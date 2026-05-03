//! `no-empty` — flag empty `{ }` blocks attached to `if`/`else`/`for`/
//! `while`/`loop`/`switch`/`case` statements. An empty body is almost
//! always a placeholder the author forgot to fill in or a leftover
//! from deleting code; either way it's worth surfacing.
//!
//! Empty function bodies are deliberately *not* flagged — stubs,
//! interface placeholders, and trivial entry points are legitimate
//! reasons to leave a function empty.

const std = @import("std");

const Rule = @import("../Rule.zig");
const Context = @import("../Context.zig");
const Diagnostic = @import("../../Diagnostic.zig");
const Ast = @import("../../Ast.zig");
const MultiVisitor = @import("../MultiVisitor.zig");

pub const rule = Rule{
    .meta = .{
        .id = "no-empty",
        .code = Diagnostic.Code.lint_no_empty,
        .default_severity = .warning,
        .description = "Report empty blocks attached to control-flow statements",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/no-empty.md",
        .category = .suspicious,
    },
    .listener = makeListener,
};

/// Per-listener scratch state. `handled` records compounds we've already
/// flagged via a parent control-flow stmt (`if`/`switch`/`for`/…), so the
/// later on_stmt(.compound) event for the same compound — which fires for
/// `else { … }` branches that travel through MultiVisitor's stmt arm —
/// doesn't double-flag with the generic "block" label.
const State = struct {
    ctx: *Context,
    handled: std.AutoHashMapUnmanaged(*Ast.CompoundStmt, void) = .empty,
};

fn makeListener(ctx: *Context) error{OutOfMemory}!MultiVisitor.Listener {
    const state = try ctx.arena.create(State);
    state.* = .{ .ctx = ctx };
    return .{ .ctx = state, .on_stmt = onStmt };
}

fn onStmt(opaque_ctx: *anyopaque, stmt: Ast.Stmt) error{OutOfMemory}!void {
    const state: *State = @ptrCast(@alignCast(opaque_ctx));
    switch (stmt) {
        .compound => |s| {
            if (state.handled.contains(s)) return;
            try flagEmpty(state.ctx, s, "block");
        },
        .@"if" => |s| {
            try flagEmpty(state.ctx, s.body, "if");
            if (s.else_branch) |eb| switch (eb) {
                .compound => |ec| {
                    try flagEmpty(state.ctx, ec, "else");
                    try state.handled.put(state.ctx.arena, ec, {});
                },
                else => {},
            };
        },
        .@"switch" => |s| for (s.cases.items) |case| try flagEmpty(state.ctx, case.body, "case"),
        .@"for" => |s| try flagEmpty(state.ctx, s.body, "for"),
        .@"while" => |s| try flagEmpty(state.ctx, s.body, "while"),
        .loop => |s| try flagEmpty(state.ctx, s.body, "loop"),
        else => {},
    }
}

fn flagEmpty(ctx: *Context, c: *Ast.CompoundStmt, kind: []const u8) error{OutOfMemory}!void {
    if (c.stmts.items.len != 0) return;
    const span = c.span;
    if (span.start == span.end) return;

    const msg = try ctx.fmt("empty {s} block", .{kind});
    ctx.report(.{
        .message = msg,
        .range = ctx.makeRange(span.start, span.end),
    });
}
