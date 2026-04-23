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
    const cyclo = 1 + compoundDecisions(body);
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

fn compoundDecisions(c: *Ast.CompoundStmt) u32 {
    var n: u32 = 0;
    for (c.stmts.items) |stmt| n += stmtDecisions(stmt);
    return n;
}

fn stmtDecisions(stmt: Ast.Stmt) u32 {
    return switch (stmt) {
        .compound => |s| compoundDecisions(s),
        .@"if" => |s| blk: {
            var n: u32 = 1 + exprDecisions(s.condition) + compoundDecisions(s.body);
            if (s.else_branch) |eb| n += stmtDecisions(eb);
            break :blk n;
        },
        .@"for" => |s| blk: {
            var n: u32 = 1 + compoundDecisions(s.body);
            if (s.condition) |c| n += exprDecisions(c);
            break :blk n;
        },
        .@"while" => |s| 1 + exprDecisions(s.condition) + compoundDecisions(s.body),
        .loop => |s| blk: {
            var n: u32 = 1 + compoundDecisions(s.body);
            if (s.continuing) |cc| n += compoundDecisions(cc);
            break :blk n;
        },
        .@"switch" => |s| blk: {
            var n: u32 = exprDecisions(s.expr);
            for (s.cases.items) |case| n += 1 + compoundDecisions(case.body);
            break :blk n;
        },
        .break_if => |s| 1 + exprDecisions(s.condition),
        .@"return" => |s| if (s.value) |v| exprDecisions(v) else 0,
        .assign => |s| exprDecisions(s.left) + exprDecisions(s.right),
        .call => |s| blk: {
            var n: u32 = 0;
            if (s.call.func) |f| n += exprDecisions(f);
            for (s.call.args.items) |a| n += exprDecisions(a);
            break :blk n;
        },
        .incr_decr => |s| exprDecisions(s.expr),
        else => 0,
    };
}

/// Each `&&` / `||` in a condition is an additional independent path.
fn exprDecisions(root: Ast.Expr) u32 {
    var count: u32 = 0;
    var stack_buf: [64]Ast.Expr = undefined;
    var top: usize = 1;
    stack_buf[0] = root;
    while (top > 0) {
        top -= 1;
        const e = stack_buf[top];
        switch (e) {
            .binary => |b| {
                if (b.op == .logical_and or b.op == .logical_or) count += 1;
                if (top + 2 > stack_buf.len) continue;
                stack_buf[top] = b.left;
                stack_buf[top + 1] = b.right;
                top += 2;
            },
            .unary => |u| {
                if (top >= stack_buf.len) continue;
                stack_buf[top] = u.operand;
                top += 1;
            },
            .paren => |p| {
                if (top >= stack_buf.len) continue;
                stack_buf[top] = p.expr;
                top += 1;
            },
            .call => |c| {
                if (c.func) |f| {
                    if (top >= stack_buf.len) continue;
                    stack_buf[top] = f;
                    top += 1;
                }
                for (c.args.items) |a| {
                    if (top >= stack_buf.len) continue;
                    stack_buf[top] = a;
                    top += 1;
                }
            },
            .index => |i| {
                if (top + 2 > stack_buf.len) continue;
                stack_buf[top] = i.base;
                stack_buf[top + 1] = i.idx;
                top += 2;
            },
            .member => |m| {
                if (top >= stack_buf.len) continue;
                stack_buf[top] = m.base;
                top += 1;
            },
            .literal, .ident => {},
        }
    }
    return count;
}
