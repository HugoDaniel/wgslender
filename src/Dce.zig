//! Dead code elimination for WGSL modules.
//!
//! Marks symbols reachable from entry points as live using BFS.
//! If no entry points exist, all symbols are conservatively marked live.

const std = @import("std");
const Ast = @import("Ast.zig");

/// Perform dead code elimination. Returns the number of dead symbols.
pub fn mark(allocator: std.mem.Allocator, module: *Ast.Module) std.mem.Allocator.Error!u32 {
    if (module.symbols.items.len == 0) return 0;

    // Build dependency graph
    var deps: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)) = .empty;
    defer {
        var it = deps.valueIterator();
        while (it.next()) |list| list.deinit(allocator);
        deps.deinit(allocator);
    }
    try buildDependencyGraph(allocator, module, &deps);

    // Find entry points
    var entry_points: std.ArrayListUnmanaged(u32) = .empty;
    defer entry_points.deinit(allocator);
    for (module.symbols.items, 0..) |sym, i| {
        if (sym.flags.is_entry_point) {
            try entry_points.append(allocator, @intCast(i));
        }
    }

    // Conservative: no entry points → mark all live
    if (entry_points.items.len == 0) {
        for (module.symbols.items) |*sym| {
            sym.flags.is_live = true;
        }
        return 0;
    }

    // BFS from entry points
    var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer visited.deinit(allocator);

    var queue: std.ArrayListUnmanaged(u32) = .empty;
    defer queue.deinit(allocator);
    for (entry_points.items) |ep| {
        try queue.append(allocator, ep);
    }

    var head: usize = 0;
    while (head < queue.items.len) {
        const idx = queue.items[head];
        head += 1;
        if (visited.contains(idx)) continue;
        try visited.put(allocator, idx, {});

        if (idx < module.symbols.items.len) {
            module.symbols.items[idx].flags.is_live = true;
        }

        if (deps.get(idx)) |dep_list| {
            for (dep_list.items) |dep_idx| {
                if (!visited.contains(dep_idx)) {
                    try queue.append(allocator, dep_idx);
                }
            }
        }
    }

    // Count dead
    var dead: u32 = 0;
    for (module.symbols.items) |sym| {
        if (!sym.flags.is_live) dead += 1;
    }
    return dead;
}

fn buildDependencyGraph(allocator: std.mem.Allocator, module: *const Ast.Module, deps: *std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32))) std.mem.Allocator.Error!void {
    for (module.declarations.items) |decl| {
        try collectDeclDeps(allocator, decl, deps);
    }
}

fn collectDeclDeps(allocator: std.mem.Allocator, decl: Ast.Decl, deps: *std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32))) std.mem.Allocator.Error!void {
    const name_ref = decl.nameRef();
    if (!name_ref.isValid()) return;
    const sym_idx = name_ref.index();

    var refs: std.ArrayListUnmanaged(u32) = .empty;

    switch (decl) {
        .@"const" => |d| {
            if (d.initializer) |init_expr| try collectExprRefs(allocator, init_expr, &refs);
            if (d.typ) |t| try collectTypeRefs(allocator, t, &refs);
        },
        .override => |d| {
            if (d.initializer) |init_expr| try collectExprRefs(allocator, init_expr, &refs);
            if (d.typ) |t| try collectTypeRefs(allocator, t, &refs);
        },
        .@"var" => |d| {
            if (d.initializer) |init_expr| try collectExprRefs(allocator, init_expr, &refs);
            if (d.typ) |t| try collectTypeRefs(allocator, t, &refs);
        },
        .let => |d| {
            if (d.initializer) |init_expr| try collectExprRefs(allocator, init_expr, &refs);
            if (d.typ) |t| try collectTypeRefs(allocator, t, &refs);
        },
        .function => |d| {
            for (d.parameters.items) |param| try collectTypeRefs(allocator, param.typ, &refs);
            if (d.return_type) |rt| try collectTypeRefs(allocator, rt, &refs);
            if (d.body) |body| try collectStmtRefs(allocator, .{ .compound = body }, &refs);
        },
        .@"struct" => |d| {
            for (d.members.items) |member| try collectTypeRefs(allocator, member.typ, &refs);
        },
        .alias => |d| try collectTypeRefs(allocator, d.typ, &refs),
        .const_assert => {},
    }

    try deps.put(allocator, sym_idx, refs);
}

/// Iteratively collects symbol references from an expression tree using a worklist.
pub fn collectExprRefs(allocator: std.mem.Allocator, expr: Ast.Expr, refs: *std.ArrayListUnmanaged(u32)) std.mem.Allocator.Error!void {
    var stack: std.ArrayListUnmanaged(Ast.Expr) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, expr);

    while (true) {
        const e = stack.pop() orelse break;
        switch (e) {
            .ident => |ie| {
                if (ie.ref.isValid()) try refs.append(allocator, ie.ref.index());
            },
            .binary => |be| {
                try stack.append(allocator, be.right);
                try stack.append(allocator, be.left);
            },
            .unary => |ue| try stack.append(allocator, ue.operand),
            .call => |ce| {
                var i = ce.args.items.len;
                while (i > 0) {
                    i -= 1;
                    try stack.append(allocator, ce.args.items[i]);
                }
                if (ce.func) |f| try stack.append(allocator, f);
            },
            .index => |ie| {
                try stack.append(allocator, ie.idx);
                try stack.append(allocator, ie.base);
            },
            .member => |me| try stack.append(allocator, me.base),
            .paren => |pe| try stack.append(allocator, pe.expr),
            .literal => {},
        }
    }
}

/// Iteratively collects symbol references from a type tree.
fn collectTypeRefs(allocator: std.mem.Allocator, typ: Ast.Type, refs: *std.ArrayListUnmanaged(u32)) std.mem.Allocator.Error!void {
    var current = typ;
    while (true) {
        switch (current) {
            .ident => |t| {
                if (t.ref.isValid()) try refs.append(allocator, t.ref.index());
                break;
            },
            .vec => |t| {
                current = t.elem_type orelse break;
            },
            .mat => |t| {
                current = t.elem_type orelse break;
            },
            .array => |t| {
                if (t.size) |s| try collectExprRefs(allocator, s, refs);
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
    }
}

/// Iteratively collects symbol references from a statement tree using a worklist.
pub fn collectStmtRefs(allocator: std.mem.Allocator, stmt: Ast.Stmt, refs: *std.ArrayListUnmanaged(u32)) std.mem.Allocator.Error!void {
    var stack: std.ArrayListUnmanaged(Ast.Stmt) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, stmt);

    while (true) {
        const s = stack.pop() orelse break;
        switch (s) {
            .compound => |cs| {
                for (cs.stmts.items) |inner| try stack.append(allocator, inner);
            },
            .@"return" => |rs| {
                if (rs.value) |v| try collectExprRefs(allocator, v, refs);
            },
            .@"if" => |is| {
                try collectExprRefs(allocator, is.condition, refs);
                try stack.append(allocator, .{ .compound = is.body });
                if (is.else_branch) |eb| try stack.append(allocator, eb);
            },
            .@"switch" => |ss| {
                try collectExprRefs(allocator, ss.expr, refs);
                for (ss.cases.items) |c| {
                    for (c.selectors.items) |sel| try collectExprRefs(allocator, sel, refs);
                    try stack.append(allocator, .{ .compound = c.body });
                }
            },
            .@"for" => |fs| {
                if (fs.init_stmt) |is| try stack.append(allocator, is);
                if (fs.condition) |c| try collectExprRefs(allocator, c, refs);
                if (fs.update) |u| try stack.append(allocator, u);
                try stack.append(allocator, .{ .compound = fs.body });
            },
            .@"while" => |ws| {
                try collectExprRefs(allocator, ws.condition, refs);
                try stack.append(allocator, .{ .compound = ws.body });
            },
            .loop => |ls| {
                try stack.append(allocator, .{ .compound = ls.body });
                if (ls.continuing) |c| try stack.append(allocator, .{ .compound = c });
            },
            .break_if => |bs| try collectExprRefs(allocator, bs.condition, refs),
            .assign => |as_| {
                try collectExprRefs(allocator, as_.left, refs);
                try collectExprRefs(allocator, as_.right, refs);
            },
            .incr_decr => |ids| try collectExprRefs(allocator, ids.expr, refs),
            .call => |cs| {
                if (cs.call.func) |f| try collectExprRefs(allocator, f, refs);
                for (cs.call.args.items) |arg| try collectExprRefs(allocator, arg, refs);
            },
            .decl => |ds| {
                switch (ds.decl) {
                    .@"const" => |d| {
                        if (d.initializer) |init_expr| try collectExprRefs(allocator, init_expr, refs);
                        if (d.typ) |t| try collectTypeRefs(allocator, t, refs);
                    },
                    .let => |d| {
                        if (d.initializer) |init_expr| try collectExprRefs(allocator, init_expr, refs);
                        if (d.typ) |t| try collectTypeRefs(allocator, t, refs);
                    },
                    .@"var" => |d| {
                        if (d.initializer) |init_expr| try collectExprRefs(allocator, init_expr, refs);
                        if (d.typ) |t| try collectTypeRefs(allocator, t, refs);
                    },
                    else => {},
                }
            },
            .@"break", .@"continue", .discard => {},
        }
    }
}

/// Check if a declaration is live (for use by printer).
pub fn isDeclarationLive(decl: Ast.Decl, symbols: []const Ast.Symbol) bool {
    const ref = decl.nameRef();
    if (ref == .none) {
        // const_assert is always kept
        return true;
    }
    if (!ref.isValid()) return true;
    const idx = ref.index();
    if (idx >= symbols.len) return true;
    return symbols[idx].flags.is_live;
}

// =========================================================================
// Tests
// =========================================================================

const Lexer = @import("Lexer.zig");
const Parser = @import("Parser.zig");

fn parseModule(allocator: std.mem.Allocator, source: [:0]const u8) ?*Ast.Module {
    var tokens = Lexer.tokenize(allocator, source) catch return null;
    defer tokens.deinit(allocator);
    var parser = Parser.init(allocator, source, tokens) catch return null;
    return parser.parse() catch null;
}

test "mark: empty module" {
    var scope = Ast.Scope.init(null);
    var module = Ast.Module.init(&scope, "");
    const dead = try mark(std.testing.allocator, &module);
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

    const dead = try mark(alloc, module);
    try std.testing.expectEqual(@as(u32, 0), dead);

    // All symbols should be live
    for (module.symbols.items) |sym| {
        if (sym.kind == .function) {
            try std.testing.expect(sym.flags.is_live);
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

    const dead = try mark(alloc, module);
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

    const dead = try mark(alloc, module);
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

    const dead = try mark(alloc, module);
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

    _ = try mark(alloc, module);

    // Check that main is live and unused is not
    for (module.declarations.items) |decl| {
        const live = isDeclarationLive(decl, module.symbols.items);
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

    _ = try mark(alloc, module);

    var found_used = false;
    var found_unused = false;
    for (module.declarations.items) |decl| {
        const ref = decl.nameRef();
        if (ref.isValid() and ref.index() < module.symbols.items.len) {
            const name = module.symbols.items[ref.index()].original_name;
            const live = isDeclarationLive(decl, module.symbols.items);
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

    _ = try mark(alloc, module);

    for (module.declarations.items) |decl| {
        const ref = decl.nameRef();
        if (ref.isValid() and ref.index() < module.symbols.items.len) {
            const name = module.symbols.items[ref.index()].original_name;
            const live = isDeclarationLive(decl, module.symbols.items);
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

    _ = try mark(alloc, module);

    for (module.declarations.items) |decl| {
        const ref = decl.nameRef();
        if (ref.isValid() and ref.index() < module.symbols.items.len) {
            const name = module.symbols.items[ref.index()].original_name;
            const live = isDeclarationLive(decl, module.symbols.items);
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

    _ = try mark(alloc, module);

    for (module.declarations.items) |decl| {
        const ref = decl.nameRef();
        if (ref.isValid() and ref.index() < module.symbols.items.len) {
            const name = module.symbols.items[ref.index()].original_name;
            const live = isDeclarationLive(decl, module.symbols.items);
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

    _ = try mark(alloc, module);

    for (module.declarations.items) |decl| {
        const ref = decl.nameRef();
        if (ref.isValid() and ref.index() < module.symbols.items.len) {
            const name = module.symbols.items[ref.index()].original_name;
            const live = isDeclarationLive(decl, module.symbols.items);
            if (std.mem.eql(u8, name, "used")) {
                try std.testing.expect(live);
            } else if (std.mem.eql(u8, name, "unused_binding")) {
                try std.testing.expect(!live);
            }
        }
    }
}

test "collectExprRefs: ident expr" {
    var refs: std.ArrayListUnmanaged(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var ident = Ast.IdentExpr{ .name = "x", .ref = @enumFromInt(5) };
    try collectExprRefs(std.testing.allocator, .{ .ident = &ident }, &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
    try std.testing.expectEqual(@as(u32, 5), refs.items[0]);
}

test "collectExprRefs: invalid ref ignored" {
    var refs: std.ArrayListUnmanaged(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var ident = Ast.IdentExpr{ .name = "x", .ref = .none };
    try collectExprRefs(std.testing.allocator, .{ .ident = &ident }, &refs);

    try std.testing.expectEqual(@as(usize, 0), refs.items.len);
}

test "collectExprRefs: literal expr" {
    var refs: std.ArrayListUnmanaged(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var lit = Ast.LiteralExpr{ .kind = .int_literal, .value = "42" };
    try collectExprRefs(std.testing.allocator, .{ .literal = &lit }, &refs);

    try std.testing.expectEqual(@as(usize, 0), refs.items.len);
}

test "collectTypeRefs: ident type with ref" {
    var refs: std.ArrayListUnmanaged(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var ident = Ast.IdentType{ .name = "MyStruct", .ref = @enumFromInt(3) };
    try collectTypeRefs(std.testing.allocator, .{ .ident = &ident }, &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
    try std.testing.expectEqual(@as(u32, 3), refs.items[0]);
}

test "collectTypeRefs: vec type with elem" {
    var refs: std.ArrayListUnmanaged(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var elem = Ast.IdentType{ .name = "f32" };
    var vec = Ast.VecType{ .size = 3, .elem_type = .{ .ident = &elem } };
    try collectTypeRefs(std.testing.allocator, .{ .vec = &vec }, &refs);

    // f32 has no valid ref, so no refs collected
    try std.testing.expectEqual(@as(usize, 0), refs.items.len);
}

test "collectTypeRefs: array with struct element" {
    var refs: std.ArrayListUnmanaged(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var elem_ident = Ast.IdentType{ .name = "Particle", .ref = @enumFromInt(7) };
    var arr = Ast.ArrayType{ .elem_type = .{ .ident = &elem_ident } };
    try collectTypeRefs(std.testing.allocator, .{ .array = &arr }, &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
    try std.testing.expectEqual(@as(u32, 7), refs.items[0]);
}

test "collectTypeRefs: sampler type" {
    var refs: std.ArrayListUnmanaged(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var sampler = Ast.SamplerType{ .comparison = false };
    try collectTypeRefs(std.testing.allocator, .{ .sampler = &sampler }, &refs);

    try std.testing.expectEqual(@as(usize, 0), refs.items.len);
}

// -------------------------------------------------------------------------
// collectExprRefs: remaining expression types
// -------------------------------------------------------------------------

test "collectExprRefs: binary expr" {
    var refs: std.ArrayListUnmanaged(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var left = Ast.IdentExpr{ .name = "a", .ref = @enumFromInt(1) };
    var right = Ast.IdentExpr{ .name = "b", .ref = @enumFromInt(2) };
    var bin = Ast.BinaryExpr{ .op = .add, .left = .{ .ident = &left }, .right = .{ .ident = &right } };
    try collectExprRefs(std.testing.allocator, .{ .binary = &bin }, &refs);

    try std.testing.expectEqual(@as(usize, 2), refs.items.len);
}

test "collectExprRefs: unary expr" {
    var refs: std.ArrayListUnmanaged(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var operand = Ast.IdentExpr{ .name = "x", .ref = @enumFromInt(1) };
    var un = Ast.UnaryExpr{ .op = .neg, .operand = .{ .ident = &operand } };
    try collectExprRefs(std.testing.allocator, .{ .unary = &un }, &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
}

test "collectExprRefs: call expr" {
    var refs: std.ArrayListUnmanaged(u32) = .empty;
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
    var refs: std.ArrayListUnmanaged(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var base = Ast.IdentExpr{ .name = "arr", .ref = @enumFromInt(1) };
    var idx = Ast.IdentExpr{ .name = "i", .ref = @enumFromInt(2) };
    var index_expr = Ast.IndexExpr{ .base = .{ .ident = &base }, .idx = .{ .ident = &idx } };
    try collectExprRefs(std.testing.allocator, .{ .index = &index_expr }, &refs);

    try std.testing.expectEqual(@as(usize, 2), refs.items.len);
}

test "collectExprRefs: member expr" {
    var refs: std.ArrayListUnmanaged(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var base = Ast.IdentExpr{ .name = "s", .ref = @enumFromInt(1) };
    var mem = Ast.MemberExpr{ .base = .{ .ident = &base }, .member_name = "x" };
    try collectExprRefs(std.testing.allocator, .{ .member = &mem }, &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
}

test "collectExprRefs: paren expr" {
    var refs: std.ArrayListUnmanaged(u32) = .empty;
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
    var refs: std.ArrayListUnmanaged(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var ident = Ast.IdentType{ .name = "f32" }; // builtin, no ref
    try collectTypeRefs(std.testing.allocator, .{ .ident = &ident }, &refs);

    try std.testing.expectEqual(@as(usize, 0), refs.items.len);
}

test "collectTypeRefs: mat type with elem" {
    var refs: std.ArrayListUnmanaged(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var elem = Ast.IdentType{ .name = "MyType", .ref = @enumFromInt(1) };
    var mat = Ast.MatType{ .cols = 4, .rows = 4, .elem_type = .{ .ident = &elem } };
    try collectTypeRefs(std.testing.allocator, .{ .mat = &mat }, &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
}

test "collectTypeRefs: ptr type" {
    var refs: std.ArrayListUnmanaged(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var elem = Ast.IdentType{ .name = "MyType", .ref = @enumFromInt(1) };
    var ptr_type = Ast.PtrType{ .address_space = .function, .elem_type = .{ .ident = &elem } };
    try collectTypeRefs(std.testing.allocator, .{ .ptr = &ptr_type }, &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
}

test "collectTypeRefs: atomic type builtin" {
    var refs: std.ArrayListUnmanaged(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var elem = Ast.IdentType{ .name = "u32" }; // builtin, no ref
    var atomic = Ast.AtomicType{ .elem_type = .{ .ident = &elem } };
    try collectTypeRefs(std.testing.allocator, .{ .atomic = &atomic }, &refs);

    try std.testing.expectEqual(@as(usize, 0), refs.items.len);
}

test "collectTypeRefs: texture type with sampled type" {
    var refs: std.ArrayListUnmanaged(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var sampled = Ast.IdentType{ .name = "MyType", .ref = @enumFromInt(1) };
    var tex = Ast.TextureType{ .kind = .sampled, .dimension = .@"2d", .sampled_type = .{ .ident = &sampled } };
    try collectTypeRefs(std.testing.allocator, .{ .texture = &tex }, &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
}

test "collectTypeRefs: array with size expr" {
    var refs: std.ArrayListUnmanaged(u32) = .empty;
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
    var refs: std.ArrayListUnmanaged(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var value = Ast.IdentExpr{ .name = "x", .ref = @enumFromInt(1) };
    var ret = Ast.ReturnStmt{ .value = .{ .ident = &value } };
    try collectStmtRefs(std.testing.allocator, .{ .@"return" = &ret }, &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
}

test "collectStmtRefs: assign stmt" {
    var refs: std.ArrayListUnmanaged(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var left = Ast.IdentExpr{ .name = "x", .ref = @enumFromInt(0) };
    var right = Ast.IdentExpr{ .name = "y", .ref = @enumFromInt(1) };
    var assign = Ast.AssignStmt{ .op = .simple, .left = .{ .ident = &left }, .right = .{ .ident = &right } };
    try collectStmtRefs(std.testing.allocator, .{ .assign = &assign }, &refs);

    try std.testing.expectEqual(@as(usize, 2), refs.items.len);
}

test "collectStmtRefs: incr_decr stmt" {
    var refs: std.ArrayListUnmanaged(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var expr = Ast.IdentExpr{ .name = "i", .ref = @enumFromInt(0) };
    var incr = Ast.IncrDecrStmt{ .expr = .{ .ident = &expr }, .increment = true };
    try collectStmtRefs(std.testing.allocator, .{ .incr_decr = &incr }, &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
}

test "collectStmtRefs: call stmt" {
    var refs: std.ArrayListUnmanaged(u32) = .empty;
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
    var refs: std.ArrayListUnmanaged(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var cond = Ast.IdentExpr{ .name = "done", .ref = @enumFromInt(0) };
    var break_if = Ast.BreakIfStmt{ .condition = .{ .ident = &cond } };
    try collectStmtRefs(std.testing.allocator, .{ .break_if = &break_if }, &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
}

test "collectStmtRefs: break and continue have no refs" {
    var refs: std.ArrayListUnmanaged(u32) = .empty;
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
    var refs: std.ArrayListUnmanaged(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var value = Ast.IdentExpr{ .name = "x", .ref = @enumFromInt(1) };
    var ret = Ast.ReturnStmt{ .value = .{ .ident = &value } };
    var stmts_buf = [_]Ast.Stmt{.{ .@"return" = &ret }};
    var compound = Ast.CompoundStmt{ .stmts = .{ .items = &stmts_buf, .capacity = 1 } };
    try collectStmtRefs(std.testing.allocator, .{ .compound = &compound }, &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
}

test "collectStmtRefs: if stmt with else" {
    var refs: std.ArrayListUnmanaged(u32) = .empty;
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
    var refs: std.ArrayListUnmanaged(u32) = .empty;
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
    var refs: std.ArrayListUnmanaged(u32) = .empty;
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
    var refs: std.ArrayListUnmanaged(u32) = .empty;
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
    var refs: std.ArrayListUnmanaged(u32) = .empty;
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
    var refs: std.ArrayListUnmanaged(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var init_val = Ast.IdentExpr{ .name = "y", .ref = @enumFromInt(1) };
    var const_decl = Ast.ConstDecl{ .name = @enumFromInt(0), .initializer = .{ .ident = &init_val } };
    var decl_stmt = Ast.DeclStmt{ .decl = .{ .@"const" = &const_decl } };
    try collectStmtRefs(std.testing.allocator, .{ .decl = &decl_stmt }, &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
}

test "collectStmtRefs: decl stmt let" {
    var refs: std.ArrayListUnmanaged(u32) = .empty;
    defer refs.deinit(std.testing.allocator);

    var init_val = Ast.IdentExpr{ .name = "y", .ref = @enumFromInt(1) };
    var let_decl = Ast.LetDecl{ .name = @enumFromInt(0), .initializer = .{ .ident = &init_val } };
    var decl_stmt = Ast.DeclStmt{ .decl = .{ .let = &let_decl } };
    try collectStmtRefs(std.testing.allocator, .{ .decl = &decl_stmt }, &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
}

test "collectStmtRefs: decl stmt var with type and init" {
    var refs: std.ArrayListUnmanaged(u32) = .empty;
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
    var refs: std.ArrayListUnmanaged(u32) = .empty;
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

    var deps: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)) = .empty;
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

    var deps: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)) = .empty;
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

    var deps: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)) = .empty;
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

    var deps: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)) = .empty;
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

    var deps: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)) = .empty;
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

    var deps: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)) = .empty;
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

    var deps: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)) = .empty;
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

    var deps: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)) = .empty;
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
    var lit = Ast.LiteralExpr{ .kind = .true_literal, .value = "true" };
    var decl = Ast.ConstAssertDecl{ .expr = .{ .literal = &lit } };
    try std.testing.expect(isDeclarationLive(.{ .const_assert = &decl }, &.{}));
}

test "isDeclarationLive: let decl" {
    var symbols = [_]Ast.Symbol{
        .{ .original_name = "x", .kind = .let, .flags = .{ .is_live = true } },
    };
    var let_decl = Ast.LetDecl{ .name = @enumFromInt(0) };
    try std.testing.expect(isDeclarationLive(.{ .let = &let_decl }, &symbols));
}

test "isDeclarationLive: out of bounds ref kept" {
    var const_decl = Ast.ConstDecl{ .name = @enumFromInt(999) };
    try std.testing.expect(isDeclarationLive(.{ .@"const" = &const_decl }, &.{}));
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

    _ = try mark(alloc, module);

    var found_dead = false;
    var found_used = false;
    var found_main = false;
    for (module.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.original_name, "dead")) {
            found_dead = true;
            try std.testing.expect(!sym.flags.is_live);
        } else if (std.mem.eql(u8, sym.original_name, "used")) {
            found_used = true;
            try std.testing.expect(sym.flags.is_live);
        } else if (std.mem.eql(u8, sym.original_name, "main")) {
            found_main = true;
            try std.testing.expect(sym.flags.is_live);
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

    _ = try mark(alloc, module);

    for (module.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.original_name, "a") or
            std.mem.eql(u8, sym.original_name, "b") or
            std.mem.eql(u8, sym.original_name, "c") or
            std.mem.eql(u8, sym.original_name, "main"))
        {
            try std.testing.expect(sym.flags.is_live);
        } else if (std.mem.eql(u8, sym.original_name, "unused")) {
            try std.testing.expect(!sym.flags.is_live);
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

    const dead = try mark(alloc, module);

    for (module.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.original_name, "Data") or
            std.mem.eql(u8, sym.original_name, "Wrapper") or
            std.mem.eql(u8, sym.original_name, "helper") or
            std.mem.eql(u8, sym.original_name, "main"))
        {
            try std.testing.expect(sym.flags.is_live);
        } else if (std.mem.eql(u8, sym.original_name, "unused_const") or
            std.mem.eql(u8, sym.original_name, "unused_helper"))
        {
            try std.testing.expect(!sym.flags.is_live);
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

    // Then try mark with failing allocator
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const result = mark(failing.allocator(), module);
    try std.testing.expect(result == error.OutOfMemory);
}
