//! `prefer-let-over-var` — function-scope `var` declarations that are
//! never reassigned (and never have their address taken) should be
//! `let`. This mirrors ESLint's `prefer-const` for the WGSL idiom:
//!   * `let x = …;` — immutable binding, dies with the block.
//!   * `var x = …;` — mutable reference, needs a storage slot.
//!
//! Autofix replaces the `var` keyword with `let`. The rule does not
//! flag module-scope `var` (those have different semantics — they
//! carry an address space, access mode, and potentially bindings) or
//! `var` with an explicit type annotation that would lose meaning
//! once it's `let` (we still flag those, the type stays valid).
//!
//! Conservative carve-outs:
//!   * Any assignment (`=`, `+=`, etc.) or increment/decrement anywhere
//!     in the function body counts as mutation.
//!   * `&v` (address-of) forces `var` because `let` can't have a
//!     reference taken — so we skip.

const std = @import("std");

const Rule = @import("../Rule.zig");
const Context = @import("../Context.zig");
const Diagnostic = @import("../../Diagnostic.zig");
const Ast = @import("../../Ast.zig");

pub const rule = Rule{
    .meta = .{
        .id = "prefer-let-over-var",
        .code = Diagnostic.Code.lint_prefer_let_over_var,
        .default_severity = .warning,
        .description = "Prefer `let` over function-scope `var` when the binding is never reassigned",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/prefer-let-over-var.md",
        .category = .style,
        .fixable = true,
    },
    .run = run,
};

const MutatedSet = std.AutoHashMapUnmanaged(u32, void);

fn run(ctx: *Context) error{OutOfMemory}!void {
    for (ctx.module.declarations.items) |decl| switch (decl) {
        .function => |fd| try checkFunction(ctx, fd),
        else => {},
    };
}

fn checkFunction(ctx: *Context, fd: *const Ast.FunctionDecl) error{OutOfMemory}!void {
    const body = fd.body orelse return;

    var mutated: MutatedSet = .empty;
    defer mutated.deinit(ctx.arena);
    try collectMutations(ctx, body, &mutated);

    try flagImmutableVars(ctx, body, &mutated);
}

fn collectMutations(ctx: *Context, c: *Ast.CompoundStmt, out: *MutatedSet) error{OutOfMemory}!void {
    for (c.stmts.items) |stmt| try collectMutationsStmt(ctx, stmt, out);
}

fn collectMutationsStmt(ctx: *Context, stmt: Ast.Stmt, out: *MutatedSet) error{OutOfMemory}!void {
    switch (stmt) {
        .compound => |s| try collectMutations(ctx, s, out),
        .@"if" => |s| {
            try collectMutations(ctx, s.body, out);
            if (s.else_branch) |eb| try collectMutationsStmt(ctx, eb, out);
        },
        .@"switch" => |s| for (s.cases.items) |case| try collectMutations(ctx, case.body, out),
        .@"for" => |s| {
            if (s.init_stmt) |is| try collectMutationsStmt(ctx, is, out);
            if (s.update) |u| try collectMutationsStmt(ctx, u, out);
            try collectMutations(ctx, s.body, out);
        },
        .@"while" => |s| try collectMutations(ctx, s.body, out),
        .loop => |s| {
            try collectMutations(ctx, s.body, out);
            if (s.continuing) |cc| try collectMutations(ctx, cc, out);
        },
        .assign => |s| if (lvalueRoot(s.left)) |ref| try out.put(ctx.arena, @intFromEnum(ref), {}),
        .incr_decr => |s| if (lvalueRoot(s.expr)) |ref| try out.put(ctx.arena, @intFromEnum(ref), {}),
        .decl => |s| try collectMutationsDecl(ctx, s.decl, out),
        else => {},
    }

    // Address-of (&v) forces `var`: we need an addressable storage slot.
    try collectAddrsInStmt(ctx, stmt, out);
}

fn collectMutationsDecl(ctx: *Context, decl: Ast.Decl, out: *MutatedSet) error{OutOfMemory}!void {
    switch (decl) {
        .function => |fd| if (fd.body) |body| try collectMutations(ctx, body, out),
        .@"var" => |d| if (d.initializer) |e| try collectAddrsInExpr(ctx, e, out),
        .let => |d| if (d.initializer) |e| try collectAddrsInExpr(ctx, e, out),
        .@"const" => |d| if (d.initializer) |e| try collectAddrsInExpr(ctx, e, out),
        else => {},
    }
}

fn collectAddrsInStmt(ctx: *Context, stmt: Ast.Stmt, out: *MutatedSet) error{OutOfMemory}!void {
    switch (stmt) {
        .@"return" => |s| if (s.value) |v| try collectAddrsInExpr(ctx, v, out),
        .@"if" => |s| try collectAddrsInExpr(ctx, s.condition, out),
        .@"switch" => |s| {
            try collectAddrsInExpr(ctx, s.expr, out);
            for (s.cases.items) |case| for (case.selectors.items) |sel| try collectAddrsInExpr(ctx, sel, out);
        },
        .@"for" => |s| if (s.condition) |c| try collectAddrsInExpr(ctx, c, out),
        .@"while" => |s| try collectAddrsInExpr(ctx, s.condition, out),
        .assign => |s| {
            try collectAddrsInExpr(ctx, s.left, out);
            try collectAddrsInExpr(ctx, s.right, out);
        },
        .call => |s| for (s.call.args.items) |a| try collectAddrsInExpr(ctx, a, out),
        .break_if => |s| try collectAddrsInExpr(ctx, s.condition, out),
        .incr_decr => |s| try collectAddrsInExpr(ctx, s.expr, out),
        else => {},
    }
}

fn collectAddrsInExpr(ctx: *Context, root: Ast.Expr, out: *MutatedSet) error{OutOfMemory}!void {
    var stack: std.ArrayListUnmanaged(Ast.Expr) = .empty;
    defer stack.deinit(ctx.arena);
    try stack.append(ctx.arena, root);
    while (stack.pop()) |e| switch (e) {
        .unary => |u| {
            if (u.op == .addr) {
                if (lvalueRoot(u.operand)) |ref| try out.put(ctx.arena, @intFromEnum(ref), {});
            }
            try stack.append(ctx.arena, u.operand);
        },
        .binary => |b| {
            try stack.append(ctx.arena, b.left);
            try stack.append(ctx.arena, b.right);
        },
        .call => |c| {
            if (c.func) |f| try stack.append(ctx.arena, f);
            for (c.args.items) |a| try stack.append(ctx.arena, a);
        },
        .index => |i| {
            try stack.append(ctx.arena, i.base);
            try stack.append(ctx.arena, i.idx);
        },
        .member => |m| try stack.append(ctx.arena, m.base),
        .paren => |p| try stack.append(ctx.arena, p.expr),
        .ident, .literal => {},
    };
}

/// Drill through paren / member / index to the underlying ident of an
/// lvalue — returns the symbol being mutated. For a pointer deref (`*p`)
/// we still credit `p` since the author's intent is to write through
/// that handle.
fn lvalueRoot(e: Ast.Expr) ?Ast.SymbolIndex {
    return switch (e) {
        .ident => |i| if (i.ref.isValid()) i.ref else null,
        .paren => |p| lvalueRoot(p.expr),
        .member => |m| lvalueRoot(m.base),
        .index => |i| lvalueRoot(i.base),
        .unary => |u| switch (u.op) {
            .deref => lvalueRoot(u.operand),
            else => null,
        },
        else => null,
    };
}

fn flagImmutableVars(ctx: *Context, c: *Ast.CompoundStmt, mutated: *const MutatedSet) error{OutOfMemory}!void {
    for (c.stmts.items) |stmt| try flagStmt(ctx, stmt, mutated);
}

fn flagStmt(ctx: *Context, stmt: Ast.Stmt, mutated: *const MutatedSet) error{OutOfMemory}!void {
    switch (stmt) {
        .compound => |s| try flagImmutableVars(ctx, s, mutated),
        .@"if" => |s| {
            try flagImmutableVars(ctx, s.body, mutated);
            if (s.else_branch) |eb| try flagStmt(ctx, eb, mutated);
        },
        .@"switch" => |s| for (s.cases.items) |case| try flagImmutableVars(ctx, case.body, mutated),
        .@"for" => |s| {
            if (s.init_stmt) |is| try flagStmt(ctx, is, mutated);
            try flagImmutableVars(ctx, s.body, mutated);
        },
        .@"while" => |s| try flagImmutableVars(ctx, s.body, mutated),
        .loop => |s| {
            try flagImmutableVars(ctx, s.body, mutated);
            if (s.continuing) |cc| try flagImmutableVars(ctx, cc, mutated);
        },
        .decl => |s| switch (s.decl) {
            .@"var" => |vd| try flagVarDecl(ctx, vd, mutated),
            else => {},
        },
        else => {},
    }
}

fn flagVarDecl(ctx: *Context, vd: *Ast.VarDecl, mutated: *const MutatedSet) error{OutOfMemory}!void {
    // Skip module-scope-shaped vars: address-space or access-mode
    // annotations belong to the storage-class world, not local scope.
    if (vd.address_space != .none or vd.access_mode != .none) return;
    // Skip if any attributes are attached (would be unusual for a local).
    if (vd.attributes.items.len > 0) return;
    const name_ref = vd.name;
    if (!name_ref.isValid()) return;
    if (mutated.contains(@intFromEnum(name_ref))) return;

    const sym = ctx.module.symbols.items[name_ref.index()];
    // `var` decl_span starts at the `var` keyword. Autofix swaps the
    // leading 3 bytes for `let`.
    const span = vd.decl_span;
    if (span.start == span.end) return;
    const source = ctx.source;
    if (span.start + 3 > source.len) return;
    if (!std.mem.eql(u8, source[span.start .. span.start + 3], "var")) return;

    const fix = try ctx.arena.create(Diagnostic.Fix);
    fix.* = .{
        .range = ctx.makeRange(span.start, span.start + 3),
        .text = "let",
    };

    const name_end = sym.loc + @as(u32, @intCast(sym.original_name.len));
    const msg = try ctx.fmt(
        "'{s}' is never reassigned — prefer `let` over `var`",
        .{sym.original_name},
    );
    ctx.report(.{
        .message = msg,
        .range = ctx.makeRange(sym.loc, name_end),
        .fix = fix,
    });
}
