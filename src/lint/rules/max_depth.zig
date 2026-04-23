//! `max-depth` — cap the nesting depth of control-flow statements
//! inside a function. Default ceiling is 4. Deep nesting obscures
//! reachability and, in compute shaders, makes uniformity harder to
//! reason about.
//!
//! Nesting counted: `if`, `else`, `for`, `while`, `loop`, `switch`,
//! and bare compound blocks. Each `case` body counts as +1.
//!
//! Configurable via `["warn", { "max": 3 }]`.

const std = @import("std");

const Rule = @import("../Rule.zig");
const Context = @import("../Context.zig");
const Diagnostic = @import("../../Diagnostic.zig");
const Ast = @import("../../Ast.zig");

pub const rule = Rule{
    .meta = .{
        .id = "max-depth",
        .code = Diagnostic.Code.lint_max_depth,
        .default_severity = .warning,
        .description = "Report functions whose nesting depth exceeds N (default 4)",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/max-depth.md",
        .category = .style,
    },
    .run = run,
};

const DEFAULT_MAX: u32 = 4;

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
    const body = fd.body orelse return;
    const depth = compoundDepth(body);
    if (depth <= max) return;

    const name_ref = fd.name;
    if (!name_ref.isValid()) return;
    const sym = ctx.module.symbols.items[name_ref.index()];
    const name_end = sym.loc + @as(u32, @intCast(sym.original_name.len));

    const msg = try ctx.fmt(
        "function '{s}' nests to depth {d} ({d} is the configured max)",
        .{ sym.original_name, depth, max },
    );
    ctx.report(.{
        .message = msg,
        .range = ctx.makeRange(sym.loc, name_end),
    });
}

/// Depth of the deepest nested construct inside a compound body. The
/// body itself counts as 0 — we're measuring what the author added on
/// top of the entry block.
fn compoundDepth(c: *Ast.CompoundStmt) u32 {
    var m: u32 = 0;
    for (c.stmts.items) |stmt| {
        const d = stmtDepth(stmt);
        if (d > m) m = d;
    }
    return m;
}

fn stmtDepth(stmt: Ast.Stmt) u32 {
    return switch (stmt) {
        .compound => |s| 1 + compoundDepth(s),
        .@"if" => |s| 1 + @max(compoundDepth(s.body), if (s.else_branch) |eb| stmtDepth(eb) else 0),
        .@"for" => |s| 1 + compoundDepth(s.body),
        .@"while" => |s| 1 + compoundDepth(s.body),
        .loop => |s| 1 + compoundDepth(s.body),
        .@"switch" => |s| blk: {
            var m: u32 = 0;
            for (s.cases.items) |case| {
                const d = compoundDepth(case.body);
                if (d > m) m = d;
            }
            break :blk 1 + m;
        },
        else => 0,
    };
}
