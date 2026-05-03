//! `no-redundant-casts` — flag a scalar "cast" constructor whose
//! argument is already the target type. In WGSL, casts look like
//! function calls: `f32(x)`, `u32(y)`, `i32(z)`, `bool(w)`, `f16(v)`.
//! When the argument's inferred type already matches, the call is a
//! no-op — just noise the reader has to parse past.
//!
//! Autofix replaces the whole call with the argument, preserving the
//! argument's source text exactly (whitespace and all).
//!
//! We only look at the *five scalar cast constructors*. `vec3<f32>(v)`
//! with `v: vec3<f32>` is technically also redundant, but the number of
//! vector/matrix constructor shapes makes the false-positive surface
//! wider than the value is worth. Scalar casts are the common case.

const std = @import("std");

const Rule = @import("../Rule.zig");
const Context = @import("../Context.zig");
const Diagnostic = @import("../../Diagnostic.zig");
const Ast = @import("../../Ast.zig");
const Types = @import("../../Types.zig");
const walk = @import("../walk.zig");
const MultiVisitor = @import("../MultiVisitor.zig");
const exprStart = walk.exprStart;
const exprEnd = walk.exprEnd;

pub const rule = Rule{
    .meta = .{
        .id = "no-redundant-casts",
        .code = Diagnostic.Code.lint_no_redundant_casts,
        .default_severity = .warning,
        .description = "Report scalar cast constructors (f32/u32/i32/bool/f16) whose argument already has the target type",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/no-redundant-casts.md",
        .category = .suspicious,
        .fixable = true,
    },
    .run = run,
};

fn run(ctx: *Context) error{OutOfMemory}!void {
    try MultiVisitor.walk(ctx.arena, ctx.module, &.{
        .{ .ctx = ctx, .on_expr = onExpr },
    });
}

fn onExpr(opaque_ctx: *anyopaque, e: Ast.Expr) error{OutOfMemory}!void {
    const ctx: *Context = @ptrCast(@alignCast(opaque_ctx));
    const call = switch (e) {
        .call => |c| c,
        else => return,
    };
    const target = castTarget(call) orelse return;
    if (call.args.items.len != 1) return;
    const arg = call.args.items[0];

    const arg_kind = scalarKindOf(ctx, arg) orelse return;
    if (arg_kind != target) return;

    try reportMatch(ctx, call, arg, target);
}

/// For a call expression, return the scalar kind the constructor
/// produces — null for anything that isn't one of our five recognized
/// cast identifiers.
fn castTarget(call: *Ast.CallExpr) ?Types.ScalarKind {
    const func = call.func orelse return null;
    const name = switch (func) {
        .ident => |i| i.name,
        else => return null,
    };
    if (std.mem.eql(u8, name, "f32")) return .f32;
    if (std.mem.eql(u8, name, "u32")) return .u32;
    if (std.mem.eql(u8, name, "i32")) return .i32;
    if (std.mem.eql(u8, name, "bool")) return .bool;
    if (std.mem.eql(u8, name, "f16")) return .f16;
    return null;
}

fn scalarKindOf(ctx: *const Context, e: Ast.Expr) ?Types.ScalarKind {
    const key = exprKey(e) orelse return null;
    const info = ctx.analysis.expr_types.get(key) orelse return null;
    return switch (info.typ) {
        .scalar => |s| s.kind,
        else => null,
    };
}

fn exprKey(e: Ast.Expr) ?u32 {
    return switch (e) {
        .literal => |x| x.loc,
        .ident => |x| x.loc,
        .binary => |x| x.loc,
        .unary => |x| x.loc,
        .call => |x| x.loc,
        .index => |x| x.loc,
        .member => |x| x.loc,
        .paren => |p| exprKey(p.expr),
    };
}

fn reportMatch(
    ctx: *Context,
    call: *Ast.CallExpr,
    arg: Ast.Expr,
    target: Types.ScalarKind,
) !void {
    const start = call.loc;
    const end = call.end_loc;
    if (start == end) return;

    const arg_start = exprStart(arg);
    const arg_end = exprEnd(arg);
    if (arg_start == arg_end) return;
    const arg_text = ctx.sourceSlice(arg_start, arg_end);

    const fix = try ctx.arena.create(Diagnostic.Fix);
    fix.* = .{
        .range = ctx.makeRange(start, end),
        .text = try ctx.arena.dupe(u8, arg_text),
    };

    const msg = try ctx.fmt(
        "redundant cast to '{s}' — argument is already '{s}'",
        .{ scalarName(target), scalarName(target) },
    );
    ctx.report(.{
        .message = msg,
        .range = ctx.makeRange(start, end),
        .fix = fix,
    });
}

fn scalarName(k: Types.ScalarKind) []const u8 {
    return switch (k) {
        .f32 => "f32",
        .u32 => "u32",
        .i32 => "i32",
        .bool => "bool",
        .f16 => "f16",
        .abstract_int => "abstract-int",
        .abstract_float => "abstract-float",
    };
}
