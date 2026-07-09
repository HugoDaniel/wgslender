//! Engine-level signature tests for `src/Operators.zig` — resolve operator
//! overload sets directly through the `Overload` solver, independent of the
//! validator wiring. This is the per-family "red first" unit gate the
//! Block 2.1 migration lands alongside each family; the end-to-end behavior
//! is separately pinned by `tests/inference/operator_result_pin_test.zig`.
//!
//! Convention: `resolveBinary` returns the materialized result-type string on
//! a match, or `null` on no-match. A `null` for an operand pair that the old
//! hand-rolled checker accepted-then-silently-failed is the *intended* fix —
//! the engine rejects invalid shapes instead of swallowing them.

const std = @import("std");
const wgslender = @import("wgslender");

const Operators = wgslender.Operators;
const Overload = wgslender.Overload;
const Types = wgslender.Types;
const Ast = wgslender.Ast;

/// Resolve `op` against (a, b); return the winning overload's materialized
/// result-type string, or null when no overload matches.
fn resolveBinary(arena: std.mem.Allocator, op: Ast.BinaryOp, a: Types.Type, b: Types.Type) !?[]const u8 {
    const sigs = Operators.binarySigs(op);
    const args = [_]?Types.Type{ a, b };
    return switch (Overload.resolve(sigs, &args)) {
        .err => null,
        .ok => |ok| blk: {
            const sig = sigs[ok.sig_index];
            const t: Types.Type = switch (sig.result) {
                .fixed => |ft| ft,
                .pattern => |p| (try Overload.buildPatternType(arena, p, &ok.bindings)) orelse
                    return error.UnboundResultPattern,
                // Comparison / equality: bool-shaped like the indexed operand.
                // Reproduces `Validator.buildOverloadResult`'s materialization
                // (which needs the arg types, not just the bindings).
                .bool_shape_of => |idx| bs: {
                    const at = if (idx == 0) a else b;
                    if (at == .vector) {
                        const bv = try arena.create(Types.Vector);
                        bv.* = .{ .width = at.vector.width, .element = Types.scalar_bool_ptr };
                        break :bs Types.Type{ .vector = bv };
                    }
                    break :bs Types.Bool;
                },
                else => return error.UnexpectedResultRule,
            };
            break :blk t.string();
        },
    };
}

fn vecT(arena: std.mem.Allocator, width: u8, elem: *const Types.Scalar) !Types.Type {
    const v = try arena.create(Types.Vector);
    v.* = .{ .width = width, .element = elem };
    return .{ .vector = v };
}

fn matT(arena: std.mem.Allocator, cols: u8, rows: u8, elem: *const Types.Scalar) !Types.Type {
    const m = try arena.create(Types.Matrix);
    m.* = .{ .cols = cols, .rows = rows, .element = elem };
    return .{ .matrix = m };
}

test "logical &&/|| : only (bool, bool) resolves, to bool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]Ast.BinaryOp{ .logical_and, .logical_or }) |op| {
        try std.testing.expectEqualStrings("bool", (try resolveBinary(a, op, Types.Bool, Types.Bool)).?);
        try std.testing.expect((try resolveBinary(a, op, Types.I32, Types.Bool)) == null);
        try std.testing.expect((try resolveBinary(a, op, Types.Bool, Types.I32)) == null);
        try std.testing.expect((try resolveBinary(a, op, Types.U32, Types.U32)) == null);
    }
}

test "bitwise &/|/^ : bool^bool -> bool; int^int -> common; vecN<int> matched by width+sign" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const vec3i = try vecT(a, 3, Types.scalar_i32_ptr);
    const vec2i = try vecT(a, 2, Types.scalar_i32_ptr);
    const vec3u = try vecT(a, 3, Types.scalar_u32_ptr);

    for ([_]Ast.BinaryOp{ .@"and", .@"or", .xor }) |op| {
        // bool ^ bool -> bool
        try std.testing.expectEqualStrings("bool", (try resolveBinary(a, op, Types.Bool, Types.Bool)).?);
        // int scalars, same and mixed-abstract -> common concrete
        try std.testing.expectEqualStrings("i32", (try resolveBinary(a, op, Types.I32, Types.I32)).?);
        try std.testing.expectEqualStrings("u32", (try resolveBinary(a, op, Types.U32, Types.U32)).?);
        try std.testing.expectEqualStrings("i32", (try resolveBinary(a, op, Types.AbstractInt, Types.I32)).?);
        try std.testing.expectEqualStrings("u32", (try resolveBinary(a, op, Types.U32, Types.AbstractInt)).?);
        // int vectors: same width+sign only
        try std.testing.expectEqualStrings("vec3<i32>", (try resolveBinary(a, op, vec3i, vec3i)).?);

        // --- intended fixes: shapes the old checker silently failed on ---
        try std.testing.expect((try resolveBinary(a, op, Types.I32, Types.U32)) == null); // mixed sign scalar
        try std.testing.expect((try resolveBinary(a, op, vec3i, vec3u)) == null); // mixed sign vector
        try std.testing.expect((try resolveBinary(a, op, vec3i, vec2i)) == null); // width mismatch
        try std.testing.expect((try resolveBinary(a, op, Types.I32, vec3i)) == null); // scalar vs vector
        // non-integer scalars never match
        try std.testing.expect((try resolveBinary(a, op, Types.F32, Types.F32)) == null);
        try std.testing.expect((try resolveBinary(a, op, Types.Bool, Types.I32)) == null);
    }
}

test "shifts <</>> : int<<u32 -> the LHS type; RHS is u32/abstract; vectors matched by width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const vec3i = try vecT(a, 3, Types.scalar_i32_ptr);
    const vec2i = try vecT(a, 2, Types.scalar_i32_ptr);
    const vec3u = try vecT(a, 3, Types.scalar_u32_ptr);
    const vec2u = try vecT(a, 2, Types.scalar_u32_ptr);

    for ([_]Ast.BinaryOp{ .shl, .shr }) |op| {
        // Asymmetric: the result is the *LHS* integer type, independent of the
        // (u32) shift amount. i32<<u32 -> i32, not a common type.
        try std.testing.expectEqualStrings("i32", (try resolveBinary(a, op, Types.I32, Types.U32)).?);
        try std.testing.expectEqualStrings("u32", (try resolveBinary(a, op, Types.U32, Types.U32)).?);
        try std.testing.expectEqualStrings("i32", (try resolveBinary(a, op, Types.I32, Types.AbstractInt)).?); // abstract RHS ok
        try std.testing.expect((try resolveBinary(a, op, Types.AbstractInt, Types.U32)) != null); // abstract LHS ok

        // RHS shift amount is u32-family only: i32/f32/bool amounts are rejected.
        try std.testing.expect((try resolveBinary(a, op, Types.I32, Types.I32)) == null);
        try std.testing.expect((try resolveBinary(a, op, Types.U32, Types.I32)) == null);
        try std.testing.expect((try resolveBinary(a, op, Types.I32, Types.F32)) == null);
        try std.testing.expect((try resolveBinary(a, op, Types.I32, Types.Bool)) == null);
        // LHS must be integer.
        try std.testing.expect((try resolveBinary(a, op, Types.F32, Types.U32)) == null);
        try std.testing.expect((try resolveBinary(a, op, Types.Bool, Types.U32)) == null);

        // Vectors: component-wise, RHS is vecN<u32> of matching width; result
        // is the LHS vector.
        try std.testing.expectEqualStrings("vec3<i32>", (try resolveBinary(a, op, vec3i, vec3u)).?);
        try std.testing.expectEqualStrings("vec3<u32>", (try resolveBinary(a, op, vec3u, vec3u)).?);
        try std.testing.expectEqualStrings("vec2<i32>", (try resolveBinary(a, op, vec2i, vec2u)).?);
        // Width mismatch, i32 shift amount, and scalar<->vector shapes reject.
        try std.testing.expect((try resolveBinary(a, op, vec3i, vec2u)) == null);
        try std.testing.expect((try resolveBinary(a, op, vec3i, vec3i)) == null);
        try std.testing.expect((try resolveBinary(a, op, vec3i, Types.U32)) == null);
        try std.testing.expect((try resolveBinary(a, op, Types.I32, vec3u)) == null);
    }
}

test "comparisons < <= > >= : common numeric scalar/vector -> bool-shaped; bool/matrix/mixed reject" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const vec2f = try vecT(a, 2, Types.scalar_f32_ptr);
    const vec2i = try vecT(a, 2, Types.scalar_i32_ptr);
    const vec3i = try vecT(a, 3, Types.scalar_i32_ptr);
    const vec2u = try vecT(a, 2, Types.scalar_u32_ptr);
    const vec3b = try vecT(a, 3, Types.scalar_bool_ptr);
    const mat2x2 = try matT(a, 2, 2, Types.scalar_f32_ptr);

    for ([_]Ast.BinaryOp{ .lt, .le, .gt, .ge }) |op| {
        // Common numeric scalar -> bool (independent of the element type).
        try std.testing.expectEqualStrings("bool", (try resolveBinary(a, op, Types.I32, Types.I32)).?);
        try std.testing.expectEqualStrings("bool", (try resolveBinary(a, op, Types.U32, Types.U32)).?);
        try std.testing.expectEqualStrings("bool", (try resolveBinary(a, op, Types.F32, Types.F32)).?);
        try std.testing.expectEqualStrings("bool", (try resolveBinary(a, op, Types.AbstractInt, Types.I32)).?);
        try std.testing.expectEqualStrings("bool", (try resolveBinary(a, op, Types.AbstractInt, Types.AbstractInt)).?);
        // Common numeric vector -> vecN<bool>.
        try std.testing.expectEqualStrings("vec2<bool>", (try resolveBinary(a, op, vec2f, vec2f)).?);
        try std.testing.expectEqualStrings("vec3<bool>", (try resolveBinary(a, op, vec3i, vec3i)).?);

        // bool operands have no comparison form.
        try std.testing.expect((try resolveBinary(a, op, Types.Bool, Types.Bool)) == null);
        try std.testing.expect((try resolveBinary(a, op, vec3b, vec3b)) == null);
        // Mixed sign / int-vs-float never share a common type.
        try std.testing.expect((try resolveBinary(a, op, Types.I32, Types.U32)) == null);
        try std.testing.expect((try resolveBinary(a, op, Types.I32, Types.F32)) == null);
        try std.testing.expect((try resolveBinary(a, op, vec2i, vec2u)) == null);
        // Width mismatch and scalar<->vector shapes.
        try std.testing.expect((try resolveBinary(a, op, vec2i, vec3i)) == null);
        try std.testing.expect((try resolveBinary(a, op, Types.I32, vec2i)) == null);
        // Matrices (and other composites) match neither sig.
        try std.testing.expect((try resolveBinary(a, op, mat2x2, mat2x2)) == null);
    }
}

test "equality == != : any scalar/vector incl bool -> bool-shaped; matrix rejects; mismatch rejects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const vec2i = try vecT(a, 2, Types.scalar_i32_ptr);
    const vec3i = try vecT(a, 3, Types.scalar_i32_ptr);
    const vec2u = try vecT(a, 2, Types.scalar_u32_ptr);
    const vec3b = try vecT(a, 3, Types.scalar_bool_ptr);
    const mat2x2 = try matT(a, 2, 2, Types.scalar_f32_ptr);

    for ([_]Ast.BinaryOp{ .eq, .ne }) |op| {
        // Any common scalar -> bool. Unlike comparison, bool operands ARE
        // comparable with == / !=.
        try std.testing.expectEqualStrings("bool", (try resolveBinary(a, op, Types.I32, Types.I32)).?);
        try std.testing.expectEqualStrings("bool", (try resolveBinary(a, op, Types.U32, Types.U32)).?);
        try std.testing.expectEqualStrings("bool", (try resolveBinary(a, op, Types.F32, Types.F32)).?);
        try std.testing.expectEqualStrings("bool", (try resolveBinary(a, op, Types.Bool, Types.Bool)).?);
        try std.testing.expectEqualStrings("bool", (try resolveBinary(a, op, Types.AbstractInt, Types.I32)).?);
        // Any common vector -> vecN<bool>, including vecN<bool> operands.
        try std.testing.expectEqualStrings("vec2<bool>", (try resolveBinary(a, op, vec2i, vec2i)).?);
        try std.testing.expectEqualStrings("vec3<bool>", (try resolveBinary(a, op, vec3b, vec3b)).?);

        // Mixed sign / int-vs-float / scalar-bool-vs-int never share a type.
        try std.testing.expect((try resolveBinary(a, op, Types.I32, Types.U32)) == null);
        try std.testing.expect((try resolveBinary(a, op, Types.I32, Types.F32)) == null);
        try std.testing.expect((try resolveBinary(a, op, Types.I32, Types.Bool)) == null);
        try std.testing.expect((try resolveBinary(a, op, vec2i, vec2u)) == null);
        // Width mismatch and scalar<->vector shapes.
        try std.testing.expect((try resolveBinary(a, op, vec2i, vec3i)) == null);
        try std.testing.expect((try resolveBinary(a, op, Types.I32, vec2i)) == null);
        // Matrices have no equality overload (the pre-engine checker silently
        // accepted `mat == mat` and returned bool — now correctly rejected).
        try std.testing.expect((try resolveBinary(a, op, mat2x2, mat2x2)) == null);
    }
}

test "additive + - : common numeric scalar/vector, scalar broadcast, same-shape matrix; bool rejects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const vec2f = try vecT(a, 2, Types.scalar_f32_ptr);
    const vec3f = try vecT(a, 3, Types.scalar_f32_ptr);
    const vec2i = try vecT(a, 2, Types.scalar_i32_ptr);
    const vec3b = try vecT(a, 3, Types.scalar_bool_ptr);
    const mat2x3 = try matT(a, 2, 3, Types.scalar_f32_ptr);
    const mat3x2 = try matT(a, 3, 2, Types.scalar_f32_ptr);

    for ([_]Ast.BinaryOp{ .add, .sub }) |op| {
        // Common numeric scalar; abstract yields to the concrete partner.
        try std.testing.expectEqualStrings("i32", (try resolveBinary(a, op, Types.I32, Types.I32)).?);
        try std.testing.expectEqualStrings("f32", (try resolveBinary(a, op, Types.F32, Types.F32)).?);
        try std.testing.expectEqualStrings("i32", (try resolveBinary(a, op, Types.AbstractInt, Types.I32)).?);
        try std.testing.expectEqualStrings("f32", (try resolveBinary(a, op, Types.F32, Types.AbstractInt)).?);
        // Common numeric vector.
        try std.testing.expectEqualStrings("vec2<f32>", (try resolveBinary(a, op, vec2f, vec2f)).?);
        try std.testing.expectEqualStrings("vec2<i32>", (try resolveBinary(a, op, vec2i, vec2i)).?);
        // Scalar broadcast, both directions; the scalar's element must match.
        try std.testing.expectEqualStrings("vec2<f32>", (try resolveBinary(a, op, vec2f, Types.F32)).?);
        try std.testing.expectEqualStrings("vec2<f32>", (try resolveBinary(a, op, Types.F32, vec2f)).?);
        try std.testing.expectEqualStrings("vec2<i32>", (try resolveBinary(a, op, vec2i, Types.AbstractInt)).?);
        // An abstract-int scalar broadcasts into a float / uint vector, unifying
        // to the vector's element (the old checker concretized it to i32 first
        // and wrongly rejected `1 + vec2<f32>`).
        try std.testing.expectEqualStrings("vec2<f32>", (try resolveBinary(a, op, Types.AbstractInt, vec2f)).?);
        // Same-shape matrix (+/- require identical dimensions).
        try std.testing.expectEqualStrings("mat2x3<f32>", (try resolveBinary(a, op, mat2x3, mat2x3)).?);

        // --- rejections ---
        // bool operands are not numeric (the old checker wrongly returned bool).
        try std.testing.expect((try resolveBinary(a, op, Types.Bool, Types.Bool)) == null);
        try std.testing.expect((try resolveBinary(a, op, vec3b, vec3b)) == null);
        try std.testing.expect((try resolveBinary(a, op, vec3b, Types.Bool)) == null);
        // Mixed sign / int-vs-float / width / scalar<->vector.
        try std.testing.expect((try resolveBinary(a, op, Types.I32, Types.U32)) == null);
        try std.testing.expect((try resolveBinary(a, op, Types.I32, Types.F32)) == null);
        try std.testing.expect((try resolveBinary(a, op, vec2f, vec3f)) == null);
        try std.testing.expect((try resolveBinary(a, op, vec2f, vec2i)) == null);
        try std.testing.expect((try resolveBinary(a, op, Types.I32, vec2f)) == null);
        // Different-shape matrices do not add.
        try std.testing.expect((try resolveBinary(a, op, mat2x3, mat3x2)) == null);
    }
}

test "division / : common numeric scalar/vector, scalar broadcast; no matrix form; bool rejects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const vec2f = try vecT(a, 2, Types.scalar_f32_ptr);
    const vec3f = try vecT(a, 3, Types.scalar_f32_ptr);
    const vec2i = try vecT(a, 2, Types.scalar_i32_ptr);
    const vec2u = try vecT(a, 2, Types.scalar_u32_ptr);
    const vec3b = try vecT(a, 3, Types.scalar_bool_ptr);
    const mat2x2 = try matT(a, 2, 2, Types.scalar_f32_ptr);
    const mat2x3 = try matT(a, 2, 3, Types.scalar_f32_ptr);

    // Common numeric scalar; abstract yields to the concrete partner.
    try std.testing.expectEqualStrings("i32", (try resolveBinary(a, .div, Types.I32, Types.I32)).?);
    try std.testing.expectEqualStrings("f32", (try resolveBinary(a, .div, Types.F32, Types.F32)).?);
    try std.testing.expectEqualStrings("i32", (try resolveBinary(a, .div, Types.AbstractInt, Types.I32)).?);
    try std.testing.expectEqualStrings("f32", (try resolveBinary(a, .div, Types.F32, Types.AbstractInt)).?);
    // Common numeric vector.
    try std.testing.expectEqualStrings("vec2<f32>", (try resolveBinary(a, .div, vec2f, vec2f)).?);
    try std.testing.expectEqualStrings("vec2<u32>", (try resolveBinary(a, .div, vec2u, vec2u)).?);
    // Scalar broadcast, both directions.
    try std.testing.expectEqualStrings("vec2<f32>", (try resolveBinary(a, .div, vec2f, Types.F32)).?);
    try std.testing.expectEqualStrings("vec2<f32>", (try resolveBinary(a, .div, Types.F32, vec2f)).?);
    // An abstract-int scalar broadcasts into a float / uint vector, unifying to
    // the vector's element (the old `divResultType` concretized it to i32 first
    // and wrongly rejected `1 / vec2<f32>` and `1 / vec2<u32>`).
    try std.testing.expectEqualStrings("vec2<f32>", (try resolveBinary(a, .div, Types.AbstractInt, vec2f)).?);
    try std.testing.expectEqualStrings("vec2<u32>", (try resolveBinary(a, .div, vec2u, Types.AbstractInt)).?);

    // --- rejections ---
    // WGSL defines no matrix division; unlike +/- there is no composite form
    // (the old `commonType` fast path wrongly accepted `mat / mat`).
    try std.testing.expect((try resolveBinary(a, .div, mat2x2, mat2x2)) == null);
    try std.testing.expect((try resolveBinary(a, .div, mat2x3, mat2x3)) == null);
    try std.testing.expect((try resolveBinary(a, .div, mat2x2, Types.F32)) == null);
    // bool operands are not numeric (the old checker wrongly returned bool).
    try std.testing.expect((try resolveBinary(a, .div, Types.Bool, Types.Bool)) == null);
    try std.testing.expect((try resolveBinary(a, .div, vec3b, vec3b)) == null);
    // Mixed sign / int-vs-float / width / elem / scalar<->vector.
    try std.testing.expect((try resolveBinary(a, .div, Types.I32, Types.U32)) == null);
    try std.testing.expect((try resolveBinary(a, .div, Types.I32, Types.F32)) == null);
    try std.testing.expect((try resolveBinary(a, .div, vec2f, vec3f)) == null);
    try std.testing.expect((try resolveBinary(a, .div, vec2f, vec2i)) == null);
    try std.testing.expect((try resolveBinary(a, .div, Types.I32, vec2f)) == null);
}

test "modulo % : common numeric scalar/vector, scalar broadcast; no matrix form (mirrors /)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const vec2f = try vecT(a, 2, Types.scalar_f32_ptr);
    const vec3f = try vecT(a, 3, Types.scalar_f32_ptr);
    const vec2i = try vecT(a, 2, Types.scalar_i32_ptr);
    const vec2u = try vecT(a, 2, Types.scalar_u32_ptr);
    const vec3b = try vecT(a, 3, Types.scalar_bool_ptr);
    const mat2x2 = try matT(a, 2, 2, Types.scalar_f32_ptr);
    const mat2x3 = try matT(a, 2, 3, Types.scalar_f32_ptr);

    // `%` shares division's scalar / vector / scalar-broadcast forms exactly —
    // WGSL defines it on both integers and floats, with no matrix form (§8.7).
    // Common numeric scalar; abstract yields to the concrete partner.
    try std.testing.expectEqualStrings("i32", (try resolveBinary(a, .mod, Types.I32, Types.I32)).?);
    try std.testing.expectEqualStrings("f32", (try resolveBinary(a, .mod, Types.F32, Types.F32)).?);
    try std.testing.expectEqualStrings("i32", (try resolveBinary(a, .mod, Types.AbstractInt, Types.I32)).?);
    try std.testing.expectEqualStrings("f32", (try resolveBinary(a, .mod, Types.F32, Types.AbstractInt)).?);
    // Common numeric vector.
    try std.testing.expectEqualStrings("vec2<f32>", (try resolveBinary(a, .mod, vec2f, vec2f)).?);
    try std.testing.expectEqualStrings("vec2<u32>", (try resolveBinary(a, .mod, vec2u, vec2u)).?);
    // Scalar broadcast, both directions (the old `commonType`-only checker
    // silently failed these though §8.7 allows them).
    try std.testing.expectEqualStrings("vec2<f32>", (try resolveBinary(a, .mod, vec2f, Types.F32)).?);
    try std.testing.expectEqualStrings("vec2<f32>", (try resolveBinary(a, .mod, Types.F32, vec2f)).?);
    // An abstract-int scalar broadcasts into a float / uint vector, unifying to
    // the vector's element.
    try std.testing.expectEqualStrings("vec2<f32>", (try resolveBinary(a, .mod, Types.AbstractInt, vec2f)).?);
    try std.testing.expectEqualStrings("vec2<u32>", (try resolveBinary(a, .mod, vec2u, Types.AbstractInt)).?);

    // --- rejections ---
    // No matrix form (§8.7): neither same-shape nor matrix/scalar resolves.
    try std.testing.expect((try resolveBinary(a, .mod, mat2x2, mat2x2)) == null);
    try std.testing.expect((try resolveBinary(a, .mod, mat2x3, mat2x3)) == null);
    try std.testing.expect((try resolveBinary(a, .mod, mat2x2, Types.F32)) == null);
    // bool operands are not numeric.
    try std.testing.expect((try resolveBinary(a, .mod, Types.Bool, Types.Bool)) == null);
    try std.testing.expect((try resolveBinary(a, .mod, vec3b, vec3b)) == null);
    // Mixed sign / int-vs-float / width / elem / scalar<->vector.
    try std.testing.expect((try resolveBinary(a, .mod, Types.I32, Types.U32)) == null);
    try std.testing.expect((try resolveBinary(a, .mod, Types.I32, Types.F32)) == null);
    try std.testing.expect((try resolveBinary(a, .mod, vec2f, vec3f)) == null);
    try std.testing.expect((try resolveBinary(a, .mod, vec2f, vec2i)) == null);
    try std.testing.expect((try resolveBinary(a, .mod, Types.I32, vec2f)) == null);
}

test "multiplication * : scalar/vector/broadcast plus the full matrix product set (spec-correct matmul)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const vec2f = try vecT(a, 2, Types.scalar_f32_ptr);
    const vec3f = try vecT(a, 3, Types.scalar_f32_ptr);
    const vec2i = try vecT(a, 2, Types.scalar_i32_ptr);
    const vec2u = try vecT(a, 2, Types.scalar_u32_ptr);
    const vec3b = try vecT(a, 3, Types.scalar_bool_ptr);
    const mat2x2 = try matT(a, 2, 2, Types.scalar_f32_ptr);
    const mat2x3 = try matT(a, 2, 3, Types.scalar_f32_ptr); // cols=2, rows=3
    const mat3x2 = try matT(a, 3, 2, Types.scalar_f32_ptr); // cols=3, rows=2
    const mat3x3 = try matT(a, 3, 3, Types.scalar_f32_ptr);

    // --- shared scalar / vector / broadcast forms (identical to +,-,/) ---
    try std.testing.expectEqualStrings("i32", (try resolveBinary(a, .mul, Types.I32, Types.I32)).?);
    try std.testing.expectEqualStrings("f32", (try resolveBinary(a, .mul, Types.F32, Types.AbstractInt)).?);
    try std.testing.expectEqualStrings("vec2<f32>", (try resolveBinary(a, .mul, vec2f, vec2f)).?);
    try std.testing.expectEqualStrings("vec2<f32>", (try resolveBinary(a, .mul, vec2f, Types.F32)).?);
    try std.testing.expectEqualStrings("vec2<f32>", (try resolveBinary(a, .mul, Types.F32, vec2f)).?);
    // Abstract-int broadcasts into a float / uint vector, unifying to the
    // vector's element (the old checker concretized it to i32 first and wrongly
    // rejected `1 * vec2<f32>`).
    try std.testing.expectEqualStrings("vec2<f32>", (try resolveBinary(a, .mul, Types.AbstractInt, vec2f)).?);
    try std.testing.expectEqualStrings("vec2<u32>", (try resolveBinary(a, .mul, vec2u, Types.AbstractInt)).?);

    // --- matrix · scalar (either order); matrices are float-only, and an
    // abstract-int factor promotes to abstract-float and unifies (`m * 2`). ---
    try std.testing.expectEqualStrings("mat2x3<f32>", (try resolveBinary(a, .mul, mat2x3, Types.F32)).?);
    try std.testing.expectEqualStrings("mat2x3<f32>", (try resolveBinary(a, .mul, Types.F32, mat2x3)).?);
    try std.testing.expectEqualStrings("mat2x2<f32>", (try resolveBinary(a, .mul, mat2x2, Types.AbstractInt)).?);
    try std.testing.expectEqualStrings("mat2x2<f32>", (try resolveBinary(a, .mul, Types.AbstractInt, mat2x2)).?);

    // --- matrix · vector: matCxR * vecC -> vecR (vector width = matrix cols) ---
    try std.testing.expectEqualStrings("vec2<f32>", (try resolveBinary(a, .mul, mat2x2, vec2f)).?);
    try std.testing.expectEqualStrings("vec3<f32>", (try resolveBinary(a, .mul, mat2x3, vec2f)).?); // cols=2 consumes width 2; rows=3 -> vec3
    // --- vector · matrix: vecR * matCxR -> vecC (vector width = matrix rows) ---
    try std.testing.expectEqualStrings("vec2<f32>", (try resolveBinary(a, .mul, vec2f, mat2x2)).?);
    try std.testing.expectEqualStrings("vec3<f32>", (try resolveBinary(a, .mul, vec2f, mat3x2)).?); // rows=2 consumes width 2; cols=3 -> vec3

    // --- matrix · matrix: matKxR * matCxK -> matCxR (A.cols == B.rows == K) ---
    try std.testing.expectEqualStrings("mat2x2<f32>", (try resolveBinary(a, .mul, mat2x2, mat2x2)).?);
    try std.testing.expectEqualStrings("mat3x3<f32>", (try resolveBinary(a, .mul, mat3x3, mat3x3)).?);
    // Non-square products the old checker wrongly *rejected* (it had no general
    // matmul arm): A.cols == B.rows, result mat(B.cols)x(A.rows).
    try std.testing.expectEqualStrings("mat3x2<f32>", (try resolveBinary(a, .mul, mat2x2, mat3x2)).?); // K=2,R=2,C=3
    try std.testing.expectEqualStrings("mat2x3<f32>", (try resolveBinary(a, .mul, mat2x3, mat2x2)).?); // K=2,R=3,C=2
    try std.testing.expectEqualStrings("mat3x3<f32>", (try resolveBinary(a, .mul, mat2x3, mat3x2)).?); // K=2,R=3,C=3
    try std.testing.expectEqualStrings("mat2x2<f32>", (try resolveBinary(a, .mul, mat3x2, mat2x3)).?); // K=3,R=2,C=2

    // --- rejections ---
    // Non-conformant matmul (A.cols != B.rows): the old checker's commonType
    // fast path wrongly *accepted* these same-type non-square products,
    // returning a nonsense matrix.
    try std.testing.expect((try resolveBinary(a, .mul, mat2x3, mat2x3)) == null); // cols 2 != rows 3
    try std.testing.expect((try resolveBinary(a, .mul, mat3x2, mat3x2)) == null); // cols 3 != rows 2
    // Matrix · vector width mismatch (vector width != matrix cols).
    try std.testing.expect((try resolveBinary(a, .mul, mat2x2, vec3f)) == null);
    // Vector · matrix width mismatch (vector width != matrix rows).
    try std.testing.expect((try resolveBinary(a, .mul, vec3f, mat2x2)) == null);
    // Matrices are float-only: an integer vector never pairs with a matrix.
    try std.testing.expect((try resolveBinary(a, .mul, mat2x2, vec2i)) == null);
    // bool operands are not numeric (the old checker wrongly returned bool).
    try std.testing.expect((try resolveBinary(a, .mul, Types.Bool, Types.Bool)) == null);
    try std.testing.expect((try resolveBinary(a, .mul, vec3b, vec3b)) == null);
    // Mixed sign / int-vs-float / element mismatch.
    try std.testing.expect((try resolveBinary(a, .mul, Types.I32, Types.U32)) == null);
    try std.testing.expect((try resolveBinary(a, .mul, Types.I32, Types.F32)) == null);
    try std.testing.expect((try resolveBinary(a, .mul, vec2f, vec2i)) == null);
}
