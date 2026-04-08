//! WGSL-to-WASM binary shader compiler.
//!
//! Compiles a WGSL shader into a compact `.wasm` binary that regenerates
//! the WGSL string at runtime. Uses BPE (byte-pair encoding) for compression
//! with a ~110-byte WASM decoder. All WGSL knowledge lives in Zig at compile
//! time; the generated WASM has zero knowledge of WGSL syntax.
//!
//! Pipeline:
//!   WGSL → Parse → Minify → Sort declarations → Scope-local rename
//!        → Print text → BPE compress → WASM module
//!
//! The generated WASM module exports:
//!   * `memory` — linear memory; WGSL text is written at offset 0
//!   * `generate() → i32` — expands BPE data, returns WGSL byte length
//!
//! Memory layout (offsets computed per shader):
//!   ```
//!   [0 .. output_len)              Output buffer (expanded WGSL text)
//!   [rules_base .. +num_rules*2)   BPE rules table (byte pairs)
//!   [stack_base .. +256)           Expansion stack (used by decoder)
//!   [data_start .. +data_len)      BPE-compressed text
//!   ```
//!
//! Also contains an op-stream VM path (OpEmitter + VmGen) used for
//! round-trip testing. The BPE path is the default for `compile()`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Lexer = @import("Lexer.zig");
const Parser = @import("Parser.zig");
const Printer = @import("Printer.zig");
const Minifier = @import("Minifier.zig");
const RenamerMod = @import("Renamer.zig");
const Dce = @import("Dce.zig");
const WasmBinary = @import("WasmBinary.zig");
const ScopeLocalRenamer = Minifier.ScopeLocalRenamer;

// =========================================================================
// Op encoding constants
// =========================================================================

const OP_END: u8 = 0x00;
const OP_SYM: u8 = 0x01;
const OP_STR_BASE: u8 = 0x80;
const MAX_STR_ENTRIES: usize = 128;
const MAX_SYM_ENTRIES: usize = 256;

// =========================================================================
// Memory layout constants
// =========================================================================

/// Output buffer starts at 0. Size is computed from expected output length.
const OUTPUT_BASE: u32 = 0;
/// Tables and data start at a fixed offset (4KB) to simplify layout.
/// Output buffer is [0..TABLE_BASE). If output > 4KB, TABLE_BASE is bumped.
const DEFAULT_TABLE_BASE: u32 = 4096;

// =========================================================================
// Public API
// =========================================================================

pub const CompileOptions = struct {
    minify: bool = true,
    minify_options: Minifier.Options = Minifier.defaultOptions(),
};

/// Result of compiling a WGSL shader to a `.wasm` binary.
/// The `wasm` slice is valid until `deinit()` is called.
pub const CompileResult = struct {
    /// The generated WASM binary. Feed to `WebAssembly.instantiate()`.
    wasm: []const u8,
    original_size: usize,
    wasm_size: usize,
    /// Internal arena owning all allocated data.
    _arena: ?std.heap.ArenaAllocator = null,

    /// Free all memory owned by this result. After calling, `wasm` is invalid.
    pub fn deinit(self: *CompileResult, allocator: Allocator) void {
        _ = allocator;
        var arena = self._arena orelse return;
        arena.deinit();
        self._arena = null;
    }
};

/// Compile WGSL source to a `.wasm` binary shader.
pub fn compile(allocator: Allocator, source: [:0]const u8, options: CompileOptions) !CompileResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var result = try compileInner(alloc, source, options);
    result._arena = arena;
    return result;
}

fn compileInner(allocator: Allocator, source: [:0]const u8, options: CompileOptions) !CompileResult {
    const original_size = source.len;

    // 1. Parse
    var tokens = try Lexer.tokenize(allocator, source);
    defer tokens.deinit(allocator);

    var parser = try Parser.init(allocator, source, tokens);
    const module = parser.parse() catch return error.OutOfMemory;
    if (parser.errors.items.len > 0) return error.OutOfMemory;

    // 2. Prepare renamer (global frequency-based)
    const base_renamer = try prepareRenamer(allocator, module, options);

    // 3. Apply scope-local renaming for better compression
    //    Within each function, reassign params/locals to a,b,c,... per function.
    //    This makes similar functions produce identical text patterns.
    const scope_renamer = try ScopeLocalRenamer.init(allocator, module, base_renamer);
    const renamer = &scope_renamer.ren;

    // 4. Sort declarations by kind + size for better compression
    const sorted_decls = try Minifier.sortDeclarations(allocator, module);

    // 5. Print sorted minified text
    var printer = Printer.init(allocator, .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .tree_shaking = false, // already filtered by sortDeclarations
        .renamer = renamer,
    }, module.symbols.items);
    defer printer.deinit();
    const minified = try printSortedModule(allocator, &printer, module, sorted_decls);

    // 6. BPE compress
    var bpe = try BpeEncoder.compress(allocator, minified);

    // 7. Compute memory layout
    const output_len: u32 = @intCast(minified.len);
    const rules_base = alignUp(output_len, 4);
    const rules_size: u32 = @as(u32, bpe.num_rules) * 2;
    const stack_base = rules_base + rules_size;
    const stack_size: u32 = 256;
    const data_start = stack_base + stack_size;
    const data_len: u32 = @intCast(bpe.data.len);
    const data_end = data_start + data_len;

    // 8. Generate BPE decoder WASM
    var vm_body: std.ArrayListUnmanaged(u8) = .empty;
    try BpeVmGen.generate(&vm_body, allocator, .{
        .data_start = data_start,
        .data_end = data_end,
        .rules_base = rules_base,
        .stack_base = stack_base,
    });

    // 9. Build code section
    var code_section: std.ArrayListUnmanaged(u8) = .empty;
    try WasmBinary.writeUleb128(&code_section, allocator, 1);
    try WasmBinary.writeUleb128(&code_section, allocator, @intCast(vm_body.items.len));
    try code_section.appendSlice(allocator, vm_body.items);

    // 10. Assemble WASM module
    const total_size = data_end;
    const min_pages = @max(1, (total_size + 65535) / 65536);

    const wasm = try WasmBinary.writeModule(
        allocator,
        null,
        null,
        min_pages,
        &.{
            .{ .name = "memory", .kind = .memory, .index = 0 },
            .{ .name = "generate", .kind = .func, .index = 0 },
        },
        code_section.items,
        &.{
            .{ .offset = rules_base, .data = bpe.rulesBytes() },
            .{ .offset = data_start, .data = bpe.data },
        },
    );

    return .{
        .wasm = wasm,
        .original_size = original_size,
        .wasm_size = wasm.len,
    };
}

/// Print a module with pre-sorted declarations (bypasses Printer's own module printing).
fn printSortedModule(allocator: Allocator, printer: *Printer, module: *const Ast.Module, sorted_decls: []const Ast.Decl) ![]const u8 {
    _ = module;
    printer.buf.clearRetainingCapacity();
    for (sorted_decls) |decl| {
        try printer.printDecl(decl);
    }
    const result = try allocator.alloc(u8, printer.buf.items.len);
    @memcpy(result, printer.buf.items);
    return result;
}

/// Round `value` up to the next multiple of `alignment` (must be power of 2).
fn alignUp(value: u32, alignment: u32) u32 {
    return (value + alignment - 1) & ~(alignment - 1);
}

/// Set up the global frequency-based renamer. Marks API-facing symbols
/// as must-not-rename, runs DCE if configured, then assigns short names
/// to the most-used symbols.
fn prepareRenamer(allocator: Allocator, module: *Ast.Module, options: CompileOptions) !*const Printer.Renamer {
    if (options.minify) {
        const mopts = options.minify_options;

        for (module.symbols.items) |*sym| {
            if (sym.flags.is_entry_point) sym.flags.must_not_be_renamed = true;
            if (sym.kind == .builtin) sym.flags.must_not_be_renamed = true;
            if (sym.kind == .override) sym.flags.must_not_be_renamed = true;
            if (sym.flags.is_external_binding and !mopts.mangle_external_bindings) {
                sym.flags.must_not_be_renamed = true;
            }
            for (mopts.keep_names) |name| {
                if (std.mem.eql(u8, sym.original_name, name)) {
                    sym.flags.must_not_be_renamed = true;
                    break;
                }
            }
        }

        if (mopts.tree_shaking) {
            _ = Dce.mark(allocator, module);
        } else {
            for (module.symbols.items) |*sym| sym.flags.is_live = true;
        }

        var uses = Minifier.computeSymbolUsage(allocator, module);
        defer uses.deinit(allocator);
        var reserved = RenamerMod.computeReservedNames(allocator);
        for (mopts.keep_names) |name| try reserved.put(allocator, name, {});

        if (mopts.minify_identifiers) {
            const r = try allocator.create(RenamerMod.MinifyRenamer);
            r.* = RenamerMod.MinifyRenamer.init(allocator, module.symbols.items, reserved);
            r.accumulateSymbolUseCounts(&uses);
            r.allocateSlots();
            r.reserveUnrenamedSymbolNames();
            r.assignNames();
            r.renamer.ptr = @ptrCast(r);
            return &r.renamer;
        }
    } else {
        for (module.symbols.items) |*sym| sym.flags.is_live = true;
    }

    const noop = try allocator.create(RenamerMod.NoOpRenamer);
    noop.* = RenamerMod.NoOpRenamer.init(module.symbols.items);
    noop.renamer.ptr = @ptrCast(noop);
    return &noop.renamer;
}

// =========================================================================
// String Table — lazily built during op emission
// =========================================================================

const StringTable = struct {
    map: std.StringHashMapUnmanaged(u8),
    strings: std.ArrayListUnmanaged([]const u8),
    count: usize,

    fn init() StringTable {
        return .{ .map = .{}, .strings = .empty, .count = 0 };
    }

    /// Returns index if string is in table (or can be added). null if table full.
    fn getOrAdd(self: *StringTable, alloc: Allocator, s: []const u8) !?u8 {
        if (self.map.get(s)) |idx| return idx;
        if (self.count >= MAX_STR_ENTRIES) return null;
        const idx: u8 = @intCast(self.count);
        try self.map.put(alloc, s, idx);
        try self.strings.append(alloc, s);
        self.count += 1;
        return idx;
    }
};

// =========================================================================
// Symbol Table — lazily built during op emission
// =========================================================================

const SymbolTable = struct {
    map: std.StringHashMapUnmanaged(u8),
    names: std.ArrayListUnmanaged([]const u8),
    count: usize,

    fn init() SymbolTable {
        return .{ .map = .{}, .names = .empty, .count = 0 };
    }

    /// Returns index if symbol is in table (or can be added). null if table full.
    fn getOrAdd(self: *SymbolTable, alloc: Allocator, name: []const u8) !?u8 {
        if (self.map.get(name)) |idx| return idx;
        if (self.count >= MAX_SYM_ENTRIES) return null;
        const idx: u8 = @intCast(self.count);
        try self.map.put(alloc, name, idx);
        try self.names.append(alloc, name);
        self.count += 1;
        return idx;
    }
};

// =========================================================================
// OpEmitter — walks AST, produces flat op stream
// =========================================================================

const OpEmitter = struct {
    ops: std.ArrayListUnmanaged(u8),
    str_table: StringTable,
    sym_table: SymbolTable,
    alloc: Allocator,
    module: *const Ast.Module,
    renamer: *const Printer.Renamer,
    needs_space: bool,
    output_size: u32,

    fn init(allocator: Allocator, module: *const Ast.Module, renamer: *const Printer.Renamer) OpEmitter {
        return .{
            .ops = .empty,
            .str_table = StringTable.init(),
            .sym_table = SymbolTable.init(),
            .alloc = allocator,
            .module = module,
            .renamer = renamer,
            .needs_space = false,
            .output_size = 0,
        };
    }

    // -- Output helpers --

    fn emitStr(self: *OpEmitter, s: []const u8) !void {
        if (s.len >= 2) {
            if (try self.str_table.getOrAdd(self.alloc, s)) |idx| {
                try self.ops.append(self.alloc, OP_STR_BASE + idx);
                self.output_size += @intCast(s.len);
                self.needs_space = false;
                return;
            }
        }
        for (s) |c| try self.ops.append(self.alloc, c);
        self.output_size += @intCast(s.len);
        self.needs_space = false;
    }

    fn emitByte(self: *OpEmitter, c: u8) !void {
        try self.ops.append(self.alloc, c);
        self.output_size += 1;
        self.needs_space = false;
    }

    fn emitSpace(self: *OpEmitter) !void {
        if (self.needs_space) {
            try self.ops.append(self.alloc, ' ');
            self.output_size += 1;
        }
        self.needs_space = false;
    }

    fn emitName(self: *OpEmitter, ref: Ast.SymbolIndex) !void {
        if (!ref.isValid()) return;
        const idx = ref.index();
        if (idx >= self.module.symbols.items.len) return;
        const name = self.renamer.nameForSymbol(ref);
        if (name.len == 1) {
            // Single-char: emit as literal ASCII
            try self.ops.append(self.alloc, name[0]);
        } else if (name.len > 1) {
            // Multi-char: emit as symbol ref
            if (try self.sym_table.getOrAdd(self.alloc, name)) |sym_idx| {
                try self.ops.append(self.alloc, OP_SYM);
                try self.ops.append(self.alloc, sym_idx);
            } else {
                // Table full — emit literal bytes
                for (name) |c| try self.ops.append(self.alloc, c);
            }
        }
        self.output_size += @intCast(name.len);
        self.needs_space = false;
    }

    // -- Module --

    fn emitModule(self: *OpEmitter) !void {
        for (self.module.directives.items) |dir| {
            try self.emitDirective(dir);
        }
        for (self.module.declarations.items) |decl| {
            if (Dce.isDeclarationLive(decl, self.module.symbols.items)) {
                try self.emitDecl(decl);
            }
        }
    }

    fn emitDirective(self: *OpEmitter, d: Ast.Directive) !void {
        switch (d) {
            .enable => |dir| {
                try self.emitStr("enable ");
                for (dir.features.items, 0..) |feat, i| {
                    if (i > 0) { try self.emitByte(','); try self.emitSpace(); }
                    try self.emitStr(feat);
                }
                try self.emitByte(';');
            },
            .requires => |dir| {
                try self.emitStr("requires ");
                for (dir.features.items, 0..) |feat, i| {
                    if (i > 0) { try self.emitByte(','); try self.emitSpace(); }
                    try self.emitStr(feat);
                }
                try self.emitByte(';');
            },
            .diagnostic => |dir| {
                try self.emitStr("diagnostic(");
                try self.emitStr(dir.severity);
                try self.emitByte(','); try self.emitSpace();
                try self.emitStr(dir.rule);
                try self.emitByte(')');
                try self.emitByte(';');
            },
        }
    }

    // -- Declarations --

    fn emitDecl(self: *OpEmitter, d: Ast.Decl) Allocator.Error!void {
        switch (d) {
            .@"const" => |decl| {
                try self.emitStr("const ");
                try self.emitName(decl.name);
                if (decl.typ) |t| { try self.emitByte(':'); try self.emitSpace(); try self.emitType(t); }
                try self.emitSpace(); try self.emitByte('='); try self.emitSpace();
                if (decl.initializer) |init_expr| try self.emitExpr(init_expr);
                try self.emitByte(';');
            },
            .override => |decl| {
                try self.emitAttributes(decl.attributes.items);
                try self.emitStr("override ");
                try self.emitName(decl.name);
                if (decl.typ) |t| { try self.emitByte(':'); try self.emitSpace(); try self.emitType(t); }
                if (decl.initializer) |init_expr| {
                    try self.emitSpace(); try self.emitByte('='); try self.emitSpace();
                    try self.emitExpr(init_expr);
                }
                try self.emitByte(';');
            },
            .@"var" => |decl| {
                try self.emitAttributes(decl.attributes.items);
                try self.emitStr("var");
                if (decl.address_space != .none) {
                    try self.emitByte('<');
                    try self.emitStr(decl.address_space.string());
                    if (decl.access_mode != .none) {
                        try self.emitByte(','); try self.emitSpace();
                        try self.emitStr(decl.access_mode.string());
                    }
                    try self.emitByte('>');
                }
                try self.emitByte(' ');
                try self.emitName(decl.name);
                if (decl.typ) |t| { try self.emitByte(':'); try self.emitSpace(); try self.emitType(t); }
                if (decl.initializer) |init_expr| {
                    try self.emitSpace(); try self.emitByte('='); try self.emitSpace();
                    try self.emitExpr(init_expr);
                }
                try self.emitByte(';');
            },
            .let => |decl| {
                try self.emitStr("let ");
                try self.emitName(decl.name);
                if (decl.typ) |t| { try self.emitByte(':'); try self.emitSpace(); try self.emitType(t); }
                try self.emitSpace(); try self.emitByte('='); try self.emitSpace();
                if (decl.initializer) |init_expr| try self.emitExpr(init_expr);
                try self.emitByte(';');
            },
            .function => |decl| {
                try self.emitAttributes(decl.attributes.items);
                try self.emitStr("fn ");
                try self.emitName(decl.name);
                try self.emitByte('(');
                for (decl.parameters.items, 0..) |param, i| {
                    if (i > 0) { try self.emitByte(','); try self.emitSpace(); }
                    try self.emitAttributes(param.attributes.items);
                    try self.emitName(param.name);
                    try self.emitByte(':'); try self.emitSpace();
                    try self.emitType(param.typ);
                }
                try self.emitByte(')');
                if (decl.return_type) |rt| {
                    try self.emitSpace(); try self.emitStr("->"); try self.emitSpace();
                    try self.emitAttributes(decl.return_attr.items);
                    try self.emitType(rt);
                }
                try self.emitSpace();
                if (decl.body) |body| try self.emitCompoundStmt(body);
            },
            .@"struct" => |decl| {
                try self.emitStr("struct ");
                try self.emitName(decl.name);
                try self.emitSpace();
                try self.emitByte('{');
                for (decl.members.items, 0..) |member, i| {
                    try self.emitAttributes(member.attributes.items);
                    try self.emitName(member.name);
                    try self.emitByte(':'); try self.emitSpace();
                    try self.emitType(member.typ);
                    if (i < decl.members.items.len - 1) try self.emitByte(',');
                }
                try self.emitByte('}');
            },
            .alias => |decl| {
                try self.emitStr("alias ");
                try self.emitName(decl.name);
                try self.emitSpace(); try self.emitByte('='); try self.emitSpace();
                try self.emitType(decl.typ);
                try self.emitByte(';');
            },
            .const_assert => |decl| {
                try self.emitStr("const_assert ");
                try self.emitExpr(decl.expr);
                try self.emitByte(';');
            },
        }
    }

    fn emitAttributes(self: *OpEmitter, attrs: []const Ast.Attribute) Allocator.Error!void {
        for (attrs) |attr| {
            try self.emitByte('@');
            try self.emitStr(attr.name);
            if (attr.args.items.len > 0) {
                try self.emitByte('(');
                for (attr.args.items, 0..) |arg, i| {
                    if (i > 0) { try self.emitByte(','); try self.emitSpace(); }
                    try self.emitExpr(arg);
                }
                try self.emitByte(')');
            }
            self.needs_space = true;
            try self.emitSpace();
        }
    }

    // -- Types --

    fn emitType(self: *OpEmitter, t: Ast.Type) Allocator.Error!void {
        switch (t) {
            .ident => |typ| {
                if (typ.ref.isValid()) {
                    try self.emitName(typ.ref);
                } else {
                    try self.emitStr(typ.name);
                }
            },
            .vec => |typ| {
                if (typ.shorthand.len > 0) {
                    try self.emitStr(typ.shorthand);
                } else {
                    try self.emitStr("vec");
                    try self.emitByte('0' + typ.size);
                    try self.emitByte('<');
                    if (typ.elem_type) |et| try self.emitType(et);
                    try self.emitByte('>');
                    self.needs_space = true;
                }
            },
            .mat => |typ| {
                if (typ.shorthand.len > 0) {
                    try self.emitStr(typ.shorthand);
                } else {
                    try self.emitStr("mat");
                    try self.emitByte('0' + typ.cols);
                    try self.emitByte('x');
                    try self.emitByte('0' + typ.rows);
                    try self.emitByte('<');
                    if (typ.elem_type) |et| try self.emitType(et);
                    try self.emitByte('>');
                    self.needs_space = true;
                }
            },
            .array => |typ| {
                try self.emitStr("array<");
                if (typ.elem_type) |et| try self.emitType(et);
                if (typ.size) |s| { try self.emitByte(','); try self.emitSpace(); try self.emitExpr(s); }
                try self.emitByte('>');
                self.needs_space = true;
            },
            .ptr => |typ| {
                try self.emitStr("ptr<");
                try self.emitStr(typ.address_space.string());
                try self.emitByte(','); try self.emitSpace();
                try self.emitType(typ.elem_type);
                if (typ.access_mode != .none) {
                    try self.emitByte(','); try self.emitSpace();
                    try self.emitStr(typ.access_mode.string());
                }
                try self.emitByte('>');
                self.needs_space = true;
            },
            .atomic => |typ| {
                try self.emitStr("atomic<");
                try self.emitType(typ.elem_type);
                try self.emitByte('>');
                self.needs_space = true;
            },
            .sampler => |typ| {
                if (typ.comparison) {
                    try self.emitStr("sampler_comparison");
                } else {
                    try self.emitStr("sampler");
                }
            },
            .texture => |typ| try self.emitTextureType(typ),
        }
    }

    fn emitTextureType(self: *OpEmitter, t: *const Ast.TextureType) Allocator.Error!void {
        const prefix: []const u8 = switch (t.kind) {
            .sampled => "texture_",
            .multisampled => "texture_multisampled_",
            .storage => "texture_storage_",
            .depth => "texture_depth_",
            .depth_multisampled => "texture_depth_multisampled_",
            .external => {
                try self.emitStr("texture_external");
                return;
            },
        };
        try self.emitStr(prefix);
        try self.emitStr(switch (t.dimension) {
            .@"1d" => "1d",
            .@"2d" => "2d",
            .@"2d_array" => "2d_array",
            .@"3d" => "3d",
            .cube => "cube",
            .cube_array => "cube_array",
        });
        if (t.sampled_type) |st| {
            try self.emitByte('<');
            try self.emitType(st);
            try self.emitByte('>');
            self.needs_space = true;
        } else if (t.texel_format.len > 0) {
            try self.emitByte('<');
            try self.emitStr(t.texel_format);
            try self.emitByte(','); try self.emitSpace();
            try self.emitStr(t.access_mode.string());
            try self.emitByte('>');
            self.needs_space = true;
        }
    }

    // -- Expressions --

    fn emitExpr(self: *OpEmitter, e: Ast.Expr) Allocator.Error!void {
        switch (e) {
            .ident => |expr| {
                if (expr.ref.isValid()) {
                    try self.emitName(expr.ref);
                } else {
                    try self.emitStr(expr.name);
                }
            },
            .literal => |expr| try self.emitStr(expr.value),
            .binary => |expr| {
                try self.emitExpr(expr.left);
                try self.emitSpace(); try self.emitStr(expr.op.string()); try self.emitSpace();
                try self.emitExpr(expr.right);
            },
            .unary => |expr| {
                try self.emitStr(expr.op.string());
                try self.emitExpr(expr.operand);
            },
            .call => |expr| {
                if (expr.template_type) |tt| {
                    try self.emitType(tt);
                } else if (expr.func) |f| {
                    try self.emitExpr(f);
                }
                try self.emitByte('(');
                for (expr.args.items, 0..) |arg, i| {
                    if (i > 0) { try self.emitByte(','); try self.emitSpace(); }
                    try self.emitExpr(arg);
                }
                try self.emitByte(')');
            },
            .index => |expr| {
                try self.emitExpr(expr.base);
                try self.emitByte('[');
                try self.emitExpr(expr.idx);
                try self.emitByte(']');
            },
            .member => |expr| {
                try self.emitExpr(expr.base);
                try self.emitByte('.');
                try self.emitStr(expr.member_name);
            },
            .paren => |expr| {
                try self.emitByte('(');
                try self.emitExpr(expr.expr);
                try self.emitByte(')');
            },
        }
    }

    // -- Statements --

    fn emitCompoundStmt(self: *OpEmitter, stmt: *const Ast.CompoundStmt) Allocator.Error!void {
        try self.emitByte('{');
        for (stmt.stmts.items) |s| {
            try self.emitStmt(s);
        }
        try self.emitByte('}');
    }

    fn emitStmt(self: *OpEmitter, s: Ast.Stmt) Allocator.Error!void {
        switch (s) {
            .compound => |stmt| {
                try self.emitByte('{');
                for (stmt.stmts.items) |sub| try self.emitStmt(sub);
                try self.emitByte('}');
            },
            .@"return" => |stmt| {
                try self.emitStr("return");
                if (stmt.value) |v| { try self.emitByte(' '); try self.emitExpr(v); }
                try self.emitByte(';');
            },
            .@"if" => |stmt| try self.emitIfStmt(stmt),
            .@"switch" => |stmt| {
                try self.emitStr("switch ");
                try self.emitExpr(stmt.expr);
                try self.emitSpace();
                try self.emitByte('{');
                for (stmt.cases.items) |c| {
                    if (c.selectors.items.len == 0) {
                        try self.emitStr("default");
                    } else {
                        try self.emitStr("case ");
                        for (c.selectors.items, 0..) |sel, i| {
                            if (i > 0) { try self.emitByte(','); try self.emitSpace(); }
                            try self.emitExpr(sel);
                        }
                    }
                    try self.emitByte(':');
                    try self.emitSpace();
                    try self.emitCompoundStmt(c.body);
                }
                try self.emitByte('}');
            },
            .@"for" => |stmt| try self.emitForStmt(stmt),
            .@"while" => |stmt| {
                try self.emitStr("while ");
                try self.emitExpr(stmt.condition);
                try self.emitSpace();
                try self.emitCompoundStmt(stmt.body);
            },
            .loop => |stmt| {
                try self.emitStr("loop");
                try self.emitSpace();
                try self.emitCompoundStmt(stmt.body);
                if (stmt.continuing) |c| {
                    try self.emitStr(" continuing");
                    try self.emitSpace();
                    try self.emitCompoundStmt(c);
                }
            },
            .@"break" => try self.emitStr("break;"),
            .break_if => |stmt| {
                try self.emitStr("break if ");
                try self.emitExpr(stmt.condition);
                try self.emitByte(';');
            },
            .@"continue" => try self.emitStr("continue;"),
            .discard => try self.emitStr("discard;"),
            .assign => |stmt| {
                try self.emitExpr(stmt.left);
                try self.emitSpace(); try self.emitStr(stmt.op.string()); try self.emitSpace();
                try self.emitExpr(stmt.right);
                try self.emitByte(';');
            },
            .incr_decr => |stmt| {
                try self.emitExpr(stmt.expr);
                if (stmt.increment) try self.emitStr("++") else try self.emitStr("--");
                try self.emitByte(';');
            },
            .call => |stmt| {
                try self.emitExpr(.{ .call = stmt.call });
                try self.emitByte(';');
            },
            .decl => |stmt| try self.emitDeclStmt(stmt.decl),
        }
    }

    fn emitIfStmt(self: *OpEmitter, stmt: *const Ast.IfStmt) Allocator.Error!void {
        try self.emitStr("if ");
        try self.emitExpr(stmt.condition);
        try self.emitSpace();
        try self.emitCompoundStmt(stmt.body);
        if (stmt.else_branch) |eb| {
            try self.emitElseChain(eb);
        }
    }

    fn emitElseChain(self: *OpEmitter, s: Ast.Stmt) Allocator.Error!void {
        if (s == .@"if") {
            const if_stmt = s.@"if";
            try self.emitStr(" else if ");
            try self.emitExpr(if_stmt.condition);
            try self.emitSpace();
            try self.emitCompoundStmt(if_stmt.body);
            if (if_stmt.else_branch) |eb| try self.emitElseChain(eb);
        } else {
            try self.emitStr(" else");
            try self.emitSpace();
            try self.emitStmt(s);
        }
    }

    fn emitForStmt(self: *OpEmitter, stmt: *const Ast.ForStmt) Allocator.Error!void {
        try self.emitStr("for(");
        if (stmt.init_stmt) |is| try self.emitForInit(is);
        try self.emitByte(';');
        if (stmt.condition) |c| try self.emitExpr(c);
        try self.emitByte(';');
        if (stmt.update) |u| try self.emitForUpdate(u);
        try self.emitByte(')');
        try self.emitSpace();
        try self.emitCompoundStmt(stmt.body);
    }

    fn emitForInit(self: *OpEmitter, s: Ast.Stmt) Allocator.Error!void {
        switch (s) {
            .decl => |ds| {
                switch (ds.decl) {
                    .@"var" => |decl| {
                        try self.emitStr("var ");
                        try self.emitName(decl.name);
                        if (decl.typ) |t| { try self.emitByte(':'); try self.emitSpace(); try self.emitType(t); }
                        if (decl.initializer) |init_expr| {
                            try self.emitSpace(); try self.emitByte('='); try self.emitSpace();
                            try self.emitExpr(init_expr);
                        }
                    },
                    .let => |decl| {
                        try self.emitStr("let ");
                        try self.emitName(decl.name);
                        if (decl.typ) |t| { try self.emitByte(':'); try self.emitSpace(); try self.emitType(t); }
                        try self.emitSpace(); try self.emitByte('='); try self.emitSpace();
                        if (decl.initializer) |init_expr| try self.emitExpr(init_expr);
                    },
                    else => {},
                }
            },
            .assign => |stmt| {
                try self.emitExpr(stmt.left);
                try self.emitSpace(); try self.emitStr(stmt.op.string()); try self.emitSpace();
                try self.emitExpr(stmt.right);
            },
            else => {},
        }
    }

    fn emitForUpdate(self: *OpEmitter, s: Ast.Stmt) Allocator.Error!void {
        switch (s) {
            .incr_decr => |stmt| {
                try self.emitExpr(stmt.expr);
                if (stmt.increment) try self.emitStr("++") else try self.emitStr("--");
            },
            .assign => |stmt| {
                try self.emitExpr(stmt.left);
                try self.emitSpace(); try self.emitStr(stmt.op.string()); try self.emitSpace();
                try self.emitExpr(stmt.right);
            },
            .call => |stmt| try self.emitExpr(.{ .call = stmt.call }),
            else => {},
        }
    }

    fn emitDeclStmt(self: *OpEmitter, d: Ast.Decl) Allocator.Error!void {
        switch (d) {
            .@"const" => |decl| {
                try self.emitStr("const ");
                try self.emitName(decl.name);
                if (decl.typ) |t| { try self.emitByte(':'); try self.emitSpace(); try self.emitType(t); }
                try self.emitSpace(); try self.emitByte('='); try self.emitSpace();
                if (decl.initializer) |init_expr| try self.emitExpr(init_expr);
                try self.emitByte(';');
            },
            .let => |decl| {
                try self.emitStr("let ");
                try self.emitName(decl.name);
                if (decl.typ) |t| { try self.emitByte(':'); try self.emitSpace(); try self.emitType(t); }
                try self.emitSpace(); try self.emitByte('='); try self.emitSpace();
                if (decl.initializer) |init_expr| try self.emitExpr(init_expr);
                try self.emitByte(';');
            },
            .@"var" => |decl| {
                try self.emitAttributes(decl.attributes.items);
                try self.emitStr("var");
                if (decl.address_space != .none) {
                    try self.emitByte('<');
                    try self.emitStr(decl.address_space.string());
                    if (decl.access_mode != .none) {
                        try self.emitByte(','); try self.emitSpace();
                        try self.emitStr(decl.access_mode.string());
                    }
                    try self.emitByte('>');
                }
                try self.emitByte(' ');
                try self.emitName(decl.name);
                if (decl.typ) |t| { try self.emitByte(':'); try self.emitSpace(); try self.emitType(t); }
                if (decl.initializer) |init_expr| {
                    try self.emitSpace(); try self.emitByte('='); try self.emitSpace();
                    try self.emitExpr(init_expr);
                }
                try self.emitByte(';');
            },
            else => try self.emitDecl(d),
        }
    }
};

// =========================================================================
// VmGen — generates tiny WASM VM that executes the op stream
// =========================================================================

const VmGen = struct {
    const Layout = struct {
        ops_offset: u32,
        sym_offsets_base: u32,
        sym_lens_base: u32,
        str_offsets_base: u32,
        str_lens_base: u32,
    };

    /// Generate the WASM function body for `generate() -> i32`.
    /// The VM dispatches on op bytes: literal ASCII, string ref, symbol ref.
    fn generate(body: *std.ArrayListUnmanaged(u8), alloc: Allocator, layout: Layout) !void {
        const e = WasmBinary.Emit.init(body, alloc);

        // Locals: 0=rp (read pointer), 1=wp (write pointer), 2=op, 3=idx, 4=len, 5=src
        try e.localDecl(6);

        // rp = ops_offset
        try e.i32_const(@intCast(layout.ops_offset));
        try e.local_set(0);

        // wp = 0
        try e.i32_const(0);
        try e.local_set(1);

        // Main loop
        try e.block(); // $exit (depth 1 from loop, 0 from block)
        try e.loop_(); // $loop

        // op = mem[rp]
        try e.local_get(0);
        try e.i32_load8_u();
        try e.local_set(2);

        // rp++
        try e.local_get(0);
        try e.i32_const(1);
        try e.i32_add();
        try e.local_set(0);

        // if op == 0: return wp
        try e.local_get(2);
        try e.i32_eqz();
        try e.br_if(1); // break to $exit

        // if op >= 0x80: string ref
        try e.local_get(2);
        try e.i32_const(0x80);
        try e.i32_ge_u();
        try e.if_();
        {
            // idx = op - 0x80
            try e.local_get(2);
            try e.i32_const(0x80);
            try e.i32_sub();
            try e.local_set(3);
            // src = str_offsets[idx] (u16 LE)
            try e.local_get(3);
            try e.i32_const(2);
            try e.i32_mul();
            try e.i32_const(@intCast(layout.str_offsets_base));
            try e.i32_add();
            try e.i32_load16_u();
            try e.local_set(5);
            // len = str_lens[idx]
            try e.local_get(3);
            try e.i32_const(@intCast(layout.str_lens_base));
            try e.i32_add();
            try e.i32_load8_u();
            try e.local_set(4);
            // copy loop: while len > 0
            try e.block();
            try e.loop_();
            try e.local_get(4);
            try e.i32_eqz();
            try e.br_if(1); // break copy loop
            // output[wp] = mem[src]
            try e.local_get(1);
            try e.local_get(5);
            try e.i32_load8_u();
            try e.i32_store8();
            // wp++, src++, len--
            try e.local_get(1);
            try e.i32_const(1);
            try e.i32_add();
            try e.local_set(1);
            try e.local_get(5);
            try e.i32_const(1);
            try e.i32_add();
            try e.local_set(5);
            try e.local_get(4);
            try e.i32_const(1);
            try e.i32_sub();
            try e.local_set(4);
            try e.br(0); // continue copy loop
            try e.end(); // end copy loop
            try e.end(); // end copy block
            try e.br(1); // continue main loop (depth: if→loop)
        }
        try e.end(); // end if (string ref)

        // if op >= 0x20: literal ASCII byte
        try e.local_get(2);
        try e.i32_const(0x20);
        try e.i32_ge_u();
        try e.if_();
        {
            // output[wp] = op
            try e.local_get(1);
            try e.local_get(2);
            try e.i32_store8();
            // wp++
            try e.local_get(1);
            try e.i32_const(1);
            try e.i32_add();
            try e.local_set(1);
            try e.br(1); // continue main loop (depth 1 because inside if)
        }
        try e.end(); // end if (literal)

        // if op == 0x01: symbol ref
        try e.local_get(2);
        try e.i32_const(OP_SYM);
        try e.i32_eq();
        try e.if_();
        {
            // idx = mem[rp]; rp++
            try e.local_get(0);
            try e.i32_load8_u();
            try e.local_set(3);
            try e.local_get(0);
            try e.i32_const(1);
            try e.i32_add();
            try e.local_set(0);
            // src = sym_offsets[idx] (u16 LE)
            try e.local_get(3);
            try e.i32_const(2);
            try e.i32_mul();
            try e.i32_const(@intCast(layout.sym_offsets_base));
            try e.i32_add();
            try e.i32_load16_u();
            try e.local_set(5);
            // len = sym_lens[idx]
            try e.local_get(3);
            try e.i32_const(@intCast(layout.sym_lens_base));
            try e.i32_add();
            try e.i32_load8_u();
            try e.local_set(4);
            // copy loop
            try e.block();
            try e.loop_();
            try e.local_get(4);
            try e.i32_eqz();
            try e.br_if(1);
            try e.local_get(1);
            try e.local_get(5);
            try e.i32_load8_u();
            try e.i32_store8();
            try e.local_get(1);
            try e.i32_const(1);
            try e.i32_add();
            try e.local_set(1);
            try e.local_get(5);
            try e.i32_const(1);
            try e.i32_add();
            try e.local_set(5);
            try e.local_get(4);
            try e.i32_const(1);
            try e.i32_sub();
            try e.local_set(4);
            try e.br(0);
            try e.end();
            try e.end();
            try e.br(1); // continue main loop (depth: if→loop)
        }
        try e.end(); // end if (symbol ref)

        // Skip unknown ops
        try e.br(0); // continue main loop
        try e.end(); // end $loop
        try e.end(); // end $exit

        // return wp
        try e.local_get(1);
        try e.end(); // end function
    }
};

// =========================================================================
// Native op decoder — for round-trip testing
// =========================================================================

/// Decode an op stream into text using the provided tables.
/// Used for testing: compare output against the text Printer.
pub fn decodeOps(
    alloc: Allocator,
    ops: []const u8,
    sym_names: []const []const u8,
    str_consts: []const []const u8,
) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var rp: usize = 0;
    while (rp < ops.len) {
        const op = ops[rp];
        rp += 1;
        if (op == OP_END) break;
        if (op >= OP_STR_BASE) {
            const idx = op - OP_STR_BASE;
            if (idx < str_consts.len) try out.appendSlice(alloc, str_consts[idx]);
        } else if (op >= 0x20) {
            try out.append(alloc, op);
        } else if (op == OP_SYM) {
            if (rp < ops.len) {
                const idx = ops[rp];
                rp += 1;
                if (idx < sym_names.len) try out.appendSlice(alloc, sym_names[idx]);
            }
        }
        // else: reserved op, skip
    }
    return out.items;
}

// =========================================================================
// BPE Encoder — byte-pair encoding for text compression
// =========================================================================

/// Byte-pair encoding compressor.
///
/// Iteratively replaces the most frequent byte pair with a new byte (0x80+),
/// recording the replacement rule. Up to `MAX_RULES` rounds. The decoder
/// reverses the process with a stack-based expansion.
const BpeEncoder = struct {
    const MAX_RULES = 64;

    rules: [MAX_RULES][2]u8,
    num_rules: u8,
    data: []const u8,

    /// Return the rules as a flat byte slice (2 bytes per rule).
    fn rulesBytes(self: *const BpeEncoder) []const u8 {
        return @as([*]const u8, @ptrCast(&self.rules))[0 .. @as(usize, self.num_rules) * 2];
    }

    /// Compress input using iterative byte-pair encoding.
    /// Caller owns returned `.data` via the provided allocator.
    fn compress(allocator: Allocator, input: []const u8) !BpeEncoder {
        var result: BpeEncoder = .{ .rules = undefined, .num_rules = 0, .data = input };
        if (input.len < 2) return result;

        var buf = try allocator.alloc(u8, input.len);
        @memcpy(buf, input);
        var len = input.len;

        // Heap-allocated pair frequency table (256*256*4 = 256KB, too large for stack)
        const counts = try allocator.alloc(u32, 256 * 256);

        var next_byte: u16 = 0x80;
        for (0..MAX_RULES) |_| {
            if (next_byte > 0xFF or len < 2) break;

            const best = findBestPair(buf[0..len], counts);
            if (best.count < 3) break;

            len = replacePair(buf, len, best.byte_a, best.byte_b, @intCast(next_byte));
            result.rules[result.num_rules] = .{ best.byte_a, best.byte_b };
            result.num_rules += 1;
            next_byte += 1;
        }

        result.data = buf[0..len];
        return result;
    }

    const BestPair = struct { byte_a: u8, byte_b: u8, count: u32 };

    /// Scan data for the most frequent byte pair.
    fn findBestPair(data: []const u8, counts: []u32) BestPair {
        @memset(counts, 0);
        for (0..data.len - 1) |i| {
            counts[@as(usize, data[i]) * 256 + data[i + 1]] += 1;
        }

        var best_idx: usize = 0;
        var best_count: u32 = 0;
        for (counts, 0..) |c, idx| {
            if (c > best_count) {
                best_count = c;
                best_idx = idx;
            }
        }
        return .{
            .byte_a = @intCast(best_idx / 256),
            .byte_b = @intCast(best_idx % 256),
            .count = best_count,
        };
    }

    /// Replace all non-overlapping occurrences of (byte_a, byte_b) with new_byte.
    /// Returns the new length.
    fn replacePair(buf: []u8, len: usize, byte_a: u8, byte_b: u8, new_byte: u8) usize {
        var write: usize = 0;
        var read: usize = 0;
        while (read < len) {
            if (read + 1 < len and buf[read] == byte_a and buf[read + 1] == byte_b) {
                buf[write] = new_byte;
                write += 1;
                read += 2;
            } else {
                buf[write] = buf[read];
                write += 1;
                read += 1;
            }
        }
        return write;
    }
};

// =========================================================================
// BPE WASM decoder generator — stack-based BPE expansion
// =========================================================================

/// Generates WASM bytecode for a stack-based BPE decoder.
///
/// The decoder reads compressed bytes sequentially. Literal bytes (< 0x80)
/// are written directly to output. BPE bytes (>= 0x80) push their two
/// children onto an expansion stack. ~110 bytes of WASM code.
const BpeVmGen = struct {
    const Layout = struct {
        data_start: u32,
        data_end: u32,
        rules_base: u32,
        stack_base: u32,
    };

    /// Emit the `generate() → i32` function body.
    fn generate(body: *std.ArrayListUnmanaged(u8), alloc: Allocator, layout: Layout) !void {
        const e = WasmBinary.Emit.init(body, alloc);

        // Locals: 0=rp, 1=wp, 2=sp, 3=byte
        try e.localDecl(4);

        // rp = data_start
        try e.i32_const(@intCast(layout.data_start));
        try e.local_set(0);
        // wp = 0
        try e.i32_const(0);
        try e.local_set(1);
        // sp = stack_base
        try e.i32_const(@intCast(layout.stack_base));
        try e.local_set(2);

        // block $exit
        try e.block();
        // loop $main
        try e.loop_();

        // --- Get next byte: stack or data ---
        // if sp > stack_base: pop from stack
        try e.local_get(2);
        try e.i32_const(@intCast(layout.stack_base));
        try e.i32_gt_u();
        try e.if_();
        {
            // sp--; byte = mem[sp]
            try e.local_get(2);
            try e.i32_const(1);
            try e.i32_sub();
            try e.local_tee(2);
            try e.i32_load8_u();
            try e.local_set(3);
        }
        try e.else_();
        {
            // if rp >= data_end: break
            try e.local_get(0);
            try e.i32_const(@intCast(layout.data_end));
            try e.i32_ge_u();
            try e.br_if(2); // break to $exit (else=0, loop=1, block=2)

            // byte = mem[rp]; rp++
            try e.local_get(0);
            try e.i32_load8_u();
            try e.local_set(3);
            try e.local_get(0);
            try e.i32_const(1);
            try e.i32_add();
            try e.local_set(0);
        }
        try e.end(); // end if/else

        // --- Process byte ---
        try e.local_get(3);
        try e.i32_const(0x80);
        try e.i32_lt_u();
        try e.if_();
        {
            // Literal: output[wp++] = byte
            try e.local_get(1);
            try e.local_get(3);
            try e.i32_store8();
            try e.local_get(1);
            try e.i32_const(1);
            try e.i32_add();
            try e.local_set(1);
        }
        try e.else_();
        {
            // BPE rule: push children to stack
            // Compute idx_addr = rules_base + (byte - 0x80) * 2, store in local 3
            // (byte is no longer needed after this point)
            try e.local_get(3);
            try e.i32_const(0x80);
            try e.i32_sub();
            try e.i32_const(2);
            try e.i32_mul();
            try e.i32_const(@intCast(layout.rules_base));
            try e.i32_add();
            try e.local_set(3); // local 3 = idx_addr

            // Push second child first (so first child is popped first)
            // stack[sp] = mem[idx_addr + 1]; sp++
            try e.local_get(2); // store dest = sp
            try e.local_get(3);
            try e.i32_const(1);
            try e.i32_add();
            try e.i32_load8_u(); // load second child
            try e.i32_store8(); // stack[sp] = second child
            try e.local_get(2);
            try e.i32_const(1);
            try e.i32_add();
            try e.local_set(2); // sp++

            // Push first child: stack[sp] = mem[idx_addr]; sp++
            try e.local_get(2); // store dest = sp
            try e.local_get(3);
            try e.i32_load8_u(); // load first child
            try e.i32_store8(); // stack[sp] = first child
            try e.local_get(2);
            try e.i32_const(1);
            try e.i32_add();
            try e.local_set(2); // sp++
        }
        try e.end(); // end if/else (literal vs BPE)

        try e.br(0); // continue $main loop
        try e.end(); // end $main loop
        try e.end(); // end $exit block

        // return wp
        try e.local_get(1);
        try e.end(); // end function
    }
};

// =========================================================================
// Native BPE decoder — for round-trip testing
// =========================================================================

/// Expand BPE-compressed data back to text using the rules table.
/// Uses the same stack-based algorithm as the WASM decoder.
fn decodeBpe(allocator: Allocator, data: []const u8, rules: []const [2]u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var stack: [512]u8 = undefined;
    var sp: usize = 0;
    var rp: usize = 0;

    while (sp > 0 or rp < data.len) {
        const byte = if (sp > 0) blk: {
            sp -= 1;
            break :blk stack[sp];
        } else blk: {
            const b = data[rp];
            rp += 1;
            break :blk b;
        };

        if (byte < 0x80) {
            try out.append(allocator, byte);
        } else {
            const idx = byte - 0x80;
            if (idx < rules.len) {
                stack[sp] = rules[idx][1];
                sp += 1;
                stack[sp] = rules[idx][0];
                sp += 1;
            }
        }
    }
    return out.items;
}

// =========================================================================
// Tests
// =========================================================================

/// Helper: compile a shader and verify the WASM is valid.
fn compileAndCheck(source: [:0]const u8) !CompileResult {
    const a = std.testing.allocator;
    var result = try compile(a, source, .{});
    // Verify WASM magic
    try std.testing.expectEqualSlices(u8, &WasmBinary.magic, result.wasm[0..4]);
    try std.testing.expect(result.wasm_size > 0);
    return result;
}

/// Helper: compile, then run native op decoder and compare with text Printer.
fn compileAndVerifyRoundTrip(source: [:0]const u8) !void {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Get expected output from the text Printer (minified)
    var tokens = try Lexer.tokenize(alloc, source);
    defer tokens.deinit(alloc);
    var parser = try Parser.init(alloc, source, tokens);
    const module = parser.parse() catch return error.OutOfMemory;
    if (parser.errors.items.len > 0) return error.OutOfMemory;

    // Prepare renamer (same as compile path)
    const renamer = try prepareRenamer(alloc, module, .{});

    // Text printer (minified)
    var printer = Printer.init(alloc, .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .tree_shaking = true,
        .renamer = renamer,
    }, module.symbols.items);
    defer printer.deinit();
    const expected = try printer.print(module);

    // Op emitter
    var emitter = OpEmitter.init(alloc, module, renamer);
    try emitter.emitModule();
    try emitter.ops.append(alloc, OP_END);

    // Decode ops back to text
    const actual = try decodeOps(
        alloc,
        emitter.ops.items,
        emitter.sym_table.names.items,
        emitter.str_table.strings.items,
    );

    try std.testing.expectEqualStrings(expected, actual);
}

test "compile: empty function" {
    var r = try compileAndCheck("fn main(){}");
    defer r.deinit(std.testing.allocator);
}

test "compile: function with return" {
    var r = try compileAndCheck("fn f()->i32{return 1;}");
    defer r.deinit(std.testing.allocator);
}

test "compile: let declaration" {
    var r = try compileAndCheck("fn f(){let x=1;}");
    defer r.deinit(std.testing.allocator);
}

test "compile: const declaration" {
    var r = try compileAndCheck("const PI=3.14;");
    defer r.deinit(std.testing.allocator);
}

test "compile: var declaration" {
    var r = try compileAndCheck("fn f(){var x:f32=0.0;}");
    defer r.deinit(std.testing.allocator);
}

test "compile: var with address space" {
    var r = try compileAndCheck("var<private> x:f32;");
    defer r.deinit(std.testing.allocator);
}

test "compile: struct declaration" {
    var r = try compileAndCheck("struct S{a:f32,b:i32}");
    defer r.deinit(std.testing.allocator);
}

test "compile: alias declaration" {
    var r = try compileAndCheck("alias F=f32;");
    defer r.deinit(std.testing.allocator);
}

test "compile: override declaration" {
    var r = try compileAndCheck("override x:f32=1.0;");
    defer r.deinit(std.testing.allocator);
}

test "compile: const_assert" {
    var r = try compileAndCheck("const_assert true;");
    defer r.deinit(std.testing.allocator);
}

test "compile: binary expression" {
    var r = try compileAndCheck("const x=1+2;");
    defer r.deinit(std.testing.allocator);
}

test "compile: unary expression" {
    var r = try compileAndCheck("fn f(){let x=-1;}");
    defer r.deinit(std.testing.allocator);
}

test "compile: call expression" {
    var r = try compileAndCheck("fn f(){let x=min(1,2);}");
    defer r.deinit(std.testing.allocator);
}

test "compile: member expression" {
    var r = try compileAndCheck("struct S{x:f32} fn f(s:S){let v=s.x;}");
    defer r.deinit(std.testing.allocator);
}

test "compile: index expression" {
    var r = try compileAndCheck("fn f(a:array<f32,4>){let v=a[0];}");
    defer r.deinit(std.testing.allocator);
}

test "compile: paren expression" {
    var r = try compileAndCheck("const x=(1+2)*3;");
    defer r.deinit(std.testing.allocator);
}

test "compile: if statement" {
    var r = try compileAndCheck("fn f(){if true{return;}}");
    defer r.deinit(std.testing.allocator);
}

test "compile: if-else statement" {
    var r = try compileAndCheck("fn f(){if true{return;}else{return;}}");
    defer r.deinit(std.testing.allocator);
}

test "compile: while statement" {
    var r = try compileAndCheck("fn f(){var i=0;while i<10{i=i+1;}}");
    defer r.deinit(std.testing.allocator);
}

test "compile: for statement" {
    var r = try compileAndCheck("fn f(){for(var i=0;i<10;i=i+1){}}");
    defer r.deinit(std.testing.allocator);
}

test "compile: loop statement" {
    var r = try compileAndCheck("fn f(){loop{break;}}");
    defer r.deinit(std.testing.allocator);
}

test "compile: assign statement" {
    var r = try compileAndCheck("fn f(){var x=0;x=1;}");
    defer r.deinit(std.testing.allocator);
}

test "compile: incr_decr statement" {
    var r = try compileAndCheck("fn f(){var x=0;x++;}");
    defer r.deinit(std.testing.allocator);
}

test "compile: call statement" {
    var r = try compileAndCheck("fn g(){} fn f(){g();}");
    defer r.deinit(std.testing.allocator);
}

test "compile: discard statement" {
    var r = try compileAndCheck("fn f(){discard;}");
    defer r.deinit(std.testing.allocator);
}

test "compile: continue statement" {
    var r = try compileAndCheck("fn f(){loop{continue;}}");
    defer r.deinit(std.testing.allocator);
}

test "compile: break_if statement" {
    var r = try compileAndCheck("fn f(){loop{break if true;}}");
    defer r.deinit(std.testing.allocator);
}

test "compile: type vec shorthand" {
    var r = try compileAndCheck("fn f(v:vec4f){}");
    defer r.deinit(std.testing.allocator);
}

test "compile: type array" {
    var r = try compileAndCheck("fn f(a:array<f32,4>){}");
    defer r.deinit(std.testing.allocator);
}

test "compile: type sampler" {
    var r = try compileAndCheck("fn f(s:sampler){}");
    defer r.deinit(std.testing.allocator);
}

test "compile: attributes" {
    var r = try compileAndCheck("@compute @workgroup_size(1) fn main(){}");
    defer r.deinit(std.testing.allocator);
}

test "compile: function with params and return type" {
    var r = try compileAndCheck("fn add(a:f32,b:f32)->f32{return a+b;}");
    defer r.deinit(std.testing.allocator);
}

test "compile: repeated calls no leak" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "fn f(){let x=1;return;}";
    for (0..10) |_| {
        var result = try compile(a, source, .{});
        result.deinit(a);
    }
}

test "compile: switch statement" {
    var r = try compileAndCheck("fn f(x:i32){switch x{case 1:{} default:{}}}");
    defer r.deinit(std.testing.allocator);
}

test "compile: loop with break" {
    var r = try compileAndCheck("fn f(){loop{break;}}");
    defer r.deinit(std.testing.allocator);
}

test "compile: struct with attributes" {
    var r = try compileAndCheck("struct V{@location(0) pos:vec4f,@location(1) col:vec4f}");
    defer r.deinit(std.testing.allocator);
}

test "compile: uniform var with binding" {
    var r = try compileAndCheck("@group(0) @binding(0) var<uniform> u:f32;@compute @workgroup_size(1) fn main(){let x=u;}");
    defer r.deinit(std.testing.allocator);
}

// Round-trip tests: verify OpEmitter output matches text Printer
test "round-trip: empty function" {
    try compileAndVerifyRoundTrip("fn main(){}");
}

test "round-trip: function with return" {
    try compileAndVerifyRoundTrip("fn f()->i32{return 1;}");
}

test "round-trip: const declaration" {
    try compileAndVerifyRoundTrip("const PI=3.14;");
}

test "round-trip: var with address space" {
    try compileAndVerifyRoundTrip("var<private> x:f32;");
}

test "round-trip: struct declaration" {
    try compileAndVerifyRoundTrip("struct S{a:f32,b:i32}");
}

test "round-trip: binary expression" {
    try compileAndVerifyRoundTrip("const x=1+2;");
}

test "round-trip: function with params and return" {
    try compileAndVerifyRoundTrip("fn add(a:f32,b:f32)->f32{return a+b;}");
}

test "round-trip: attributes" {
    try compileAndVerifyRoundTrip("@compute @workgroup_size(1) fn main(){}");
}

test "round-trip: if-else chain" {
    try compileAndVerifyRoundTrip("fn f(x:i32){if x>0{return;}else if x<0{return;}else{return;}}");
}

test "round-trip: for statement" {
    try compileAndVerifyRoundTrip("fn f(){for(var i=0;i<10;i=i+1){}}");
}

test "round-trip: switch statement" {
    try compileAndVerifyRoundTrip("fn f(x:i32){switch x{case 1:{} default:{}}}");
}

test "round-trip: uniform var with binding" {
    try compileAndVerifyRoundTrip("@group(0) @binding(0) var<uniform> u:f32;@compute @workgroup_size(1) fn main(){let x=u;}");
}

test "round-trip: complex shader" {
    try compileAndVerifyRoundTrip(
        \\struct Uniforms{time:f32,resolution:vec2f}
        \\@group(0) @binding(0) var<uniform> u:Uniforms;
        \\fn sdf(p:vec3f)->f32{return length(p)-1.0;}
        \\@fragment fn main(@builtin(position) pos:vec4f)->@location(0) vec4f{
        \\  var uv=(pos.xy/u.resolution)*2.0-1.0;
        \\  let d=sdf(vec3f(uv,0.0));
        \\  return vec4f(vec3f(d),1.0);
        \\}
    );
}
