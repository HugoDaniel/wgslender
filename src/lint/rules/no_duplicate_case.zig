//! `no-duplicate-case` — flag `switch` statements with two `case`
//! selectors that evaluate to the same literal value. The second
//! (and later) case is unreachable; the rule reports each duplicate
//! alongside a note pointing at the earlier selector.
//!
//! We only consider literal selectors (integer or boolean). Named
//! constants — `case MY_CONST:` — are allowed to coexist because we
//! can't cheaply prove their values without constant folding.

const std = @import("std");

const Rule = @import("../Rule.zig");
const Context = @import("../Context.zig");
const Diagnostic = @import("../../Diagnostic.zig");
const Ast = @import("../../Ast.zig");
const MultiVisitor = @import("../MultiVisitor.zig");

pub const rule = Rule{
    .meta = .{
        .id = "no-duplicate-case",
        .code = Diagnostic.Code.lint_no_duplicate_case,
        .default_severity = .warning,
        .description = "Report switch statements with duplicate case selectors",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/no-duplicate-case.md",
        .category = .correctness,
    },
    .listener = makeListener,
};

fn makeListener(ctx: *Context) error{OutOfMemory}!MultiVisitor.Listener {
    return .{ .ctx = ctx, .on_stmt = onStmt };
}

fn onStmt(opaque_ctx: *anyopaque, stmt: Ast.Stmt) error{OutOfMemory}!void {
    const ctx: *Context = @ptrCast(@alignCast(opaque_ctx));
    const s = switch (stmt) {
        .@"switch" => |sw| sw,
        else => return,
    };
    try checkSwitch(ctx, s);
}

const Seen = struct {
    value: []const u8,
    loc: u32,
    len: u32,
};

fn checkSwitch(ctx: *Context, s: *Ast.SwitchStmt) error{OutOfMemory}!void {
    var seen: std.ArrayList(Seen) = .empty;
    defer seen.deinit(ctx.arena);

    for (s.cases.items) |case| {
        for (case.selectors.items) |sel| {
            const lit = unwrapLiteral(sel) orelse continue;
            const norm = normalize(lit.value);
            if (findSeen(seen.items, norm)) |earlier| {
                const end = lit.loc + @as(u32, @intCast(lit.value.len));
                const earlier_end = earlier.loc + earlier.len;
                const msg = try ctx.fmt(
                    "duplicate case selector '{s}' — earlier selector on the same switch shadows this one",
                    .{lit.value},
                );
                ctx.report(.{
                    .message = msg,
                    .range = ctx.makeRange(lit.loc, end),
                    .related = try dupeRelated(ctx, earlier.loc, earlier_end, "previous selector here"),
                });
            } else {
                try seen.append(ctx.arena, .{
                    .value = norm,
                    .loc = lit.loc,
                    .len = @intCast(lit.value.len),
                });
            }
        }
    }
}

fn unwrapLiteral(expr: Ast.Expr) ?*Ast.LiteralExpr {
    return switch (expr) {
        .literal => |l| l,
        .paren => |p| unwrapLiteral(p.expr),
        else => null,
    };
}

fn findSeen(items: []const Seen, value: []const u8) ?Seen {
    for (items) |s| {
        if (std.mem.eql(u8, s.value, value)) return s;
    }
    return null;
}

/// Strip trailing WGSL numeric suffixes so `42` and `42u` collide.
fn normalize(v: []const u8) []const u8 {
    if (v.len == 0) return v;
    const last = v[v.len - 1];
    if (last == 'u' or last == 'i' or last == 'f' or last == 'h') {
        return v[0 .. v.len - 1];
    }
    return v;
}

fn dupeRelated(
    ctx: *Context,
    start: u32,
    end: u32,
    message: []const u8,
) error{OutOfMemory}![]const Diagnostic.RelatedInfo {
    const buf = try ctx.arena.alloc(Diagnostic.RelatedInfo, 1);
    buf[0] = .{
        .range = ctx.makeRange(start, end),
        .message = message,
    };
    return buf;
}
