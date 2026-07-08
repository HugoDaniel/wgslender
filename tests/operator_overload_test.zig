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
