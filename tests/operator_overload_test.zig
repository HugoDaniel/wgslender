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
