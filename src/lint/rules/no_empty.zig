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

pub const rule = Rule{
    .meta = .{
        .id = "no-empty",
        .code = Diagnostic.Code.lint_no_empty,
        .default_severity = .warning,
        .description = "Report empty blocks attached to control-flow statements",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/no-empty.md",
        .category = .suspicious,
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
        .compound => |s| {
            try flagEmpty(ctx, s, "block");
            try walkCompound(ctx, s);
        },
        .@"if" => |s| {
            try flagEmpty(ctx, s.body, "if");
            try walkCompound(ctx, s.body);
            if (s.else_branch) |eb| {
                switch (eb) {
                    .compound => |ec| {
                        try flagEmpty(ctx, ec, "else");
                        try walkCompound(ctx, ec);
                    },
                    else => try walkStmt(ctx, eb),
                }
            }
        },
        .@"switch" => |s| {
            for (s.cases.items) |case| {
                try flagEmpty(ctx, case.body, "case");
                try walkCompound(ctx, case.body);
            }
        },
        .@"for" => |s| {
            try flagEmpty(ctx, s.body, "for");
            try walkCompound(ctx, s.body);
        },
        .@"while" => |s| {
            try flagEmpty(ctx, s.body, "while");
            try walkCompound(ctx, s.body);
        },
        .loop => |s| {
            try flagEmpty(ctx, s.body, "loop");
            try walkCompound(ctx, s.body);
            if (s.continuing) |cc| try walkCompound(ctx, cc);
        },
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
