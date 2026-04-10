//! WGSL minification pipeline.
//!
//! Orchestrates: Parse → Mark API-facing → DCE → Compute usage → Rename
//!             → [Scope-local rename] → [Sort declarations] → Print.
//!
//! The optional scope-local rename and declaration sort passes improve
//! DEFLATE compression by making structurally similar functions produce
//! near-identical text and grouping declarations by kind.

const std = @import("std");
const Ast = @import("Ast.zig");
const Lexer = @import("Lexer.zig");
const Parser = @import("Parser.zig");
const Printer = @import("Printer.zig");
const RenamerMod = @import("Renamer.zig");
const Dce = @import("Dce.zig");
const SourceMap = @import("SourceMap.zig");

const Reflect = @import("Reflect.zig");

const Minifier = @This();

pub const SourceMapOptions = struct {
    file: []const u8 = "",
    source_name: []const u8 = "",
    include_source: bool = false,
};

pub const Options = struct {
    minify_whitespace: bool = true,
    minify_identifiers: bool = true,
    minify_syntax: bool = true,
    mangle_external_bindings: bool = false,
    tree_shaking: bool = true,
    preserve_uniform_struct_types: bool = false,
    keep_names: []const []const u8 = &.{},
    generate_source_map: bool = false,
    source_map_options: SourceMapOptions = .{},
    /// Sort module-level declarations by kind (struct→alias→const→var→fn) then
    /// by size. Groups similar declarations together for better DEFLATE compression.
    /// Safe because WGSL module-level declarations have no text-order dependency.
    sort_declarations: bool = false,
    /// Within each function, rename parameters and locals to a canonical sequence
    /// (a, b, c, ...) restarting per function. Makes structurally similar functions
    /// produce near-identical text, improving DEFLATE compression.
    scope_local_rename: bool = false,
};

pub const Result = struct {
    code: []const u8,
    errors: []const Parser.ParseError,
    original_size: usize,
    minified_size: usize,
    symbols_total: usize,
    symbols_dead: u32,
    source_map: ?SourceMap.Result = null,
    /// Internal arena owning all allocated data. Call `deinit()` to free.
    /// Null when called directly (caller manages memory).
    _arena: ?std.heap.ArenaAllocator = null,

    /// Free all memory owned by this result. After calling deinit, all
    /// slices (code, errors, source_map) are invalid.
    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        _ = allocator;
        var arena = self._arena orelse return;
        arena.deinit();
        self._arena = null;
    }
};

/// Returns default minification options (all minification enabled).
pub fn defaultOptions() Options {
    return .{};
}

/// Minify WGSL source code. Returns the minified code and statistics.
/// The returned code is owned by the arena allocator.
pub fn minify(arena: std.mem.Allocator, source: [:0]const u8, options: Options) !Result {
    var result = Result{
        .code = "",
        .errors = &.{},
        .original_size = source.len,
        .minified_size = 0,
        .symbols_total = 0,
        .symbols_dead = 0,
    };

    // 1. Tokenize
    var tokens = try Lexer.tokenize(arena, source);
    defer tokens.deinit(arena);

    // 2. Parse
    var parser = try Parser.init(arena, source, tokens);
    const module = parser.parse() catch {
        result.code = source;
        result.minified_size = source.len;
        result.errors = parser.errors.items;
        return result;
    };

    if (parser.errors.items.len > 0) {
        result.code = source;
        result.minified_size = source.len;
        result.errors = parser.errors.items;
        return result;
    }

    // 3. Mark API-facing symbols
    markAPIFacingSymbols(module, options);

    // 4. DCE
    if (options.tree_shaking) {
        result.symbols_dead = try Dce.mark(arena, module);
        std.debug.assert(result.symbols_dead <= module.symbols.items.len);
    } else {
        for (module.symbols.items) |*sym| {
            sym.flags.is_live = true;
        }
    }

    // 5. Compute usage
    var uses = try computeSymbolUsage(arena, module);
    defer uses.deinit(arena);

    // 6. Build reserved names
    var reserved = try RenamerMod.computeReservedNames(arena);
    for (options.keep_names) |name| {
        try reserved.put(arena, name, {});
    }

    // 7. Set up source map generator if requested
    const source_map_gen = try initSourceMapGen(arena, source, options);

    // 8. Create renamer and print
    const print_result = try printWithRenamer(arena, module, options, &uses, reserved, source_map_gen);
    result.code = print_result.code;

    // 9. Finalize source map
    if (source_map_gen) |gen| {
        result.source_map = try gen.generate();
    }

    result.minified_size = result.code.len;
    result.symbols_total = module.symbols.items.len;
    return result;
}

pub const MinifyAndReflectResult = struct {
    minify: Result,
    reflect: Reflect.ReflectResult,
    _arena: ?std.heap.ArenaAllocator = null,

    pub fn deinit(self: *MinifyAndReflectResult, allocator: std.mem.Allocator) void {
        _ = allocator;
        var arena = self._arena orelse return;
        arena.deinit();
        self._arena = null;
    }
};

/// Minify and reflect in a single pass, sharing the parsed module and renamer.
/// Reflection uses the minified names so callers can map bindings to the
/// minified output.
pub fn minifyAndReflect(arena: std.mem.Allocator, source: [:0]const u8, options: Options) !MinifyAndReflectResult {
    var result = MinifyAndReflectResult{
        .minify = .{
            .code = "",
            .errors = &.{},
            .original_size = source.len,
            .minified_size = 0,
            .symbols_total = 0,
            .symbols_dead = 0,
        },
        .reflect = .{},
    };

    // 1. Tokenize
    var tokens = try Lexer.tokenize(arena, source);
    defer tokens.deinit(arena);

    // 2. Parse
    var parser = try Parser.init(arena, source, tokens);
    const module = parser.parse() catch {
        result.minify.code = source;
        result.minify.minified_size = source.len;
        result.minify.errors = parser.errors.items;
        for (parser.errors.items) |err| {
            try result.reflect.errors.append(arena, err.message);
        }
        return result;
    };

    if (parser.errors.items.len > 0) {
        result.minify.code = source;
        result.minify.minified_size = source.len;
        result.minify.errors = parser.errors.items;
        for (parser.errors.items) |err| {
            try result.reflect.errors.append(arena, err.message);
        }
        return result;
    }

    // 3–6. Mark API-facing, DCE, compute usage, build reserved names
    markAPIFacingSymbols(module, options);

    if (options.tree_shaking) {
        result.minify.symbols_dead = try Dce.mark(arena, module);
    } else {
        for (module.symbols.items) |*sym| {
            sym.flags.is_live = true;
        }
    }

    var uses = try computeSymbolUsage(arena, module);
    defer uses.deinit(arena);

    var reserved = try RenamerMod.computeReservedNames(arena);
    for (options.keep_names) |name| {
        try reserved.put(arena, name, {});
    }

    // 7. Source map
    const source_map_gen = try initSourceMapGen(arena, source, options);

    // 8. Create renamer and print
    const print_result = try printWithRenamer(arena, module, options, &uses, reserved, source_map_gen);
    result.minify.code = print_result.code;

    // 9. Finalize source map
    if (source_map_gen) |gen| {
        result.minify.source_map = try gen.generate();
    }

    result.minify.minified_size = result.minify.code.len;
    result.minify.symbols_total = module.symbols.items.len;

    // 10. Reflect using the same module and renamer
    result.reflect = try Reflect.reflectWithRenamer(arena, module, print_result.renamer);

    return result;
}

fn initSourceMapGen(arena: std.mem.Allocator, source: [:0]const u8, options: Options) !?*SourceMap.Generator {
    if (!options.generate_source_map) return null;
    const gen = try arena.create(SourceMap.Generator);
    gen.* = try SourceMap.Generator.init(arena, source);
    gen.setFile(options.source_map_options.file);
    gen.setSourceName(options.source_map_options.source_name);
    gen.setIncludeSource(options.source_map_options.include_source);
    return gen;
}

const PrintResult = struct {
    code: []const u8,
    renamer: *const Printer.Renamer,
};

fn createMinifyRenamer(
    arena: std.mem.Allocator,
    module: *Ast.Module,
    uses: *const std.AutoHashMapUnmanaged(Ast.SymbolIndex, u32),
    reserved: std.StringHashMapUnmanaged(void),
) !*const Printer.Renamer {
    const r = try arena.create(RenamerMod.MinifyRenamer);
    r.* = RenamerMod.MinifyRenamer.init(arena, module.symbols.items, reserved);
    r.accumulateSymbolUseCounts(uses);
    try r.allocateSlots();
    try r.reserveUnrenamedSymbolNames();
    try r.assignNames();
    r.renamer.ptr = @ptrCast(r);
    return &r.renamer;
}

fn createNoOpRenamer(arena: std.mem.Allocator, module: *Ast.Module) !*const Printer.Renamer {
    const r = try arena.create(RenamerMod.NoOpRenamer);
    r.* = RenamerMod.NoOpRenamer.init(module.symbols.items);
    r.renamer.ptr = @ptrCast(r);
    return &r.renamer;
}

fn printWithRenamer(
    arena: std.mem.Allocator,
    module: *Ast.Module,
    options: Options,
    uses: *const std.AutoHashMapUnmanaged(Ast.SymbolIndex, u32),
    reserved: std.StringHashMapUnmanaged(void),
    source_map_gen: ?*SourceMap.Generator,
) !PrintResult {
    // Build base renamer (frequency-based or no-op)
    const renamer_base = if (options.minify_identifiers)
        try createMinifyRenamer(arena, module, uses, reserved)
    else
        try createNoOpRenamer(arena, module);

    var renamer: *const Printer.Renamer = renamer_base;

    // Optionally wrap with scope-local renaming
    if (options.scope_local_rename and options.minify_identifiers) {
        const scope = try ScopeLocalRenamer.init(arena, module, renamer);
        renamer = &scope.ren;
    }

    // Print — either sorted or in original order
    var printer = Printer.init(arena, .{
        .minify_whitespace = options.minify_whitespace,
        .minify_identifiers = options.minify_identifiers,
        .minify_syntax = options.minify_syntax,
        .tree_shaking = if (options.sort_declarations) false else options.tree_shaking,
        .renamer = renamer,
        .source_map_gen = source_map_gen,
    }, module.symbols.items);

    if (options.sort_declarations) {
        const sorted = try sortDeclarations(arena, module);
        printer.buf.clearRetainingCapacity();
        for (sorted) |decl| {
            try printer.printDecl(decl);
        }
        return .{ .code = printer.buf.items, .renamer = renamer };
    }

    return .{ .code = try printer.print(module), .renamer = renamer };
}

fn markAPIFacingSymbols(module: *Ast.Module, options: Options) void {
    for (module.symbols.items) |*sym| {
        if (sym.flags.is_entry_point) sym.flags.must_not_be_renamed = true;
        if (sym.kind == .builtin) sym.flags.must_not_be_renamed = true;
        if (sym.kind == .override) sym.flags.must_not_be_renamed = true;
        if (sym.flags.is_external_binding and !options.mangle_external_bindings) {
            sym.flags.must_not_be_renamed = true;
        }
        // Check keep_names
        for (options.keep_names) |name| {
            if (std.mem.eql(u8, sym.original_name, name)) {
                sym.flags.must_not_be_renamed = true;
                break;
            }
        }
    }

    // Preserve uniform struct types
    if (options.preserve_uniform_struct_types) {
        for (module.declarations.items) |decl| {
            if (decl != .@"var") continue;
            const var_decl = decl.@"var";
            if (!var_decl.name.isValid()) continue;
            const sym = &module.symbols.items[var_decl.name.index()];
            if (!sym.flags.is_external_binding) continue;
            if (var_decl.typ) |typ| {
                if (typ == .ident) {
                    const ident_type = typ.ident;
                    if (ident_type.ref.isValid() and ident_type.ref.index() < module.symbols.items.len) {
                        module.symbols.items[ident_type.ref.index()].flags.must_not_be_renamed = true;
                    }
                }
            }
        }
    }
}

pub fn computeSymbolUsage(arena: std.mem.Allocator, module: *const Ast.Module) !std.AutoHashMapUnmanaged(Ast.SymbolIndex, u32) {
    var uses: std.AutoHashMapUnmanaged(Ast.SymbolIndex, u32) = .empty;
    for (module.declarations.items) |decl| {
        try countDeclUsage(arena, decl, &uses);
    }
    return uses;
}

fn countDeclUsage(arena: std.mem.Allocator, decl: Ast.Decl, uses: *std.AutoHashMapUnmanaged(Ast.SymbolIndex, u32)) std.mem.Allocator.Error!void {
    switch (decl) {
        .@"const" => |d| {
            if (d.initializer) |init_expr| try countExprUsage(arena, init_expr, uses);
        },
        .override => |d| {
            if (d.initializer) |init_expr| try countExprUsage(arena, init_expr, uses);
        },
        .@"var" => |d| {
            if (d.initializer) |init_expr| try countExprUsage(arena, init_expr, uses);
        },
        .let => |d| {
            if (d.initializer) |init_expr| try countExprUsage(arena, init_expr, uses);
        },
        .function => |d| {
            // Count function name itself
            if (d.name.isValid()) {
                const entry = try uses.getOrPutValue(arena, d.name, 0);
                entry.value_ptr.* += 1;
            }
            if (d.body) |body| try countStmtUsage(arena, .{ .compound = body }, uses);
        },
        .@"struct", .alias, .const_assert => {},
    }
}

/// Iteratively counts symbol usage in an expression tree using a worklist.
fn countExprUsage(arena: std.mem.Allocator, expr: Ast.Expr, uses: *std.AutoHashMapUnmanaged(Ast.SymbolIndex, u32)) std.mem.Allocator.Error!void {
    var stack: std.ArrayListUnmanaged(Ast.Expr) = .empty;
    defer stack.deinit(arena);
    try stack.append(arena, expr);

    for (0..65536) |_| {
        const e = stack.pop() orelse break;
        switch (e) {
            .ident => |ie| {
                if (ie.ref.isValid()) {
                    const entry = try uses.getOrPutValue(arena, ie.ref, 0);
                    entry.value_ptr.* += 1;
                }
            },
            .binary => |be| {
                try stack.append(arena, be.right);
                try stack.append(arena, be.left);
            },
            .unary => |ue| try stack.append(arena, ue.operand),
            .call => |ce| {
                var i = ce.args.items.len;
                while (i > 0) {
                    i -= 1;
                    try stack.append(arena, ce.args.items[i]);
                }
                if (ce.func) |f| try stack.append(arena, f);
            },
            .index => |ie| {
                try stack.append(arena, ie.idx);
                try stack.append(arena, ie.base);
            },
            .member => |me| try stack.append(arena, me.base),
            .paren => |pe| try stack.append(arena, pe.expr),
            .literal => {},
        }
    } else unreachable;
}

/// Iteratively counts symbol usage in a statement tree using a worklist.
fn countStmtUsage(arena: std.mem.Allocator, stmt: Ast.Stmt, uses: *std.AutoHashMapUnmanaged(Ast.SymbolIndex, u32)) std.mem.Allocator.Error!void {
    var stack: std.ArrayListUnmanaged(Ast.Stmt) = .empty;
    defer stack.deinit(arena);
    try stack.append(arena, stmt);

    for (0..65536) |_| {
        const s = stack.pop() orelse break;
        switch (s) {
            .compound => |cs| {
                for (cs.stmts.items) |inner| try stack.append(arena, inner);
            },
            .@"return" => |rs| {
                if (rs.value) |v| try countExprUsage(arena, v, uses);
            },
            .@"if" => |is| {
                try countExprUsage(arena, is.condition, uses);
                try stack.append(arena, .{ .compound = is.body });
                if (is.else_branch) |eb| try stack.append(arena, eb);
            },
            .@"switch" => |ss| {
                try countExprUsage(arena, ss.expr, uses);
                for (ss.cases.items) |c| {
                    for (c.selectors.items) |sel| try countExprUsage(arena, sel, uses);
                    try stack.append(arena, .{ .compound = c.body });
                }
            },
            .@"for" => |fs| {
                if (fs.init_stmt) |is| try stack.append(arena, is);
                if (fs.condition) |c| try countExprUsage(arena, c, uses);
                if (fs.update) |u| try stack.append(arena, u);
                try stack.append(arena, .{ .compound = fs.body });
            },
            .@"while" => |ws| {
                try countExprUsage(arena, ws.condition, uses);
                try stack.append(arena, .{ .compound = ws.body });
            },
            .loop => |ls| {
                try stack.append(arena, .{ .compound = ls.body });
                if (ls.continuing) |c| try stack.append(arena, .{ .compound = c });
            },
            .break_if => |bs| try countExprUsage(arena, bs.condition, uses),
            .assign => |as_| {
                try countExprUsage(arena, as_.left, uses);
                try countExprUsage(arena, as_.right, uses);
            },
            .incr_decr => |ids| try countExprUsage(arena, ids.expr, uses),
            .call => |cs| {
                if (cs.call.func) |f| try countExprUsage(arena, f, uses);
                for (cs.call.args.items) |arg| try countExprUsage(arena, arg, uses);
            },
            .decl => |ds| try countDeclUsage(arena, ds.decl, uses),
            .@"break", .@"continue", .discard => {},
        }
    } else unreachable;
}

// =========================================================================
// Scope-local renaming — canonical per-function naming for compression
// =========================================================================

/// Wraps the global renamer, overriding function-local symbols (parameters,
/// locals) with canonical names (a, b, c, ...) that restart in each function.
pub const ScopeLocalRenamer = struct {
    overrides: std.AutoHashMapUnmanaged(u32, []const u8),
    base: *const Printer.Renamer,
    ren: Printer.Renamer,

    pub fn init(arena: std.mem.Allocator, module: *const Ast.Module, base: *const Printer.Renamer) !*ScopeLocalRenamer {
        const self = try arena.create(ScopeLocalRenamer);
        self.* = .{ .overrides = .{}, .base = base, .ren = undefined };

        // Collect global symbol indices (should NOT be overridden)
        var globals: std.AutoHashMapUnmanaged(u32, void) = .{};
        for (module.declarations.items) |decl| {
            const ref = decl.nameRef();
            if (ref.isValid()) try globals.put(arena, ref.index(), {});
        }

        // Collect renamed names of all globals so locals don't shadow them.
        // Without this, a parameter renamed to "a" can shadow a struct also
        // renamed to "a", producing invalid WGSL like `fn f(a:u32)->a`.
        var reserved_names: std.StringHashMapUnmanaged(void) = .{};
        var globals_iter = globals.keyIterator();
        while (globals_iter.next()) |key_ptr| {
            const sym_ref: Ast.SymbolIndex = @enumFromInt(key_ptr.*);
            const name = base.nameForSymbol(sym_ref);
            try reserved_names.put(arena, name, {});
        }

        var name_buf: [16]u8 = undefined;
        for (module.declarations.items) |decl| {
            if (decl != .function) continue;
            const func = decl.function;
            var name_idx: u32 = 0;

            for (func.parameters.items) |param| {
                if (!param.name.isValid()) continue;
                const sym_idx = param.name.index();
                if (globals.contains(sym_idx)) continue;
                if (module.symbols.items[sym_idx].flags.must_not_be_renamed) continue;
                const name = try allocCanonicalName(arena, &name_buf, &name_idx, &reserved_names);
                try self.overrides.put(arena, sym_idx, name);
            }

            if (func.body) |body| {
                try collectBodyLocals(arena, body, module, &globals, &self.overrides, &name_buf, &name_idx, &reserved_names);
            }
        }

        self.ren = .{ .ptr = @ptrCast(self), .nameForSymbolFn = &nameForSymbol };
        return self;
    }

    fn allocCanonicalName(arena: std.mem.Allocator, buf: *[16]u8, idx: *u32, reserved: *const std.StringHashMapUnmanaged(void)) ![]const u8 {
        for (0..256) |_| {
            const name = RenamerMod.numberToMinifiedName(buf, idx.*);
            idx.* += 1;
            if (reserved.contains(name)) continue;
            const copy = try arena.alloc(u8, name.len);
            @memcpy(copy, name);
            return copy;
        } else unreachable;
    }

    /// Iteratively walks compound statements, assigning canonical names to local declarations.
    fn collectBodyLocals(
        arena: std.mem.Allocator,
        body: *const Ast.CompoundStmt,
        module: *const Ast.Module,
        globals: *const std.AutoHashMapUnmanaged(u32, void),
        overrides: *std.AutoHashMapUnmanaged(u32, []const u8),
        name_buf: *[16]u8,
        name_idx: *u32,
        reserved: *const std.StringHashMapUnmanaged(void),
    ) std.mem.Allocator.Error!void {
        var bodies: std.ArrayListUnmanaged(*const Ast.CompoundStmt) = .empty;
        defer bodies.deinit(arena);
        try bodies.append(arena, body);

        for (0..65536) |_| {
            const current_body = bodies.pop() orelse break;
            for (current_body.stmts.items) |stmt| {
                switch (stmt) {
                    .decl => |ds| {
                        const ref = ds.decl.nameRef();
                        if (ref.isValid()) {
                            const sym_idx = ref.index();
                            if (!globals.contains(sym_idx) and !module.symbols.items[sym_idx].flags.must_not_be_renamed) {
                                const name = try allocCanonicalName(arena, name_buf, name_idx, reserved);
                                try overrides.put(arena, sym_idx, name);
                            }
                        }
                    },
                    .@"if" => |s| {
                        try bodies.append(arena, s.body);
                        // Walk else-if chain iteratively
                        var eb_opt = s.else_branch;
                        while (eb_opt) |eb| {
                            switch (eb) {
                                .@"if" => |eif| {
                                    try bodies.append(arena, eif.body);
                                    eb_opt = eif.else_branch;
                                },
                                .compound => |cs| {
                                    try bodies.append(arena, cs);
                                    break;
                                },
                                else => break,
                            }
                        }
                    },
                    .@"for" => |s| try bodies.append(arena, s.body),
                    .@"while" => |s| try bodies.append(arena, s.body),
                    .loop => |s| {
                        try bodies.append(arena, s.body);
                        if (s.continuing) |c| try bodies.append(arena, c);
                    },
                    .@"switch" => |s| {
                        for (s.cases.items) |case| try bodies.append(arena, case.body);
                    },
                    .compound => |s| try bodies.append(arena, s),
                    else => {},
                }
            }
        } else unreachable;
    }

    fn nameForSymbol(ptr: *const anyopaque, ref: Ast.SymbolIndex) []const u8 {
        const self: *const ScopeLocalRenamer = @ptrCast(@alignCast(ptr));
        if (!ref.isValid()) return "";
        if (self.overrides.get(ref.index())) |name| return name;
        return self.base.nameForSymbol(ref);
    }
};

// =========================================================================
// Declaration sorting — group by kind + size for better compression
// =========================================================================

/// Sort module-level declarations by kind (struct→alias→const→var→fn) then
/// by estimated size. Filters to live declarations.
pub fn sortDeclarations(arena: std.mem.Allocator, module: *const Ast.Module) ![]Ast.Decl {
    var live: std.ArrayListUnmanaged(Ast.Decl) = .empty;
    for (module.declarations.items) |decl| {
        if (Dce.isDeclarationLive(decl, module.symbols.items)) {
            try live.append(arena, decl);
        }
    }

    const SortCtx = struct {
        fn lessThan(_: void, a: Ast.Decl, b: Ast.Decl) bool {
            const ka = declKind(a);
            const kb = declKind(b);
            if (ka != kb) return ka < kb;
            return declSize(a) < declSize(b);
        }

        fn declKind(d: Ast.Decl) u8 {
            return switch (d) {
                .@"struct" => 0,
                .alias => 1,
                .const_assert => 2,
                .@"const" => 3,
                .override => 4,
                .@"var" => 5,
                .let => 5,
                .function => 6,
            };
        }

        fn declSize(d: Ast.Decl) u32 {
            return switch (d) {
                .function => |f| @as(u32, @intCast(f.parameters.items.len)) * 10 + if (f.body) |b| @as(u32, @intCast(b.stmts.items.len)) * 5 else 0,
                .@"struct" => |s| @as(u32, @intCast(s.members.items.len)) * 8,
                else => 1,
            };
        }
    };

    std.mem.sort(Ast.Decl, live.items, {}, SortCtx.lessThan);
    return live.items;
}

// =========================================================================
// Tests
// =========================================================================

test "minify basic smoke test" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn main() { let x = 1; }";
    const result = try minify(arena.allocator(), source, .{});
    try std.testing.expect(result.code.len > 0);
    try std.testing.expect(result.errors.len == 0);
}
