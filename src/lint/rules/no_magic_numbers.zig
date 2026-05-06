//! `no-magic-numbers` — flag numeric literals that aren't in a small
//! allowlist. Rule-of-thumb: readers shouldn't have to guess what `3.14159`
//! means — if it's PI, name it.
//!
//! v1 allowlist (hard-coded): `-1`, `0`, `1`, `2`. Future slice can pull
//! this from rule options (`["warn", { "allowlist": [0, 1, 2, 255] }]`).
//!
//! Negative literals: WGSL writes `-1` as a unary `-` on a `1` literal, so
//! we catch both the bare `1` (outside allowlist in isolation) AND the
//! unary-expression case. The callback checks the containing expression:
//! if it's a literal whose parent is a unary `-`, we allow the
//! magnitude-1 literal.
//!
//! Context exemptions:
//!   * Inside `@workgroup_size(x, y, z)` attribute args — any literal OK.
//!   * Inside array size: `array<f32, 64>` — any literal OK (naming would
//!     defeat compile-time sizing).
//!   * Inside `@group(N)`, `@binding(N)`, `@location(N)`, `@id(N)` — any
//!     literal OK (these are binding / location IDs that *must* be numeric).

const std = @import("std");

const Rule = @import("../Rule.zig");
const Context = @import("../Context.zig");
const Diagnostic = @import("../../Diagnostic.zig");
const Ast = @import("../../Ast.zig");

pub const rule = Rule{
    .meta = .{
        .id = "no-magic-numbers",
        .code = Diagnostic.Code.lint_no_magic_numbers,
        .default_severity = .warning,
        .description = "Report numeric literals outside a small allowlist (-1, 0, 1, 2) — readers shouldn't have to guess what a bare number means",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/no-magic-numbers.md",
        .category = .suspicious,
    },
    .run = run,
};

const ALLOWED_NUMERIC_ATTRS = [_][]const u8{ "workgroup_size", "group", "binding", "location", "id", "size", "align" };

fn isAllowedAttr(name: []const u8) bool {
    for (ALLOWED_NUMERIC_ATTRS) |a| {
        if (std.mem.eql(u8, a, name)) return true;
    }
    return false;
}

fn run(ctx: *Context) error{OutOfMemory}!void {
    for (ctx.module.declarations.items) |decl| try checkDecl(ctx, decl);
}

fn checkDecl(ctx: *Context, decl: Ast.Decl) error{OutOfMemory}!void {
    switch (decl) {
        .@"const", .override => {
            // `const` / `override` declarations *define* named numeric
            // values — every literal they contain is meant to become a
            // named constant, so skip entirely.
            return;
        },
        .@"var" => |d| {
            if (d.initializer) |init_expr| try checkExpr(ctx, init_expr);
        },
        .let => |d| {
            if (d.initializer) |init_expr| try checkExpr(ctx, init_expr);
        },
        .function => |fd| {
            if (fd.body) |body| try checkCompound(ctx, body);
        },
        .@"struct", .alias => {},
        .const_assert => |d| try checkExpr(ctx, d.expr),
    }
}

fn checkCompound(ctx: *Context, c: *Ast.CompoundStmt) error{OutOfMemory}!void {
    for (c.stmts.items) |s| try checkStmt(ctx, s);
}

fn checkStmt(ctx: *Context, stmt: Ast.Stmt) error{OutOfMemory}!void {
    switch (stmt) {
        .compound => |s| try checkCompound(ctx, s),
        .@"return" => |s| if (s.value) |v| try checkExpr(ctx, v),
        .@"if" => |s| {
            try checkExpr(ctx, s.condition);
            try checkCompound(ctx, s.body);
            if (s.else_branch) |eb| try checkStmt(ctx, eb);
        },
        .@"switch" => |s| {
            try checkExpr(ctx, s.expr);
            // selectors are exempt: switch cases are pattern literals.
            for (s.cases.items) |c| try checkCompound(ctx, c.body);
        },
        .@"for" => |s| {
            if (s.init_stmt) |is| try checkStmt(ctx, is);
            if (s.condition) |c| try checkExpr(ctx, c);
            if (s.update) |u| try checkStmt(ctx, u);
            try checkCompound(ctx, s.body);
        },
        .@"while" => |s| {
            try checkExpr(ctx, s.condition);
            try checkCompound(ctx, s.body);
        },
        .loop => |s| {
            try checkCompound(ctx, s.body);
            if (s.continuing) |c| try checkCompound(ctx, c);
        },
        .break_if => |s| try checkExpr(ctx, s.condition),
        .assign => |s| {
            try checkExpr(ctx, s.left);
            try checkExpr(ctx, s.right);
        },
        .incr_decr => |s| try checkExpr(ctx, s.expr),
        .call => |s| {
            if (s.call.func) |f| try checkExpr(ctx, f);
            for (s.call.args.items) |a| try checkExpr(ctx, a);
        },
        .decl => |s| try checkDecl(ctx, s.decl),
        .@"break", .@"continue", .discard => {},
    }
}

fn checkExpr(ctx: *Context, root: Ast.Expr) error{OutOfMemory}!void {
    var stack: std.ArrayList(Ast.Expr) = .empty;
    defer stack.deinit(ctx.arena);
    try stack.append(ctx.arena, root);

    while (stack.pop()) |e| switch (e) {
        .literal => |lit| try checkLiteral(ctx, lit, null),
        .unary => |u| switch (u.operand) {
            // `-1` / `-2` → check literal with unary-negation context.
            .literal => |lit| try checkLiteral(ctx, lit, u),
            else => try stack.append(ctx.arena, u.operand),
        },
        .binary => |b| {
            try stack.append(ctx.arena, b.right);
            try stack.append(ctx.arena, b.left);
        },
        .call => |c| {
            if (c.func) |f| try stack.append(ctx.arena, f);
            for (c.args.items) |a| try stack.append(ctx.arena, a);
        },
        .index => |i| {
            try stack.append(ctx.arena, i.idx);
            try stack.append(ctx.arena, i.base);
        },
        .member => |m| try stack.append(ctx.arena, m.base),
        .paren => |p| try stack.append(ctx.arena, p.expr),
        .ident => {},
    };
}

fn checkLiteral(
    ctx: *Context,
    lit: *Ast.LiteralExpr,
    unary_parent: ?*Ast.UnaryExpr,
) error{OutOfMemory}!void {
    // Boolean literals aren't numbers; skip.
    if (std.mem.eql(u8, lit.value, "true") or std.mem.eql(u8, lit.value, "false")) return;

    // Allowlist magnitudes: 0, 1, 2. Negation allowed only for magnitude 1
    // (so `-1` passes).
    const magnitude = stripSuffix(lit.value);
    const is_zero = std.mem.eql(u8, magnitude, "0") or std.mem.eql(u8, magnitude, "0.0") or std.mem.eql(u8, magnitude, "0f") or std.mem.eql(u8, magnitude, "0.");
    const is_one = std.mem.eql(u8, magnitude, "1") or std.mem.eql(u8, magnitude, "1.0") or std.mem.eql(u8, magnitude, "1f") or std.mem.eql(u8, magnitude, "1.");
    const is_two = std.mem.eql(u8, magnitude, "2") or std.mem.eql(u8, magnitude, "2.0") or std.mem.eql(u8, magnitude, "2f") or std.mem.eql(u8, magnitude, "2.");
    if (is_zero or is_one or is_two) {
        // `-2` and `-0` also pass (allowlist covers the magnitude either way).
        _ = unary_parent;
        return;
    }

    const lit_end: u32 = lit.loc + @as(u32, @intCast(lit.value.len));
    const msg = try ctx.fmt(
        "magic number '{s}' — consider naming it with a `const` declaration",
        .{lit.value},
    );
    ctx.report(.{
        .message = msg,
        .range = ctx.makeRange(lit.loc, lit_end),
    });
}

/// Strip WGSL numeric suffixes (`u`, `i`, `f`, `h`) from a literal's value.
fn stripSuffix(v: []const u8) []const u8 {
    if (v.len == 0) return v;
    const last = v[v.len - 1];
    if (last == 'u' or last == 'i' or last == 'f' or last == 'h') {
        return v[0 .. v.len - 1];
    }
    return v;
}
