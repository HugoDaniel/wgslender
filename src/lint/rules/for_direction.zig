//! `for-direction` — detect for-loop patterns whose update moves the
//! counter *away* from the termination condition, producing an infinite
//! loop or a dead body.
//!
//! The rule only flags "obvious" mismatches: simple integer counters with
//! a literal comparison and a literal increment/decrement. Anything
//! fancier (templates, struct members, function-call bounds) is ignored
//! — false positives cost more than the occasional miss.
//!
//! Matching shapes:
//!   * condition: `i <op> rhs` where `<op>` is `<`, `<=`, `>`, `>=`.
//!   * update: `i++`, `i--`, `i += k`, `i -= k` (k > 0 literal).
//!
//! Flagged when:
//!   * cond uses `<` / `<=` AND update decrements `i`.
//!   * cond uses `>` / `>=` AND update increments `i`.

const std = @import("std");

const Rule = @import("../Rule.zig");
const Context = @import("../Context.zig");
const Diagnostic = @import("../../Diagnostic.zig");
const Ast = @import("../../Ast.zig");
const MultiVisitor = @import("../MultiVisitor.zig");

pub const rule = Rule{
    .meta = .{
        .id = "for-direction",
        .code = Diagnostic.Code.lint_for_direction,
        .default_severity = .warning,
        .description = "Report for-loops whose update moves the counter away from the termination condition",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/for-direction.md",
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
        .@"for" => |f| f,
        else => return,
    };
    try checkFor(ctx, s);
}

const Direction = enum { up, down };

fn checkFor(ctx: *Context, s: *Ast.ForStmt) error{OutOfMemory}!void {
    const cond = s.condition orelse return;
    const bin = switch (cond) {
        .binary => |b| b,
        else => return,
    };
    const cmp_dir: Direction = switch (bin.op) {
        .lt, .le => .up,
        .gt, .ge => .down,
        else => return,
    };
    const counter_ref = identRef(bin.left) orelse return;

    const update = s.update orelse return;
    const update_dir = updateDirection(update, counter_ref) orelse return;
    if (update_dir == cmp_dir) return;

    const span = s.span;
    if (span.start == span.end) return;
    const msg = try ctx.fmt(
        "for-loop update moves counter away from termination — condition '{s}' vs update in the opposite direction",
        .{bin.op.string()},
    );
    ctx.report(.{
        .message = msg,
        .range = ctx.makeRange(span.start, span.end),
    });
}

fn identRef(expr: Ast.Expr) ?Ast.SymbolIndex {
    return switch (expr) {
        .ident => |i| if (i.ref.isValid()) i.ref else null,
        .paren => |p| identRef(p.expr),
        else => null,
    };
}

fn updateDirection(stmt: Ast.Stmt, counter: Ast.SymbolIndex) ?Direction {
    switch (stmt) {
        .incr_decr => |s| {
            const ref = identRef(s.expr) orelse return null;
            if (ref != counter) return null;
            return if (s.increment) .up else .down;
        },
        .assign => |s| {
            const ref = identRef(s.left) orelse return null;
            if (ref != counter) return null;
            return switch (s.op) {
                .add => if (isPositiveLiteral(s.right)) Direction.up else null,
                .sub => if (isPositiveLiteral(s.right)) Direction.down else null,
                else => null,
            };
        },
        else => return null,
    }
}

fn isPositiveLiteral(expr: Ast.Expr) bool {
    return switch (expr) {
        .literal => |l| !std.mem.startsWith(u8, l.value, "-") and !std.mem.eql(u8, l.value, "0") and !std.mem.eql(u8, l.value, "0u") and !std.mem.eql(u8, l.value, "0i"),
        .paren => |p| isPositiveLiteral(p.expr),
        else => false,
    };
}
