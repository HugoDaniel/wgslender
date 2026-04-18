//! Pass-2 AST visitor.
//!
//! Shared by `Parser` (after its Pass-1 parse) and `CstLower` (after its
//! Pass-1 CST→AST lowering). Walks a fully-built `Ast.Module`, binding
//! identifier references to symbols, incrementing `use_count`, and marking
//! expression purity in post-order.
//!
//! All behavior here was moved verbatim from `Parser.zig` — any drift would
//! break the equivalence gate between the two front-ends.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Parser = @import("Parser.zig");

/// Everything Pass 2 needs to read or mutate. The caller owns all slices
/// and lists; `visit` never allocates into them (it only mutates in place:
/// `use_count`, ident `ref`, expression purity flags).
pub const Context = struct {
    arena: Allocator,
    /// Symbol table slice. `visit` increments `use_count` in place.
    symbols: []Ast.Symbol,
    /// DFS append-order list of non-root scopes, produced by Pass 1.
    scopes_in_order: []*Ast.Scope,
    /// Current scope cursor during visit. Caller initializes to
    /// `module.scope`; `visit` walks into/out of it via `enterNextScope` /
    /// `exitScope`.
    scope: *Ast.Scope,
    scope_index: u32 = 0,
    /// Byte offset of the identifier currently being resolved. Used by
    /// `lookupSymbol` to enforce text-order visibility inside function
    /// bodies (module-scope lookups ignore it).
    current_loc: u32 = 0,
    /// Diagnostics bucket; `visit` appends use-before-declaration errors.
    errors: *std.ArrayListUnmanaged(Parser.ParseError),
    /// Upper bound on worklist iterations in stmt/expr visits. Parser
    /// supplies `token_tags.len * 2`; CstLower supplies an equivalent
    /// bound derived from CST node count. Purely a safety guard.
    safety_budget: usize,
};

pub fn visit(ctx: *Context, module: *Ast.Module) void {
    ctx.scope = module.scope;
    ctx.scope_index = 0;

    for (module.declarations.items) |decl| {
        visitDecl(ctx, decl);
    }
}

fn visitDecl(ctx: *Context, d: Ast.Decl) void {
    switch (d) {
        .@"const" => |decl| {
            if (decl.typ) |t| visitType(ctx, t);
            if (decl.initializer) |init_expr| decl.initializer = visitExpr(ctx, init_expr);
        },
        .override => |decl| {
            if (decl.typ) |t| visitType(ctx, t);
            if (decl.initializer) |init_expr| decl.initializer = visitExpr(ctx, init_expr);
        },
        .@"var" => |decl| {
            if (decl.typ) |t| visitType(ctx, t);
            if (decl.initializer) |init_expr| decl.initializer = visitExpr(ctx, init_expr);
        },
        .let => |decl| {
            if (decl.typ) |t| visitType(ctx, t);
            if (decl.initializer) |init_expr| decl.initializer = visitExpr(ctx, init_expr);
        },
        .function => |decl| visitFunctionDecl(ctx, decl),
        .@"struct" => |decl| {
            for (decl.members.items) |member| {
                visitType(ctx, member.typ);
            }
        },
        .alias => |decl| visitType(ctx, decl.typ),
        .const_assert => |decl| decl.expr = visitExpr(ctx, decl.expr),
    }
}

fn visitFunctionDecl(ctx: *Context, decl: *Ast.FunctionDecl) void {
    for (decl.parameters.items) |param| {
        visitType(ctx, param.typ);
    }
    if (decl.return_type) |rt| visitType(ctx, rt);
    enterNextScope(ctx);
    if (decl.body) |body| visitCompoundStmt(ctx, body);
    exitScope(ctx);
}

const Work = union(enum) {
    stmt: Ast.Stmt,
    compound: *Ast.CompoundStmt,
    exit_scope,
};

fn visitCompoundStmt(ctx: *Context, stmt: *Ast.CompoundStmt) void {
    var stack: std.ArrayListUnmanaged(Work) = .empty;
    defer stack.deinit(ctx.arena);
    stack.append(ctx.arena, .{ .compound = stmt }) catch return;

    for (0..ctx.safety_budget) |_| {
        const work = stack.pop() orelse break;
        switch (work) {
            .exit_scope => exitScope(ctx),
            .compound => |body| {
                enterNextScope(ctx);
                stack.append(ctx.arena, .exit_scope) catch {};
                var i = body.stmts.items.len;
                while (i > 0) {
                    i -= 1;
                    stack.append(ctx.arena, .{ .stmt = body.stmts.items[i] }) catch {};
                }
            },
            .stmt => |s| processOneStmt(ctx, s, &stack),
        }
    } else unreachable;
}

/// Process a single statement, pushing child work items onto the stack.
/// Expression visits are done inline (already iterative).
fn processOneStmt(ctx: *Context, s: Ast.Stmt, stack: *std.ArrayListUnmanaged(Work)) void {
    switch (s) {
        .compound => |stmt| stack.append(ctx.arena, .{ .compound = stmt }) catch {},
        .@"return" => |stmt| {
            if (stmt.value) |v| stmt.value = visitExpr(ctx, v);
        },
        .@"if" => |stmt| {
            stmt.condition = visitExpr(ctx, stmt.condition);
            // Push else branch first (processed after body), then body
            if (stmt.else_branch) |eb| stack.append(ctx.arena, .{ .stmt = eb }) catch {};
            stack.append(ctx.arena, .{ .compound = stmt.body }) catch {};
        },
        .@"switch" => |stmt| {
            stmt.expr = visitExpr(ctx, stmt.expr);
            // Push case bodies in reverse order
            var i = stmt.cases.items.len;
            while (i > 0) {
                i -= 1;
                const c = &stmt.cases.items[i];
                stack.append(ctx.arena, .{ .compound = c.body }) catch {};
            }
            // Visit selectors inline
            for (stmt.cases.items) |*c| {
                for (c.selectors.items, 0..) |sel, j| {
                    c.selectors.items[j] = visitExpr(ctx, sel);
                }
            }
        },
        .@"for" => |stmt| {
            // For has its own scope wrapping init/condition/update/body
            enterNextScope(ctx);
            if (stmt.init_stmt) |is| processOneStmt(ctx, is, stack);
            if (stmt.condition) |cond| stmt.condition = visitExpr(ctx, cond);
            if (stmt.update) |upd| processOneStmt(ctx, upd, stack);
            // Push exit_scope (for-scope), then body (which adds its own scope)
            stack.append(ctx.arena, .exit_scope) catch {};
            stack.append(ctx.arena, .{ .compound = stmt.body }) catch {};
        },
        .@"while" => |stmt| {
            stmt.condition = visitExpr(ctx, stmt.condition);
            stack.append(ctx.arena, .{ .compound = stmt.body }) catch {};
        },
        .loop => |stmt| {
            if (stmt.continuing) |c| stack.append(ctx.arena, .{ .compound = c }) catch {};
            stack.append(ctx.arena, .{ .compound = stmt.body }) catch {};
        },
        .break_if => |stmt| {
            stmt.condition = visitExpr(ctx, stmt.condition);
        },
        .assign => |stmt| {
            stmt.left = visitExpr(ctx, stmt.left);
            stmt.right = visitExpr(ctx, stmt.right);
        },
        .incr_decr => |stmt| {
            stmt.expr = visitExpr(ctx, stmt.expr);
        },
        .call => |stmt| {
            if (stmt.call.func) |f| stmt.call.func = visitExpr(ctx, f);
            if (stmt.call.template_type) |tt| visitType(ctx, tt);
            for (stmt.call.args.items, 0..) |arg, j| {
                stmt.call.args.items[j] = visitExpr(ctx, arg);
            }
        },
        .decl => |stmt| visitDecl(ctx, stmt.decl),
        .@"break", .@"continue", .discard => {},
    }
}

/// Iteratively visits an expression tree using a two-phase worklist.
/// Pushes mark(e) before children so purity marking happens in post-order.
pub fn visitExpr(ctx: *Context, e: Ast.Expr) Ast.Expr {
    const ExprWork = union(enum) {
        visit: Ast.Expr,
        mark: Ast.Expr,
    };

    var stack: std.ArrayListUnmanaged(ExprWork) = .empty;
    defer stack.deinit(ctx.arena);
    stack.append(ctx.arena, .{ .visit = e }) catch return e;

    for (0..ctx.safety_budget) |_| {
        const work = stack.pop() orelse break;
        switch (work) {
            .mark => |me| Ast.markExprPurity(me, ctx.symbols),
            .visit => |ve| {
                // Push mark first (popped last = post-order)
                stack.append(ctx.arena, .{ .mark = ve }) catch {};

                switch (ve) {
                    .ident => |expr| {
                        ctx.current_loc = expr.loc;
                        if (lookupSymbol(ctx, expr.name)) |ref| {
                            expr.ref = ref;
                            if (ref.isValid()) {
                                const idx = ref.index();
                                if (idx < ctx.symbols.len) {
                                    ctx.symbols[idx].use_count += 1;
                                }
                            }
                        } else if (lookupSymbolAnyLoc(ctx, expr.name)) |ref| {
                            const msg = std.fmt.allocPrint(ctx.arena, "'{s}' is used before its declaration", .{expr.name}) catch "identifier used before declaration";
                            ctx.errors.append(ctx.arena, .{ .message = msg, .pos = expr.loc, .code = "E0102" }) catch {};
                            expr.ref = ref;
                        }
                    },
                    .literal => {},
                    .binary => |expr| {
                        stack.append(ctx.arena, .{ .visit = expr.right }) catch {};
                        stack.append(ctx.arena, .{ .visit = expr.left }) catch {};
                    },
                    .unary => |expr| {
                        stack.append(ctx.arena, .{ .visit = expr.operand }) catch {};
                    },
                    .call => |expr| {
                        var i = expr.args.items.len;
                        while (i > 0) {
                            i -= 1;
                            stack.append(ctx.arena, .{ .visit = expr.args.items[i] }) catch {};
                        }
                        if (expr.template_type) |tt| visitType(ctx, tt);
                        if (expr.func) |f| stack.append(ctx.arena, .{ .visit = f }) catch {};
                    },
                    .index => |expr| {
                        stack.append(ctx.arena, .{ .visit = expr.idx }) catch {};
                        stack.append(ctx.arena, .{ .visit = expr.base }) catch {};
                    },
                    .member => |expr| {
                        stack.append(ctx.arena, .{ .visit = expr.base }) catch {};
                    },
                    .paren => |expr| {
                        stack.append(ctx.arena, .{ .visit = expr.expr }) catch {};
                    },
                }
            },
        }
    } else unreachable;
    return e;
}

/// Iteratively visits a type, following single-child chains.
pub fn visitType(ctx: *Context, t: Ast.Type) void {
    var current = t;
    for (0..32) |_| {
        switch (current) {
            .ident => |typ| {
                ctx.current_loc = 0; // Types don't have text-order restrictions at module scope
                if (lookupSymbol(ctx, typ.name)) |ref| {
                    typ.ref = ref;
                    if (ref.isValid()) {
                        const idx = ref.index();
                        if (idx < ctx.symbols.len) {
                            ctx.symbols[idx].use_count += 1;
                        }
                    }
                }
                break;
            },
            .vec => |typ| current = typ.elem_type orelse break,
            .mat => |typ| current = typ.elem_type orelse break,
            .array => |typ| {
                if (typ.size) |s| _ = visitExpr(ctx, s);
                current = typ.elem_type orelse break;
            },
            .ptr => |typ| current = typ.elem_type,
            .atomic => |typ| current = typ.elem_type,
            .sampler => break,
            .texture => |typ| current = typ.sampled_type orelse break,
        }
    } else unreachable;
}

fn lookupSymbol(ctx: *const Context, name: []const u8) ?Ast.SymbolIndex {
    var scope_iter: ?*Ast.Scope = ctx.scope;
    while (scope_iter) |s| {
        if (s.members.get(name)) |member| {
            // Module scope (no parent) is always visible.
            // Local symbols visible only if declared before current_loc.
            // During parse pass (current_loc == 0), allow all.
            if (s.parent == null or ctx.current_loc == 0 or member.loc < ctx.current_loc) {
                return member.ref;
            }
        }
        scope_iter = s.parent;
    }
    return null;
}

/// Like lookupSymbol but ignores text-order constraints.
/// Used to distinguish "use before declaration" from "truly undefined".
fn lookupSymbolAnyLoc(ctx: *const Context, name: []const u8) ?Ast.SymbolIndex {
    var scope_iter: ?*Ast.Scope = ctx.scope;
    while (scope_iter) |s| {
        if (s.members.get(name)) |member| {
            return member.ref;
        }
        scope_iter = s.parent;
    }
    return null;
}

fn enterNextScope(ctx: *Context) void {
    if (ctx.scope_index < ctx.scopes_in_order.len) {
        ctx.scope = ctx.scopes_in_order[ctx.scope_index];
        ctx.scope_index += 1;
    }
}

fn exitScope(ctx: *Context) void {
    if (ctx.scope.parent) |p| ctx.scope = p;
}
