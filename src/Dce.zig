//! Dead code elimination for WGSL modules.
//!
//! Marks symbols reachable from entry points as live using BFS.
//! If no entry points exist, all symbols are conservatively marked live.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Liveness = @import("Liveness.zig");

/// Perform dead code elimination. Returns the number of dead symbols.
///
/// `out` receives the per-symbol liveness bits (replacement for the
/// `Symbol.flags.is_live` field deleted in B.M5). Caller allocates
/// `out` with `Liveness.init(arena, module.symbols.items.len)` before
/// the call.
pub fn mark(arena: Allocator, module: *Ast.Module, out: *Liveness) Allocator.Error!u32 {
    // Pre: symbol indices are encoded as u32, so the table can never grow
    // past that ceiling. A breach here would silently truncate downstream
    // SymbolIndex values when buildDependencyGraph stamps them.
    std.debug.assert(module.symbols.items.len < std.math.maxInt(u32));
    if (module.symbols.items.len == 0) return 0;

    // Build dependency graph
    var deps: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty;
    defer {
        var it = deps.valueIterator();
        while (it.next()) |list| list.deinit(arena);
        deps.deinit(arena);
    }
    try buildDependencyGraph(arena, module, &deps);

    // Find entry points
    var entry_points: std.ArrayList(u32) = .empty;
    defer entry_points.deinit(arena);
    for (module.symbols.items, 0..) |sym, i| {
        if (sym.flags.is_entry_point) {
            try entry_points.append(arena, @intCast(i));
        }
    }

    // No entry points means this is a shader library — we can't know what's
    // used externally, so conservatively keep everything.
    if (entry_points.items.len == 0) {
        out.markAllLive();
        return 0;
    }

    // BFS from entry points
    var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer visited.deinit(arena);

    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(arena);
    for (entry_points.items) |ep| {
        try queue.append(arena, ep);
    }

    var head: usize = 0;
    while (head < queue.items.len) {
        const idx = queue.items[head];
        head += 1;
        if (visited.contains(idx)) continue;
        try visited.put(arena, idx, {});

        std.debug.assert(idx < module.symbols.items.len);
        if (idx < module.symbols.items.len) out.markLive(idx);

        if (deps.get(idx)) |dep_list| {
            for (dep_list.items) |dep_idx| {
                if (!visited.contains(dep_idx)) {
                    try queue.append(arena, dep_idx);
                }
            }
        }
    }

    // BFS completeness: visited count must equal live count.
    std.debug.assert(visited.count() <= module.symbols.items.len);

    const live = out.countLive();
    const dead: u32 = @intCast(module.symbols.items.len - live);

    // Post-conditions: live + dead == total, all entry points are live.
    for (module.symbols.items, 0..) |sym, i| {
        if (sym.flags.is_entry_point) std.debug.assert(out.isLive(@intCast(i)));
    }

    return dead;
}

pub fn buildDependencyGraph(
    arena: Allocator,
    module: *const Ast.Module,
    deps: *std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)),
) Allocator.Error!void {
    assert(deps.count() == 0);
    assert(module.symbols.items.len < std.math.maxInt(u32));
    for (module.declarations.items) |decl| {
        try collectDeclDeps(arena, decl, deps);
    }
}

fn collectDeclDeps(
    arena: Allocator,
    decl: Ast.Decl,
    deps: *std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)),
) Allocator.Error!void {
    const name_ref = decl.nameRef();
    if (!name_ref.isValid()) return;
    const sym_idx = name_ref.index();

    var refs: std.ArrayList(u32) = .empty;

    switch (decl) {
        .@"const" => |d| {
            if (d.initializer) |init_expr| try collectExprRefs(arena, init_expr, &refs);
            if (d.typ) |t| try collectTypeRefs(arena, t, &refs);
        },
        .override => |d| {
            try collectAttrRefs(arena, d.attributes.items, &refs);
            if (d.initializer) |init_expr| try collectExprRefs(arena, init_expr, &refs);
            if (d.typ) |t| try collectTypeRefs(arena, t, &refs);
        },
        .@"var" => |d| {
            try collectAttrRefs(arena, d.attributes.items, &refs);
            if (d.initializer) |init_expr| try collectExprRefs(arena, init_expr, &refs);
            if (d.typ) |t| try collectTypeRefs(arena, t, &refs);
        },
        .let => |d| {
            if (d.initializer) |init_expr| try collectExprRefs(arena, init_expr, &refs);
            if (d.typ) |t| try collectTypeRefs(arena, t, &refs);
        },
        .function => |d| {
            try collectAttrRefs(arena, d.attributes.items, &refs);
            for (d.parameters.items) |param| {
                try collectAttrRefs(arena, param.attributes.items, &refs);
                try collectTypeRefs(arena, param.typ, &refs);
            }
            if (d.return_type) |rt| try collectTypeRefs(arena, rt, &refs);
            try collectAttrRefs(arena, d.return_attr.items, &refs);
            if (d.body) |body| try collectStmtRefs(arena, .{ .compound = body }, &refs);
        },
        .@"struct" => |d| {
            for (d.members.items) |member| {
                try collectAttrRefs(arena, member.attributes.items, &refs);
                try collectTypeRefs(arena, member.typ, &refs);
            }
        },
        .alias => |d| try collectTypeRefs(arena, d.typ, &refs),
        .const_assert => {},
    }

    try deps.put(arena, sym_idx, refs);
}

/// Collects symbol references from attribute args, mirroring `AstVisit`'s
/// `visitAttributes` filter. `@builtin`/`@interpolate`/`@diagnostic` are
/// skipped — full-parse Pass 2 doesn't bind their idents, so DCE must not
/// trace through them either; otherwise an entry-reachable attr could
/// keep a same-named user const "alive" even though no symbol-ref
/// actually exists.
fn collectAttrRefs(
    arena: Allocator,
    attrs: []const Ast.Attribute,
    refs: *std.ArrayList(u32),
) Allocator.Error!void {
    for (attrs) |attr| {
        if (!Ast.attributeArgsResolveSymbols(attr.name)) continue;
        for (attr.args.items) |arg| try collectExprRefs(arena, arg, refs);
    }
}

/// Iteratively collects symbol references from an expression tree using a worklist.
pub fn collectExprRefs(
    arena: Allocator,
    expr: Ast.Expr,
    refs: *std.ArrayList(u32),
) Allocator.Error!void {
    var stack: std.ArrayList(Ast.Expr) = .empty;
    defer stack.deinit(arena);
    try stack.append(arena, expr);

    // Bounded worklist: 65536 handles any realistic expression tree depth.
    for (0..65536) |_| {
        const e = stack.pop() orelse break;
        switch (e) {
            .ident => |ie| {
                if (ie.ref.isValid()) try refs.append(arena, ie.ref.index());
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

/// Iteratively collects symbol references from a type tree.
fn collectTypeRefs(
    arena: Allocator,
    typ: Ast.Type,
    refs: *std.ArrayList(u32),
) Allocator.Error!void {
    var current = typ;
    for (0..32) |_| {
        switch (current) {
            .ident => |t| {
                if (t.ref.isValid()) try refs.append(arena, t.ref.index());
                break;
            },
            .vec => |t| {
                current = t.elem_type orelse break;
            },
            .mat => |t| {
                current = t.elem_type orelse break;
            },
            .array => |t| {
                if (t.size) |s| try collectExprRefs(arena, s, refs);
                current = t.elem_type orelse break;
            },
            .ptr => |t| {
                current = t.elem_type;
            },
            .atomic => |t| {
                current = t.elem_type;
            },
            .texture => |t| {
                current = t.sampled_type orelse break;
            },
            .sampler => break,
        }
    } else unreachable;
}

/// Iteratively collects symbol references from a statement tree using a worklist.
pub fn collectStmtRefs(
    arena: Allocator,
    stmt: Ast.Stmt,
    refs: *std.ArrayList(u32),
) Allocator.Error!void {
    var stack: std.ArrayList(Ast.Stmt) = .empty;
    defer stack.deinit(arena);
    try stack.append(arena, stmt);

    for (0..65536) |_| {
        const s = stack.pop() orelse break;
        switch (s) {
            .compound => |cs| {
                for (cs.stmts.items) |inner| try stack.append(arena, inner);
            },
            .@"return" => |rs| {
                if (rs.value) |v| try collectExprRefs(arena, v, refs);
            },
            .@"if" => |is| {
                try collectExprRefs(arena, is.condition, refs);
                try stack.append(arena, .{ .compound = is.body });
                if (is.else_branch) |eb| try stack.append(arena, eb);
            },
            .@"switch" => |ss| {
                try collectExprRefs(arena, ss.expr, refs);
                for (ss.cases.items) |c| {
                    for (c.selectors.items) |sel| try collectExprRefs(arena, sel, refs);
                    try stack.append(arena, .{ .compound = c.body });
                }
            },
            .@"for" => |fs| {
                if (fs.init_stmt) |is| try stack.append(arena, is);
                if (fs.condition) |c| try collectExprRefs(arena, c, refs);
                if (fs.update) |u| try stack.append(arena, u);
                try stack.append(arena, .{ .compound = fs.body });
            },
            .@"while" => |ws| {
                try collectExprRefs(arena, ws.condition, refs);
                try stack.append(arena, .{ .compound = ws.body });
            },
            .loop => |ls| {
                try stack.append(arena, .{ .compound = ls.body });
                if (ls.continuing) |c| try stack.append(arena, .{ .compound = c });
            },
            .break_if => |bs| try collectExprRefs(arena, bs.condition, refs),
            .assign => |as_| {
                try collectExprRefs(arena, as_.left, refs);
                try collectExprRefs(arena, as_.right, refs);
            },
            .incr_decr => |ids| try collectExprRefs(arena, ids.expr, refs),
            .call => |cs| {
                if (cs.call.func) |f| try collectExprRefs(arena, f, refs);
                for (cs.call.args.items) |arg| try collectExprRefs(arena, arg, refs);
            },
            .decl => |ds| {
                switch (ds.decl) {
                    .@"const" => |d| {
                        if (d.initializer) |init_expr| try collectExprRefs(arena, init_expr, refs);
                        if (d.typ) |t| try collectTypeRefs(arena, t, refs);
                    },
                    .let => |d| {
                        if (d.initializer) |init_expr| try collectExprRefs(arena, init_expr, refs);
                        if (d.typ) |t| try collectTypeRefs(arena, t, refs);
                    },
                    .@"var" => |d| {
                        if (d.initializer) |init_expr| try collectExprRefs(arena, init_expr, refs);
                        if (d.typ) |t| try collectTypeRefs(arena, t, refs);
                    },
                    else => {},
                }
            },
            .@"break", .@"continue", .discard => {},
        }
    } else unreachable;
}

/// Check if a declaration is live (for use by printer). When `liveness`
/// has not been populated (length zero, e.g., DCE skipped) every
/// declaration is conservatively kept — matches the pre-B.M5 behavior
/// where `Symbol.flags.is_live` defaulted to `false` only after
/// `Dce.mark` ran.
pub fn isDeclarationLive(decl: Ast.Decl, liveness: Liveness) bool {
    const ref = decl.nameRef();
    if (ref == .none) {
        // const_assert is always kept
        return true;
    }
    if (!ref.isValid()) return true;
    const idx = ref.index();
    assert(idx < std.math.maxInt(u32));
    if (idx >= liveness.bits.bit_length) return true;
    assert(liveness.bits.bit_length > 0);
    return liveness.bits.isSet(idx);
}

// =========================================================================
// Tests
// =========================================================================

const Lexer = @import("Lexer.zig");
const Parser = @import("Parser.zig");

fn parseModule(arena: Allocator, source: [:0]const u8) ?*Ast.Module {
    var tokens = Lexer.tokenize(arena, source) catch return null;
    defer tokens.deinit(arena);
    var parser = Parser.init(arena, source, tokens) catch return null;
    return parser.parse() catch null;
}

/// Test helper: allocates a fresh `Liveness` side-table on the module
/// and runs `mark`. Returns the dead-symbol count; the populated
/// liveness is left on `module.liveness` for downstream assertions.
fn markForTest(arena: Allocator, module: *Ast.Module) Allocator.Error!u32 {
    module.liveness = try Liveness.init(arena, module.symbols.items.len);
    return try mark(arena, module, &module.liveness);
}

test "mark: empty module" {
    var scope = Ast.Scope.init(null, .module);
    var module = Ast.Module.init(&scope, "");
    const dead = try markForTest(std.testing.allocator, &module);
    try std.testing.expectEqual(@as(u32, 0), dead);
}

test "mark: no entry points keeps all live" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const module = parseModule(alloc,
        \\fn a() -> f32 { return 1.0; }
        \\fn b() -> f32 { return 2.0; }
    ) orelse return error.TestParseFailed;

    const dead = try markForTest(alloc, module);
    try std.testing.expectEqual(@as(u32, 0), dead);

    // All symbols should be live
    for (module.symbols.items, 0..) |sym, i| {
        if (sym.kind == .function) {
            try std.testing.expect(module.liveness.isLive(@intCast(i)));
        }
    }
}

test "mark: with entry point removes unused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const module = parseModule(alloc,
        \\fn unused() -> f32 { return 1.0; }
        \\@fragment fn main() -> @location(0) vec4f {
        \\    return vec4f(1.0);
        \\}
    ) orelse return error.TestParseFailed;

    const dead = try markForTest(alloc, module);
    try std.testing.expect(dead > 0);
}

test "mark: transitive dependencies are kept" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const module = parseModule(alloc,
        \\fn a() -> f32 { return 1.0; }
        \\fn b() -> f32 { return a(); }
        \\fn c() -> f32 { return b(); }
        \\@fragment fn main() -> @location(0) vec4f {
        \\    return vec4f(c());
        \\}
    ) orelse return error.TestParseFailed;

    const dead = try markForTest(alloc, module);
    try std.testing.expectEqual(@as(u32, 0), dead);
}

test "mark: complex with unused functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const module = parseModule(alloc,
        \\fn used() -> f32 { return 1.0; }
        \\fn unused1() -> f32 { return 2.0; }
        \\fn unused2() -> f32 { return 3.0; }
        \\@fragment fn main() -> @location(0) vec4f {
        \\    return vec4f(used());
        \\}
    ) orelse return error.TestParseFailed;

    const dead = try markForTest(alloc, module);
    // unused1 and unused2 should be dead
    try std.testing.expect(dead >= 2);
}

test "isDeclarationLive: function decl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const module = parseModule(alloc,
        \\fn unused() {}
        \\@fragment fn main() -> @location(0) vec4f {
        \\    return vec4f(1.0);
        \\}
    ) orelse return error.TestParseFailed;

    _ = try markForTest(alloc, module);

    // Check that main is live and unused is not
    for (module.declarations.items) |decl| {
        const live = isDeclarationLive(decl, module.liveness);
        const ref = decl.nameRef();
        if (ref.isValid()) {
            const idx = ref.index();
            if (idx < module.symbols.items.len) {
                const name = module.symbols.items[idx].original_name;
                if (std.mem.eql(u8, name, "main")) {
                    try std.testing.expect(live);
                } else if (std.mem.eql(u8, name, "unused")) {
                    try std.testing.expect(!live);
                }
            }
        }
    }
}

test "isDeclarationLive: const decl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const module = parseModule(alloc,
        \\const USED: f32 = 1.0;
        \\const UNUSED: f32 = 2.0;
        \\@fragment fn main() -> @location(0) vec4f {
        \\    return vec4f(USED);
        \\}
    ) orelse return error.TestParseFailed;

    _ = try markForTest(alloc, module);

    var found_used = false;
    var found_unused = false;
    for (module.declarations.items) |decl| {
        const ref = decl.nameRef();
        if (ref.isValid() and ref.index() < module.symbols.items.len) {
            const name = module.symbols.items[ref.index()].original_name;
            const live = isDeclarationLive(decl, module.liveness);
            if (std.mem.eql(u8, name, "USED")) {
                found_used = true;
                try std.testing.expect(live);
            } else if (std.mem.eql(u8, name, "UNUSED")) {
                found_unused = true;
                try std.testing.expect(!live);
            }
        }
    }
    try std.testing.expect(found_used);
    try std.testing.expect(found_unused);
}

test "isDeclarationLive: struct decl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const module = parseModule(alloc,
        \\struct Used { x: f32 }
        \\struct Unused { y: f32 }
        \\@fragment fn main() -> @location(0) vec4f {
        \\    var u: Used;
        \\    u.x = 1.0;
        \\    return vec4f(u.x);
        \\}
    ) orelse return error.TestParseFailed;

    _ = try markForTest(alloc, module);

    for (module.declarations.items) |decl| {
        const ref = decl.nameRef();
        if (ref.isValid() and ref.index() < module.symbols.items.len) {
            const name = module.symbols.items[ref.index()].original_name;
            const live = isDeclarationLive(decl, module.liveness);
            if (std.mem.eql(u8, name, "Used")) {
                try std.testing.expect(live);
            } else if (std.mem.eql(u8, name, "Unused")) {
                try std.testing.expect(!live);
            }
        }
    }
}

test "isDeclarationLive: alias decl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const module = parseModule(alloc,
        \\alias UsedFloat = f32;
        \\alias UnusedInt = i32;
        \\@fragment fn main() -> @location(0) vec4f {
        \\    var x: UsedFloat = 1.0;
        \\    return vec4f(x);
        \\}
    ) orelse return error.TestParseFailed;

    _ = try markForTest(alloc, module);

    for (module.declarations.items) |decl| {
        const ref = decl.nameRef();
        if (ref.isValid() and ref.index() < module.symbols.items.len) {
            const name = module.symbols.items[ref.index()].original_name;
            const live = isDeclarationLive(decl, module.liveness);
            if (std.mem.eql(u8, name, "UsedFloat")) {
                try std.testing.expect(live);
            } else if (std.mem.eql(u8, name, "UnusedInt")) {
                try std.testing.expect(!live);
            }
        }
    }
}

test "isDeclarationLive: override decl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const module = parseModule(alloc,
        \\override USED: f32 = 1.0;
        \\override UNUSED: f32 = 2.0;
        \\@fragment fn main() -> @location(0) vec4f {
        \\    return vec4f(USED);
        \\}
    ) orelse return error.TestParseFailed;

    _ = try markForTest(alloc, module);

    for (module.declarations.items) |decl| {
        const ref = decl.nameRef();
        if (ref.isValid() and ref.index() < module.symbols.items.len) {
            const name = module.symbols.items[ref.index()].original_name;
            const live = isDeclarationLive(decl, module.liveness);
            if (std.mem.eql(u8, name, "USED")) {
                try std.testing.expect(live);
            } else if (std.mem.eql(u8, name, "UNUSED")) {
                try std.testing.expect(!live);
            }
        }
    }
}

test "isDeclarationLive: var decl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const module = parseModule(alloc,
        \\@group(0) @binding(0) var<uniform> used: f32;
        \\@group(0) @binding(1) var<uniform> unused_binding: f32;
        \\@fragment fn main() -> @location(0) vec4f {
        \\    return vec4f(used);
        \\}
    ) orelse return error.TestParseFailed;

    _ = try markForTest(alloc, module);

    for (module.declarations.items) |decl| {
        const ref = decl.nameRef();
        if (ref.isValid() and ref.index() < module.symbols.items.len) {
            const name = module.symbols.items[ref.index()].original_name;
            const live = isDeclarationLive(decl, module.liveness);
            if (std.mem.eql(u8, name, "used")) {
                try std.testing.expect(live);
            } else if (std.mem.eql(u8, name, "unused_binding")) {
                try std.testing.expect(!live);
            }
        }
    }
}

test "collectExprRefs: ident expr" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var ident = Ast.IdentExpr{ .name = "x", .ref = @enumFromInt(5) };
    try collectExprRefs(std.testing.allocator, .{ .ident = &ident }, &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
    try std.testing.expectEqual(@as(u32, 5), refs.items[0]);
}

test "collectExprRefs: invalid ref ignored" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var ident = Ast.IdentExpr{ .name = "x", .ref = .none };
    try collectExprRefs(std.testing.allocator, .{ .ident = &ident }, &refs);

    try std.testing.expectEqual(@as(usize, 0), refs.items.len);
}

test "collectExprRefs: literal expr" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var lit = Ast.LiteralExpr{ .kind = .int_literal, .value = "42" };
    try collectExprRefs(std.testing.allocator, .{ .literal = &lit }, &refs);

    try std.testing.expectEqual(@as(usize, 0), refs.items.len);
}

test "collectTypeRefs: ident type with ref" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var ident = Ast.IdentType{ .name = "MyStruct", .ref = @enumFromInt(3) };
    try collectTypeRefs(std.testing.allocator, .{ .ident = &ident }, &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
    try std.testing.expectEqual(@as(u32, 3), refs.items[0]);
}

test "collectTypeRefs: vec type with elem" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var elem = Ast.IdentType{ .name = "f32" };
    var vec = Ast.VecType{ .size = 3, .elem_type = .{ .ident = &elem } };
    try collectTypeRefs(std.testing.allocator, .{ .vec = &vec }, &refs);

    // f32 has no valid ref, so no refs collected
    try std.testing.expectEqual(@as(usize, 0), refs.items.len);
}

test "collectTypeRefs: array with struct element" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var elem_ident = Ast.IdentType{ .name = "Particle", .ref = @enumFromInt(7) };
    var arr = Ast.ArrayType{ .elem_type = .{ .ident = &elem_ident } };
    try collectTypeRefs(std.testing.allocator, .{ .array = &arr }, &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
    try std.testing.expectEqual(@as(u32, 7), refs.items[0]);
}

test "collectTypeRefs: sampler type" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var sampler = Ast.SamplerType{ .comparison = false };
    try collectTypeRefs(std.testing.allocator, .{ .sampler = &sampler }, &refs);

    try std.testing.expectEqual(@as(usize, 0), refs.items.len);
}

// -------------------------------------------------------------------------
// collectExprRefs: remaining expression types
// -------------------------------------------------------------------------

test "collectExprRefs: binary expr" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var left = Ast.IdentExpr{ .name = "a", .ref = @enumFromInt(1) };
    var right = Ast.IdentExpr{ .name = "b", .ref = @enumFromInt(2) };
    var bin = Ast.BinaryExpr{ .op = .add, .left = .{ .ident = &left }, .right = .{ .ident = &right } };
    try collectExprRefs(std.testing.allocator, .{ .binary = &bin }, &refs);

    try std.testing.expectEqual(@as(usize, 2), refs.items.len);
}

test "collectExprRefs: unary expr" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var operand = Ast.IdentExpr{ .name = "x", .ref = @enumFromInt(1) };
    var un = Ast.UnaryExpr{ .op = .neg, .operand = .{ .ident = &operand } };
    try collectExprRefs(std.testing.allocator, .{ .unary = &un }, &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
}

test "collectExprRefs: call expr" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var func_id = Ast.IdentExpr{ .name = "f", .ref = @enumFromInt(0) };
    var arg1 = Ast.IdentExpr{ .name = "a", .ref = @enumFromInt(1) };
    var arg2 = Ast.IdentExpr{ .name = "b", .ref = @enumFromInt(2) };
    var args_buf = [_]Ast.Expr{ .{ .ident = &arg1 }, .{ .ident = &arg2 } };
    var call = Ast.CallExpr{ .func = .{ .ident = &func_id }, .args = .{ .items = &args_buf, .capacity = 2 } };
    try collectExprRefs(std.testing.allocator, .{ .call = &call }, &refs);

    try std.testing.expectEqual(@as(usize, 3), refs.items.len);
}

test "collectExprRefs: index expr" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var base = Ast.IdentExpr{ .name = "arr", .ref = @enumFromInt(1) };
    var idx = Ast.IdentExpr{ .name = "i", .ref = @enumFromInt(2) };
    var index_expr = Ast.IndexExpr{ .base = .{ .ident = &base }, .idx = .{ .ident = &idx } };
    try collectExprRefs(std.testing.allocator, .{ .index = &index_expr }, &refs);

    try std.testing.expectEqual(@as(usize, 2), refs.items.len);
}

test "collectExprRefs: member expr" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var base = Ast.IdentExpr{ .name = "s", .ref = @enumFromInt(1) };
    var mem = Ast.MemberExpr{ .base = .{ .ident = &base }, .member_name = "x" };
    try collectExprRefs(std.testing.allocator, .{ .member = &mem }, &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
}

test "collectExprRefs: paren expr" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var inner = Ast.IdentExpr{ .name = "x", .ref = @enumFromInt(1) };
    var paren = Ast.ParenExpr{ .expr = .{ .ident = &inner } };
    try collectExprRefs(std.testing.allocator, .{ .paren = &paren }, &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
}

// -------------------------------------------------------------------------
// collectTypeRefs: remaining type variants
// -------------------------------------------------------------------------

test "collectTypeRefs: ident type invalid ref" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var ident = Ast.IdentType{ .name = "f32" }; // builtin, no ref
    try collectTypeRefs(std.testing.allocator, .{ .ident = &ident }, &refs);

    try std.testing.expectEqual(@as(usize, 0), refs.items.len);
}

test "collectTypeRefs: mat type with elem" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var elem = Ast.IdentType{ .name = "MyType", .ref = @enumFromInt(1) };
    var mat = Ast.MatType{ .cols = 4, .rows = 4, .elem_type = .{ .ident = &elem } };
    try collectTypeRefs(std.testing.allocator, .{ .mat = &mat }, &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
}

test "collectTypeRefs: ptr type" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var elem = Ast.IdentType{ .name = "MyType", .ref = @enumFromInt(1) };
    var ptr_type = Ast.PtrType{ .address_space = .function, .elem_type = .{ .ident = &elem } };
    try collectTypeRefs(std.testing.allocator, .{ .ptr = &ptr_type }, &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
}

test "collectTypeRefs: atomic type builtin" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var elem = Ast.IdentType{ .name = "u32" }; // builtin, no ref
    var atomic = Ast.AtomicType{ .elem_type = .{ .ident = &elem } };
    try collectTypeRefs(std.testing.allocator, .{ .atomic = &atomic }, &refs);

    try std.testing.expectEqual(@as(usize, 0), refs.items.len);
}

test "collectTypeRefs: texture type with sampled type" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var sampled = Ast.IdentType{ .name = "MyType", .ref = @enumFromInt(1) };
    var tex = Ast.TextureType{ .kind = .sampled, .dimension = .@"2d", .sampled_type = .{ .ident = &sampled } };
    try collectTypeRefs(std.testing.allocator, .{ .texture = &tex }, &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
}

test "collectTypeRefs: array with size expr" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var elem = Ast.IdentType{ .name = "MyType", .ref = @enumFromInt(1) };
    var size_expr = Ast.IdentExpr{ .name = "N", .ref = @enumFromInt(2) };
    var arr = Ast.ArrayType{ .elem_type = .{ .ident = &elem }, .size = .{ .ident = &size_expr } };
    try collectTypeRefs(std.testing.allocator, .{ .array = &arr }, &refs);

    try std.testing.expectEqual(@as(usize, 2), refs.items.len);
}

// -------------------------------------------------------------------------
// collectStmtRefs: basic statements
// -------------------------------------------------------------------------

test "collectStmtRefs: return stmt with value" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var value = Ast.IdentExpr{ .name = "x", .ref = @enumFromInt(1) };
    var ret = Ast.ReturnStmt{ .value = .{ .ident = &value } };
    try collectStmtRefs(std.testing.allocator, .{ .@"return" = &ret }, &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
}

test "collectStmtRefs: assign stmt" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var left = Ast.IdentExpr{ .name = "x", .ref = @enumFromInt(0) };
    var right = Ast.IdentExpr{ .name = "y", .ref = @enumFromInt(1) };
    var assign = Ast.AssignStmt{ .op = .simple, .left = .{ .ident = &left }, .right = .{ .ident = &right } };
    try collectStmtRefs(std.testing.allocator, .{ .assign = &assign }, &refs);

    try std.testing.expectEqual(@as(usize, 2), refs.items.len);
}

test "collectStmtRefs: incr_decr stmt" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var expr = Ast.IdentExpr{ .name = "i", .ref = @enumFromInt(0) };
    var incr = Ast.IncrDecrStmt{ .expr = .{ .ident = &expr }, .increment = true };
    try collectStmtRefs(std.testing.allocator, .{ .incr_decr = &incr }, &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
}

test "collectStmtRefs: call stmt" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var func_id = Ast.IdentExpr{ .name = "f", .ref = @enumFromInt(0) };
    var arg = Ast.IdentExpr{ .name = "a", .ref = @enumFromInt(1) };
    var args_buf = [_]Ast.Expr{.{ .ident = &arg }};
    var call_expr = Ast.CallExpr{ .func = .{ .ident = &func_id }, .args = .{ .items = &args_buf, .capacity = 1 } };
    var call_stmt = Ast.CallStmt{ .call = &call_expr };
    try collectStmtRefs(std.testing.allocator, .{ .call = &call_stmt }, &refs);

    try std.testing.expectEqual(@as(usize, 2), refs.items.len);
}

test "collectStmtRefs: break_if stmt" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var cond = Ast.IdentExpr{ .name = "done", .ref = @enumFromInt(0) };
    var break_if = Ast.BreakIfStmt{ .condition = .{ .ident = &cond } };
    try collectStmtRefs(std.testing.allocator, .{ .break_if = &break_if }, &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
}

test "collectStmtRefs: break and continue have no refs" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var brk = Ast.BreakStmt{};
    try collectStmtRefs(std.testing.allocator, .{ .@"break" = &brk }, &refs);
    try std.testing.expectEqual(@as(usize, 0), refs.items.len);

    var cont = Ast.ContinueStmt{};
    try collectStmtRefs(std.testing.allocator, .{ .@"continue" = &cont }, &refs);
    try std.testing.expectEqual(@as(usize, 0), refs.items.len);

    var disc = Ast.DiscardStmt{};
    try collectStmtRefs(std.testing.allocator, .{ .discard = &disc }, &refs);
    try std.testing.expectEqual(@as(usize, 0), refs.items.len);
}

// -------------------------------------------------------------------------
// collectStmtRefs: compound and control flow
// -------------------------------------------------------------------------

test "collectStmtRefs: compound stmt" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var value = Ast.IdentExpr{ .name = "x", .ref = @enumFromInt(1) };
    var ret = Ast.ReturnStmt{ .value = .{ .ident = &value } };
    var stmts_buf = [_]Ast.Stmt{.{ .@"return" = &ret }};
    var compound = Ast.CompoundStmt{ .stmts = .{ .items = &stmts_buf, .capacity = 1 } };
    try collectStmtRefs(std.testing.allocator, .{ .compound = &compound }, &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
}

test "collectStmtRefs: if stmt with else" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var cond = Ast.IdentExpr{ .name = "c", .ref = @enumFromInt(0) };
    var body_val = Ast.IdentExpr{ .name = "a", .ref = @enumFromInt(1) };
    var body_ret = Ast.ReturnStmt{ .value = .{ .ident = &body_val } };
    var body_stmts = [_]Ast.Stmt{.{ .@"return" = &body_ret }};
    var body = Ast.CompoundStmt{ .stmts = .{ .items = &body_stmts, .capacity = 1 } };
    var else_val = Ast.IdentExpr{ .name = "b", .ref = @enumFromInt(2) };
    var else_ret = Ast.ReturnStmt{ .value = .{ .ident = &else_val } };
    var else_stmts = [_]Ast.Stmt{.{ .@"return" = &else_ret }};
    var else_body = Ast.CompoundStmt{ .stmts = .{ .items = &else_stmts, .capacity = 1 } };
    var if_stmt = Ast.IfStmt{
        .condition = .{ .ident = &cond },
        .body = &body,
        .else_branch = .{ .compound = &else_body },
    };
    try collectStmtRefs(std.testing.allocator, .{ .@"if" = &if_stmt }, &refs);

    try std.testing.expectEqual(@as(usize, 3), refs.items.len);
}

test "collectStmtRefs: while stmt" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var cond = Ast.IdentExpr{ .name = "c", .ref = @enumFromInt(0) };
    var body_val = Ast.IdentExpr{ .name = "x", .ref = @enumFromInt(1) };
    var body_ret = Ast.ReturnStmt{ .value = .{ .ident = &body_val } };
    var body_stmts = [_]Ast.Stmt{.{ .@"return" = &body_ret }};
    var body = Ast.CompoundStmt{ .stmts = .{ .items = &body_stmts, .capacity = 1 } };
    var while_stmt = Ast.WhileStmt{ .condition = .{ .ident = &cond }, .body = &body };
    try collectStmtRefs(std.testing.allocator, .{ .@"while" = &while_stmt }, &refs);

    try std.testing.expectEqual(@as(usize, 2), refs.items.len);
}

test "collectStmtRefs: loop stmt with continuing" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var body_val = Ast.IdentExpr{ .name = "x", .ref = @enumFromInt(0) };
    var body_ret = Ast.ReturnStmt{ .value = .{ .ident = &body_val } };
    var body_stmts = [_]Ast.Stmt{.{ .@"return" = &body_ret }};
    var body = Ast.CompoundStmt{ .stmts = .{ .items = &body_stmts, .capacity = 1 } };

    var cont_func = Ast.IdentExpr{ .name = "update", .ref = @enumFromInt(1) };
    var cont_call = Ast.CallExpr{ .func = .{ .ident = &cont_func }, .args = .empty };
    var cont_call_stmt = Ast.CallStmt{ .call = &cont_call };
    var cont_stmts = [_]Ast.Stmt{.{ .call = &cont_call_stmt }};
    var continuing = Ast.CompoundStmt{ .stmts = .{ .items = &cont_stmts, .capacity = 1 } };

    var loop_stmt = Ast.LoopStmt{ .body = &body, .continuing = &continuing };
    try collectStmtRefs(std.testing.allocator, .{ .loop = &loop_stmt }, &refs);

    try std.testing.expectEqual(@as(usize, 2), refs.items.len);
}

test "collectStmtRefs: switch stmt" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var expr = Ast.IdentExpr{ .name = "x", .ref = @enumFromInt(0) };
    var sel = Ast.IdentExpr{ .name = "A", .ref = @enumFromInt(1) };
    var case_val = Ast.IdentExpr{ .name = "y", .ref = @enumFromInt(2) };
    var case_ret = Ast.ReturnStmt{ .value = .{ .ident = &case_val } };
    var case_stmts = [_]Ast.Stmt{.{ .@"return" = &case_ret }};
    var case_body = Ast.CompoundStmt{ .stmts = .{ .items = &case_stmts, .capacity = 1 } };
    var selectors_buf = [_]Ast.Expr{.{ .ident = &sel }};
    var cases_buf = [_]Ast.SwitchCase{.{
        .selectors = .{ .items = &selectors_buf, .capacity = 1 },
        .body = &case_body,
    }};
    var switch_stmt = Ast.SwitchStmt{
        .expr = .{ .ident = &expr },
        .cases = .{ .items = &cases_buf, .capacity = 1 },
    };
    try collectStmtRefs(std.testing.allocator, .{ .@"switch" = &switch_stmt }, &refs);

    try std.testing.expectEqual(@as(usize, 3), refs.items.len);
}

test "collectStmtRefs: for stmt" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var init_left = Ast.IdentExpr{ .name = "i", .ref = @enumFromInt(0) };
    var init_right = Ast.LiteralExpr{ .kind = .int_literal, .value = "0" };
    var init_stmt = Ast.AssignStmt{ .op = .simple, .left = .{ .ident = &init_left }, .right = .{ .literal = &init_right } };

    var cond = Ast.IdentExpr{ .name = "n", .ref = @enumFromInt(1) };

    var update_expr = Ast.IdentExpr{ .name = "j", .ref = @enumFromInt(2) };
    var update_stmt = Ast.IncrDecrStmt{ .expr = .{ .ident = &update_expr }, .increment = true };

    var brk = Ast.BreakStmt{};
    var body_stmts = [_]Ast.Stmt{.{ .@"break" = &brk }};
    var body = Ast.CompoundStmt{ .stmts = .{ .items = &body_stmts, .capacity = 1 } };

    var for_stmt = Ast.ForStmt{
        .init_stmt = .{ .assign = &init_stmt },
        .condition = .{ .ident = &cond },
        .update = .{ .incr_decr = &update_stmt },
        .body = &body,
    };
    try collectStmtRefs(std.testing.allocator, .{ .@"for" = &for_stmt }, &refs);

    try std.testing.expectEqual(@as(usize, 3), refs.items.len);
}

// -------------------------------------------------------------------------
// collectStmtRefs: decl statements
// -------------------------------------------------------------------------

test "collectStmtRefs: decl stmt const" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var init_val = Ast.IdentExpr{ .name = "y", .ref = @enumFromInt(1) };
    var const_decl = Ast.ConstDecl{ .name = @enumFromInt(0), .initializer = .{ .ident = &init_val } };
    var decl_stmt = Ast.DeclStmt{ .decl = .{ .@"const" = &const_decl } };
    try collectStmtRefs(std.testing.allocator, .{ .decl = &decl_stmt }, &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
}

test "collectStmtRefs: decl stmt let" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var init_val = Ast.IdentExpr{ .name = "y", .ref = @enumFromInt(1) };
    var let_decl = Ast.LetDecl{ .name = @enumFromInt(0), .initializer = .{ .ident = &init_val } };
    var decl_stmt = Ast.DeclStmt{ .decl = .{ .let = &let_decl } };
    try collectStmtRefs(std.testing.allocator, .{ .decl = &decl_stmt }, &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
}

test "collectStmtRefs: decl stmt var with type and init" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var init_val = Ast.IdentExpr{ .name = "y", .ref = @enumFromInt(1) };
    var type_id = Ast.IdentType{ .name = "MyType", .ref = @enumFromInt(2) };
    var var_decl = Ast.VarDecl{
        .name = @enumFromInt(0),
        .attributes = .empty,
        .typ = .{ .ident = &type_id },
        .initializer = .{ .ident = &init_val },
    };
    var decl_stmt = Ast.DeclStmt{ .decl = .{ .@"var" = &var_decl } };
    try collectStmtRefs(std.testing.allocator, .{ .decl = &decl_stmt }, &refs);

    try std.testing.expectEqual(@as(usize, 2), refs.items.len);
}

test "collectStmtRefs: decl stmt var type only" {
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var type_id = Ast.IdentType{ .name = "MyType", .ref = @enumFromInt(1) };
    var var_decl = Ast.VarDecl{ .name = @enumFromInt(0), .attributes = .empty, .typ = .{ .ident = &type_id } };
    var decl_stmt = Ast.DeclStmt{ .decl = .{ .@"var" = &var_decl } };
    try collectStmtRefs(std.testing.allocator, .{ .decl = &decl_stmt }, &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
}

// -------------------------------------------------------------------------
// collectDeclDeps: integration tests via parser
// -------------------------------------------------------------------------

test "collectDeclDeps: const depends on const" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const module = parseModule(alloc, "const a = 1; const b = a;") orelse return error.TestParseFailed;

    var deps: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty;
    defer {
        var it = deps.valueIterator();
        while (it.next()) |list| list.deinit(alloc);
        deps.deinit(alloc);
    }
    try buildDependencyGraph(alloc, module, &deps);

    try std.testing.expect(deps.count() > 0);
}

test "collectDeclDeps: override with init" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const module = parseModule(alloc, "const base = 1.0; @id(0) override scale: f32 = base;") orelse return error.TestParseFailed;

    var deps: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty;
    defer {
        var it = deps.valueIterator();
        while (it.next()) |list| list.deinit(alloc);
        deps.deinit(alloc);
    }
    try buildDependencyGraph(alloc, module, &deps);

    try std.testing.expect(deps.count() > 0);
}

test "collectDeclDeps: override without init" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const module = parseModule(alloc, "@id(0) override x: f32;") orelse return error.TestParseFailed;

    var deps: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty;
    defer {
        var it = deps.valueIterator();
        while (it.next()) |list| list.deinit(alloc);
        deps.deinit(alloc);
    }
    try buildDependencyGraph(alloc, module, &deps);
    // Should not panic
}

test "collectDeclDeps: var without init" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const module = parseModule(alloc, "var<private> x: i32;") orelse return error.TestParseFailed;

    var deps: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty;
    defer {
        var it = deps.valueIterator();
        while (it.next()) |list| list.deinit(alloc);
        deps.deinit(alloc);
    }
    try buildDependencyGraph(alloc, module, &deps);
    // Should not panic
}

test "collectDeclDeps: var with init" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const module = parseModule(alloc, "const init_val = 0; var<private> x: i32 = init_val;") orelse return error.TestParseFailed;

    var deps: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty;
    defer {
        var it = deps.valueIterator();
        while (it.next()) |list| list.deinit(alloc);
        deps.deinit(alloc);
    }
    try buildDependencyGraph(alloc, module, &deps);

    try std.testing.expect(deps.count() > 0);
}

test "collectDeclDeps: function with body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const module = parseModule(alloc,
        \\struct Data { value: f32 }
        \\fn helper(d: Data) -> f32 { return d.value; }
    ) orelse return error.TestParseFailed;

    var deps: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty;
    defer {
        var it = deps.valueIterator();
        while (it.next()) |list| list.deinit(alloc);
        deps.deinit(alloc);
    }
    try buildDependencyGraph(alloc, module, &deps);

    try std.testing.expect(deps.count() > 0);
}

test "collectDeclDeps: struct with nested type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const module = parseModule(alloc,
        \\struct Inner { x: f32 }
        \\struct Outer { inner: Inner }
    ) orelse return error.TestParseFailed;

    var deps: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty;
    defer {
        var it = deps.valueIterator();
        while (it.next()) |list| list.deinit(alloc);
        deps.deinit(alloc);
    }
    try buildDependencyGraph(alloc, module, &deps);

    try std.testing.expect(deps.count() > 0);
}

test "collectDeclDeps: alias depends on struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const module = parseModule(alloc,
        \\struct Data { x: f32 }
        \\alias DataRef = Data;
    ) orelse return error.TestParseFailed;

    var deps: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty;
    defer {
        var it = deps.valueIterator();
        while (it.next()) |list| list.deinit(alloc);
        deps.deinit(alloc);
    }
    try buildDependencyGraph(alloc, module, &deps);

    try std.testing.expect(deps.count() > 0);
}

// -------------------------------------------------------------------------
// isDeclarationLive: edge cases
// -------------------------------------------------------------------------

test "isDeclarationLive: const_assert always kept" {
    const empty_liveness: Liveness = .{ .bits = .{} };
    var lit = Ast.LiteralExpr{ .kind = .true_literal, .value = "true" };
    var decl = Ast.ConstAssertDecl{ .expr = .{ .literal = &lit } };
    try std.testing.expect(isDeclarationLive(.{ .const_assert = &decl }, empty_liveness));
}

test "isDeclarationLive: let decl" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    var liveness = try Liveness.init(arena_inst.allocator(), 1);
    liveness.markLive(0);
    var let_decl = Ast.LetDecl{ .name = @enumFromInt(0) };
    try std.testing.expect(isDeclarationLive(.{ .let = &let_decl }, liveness));
}

test "isDeclarationLive: out of bounds ref kept" {
    const empty_liveness: Liveness = .{ .bits = .{} };
    var const_decl = Ast.ConstDecl{ .name = @enumFromInt(999) };
    try std.testing.expect(isDeclarationLive(.{ .@"const" = &const_decl }, empty_liveness));
}

// -------------------------------------------------------------------------
// mark: with specific symbol name checks
// -------------------------------------------------------------------------

test "mark: entry point and dependencies are live, unused are dead" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const module = parseModule(alloc,
        \\const dead = 1;
        \\const used = 2;
        \\@compute @workgroup_size(1) fn main() { let x = used; }
    ) orelse return error.TestParseFailed;

    _ = try markForTest(alloc, module);

    var found_dead = false;
    var found_used = false;
    var found_main = false;
    for (module.symbols.items, 0..) |sym, i| {
        const live = module.liveness.isLive(@intCast(i));
        if (std.mem.eql(u8, sym.original_name, "dead")) {
            found_dead = true;
            try std.testing.expect(!live);
        } else if (std.mem.eql(u8, sym.original_name, "used")) {
            found_used = true;
            try std.testing.expect(live);
        } else if (std.mem.eql(u8, sym.original_name, "main")) {
            found_main = true;
            try std.testing.expect(live);
        }
    }
    try std.testing.expect(found_dead);
    try std.testing.expect(found_used);
    try std.testing.expect(found_main);
}

test "mark: transitive chain a -> b -> c" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const module = parseModule(alloc,
        \\const a = 1;
        \\const b = a;
        \\const c = b;
        \\const unused = 42;
        \\@compute @workgroup_size(1) fn main() { let x = c; }
    ) orelse return error.TestParseFailed;

    _ = try markForTest(alloc, module);

    for (module.symbols.items, 0..) |sym, i| {
        const live = module.liveness.isLive(@intCast(i));
        if (std.mem.eql(u8, sym.original_name, "a") or
            std.mem.eql(u8, sym.original_name, "b") or
            std.mem.eql(u8, sym.original_name, "c") or
            std.mem.eql(u8, sym.original_name, "main"))
        {
            try std.testing.expect(live);
        } else if (std.mem.eql(u8, sym.original_name, "unused")) {
            try std.testing.expect(!live);
        }
    }
}

test "mark: complex dependencies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const module = parseModule(alloc,
        \\struct Data { value: f32 }
        \\struct Wrapper { data: Data }
        \\const SCALE = 2.0;
        \\const unused_const = 42.0;
        \\fn helper(w: Wrapper) -> f32 { return w.data.value; }
        \\fn unused_helper() -> f32 { return unused_const; }
        \\@compute @workgroup_size(1) fn main() { var w: Wrapper; let r = helper(w); }
    ) orelse return error.TestParseFailed;

    const dead = try markForTest(alloc, module);

    for (module.symbols.items, 0..) |sym, i| {
        const live = module.liveness.isLive(@intCast(i));
        if (std.mem.eql(u8, sym.original_name, "Data") or
            std.mem.eql(u8, sym.original_name, "Wrapper") or
            std.mem.eql(u8, sym.original_name, "helper") or
            std.mem.eql(u8, sym.original_name, "main"))
        {
            try std.testing.expect(live);
        } else if (std.mem.eql(u8, sym.original_name, "unused_const") or
            std.mem.eql(u8, sym.original_name, "unused_helper"))
        {
            try std.testing.expect(!live);
        }
    }

    try std.testing.expect(dead >= 2);
}

test "mark: find entry points" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const module = parseModule(alloc,
        \\fn helper() {}
        \\@vertex fn vert() -> @builtin(position) vec4<f32> { return vec4<f32>(0.0); }
        \\@fragment fn frag() -> @location(0) vec4<f32> { return vec4<f32>(0.0); }
        \\@compute @workgroup_size(1) fn comp() {}
    ) orelse return error.TestParseFailed;

    // Count entry points
    var entry_count: u32 = 0;
    for (module.symbols.items) |sym| {
        if (sym.flags.is_entry_point) entry_count += 1;
    }
    try std.testing.expectEqual(@as(u32, 3), entry_count);
}

test "mark: propagates OOM" {
    // First parse with real allocator
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = parseModule(arena.allocator(),
        \\@compute @workgroup_size(1) fn main() {}
        \\fn helper() {}
    ) orelse return error.TestParseFailed;

    // Then try mark with failing allocator. After B.M3 the very first
    // allocation is Liveness.init (inside markForTest); pre-B.M3 it was
    // the dependency graph inside mark. Either way, fail_index=0 forces
    // the first allocation to fail and OOM must propagate.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const result = markForTest(failing.allocator(), module);
    try std.testing.expect(result == error.OutOfMemory);
}

// =========================================================================
// Attribute-arg reachability — tests for the gap closure across
// `Ast.attributeArgsResolveSymbols`. Pre-fix: an entry-point-reachable
// `@workgroup_size(WG_X)` with `WG_X` declared but unreferenced anywhere
// else would DCE `WG_X`, making `Printer.zig`'s `is_live` gate drop the
// `const WG_X` decl and produce an unresolvable attribute. These tests
// pin that those references now propagate liveness end-to-end.
// =========================================================================

fn assertNamedSymLive(module: *const Ast.Module, name: []const u8) !void {
    for (module.symbols.items, 0..) |sym, i| {
        if (std.mem.eql(u8, sym.original_name, name)) {
            if (!module.liveness.isLive(@intCast(i))) {
                std.debug.print("expected '{s}' to be live, but it was DCE'd\n", .{name});
                return error.SymbolWasDeadButShouldBeLive;
            }
            return;
        }
    }
    return error.SymbolNotFound;
}

fn assertNamedSymDead(module: *const Ast.Module, name: []const u8) !void {
    for (module.symbols.items, 0..) |sym, i| {
        if (std.mem.eql(u8, sym.original_name, name)) {
            if (module.liveness.isLive(@intCast(i))) {
                std.debug.print("expected '{s}' to be dead, but it was kept\n", .{name});
                return error.SymbolWasLiveButShouldBeDead;
            }
            return;
        }
    }
    return error.SymbolNotFound;
}

test "attribute-arg reachability: @workgroup_size(WG_X) keeps WG_X live" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = parseModule(arena.allocator(),
        \\const WG_X: u32 = 16;
        \\@compute @workgroup_size(WG_X) fn main() {}
    ) orelse return error.TestParseFailed;
    _ = try markForTest(arena.allocator(), module);
    try assertNamedSymLive(module, "WG_X");
    try assertNamedSymLive(module, "main");
}

test "attribute-arg reachability: @group(BG) on a referenced var keeps BG live" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = parseModule(arena.allocator(),
        \\const BG: u32 = 0;
        \\@group(BG) @binding(0) var<uniform> u: vec4f;
        \\@compute @workgroup_size(1) fn main() { let _v = u; }
    ) orelse return error.TestParseFailed;
    _ = try markForTest(arena.allocator(), module);
    try assertNamedSymLive(module, "BG");
    try assertNamedSymLive(module, "u");
}

test "attribute-arg reachability: @binding(IDX) on a referenced var keeps IDX live" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = parseModule(arena.allocator(),
        \\const IDX: u32 = 2;
        \\@group(0) @binding(IDX) var<uniform> u: vec4f;
        \\@compute @workgroup_size(1) fn main() { let _v = u; }
    ) orelse return error.TestParseFailed;
    _ = try markForTest(arena.allocator(), module);
    try assertNamedSymLive(module, "IDX");
}

test "attribute-arg reachability: @id(MY_ID) on a referenced override keeps MY_ID live" {
    // `@id` takes a const-expression — MY_ID must be `const`, not
    // `override` (validator E0315 otherwise). We pin DCE liveness here;
    // validator semantics are covered separately in tests/validation_test.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = parseModule(arena.allocator(),
        \\const MY_ID: u32 = 7;
        \\@id(MY_ID) override x: f32;
        \\@compute @workgroup_size(1) fn main() { let _v = x; }
    ) orelse return error.TestParseFailed;
    _ = try markForTest(arena.allocator(), module);
    try assertNamedSymLive(module, "MY_ID");
}

test "attribute-arg reachability: struct member @align(A) keeps A live" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = parseModule(arena.allocator(),
        \\const A: u32 = 16;
        \\struct S { @align(A) x: f32, y: i32 }
        \\@group(0) @binding(0) var<storage> s: S;
        \\@compute @workgroup_size(1) fn main() { let _v = s; }
    ) orelse return error.TestParseFailed;
    _ = try markForTest(arena.allocator(), module);
    try assertNamedSymLive(module, "A");
    try assertNamedSymLive(module, "S");
}

test "attribute-arg reachability: struct member @size(SZ) keeps SZ live" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = parseModule(arena.allocator(),
        \\const SZ: u32 = 32;
        \\struct S { @size(SZ) x: f32, y: i32 }
        \\@group(0) @binding(0) var<storage> s: S;
        \\@compute @workgroup_size(1) fn main() { let _v = s; }
    ) orelse return error.TestParseFailed;
    _ = try markForTest(arena.allocator(), module);
    try assertNamedSymLive(module, "SZ");
}

test "attribute-arg reachability: param @location(L) keeps L live" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = parseModule(arena.allocator(),
        \\const L: u32 = 3;
        \\@vertex fn main(@location(L) p: vec4f) -> @builtin(position) vec4f { return p; }
    ) orelse return error.TestParseFailed;
    _ = try markForTest(arena.allocator(), module);
    try assertNamedSymLive(module, "L");
}

test "attribute-arg reachability: return @location(RL) keeps RL live" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = parseModule(arena.allocator(),
        \\const RL: u32 = 1;
        \\@fragment fn main() -> @location(RL) vec4f { return vec4f(0.0); }
    ) orelse return error.TestParseFailed;
    _ = try markForTest(arena.allocator(), module);
    try assertNamedSymLive(module, "RL");
}

test "attribute-arg reachability: cascading consts traced through @workgroup_size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = parseModule(arena.allocator(),
        \\const A: u32 = 1;
        \\const B: u32 = A + 1;
        \\@compute @workgroup_size(B) fn main() {}
    ) orelse return error.TestParseFailed;
    _ = try markForTest(arena.allocator(), module);
    try assertNamedSymLive(module, "A");
    try assertNamedSymLive(module, "B");
}

test "attribute-arg reachability: same const referenced multiple times keeps it live, others dead" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = parseModule(arena.allocator(),
        \\const N: u32 = 8;
        \\const UNUSED: u32 = 99;
        \\@compute @workgroup_size(N, N, N) fn main() {}
    ) orelse return error.TestParseFailed;
    _ = try markForTest(arena.allocator(), module);
    try assertNamedSymLive(module, "N");
    try assertNamedSymDead(module, "UNUSED");
}

test "attribute-arg reachability: nested expression in attr keeps inner const live" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = parseModule(arena.allocator(),
        \\const N: u32 = 4;
        \\@compute @workgroup_size(N * 2) fn main() {}
    ) orelse return error.TestParseFailed;
    _ = try markForTest(arena.allocator(), module);
    try assertNamedSymLive(module, "N");
}

test "attribute-arg reachability: deny-list — same-named const is NOT kept by @interpolate" {
    // The user has declared `const linear: f32 = 1.0;` — it's NOT
    // referenced anywhere outside the `@interpolate` deny-list attr.
    // DCE must mark it dead even though `@interpolate(linear)` syntactically
    // mentions the same name; the predicate denies symbol resolution there.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = parseModule(arena.allocator(),
        \\const linear: f32 = 1.0;
        \\struct V { @location(0) @interpolate(linear) p: vec4f }
        \\@group(0) @binding(0) var<storage> v: V;
        \\@compute @workgroup_size(1) fn main() { let _v = v; }
    ) orelse return error.TestParseFailed;
    _ = try markForTest(arena.allocator(), module);
    try assertNamedSymDead(module, "linear");
}

test "attribute-arg reachability: @group(BG) on unreferenced var leaves BG dead" {
    // BG appears in `@group(BG)` on a var that itself isn't reached from
    // the entry point — the var is dead, so its attribute walks aren't
    // visited by BFS. BG stays dead. (Negative test: we don't over-mark.)
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = parseModule(arena.allocator(),
        \\const BG: u32 = 0;
        \\@group(BG) @binding(0) var<uniform> unused_u: vec4f;
        \\@compute @workgroup_size(1) fn main() {}
    ) orelse return error.TestParseFailed;
    _ = try markForTest(arena.allocator(), module);
    try assertNamedSymDead(module, "BG");
    try assertNamedSymDead(module, "unused_u");
}
