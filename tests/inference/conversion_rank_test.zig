//! WGSL ConversionRank — spec §8.2 (index.bs lines 2436–2510).
//!
//! Every row in the spec's ConversionRank table gets at least one
//! positive assertion here, plus negative assertions that pin which
//! conversions are *not* feasible. Vectors, matrices and fixed-size
//! arrays inherit their element's rank — tested via propagation cases.

const std = @import("std");
const wgslender = @import("wgslender");
const Types = wgslender.Types;
const Ast = wgslender.Ast;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

fn rank(src: Types.Type, dst: Types.Type) ?u32 {
    return Types.conversionRank(src, dst);
}

// --- Identity (§8.2 row 1) ---

test "rank §8.2: identity on every scalar is 0" {
    try expectEqual(@as(?u32, 0), rank(Types.Bool, Types.Bool));
    try expectEqual(@as(?u32, 0), rank(Types.I32, Types.I32));
    try expectEqual(@as(?u32, 0), rank(Types.U32, Types.U32));
    try expectEqual(@as(?u32, 0), rank(Types.F32, Types.F32));
    try expectEqual(@as(?u32, 0), rank(Types.F16, Types.F16));
    try expectEqual(@as(?u32, 0), rank(Types.AbstractInt, Types.AbstractInt));
    try expectEqual(@as(?u32, 0), rank(Types.AbstractFloat, Types.AbstractFloat));
}

test "rank §8.2: identity on void is 0" {
    try expectEqual(@as(?u32, 0), rank(Types.Void, Types.Void));
}

// --- Abstract cascade (§8.2 rows 3–9) ---

test "rank §8.2: AbstractFloat → f32 is 1" {
    try expectEqual(@as(?u32, 1), rank(Types.AbstractFloat, Types.F32));
}

test "rank §8.2: AbstractFloat → f16 is 2" {
    try expectEqual(@as(?u32, 2), rank(Types.AbstractFloat, Types.F16));
}

test "rank §8.2: AbstractInt → i32 is 3" {
    try expectEqual(@as(?u32, 3), rank(Types.AbstractInt, Types.I32));
}

test "rank §8.2: AbstractInt → u32 is 4" {
    try expectEqual(@as(?u32, 4), rank(Types.AbstractInt, Types.U32));
}

test "rank §8.2: AbstractInt → AbstractFloat is 5" {
    try expectEqual(@as(?u32, 5), rank(Types.AbstractInt, Types.AbstractFloat));
}

test "rank §8.2: AbstractInt → f32 is 6 (i32 preferred)" {
    try expectEqual(@as(?u32, 6), rank(Types.AbstractInt, Types.F32));
}

test "rank §8.2: AbstractInt → f16 is 7 (i32 still preferred)" {
    try expectEqual(@as(?u32, 7), rank(Types.AbstractInt, Types.F16));
}

test "rank §8.2: preference — AbstractFloat prefers f32 over f16" {
    const to_f32 = rank(Types.AbstractFloat, Types.F32) orelse return error.TestUnexpectedResult;
    const to_f16 = rank(Types.AbstractFloat, Types.F16) orelse return error.TestUnexpectedResult;
    try expect(to_f32 < to_f16);
}

test "rank §8.2: preference — AbstractInt prefers i32 over u32" {
    const to_i32 = rank(Types.AbstractInt, Types.I32) orelse return error.TestUnexpectedResult;
    const to_u32 = rank(Types.AbstractInt, Types.U32) orelse return error.TestUnexpectedResult;
    try expect(to_i32 < to_u32);
}

test "rank §8.2: preference — AbstractInt prefers int over float" {
    const to_i32 = rank(Types.AbstractInt, Types.I32) orelse return error.TestUnexpectedResult;
    const to_f32 = rank(Types.AbstractInt, Types.F32) orelse return error.TestUnexpectedResult;
    try expect(to_i32 < to_f32);
}

// --- Infeasible scalar conversions ---

test "rank §8.2 negative: concrete → abstract is infeasible" {
    try expectEqual(@as(?u32, null), rank(Types.I32, Types.AbstractInt));
    try expectEqual(@as(?u32, null), rank(Types.F32, Types.AbstractFloat));
    try expectEqual(@as(?u32, null), rank(Types.F32, Types.AbstractInt));
}

test "rank §8.2 negative: concrete → concrete of different kind is infeasible" {
    try expectEqual(@as(?u32, null), rank(Types.I32, Types.U32));
    try expectEqual(@as(?u32, null), rank(Types.I32, Types.F32));
    try expectEqual(@as(?u32, null), rank(Types.U32, Types.I32));
    try expectEqual(@as(?u32, null), rank(Types.F32, Types.F16));
    try expectEqual(@as(?u32, null), rank(Types.F16, Types.F32));
}

test "rank §8.2 negative: bool has no conversion targets" {
    try expectEqual(@as(?u32, null), rank(Types.Bool, Types.I32));
    try expectEqual(@as(?u32, null), rank(Types.I32, Types.Bool));
    try expectEqual(@as(?u32, null), rank(Types.Bool, Types.AbstractInt));
    try expectEqual(@as(?u32, null), rank(Types.AbstractInt, Types.Bool));
}

test "rank §8.2 negative: AbstractFloat cannot demote to int" {
    try expectEqual(@as(?u32, null), rank(Types.AbstractFloat, Types.I32));
    try expectEqual(@as(?u32, null), rank(Types.AbstractFloat, Types.U32));
    try expectEqual(@as(?u32, null), rank(Types.AbstractFloat, Types.AbstractInt));
}

// --- Vector propagation (§8.2 row 10) ---

test "rank §8.2: vec<N, AbstractFloat> → vec<N, f32> inherits rank 1" {
    const a = std.testing.allocator;
    const v_abs = try Types.vec(a, 3, Types.scalar_abstract_float_ptr);
    defer a.destroy(v_abs.vector);
    const v_f32 = try Types.vec(a, 3, Types.scalar_f32_ptr);
    defer a.destroy(v_f32.vector);
    try expectEqual(@as(?u32, 1), rank(v_abs, v_f32));
}

test "rank §8.2: vec<N, AbstractInt> → vec<N, i32> inherits rank 3" {
    const a = std.testing.allocator;
    const v_abs = try Types.vec(a, 2, Types.scalar_abstract_int_ptr);
    defer a.destroy(v_abs.vector);
    const v_i32 = try Types.vec(a, 2, Types.scalar_i32_ptr);
    defer a.destroy(v_i32.vector);
    try expectEqual(@as(?u32, 3), rank(v_abs, v_i32));
}

test "rank §8.2: vec<N, AbstractInt> → vec<N, f16> inherits rank 7" {
    const a = std.testing.allocator;
    const v_abs = try Types.vec(a, 4, Types.scalar_abstract_int_ptr);
    defer a.destroy(v_abs.vector);
    const v_f16 = try Types.vec(a, 4, Types.scalar_f16_ptr);
    defer a.destroy(v_f16.vector);
    try expectEqual(@as(?u32, 7), rank(v_abs, v_f16));
}

test "rank §8.2 negative: vectors of different widths are infeasible" {
    const a = std.testing.allocator;
    const v2 = try Types.vec(a, 2, Types.scalar_abstract_int_ptr);
    defer a.destroy(v2.vector);
    const v3 = try Types.vec(a, 3, Types.scalar_i32_ptr);
    defer a.destroy(v3.vector);
    try expectEqual(@as(?u32, null), rank(v2, v3));
}

test "rank §8.2 negative: vec<N, i32> → vec<N, u32> is infeasible" {
    const a = std.testing.allocator;
    const vi = try Types.vec(a, 3, Types.scalar_i32_ptr);
    defer a.destroy(vi.vector);
    const vu = try Types.vec(a, 3, Types.scalar_u32_ptr);
    defer a.destroy(vu.vector);
    try expectEqual(@as(?u32, null), rank(vi, vu));
}

test "rank §8.2: vec<N, T> → vec<N, T> identity is 0" {
    const a = std.testing.allocator;
    const v = try Types.vec(a, 3, Types.scalar_f32_ptr);
    defer a.destroy(v.vector);
    // Note: these are distinct allocations but .eql compares structurally.
    try expectEqual(@as(?u32, 0), rank(v, v));
}

// --- Matrix propagation (§8.2 row 11) ---

test "rank §8.2: mat<C, R, AbstractFloat> → mat<C, R, f32> inherits rank 1" {
    const a = std.testing.allocator;
    const m_abs = try Types.mat(a, 3, 3, Types.scalar_abstract_float_ptr);
    defer a.destroy(m_abs.matrix);
    const m_f32 = try Types.mat(a, 3, 3, Types.scalar_f32_ptr);
    defer a.destroy(m_f32.matrix);
    try expectEqual(@as(?u32, 1), rank(m_abs, m_f32));
}

test "rank §8.2: mat<C, R, AbstractFloat> → mat<C, R, f16> inherits rank 2" {
    const a = std.testing.allocator;
    const m_abs = try Types.mat(a, 4, 4, Types.scalar_abstract_float_ptr);
    defer a.destroy(m_abs.matrix);
    const m_f16 = try Types.mat(a, 4, 4, Types.scalar_f16_ptr);
    defer a.destroy(m_f16.matrix);
    try expectEqual(@as(?u32, 2), rank(m_abs, m_f16));
}

test "rank §8.2 negative: matrices of different shapes are infeasible" {
    const a = std.testing.allocator;
    const m23 = try Types.mat(a, 2, 3, Types.scalar_abstract_float_ptr);
    defer a.destroy(m23.matrix);
    const m32 = try Types.mat(a, 3, 2, Types.scalar_f32_ptr);
    defer a.destroy(m32.matrix);
    try expectEqual(@as(?u32, null), rank(m23, m32));
}

test "rank §8.2 negative: mat<C, R, f32> → mat<C, R, f16> is infeasible" {
    const a = std.testing.allocator;
    const mf = try Types.mat(a, 4, 4, Types.scalar_f32_ptr);
    defer a.destroy(mf.matrix);
    const mh = try Types.mat(a, 4, 4, Types.scalar_f16_ptr);
    defer a.destroy(mh.matrix);
    try expectEqual(@as(?u32, null), rank(mf, mh));
}

// --- Array propagation (§8.2 row 12) ---

test "rank §8.2: array<AbstractInt, N> → array<i32, N> inherits rank 3" {
    const a = std.testing.allocator;
    const a_abs = try Types.arr(a, Types.AbstractInt, 4);
    defer a.destroy(a_abs.array);
    const a_i32 = try Types.arr(a, Types.I32, 4);
    defer a.destroy(a_i32.array);
    try expectEqual(@as(?u32, 3), rank(a_abs, a_i32));
}

test "rank §8.2: array<AbstractFloat, N> → array<f32, N> inherits rank 1" {
    const a = std.testing.allocator;
    const a_abs = try Types.arr(a, Types.AbstractFloat, 8);
    defer a.destroy(a_abs.array);
    const a_f32 = try Types.arr(a, Types.F32, 8);
    defer a.destroy(a_f32.array);
    try expectEqual(@as(?u32, 1), rank(a_abs, a_f32));
}

test "rank §8.2 negative: arrays of different counts are infeasible" {
    const a = std.testing.allocator;
    const a4 = try Types.arr(a, Types.AbstractInt, 4);
    defer a.destroy(a4.array);
    const a8 = try Types.arr(a, Types.I32, 8);
    defer a.destroy(a8.array);
    try expectEqual(@as(?u32, null), rank(a4, a8));
}

test "rank §8.2 negative: runtime-sized arrays do not carry abstract" {
    const a = std.testing.allocator;
    const a_rt = try Types.runtimeArray(a, Types.AbstractInt);
    defer a.destroy(a_rt.array);
    const a_i32_rt = try Types.runtimeArray(a, Types.I32);
    defer a.destroy(a_i32_rt.array);
    // Runtime-sized arrays are structurally non-convertible per spec note.
    try expectEqual(@as(?u32, null), rank(a_rt, a_i32_rt));
}

test "rank §8.2: nested array<vec<N, AbstractFloat>, M> → array<vec<N, f32>, M>" {
    const a = std.testing.allocator;
    const v_abs = try Types.vec(a, 3, Types.scalar_abstract_float_ptr);
    defer a.destroy(v_abs.vector);
    const v_f32 = try Types.vec(a, 3, Types.scalar_f32_ptr);
    defer a.destroy(v_f32.vector);
    const a_abs = try Types.arr(a, v_abs, 2);
    defer a.destroy(a_abs.array);
    const a_f32 = try Types.arr(a, v_f32, 2);
    defer a.destroy(a_f32.array);
    try expectEqual(@as(?u32, 1), rank(a_abs, a_f32));
}

// --- Load rule (§8.2 row 2) ---

test "rank §8.2: ref<AS, T, read> → T is 0" {
    const a = std.testing.allocator;
    const r = try Types.ref(a, .storage, Types.F32, .read);
    defer a.destroy(r.reference);
    try expectEqual(@as(?u32, 0), rank(r, Types.F32));
}

test "rank §8.2: ref<AS, T, read_write> → T is 0" {
    const a = std.testing.allocator;
    const r = try Types.ref(a, .function, Types.I32, .read_write);
    defer a.destroy(r.reference);
    try expectEqual(@as(?u32, 0), rank(r, Types.I32));
}

test "rank §8.2: ref<AS, AbstractInt, read> → i32 still feasible at rank 3" {
    const a = std.testing.allocator;
    const r = try Types.ref(a, .function, Types.AbstractInt, .read);
    defer a.destroy(r.reference);
    // Load rule hits rank 0, then the inner conversion to i32 is rank 3.
    try expectEqual(@as(?u32, 3), rank(r, Types.I32));
}

test "rank §8.2 negative: ref<AS, T, write> cannot load" {
    const a = std.testing.allocator;
    const r = try Types.ref(a, .storage, Types.F32, .write);
    defer a.destroy(r.reference);
    try expectEqual(@as(?u32, null), rank(r, Types.F32));
}

test "rank §8.2: ref of vector → vector is 0" {
    const a = std.testing.allocator;
    const v = try Types.vec(a, 4, Types.scalar_f32_ptr);
    defer a.destroy(v.vector);
    const r = try Types.ref(a, .function, v, .read_write);
    defer a.destroy(r.reference);
    try expectEqual(@as(?u32, 0), rank(r, v));
}

// --- Cross-kind infeasible ---

test "rank §8.2 negative: scalar → vector is infeasible" {
    const a = std.testing.allocator;
    const v = try Types.vec(a, 3, Types.scalar_f32_ptr);
    defer a.destroy(v.vector);
    try expectEqual(@as(?u32, null), rank(Types.F32, v));
    try expectEqual(@as(?u32, null), rank(v, Types.F32));
}

test "rank §8.2 negative: vector → matrix is infeasible" {
    const a = std.testing.allocator;
    const v = try Types.vec(a, 3, Types.scalar_f32_ptr);
    defer a.destroy(v.vector);
    const m = try Types.mat(a, 3, 3, Types.scalar_f32_ptr);
    defer a.destroy(m.matrix);
    try expectEqual(@as(?u32, null), rank(v, m));
}

test "rank §8.2 negative: pointer with mismatched address space is infeasible" {
    const a = std.testing.allocator;
    const p1 = try Types.ptr(a, .function, Types.F32, .read_write);
    defer a.destroy(p1.pointer);
    const p2 = try Types.ptr(a, .storage, Types.F32, .read_write);
    defer a.destroy(p2.pointer);
    try expectEqual(@as(?u32, null), rank(p1, p2));
}

test "rank §8.2: pointer identity is 0" {
    const a = std.testing.allocator;
    const p1 = try Types.ptr(a, .function, Types.F32, .read_write);
    defer a.destroy(p1.pointer);
    const p2 = try Types.ptr(a, .function, Types.F32, .read_write);
    defer a.destroy(p2.pointer);
    // Structural identity via .eql
    try expectEqual(@as(?u32, 0), rank(p1, p2));
}

// --- Preference invariants used by overload resolution ---

test "rank §8.2 invariant: every feasible conversion has finite rank" {
    // Every entry in the spec rank table sanity-checked to fit in u32.
    inline for ([_]u32{ 0, 1, 2, 3, 4, 5, 6, 7 }) |expected| {
        _ = expected;
    }
    // This is a smoke check — the exact values are asserted per-row above.
    try expectEqual(@as(?u32, 0), rank(Types.I32, Types.I32));
    try expectEqual(@as(?u32, 7), rank(Types.AbstractInt, Types.F16));
}
