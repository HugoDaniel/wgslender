//! `no-magic-numbers` — flag numeric literals that aren't in a small
//! allowlist. Rule-of-thumb: readers shouldn't have to guess what `3.14159`
//! means — if it's PI, name it.
//!
//! v1 allowlist (hard-coded): magnitudes `0`, `1`, `2`. Future slice can pull
//! this from rule options (`["warn", { "allowlist": [0, 1, 2, 255] }]`).
//!
//! The allowlist matches a literal's *spelling* — after stripping one `u` /
//! `i` / `f` / `h` suffix — not its value, so `ALLOWED_MAGNITUDES` is the
//! exact set that passes. Numerically-equal spellings outside it (`00`,
//! `0.00`, `.0`, `0x1`, `1e0`) are still reported; that's a known sharp edge
//! of spelling-matching, not an intentional call.
//!
//! Negative literals: WGSL writes `-1` as a unary `-` on a `1` literal, so
//! only the magnitude ever reaches `checkLiteral` — the sign is invisible to
//! this rule by construction. The allowlist is therefore sign-symmetric:
//! `-1` and `-2` pass exactly as `1` and `2` do, and `-3` reports at the `3`.
//!
//! Context exemptions. Only the `switch`-selector case is an explicit skip;
//! every other exemption falls out of *where the walk goes* — `run` descends
//! into declaration initializers and function bodies, and nothing else:
//!   * Attribute args — `@workgroup_size(x, y, z)`, `@group(N)`, `@binding(N)`,
//!     `@location(N)`, `@id(N)`, `@size(N)`, `@align(N)`. Attributes are never
//!     visited, so their operands (which *must* be numeric) never surface.
//!   * Type positions — `array<f32, 64>`. Types are never visited; naming an
//!     array size would defeat compile-time sizing anyway.
//!   * `switch` case selectors — pattern literals, skipped explicitly in
//!     `checkStmt`.
//!   * Anything inside a `const` / `override` declaration, whose whole job is
//!     to *be* the named numeric value.

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
        .description = "Report numeric literals outside a small allowlist (0, 1, 2, either sign) — readers shouldn't have to guess what a bare number means",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/no-magic-numbers.md",
        .category = .suspicious,
    },
    .run = run,
};

/// Literal spellings that pass, compared *after* `stripSuffix`. Spelling, not
/// value — see the module doc.
const ALLOWED_MAGNITUDES = [_][]const u8{ "0", "0.0", "0.", "1", "1.0", "1.", "2", "2.0", "2." };

fn isAllowedMagnitude(magnitude: []const u8) bool {
    for (ALLOWED_MAGNITUDES) |a| {
        if (std.mem.eql(u8, a, magnitude)) return true;
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
        .phony => |s| try checkExpr(ctx, s.expr),
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
        .literal => |lit| try checkLiteral(ctx, lit),
        // `-1` reaches `checkLiteral` as a bare `1`; the allowlist is
        // sign-symmetric, so the operand needs no negation context.
        .unary => |u| try stack.append(ctx.arena, u.operand),
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

fn checkLiteral(ctx: *Context, lit: *Ast.LiteralExpr) error{OutOfMemory}!void {
    // Boolean literals aren't numbers; skip.
    if (std.mem.eql(u8, lit.value, "true") or std.mem.eql(u8, lit.value, "false")) return;

    // A leading `-` is a separate unary node, so this only ever sees the
    // magnitude — the allowlist covers both signs.
    if (isAllowedMagnitude(stripSuffix(lit.value))) return;

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
