//! `complexity` — cyclomatic complexity ceiling per function. McCabe's
//! metric counts linearly-independent paths through the body. We use
//! the practical formulation:
//!
//!     complexity = 1 + decisions
//!
//! where a decision is each `if`, `else if`, each case in a `switch`,
//! each loop (`for`/`while`/`loop`), each `&&` / `||`, and each
//! `break if` in a continuing block.
//!
//! Default ceiling: 15. Configurable via `["warn", { "max": 10 }]`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Rule = @import("../Rule.zig");
const Context = @import("../Context.zig");
const Diagnostic = @import("../../Diagnostic.zig");
const Ast = @import("../../Ast.zig");

pub const rule = Rule{
    .meta = .{
        .id = "complexity",
        .code = Diagnostic.Code.lint_complexity,
        .default_severity = .warning,
        .description = "Report functions whose cyclomatic complexity exceeds N (default 15)",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/complexity.md",
        .category = .style,
    },
    .run = run,
};

const DEFAULT_MAX: u32 = 15;

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
    const cyclo = 1 + try compoundDecisions(ctx.arena, body);
    if (cyclo <= max) return;

    const name_ref = fd.name;
    if (!name_ref.isValid()) return;
    const sym = ctx.module.symbols.items[name_ref.index()];
    const name_end = sym.loc + @as(u32, @intCast(sym.original_name.len));

    const msg = try ctx.fmt(
        "function '{s}' has cyclomatic complexity {d} ({d} is the configured max)",
        .{ sym.original_name, cyclo, max },
    );
    ctx.report(.{
        .message = msg,
        .range = ctx.makeRange(sym.loc, name_end),
    });
}

fn compoundDecisions(arena: Allocator, c: *Ast.CompoundStmt) error{OutOfMemory}!u32 {
    var n: u32 = 0;
    for (c.stmts.items) |stmt| n += try stmtDecisions(arena, stmt);
    return n;
}

fn stmtDecisions(arena: Allocator, stmt: Ast.Stmt) error{OutOfMemory}!u32 {
    return switch (stmt) {
        .compound => |s| try compoundDecisions(arena, s),
        .@"if" => |s| blk: {
            var n: u32 = 1 + (try exprDecisions(arena, s.condition)) + (try compoundDecisions(arena, s.body));
            if (s.else_branch) |eb| n += try stmtDecisions(arena, eb);
            break :blk n;
        },
        .@"for" => |s| blk: {
            var n: u32 = 1 + (try compoundDecisions(arena, s.body));
            if (s.condition) |c| n += try exprDecisions(arena, c);
            break :blk n;
        },
        .@"while" => |s| 1 + (try exprDecisions(arena, s.condition)) + (try compoundDecisions(arena, s.body)),
        .loop => |s| blk: {
            var n: u32 = 1 + (try compoundDecisions(arena, s.body));
            if (s.continuing) |cc| n += try compoundDecisions(arena, cc);
            break :blk n;
        },
        .@"switch" => |s| blk: {
            var n: u32 = try exprDecisions(arena, s.expr);
            for (s.cases.items) |case| n += 1 + (try compoundDecisions(arena, case.body));
            break :blk n;
        },
        .break_if => |s| 1 + (try exprDecisions(arena, s.condition)),
        .@"return" => |s| if (s.value) |v| try exprDecisions(arena, v) else 0,
        .assign => |s| (try exprDecisions(arena, s.left)) + (try exprDecisions(arena, s.right)),
        .call => |s| blk: {
            var n: u32 = 0;
            if (s.call.func) |f| n += try exprDecisions(arena, f);
            for (s.call.args.items) |a| n += try exprDecisions(arena, a);
            break :blk n;
        },
        .incr_decr => |s| try exprDecisions(arena, s.expr),
        else => 0,
    };
}

/// Each `&&` / `||` in a condition is an additional independent path.
/// Arena-backed iterative walk — the expression tree can nest arbitrarily
/// deep, so the traversal stack must grow (a fixed buffer silently dropped
/// subtrees past its cap, under-counting deeply nested conditions).
fn exprDecisions(arena: Allocator, root: Ast.Expr) error{OutOfMemory}!u32 {
    var count: u32 = 0;
    var stack: std.ArrayList(Ast.Expr) = .empty;
    defer stack.deinit(arena);
    try stack.append(arena, root);
    while (stack.pop()) |e| switch (e) {
        .binary => |b| {
            if (b.op == .logical_and or b.op == .logical_or) count += 1;
            try stack.append(arena, b.left);
            try stack.append(arena, b.right);
        },
        .unary => |u| try stack.append(arena, u.operand),
        .paren => |p| try stack.append(arena, p.expr),
        .call => |c| {
            if (c.func) |f| try stack.append(arena, f);
            for (c.args.items) |a| try stack.append(arena, a);
        },
        .index => |i| {
            try stack.append(arena, i.base);
            try stack.append(arena, i.idx);
        },
        .member => |m| try stack.append(arena, m.base),
        .literal, .ident => {},
    };
    return count;
}
