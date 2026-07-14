//! Multi-listener AST walker — one traversal of a module fans out to N
//! subscribed listeners. When many rules each want to observe every node,
//! `MultiVisitor.walk` pays the traversal cost once instead of once per rule.
//!
//! Which rules ride the shared walk is a *taxonomy*, not a migration
//! backlog. A rule subscribes a `listener` when it is a **pure per-node
//! observer** — it reacts to each `Ast.Expr` / `Ast.Stmt` / `Ast.Decl` in
//! isolation, with no context beyond the node itself (e.g. `no-self-assign`,
//! `no-lonely-if`, `no-redundant-casts`). Those, and only those, dedup onto
//! this walk. Everything else keeps its own `run` pass, because the shared
//! node-fanout is the wrong shape for it:
//!   - **Table scans** walk `module.symbols` / a `MinifyEstimator`, not the
//!     tree (`no-unused-vars`, `minify/*`, `naming-convention`).
//!   - **Subtree folds** reduce a whole function body to one number and read
//!     best as direct recursion — `complexity` (`1 + decisions`), `max-depth`
//!     (`1 + max(children)`). A fanout would also over-count, since these
//!     deliberately weight some node positions and ignore others.
//!   - **Block-sequential** rules need statement *order within a block*
//!     (`no-unreachable`'s "after a terminator"), which per-node events drop.
//!   - **Context-sensitive observers** exempt whole regions the generic walk
//!     still visits — `no-magic-numbers` skips `const` initializers,
//!     attribute args and switch selectors, so a plain `on_expr` would
//!     false-positive.
//! Adding enter/exit events purely to force a fold onto this walk would be
//! machinery for one beneficiary; the recursive form is the clearer home.
//!
//! Traversal shape:
//!   - Expressions: iterative, stack-based (deeply nested shaders don't
//!     blow the host stack). Children are pushed right-then-left so the
//!     pop order yields document order (left-then-right).
//!   - Statements / declarations: recursive (bodies are not deeply nested).
//!
//! Dispatch order:
//!   - For each visited node, all listeners' callbacks fire (in slice
//!     order) BEFORE descending into children, so listeners see nodes in
//!     document order (parent before children, left sibling before right).
//!
//! All callbacks are optional and propagate `Allocator.Error` — rules
//! that can't fail simply use a wrapper that returns `error{}!void`-style
//! noop. `ctx` is type-erased; each listener owns the cast back to its
//! concrete state type.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("../Ast.zig");

/// One subscriber to the visitor. All callbacks are optional; `null`
/// means "don't fire this event for me". The visitor passes back the
/// listener's own `ctx` pointer, type-erased.
pub const Listener = struct {
    ctx: *anyopaque,
    on_expr: ?*const fn (*anyopaque, Ast.Expr) Allocator.Error!void = null,
    on_stmt: ?*const fn (*anyopaque, Ast.Stmt) Allocator.Error!void = null,
    on_decl: ?*const fn (*anyopaque, Ast.Decl) Allocator.Error!void = null,
};

/// Walk every declaration in `module` in document order, firing each
/// listener's callbacks. Empty `listeners` is a no-op.
pub fn walk(
    arena: Allocator,
    module: *const Ast.Module,
    listeners: []const Listener,
) Allocator.Error!void {
    if (listeners.len == 0) return;
    for (module.declarations.items) |decl| try walkDecl(arena, decl, listeners);
}

fn walkDecl(arena: Allocator, decl: Ast.Decl, listeners: []const Listener) Allocator.Error!void {
    for (listeners) |l| if (l.on_decl) |cb| try cb(l.ctx, decl);

    switch (decl) {
        .@"const" => |d| {
            if (d.initializer) |init_expr| try walkExpr(arena, init_expr, listeners);
        },
        .override => |d| {
            for (d.attributes.items) |attr| for (attr.args.items) |a| try walkExpr(arena, a, listeners);
            if (d.initializer) |init_expr| try walkExpr(arena, init_expr, listeners);
        },
        .@"var" => |d| {
            for (d.attributes.items) |attr| for (attr.args.items) |a| try walkExpr(arena, a, listeners);
            if (d.initializer) |init_expr| try walkExpr(arena, init_expr, listeners);
        },
        .let => |d| {
            if (d.initializer) |init_expr| try walkExpr(arena, init_expr, listeners);
        },
        .function => |fd| {
            for (fd.attributes.items) |attr| for (attr.args.items) |a| try walkExpr(arena, a, listeners);
            if (fd.body) |body| try walkCompound(arena, body, listeners);
        },
        .const_assert => |d| try walkExpr(arena, d.expr, listeners),
        .@"struct", .alias => {},
    }
}

fn walkCompound(
    arena: Allocator,
    compound: *Ast.CompoundStmt,
    listeners: []const Listener,
) Allocator.Error!void {
    for (compound.stmts.items) |stmt| try walkStmt(arena, stmt, listeners);
}

fn walkStmt(arena: Allocator, stmt: Ast.Stmt, listeners: []const Listener) Allocator.Error!void {
    for (listeners) |l| if (l.on_stmt) |cb| try cb(l.ctx, stmt);

    switch (stmt) {
        .compound => |s| try walkCompound(arena, s, listeners),
        .@"return" => |s| if (s.value) |v| try walkExpr(arena, v, listeners),
        .@"if" => |s| {
            try walkExpr(arena, s.condition, listeners);
            try walkCompound(arena, s.body, listeners);
            if (s.else_branch) |eb| try walkStmt(arena, eb, listeners);
        },
        .@"switch" => |s| {
            try walkExpr(arena, s.expr, listeners);
            for (s.cases.items) |c| {
                for (c.selectors.items) |sel| try walkExpr(arena, sel, listeners);
                try walkCompound(arena, c.body, listeners);
            }
        },
        .@"for" => |s| {
            if (s.init_stmt) |is| try walkStmt(arena, is, listeners);
            if (s.condition) |c| try walkExpr(arena, c, listeners);
            if (s.update) |u| try walkStmt(arena, u, listeners);
            try walkCompound(arena, s.body, listeners);
        },
        .@"while" => |s| {
            try walkExpr(arena, s.condition, listeners);
            try walkCompound(arena, s.body, listeners);
        },
        .loop => |s| {
            try walkCompound(arena, s.body, listeners);
            if (s.continuing) |c| try walkCompound(arena, c, listeners);
        },
        .break_if => |s| try walkExpr(arena, s.condition, listeners),
        .assign => |s| {
            try walkExpr(arena, s.left, listeners);
            try walkExpr(arena, s.right, listeners);
        },
        .incr_decr => |s| try walkExpr(arena, s.expr, listeners),
        .call => |s| {
            if (s.call.func) |f| try walkExpr(arena, f, listeners);
            for (s.call.args.items) |a| try walkExpr(arena, a, listeners);
        },
        .decl => |s| try walkDecl(arena, s.decl, listeners),
        .@"break", .@"continue", .discard => {},
    }
}

fn walkExpr(arena: Allocator, root: Ast.Expr, listeners: []const Listener) Allocator.Error!void {
    var stack: std.ArrayList(Ast.Expr) = .empty;
    defer stack.deinit(arena);
    try stack.append(arena, root);

    while (stack.pop()) |e| {
        for (listeners) |l| if (l.on_expr) |cb| try cb(l.ctx, e);
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

// Tests live in `tests/multi_visitor_test.zig` so they can import the
// wgslender package (Lexer / Parser are outside this file's module path).
