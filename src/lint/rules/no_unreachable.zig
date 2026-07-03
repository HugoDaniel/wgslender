//! `no-unreachable` — flag statements that follow an unconditional
//! `return`, `break`, `continue`, or `discard` in the same compound block.
//!
//! Only the *immediate textual* continuation is considered — we don't do
//! full reachability analysis across if/else branches (the validator's
//! W0103 covers the richer cases). The goal here is to catch the common
//! mistake of leaving orphan statements after an early exit.

const std = @import("std");

const Rule = @import("../Rule.zig");
const Context = @import("../Context.zig");
const Diagnostic = @import("../../Diagnostic.zig");
const Ast = @import("../../Ast.zig");

pub const rule = Rule{
    .meta = .{
        .id = "no-unreachable",
        .code = Diagnostic.Code.lint_no_unreachable,
        .default_severity = .warning,
        .description = "Report statements that follow an unconditional return, break, continue, or discard",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/no-unreachable.md",
        .category = .correctness,
    },
    .run = run,
};

fn run(ctx: *Context) error{OutOfMemory}!void {
    for (ctx.module.declarations.items) |decl| switch (decl) {
        .function => |fd| if (fd.body) |body| try checkCompound(ctx, body),
        else => {},
    };
}

fn checkCompound(ctx: *Context, c: *Ast.CompoundStmt) error{OutOfMemory}!void {
    var seen_terminator = false;
    for (c.stmts.items) |stmt| {
        if (seen_terminator) {
            try report(ctx, stmt);
            continue;
        }
        try recurse(ctx, stmt);
        if (isTerminator(stmt)) seen_terminator = true;
    }
}

fn recurse(ctx: *Context, stmt: Ast.Stmt) error{OutOfMemory}!void {
    switch (stmt) {
        .compound => |s| try checkCompound(ctx, s),
        .@"if" => |s| {
            try checkCompound(ctx, s.body);
            if (s.else_branch) |eb| try recurse(ctx, eb);
        },
        .@"switch" => |s| for (s.cases.items) |case| try checkCompound(ctx, case.body),
        .@"for" => |s| try checkCompound(ctx, s.body),
        .@"while" => |s| try checkCompound(ctx, s.body),
        .loop => |s| {
            try checkCompound(ctx, s.body);
            if (s.continuing) |cc| try checkCompound(ctx, cc);
        },
        else => {},
    }
}

fn isTerminator(stmt: Ast.Stmt) bool {
    return switch (stmt) {
        .@"return", .@"break", .@"continue", .discard => true,
        else => false,
    };
}

fn report(ctx: *Context, stmt: Ast.Stmt) error{OutOfMemory}!void {
    const span = stmt.span();
    if (span.start == span.end) return;
    const msg = try ctx.fmt("unreachable code after terminator statement", .{});
    ctx.report(.{
        .message = msg,
        .range = ctx.makeRange(span.start, span.end),
    });
}
