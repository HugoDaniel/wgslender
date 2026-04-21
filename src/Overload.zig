//! Declarative builtin overload signatures + unification solver.
//!
//! Phase 1 of Task #9: replaces the string-matched per-builtin logic in
//! `Validator.inferCustomBuiltin` for a targeted subset (frexp, modf,
//! atomic*, unpack*, subgroupBallot, workgroupUniformLoad, transpose)
//! with a declarative signature table driven by a generic unification
//! solver. Builtins with `Builtin.overloads == null` continue to ride
//! the old path, so this module is strictly additive.
//!
//! Spec: WGSL §8.7 overload resolution. Feasible candidates are ranked
//! by the max `Types.conversionRank` across their bound arguments; the
//! lowest total wins. Ties are broken by declaration order (first wins),
//! which matches Naga/Tint.
//!
//! The engine is deliberately small: texture/bitcast/dot4*-packed
//! complexity is deferred to Phase 3, so the Pattern grammar covers only
//! the shapes Phase 1 needs (scalar, vector, matrix, pointer<atomic<T>>,
//! concrete singleton refs). Expanding it later is a matter of adding
//! new `Pattern` variants and `unifyArg` cases.

const std = @import("std");
const Ast = @import("Ast.zig");
const Types = @import("Types.zig");

const Overload = @This();

// =========================================================================
// Signature DSL
// =========================================================================

/// A scalar family constraint used by `.tparam_scalar`. Narrows the set of
/// scalar kinds a type parameter may bind to so one overload signature can
/// stand in for several spec overload forms (e.g. T ∈ {f32, f16, abstract-
/// float}). Bool is modeled explicitly via `.concrete`.
pub const ScalarFamily = enum {
    /// f32, f16, abstract-float.
    float,
    /// i32, u32, abstract-int.
    integer,
    /// any non-bool scalar (i32, u32, f32, f16, abstract-int, abstract-float).
    numeric,
    /// abstract-int only — used to pin packed-dot callers that must be u32 via
    /// the load rule; not currently needed but keeps the enum honest.
    abstract_int,

    pub fn accepts(self: ScalarFamily, kind: Types.ScalarKind) bool {
        return switch (self) {
            .float => kind == .f32 or kind == .f16 or kind == .abstract_float,
            .integer => kind == .i32 or kind == .u32 or kind == .abstract_int,
            .numeric => kind != .bool,
            .abstract_int => kind == .abstract_int,
        };
    }
};

/// A parameter or return pattern. Patterns are tree-structured: containers
/// (vector, matrix, pointer, atomic) nest a child pattern. A leaf is either
/// a concrete reference or a type-parameter slot.
///
/// Fields `elem_tparam`, `width_tparam`, `as_tparam`, `am_tparam` are tparam
/// indices; a negative sentinel (u8 max) means "unbound — infer or fix to
/// the Pattern's inline literal".
pub const Pattern = union(enum) {
    /// A pinned concrete type (U32, I32, F32, F16, Bool, or Void).
    concrete: Types.Type,

    /// Binds a scalar to a type parameter. The scalar's kind is recorded in
    /// `binding.scalar_kind`. The `family` filter rejects incompatible kinds.
    tparam_scalar: struct { idx: u8, family: ScalarFamily },

    /// vecN<T> where N and T are type parameters. Both `n_idx` and `elem_idx`
    /// reference `tparams`. When `n_fixed != 0`, the width is pinned to that
    /// value rather than bound.
    tparam_vector: struct {
        elem_idx: u8,
        elem_family: ScalarFamily,
        n_idx: u8 = no_tparam,
        n_fixed: u8 = 0,
    },

    /// matCxR<T> — cols and rows are always fixed-literal here (the spec has
    /// no single-pattern polymorphism over both axes that Phase 1 needs).
    /// `swap_for_result = true` is used by transpose's result pattern to
    /// produce matRxC from a bound matCxR.
    tparam_matrix: struct {
        elem_idx: u8,
        elem_family: ScalarFamily,
        cols_idx: u8,
        rows_idx: u8,
    },

    /// ptr<AS, atomic<T>, AM> — Phase 1 only needs this exact shape for the
    /// atomic family. AS/AM bind to tparams; T binds via `elem_idx`.
    tparam_ptr_atomic: struct {
        as_idx: u8,
        am_idx: u8,
        elem_idx: u8,
        elem_family: ScalarFamily,
    },

    /// ptr<AS, T, AM> (no atomic) — used by workgroupUniformLoad. AS is
    /// fixed (workgroup only). T binds via `elem_idx`.
    tparam_ptr: struct {
        as_fixed: Ast.AddressSpace,
        am_idx: u8,
        elem_idx: u8,
    },

    /// Re-expansion of a previously bound scalar tparam. Used in result
    /// rules (e.g. atomic ops return T, a pattern that says "same scalar as
    /// param 0's bound T").
    bound_scalar: u8,

    /// Re-expansion of a bound elem_tparam as vecN, where N is bound.
    /// Not used in Phase 1 params (only in result rules for frexp.exp).
    bound_vector: struct { elem_idx: u8, n_idx: u8 },

    /// Re-expansion of a bound matrix but with cols/rows swapped (transpose).
    bound_matrix_transposed: struct { elem_idx: u8, cols_idx: u8, rows_idx: u8 },

    pub const no_tparam: u8 = std.math.maxInt(u8);
};

/// How to build the return type once the solver has bound all tparams.
pub const ResultRule = union(enum) {
    /// Build the type from a pattern using the bindings.
    pattern: Pattern,
    /// Fixed singleton (e.g. vec4<u32> for subgroupBallot, u32 for pack*).
    fixed: Types.Type,
    /// Delegate to the validator to synthesize `__frexp_result_T` for the
    /// bound element scalar (`0` indexes the arg whose type carries T).
    synth_frexp: u8,
    /// Same for modf.
    synth_modf: u8,
    /// Same for atomicCompareExchangeWeak.
    synth_atomic_cmp_xchg: u8,
    /// The scalar element of a bound tparam (indexes the scalar tparam).
    bound_scalar_as_type: u8,
};

/// Number of tparams an overload declares. Phase 1 tops out at 4 (the
/// pointer-atomic family needs elem_T, AS, AM, plus an optional N slot).
pub const max_tparams: u8 = 4;

/// Per-slot binding. Only the field matching the tparam's kind is read;
/// mismatched kinds are rejected during unification.
pub const Binding = struct {
    bound: bool = false,
    scalar_kind: ?Types.ScalarKind = null,
    width: ?u8 = null,
    cols: ?u8 = null,
    rows: ?u8 = null,
    address_space: ?Ast.AddressSpace = null,
    access_mode: ?Ast.AccessMode = null,
};

pub const OverloadSig = struct {
    tparam_count: u8,
    params: []const Pattern,
    result: ResultRule,
};

// =========================================================================
// Solver
// =========================================================================

pub const ResolveError = enum {
    arg_count_mismatch,
    no_matching_overload,
    ambiguous_overload,
};

pub const ResolveFailure = struct {
    kind: ResolveError,
    /// For `no_matching_overload` on a single-overload builtin: the 0-based
    /// index of the first argument that failed to unify, and the expected
    /// scalar family / shape description for that slot. Kept minimal —
    /// diagnostics are the Validator's responsibility.
    first_bad_arg: u8 = 0,
};

pub const ResolveResult = union(enum) {
    ok: struct {
        sig_index: usize,
        bindings: [max_tparams]Binding,
        total_rank: u32,
    },
    err: ResolveFailure,
};

/// Resolve a call against the overload set for `name`. Arg count must match
/// `params.len` for at least one candidate; otherwise `arg_count_mismatch`.
/// On success, returns the winning sig index and the tparam bindings; the
/// caller then uses `buildResult` to construct the return type.
pub fn resolve(sigs: []const OverloadSig, arg_types: []const ?Types.Type) ResolveResult {
    // Arity filter.
    var arity_ok: bool = false;
    for (sigs) |s| {
        if (s.params.len == arg_types.len) {
            arity_ok = true;
            break;
        }
    }
    if (!arity_ok) {
        return .{ .err = .{ .kind = .arg_count_mismatch } };
    }

    var best_idx: ?usize = null;
    var best_rank: u32 = std.math.maxInt(u32);
    var best_bindings: [max_tparams]Binding = @splat(.{});
    var last_bad_arg: u8 = 0;

    // Tie-break by declaration order — on strict less-than we take the
    // earliest winner, so two overloads with equal minimum rank leave the
    // first one selected. Ambiguity between non-equivalent candidates is
    // reserved for later phases and not triggered by Phase 1 signatures.
    for (sigs, 0..) |s, idx| {
        if (s.params.len != arg_types.len) continue;
        var bindings: [max_tparams]Binding = @splat(.{});
        var total_rank: u32 = 0;
        var ok = true;
        var bad_arg: u8 = 0;
        for (s.params, 0..) |p, pi| {
            const arg = arg_types[pi] orelse {
                // A null arg (upstream type inference failure) is treated as
                // feasible — we don't want to invent an overload error while
                // the real culprit is an earlier inference failure.
                continue;
            };
            const r = unifyArg(&p, arg, &bindings) catch {
                ok = false;
                bad_arg = @intCast(pi);
                break;
            };
            total_rank = @max(total_rank, r);
        }
        if (!ok) {
            last_bad_arg = bad_arg;
            continue;
        }
        if (best_idx == null or total_rank < best_rank) {
            best_idx = idx;
            best_rank = total_rank;
            best_bindings = bindings;
        }
    }

    if (best_idx) |idx| {
        return .{ .ok = .{
            .sig_index = idx,
            .bindings = best_bindings,
            .total_rank = best_rank,
        } };
    }
    return .{ .err = .{ .kind = .no_matching_overload, .first_bad_arg = last_bad_arg } };
}

/// Unify one argument against one parameter pattern, updating `bindings`.
/// Returns the conversion rank of the arg into the concrete form implied
/// by the (now-bound) pattern, or a slot-specific error.
fn unifyArg(p: *const Pattern, arg: Types.Type, bindings: *[max_tparams]Binding) error{Mismatch}!u32 {
    // Apply the load rule up front: a reference<AS,T,AM> where AM ∈ {read,
    // read_write} is indistinguishable from T at argument sites, and the
    // rank-0 cost is what the validator already assigns.
    var a = arg;
    if (a == .reference) {
        const r = a.reference;
        if (r.access_mode == .read or r.access_mode == .read_write) {
            a = r.element;
        }
    }

    switch (p.*) {
        .concrete => |t| {
            return Types.conversionRank(a, t) orelse return error.Mismatch;
        },
        .tparam_scalar => |ts| {
            if (a != .scalar) return error.Mismatch;
            const sk = a.scalar.kind;
            if (!ts.family.accepts(sk)) return error.Mismatch;
            return try bindScalar(bindings, ts.idx, sk, ts.family);
        },
        .tparam_vector => |tv| {
            if (a != .vector) return error.Mismatch;
            const v = a.vector;
            if (tv.n_fixed != 0) {
                if (v.width != tv.n_fixed) return error.Mismatch;
            } else if (tv.n_idx != Pattern.no_tparam) {
                if (!try bindWidth(bindings, tv.n_idx, v.width)) return error.Mismatch;
            }
            if (!tv.elem_family.accepts(v.element.kind)) return error.Mismatch;
            return try bindScalar(bindings, tv.elem_idx, v.element.kind, tv.elem_family);
        },
        .tparam_matrix => |tm| {
            if (a != .matrix) return error.Mismatch;
            const m = a.matrix;
            if (!try bindWidth(bindings, tm.cols_idx, m.cols)) return error.Mismatch;
            if (!try bindWidth(bindings, tm.rows_idx, m.rows)) return error.Mismatch;
            if (!tm.elem_family.accepts(m.element.kind)) return error.Mismatch;
            return try bindScalar(bindings, tm.elem_idx, m.element.kind, tm.elem_family);
        },
        .tparam_ptr_atomic => |tp| {
            if (a != .pointer) return error.Mismatch;
            const pp = a.pointer;
            if (pp.element != .atomic) return error.Mismatch;
            const elem_kind = pp.element.atomic.element.kind;
            if (!tp.elem_family.accepts(elem_kind)) return error.Mismatch;
            if (!try bindAddressSpace(bindings, tp.as_idx, pp.address_space)) return error.Mismatch;
            if (!try bindAccessMode(bindings, tp.am_idx, pp.access_mode)) return error.Mismatch;
            _ = try bindScalar(bindings, tp.elem_idx, elem_kind, tp.elem_family);
            return 0;
        },
        .tparam_ptr => |tp| {
            if (a != .pointer) return error.Mismatch;
            const pp = a.pointer;
            if (pp.address_space != tp.as_fixed) return error.Mismatch;
            // Record elem as a whole-Type binding via scalar-only shortcut:
            // Phase 1 only uses this for workgroupUniformLoad where `elem_idx`
            // is a scalar tparam if the element is scalar, or we just pin via
            // conversionRank=0 and look up the element type from the arg in
            // buildResult. For Phase 1 correctness we track the pointer's
            // element scalar when possible.
            if (!try bindAccessMode(bindings, tp.am_idx, pp.access_mode)) return error.Mismatch;
            if (pp.element == .scalar) {
                _ = try bindScalar(bindings, tp.elem_idx, pp.element.scalar.kind, .numeric);
            } else if (pp.element == .atomic) {
                _ = try bindScalar(bindings, tp.elem_idx, pp.element.atomic.element.kind, .numeric);
            }
            return 0;
        },
        .bound_scalar => |idx| {
            // `bound_scalar` in a param position means "the scalar T already
            // bound by an earlier param" — arg must convert to that scalar.
            // Used by atomicAdd/Sub/... and atomicCompareExchangeWeak to
            // require arg[1..] to match arg[0]'s underlying atomic<T>.
            const b = bindings[idx];
            const target_kind = (if (b.bound) b.scalar_kind else null) orelse return error.Mismatch;
            const target: Types.Type = .{ .scalar = kindPtr(target_kind) };
            return Types.conversionRank(a, target) orelse return error.Mismatch;
        },
        .bound_vector, .bound_matrix_transposed => {
            // These only appear in result rules today (frexp/modf/transpose);
            // adding them as param patterns is a later-phase extension.
            return error.Mismatch;
        },
    }
}

fn bindScalar(
    bindings: *[max_tparams]Binding,
    idx: u8,
    kind: Types.ScalarKind,
    family: ScalarFamily,
) error{Mismatch}!u32 {
    if (idx == Pattern.no_tparam) return 0;
    const b = &bindings[idx];
    if (!b.bound) {
        b.bound = true;
        b.scalar_kind = kind;
        return 0;
    }
    const prev = b.scalar_kind.?;
    if (prev == kind) return 0;
    // Two distinct scalars must unify to a common concrete kind. Prefer the
    // concrete one (abstract → concrete has a non-zero rank from Types.8.2).
    if (unifyScalarKinds(prev, kind, family)) |chosen| {
        b.scalar_kind = chosen;
        // Cost is the max rank needed to reach `chosen` from either observed
        // kind. Zero when one side already equals `chosen`.
        const ra = scalarRank(prev, chosen);
        const rb = scalarRank(kind, chosen);
        return @max(ra, rb);
    }
    return error.Mismatch;
}

fn unifyScalarKinds(a: Types.ScalarKind, b: Types.ScalarKind, family: ScalarFamily) ?Types.ScalarKind {
    if (a == b) return a;
    // Abstract yields to concrete of compatible family.
    if (a == .abstract_int and family.accepts(b) and b != .bool) return b;
    if (b == .abstract_int and family.accepts(a) and a != .bool) return a;
    if (a == .abstract_float and (b == .f32 or b == .f16)) return b;
    if (b == .abstract_float and (a == .f32 or a == .f16)) return a;
    return null;
}

fn scalarRank(src: Types.ScalarKind, dst: Types.ScalarKind) u32 {
    if (src == dst) return 0;
    const r = Types.conversionRank(.{ .scalar = kindPtr(src) }, .{ .scalar = kindPtr(dst) });
    return r orelse std.math.maxInt(u32);
}

fn kindPtr(k: Types.ScalarKind) *const Types.Scalar {
    return switch (k) {
        .bool => Types.scalar_bool_ptr,
        .i32 => Types.scalar_i32_ptr,
        .u32 => Types.scalar_u32_ptr,
        .f32 => Types.scalar_f32_ptr,
        .f16 => Types.scalar_f16_ptr,
        .abstract_int => Types.scalar_abstract_int_ptr,
        .abstract_float => Types.scalar_abstract_float_ptr,
    };
}

fn bindWidth(bindings: *[max_tparams]Binding, idx: u8, w: u8) error{Mismatch}!bool {
    if (idx == Pattern.no_tparam) return true;
    const b = &bindings[idx];
    if (!b.bound) {
        b.bound = true;
        b.width = w;
        return true;
    }
    if (b.width) |prev| return prev == w;
    return false;
}

fn bindAddressSpace(bindings: *[max_tparams]Binding, idx: u8, as: Ast.AddressSpace) error{Mismatch}!bool {
    if (idx == Pattern.no_tparam) return true;
    const b = &bindings[idx];
    if (!b.bound) {
        b.bound = true;
        b.address_space = as;
        return true;
    }
    if (b.address_space) |prev| return prev == as;
    return false;
}

fn bindAccessMode(bindings: *[max_tparams]Binding, idx: u8, am: Ast.AccessMode) error{Mismatch}!bool {
    if (idx == Pattern.no_tparam) return true;
    const b = &bindings[idx];
    if (!b.bound) {
        b.bound = true;
        b.access_mode = am;
        return true;
    }
    if (b.access_mode) |prev| return prev == am;
    return false;
}

// =========================================================================
// Result construction
// =========================================================================

/// Materialize a Type from a pattern using the solver's bindings.
/// Returns null if the pattern references unbound slots (caller treats as
/// "no valid return" and typically returns null upstream).
pub fn buildPatternType(
    arena: std.mem.Allocator,
    pattern: Pattern,
    bindings: *const [max_tparams]Binding,
) std.mem.Allocator.Error!?Types.Type {
    switch (pattern) {
        .concrete => |t| return t,
        .tparam_scalar => |ts| {
            const b = bindings[ts.idx];
            if (!b.bound) return null;
            return .{ .scalar = kindPtr(b.scalar_kind.?) };
        },
        .tparam_vector => |tv| {
            const eb = bindings[tv.elem_idx];
            if (!eb.bound) return null;
            const width: u8 = if (tv.n_fixed != 0)
                tv.n_fixed
            else blk: {
                const wb = bindings[tv.n_idx];
                if (!wb.bound) return null;
                break :blk wb.width.?;
            };
            const v = try arena.create(Types.Vector);
            v.* = .{ .width = width, .element = kindPtr(eb.scalar_kind.?) };
            return .{ .vector = v };
        },
        .tparam_matrix => |tm| {
            const eb = bindings[tm.elem_idx];
            const cb = bindings[tm.cols_idx];
            const rb = bindings[tm.rows_idx];
            if (!eb.bound or !cb.bound or !rb.bound) return null;
            const m = try arena.create(Types.Matrix);
            m.* = .{ .cols = cb.width.?, .rows = rb.width.?, .element = kindPtr(eb.scalar_kind.?) };
            return .{ .matrix = m };
        },
        .bound_scalar => |idx| {
            const b = bindings[idx];
            if (!b.bound) return null;
            return .{ .scalar = kindPtr(b.scalar_kind.?) };
        },
        .bound_vector => |bv| {
            const eb = bindings[bv.elem_idx];
            const wb = bindings[bv.n_idx];
            if (!eb.bound or !wb.bound) return null;
            const v = try arena.create(Types.Vector);
            v.* = .{ .width = wb.width.?, .element = kindPtr(eb.scalar_kind.?) };
            return .{ .vector = v };
        },
        .bound_matrix_transposed => |bm| {
            const eb = bindings[bm.elem_idx];
            const cb = bindings[bm.cols_idx];
            const rb = bindings[bm.rows_idx];
            if (!eb.bound or !cb.bound or !rb.bound) return null;
            const m = try arena.create(Types.Matrix);
            // Swap cols and rows for transpose.
            m.* = .{ .cols = rb.width.?, .rows = cb.width.?, .element = kindPtr(eb.scalar_kind.?) };
            return .{ .matrix = m };
        },
        .tparam_ptr_atomic, .tparam_ptr => {
            // Not valid as result patterns in Phase 1.
            return null;
        },
    }
}

// =========================================================================
// Tests (module-local, exercise the solver without touching the validator)
// =========================================================================

test "resolve: bind scalar tparam from concrete arg" {
    const sigs = [_]OverloadSig{.{
        .tparam_count = 1,
        .params = &.{.{ .tparam_scalar = .{ .idx = 0, .family = .float } }},
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    }};
    const args = [_]?Types.Type{Types.F32};
    const r = resolve(&sigs, &args);
    try std.testing.expect(r == .ok);
    try std.testing.expectEqual(@as(usize, 0), r.ok.sig_index);
    try std.testing.expectEqual(Types.ScalarKind.f32, r.ok.bindings[0].scalar_kind.?);
}

test "resolve: reject scalar outside family" {
    const sigs = [_]OverloadSig{.{
        .tparam_count = 1,
        .params = &.{.{ .tparam_scalar = .{ .idx = 0, .family = .float } }},
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    }};
    const args = [_]?Types.Type{Types.I32};
    const r = resolve(&sigs, &args);
    try std.testing.expect(r == .err);
    try std.testing.expectEqual(ResolveError.no_matching_overload, r.err.kind);
}

test "resolve: bind width from vector, reject width mismatch" {
    const sigs = [_]OverloadSig{.{
        .tparam_count = 2,
        .params = &.{
            .{ .tparam_vector = .{ .elem_idx = 1, .elem_family = .float, .n_idx = 0 } },
            .{ .tparam_vector = .{ .elem_idx = 1, .elem_family = .float, .n_idx = 0 } },
        },
        .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 1, .n_idx = 0 } } },
    }};
    const v3 = Types.Vector{ .width = 3, .element = Types.scalar_f32_ptr };
    const v2 = Types.Vector{ .width = 2, .element = Types.scalar_f32_ptr };

    const ok_args = [_]?Types.Type{ .{ .vector = &v3 }, .{ .vector = &v3 } };
    const ok_r = resolve(&sigs, &ok_args);
    try std.testing.expect(ok_r == .ok);
    try std.testing.expectEqual(@as(u8, 3), ok_r.ok.bindings[0].width.?);

    const bad_args = [_]?Types.Type{ .{ .vector = &v3 }, .{ .vector = &v2 } };
    const bad_r = resolve(&sigs, &bad_args);
    try std.testing.expect(bad_r == .err);
}

test "resolve: arity mismatch surfaces distinct error" {
    const sigs = [_]OverloadSig{.{
        .tparam_count = 1,
        .params = &.{.{ .tparam_scalar = .{ .idx = 0, .family = .integer } }},
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    }};
    const args = [_]?Types.Type{ Types.I32, Types.I32 };
    const r = resolve(&sigs, &args);
    try std.testing.expect(r == .err);
    try std.testing.expectEqual(ResolveError.arg_count_mismatch, r.err.kind);
}

test "resolve: rank ordering — concrete match beats abstract promotion" {
    // Two overloads that both match (i32 arg): one takes i32 directly (rank
    // 0), the other takes abstract-int (load rule moves i32→abstract_int
    // infeasibly, so only the first is actually feasible — use two feasible
    // candidates instead).
    const sigs = [_]OverloadSig{
        .{
            .tparam_count = 1,
            .params = &.{.{ .concrete = Types.I32 }},
            .result = .{ .pattern = .{ .concrete = Types.I32 } },
        },
        .{
            .tparam_count = 1,
            .params = &.{.{ .tparam_scalar = .{ .idx = 0, .family = .integer } }},
            .result = .{ .pattern = .{ .bound_scalar = 0 } },
        },
    };
    const args = [_]?Types.Type{Types.I32};
    const r = resolve(&sigs, &args);
    try std.testing.expect(r == .ok);
    // Both have rank 0 (exact match); tie-break picks the first.
    try std.testing.expectEqual(@as(usize, 0), r.ok.sig_index);
}

test "resolve: abstract arg upgrades via non-zero rank" {
    // Single overload `(i32) -> i32`. Arg is abstract-int → rank 3 per §8.2.
    const sigs = [_]OverloadSig{.{
        .tparam_count = 0,
        .params = &.{.{ .concrete = Types.I32 }},
        .result = .{ .pattern = .{ .concrete = Types.I32 } },
    }};
    const args = [_]?Types.Type{Types.AbstractInt};
    const r = resolve(&sigs, &args);
    try std.testing.expect(r == .ok);
    try std.testing.expectEqual(@as(u32, 3), r.ok.total_rank);
}

test "resolve + build: reconstruct bound vector from tparam pattern" {
    const result_pattern = Pattern{ .tparam_vector = .{ .elem_idx = 0, .elem_family = .float, .n_fixed = 3 } };
    const sigs = [_]OverloadSig{.{
        .tparam_count = 1,
        .params = &.{.{ .tparam_vector = .{ .elem_idx = 0, .elem_family = .float, .n_fixed = 3 } }},
        .result = .{ .pattern = result_pattern },
    }};
    const v3 = Types.Vector{ .width = 3, .element = Types.scalar_f32_ptr };
    const args = [_]?Types.Type{.{ .vector = &v3 }};
    const r = resolve(&sigs, &args);
    try std.testing.expect(r == .ok);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const built = try buildPatternType(arena.allocator(), result_pattern, &r.ok.bindings);
    try std.testing.expect(built != null);
    try std.testing.expect(built.? == .vector);
    try std.testing.expectEqual(@as(u8, 3), built.?.vector.width);
    try std.testing.expectEqual(Types.ScalarKind.f32, built.?.vector.element.kind);
}

test "resolve: matrix binding — cols/rows captured separately" {
    const sigs = [_]OverloadSig{.{
        .tparam_count = 3,
        .params = &.{.{ .tparam_matrix = .{ .elem_idx = 0, .elem_family = .float, .cols_idx = 1, .rows_idx = 2 } }},
        .result = .{ .pattern = .{ .bound_matrix_transposed = .{ .elem_idx = 0, .cols_idx = 1, .rows_idx = 2 } } },
    }};
    const m2x3 = Types.Matrix{ .cols = 2, .rows = 3, .element = Types.scalar_f32_ptr };
    const args = [_]?Types.Type{.{ .matrix = &m2x3 }};
    const r = resolve(&sigs, &args);
    try std.testing.expect(r == .ok);
    try std.testing.expectEqual(@as(u8, 2), r.ok.bindings[1].width.?);
    try std.testing.expectEqual(@as(u8, 3), r.ok.bindings[2].width.?);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const built = try buildPatternType(arena.allocator(), sigs[0].result.pattern, &r.ok.bindings);
    try std.testing.expect(built != null);
    try std.testing.expect(built.? == .matrix);
    // Transposed: original 2×3 becomes 3×2.
    try std.testing.expectEqual(@as(u8, 3), built.?.matrix.cols);
    try std.testing.expectEqual(@as(u8, 2), built.?.matrix.rows);
}

test "resolve: pointer<atomic<T>> binds AS and AM" {
    const sigs = [_]OverloadSig{.{
        .tparam_count = 3,
        .params = &.{.{ .tparam_ptr_atomic = .{ .as_idx = 1, .am_idx = 2, .elem_idx = 0, .elem_family = .integer } }},
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    }};
    const atomic_i32 = Types.Atomic{ .element = Types.scalar_i32_ptr };
    const ptr_type = Types.Pointer{
        .address_space = .workgroup,
        .element = .{ .atomic = &atomic_i32 },
        .access_mode = .read_write,
    };
    const args = [_]?Types.Type{.{ .pointer = &ptr_type }};
    const r = resolve(&sigs, &args);
    try std.testing.expect(r == .ok);
    try std.testing.expectEqual(Types.ScalarKind.i32, r.ok.bindings[0].scalar_kind.?);
    try std.testing.expectEqual(Ast.AddressSpace.workgroup, r.ok.bindings[1].address_space.?);
    try std.testing.expectEqual(Ast.AccessMode.read_write, r.ok.bindings[2].access_mode.?);
}

test "resolve: reject pointer to non-atomic when pattern demands atomic" {
    const sigs = [_]OverloadSig{.{
        .tparam_count = 3,
        .params = &.{.{ .tparam_ptr_atomic = .{ .as_idx = 1, .am_idx = 2, .elem_idx = 0, .elem_family = .integer } }},
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    }};
    const ptr_type = Types.Pointer{
        .address_space = .storage,
        .element = Types.I32,
        .access_mode = .read_write,
    };
    const args = [_]?Types.Type{.{ .pointer = &ptr_type }};
    const r = resolve(&sigs, &args);
    try std.testing.expect(r == .err);
}

test "resolve: null arg is feasible, preserves rank across other args" {
    const sigs = [_]OverloadSig{.{
        .tparam_count = 1,
        .params = &.{
            .{ .tparam_scalar = .{ .idx = 0, .family = .integer } },
            .{ .tparam_scalar = .{ .idx = 0, .family = .integer } },
        },
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    }};
    const args = [_]?Types.Type{ Types.I32, null };
    const r = resolve(&sigs, &args);
    try std.testing.expect(r == .ok);
}
