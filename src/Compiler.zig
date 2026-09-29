//! WGSL-to-WASM binary shader compiler.
//!
//! Compiles a WGSL shader into a compact `.wasm` binary that regenerates
//! the WGSL string at runtime. Uses BPE (byte-pair encoding) for compression
//! with a ~110-byte WASM decoder. All WGSL knowledge lives in Zig at compile
//! time; the generated WASM has zero knowledge of WGSL syntax.
//!
//! Invariants:
//!   - The BPE rule table is bounded at 64 entries (encoded as 2 bytes
//!     each: the byte pair the rule replaces). Beyond that the compressor
//!     stops finding new pairs and emits the remainder uncompressed.
//!   - The generated WASM exports `memory` and `generate() → i32`. Callers
//!     read `output_len` bytes from offset 0 of `memory` after `generate`
//!     returns; that contract is what `packages/js-npm` and the runtime
//!     test harness drive.
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
const Pipeline = @import("Pipeline.zig");
const RenamePolicy = @import("RenamePolicy.zig");
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
    /// Empty (`len == 0`) when `errors` is non-empty — a syntax error yields
    /// diagnostics, not a binary.
    wasm: []const u8,
    original_size: usize,
    wasm_size: usize,
    /// Parse/syntax diagnostics. Non-empty ⇒ compilation produced no wasm.
    /// Mirrors `Minifier.Result.errors`: the artifact surfaces failures as
    /// data on the result, not as `error.OutOfMemory`. Real OOM still
    /// propagates through the `!CompileResult` error union.
    errors: []const Parser.ParseError = &.{},
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
pub fn compile(gpa: Allocator, source: [:0]const u8, options: CompileOptions) !CompileResult {
    // Pre: source size must fit the u32 offsets used by every BPE / WASM
    // memory-layout calculation downstream.
    std.debug.assert(source.len < std.math.maxInt(u32));

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var result = try compileInner(alloc, source, options);

    // Post: a successful compile (no diagnostics) always carries the 8-byte
    // magic + version header (`\0asm\x01\x00\x00\x00`). A shorter slice means
    // assembly aborted mid-stream without surfacing an error. When `errors` is
    // non-empty the shader never reached codegen, so `wasm` is deliberately
    // empty and the header assert does not apply.
    if (result.errors.len == 0) {
        std.debug.assert(result.wasm.len >= 8);
        std.debug.assert(std.mem.eql(u8, result.wasm[0..4], "\x00asm"));
    }

    result._arena = arena;
    return result;
}

fn compileInner(arena: Allocator, source: [:0]const u8, options: CompileOptions) !CompileResult {
    const original_size = source.len;

    // 1. Parse
    var tokens = try Lexer.tokenize(arena, source);
    defer tokens.deinit(arena);

    var parser = try Parser.init(arena, source, tokens);
    // A recoverable syntax error is data, not a failure: surface the collected
    // diagnostics on the result with an empty binary. Only a real OOM
    // propagates. (ParseFailed is a catastrophic abort that always records a
    // diagnostic first — mirror Minifier's `errors.len > 0 or module == null`.)
    const maybe_module = parser.parse() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseFailed => null,
    };
    if (maybe_module == null or parser.errors.items.len > 0) {
        return .{
            .wasm = &.{},
            .original_size = original_size,
            .wasm_size = 0,
            .errors = try arena.dupe(Parser.ParseError, parser.errors.items),
        };
    }
    const module = maybe_module.?;

    // 2-5. Prepare the renamer, scope-localize, sort, and print the sorted
    //      minified text (the exact bytes the BPE stage compresses).
    const minified = try minifiedText(arena, source, module, options);

    // 6. BPE compress
    var bpe = try BpeEncoder.compress(arena, minified);

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
    var vm_body: std.ArrayList(u8) = .empty;
    try BpeVmGen.generate(&vm_body, arena, .{
        .data_start = data_start,
        .data_end = data_end,
        .rules_base = rules_base,
        .stack_base = stack_base,
    });

    // 9. Build code section
    var code_section: std.ArrayList(u8) = .empty;
    try WasmBinary.writeUleb128(&code_section, arena, 1);
    try WasmBinary.writeUleb128(&code_section, arena, @intCast(vm_body.items.len));
    try code_section.appendSlice(arena, vm_body.items);

    // 10. Assemble WASM module
    const total_size = data_end;
    const min_pages = @max(1, (total_size + 65535) / 65536);

    const wasm = try WasmBinary.writeModule(
        arena,
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

/// Steps 2-5 of `compileInner`: build the global frequency renamer, wrap it
/// scope-local (params/locals → a,b,c,… per function), sort declarations, and
/// print the sorted minified text. Returns the exact bytes the BPE stage
/// compresses — the text the generated wasm's `generate()` decodes back at
/// runtime. There is no in-tree `decodeBpe(compress(text))` pin for this
/// text (the decoder has fixed-input unit tests; the npm suite's decoded-text
/// assertion executes the generated module end to end), so a test that proves
/// `minifiedText` correct proves the decoded wasm correct without a wasm
/// runtime.
pub fn minifiedText(arena: Allocator, source: [:0]const u8, module: *Ast.Module, options: CompileOptions) ![]const u8 {
    // Global frequency-based renamer + the rename policy the scope-local
    // wrapper consults to skip pinned symbols.
    const prep = try prepareRenamer(arena, source, module, options);

    // Scope-local renaming: within each function, reassign params/locals to
    // a,b,c,… so structurally similar functions produce identical text.
    const scope_renamer = try ScopeLocalRenamer.init(arena, module, prep.renamer, prep.policy, &prep.reserved);
    const renamer = &scope_renamer.ren;

    // Sort declarations by kind + size (already filters to live decls).
    const sorted_decls = try Minifier.sortDeclarations(arena, module);

    var printer = Printer.init(arena, .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .tree_shaking = false, // already filtered by sortDeclarations
        .renamer = renamer,
    }, module.symbols.items);
    defer printer.deinit();

    printer.buf.clearRetainingCapacity();
    try printer.printDecls(sorted_decls, null);
    // Own the bytes past the printer's arena-backed buffer (BPE reads them
    // after `printer` is deinit'd at scope exit).
    return arena.dupe(u8, printer.buf.items);
}

/// Round `value` up to the next multiple of `alignment` (must be power of 2).
fn alignUp(value: u32, alignment: u32) u32 {
    return (value + alignment - 1) & ~(alignment - 1);
}

const RenamerPrep = struct {
    renamer: *const Printer.Renamer,
    /// Per-pipeline rename-protection table. The scope-local wrapper
    /// consults it to skip pinned symbols (entry points, builtins,
    /// external bindings, keep-names) when assigning canonical names.
    policy: *const RenamePolicy,
    /// Set by `build_reserved_names`: keywords, builtins and `keep_names`.
    /// The wrapper reserves every name in it before handing out canonical
    /// names.
    reserved: std.StringHashMapUnmanaged(void),
};

/// Set up the global frequency-based renamer via the shared Pipeline.
/// Runs `mark_api_facing → dce → compute_usage → build_reserved_names →
/// build_renamer` over the parsed module; the caller wraps the resulting
/// base renamer with `ScopeLocalRenamer` (Compiler always wants
/// scope-local names for compression).
///
/// Non-minify mode (`options.minify == false`) feeds the pipeline a
/// minimal options struct that disables tree-shaking and identifier
/// renaming, mirroring the original "all-live + NoOpRenamer + empty
/// policy" behavior. The policy is non-empty (it still marks entry
/// points/builtins) but those marks affect only top-level symbols, which
/// `ScopeLocalRenamer` never touches.
fn prepareRenamer(arena: Allocator, source: [:0]const u8, module: *Ast.Module, options: CompileOptions) !RenamerPrep {
    var effective = if (options.minify) options.minify_options else Minifier.Options{
        .minify_identifiers = false,
        .tree_shaking = false,
    };
    // Compiler doesn't expose `preserve_uniform_struct_types`; force off
    // so behavior matches the pre-refactor Compiler-specific marking set.
    effective.preserve_uniform_struct_types = false;

    var state = Pipeline.State.initWithModule(arena, source, module);
    try Pipeline.run(&state, &.{
        .mark_api_facing,
        .dce,
        .compute_usage,
        .build_reserved_names,
        .build_renamer,
    }, effective);

    return .{ .renamer = state.renamer.?, .policy = state.rename_policy.?, .reserved = state.reserved.? };
}

// =========================================================================
// String Table — lazily built during op emission
// =========================================================================

const StringTable = struct {
    map: std.StringHashMapUnmanaged(u8),
    strings: std.ArrayList([]const u8),
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
    names: std.ArrayList([]const u8),
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
    ops: std.ArrayList(u8),
    str_table: StringTable,
    sym_table: SymbolTable,
    alloc: Allocator,
    module: *const Ast.Module,
    renamer: *const Printer.Renamer,
    needs_space: bool,
    output_size: u32,

    fn init(arena: Allocator, module: *const Ast.Module, renamer: *const Printer.Renamer) OpEmitter {
        return .{
            .ops = .empty,
            .str_table = StringTable.init(),
            .sym_table = SymbolTable.init(),
            .alloc = arena,
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
            if (Dce.isDeclarationLive(decl, self.module.liveness)) {
                try self.emitDecl(decl);
            }
        }
    }

    fn emitDirective(self: *OpEmitter, d: Ast.Directive) !void {
        switch (d) {
            .enable => |dir| {
                try self.emitStr("enable ");
                for (dir.features.items, 0..) |feat, i| {
                    if (i > 0) {
                        try self.emitByte(',');
                        try self.emitSpace();
                    }
                    try self.emitStr(feat);
                }
                try self.emitByte(';');
            },
            .requires => |dir| {
                try self.emitStr("requires ");
                for (dir.features.items, 0..) |feat, i| {
                    if (i > 0) {
                        try self.emitByte(',');
                        try self.emitSpace();
                    }
                    try self.emitStr(feat);
                }
                try self.emitByte(';');
            },
            .diagnostic => |dir| {
                try self.emitStr("diagnostic(");
                try self.emitStr(dir.severity);
                try self.emitByte(',');
                try self.emitSpace();
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
                if (decl.typ) |t| {
                    try self.emitByte(':');
                    try self.emitSpace();
                    try self.emitType(t);
                }
                try self.emitSpace();
                try self.emitByte('=');
                try self.emitSpace();
                if (decl.initializer) |init_expr| try self.emitExpr(init_expr);
                try self.emitByte(';');
            },
            .override => |decl| {
                try self.emitAttributes(decl.attributes.items);
                try self.emitStr("override ");
                try self.emitName(decl.name);
                if (decl.typ) |t| {
                    try self.emitByte(':');
                    try self.emitSpace();
                    try self.emitType(t);
                }
                if (decl.initializer) |init_expr| {
                    try self.emitSpace();
                    try self.emitByte('=');
                    try self.emitSpace();
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
                        try self.emitByte(',');
                        try self.emitSpace();
                        try self.emitStr(decl.access_mode.string());
                    }
                    try self.emitByte('>');
                }
                try self.emitByte(' ');
                try self.emitName(decl.name);
                if (decl.typ) |t| {
                    try self.emitByte(':');
                    try self.emitSpace();
                    try self.emitType(t);
                }
                if (decl.initializer) |init_expr| {
                    try self.emitSpace();
                    try self.emitByte('=');
                    try self.emitSpace();
                    try self.emitExpr(init_expr);
                }
                try self.emitByte(';');
            },
            .let => |decl| {
                try self.emitStr("let ");
                try self.emitName(decl.name);
                if (decl.typ) |t| {
                    try self.emitByte(':');
                    try self.emitSpace();
                    try self.emitType(t);
                }
                try self.emitSpace();
                try self.emitByte('=');
                try self.emitSpace();
                if (decl.initializer) |init_expr| try self.emitExpr(init_expr);
                try self.emitByte(';');
            },
            .function => |decl| {
                try self.emitAttributes(decl.attributes.items);
                try self.emitStr("fn ");
                try self.emitName(decl.name);
                try self.emitByte('(');
                for (decl.parameters.items, 0..) |param, i| {
                    if (i > 0) {
                        try self.emitByte(',');
                        try self.emitSpace();
                    }
                    try self.emitAttributes(param.attributes.items);
                    try self.emitName(param.name);
                    try self.emitByte(':');
                    try self.emitSpace();
                    try self.emitType(param.typ);
                }
                try self.emitByte(')');
                if (decl.return_type) |rt| {
                    try self.emitSpace();
                    try self.emitStr("->");
                    try self.emitSpace();
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
                    try self.emitByte(':');
                    try self.emitSpace();
                    try self.emitType(member.typ);
                    if (i < decl.members.items.len - 1) try self.emitByte(',');
                }
                try self.emitByte('}');
            },
            .alias => |decl| {
                try self.emitStr("alias ");
                try self.emitName(decl.name);
                try self.emitSpace();
                try self.emitByte('=');
                try self.emitSpace();
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
                    if (i > 0) {
                        try self.emitByte(',');
                        try self.emitSpace();
                    }
                    try self.emitExpr(arg);
                }
                try self.emitByte(')');
            }
            self.needs_space = true;
            try self.emitSpace();
        }
    }

    // -- Types --

    /// Iteratively emits a type, following single-child chains.
    /// Type nesting in WGSL is shallow (max 3-4 levels), and each iteration
    /// processes at most one child, so this loop is bounded.
    fn emitType(self: *OpEmitter, t: Ast.Type) Allocator.Error!void {
        // Track pending closing tokens for nested generics (e.g. ptr<storage, array<f32>>)
        var close_stack: [16]struct { close: u8, needs_space: bool, access: ?[]const u8 } = undefined;
        var close_top: usize = 0;
        var current = t;

        for (0..32) |_| {
            switch (current) {
                .ident => |typ| {
                    if (typ.ref.isValid()) {
                        try self.emitName(typ.ref);
                    } else {
                        try self.emitStr(typ.name);
                    }
                    break;
                },
                .vec => |typ| {
                    if (typ.shorthand.len > 0) {
                        try self.emitStr(typ.shorthand);
                        break;
                    }
                    try self.emitStr("vec");
                    try self.emitByte('0' + typ.size);
                    try self.emitByte('<');
                    if (close_top < close_stack.len) {
                        close_stack[close_top] = .{ .close = '>', .needs_space = true, .access = null };
                        close_top += 1;
                    }
                    current = typ.elem_type orelse break;
                },
                .mat => |typ| {
                    if (typ.shorthand.len > 0) {
                        try self.emitStr(typ.shorthand);
                        break;
                    }
                    try self.emitStr("mat");
                    try self.emitByte('0' + typ.cols);
                    try self.emitByte('x');
                    try self.emitByte('0' + typ.rows);
                    try self.emitByte('<');
                    if (close_top < close_stack.len) {
                        close_stack[close_top] = .{ .close = '>', .needs_space = true, .access = null };
                        close_top += 1;
                    }
                    current = typ.elem_type orelse break;
                },
                .array => |typ| {
                    try self.emitStr("array<");
                    if (typ.elem_type) |et| {
                        // Handle array size after element type
                        if (typ.size) |s| {
                            // Need to emit elem_type first, then ",size>"
                            // Since we can only follow one child, emit elem type in the loop
                            // and handle the rest in close_stack... but close_stack doesn't support expr.
                            // Fallback: emit the rest inline since depth is shallow.
                            try self.emitType(et); // bounded: types are max 3-4 deep
                            try self.emitByte(',');
                            try self.emitSpace();
                            try self.emitExpr(s);
                        } else {
                            try self.emitType(et);
                        }
                    }
                    try self.emitByte('>');
                    self.needs_space = true;
                    break;
                },
                .ptr => |typ| {
                    try self.emitStr("ptr<");
                    try self.emitStr(typ.address_space.string());
                    try self.emitByte(',');
                    try self.emitSpace();
                    if (close_top < close_stack.len) {
                        close_stack[close_top] = .{ .close = '>', .needs_space = true, .access = if (typ.access_mode != .none) typ.access_mode.string() else null };
                        close_top += 1;
                    }
                    current = typ.elem_type;
                },
                .atomic => |typ| {
                    try self.emitStr("atomic<");
                    if (close_top < close_stack.len) {
                        close_stack[close_top] = .{ .close = '>', .needs_space = true, .access = null };
                        close_top += 1;
                    }
                    current = typ.elem_type;
                },
                .sampler => |typ| {
                    if (typ.comparison) {
                        try self.emitStr("sampler_comparison");
                    } else {
                        try self.emitStr("sampler");
                    }
                    break;
                },
                .texture => |typ| {
                    try self.emitTextureType(typ);
                    break;
                },
            }
        } else unreachable;
        // Emit closing tokens in reverse
        while (close_top > 0) {
            close_top -= 1;
            const entry = close_stack[close_top];
            if (entry.access) |acc| {
                try self.emitByte(',');
                try self.emitSpace();
                try self.emitStr(acc);
            }
            try self.emitByte(entry.close);
            if (entry.needs_space) self.needs_space = true;
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
            try self.emitByte(',');
            try self.emitSpace();
            try self.emitStr(t.access_mode.string());
            try self.emitByte('>');
            self.needs_space = true;
        }
    }

    // -- Expressions --

    /// Iteratively emits an expression tree using a reverse-push work item stack.
    fn emitExpr(self: *OpEmitter, e: Ast.Expr) Allocator.Error!void {
        const EmitWork = union(enum) {
            expr: Ast.Expr,
            str: []const u8,
            byte: u8,
            space,
            emit_type: Ast.Type,
        };

        var stack: std.ArrayList(EmitWork) = .empty;
        defer stack.deinit(self.alloc);
        try stack.append(self.alloc, .{ .expr = e });

        for (0..65536) |_| {
            const work = stack.pop() orelse break;
            switch (work) {
                .str => |s| try self.emitStr(s),
                .byte => |b| try self.emitByte(b),
                .space => try self.emitSpace(),
                .emit_type => |t| try self.emitType(t),
                .expr => |ex| switch (ex) {
                    .ident => |expr| {
                        if (expr.ref.isValid()) {
                            try self.emitName(expr.ref);
                        } else {
                            try self.emitStr(expr.name);
                        }
                    },
                    .literal => |expr| try self.emitStr(expr.value),
                    .binary => |expr| {
                        try stack.append(self.alloc, .{ .expr = expr.right });
                        try stack.append(self.alloc, .space);
                        try stack.append(self.alloc, .{ .str = expr.op.string() });
                        try stack.append(self.alloc, .space);
                        try stack.append(self.alloc, .{ .expr = expr.left });
                    },
                    .unary => |expr| {
                        try stack.append(self.alloc, .{ .expr = expr.operand });
                        try stack.append(self.alloc, .{ .str = expr.op.string() });
                    },
                    .call => |expr| {
                        try stack.append(self.alloc, .{ .byte = ')' });
                        var i = expr.args.items.len;
                        while (i > 0) {
                            i -= 1;
                            try stack.append(self.alloc, .{ .expr = expr.args.items[i] });
                            if (i > 0) {
                                try stack.append(self.alloc, .space);
                                try stack.append(self.alloc, .{ .byte = ',' });
                            }
                        }
                        try stack.append(self.alloc, .{ .byte = '(' });
                        if (expr.template_type) |tt| {
                            try stack.append(self.alloc, .{ .emit_type = tt });
                        } else if (expr.func) |f| {
                            try stack.append(self.alloc, .{ .expr = f });
                        }
                    },
                    .index => |expr| {
                        try stack.append(self.alloc, .{ .byte = ']' });
                        try stack.append(self.alloc, .{ .expr = expr.idx });
                        try stack.append(self.alloc, .{ .byte = '[' });
                        try stack.append(self.alloc, .{ .expr = expr.base });
                    },
                    .member => |expr| {
                        try stack.append(self.alloc, .{ .str = expr.member_name });
                        try stack.append(self.alloc, .{ .byte = '.' });
                        try stack.append(self.alloc, .{ .expr = expr.base });
                    },
                    .paren => |expr| {
                        try stack.append(self.alloc, .{ .byte = ')' });
                        try stack.append(self.alloc, .{ .expr = expr.expr });
                        try stack.append(self.alloc, .{ .byte = '(' });
                    },
                },
            }
        } else unreachable;
    }

    // -- Statements --

    fn emitCompoundStmt(self: *OpEmitter, stmt: *const Ast.CompoundStmt) Allocator.Error!void {
        try self.emitByte('{');
        for (stmt.stmts.items) |s| {
            try self.emitStmt(s);
        }
        try self.emitByte('}');
    }

    /// Iteratively emits a statement tree using a work item stack.
    fn emitStmt(self: *OpEmitter, root: Ast.Stmt) Allocator.Error!void {
        const StmtEmitWork = union(enum) {
            stmt: Ast.Stmt,
            compound: *const Ast.CompoundStmt,
            else_chain: Ast.Stmt,
            continuing: *const Ast.CompoundStmt,
            close_brace,
        };

        var stack: std.ArrayList(StmtEmitWork) = .empty;
        defer stack.deinit(self.alloc);
        try stack.append(self.alloc, .{ .stmt = root });

        for (0..65536) |_| {
            const work = stack.pop() orelse break;
            switch (work) {
                .compound => |body| {
                    try self.emitByte('{');
                    // Push close_brace first (bottom = processed last), then stmts in reverse
                    try stack.append(self.alloc, .close_brace);
                    var ci = body.stmts.items.len;
                    while (ci > 0) {
                        ci -= 1;
                        try stack.append(self.alloc, .{ .stmt = body.stmts.items[ci] });
                    }
                },
                .close_brace => {
                    try self.emitByte('}');
                },
                .else_chain => |ec| {
                    const s = ec;
                    if (s == .@"if") {
                        const if_stmt = s.@"if";
                        try self.emitStr(" else if ");
                        try self.emitExpr(if_stmt.condition);
                        try self.emitSpace();
                        if (if_stmt.else_branch) |eb| try stack.append(self.alloc, .{ .else_chain = eb });
                        try stack.append(self.alloc, .{ .compound = if_stmt.body });
                    } else {
                        try self.emitStr(" else");
                        try self.emitSpace();
                        try stack.append(self.alloc, .{ .stmt = s });
                    }
                },
                .continuing => |c| {
                    try self.emitStr(" continuing");
                    try self.emitSpace();
                    try stack.append(self.alloc, .{ .compound = c });
                },
                .stmt => |s| switch (s) {
                    .compound => |stmt| try stack.append(self.alloc, .{ .compound = stmt }),
                    .@"return" => |stmt| {
                        try self.emitStr("return");
                        if (stmt.value) |v| {
                            try self.emitByte(' ');
                            try self.emitExpr(v);
                        }
                        try self.emitByte(';');
                    },
                    .@"if" => |stmt| {
                        try self.emitStr("if ");
                        try self.emitExpr(stmt.condition);
                        try self.emitSpace();
                        if (stmt.else_branch) |eb| try stack.append(self.alloc, .{ .else_chain = eb });
                        try stack.append(self.alloc, .{ .compound = stmt.body });
                    },
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
                                    if (i > 0) {
                                        try self.emitByte(',');
                                        try self.emitSpace();
                                    }
                                    try self.emitExpr(sel);
                                }
                                if (c.has_default) {
                                    // `case 1, default:` — default mixed with selectors.
                                    try self.emitByte(',');
                                    try self.emitSpace();
                                    try self.emitStr("default");
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
                        try stack.append(self.alloc, .{ .compound = stmt.body });
                    },
                    .loop => |stmt| {
                        try self.emitStr("loop");
                        try self.emitSpace();
                        if (stmt.continuing) |c| try stack.append(self.alloc, .{ .continuing = c });
                        try stack.append(self.alloc, .{ .compound = stmt.body });
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
                        try self.emitSpace();
                        try self.emitStr(stmt.op.string());
                        try self.emitSpace();
                        try self.emitExpr(stmt.right);
                        try self.emitByte(';');
                    },
                    .phony => |stmt| {
                        try self.emitStr("_");
                        try self.emitSpace();
                        try self.emitStr("=");
                        try self.emitSpace();
                        try self.emitExpr(stmt.expr);
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
                },
            }
        } else unreachable;
    }

    /// Iteratively emits an else/else-if chain.
    fn emitElseChain(self: *OpEmitter, s_init: Ast.Stmt) Allocator.Error!void {
        var s = s_init;
        for (0..65536) |_| {
            if (s == .@"if") {
                const if_stmt = s.@"if";
                try self.emitStr(" else if ");
                try self.emitExpr(if_stmt.condition);
                try self.emitSpace();
                try self.emitCompoundStmt(if_stmt.body);
                s = if_stmt.else_branch orelse break;
            } else {
                try self.emitStr(" else");
                try self.emitSpace();
                try self.emitStmt(s);
                break;
            }
        } else unreachable;
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
                        if (decl.typ) |t| {
                            try self.emitByte(':');
                            try self.emitSpace();
                            try self.emitType(t);
                        }
                        if (decl.initializer) |init_expr| {
                            try self.emitSpace();
                            try self.emitByte('=');
                            try self.emitSpace();
                            try self.emitExpr(init_expr);
                        }
                    },
                    .let => |decl| {
                        try self.emitStr("let ");
                        try self.emitName(decl.name);
                        if (decl.typ) |t| {
                            try self.emitByte(':');
                            try self.emitSpace();
                            try self.emitType(t);
                        }
                        try self.emitSpace();
                        try self.emitByte('=');
                        try self.emitSpace();
                        if (decl.initializer) |init_expr| try self.emitExpr(init_expr);
                    },
                    else => {},
                }
            },
            .assign => |stmt| {
                try self.emitExpr(stmt.left);
                try self.emitSpace();
                try self.emitStr(stmt.op.string());
                try self.emitSpace();
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
                try self.emitSpace();
                try self.emitStr(stmt.op.string());
                try self.emitSpace();
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
                if (decl.typ) |t| {
                    try self.emitByte(':');
                    try self.emitSpace();
                    try self.emitType(t);
                }
                try self.emitSpace();
                try self.emitByte('=');
                try self.emitSpace();
                if (decl.initializer) |init_expr| try self.emitExpr(init_expr);
                try self.emitByte(';');
            },
            .let => |decl| {
                try self.emitStr("let ");
                try self.emitName(decl.name);
                if (decl.typ) |t| {
                    try self.emitByte(':');
                    try self.emitSpace();
                    try self.emitType(t);
                }
                try self.emitSpace();
                try self.emitByte('=');
                try self.emitSpace();
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
                        try self.emitByte(',');
                        try self.emitSpace();
                        try self.emitStr(decl.access_mode.string());
                    }
                    try self.emitByte('>');
                }
                try self.emitByte(' ');
                try self.emitName(decl.name);
                if (decl.typ) |t| {
                    try self.emitByte(':');
                    try self.emitSpace();
                    try self.emitType(t);
                }
                if (decl.initializer) |init_expr| {
                    try self.emitSpace();
                    try self.emitByte('=');
                    try self.emitSpace();
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
    fn generate(body: *std.ArrayList(u8), alloc: Allocator, layout: Layout) !void {
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
            try emitRefLookup(e, @intCast(layout.str_offsets_base), @intCast(layout.str_lens_base));
            try emitCopyLoop(e);
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
            try emitRefLookup(e, @intCast(layout.sym_offsets_base), @intCast(layout.sym_lens_base));
            try emitCopyLoop(e);
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

    /// Emit WASM instructions to look up src (local 5) and len (local 4)
    /// from offset/length tables using idx (local 3).
    fn emitRefLookup(e: WasmBinary.Emit, offsets_base: u32, lens_base: u32) !void {
        // src = offsets[idx] (u16 LE)
        try e.local_get(3);
        try e.i32_const(2);
        try e.i32_mul();
        try e.i32_const(offsets_base);
        try e.i32_add();
        try e.i32_load16_u();
        try e.local_set(5);
        // len = lens[idx]
        try e.local_get(3);
        try e.i32_const(lens_base);
        try e.i32_add();
        try e.i32_load8_u();
        try e.local_set(4);
    }

    /// Emit WASM instructions for the copy loop: copies len bytes from src to
    /// output[wp]. Uses locals 1 (wp), 4 (len), 5 (src). Branch depths are
    /// self-contained within the emitted block/loop structure.
    fn emitCopyLoop(e: WasmBinary.Emit) !void {
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
        try e.end(); // end loop
        try e.end(); // end block
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
    var out: std.ArrayList(u8) = .empty;
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
    fn compress(arena: Allocator, input: []const u8) !BpeEncoder {
        var result: BpeEncoder = .{ .rules = undefined, .num_rules = 0, .data = input };
        if (input.len < 2) return result;

        var buf = try arena.alloc(u8, input.len);
        @memcpy(buf, input);
        var len = input.len;

        // Heap-allocated pair frequency table (256*256*4 = 256KB, too large for stack)
        const counts = try arena.alloc(u32, 256 * 256);

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
        std.debug.assert(data.len >= 2);
        std.debug.assert(counts.len == 256 * 256);
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
        std.debug.assert(len <= buf.len);
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
    fn generate(body: *std.ArrayList(u8), alloc: Allocator, layout: Layout) !void {
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
fn decodeBpe(arena: Allocator, data: []const u8, rules: []const [2]u8) ![]const u8 {
    std.debug.assert(rules.len <= BpeEncoder.MAX_RULES);
    var out: std.ArrayList(u8) = .empty;
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
            try out.append(arena, byte);
        } else {
            const idx = byte - 0x80;
            if (idx < rules.len) {
                std.debug.assert(sp + 2 <= stack.len);
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
    const module = try parser.parse();
    // Reported as OutOfMemory until now, which named the wrong cause: these
    // fixtures are valid WGSL, so a populated error list means the fixture is
    // broken, not that the allocator gave out.
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);

    // Prepare renamer (same as compile path)
    const prep = try prepareRenamer(alloc, source, module, .{});

    // Text printer (minified)
    var printer = Printer.init(alloc, .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .tree_shaking = true,
        .renamer = prep.renamer,
    }, module.symbols.items);
    defer printer.deinit();
    const expected = try printer.print(module);

    // Op emitter
    var emitter = OpEmitter.init(alloc, module, prep.renamer);
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

test "pin: compiler sorted text == Minifier.minify sorted output (shared print loop)" {
    // Both the compiler's sorted print and the public minifier's
    // sort_declarations branch drive the *same* clear/print loop over sorted
    // decls. This pins them byte-for-byte so the upcoming `Printer.printDecls`
    // unification can't silently drift one path from the other. No external
    // bindings (their alias/mangle handling differs between the paths) and
    // `minify_syntax = false` to match the compiler printer's config.
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source: [:0]const u8 =
        \\fn helper(x: f32) -> f32 { return x * 2.0; }
        \\fn secondary(a: f32, b: f32) -> f32 { return a + b; }
        \\@compute @workgroup_size(1) fn main() {
        \\  let y = secondary(helper(1.0), 2.0);
        \\}
    ;

    // Path A — public minifier, sorted branch (Pipeline.runPrint).
    const mr = try Minifier.minify(alloc, source, .{
        .minify_syntax = false,
        .sort_declarations = true,
        .scope_local_rename = true,
    });

    // Path B — compiler's sorted print (minifiedText → printDecls).
    const tokens = try Lexer.tokenize(alloc, source);
    var parser = try Parser.init(alloc, source, tokens);
    const module = parser.parse() catch return error.OutOfMemory;
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    const text_b = try minifiedText(alloc, source, module, .{});

    try std.testing.expectEqualStrings(mr.code, text_b);
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

test "decodeBpe: no rules, passthrough" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const result = try decodeBpe(arena.allocator(), "hello", &.{});
    try std.testing.expectEqualStrings("hello", result);
}

test "decodeBpe: single rule expansion" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    // Rule 0: byte 0x80 expands to 'A', 'B'
    const rules = [_][2]u8{.{ 'A', 'B' }};
    // Input: 0x80 should decode to "AB"
    const result = try decodeBpe(arena.allocator(), &.{0x80}, &rules);
    try std.testing.expectEqualStrings("AB", result);
}

test "decodeBpe: chained rules" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    // Rule 0 (0x80): 'x', 'y'  -> expands to "xy"
    // Rule 1 (0x81): 0x80, 'z' -> expands to "xyz"
    const rules = [_][2]u8{ .{ 'x', 'y' }, .{ 0x80, 'z' } };
    const result = try decodeBpe(arena.allocator(), &.{0x81}, &rules);
    try std.testing.expectEqualStrings("xyz", result);
}

test "decodeBpe: mixed literal and rule bytes" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    // Rule 0 (0x80): 'l', 'l'
    const rules = [_][2]u8{.{ 'l', 'l' }};
    // "he" + rule0 + "o" -> "hello"
    const result = try decodeBpe(arena.allocator(), &.{ 'h', 'e', 0x80, 'o' }, &rules);
    try std.testing.expectEqualStrings("hello", result);
}

test "decodeBpe: deeply chained rules stay within stack bounds" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    // Build a chain of 64 rules where each rule references the previous.
    // Rule 0: 'a', 'b'
    // Rule 1: 0x80, 'c'  -> "abc"
    // Rule 2: 0x81, 'd'  -> "abcd"
    // ...
    // Rule 63: 0xBE, char -> "ab...z..."
    var rules: [64][2]u8 = undefined;
    rules[0] = .{ 'a', 'b' };
    for (1..64) |i| {
        const char_offset: u8 = @intCast(@min(i - 1, 20));
        rules[i] = .{ @as(u8, 0x80) + @as(u8, @intCast(i - 1)), 'c' + char_offset };
    }

    // Decode the last rule — triggers maximum chain depth.
    // The assertion (sp + 2 <= 512) must hold throughout.
    const result = try decodeBpe(arena.allocator(), &.{0xBF}, &rules);
    try std.testing.expect(result.len == 65); // 2 + 63 expansion chars
}

test "decodeBpe: empty input" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const result = try decodeBpe(arena.allocator(), &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "decodeBpe: rule index out of range is ignored" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    // Only 1 rule, but input byte 0x81 references rule index 1 (out of range).
    const rules = [_][2]u8{.{ 'A', 'B' }};
    const result = try decodeBpe(arena.allocator(), &.{ 'x', 0x81, 'y' }, &rules);
    // 0x81 is silently skipped (idx >= rules.len), so only "xy".
    try std.testing.expectEqualStrings("xy", result);
}
