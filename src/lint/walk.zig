//! Lightweight AST walkers used by lint rules. Iterative, non-recursive
//! where practical so deeply nested shaders don't blow the stack.
//!
//! This is a read-only companion to `AstVisit.zig` (which does pass-2
//! symbol binding). Lint rules don't want to mutate use_count or bind
//! references — they only want to observe nodes. These helpers keep the
//! observation path separate.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("../Ast.zig");

/// Visit every expression reachable from `module` (statement exprs, decl
/// initializers, attribute args, etc.) in document order, calling `cb`
/// with user `state`. The callback receives pointers to the actual AST
/// nodes so it can inspect spans/locations without re-walking.
pub fn walkExprs(
    arena: Allocator,
    module: *const Ast.Module,
    state: anytype,
    comptime cb: fn (@TypeOf(state), Ast.Expr) void,
) Allocator.Error!void {
    for (module.declarations.items) |decl| try walkDeclExprs(arena, decl, state, cb);
}

fn walkDeclExprs(
    arena: Allocator,
    decl: Ast.Decl,
    state: anytype,
    comptime cb: fn (@TypeOf(state), Ast.Expr) void,
) Allocator.Error!void {
    switch (decl) {
        .@"const" => |d| {
            if (d.initializer) |init_expr| try walkExprTree(arena, init_expr, state, cb);
        },
        .override => |d| {
            for (d.attributes.items) |attr| for (attr.args.items) |a| try walkExprTree(arena, a, state, cb);
            if (d.initializer) |init_expr| try walkExprTree(arena, init_expr, state, cb);
        },
        .@"var" => |d| {
            for (d.attributes.items) |attr| for (attr.args.items) |a| try walkExprTree(arena, a, state, cb);
            if (d.initializer) |init_expr| try walkExprTree(arena, init_expr, state, cb);
        },
        .let => |d| {
            if (d.initializer) |init_expr| try walkExprTree(arena, init_expr, state, cb);
        },
        .function => |fd| {
            for (fd.attributes.items) |attr| for (attr.args.items) |a| try walkExprTree(arena, a, state, cb);
            if (fd.body) |body| try walkCompoundExprs(arena, body, state, cb);
        },
        .@"struct", .alias, .const_assert => {
            if (decl == .const_assert) try walkExprTree(arena, decl.const_assert.expr, state, cb);
        },
    }
}

fn walkCompoundExprs(
    arena: Allocator,
    compound: *Ast.CompoundStmt,
    state: anytype,
    comptime cb: fn (@TypeOf(state), Ast.Expr) void,
) Allocator.Error!void {
    for (compound.stmts.items) |stmt| try walkStmtExprs(arena, stmt, state, cb);
}

fn walkStmtExprs(
    arena: Allocator,
    stmt: Ast.Stmt,
    state: anytype,
    comptime cb: fn (@TypeOf(state), Ast.Expr) void,
) Allocator.Error!void {
    switch (stmt) {
        .compound => |s| try walkCompoundExprs(arena, s, state, cb),
        .@"return" => |s| if (s.value) |v| try walkExprTree(arena, v, state, cb),
        .@"if" => |s| {
            try walkExprTree(arena, s.condition, state, cb);
            try walkCompoundExprs(arena, s.body, state, cb);
            if (s.else_branch) |eb| try walkStmtExprs(arena, eb, state, cb);
        },
        .@"switch" => |s| {
            try walkExprTree(arena, s.expr, state, cb);
            for (s.cases.items) |c| {
                for (c.selectors.items) |sel| try walkExprTree(arena, sel, state, cb);
                try walkCompoundExprs(arena, c.body, state, cb);
            }
        },
        .@"for" => |s| {
            if (s.init_stmt) |is| try walkStmtExprs(arena, is, state, cb);
            if (s.condition) |c| try walkExprTree(arena, c, state, cb);
            if (s.update) |u| try walkStmtExprs(arena, u, state, cb);
            try walkCompoundExprs(arena, s.body, state, cb);
        },
        .@"while" => |s| {
            try walkExprTree(arena, s.condition, state, cb);
            try walkCompoundExprs(arena, s.body, state, cb);
        },
        .loop => |s| {
            try walkCompoundExprs(arena, s.body, state, cb);
            if (s.continuing) |c| try walkCompoundExprs(arena, c, state, cb);
        },
        .break_if => |s| try walkExprTree(arena, s.condition, state, cb),
        .assign => |s| {
            try walkExprTree(arena, s.left, state, cb);
            try walkExprTree(arena, s.right, state, cb);
        },
        .incr_decr => |s| try walkExprTree(arena, s.expr, state, cb),
        .call => |s| {
            if (s.call.func) |f| try walkExprTree(arena, f, state, cb);
            for (s.call.args.items) |a| try walkExprTree(arena, a, state, cb);
        },
        .decl => |s| try walkDeclExprs(arena, s.decl, state, cb),
        .@"break", .@"continue", .discard => {},
    }
}

fn walkExprTree(
    arena: Allocator,
    root: Ast.Expr,
    state: anytype,
    comptime cb: fn (@TypeOf(state), Ast.Expr) void,
) Allocator.Error!void {
    var stack: std.ArrayListUnmanaged(Ast.Expr) = .empty;
    defer stack.deinit(arena);
    try stack.append(arena, root);

    while (stack.pop()) |e| {
        cb(state, e);
        switch (e) {
            .binary => |b| {
                try stack.append(arena, b.right);
                try stack.append(arena, b.left);
            },
            .unary => |u| try stack.append(arena, u.operand),
            .call => |c| {
                if (c.func) |f| try stack.append(arena, f);
                for (c.args.items) |a| try stack.append(arena, a);
            },
            .index => |i| {
                try stack.append(arena, i.idx);
                try stack.append(arena, i.base);
            },
            .member => |m| try stack.append(arena, m.base),
            .paren => |p| try stack.append(arena, p.expr),
            .ident, .literal => {},
        }
    }
}

/// Visit every statement (flat, not just top-level) reachable from a
/// function body. Useful for rules that care about local-decl shapes.
pub fn walkFunctionStmts(
    arena: Allocator,
    fd: *const Ast.FunctionDecl,
    state: anytype,
    comptime cb: fn (@TypeOf(state), Ast.Stmt) void,
) Allocator.Error!void {
    const body = fd.body orelse return;
    try walkCompoundStmts(arena, body, state, cb);
}

fn walkCompoundStmts(
    arena: Allocator,
    compound: *Ast.CompoundStmt,
    state: anytype,
    comptime cb: fn (@TypeOf(state), Ast.Stmt) void,
) Allocator.Error!void {
    for (compound.stmts.items) |stmt| {
        cb(state, stmt);
        switch (stmt) {
            .compound => |s| try walkCompoundStmts(arena, s, state, cb),
            .@"if" => |s| {
                try walkCompoundStmts(arena, s.body, state, cb);
                if (s.else_branch) |eb| switch (eb) {
                    .compound => |ec| try walkCompoundStmts(arena, ec, state, cb),
                    else => cb(state, eb),
                };
            },
            .@"switch" => |s| for (s.cases.items) |c| try walkCompoundStmts(arena, c.body, state, cb),
            .@"for" => |s| try walkCompoundStmts(arena, s.body, state, cb),
            .@"while" => |s| try walkCompoundStmts(arena, s.body, state, cb),
            .loop => |s| {
                try walkCompoundStmts(arena, s.body, state, cb);
                if (s.continuing) |c| try walkCompoundStmts(arena, c, state, cb);
            },
            else => {},
        }
    }
}
