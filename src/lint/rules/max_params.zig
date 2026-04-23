//! `max-params` — cap the number of parameters on a single function.
//! Default ceiling is 8, which matches WGSL's practical pipeline-layout
//! width and most style-guide limits for non-shader code.
//!
//! Configurable via `["warn", { "max": 4 }]`.

const std = @import("std");

const Rule = @import("../Rule.zig");
const Context = @import("../Context.zig");
const Diagnostic = @import("../../Diagnostic.zig");

pub const rule = Rule{
    .meta = .{
        .id = "max-params",
        .code = Diagnostic.Code.lint_max_params,
        .default_severity = .warning,
        .description = "Report functions with more than N parameters (default 8)",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/max-params.md",
        .category = .style,
    },
    .run = run,
};

const DEFAULT_MAX: u32 = 8;

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

fn check(ctx: *Context, fd: anytype, max: u32) error{OutOfMemory}!void {
    const count: u32 = @intCast(fd.parameters.items.len);
    if (count <= max) return;

    const name_ref = fd.name;
    if (!name_ref.isValid()) return;
    const sym = ctx.module.symbols.items[name_ref.index()];
    const name_end = sym.loc + @as(u32, @intCast(sym.original_name.len));

    const msg = try ctx.fmt(
        "function '{s}' has {d} parameters ({d} is the configured max)",
        .{ sym.original_name, count, max },
    );
    ctx.report(.{
        .message = msg,
        .range = ctx.makeRange(sym.loc, name_end),
    });
}
