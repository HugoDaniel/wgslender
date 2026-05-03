//! `no-useless-return` — flag a bare `return;` as the last statement
//! of a function whose return type is void (or unspecified). The
//! implicit fall-off-the-end already does the same thing, so the
//! explicit `return;` is just noise.
//!
//! Autofix deletes the statement. We do NOT flag `return expr;` or
//! a bare `return;` in the middle of a block — early exits are often
//! structurally important even when functionally redundant.

const std = @import("std");

const Rule = @import("../Rule.zig");
const Context = @import("../Context.zig");
const Diagnostic = @import("../../Diagnostic.zig");
const Ast = @import("../../Ast.zig");
const MultiVisitor = @import("../MultiVisitor.zig");

pub const rule = Rule{
    .meta = .{
        .id = "no-useless-return",
        .code = Diagnostic.Code.lint_no_useless_return,
        .default_severity = .warning,
        .description = "Report a bare `return;` as the last statement of a void-returning function",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/no-useless-return.md",
        .category = .style,
        .fixable = true,
    },
    .listener = makeListener,
};

fn makeListener(ctx: *Context) error{OutOfMemory}!MultiVisitor.Listener {
    return .{ .ctx = ctx, .on_decl = onDecl };
}

fn onDecl(opaque_ctx: *anyopaque, decl: Ast.Decl) error{OutOfMemory}!void {
    const ctx: *Context = @ptrCast(@alignCast(opaque_ctx));
    const fd = switch (decl) {
        .function => |f| f,
        else => return,
    };
    if (fd.return_type != null) return;
    const body = fd.body orelse return;
    try checkCompoundTrailing(ctx, body);
}

fn checkCompoundTrailing(ctx: *Context, c: *Ast.CompoundStmt) error{OutOfMemory}!void {
    if (c.stmts.items.len == 0) return;
    const last = c.stmts.items[c.stmts.items.len - 1];
    switch (last) {
        .@"return" => |r| {
            if (r.value != null) return;
            const span = r.span;
            if (span.start == span.end) return;

            const fix = try ctx.arena.create(Diagnostic.Fix);
            fix.* = .{
                .range = ctx.makeRange(span.start, span.end),
                .text = "",
            };
            const msg = try ctx.fmt("`return;` is unnecessary as the last statement of a void-returning function", .{});
            ctx.report(.{
                .message = msg,
                .range = ctx.makeRange(span.start, span.end),
                .fix = fix,
            });
        },
        else => {},
    }
}
