//! `no-self-assign` — flag assignments where the left-hand side and
//! right-hand side refer to the same storage location. Examples:
//!
//!     x = x;
//!     v.xy = v.xy;
//!     arr[i] = arr[i];
//!
//! These are almost always typos or leftovers from refactors. The rule
//! attaches a fixit that deletes the whole statement; users who want to
//! reassign part of a value (e.g. to force a redundant load for
//! debugging) can suppress the rule on that line.
//!
//! Only the `simple` assignment operator (`=`) is considered; compound
//! assignments like `x += x` are genuine rewrites and not flagged.

const std = @import("std");

const Rule = @import("../Rule.zig");
const Context = @import("../Context.zig");
const Diagnostic = @import("../../Diagnostic.zig");
const Ast = @import("../../Ast.zig");

pub const rule = Rule{
    .meta = .{
        .id = "no-self-assign",
        .code = Diagnostic.Code.lint_no_self_assign,
        .default_severity = .warning,
        .description = "Report assignments where the left-hand side and right-hand side are the same storage location",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/no-self-assign.md",
        .category = .correctness,
        .fixable = true,
    },
    .run = run,
};

fn run(ctx: *Context) error{OutOfMemory}!void {
    for (ctx.module.declarations.items) |decl| switch (decl) {
        .function => |fd| if (fd.body) |body| try walkCompound(ctx, body),
        else => {},
    };
}

fn walkCompound(ctx: *Context, c: *Ast.CompoundStmt) error{OutOfMemory}!void {
    for (c.stmts.items) |stmt| try walkStmt(ctx, stmt);
}

fn walkStmt(ctx: *Context, stmt: Ast.Stmt) error{OutOfMemory}!void {
    switch (stmt) {
        .compound => |s| try walkCompound(ctx, s),
        .@"if" => |s| {
            try walkCompound(ctx, s.body);
            if (s.else_branch) |eb| try walkStmt(ctx, eb);
        },
        .@"switch" => |s| for (s.cases.items) |case| try walkCompound(ctx, case.body),
        .@"for" => |s| {
            if (s.init_stmt) |is| try walkStmt(ctx, is);
            if (s.update) |u| try walkStmt(ctx, u);
            try walkCompound(ctx, s.body);
        },
        .@"while" => |s| try walkCompound(ctx, s.body),
        .loop => |s| {
            try walkCompound(ctx, s.body);
            if (s.continuing) |cc| try walkCompound(ctx, cc);
        },
        .assign => |s| try checkAssign(ctx, s),
        else => {},
    }
}

fn checkAssign(ctx: *Context, s: *Ast.AssignStmt) error{OutOfMemory}!void {
    if (s.op != .simple) return;
    if (!sameRef(s.left, s.right)) return;

    const span = s.span;
    if (span.start == span.end) return;

    const fix = try ctx.arena.create(Diagnostic.Fix);
    fix.* = .{
        .range = ctx.makeRange(span.start, span.end),
        .text = "",
    };

    const msg = try ctx.fmt("assigning a reference to itself has no effect", .{});
    ctx.report(.{
        .message = msg,
        .range = ctx.makeRange(span.start, span.end),
        .fix = fix,
    });
}

/// Structural equality on the reference expression trees. We require
/// identifiers to resolve to the same `SymbolIndex` so two different
/// variables named `x` in nested scopes don't collide.
fn sameRef(a: Ast.Expr, b: Ast.Expr) bool {
    return switch (a) {
        .ident => |ai| switch (b) {
            .ident => |bi| ai.ref.isValid() and ai.ref == bi.ref,
            else => false,
        },
        .member => |am| switch (b) {
            .member => |bm| std.mem.eql(u8, am.member_name, bm.member_name) and sameRef(am.base, bm.base),
            else => false,
        },
        .index => |ai| switch (b) {
            .index => |bi| sameRef(ai.base, bi.base) and sameIndexKey(ai.idx, bi.idx),
            else => false,
        },
        .paren => |ap| switch (b) {
            .paren => |bp| sameRef(ap.expr, bp.expr),
            else => sameRef(ap.expr, b),
        },
        .unary => |au| switch (au.op) {
            .deref => switch (b) {
                .unary => |bu| bu.op == .deref and sameRef(au.operand, bu.operand),
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

/// For index expressions we require the key to be a literal so that
/// `arr[counter] = arr[counter]` isn't flagged — `counter` might have
/// changed between evaluation of the two sides in a future rewrite. We
/// only flag when the key is an unambiguous literal.
fn sameIndexKey(a: Ast.Expr, b: Ast.Expr) bool {
    const al = unwrapLiteral(a) orelse return false;
    const bl = unwrapLiteral(b) orelse return false;
    return std.mem.eql(u8, al.value, bl.value);
}

fn unwrapLiteral(expr: Ast.Expr) ?*Ast.LiteralExpr {
    return switch (expr) {
        .literal => |l| l,
        .paren => |p| unwrapLiteral(p.expr),
        else => null,
    };
}
