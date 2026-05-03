//! `no-lonely-if` — when an `else` branch contains a single `if` with
//! no else, the nested braces add nothing over the more idiomatic
//! `else if`.
//!
//! Matches:
//!
//!     if (a) { … } else {
//!       if (b) { … }       // <- flagged
//!     }
//!
//! Does NOT match when the inner `if` has an `else` of its own — that
//! structure reads clearly and converting it would be misleading.
//!
//! No autofix yet: reliably transforming `} else {\n  if (…) { … }\n}`
//! into `} else if (…) { … }` requires whitespace-sensitive source
//! editing that's hard to get right on a first pass. Reserved for a
//! follow-up once we add a proper token-range rewriter.

const std = @import("std");

const Rule = @import("../Rule.zig");
const Context = @import("../Context.zig");
const Diagnostic = @import("../../Diagnostic.zig");
const Ast = @import("../../Ast.zig");
const MultiVisitor = @import("../MultiVisitor.zig");

pub const rule = Rule{
    .meta = .{
        .id = "no-lonely-if",
        .code = Diagnostic.Code.lint_no_lonely_if,
        .default_severity = .warning,
        .description = "Flag `else { if (…) { … } }` with no else — prefer `else if`",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/no-lonely-if.md",
        .category = .style,
    },
    .listener = makeListener,
};

fn makeListener(ctx: *Context) error{OutOfMemory}!MultiVisitor.Listener {
    return .{ .ctx = ctx, .on_stmt = onStmt };
}

fn onStmt(opaque_ctx: *anyopaque, stmt: Ast.Stmt) error{OutOfMemory}!void {
    const ctx: *Context = @ptrCast(@alignCast(opaque_ctx));
    const s = switch (stmt) {
        .@"if" => |i| i,
        else => return,
    };
    const eb = s.else_branch orelse return;
    try checkElseBranch(ctx, eb);
}

fn checkElseBranch(ctx: *Context, eb: Ast.Stmt) error{OutOfMemory}!void {
    const compound = switch (eb) {
        .compound => |c| c,
        else => return,
    };
    if (compound.stmts.items.len != 1) return;
    const inner = switch (compound.stmts.items[0]) {
        .@"if" => |i| i,
        else => return,
    };
    if (inner.else_branch != null) return;

    const span = inner.span;
    if (span.start == span.end) return;
    const msg = try ctx.fmt("wrap this into the outer chain as `else if` — the extra braces add no value", .{});
    ctx.report(.{
        .message = msg,
        .range = ctx.makeRange(span.start, span.end),
    });
}
