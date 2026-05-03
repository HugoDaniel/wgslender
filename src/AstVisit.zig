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
const UseCounts = @import("UseCounts.zig");
const constants = @import("constants.zig");

/// Direction of a subtree walk.
///
/// `.add` — today's behavior: resolve idents against scopes, set `ref`,
/// increment `symbols[ref].use_count`, emit `E0102` on misresolution,
/// mark expression purity in post-order.
///
/// `.sub` — read-only on scopes/errors. Walks a subtree whose idents are
/// ALREADY bound (`ref` set by a previous Pass 2) and DECREMENTS
/// `symbols[ref].use_count` by one per resolved reference. No lookup, no
/// error emission, no purity marking — the subtree is about to be
/// discarded from the module.
///
/// Used by `Incremental.reparse`'s hot path to apply a targeted delta
/// when a subtree is spliced out and a new one spliced in, avoiding a
/// whole-module revisit.
pub const Mode = enum { add, sub };

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
    /// Direction of the walk (see `Mode` doc comment). Default `.add`
    /// preserves every pre-existing caller's behavior byte-for-byte.
    mode: Mode = .add,
    /// Optional side-table mirror of `symbols[idx].use_count`. When
    /// non-null, every increment/decrement on the field is mirrored on
    /// the matching slot here. B.M1 of the Symbol-immutability arc:
    /// production paths leave this null, so observable behavior is
    /// unchanged; tests opt in to verify the side-table tracks the
    /// field exactly. Bounds and validity guards inside `UseCounts`
    /// match the field-side guards, so a mirrored call is a strict
    /// no-op whenever the field-side write is.
    use_counts: ?*UseCounts = null,
};

pub fn visit(ctx: *Context, module: *Ast.Module) error{OutOfMemory}!void {
    ctx.scope = module.scope;
    ctx.scope_index = 0;

    for (module.declarations.items) |decl| {
        try visitDecl(ctx, decl);
    }
}

fn visitDecl(ctx: *Context, d: Ast.Decl) error{OutOfMemory}!void {
    switch (d) {
        .@"const" => |decl| {
            if (decl.typ) |t| try visitType(ctx, t);
            if (decl.initializer) |init_expr| decl.initializer = try visitExpr(ctx, init_expr);
        },
        .override => |decl| {
            try visitAttributes(ctx, decl.attributes.items);
            if (decl.typ) |t| try visitType(ctx, t);
            if (decl.initializer) |init_expr| decl.initializer = try visitExpr(ctx, init_expr);
        },
        .@"var" => |decl| {
            try visitAttributes(ctx, decl.attributes.items);
            if (decl.typ) |t| try visitType(ctx, t);
            if (decl.initializer) |init_expr| decl.initializer = try visitExpr(ctx, init_expr);
        },
        .let => |decl| {
            if (decl.typ) |t| try visitType(ctx, t);
            if (decl.initializer) |init_expr| decl.initializer = try visitExpr(ctx, init_expr);
        },
        .function => |decl| try visitFunctionDecl(ctx, decl),
        .@"struct" => |decl| {
            for (decl.members.items) |member| {
                try visitAttributes(ctx, member.attributes.items);
                try visitType(ctx, member.typ);
            }
        },
        .alias => |decl| try visitType(ctx, decl.typ),
        .const_assert => |decl| decl.expr = try visitExpr(ctx, decl.expr),
    }
}

fn visitFunctionDecl(ctx: *Context, decl: *Ast.FunctionDecl) error{OutOfMemory}!void {
    try visitAttributes(ctx, decl.attributes.items);
    for (decl.parameters.items) |param| {
        try visitAttributes(ctx, param.attributes.items);
        try visitType(ctx, param.typ);
    }
    if (decl.return_type) |rt| try visitType(ctx, rt);
    try visitAttributes(ctx, decl.return_attr.items);
    enterNextScope(ctx);
    if (decl.body) |body| try visitCompoundStmt(ctx, body);
    exitScope(ctx);
}

/// Walk attribute args as Pass 2 expressions, but only for attributes
/// whose args are user-symbol references (per `Ast.attributeArgsResolveSymbols`).
/// Enum-keyword attrs (`@builtin`, `@interpolate`, `@diagnostic`) are skipped so
/// a user-declared `let linear = ...` doesn't accidentally bind to the keyword
/// in `@interpolate(linear)` and get its `use_count` bumped — that would let the
/// renamer mangle it into invalid WGSL. Sub-mode is symmetric: same predicate,
/// so `flags.use_count_incremented` parity is preserved without an extra check.
fn visitAttributes(ctx: *Context, attrs: []Ast.Attribute) error{OutOfMemory}!void {
    for (attrs) |*attr| {
        if (!Ast.attributeArgsResolveSymbols(attr.name)) continue;
        for (attr.args.items, 0..) |arg, i| {
            attr.args.items[i] = try visitExpr(ctx, arg);
        }
    }
}

const Work = union(enum) {
    stmt: Ast.Stmt,
    compound: *Ast.CompoundStmt,
    exit_scope,
};

fn visitCompoundStmt(ctx: *Context, stmt: *Ast.CompoundStmt) error{OutOfMemory}!void {
    var stack: std.ArrayListUnmanaged(Work) = .empty;
    defer stack.deinit(ctx.arena);
    try stack.append(ctx.arena, .{ .compound = stmt });
    try drainStmtStack(ctx, &stack);
}

/// Drives the Work stack until it empties. Shared by `visitCompoundStmt`
/// (seeded with a `.compound`) and `visitSubtreeStmt` (seeded with a
/// single `.stmt`). Mode-sensitivity is entirely inside `processOneStmt`
/// and `visitExpr`, so this loop is mode-agnostic.
fn drainStmtStack(ctx: *Context, stack: *std.ArrayListUnmanaged(Work)) error{OutOfMemory}!void {
    for (0..ctx.safety_budget) |_| {
        const work = stack.pop() orelse break;
        switch (work) {
            .exit_scope => exitScope(ctx),
            .compound => |body| {
                enterNextScope(ctx);
                try stack.append(ctx.arena, .exit_scope);
                var i = body.stmts.items.len;
                while (i > 0) {
                    i -= 1;
                    try stack.append(ctx.arena, .{ .stmt = body.stmts.items[i] });
                }
            },
            .stmt => |s| try processOneStmt(ctx, s, stack),
        }
    } else unreachable;
}

/// Process a single statement, pushing child work items onto the stack.
/// Expression visits are done inline (already iterative).
fn processOneStmt(ctx: *Context, s: Ast.Stmt, stack: *std.ArrayListUnmanaged(Work)) error{OutOfMemory}!void {
    switch (s) {
        .compound => |stmt| try stack.append(ctx.arena, .{ .compound = stmt }),
        .@"return" => |stmt| {
            if (stmt.value) |v| stmt.value = try visitExpr(ctx, v);
        },
        .@"if" => |stmt| {
            stmt.condition = try visitExpr(ctx, stmt.condition);
            // Push else branch first (processed after body), then body
            if (stmt.else_branch) |eb| try stack.append(ctx.arena, .{ .stmt = eb });
            try stack.append(ctx.arena, .{ .compound = stmt.body });
        },
        .@"switch" => |stmt| {
            stmt.expr = try visitExpr(ctx, stmt.expr);
            // Push case bodies in reverse order
            var i = stmt.cases.items.len;
            while (i > 0) {
                i -= 1;
                const c = &stmt.cases.items[i];
                try stack.append(ctx.arena, .{ .compound = c.body });
            }
            // Visit selectors inline
            for (stmt.cases.items) |*c| {
                for (c.selectors.items, 0..) |sel, j| {
                    c.selectors.items[j] = try visitExpr(ctx, sel);
                }
            }
        },
        .@"for" => |stmt| {
            // For has its own scope wrapping init/condition/update/body
            enterNextScope(ctx);
            if (stmt.init_stmt) |is| try processOneStmt(ctx, is, stack);
            if (stmt.condition) |cond| stmt.condition = try visitExpr(ctx, cond);
            if (stmt.update) |upd| try processOneStmt(ctx, upd, stack);
            // Push exit_scope (for-scope), then body (which adds its own scope)
            try stack.append(ctx.arena, .exit_scope);
            try stack.append(ctx.arena, .{ .compound = stmt.body });
        },
        .@"while" => |stmt| {
            stmt.condition = try visitExpr(ctx, stmt.condition);
            try stack.append(ctx.arena, .{ .compound = stmt.body });
        },
        .loop => |stmt| {
            if (stmt.continuing) |c| try stack.append(ctx.arena, .{ .compound = c });
            try stack.append(ctx.arena, .{ .compound = stmt.body });
        },
        .break_if => |stmt| {
            stmt.condition = try visitExpr(ctx, stmt.condition);
        },
        .assign => |stmt| {
            stmt.left = try visitExpr(ctx, stmt.left);
            stmt.right = try visitExpr(ctx, stmt.right);
        },
        .incr_decr => |stmt| {
            stmt.expr = try visitExpr(ctx, stmt.expr);
        },
        .call => |stmt| {
            if (stmt.call.func) |f| stmt.call.func = try visitExpr(ctx, f);
            if (stmt.call.template_type) |tt| try visitType(ctx, tt);
            for (stmt.call.args.items, 0..) |arg, j| {
                stmt.call.args.items[j] = try visitExpr(ctx, arg);
            }
        },
        .decl => |stmt| try visitDecl(ctx, stmt.decl),
        .@"break", .@"continue", .discard => {},
    }
}

/// Iteratively visits an expression tree using a two-phase worklist.
/// Pushes mark(e) before children so purity marking happens in post-order.
pub fn visitExpr(ctx: *Context, e: Ast.Expr) error{OutOfMemory}!Ast.Expr {
    const ExprWork = union(enum) {
        visit: Ast.Expr,
        mark: Ast.Expr,
    };

    var stack: std.ArrayListUnmanaged(ExprWork) = .empty;
    defer stack.deinit(ctx.arena);
    try stack.append(ctx.arena, .{ .visit = e });

    for (0..ctx.safety_budget) |_| {
        const work = stack.pop() orelse break;
        switch (work) {
            .mark => |me| {
                // Sub mode walks a subtree whose purity flags we do not
                // want to re-touch: the subtree is being discarded from
                // the module, so marking is pure waste work at best.
                if (ctx.mode == .add) Ast.markExprPurity(me, ctx.symbols);
            },
            .visit => |ve| {
                // Push mark first (popped last = post-order)
                try stack.append(ctx.arena, .{ .mark = ve });

                switch (ve) {
                    .ident => |expr| switch (ctx.mode) {
                        .add => {
                            ctx.current_loc = expr.loc;
                            if (lookupSymbol(ctx, expr.name)) |ref| {
                                expr.ref = ref;
                                if (ref.isValid()) {
                                    const idx = ref.index();
                                    if (idx < ctx.symbols.len) {
                                        ctx.symbols[idx].use_count += 1;
                                        if (ctx.use_counts) |uc| uc.increment(ref);
                                        // Pair the bump with the flag so
                                        // `.sub` can tell this ident from
                                        // an E0102 ref that was set but
                                        // never counted.
                                        expr.flags.use_count_incremented = true;
                                    }
                                }
                            } else if (lookupSymbolAnyLoc(ctx, expr.name)) |ref| {
                                const msg = try std.fmt.allocPrint(ctx.arena, "'{s}' is used before its declaration", .{expr.name});
                                try ctx.errors.append(ctx.arena, .{ .message = msg, .pos = expr.loc, .code = "E0102" });
                                expr.ref = ref;
                                // use_count_incremented stays false — the
                                // E0102 branch sets `ref` for IDE goto-def
                                // but intentionally skips the bump.
                            }
                        },
                        .sub => {
                            // Subtree carries pre-bound refs from a prior
                            // Pass 2. Decrement only idents that `.add`
                            // actually bumped; E0102 refs have
                            // `ref.isValid()` without the paired
                            // increment. No lookup, no scope access, no
                            // error emission — the subtree is going away.
                            if (expr.flags.use_count_incremented) {
                                const idx = expr.ref.index();
                                if (idx < ctx.symbols.len and ctx.symbols[idx].use_count > 0) {
                                    ctx.symbols[idx].use_count -= 1;
                                    if (ctx.use_counts) |uc| uc.decrement(expr.ref);
                                }
                                expr.flags.use_count_incremented = false;
                            }
                        },
                    },
                    .literal => {},
                    .binary => |expr| {
                        try stack.append(ctx.arena, .{ .visit = expr.right });
                        try stack.append(ctx.arena, .{ .visit = expr.left });
                    },
                    .unary => |expr| {
                        try stack.append(ctx.arena, .{ .visit = expr.operand });
                    },
                    .call => |expr| {
                        var i = expr.args.items.len;
                        while (i > 0) {
                            i -= 1;
                            try stack.append(ctx.arena, .{ .visit = expr.args.items[i] });
                        }
                        if (expr.template_type) |tt| try visitType(ctx, tt);
                        if (expr.func) |f| try stack.append(ctx.arena, .{ .visit = f });
                    },
                    .index => |expr| {
                        try stack.append(ctx.arena, .{ .visit = expr.idx });
                        try stack.append(ctx.arena, .{ .visit = expr.base });
                    },
                    .member => |expr| {
                        try stack.append(ctx.arena, .{ .visit = expr.base });
                    },
                    .paren => |expr| {
                        try stack.append(ctx.arena, .{ .visit = expr.expr });
                    },
                }
            },
        }
    } else unreachable;
    return e;
}

/// Iteratively visits a type, following single-child chains. The bound
/// matches `constants.max_parser_type_depth` so the parser cannot build a
/// type the visitor refuses on depth grounds.
pub fn visitType(ctx: *Context, t: Ast.Type) error{OutOfMemory}!void {
    var current = t;
    for (0..constants.max_parser_type_depth) |_| {
        switch (current) {
            .ident => |typ| switch (ctx.mode) {
                .add => {
                    ctx.current_loc = 0; // Types don't have text-order restrictions at module scope
                    if (lookupSymbol(ctx, typ.name)) |ref| {
                        typ.ref = ref;
                        if (ref.isValid()) {
                            const idx = ref.index();
                            if (idx < ctx.symbols.len) {
                                ctx.symbols[idx].use_count += 1;
                                if (ctx.use_counts) |uc| uc.increment(ref);
                            }
                        }
                    }
                    break;
                },
                .sub => {
                    if (typ.ref.isValid()) {
                        const idx = typ.ref.index();
                        if (idx < ctx.symbols.len and ctx.symbols[idx].use_count > 0) {
                            ctx.symbols[idx].use_count -= 1;
                            if (ctx.use_counts) |uc| uc.decrement(typ.ref);
                        }
                    }
                    break;
                },
            },
            .vec => |typ| current = typ.elem_type orelse break,
            .mat => |typ| current = typ.elem_type orelse break,
            .array => |typ| {
                if (typ.size) |s| _ = try visitExpr(ctx, s);
                current = typ.elem_type orelse break;
            },
            .ptr => |typ| current = typ.elem_type,
            .atomic => |typ| current = typ.elem_type,
            .sampler => break,
            .texture => |typ| current = typ.sampled_type orelse break,
        }
    } else unreachable;
}

// =========================================================================
// Subtree entry points (incremental hot path).
//
// `visitSubtreeStmt` and `visitSubtreeExpr` drive the same walker used by
// `visit`, but seeded with a single statement or expression instead of
// the whole module. `ctx.mode` controls direction:
//   - `.add`: caller is about to splice `subtree` into the module. Resolve
//     idents against `ctx.scope` (which the caller must position at the
//     anchor's enclosing scope), increment `use_count`, mark purity.
//   - `.sub`: caller is about to splice `subtree` OUT of the module. Read
//     pre-bound `ref` fields and decrement `use_count`.
//
// Callers take the `LoweredSubtree` union returned by
// `CstLower.lowerSubtree` and dispatch on its tag into these two entry
// points. AstVisit deliberately avoids importing CstLower to keep the
// module dependency acyclic.
// =========================================================================

pub fn visitSubtreeStmt(ctx: *Context, stmt: Ast.Stmt) error{OutOfMemory}!void {
    var stack: std.ArrayListUnmanaged(Work) = .empty;
    defer stack.deinit(ctx.arena);
    try stack.append(ctx.arena, .{ .stmt = stmt });
    try drainStmtStack(ctx, &stack);
}

pub fn visitSubtreeExpr(ctx: *Context, expr: Ast.Expr) error{OutOfMemory}!Ast.Expr {
    return visitExpr(ctx, expr);
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
