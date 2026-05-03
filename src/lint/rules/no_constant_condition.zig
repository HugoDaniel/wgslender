//! `no-constant-condition` — flag literal-boolean (or literal-number)
//! conditions in `if`, `while`, `for`, and `break if` — the branch is
//! taken or not every time, so the condition is almost certainly a
//! leftover from debugging.
//!
//! `while (true) { ... break; ... }` is a common idiom; users who rely on
//! it can suppress with `// wgslender-disable-next-line no-constant-condition`
//! or switch to WGSL's dedicated `loop { }` construct, which is what the
//! spec recommends for unbounded iteration.

const std = @import("std");

const Rule = @import("../Rule.zig");
const Context = @import("../Context.zig");
const Diagnostic = @import("../../Diagnostic.zig");
const Ast = @import("../../Ast.zig");
const MultiVisitor = @import("../MultiVisitor.zig");

pub const rule = Rule{
    .meta = .{
        .id = "no-constant-condition",
        .code = Diagnostic.Code.lint_no_constant_condition,
        .default_severity = .warning,
        .description = "Report conditions that always evaluate to the same value",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/no-constant-condition.md",
        .category = .correctness,
    },
    .listener = makeListener,
};

fn makeListener(ctx: *Context) error{OutOfMemory}!MultiVisitor.Listener {
    return .{ .ctx = ctx, .on_stmt = onStmt };
}

fn onStmt(opaque_ctx: *anyopaque, stmt: Ast.Stmt) error{OutOfMemory}!void {
    const ctx: *Context = @ptrCast(@alignCast(opaque_ctx));
    switch (stmt) {
        .@"if" => |s| try checkCondition(ctx, s.condition, "if"),
        .@"while" => |s| try checkCondition(ctx, s.condition, "while"),
        .@"for" => |s| if (s.condition) |cond| try checkCondition(ctx, cond, "for"),
        .break_if => |s| try checkCondition(ctx, s.condition, "break if"),
        else => {},
    }
}

fn checkCondition(ctx: *Context, expr: Ast.Expr, kw: []const u8) error{OutOfMemory}!void {
    const lit = unwrapLiteral(expr) orelse return;
    const value = lit.value;
    const range = literalRange(ctx, lit, expr);
    const msg = try ctx.fmt(
        "constant '{s}' in {s} condition — branch is never variable",
        .{ value, kw },
    );
    ctx.report(.{
        .message = msg,
        .range = range,
    });
}

fn unwrapLiteral(expr: Ast.Expr) ?*Ast.LiteralExpr {
    return switch (expr) {
        .literal => |l| l,
        .paren => |p| unwrapLiteral(p.expr),
        .unary => |u| switch (u.op) {
            .not, .neg => unwrapLiteral(u.operand),
            else => null,
        },
        else => null,
    };
}

fn literalRange(ctx: *Context, lit: *Ast.LiteralExpr, outer: Ast.Expr) Diagnostic.Range {
    const outer_span = outer.span();
    if (outer_span.start != outer_span.end) {
        return ctx.makeRange(outer_span.start, outer_span.end);
    }
    const end: u32 = lit.loc + @as(u32, @intCast(lit.value.len));
    return ctx.makeRange(lit.loc, end);
}
