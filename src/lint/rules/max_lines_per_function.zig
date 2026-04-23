//! `max-lines-per-function` — report functions whose body spans more
//! than N source lines. Default ceiling: 120. Line count is measured
//! on the function's `decl_span` (from the first attribute or `fn`
//! keyword through the closing `}`), so it naturally includes
//! attributes, parameter list, and return type.
//!
//! Configurable via `["warn", { "max": 200 }]`.

const std = @import("std");

const Rule = @import("../Rule.zig");
const Context = @import("../Context.zig");
const Diagnostic = @import("../../Diagnostic.zig");
const Ast = @import("../../Ast.zig");

pub const rule = Rule{
    .meta = .{
        .id = "max-lines-per-function",
        .code = Diagnostic.Code.lint_max_lines_per_function,
        .default_severity = .warning,
        .description = "Report functions whose source spans more than N lines (default 120)",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/max-lines-per-function.md",
        .category = .style,
    },
    .run = run,
};

const DEFAULT_MAX: u32 = 120;

fn run(ctx: *Context) error{OutOfMemory}!void {
    const max = readMax(ctx);
    for (ctx.module.declarations.items) |decl| switch (decl) {
        .function => |fd| try check(ctx, fd, max),
        else => {},
    };
}

fn readMax(ctx: *const Context) u32 {
    const opts = ctx.options orelse return DEFAULT_MAX;
    if (opts != .object) return DEFAULT_MAX;
    const v = opts.object.get("max") orelse return DEFAULT_MAX;
    return switch (v) {
        .integer => |i| if (i > 0) @intCast(i) else DEFAULT_MAX,
        else => DEFAULT_MAX,
    };
}

fn check(ctx: *Context, fd: *const Ast.FunctionDecl, max: u32) error{OutOfMemory}!void {
    const span = fd.decl_span;
    if (span.start >= span.end) return;
    const slice = ctx.sourceSlice(span.start, span.end);
    const lines = countLines(slice);
    if (lines <= max) return;

    const name_ref = fd.name;
    if (!name_ref.isValid()) return;
    const sym = ctx.module.symbols.items[name_ref.index()];
    const name_end = sym.loc + @as(u32, @intCast(sym.original_name.len));

    const msg = try ctx.fmt(
        "function '{s}' is {d} lines long ({d} is the configured max)",
        .{ sym.original_name, lines, max },
    );
    ctx.report(.{
        .message = msg,
        .range = ctx.makeRange(sym.loc, name_end),
    });
}

fn countLines(slice: []const u8) u32 {
    var n: u32 = 1;
    for (slice) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}
