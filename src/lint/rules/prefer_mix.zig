//! `prefer-mix` — suggest the WGSL `mix(a, b, t)` builtin for manual
//! linear-interpolation patterns. The common shapes:
//!
//!     a + (b - a) * t     // textbook lerp
//!     a + t * (b - a)     // commuted multiplication
//!
//! Both are equivalent to `mix(a, b, t)` and `mix` is usually better
//! optimized (vector-aware on GPUs, fewer ops in FP error). Autofix
//! rewrites the expression in place using the outer source span.
//!
//! Intentionally conservative: we do not match `a*(1-t) + b*t` because
//! that form has subtly different numerical behavior in edge cases and
//! users sometimes pick it deliberately.

const std = @import("std");

const Rule = @import("../Rule.zig");
const Context = @import("../Context.zig");
const Diagnostic = @import("../../Diagnostic.zig");
const Ast = @import("../../Ast.zig");
const walk = @import("../walk.zig");
const exprStart = walk.exprStart;
const exprEnd = walk.exprEnd;

pub const rule = Rule{
    .meta = .{
        .id = "prefer-mix",
        .code = Diagnostic.Code.lint_prefer_mix,
        .default_severity = .warning,
        .description = "Prefer the mix(a, b, t) builtin over the manual `a + (b - a) * t` lerp pattern",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/prefer-mix.md",
        .category = .performance,
        .fixable = true,
    },
    .run = run,
};

fn run(ctx: *Context) error{OutOfMemory}!void {
    try walk.walkExprs(ctx.arena, ctx.module, ctx, onExpr);
}

fn onExpr(ctx: *Context, e: Ast.Expr) void {
    const matched = matchLerp(e) orelse return;
    reportMatch(ctx, e, matched) catch return;
}

const Match = struct {
    a: Ast.Expr,
    b: Ast.Expr,
    t: Ast.Expr,
};

/// Match `a + (b - a) * t` (and the commuted `a + t * (b - a)`). Returns
/// the bound `a`, `b`, `t` on success.
fn matchLerp(root: Ast.Expr) ?Match {
    const add = switch (unwrap(root)) {
        .binary => |b| if (b.op == .add) b else return null,
        else => return null,
    };
    const a_expr = unwrap(add.left);
    const mul = switch (unwrap(add.right)) {
        .binary => |b| if (b.op == .mul) b else return null,
        else => return null,
    };
    // Try both orderings of the multiplication.
    if (matchLerpMul(a_expr, mul.left, mul.right)) |m| return m;
    if (matchLerpMul(a_expr, mul.right, mul.left)) |m| return m;
    return null;
}

fn matchLerpMul(a_expr: Ast.Expr, diff_side: Ast.Expr, t_side: Ast.Expr) ?Match {
    const sub = switch (unwrap(diff_side)) {
        .binary => |b| if (b.op == .sub) b else return null,
        else => return null,
    };
    if (!sameExprText(a_expr, sub.right)) return null;
    return .{ .a = a_expr, .b = sub.left, .t = t_side };
}

fn unwrap(e: Ast.Expr) Ast.Expr {
    var cur = e;
    while (true) switch (cur) {
        .paren => |p| cur = p.expr,
        else => return cur,
    };
}

fn sameExprText(a: Ast.Expr, b: Ast.Expr) bool {
    return sameRef(a, b);
}

fn sameRef(a: Ast.Expr, b: Ast.Expr) bool {
    return switch (unwrap(a)) {
        .ident => |ai| switch (unwrap(b)) {
            .ident => |bi| ai.ref.isValid() and ai.ref == bi.ref,
            else => false,
        },
        .member => |am| switch (unwrap(b)) {
            .member => |bm| std.mem.eql(u8, am.member_name, bm.member_name) and sameRef(am.base, bm.base),
            else => false,
        },
        .literal => |al| switch (unwrap(b)) {
            .literal => |bl| std.mem.eql(u8, al.value, bl.value),
            else => false,
        },
        else => false,
    };
}

fn reportMatch(ctx: *Context, outer: Ast.Expr, m: Match) !void {
    const start = exprStart(outer);
    const end = exprEnd(outer);
    if (start == end) return;

    const a_text = exprText(ctx, m.a) orelse return;
    const b_text = exprText(ctx, m.b) orelse return;
    const t_text = exprText(ctx, m.t) orelse return;
    const replacement = try std.fmt.allocPrint(ctx.arena, "mix({s}, {s}, {s})", .{ a_text, b_text, t_text });

    const fix = try ctx.arena.create(Diagnostic.Fix);
    fix.* = .{
        .range = ctx.makeRange(start, end),
        .text = replacement,
    };

    const msg = try ctx.fmt("prefer mix({s}, {s}, {s}) over manual lerp", .{ a_text, b_text, t_text });
    ctx.report(.{
        .message = msg,
        .range = ctx.makeRange(start, end),
        .fix = fix,
    });
}

fn exprText(ctx: *const Context, e: Ast.Expr) ?[]const u8 {
    const s = exprStart(e);
    const t = exprEnd(e);
    if (s == t) return null;
    return ctx.sourceSlice(s, t);
}
