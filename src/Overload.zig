//! Declarative builtin overload signatures + unification solver.
//!
//! Every callable WGSL builtin resolves through this engine: `Validator.
//! checkBuiltinCall` asserts `builtin_fn.overloads.len > 0` and hands the
//! argument types to `resolve`. The winning overload's `ResultRule` is
//! then materialized by `Validator.buildOverloadResult`. `bitcast<T>` is
//! the only call site that dispatches from its own block — it seeds
//! slots 0/1 from the template type and calls `resolveSeeded` against
//! one of the `Builtins.bitcast_to_*_sigs` tables, but the solver and
//! signature DSL are the same.
//!
//! Spec: WGSL §8.7 overload resolution. Feasible candidates are ranked
//! by the max `Types.conversionRank` across their bound arguments; the
//! lowest total wins. Ties are broken by declaration order (first wins),
//! which matches Naga/Tint.
//!
//! The Pattern grammar covers: scalars, vectors, matrices, pointers
//! (plain / atomic / runtime-sized array), textures (by kind + dim),
//! samplers (by comparison flag), and concrete singletons. Adding a new
//! builtin shape is a matter of adding a `Pattern` variant and a
//! corresponding `unifyArg` case.

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
    /// every scalar kind including bool. Used by `select` and a few subgroup
    /// ops where T is "any scalar or vector of any scalar".
    any,
    /// bool only — used by `all`/`any`/subgroupAll/subgroupAny for their
    /// `vecN<bool>` overloads.
    bool,
    /// Concrete 32-bit numerics only (i32, u32, f32). Used by bitcast, whose
    /// spec domain excludes f16 (not 32 bits) and abstract numerics (the
    /// validator concretizes them before the sig runs).
    concrete_32,

    pub fn accepts(self: ScalarFamily, kind: Types.ScalarKind) bool {
        return switch (self) {
            .float => kind == .f32 or kind == .f16 or kind == .abstract_float,
            .integer => kind == .i32 or kind == .u32 or kind == .abstract_int,
            .numeric => kind != .bool,
            .abstract_int => kind == .abstract_int,
            .any => true,
            .bool => kind == .bool,
            .concrete_32 => kind == .i32 or kind == .u32 or kind == .f32,
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

    /// matCxR<T> — cols and rows are always fixed-literal here. `swap_for_result
    /// = true` is used by transpose's result pattern to produce matRxC from a
    /// bound matCxR.
    tparam_matrix: struct {
        elem_idx: u8,
        elem_family: ScalarFamily,
        cols_idx: u8,
        rows_idx: u8,
    },

    /// ptr<AS, atomic<T>, AM> — used by the atomic* family. AS/AM bind to
    /// tparams; T binds via `elem_idx`.
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

    /// ptr<AS, array<E>, AM> for arrayLength (§17.14). Both AS and AM bind
    /// to tparam slots — neither is pinned. Per WGSL §6.7.4 a runtime-sized
    /// array can only legally be declared in a storage var, so the array
    /// element + `isRuntimeSized` checks are sufficient on their own —
    /// pinning AS/AM here would just duplicate what the source-level
    /// binding already guarantees while producing worse diagnostics on
    /// mismatches. The element type E is intentionally NOT bound: the
    /// result is fixed `u32` regardless of E, and runtime-sized arrays may
    /// have non-scalar elements (struct, vec, nested array) that the
    /// existing scalar-only Binding can't represent. The pattern enforces
    /// that the array is runtime-sized (`array<E>`, not `array<E, N>`).
    tparam_ptr_runtime_array: struct {
        as_idx: u8,
        am_idx: u8,
    },

    /// A texture type with fixed kind + dimension, optionally binding
    /// the sampled/storage element scalar to a tparam slot. Always a
    /// parameter pattern — WGSL has no builtin that returns a texture.
    ///
    /// Element-binding source by kind:
    ///   sampled / multisampled → `t.sampled_type.?.kind`
    ///   storage → `Types.texelFormatToScalar(t.texel_format).kind`
    ///   depth / depth_multisampled / external → no element; must set
    ///   `elem_idx = no_tparam`.
    ///
    /// Access mode is intentionally NOT constrained here. Two builtins
    /// need it — `textureStore` and `textureLoad`-on-storage — and both
    /// are handled by `Validator.preValidateTextureBuiltin`, which fires
    /// before `Overload.resolve` and produces the specific diagnostic the
    /// user deserves ("needs write, got read" vs "no matching overload").
    /// Making this declarative would require adding a per-field
    /// mismatch-reason channel to the solver for two call sites that have
    /// no peers in the WGSL spec; keeping patterns access-mode-agnostic
    /// also collapses storage sig counts.
    tparam_texture: struct {
        kind: Types.TextureKind,
        dimension: Types.TextureDimension,
        elem_idx: u8 = no_tparam,
        elem_family: ScalarFamily = .numeric,
    },

    /// Re-expansion of a previously bound scalar tparam. Used in result
    /// rules (e.g. atomic ops return T, a pattern that says "same scalar as
    /// param 0's bound T").
    bound_scalar: u8,

    /// Re-expansion of a bound elem_tparam as vecN. Width is taken from
    /// `n_fixed` if non-zero; otherwise from the slot at `n_idx`. The
    /// slot-bound form is used when the width comes from the arg (e.g.
    /// `frexp.exp`); the fixed form is used when the literal width is
    /// part of the signature (e.g. `textureLoad → vec4<T>`).
    bound_vector: struct { elem_idx: u8, n_idx: u8 = no_tparam, n_fixed: u8 = 0 },

    /// Re-expansion of a bound matrix but with cols/rows swapped (transpose).
    bound_matrix_transposed: struct { elem_idx: u8, cols_idx: u8, rows_idx: u8 },

    /// Variadic component composition for vector constructors (WGSL §16.1,
    /// vector case): `vec4(s, vec2, s)`. A *cross-arg* pattern — the whole
    /// argument list (any mix of scalars and vectors) must sum in component
    /// width to exactly `width`, and every argument's element type must
    /// implicitly convert to `elem` (a concrete or abstract scalar type).
    /// Unlike the per-slot `tparam_*` variants this folds across the entire
    /// `arg_types` slice, so a sig using it holds exactly one `params` entry
    /// and matches any non-empty arity. `elem` is carried concretely rather
    /// than as a tparam slot: constructor element types are fixed by the
    /// target (`ctorSigsFor`), never inferred across args.
    variadic_components_to_width: struct { width: u8, elem: Types.Type },

    /// Matrix-constructor dichotomy (WGSL §16.1, matrix case): the args are
    /// either exactly `cols * rows` scalars, or exactly `cols` column
    /// vectors of width `rows` — never a mix. Every element must implicitly
    /// convert to `elem`. Also a single cross-arg `params` entry. Modeled as
    /// one Pattern (not two competing sigs) so the refiner can emit the
    /// "requires all scalar values or all column vectors, not a mix" wording
    /// on a partial match instead of a generic no-match.
    all_scalar_or_all_vector: struct { cols: u8, rows: u8, elem: Types.Type },

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

/// Number of tparams an overload declares. 4 is the current maximum —
/// the pointer-atomic family needs elem_T, AS, AM plus an optional N
/// slot — and every existing signature fits.
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

/// A sig whose single parameter folds across the *entire* argument list
/// rather than matching one slot. Returns that pattern, or null for the
/// ordinary per-slot sigs. Only constructor sigs (`ctorSigsFor`) use these;
/// every builtin sig is per-slot, so this is null on the builtin hot path.
fn reductionPattern(s: OverloadSig) ?Pattern {
    if (s.params.len != 1) return null;
    return switch (s.params[0]) {
        .variadic_components_to_width, .all_scalar_or_all_vector => s.params[0],
        else => null,
    };
}

/// Arity eligibility. Ordinary sigs need an exact param/arg count match; a
/// reduction sig matches any non-empty arg list (the fold enforces the real
/// component / column count). An empty arg list only matches an explicit
/// zero-param sig — the zero-value constructor form — never a reduction.
fn sigAcceptsArity(s: OverloadSig, n: usize) bool {
    if (reductionPattern(s) != null) return n >= 1;
    return s.params.len == n;
}

/// Resolve a call against the overload set for `name`. Arg count must match
/// `params.len` for at least one candidate; otherwise `arg_count_mismatch`.
/// On success, returns the winning sig index and the tparam bindings; the
/// caller then uses `buildResult` to construct the return type.
pub fn resolve(sigs: []const OverloadSig, arg_types: []const ?Types.Type) ResolveResult {
    return resolveSeeded(sigs, @splat(.{}), arg_types);
}

/// Like `resolve`, but starts each candidate's bindings from `seed` instead
/// of the empty binding set. Used by `bitcast<T>`: the validator pre-binds
/// slot 0 to the template's element `ScalarKind` and (for vector templates)
/// slot 1 to the template's width, then the solver unifies the value arg
/// against a shape pattern that references those slots. `bindScalar` /
/// `bindWidth` already implement the "previously-bound — check compatibility"
/// branch, so seeded slots enforce equality for free.
pub fn resolveSeeded(
    sigs: []const OverloadSig,
    seed: [max_tparams]Binding,
    arg_types: []const ?Types.Type,
) ResolveResult {
    // Arity filter.
    var arity_ok: bool = false;
    for (sigs) |s| {
        if (sigAcceptsArity(s, arg_types.len)) {
            arity_ok = true;
            break;
        }
    }
    if (!arity_ok) {
        return .{ .err = .{ .kind = .arg_count_mismatch } };
    }

    var best_idx: ?usize = null;
    var best_rank: u32 = std.math.maxInt(u32);
    var best_bindings: [max_tparams]Binding = seed;
    // Deepest successful unification prefix across every failing candidate.
    // Used to report the "most likely culprit" argument on total failure:
    // if one sig matched through arg 2 and broke at arg 3, and another
    // broke at arg 0, arg 3 is almost always what the user got wrong.
    // Overwriting per-sig (as earlier iterations did) collapsed to the
    // last-tried sig's bad arg, which was usually 0 for irrelevant sigs
    // (e.g. the vector form of a scalar-valued call).
    var last_bad_arg: u8 = 0;

    // Tie-break by declaration order — on strict less-than we take the
    // earliest winner, so two overloads with equal minimum rank leave the
    // first one selected. Matches Naga/Tint; no current signature produces
    // ambiguity between non-equivalent candidates.
    for (sigs, 0..) |s, idx| {
        if (!sigAcceptsArity(s, arg_types.len)) continue;
        var bindings: [max_tparams]Binding = seed;
        var total_rank: u32 = 0;

        if (reductionPattern(s)) |rp| {
            // Cross-arg reduction sig (constructor composition / matrix
            // dichotomy): one pattern folds over the whole argument list.
            // No tparam slots, so `bindings` stays = seed.
            total_rank = unifyReduction(rp, arg_types) catch {
                // Whole-list failure — attribute the culprit to the last arg.
                const bad: u8 = if (arg_types.len == 0) 0 else @intCast(arg_types.len - 1);
                if (bad > last_bad_arg) last_bad_arg = bad;
                continue;
            };
        } else {
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
                if (bad_arg > last_bad_arg) last_bad_arg = bad_arg;
                continue;
            }
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

/// Result of `resolveTargeted`. On success the type IS the caller's
/// `target` — there is no ResultRule to materialize — so unlike
/// `ResolveResult` it carries the built type directly. On failure it
/// carries the same `ResolveFailure` the builtin path produces.
pub const TargetedResult = union(enum) {
    ok: Types.Type,
    err: ResolveFailure,
};

/// Resolve a value-constructor call. Constructor result types are fixed by
/// the syntax — `vec3<f32>(…)` is a vec3<f32> regardless of the argument
/// types — so there is no tparam to bind for the result and no ResultRule
/// to build: on success the result IS `target`. The sigs (produced by
/// `ctorSigsFor`) constrain only the argument list. Cross-arg reduction
/// patterns (vector composition, matrix dichotomy) are folded by the shared
/// solver core, so this is a thin wrapper over `resolveSeeded`.
pub fn resolveTargeted(
    sigs: []const OverloadSig,
    target: Types.Type,
    arg_types: []const ?Types.Type,
) TargetedResult {
    return switch (resolveSeeded(sigs, @splat(.{}), arg_types)) {
        .ok => .{ .ok = target },
        .err => |f| .{ .err = f },
    };
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

    return switch (p.*) {
        .concrete => |t| Types.conversionRank(a, t) orelse error.Mismatch,
        .tparam_scalar => |ts| try unifyTparamScalar(ts, a, bindings),
        .tparam_vector => |tv| try unifyTparamVector(tv, a, bindings),
        .tparam_matrix => |tm| try unifyTparamMatrix(tm, a, bindings),
        .tparam_ptr_atomic => |tp| try unifyTparamPtrAtomic(tp, a, bindings),
        .tparam_ptr => |tp| try unifyTparamPtr(tp, a, bindings),
        .tparam_ptr_runtime_array => |tp| try unifyTparamPtrRuntimeArray(tp, a, bindings),
        .tparam_texture => |tt| try unifyTparamTexture(tt, a, bindings),
        .bound_scalar => |idx| try unifyBoundScalar(idx, a, bindings),
        // `bound_vector` / `bound_matrix_transposed` only appear in result rules
        // today (frexp/modf/transpose); param-position is a later-phase extension.
        .bound_vector, .bound_matrix_transposed => error.Mismatch,
        // Cross-arg reduction patterns never reach the per-slot path — the
        // solver core folds them over the whole arg list before this runs.
        .variadic_components_to_width, .all_scalar_or_all_vector => error.Mismatch,
    };
}

/// Apply the load rule to a single type: reference<AS,T,AM> with AM ∈
/// {read, read_write} is indistinguishable from T at argument sites.
fn loadUnwrap(arg: Types.Type) Types.Type {
    if (arg == .reference) {
        const r = arg.reference;
        if (r.access_mode == .read or r.access_mode == .read_write) return r.element;
    }
    return arg;
}

/// Fold a whole argument list against a cross-arg reduction pattern, returning
/// the max element-conversion rank across args, or Mismatch. A null arg
/// (upstream inference failure) makes the whole call feasible with rank 0 —
/// this mirrors both the per-slot loop's "null is feasible" rule and the old
/// `checkVectorCtorMulti` / `checkMatrixCtorMulti` "unknown arg → skip
/// validation" behavior.
fn unifyReduction(p: Pattern, arg_types: []const ?Types.Type) error{Mismatch}!u32 {
    return switch (p) {
        .variadic_components_to_width => |vc| unifyVariadicComponents(vc.width, vc.elem, arg_types),
        .all_scalar_or_all_vector => |mm| unifyMatrixDichotomy(mm.cols, mm.rows, mm.elem, arg_types),
        else => error.Mismatch,
    };
}

/// Vector composition: the summed component width of every scalar/vector arg
/// must equal `width`, and each arg's element type must implicitly convert to
/// `elem`.
fn unifyVariadicComponents(width: u8, elem: Types.Type, arg_types: []const ?Types.Type) error{Mismatch}!u32 {
    var total: u32 = 0;
    var max_rank: u32 = 0;
    for (arg_types) |arg_opt| {
        const arg = loadUnwrap(arg_opt orelse return 0);
        const elem_type: Types.Type = switch (arg) {
            .scalar => |s| blk: {
                total += 1;
                break :blk .{ .scalar = s };
            },
            .vector => |ve| blk: {
                total += ve.width;
                break :blk .{ .scalar = ve.element };
            },
            else => return error.Mismatch,
        };
        const rank = Types.conversionRank(elem_type, elem) orelse return error.Mismatch;
        max_rank = @max(max_rank, rank);
    }
    if (total != width) return error.Mismatch;
    return max_rank;
}

/// Matrix constructor dichotomy: args are either exactly `cols * rows` scalars
/// or exactly `cols` column vectors of width `rows` — never a mix. Each
/// element must implicitly convert to `elem`.
fn unifyMatrixDichotomy(cols: u8, rows: u8, elem: Types.Type, arg_types: []const ?Types.Type) error{Mismatch}!u32 {
    var all_scalar = true;
    var all_vector = true;
    for (arg_types) |arg_opt| {
        const arg = loadUnwrap(arg_opt orelse return 0);
        if (arg != .scalar) all_scalar = false;
        if (arg != .vector) all_vector = false;
    }

    var max_rank: u32 = 0;
    if (all_scalar) {
        if (arg_types.len != @as(usize, cols) * rows) return error.Mismatch;
        for (arg_types) |arg_opt| {
            const arg = loadUnwrap(arg_opt.?);
            const rank = Types.conversionRank(.{ .scalar = arg.scalar }, elem) orelse return error.Mismatch;
            max_rank = @max(max_rank, rank);
        }
        return max_rank;
    }
    if (all_vector) {
        if (arg_types.len != cols) return error.Mismatch;
        for (arg_types) |arg_opt| {
            const arg = loadUnwrap(arg_opt.?);
            if (arg.vector.width != rows) return error.Mismatch;
            const rank = Types.conversionRank(.{ .scalar = arg.vector.element }, elem) orelse return error.Mismatch;
            max_rank = @max(max_rank, rank);
        }
        return max_rank;
    }
    return error.Mismatch; // mix of scalars and vectors — refiner explains
}

fn unifyTparamScalar(ts: anytype, a: Types.Type, bindings: *[max_tparams]Binding) error{Mismatch}!u32 {
    if (a != .scalar) return error.Mismatch;
    const sk = promoteForFamily(a.scalar.kind, ts.family);
    if (!ts.family.accepts(sk)) return error.Mismatch;
    return try bindScalar(bindings, ts.idx, sk, ts.family);
}

fn unifyTparamVector(tv: anytype, a: Types.Type, bindings: *[max_tparams]Binding) error{Mismatch}!u32 {
    if (a != .vector) return error.Mismatch;
    const v = a.vector;
    if (tv.n_fixed != 0) {
        if (v.width != tv.n_fixed) return error.Mismatch;
    } else if (tv.n_idx != Pattern.no_tparam) {
        if (!try bindWidth(bindings, tv.n_idx, v.width)) return error.Mismatch;
    }
    const elem_kind = promoteForFamily(v.element.kind, tv.elem_family);
    if (!tv.elem_family.accepts(elem_kind)) return error.Mismatch;
    return try bindScalar(bindings, tv.elem_idx, elem_kind, tv.elem_family);
}

fn unifyTparamMatrix(tm: anytype, a: Types.Type, bindings: *[max_tparams]Binding) error{Mismatch}!u32 {
    if (a != .matrix) return error.Mismatch;
    const m = a.matrix;
    if (!try bindWidth(bindings, tm.cols_idx, m.cols)) return error.Mismatch;
    if (!try bindWidth(bindings, tm.rows_idx, m.rows)) return error.Mismatch;
    if (!tm.elem_family.accepts(m.element.kind)) return error.Mismatch;
    return try bindScalar(bindings, tm.elem_idx, m.element.kind, tm.elem_family);
}

fn unifyTparamPtrAtomic(tp: anytype, a: Types.Type, bindings: *[max_tparams]Binding) error{Mismatch}!u32 {
    if (a != .pointer) return error.Mismatch;
    const pp = a.pointer;
    if (pp.element != .atomic) return error.Mismatch;
    const elem_kind = pp.element.atomic.element.kind;
    if (!tp.elem_family.accepts(elem_kind)) return error.Mismatch;
    if (!try bindAddressSpace(bindings, tp.as_idx, pp.address_space)) return error.Mismatch;
    if (!try bindAccessMode(bindings, tp.am_idx, pp.access_mode)) return error.Mismatch;
    _ = try bindScalar(bindings, tp.elem_idx, elem_kind, tp.elem_family);
    return 0;
}

fn unifyTparamPtr(tp: anytype, a: Types.Type, bindings: *[max_tparams]Binding) error{Mismatch}!u32 {
    if (a != .pointer) return error.Mismatch;
    const pp = a.pointer;
    if (pp.address_space != tp.as_fixed) return error.Mismatch;
    // Record elem as a whole-Type binding via scalar-only shortcut.
    // Used by workgroupUniformLoad: when the pointee is a scalar we
    // bind the scalar kind directly; when it's an atomic we bind its
    // inner scalar; non-scalar pointees are still matched shape-only
    // here and recovered from the arg type in `buildResult`.
    if (!try bindAccessMode(bindings, tp.am_idx, pp.access_mode)) return error.Mismatch;
    if (pp.element == .scalar) {
        _ = try bindScalar(bindings, tp.elem_idx, pp.element.scalar.kind, .numeric);
    } else if (pp.element == .atomic) {
        _ = try bindScalar(bindings, tp.elem_idx, pp.element.atomic.element.kind, .numeric);
    }
    return 0;
}

fn unifyTparamPtrRuntimeArray(tp: anytype, a: Types.Type, bindings: *[max_tparams]Binding) error{Mismatch}!u32 {
    if (a != .pointer) return error.Mismatch;
    const pp = a.pointer;
    if (pp.element != .array) return error.Mismatch;
    if (!pp.element.array.isRuntimeSized()) return error.Mismatch;
    if (!try bindAddressSpace(bindings, tp.as_idx, pp.address_space)) return error.Mismatch;
    if (!try bindAccessMode(bindings, tp.am_idx, pp.access_mode)) return error.Mismatch;
    return 0;
}

fn unifyTparamTexture(tt: anytype, a: Types.Type, bindings: *[max_tparams]Binding) error{Mismatch}!u32 {
    if (a != .texture) return error.Mismatch;
    const t = a.texture;
    if (t.kind != tt.kind) return error.Mismatch;
    if (t.dimension != tt.dimension) return error.Mismatch;
    if (tt.elem_idx == Pattern.no_tparam) return 0;
    // Extract the element scalar. Depth / depth_multisampled / external have
    // no element, so a pattern binding elem_idx against them is a sig-author
    // error — reject defensively.
    const elem_kind: Types.ScalarKind = switch (tt.kind) {
        .sampled, .multisampled => blk: {
            const st = t.sampled_type orelse return error.Mismatch;
            break :blk st.kind;
        },
        .storage => blk: {
            if (t.texel_format.len == 0) return error.Mismatch;
            break :blk Types.texelFormatToScalar(t.texel_format).kind;
        },
        .depth, .depth_multisampled, .external => return error.Mismatch,
    };
    if (!tt.elem_family.accepts(elem_kind)) return error.Mismatch;
    return try bindScalar(bindings, tt.elem_idx, elem_kind, tt.elem_family);
}

/// `bound_scalar` in a param position means "the scalar T already bound by an
/// earlier param" — arg must convert to that scalar. Used by atomicAdd/Sub/…
/// and atomicCompareExchangeWeak to require arg[1..] to match arg[0]'s
/// underlying atomic<T>.
fn unifyBoundScalar(idx: u8, a: Types.Type, bindings: *[max_tparams]Binding) error{Mismatch}!u32 {
    const b = bindings[idx];
    const target_kind = (if (b.bound) b.scalar_kind else null) orelse return error.Mismatch;
    const target: Types.Type = .{ .scalar = kindPtr(target_kind) };
    return Types.conversionRank(a, target) orelse error.Mismatch;
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

/// When an abstract scalar meets a tparam whose family expects a different
/// abstract domain, promote to the family-native abstract. Per WGSL §8.7.1
/// (conversion rank table §8.2), AbstractInt → AbstractFloat is a legal
/// promotion when matching a float overload — that's how `sin(1)` picks the
/// f32 overload without an explicit cast. Concrete kinds pass through
/// unchanged; family-incompatible kinds get rejected by `accepts`.
fn promoteForFamily(kind: Types.ScalarKind, family: ScalarFamily) Types.ScalarKind {
    if (kind == .abstract_int and family == .float) return .abstract_float;
    return kind;
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
            if (!eb.bound) return null;
            const width: u8 = if (bv.n_fixed != 0)
                bv.n_fixed
            else blk: {
                const wb = bindings[bv.n_idx];
                if (!wb.bound) return null;
                break :blk wb.width.?;
            };
            const v = try arena.create(Types.Vector);
            v.* = .{ .width = width, .element = kindPtr(eb.scalar_kind.?) };
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
        .tparam_ptr_atomic, .tparam_ptr, .tparam_ptr_runtime_array, .tparam_texture => {
            // Not valid as result patterns: WGSL has no builtin that
            // returns a pointer, atomic, or texture.
            return null;
        },
        .variadic_components_to_width, .all_scalar_or_all_vector => {
            // Param-only cross-arg patterns. Constructor results are fixed to
            // the target type (see `resolveTargeted`), never materialized here.
            return null;
        },
    }
}

// =========================================================================
// Constructor signature derivation
// =========================================================================

/// Emit the value-constructor overload set for `target`, for use with
/// `resolveTargeted`. All constructor knowledge lives here instead of being
/// scattered across a `switch (t)` with per-arm sub-switches — a new
/// constructor shape is one arm here, not a new validator branch. A
/// non-constructible target yields an empty set (the caller gates
/// constructibility separately).
pub fn ctorSigsFor(arena: std.mem.Allocator, target: Types.Type) std.mem.Allocator.Error![]const OverloadSig {
    return switch (target) {
        .scalar => try scalarCtorSigs(arena, target),
        .vector => |ve| try vectorCtorSigs(arena, target, ve),
        .matrix => |mt| try matrixCtorSigs(arena, target, mt),
        .@"struct" => |st| try structCtorSigs(arena, target, st),
        .array => |arr| try arrayCtorSigs(arena, target, arr),
        else => &.{},
    };
}

/// A zero-parameter sig — the zero-value constructor form `T()`.
fn zeroValueSig(target: Types.Type) OverloadSig {
    return .{ .tparam_count = 0, .params = &[_]Pattern{}, .result = .{ .fixed = target } };
}

/// A one-parameter constructor sig with a fixed result.
fn onePatternSig(arena: std.mem.Allocator, target: Types.Type, p: Pattern) std.mem.Allocator.Error!OverloadSig {
    const params = try arena.alloc(Pattern, 1);
    params[0] = p;
    return .{ .tparam_count = 0, .params = params, .result = .{ .fixed = target } };
}

/// Scalar `T`: zero-value, and the explicit conversion `T(any scalar)` —
/// scalar value constructors convert any scalar to any scalar (`f32(1i)`).
fn scalarCtorSigs(arena: std.mem.Allocator, target: Types.Type) std.mem.Allocator.Error![]const OverloadSig {
    const sigs = try arena.alloc(OverloadSig, 2);
    sigs[0] = zeroValueSig(target);
    sigs[1] = try onePatternSig(arena, target, .{ .tparam_scalar = .{ .idx = 0, .family = .any } });
    return sigs;
}

/// Vector `vecN<E>`: zero-value, splat (a single scalar convertible to E),
/// copy/convert (a single same-width vector), and variadic composition.
fn vectorCtorSigs(arena: std.mem.Allocator, target: Types.Type, ve: *const Types.Vector) std.mem.Allocator.Error![]const OverloadSig {
    const elem_t: Types.Type = .{ .scalar = ve.element };
    const sigs = try arena.alloc(OverloadSig, 4);
    sigs[0] = zeroValueSig(target);
    sigs[1] = try onePatternSig(arena, target, .{ .concrete = elem_t }); // splat
    sigs[2] = try onePatternSig(arena, target, .{ .concrete = target }); // copy/convert (implicit here; 4b adds explicit)
    sigs[3] = try onePatternSig(arena, target, .{ .variadic_components_to_width = .{ .width = ve.width, .elem = elem_t } });
    return sigs;
}

/// Matrix `matCxR<E>`: zero-value, copy/convert, and the scalar/column-vector
/// dichotomy.
fn matrixCtorSigs(arena: std.mem.Allocator, target: Types.Type, mt: *const Types.Matrix) std.mem.Allocator.Error![]const OverloadSig {
    const elem_t: Types.Type = .{ .scalar = mt.element };
    const sigs = try arena.alloc(OverloadSig, 3);
    sigs[0] = zeroValueSig(target);
    sigs[1] = try onePatternSig(arena, target, .{ .concrete = target }); // copy/convert
    sigs[2] = try onePatternSig(arena, target, .{ .all_scalar_or_all_vector = .{ .cols = mt.cols, .rows = mt.rows, .elem = elem_t } });
    return sigs;
}

/// Struct `S`: zero-value, and positional `(T1, …, TN) -> S` with per-field
/// implicit convertibility.
fn structCtorSigs(arena: std.mem.Allocator, target: Types.Type, st: *const Types.Struct) std.mem.Allocator.Error![]const OverloadSig {
    const sigs = try arena.alloc(OverloadSig, 2);
    sigs[0] = zeroValueSig(target);
    const params = try arena.alloc(Pattern, st.fields.len);
    for (st.fields, 0..) |field, i| params[i] = .{ .concrete = field.typ };
    sigs[1] = .{ .tparam_count = 0, .params = params, .result = .{ .fixed = target } };
    return sigs;
}

/// Array `array<E, N>`: zero-value, and positional `(E, …, E) × N`.
/// Runtime-sized arrays (`count == 0`) have no element-constructor form.
fn arrayCtorSigs(arena: std.mem.Allocator, target: Types.Type, arr: *const Types.Array) std.mem.Allocator.Error![]const OverloadSig {
    if (arr.count == 0) {
        const sigs = try arena.alloc(OverloadSig, 1);
        sigs[0] = zeroValueSig(target);
        return sigs;
    }
    const sigs = try arena.alloc(OverloadSig, 2);
    sigs[0] = zeroValueSig(target);
    const params = try arena.alloc(Pattern, arr.count);
    for (params) |*p| p.* = .{ .concrete = arr.element };
    sigs[1] = .{ .tparam_count = 0, .params = params, .result = .{ .fixed = target } };
    return sigs;
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

// =========================================================================
// resolveSeeded + ScalarFamily.concrete_32
// =========================================================================

test "ScalarFamily.concrete_32 accepts i32/u32/f32, rejects f16/bool/abstract" {
    try std.testing.expect(ScalarFamily.concrete_32.accepts(.i32));
    try std.testing.expect(ScalarFamily.concrete_32.accepts(.u32));
    try std.testing.expect(ScalarFamily.concrete_32.accepts(.f32));
    try std.testing.expect(!ScalarFamily.concrete_32.accepts(.f16));
    try std.testing.expect(!ScalarFamily.concrete_32.accepts(.bool));
    try std.testing.expect(!ScalarFamily.concrete_32.accepts(.abstract_int));
    try std.testing.expect(!ScalarFamily.concrete_32.accepts(.abstract_float));
}

test "resolveSeeded: seeded scalar kind binds slot 0, solver binds slot 2" {
    // Bitcast-style sig: (scalar_32 S) → T where T is pre-seeded in slot 0.
    const sigs = [_]OverloadSig{.{
        .tparam_count = 3,
        .params = &.{.{ .tparam_scalar = .{ .idx = 2, .family = .concrete_32 } }},
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    }};
    var seed: [max_tparams]Binding = @splat(.{});
    seed[0] = .{ .bound = true, .scalar_kind = .f32 };
    const args = [_]?Types.Type{Types.U32};
    const r = resolveSeeded(&sigs, seed, &args);
    try std.testing.expect(r == .ok);
    // Seeded slot 0 preserved:
    try std.testing.expectEqual(Types.ScalarKind.f32, r.ok.bindings[0].scalar_kind.?);
    // Solver-bound slot 2:
    try std.testing.expectEqual(Types.ScalarKind.u32, r.ok.bindings[2].scalar_kind.?);
}

test "resolveSeeded: seeded width forces arg width to match" {
    // vecN<concrete_32> where N is pre-seeded. arg must have same width.
    const sigs = [_]OverloadSig{.{
        .tparam_count = 3,
        .params = &.{.{ .tparam_vector = .{ .elem_idx = 2, .elem_family = .concrete_32, .n_idx = 1 } }},
        .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_idx = 1 } } },
    }};
    var seed: [max_tparams]Binding = @splat(.{});
    seed[0] = .{ .bound = true, .scalar_kind = .i32 };
    seed[1] = .{ .bound = true, .width = 3 };

    const v3_u32 = Types.Vector{ .width = 3, .element = Types.scalar_u32_ptr };
    const ok_r = resolveSeeded(&sigs, seed, &[_]?Types.Type{.{ .vector = &v3_u32 }});
    try std.testing.expect(ok_r == .ok);
    try std.testing.expectEqual(@as(u8, 3), ok_r.ok.bindings[1].width.?);

    const v2_u32 = Types.Vector{ .width = 2, .element = Types.scalar_u32_ptr };
    const bad_r = resolveSeeded(&sigs, seed, &[_]?Types.Type{.{ .vector = &v2_u32 }});
    try std.testing.expect(bad_r == .err);
}

test "resolveSeeded: concrete param works without touching seeded slots" {
    // (vec2<f16>) → T where T is pre-seeded. Param is concrete, no binding.
    const vec2_f16 = Types.Vector{ .width = 2, .element = Types.scalar_f16_ptr };
    const vec2_f16_type: Types.Type = .{ .vector = &vec2_f16 };
    const sigs = [_]OverloadSig{.{
        .tparam_count = 1,
        .params = &.{.{ .concrete = vec2_f16_type }},
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    }};
    var seed: [max_tparams]Binding = @splat(.{});
    seed[0] = .{ .bound = true, .scalar_kind = .i32 };
    const r = resolveSeeded(&sigs, seed, &[_]?Types.Type{vec2_f16_type});
    try std.testing.expect(r == .ok);
    try std.testing.expectEqual(Types.ScalarKind.i32, r.ok.bindings[0].scalar_kind.?);
}

test "resolveSeeded: rejects arg outside concrete_32 family (f16)" {
    const sigs = [_]OverloadSig{.{
        .tparam_count = 3,
        .params = &.{.{ .tparam_scalar = .{ .idx = 2, .family = .concrete_32 } }},
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    }};
    var seed: [max_tparams]Binding = @splat(.{});
    seed[0] = .{ .bound = true, .scalar_kind = .f32 };
    const r = resolveSeeded(&sigs, seed, &[_]?Types.Type{Types.F16});
    try std.testing.expect(r == .err);
    try std.testing.expectEqual(ResolveError.no_matching_overload, r.err.kind);
}

test "resolveSeeded: empty seed is equivalent to resolve()" {
    const sigs = [_]OverloadSig{.{
        .tparam_count = 1,
        .params = &.{.{ .tparam_scalar = .{ .idx = 0, .family = .integer } }},
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    }};
    const args = [_]?Types.Type{Types.I32};
    const seeded = resolveSeeded(&sigs, @splat(.{}), &args);
    const plain = resolve(&sigs, &args);
    try std.testing.expect(seeded == .ok);
    try std.testing.expect(plain == .ok);
    try std.testing.expectEqual(plain.ok.sig_index, seeded.ok.sig_index);
    try std.testing.expectEqual(plain.ok.bindings[0].scalar_kind.?, seeded.ok.bindings[0].scalar_kind.?);
}

// -------------------------------------------------------------------------
// tparam_texture + bound_vector.n_fixed
// -------------------------------------------------------------------------

test "tparam_texture: binds sampled element from texture_2d<f32>" {
    const sigs = [_]OverloadSig{.{
        .tparam_count = 1,
        .params = &.{.{ .tparam_texture = .{
            .kind = .sampled,
            .dimension = .@"2d",
            .elem_idx = 0,
            .elem_family = .numeric,
        } }},
        .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_fixed = 4 } } },
    }};
    const tex = Types.Texture{
        .kind = .sampled,
        .dimension = .@"2d",
        .sampled_type = Types.scalar_f32_ptr,
        .texel_format = "",
        .access_mode = .read,
    };
    const r = resolve(&sigs, &[_]?Types.Type{.{ .texture = &tex }});
    try std.testing.expect(r == .ok);
    try std.testing.expectEqual(Types.ScalarKind.f32, r.ok.bindings[0].scalar_kind.?);
}

test "tparam_texture: binds integer element from texture_2d<i32>" {
    const sigs = [_]OverloadSig{.{
        .tparam_count = 1,
        .params = &.{.{ .tparam_texture = .{
            .kind = .sampled,
            .dimension = .@"2d",
            .elem_idx = 0,
            .elem_family = .numeric,
        } }},
        .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_fixed = 4 } } },
    }};
    const tex = Types.Texture{
        .kind = .sampled,
        .dimension = .@"2d",
        .sampled_type = Types.scalar_i32_ptr,
        .texel_format = "",
        .access_mode = .read,
    };
    const r = resolve(&sigs, &[_]?Types.Type{.{ .texture = &tex }});
    try std.testing.expect(r == .ok);
    try std.testing.expectEqual(Types.ScalarKind.i32, r.ok.bindings[0].scalar_kind.?);
}

test "tparam_texture: storage element comes from texel_format" {
    const sigs = [_]OverloadSig{.{
        .tparam_count = 1,
        .params = &.{.{ .tparam_texture = .{
            .kind = .storage,
            .dimension = .@"2d",
            .elem_idx = 0,
            .elem_family = .numeric,
        } }},
        .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_fixed = 4 } } },
    }};

    const unorm = Types.Texture{
        .kind = .storage,
        .dimension = .@"2d",
        .sampled_type = null,
        .texel_format = "rgba8unorm",
        .access_mode = .read,
    };
    const r_unorm = resolve(&sigs, &[_]?Types.Type{.{ .texture = &unorm }});
    try std.testing.expect(r_unorm == .ok);
    try std.testing.expectEqual(Types.ScalarKind.f32, r_unorm.ok.bindings[0].scalar_kind.?);

    const sint = Types.Texture{
        .kind = .storage,
        .dimension = .@"2d",
        .sampled_type = null,
        .texel_format = "rg32sint",
        .access_mode = .read,
    };
    const r_sint = resolve(&sigs, &[_]?Types.Type{.{ .texture = &sint }});
    try std.testing.expect(r_sint == .ok);
    try std.testing.expectEqual(Types.ScalarKind.i32, r_sint.ok.bindings[0].scalar_kind.?);

    const uint = Types.Texture{
        .kind = .storage,
        .dimension = .@"2d",
        .sampled_type = null,
        .texel_format = "r32uint",
        .access_mode = .read_write,
    };
    const r_uint = resolve(&sigs, &[_]?Types.Type{.{ .texture = &uint }});
    try std.testing.expect(r_uint == .ok);
    try std.testing.expectEqual(Types.ScalarKind.u32, r_uint.ok.bindings[0].scalar_kind.?);
}

test "tparam_texture: rejects wrong kind (storage pattern, sampled arg)" {
    const sigs = [_]OverloadSig{.{
        .tparam_count = 1,
        .params = &.{.{ .tparam_texture = .{
            .kind = .storage,
            .dimension = .@"2d",
            .elem_idx = 0,
            .elem_family = .numeric,
        } }},
        .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_fixed = 4 } } },
    }};
    const tex = Types.Texture{
        .kind = .sampled,
        .dimension = .@"2d",
        .sampled_type = Types.scalar_f32_ptr,
        .texel_format = "",
        .access_mode = .read,
    };
    const r = resolve(&sigs, &[_]?Types.Type{.{ .texture = &tex }});
    try std.testing.expect(r == .err);
    try std.testing.expectEqual(ResolveError.no_matching_overload, r.err.kind);
}

test "tparam_texture: rejects wrong dimension (2d pattern, 3d arg)" {
    const sigs = [_]OverloadSig{.{
        .tparam_count = 1,
        .params = &.{.{ .tparam_texture = .{
            .kind = .sampled,
            .dimension = .@"2d",
            .elem_idx = 0,
            .elem_family = .numeric,
        } }},
        .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_fixed = 4 } } },
    }};
    const tex = Types.Texture{
        .kind = .sampled,
        .dimension = .@"3d",
        .sampled_type = Types.scalar_f32_ptr,
        .texel_format = "",
        .access_mode = .read,
    };
    const r = resolve(&sigs, &[_]?Types.Type{.{ .texture = &tex }});
    try std.testing.expect(r == .err);
}

test "tparam_texture: elem_family.integer rejects texture_2d<f32>" {
    const sigs = [_]OverloadSig{.{
        .tparam_count = 1,
        .params = &.{.{ .tparam_texture = .{
            .kind = .sampled,
            .dimension = .@"2d",
            .elem_idx = 0,
            .elem_family = .integer,
        } }},
        .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_fixed = 4 } } },
    }};
    const tex = Types.Texture{
        .kind = .sampled,
        .dimension = .@"2d",
        .sampled_type = Types.scalar_f32_ptr,
        .texel_format = "",
        .access_mode = .read,
    };
    const r = resolve(&sigs, &[_]?Types.Type{.{ .texture = &tex }});
    try std.testing.expect(r == .err);
}

test "tparam_texture: depth texture with elem_idx=no_tparam accepts" {
    const sigs = [_]OverloadSig{.{
        .tparam_count = 0,
        .params = &.{.{ .tparam_texture = .{
            .kind = .depth,
            .dimension = .@"2d",
        } }},
        .result = .{ .fixed = Types.F32 },
    }};
    const tex = Types.Texture{
        .kind = .depth,
        .dimension = .@"2d",
        .sampled_type = null,
        .texel_format = "",
        .access_mode = .read,
    };
    const r = resolve(&sigs, &[_]?Types.Type{.{ .texture = &tex }});
    try std.testing.expect(r == .ok);
}

test "tparam_texture: unwraps reference<handle, texture, read>" {
    // Module-scope `var<handle>` textures surface as a reference to the
    // texture type. The solver's load rule should unwrap this the same
    // way it does for memory-backed var declarations.
    const sigs = [_]OverloadSig{.{
        .tparam_count = 1,
        .params = &.{.{ .tparam_texture = .{
            .kind = .sampled,
            .dimension = .@"2d",
            .elem_idx = 0,
            .elem_family = .numeric,
        } }},
        .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_fixed = 4 } } },
    }};
    const tex = Types.Texture{
        .kind = .sampled,
        .dimension = .@"2d",
        .sampled_type = Types.scalar_f32_ptr,
        .texel_format = "",
        .access_mode = .read,
    };
    const ref = Types.Reference{
        .address_space = .handle,
        .element = .{ .texture = &tex },
        .access_mode = .read,
    };
    const r = resolve(&sigs, &[_]?Types.Type{.{ .reference = &ref }});
    try std.testing.expect(r == .ok);
    try std.testing.expectEqual(Types.ScalarKind.f32, r.ok.bindings[0].scalar_kind.?);
}

test "bound_vector.n_fixed: materializes vec4 from bound element" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var bindings: [max_tparams]Binding = @splat(.{});
    bindings[0] = .{ .bound = true, .scalar_kind = .i32 };

    const pat: Pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_fixed = 4 } };
    const t = try buildPatternType(arena_state.allocator(), pat, &bindings);
    try std.testing.expect(t != null);
    try std.testing.expect(t.? == .vector);
    try std.testing.expectEqual(@as(u8, 4), t.?.vector.width);
    try std.testing.expectEqual(Types.ScalarKind.i32, t.?.vector.element.kind);
}

test "buildPatternType: tparam_texture returns null (result-position unsupported)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var bindings: [max_tparams]Binding = @splat(.{});
    const pat: Pattern = .{ .tparam_texture = .{
        .kind = .sampled,
        .dimension = .@"2d",
    } };
    const t = try buildPatternType(arena_state.allocator(), pat, &bindings);
    try std.testing.expect(t == null);
}

// -------------------------------------------------------------------------
// tparam_ptr_runtime_array (arrayLength)
// -------------------------------------------------------------------------

test "tparam_ptr_runtime_array: accepts ptr<storage, array<f32>, read>" {
    const sigs = [_]OverloadSig{.{
        .tparam_count = 2,
        .params = &.{.{ .tparam_ptr_runtime_array = .{ .as_idx = 0, .am_idx = 1 } }},
        .result = .{ .fixed = Types.U32 },
    }};
    const arr = Types.Array{ .element = Types.F32, .count = 0 };
    const ptr = Types.Pointer{
        .address_space = .storage,
        .element = .{ .array = &arr },
        .access_mode = .read,
    };
    const r = resolve(&sigs, &[_]?Types.Type{.{ .pointer = &ptr }});
    try std.testing.expect(r == .ok);
    try std.testing.expectEqual(Ast.AddressSpace.storage, r.ok.bindings[0].address_space.?);
    try std.testing.expectEqual(Ast.AccessMode.read, r.ok.bindings[1].access_mode.?);
}

test "tparam_ptr_runtime_array: accepts ptr<storage, array<f32>, read_write>" {
    const sigs = [_]OverloadSig{.{
        .tparam_count = 2,
        .params = &.{.{ .tparam_ptr_runtime_array = .{ .as_idx = 0, .am_idx = 1 } }},
        .result = .{ .fixed = Types.U32 },
    }};
    const arr = Types.Array{ .element = Types.F32, .count = 0 };
    const ptr = Types.Pointer{
        .address_space = .storage,
        .element = .{ .array = &arr },
        .access_mode = .read_write,
    };
    const r = resolve(&sigs, &[_]?Types.Type{.{ .pointer = &ptr }});
    try std.testing.expect(r == .ok);
    try std.testing.expectEqual(Ast.AccessMode.read_write, r.ok.bindings[1].access_mode.?);
}

test "tparam_ptr_runtime_array: rejects sized array (count != 0)" {
    const sigs = [_]OverloadSig{.{
        .tparam_count = 2,
        .params = &.{.{ .tparam_ptr_runtime_array = .{ .as_idx = 0, .am_idx = 1 } }},
        .result = .{ .fixed = Types.U32 },
    }};
    const arr = Types.Array{ .element = Types.F32, .count = 16 };
    const ptr = Types.Pointer{
        .address_space = .storage,
        .element = .{ .array = &arr },
        .access_mode = .read,
    };
    const r = resolve(&sigs, &[_]?Types.Type{.{ .pointer = &ptr }});
    try std.testing.expect(r == .err);
}

test "tparam_ptr_runtime_array: accepts unconventional AS but binds whatever is given" {
    // The pattern is permissive about AS; per spec only `storage` is legal,
    // but upstream var-decl validation already rejects runtime-sized arrays
    // in workgroup/uniform/function. The pattern just records what it sees.
    const sigs = [_]OverloadSig{.{
        .tparam_count = 2,
        .params = &.{.{ .tparam_ptr_runtime_array = .{ .as_idx = 0, .am_idx = 1 } }},
        .result = .{ .fixed = Types.U32 },
    }};
    const arr = Types.Array{ .element = Types.F32, .count = 0 };
    const ptr = Types.Pointer{
        .address_space = .function,
        .element = .{ .array = &arr },
        .access_mode = .read_write,
    };
    const r = resolve(&sigs, &[_]?Types.Type{.{ .pointer = &ptr }});
    try std.testing.expect(r == .ok);
    try std.testing.expectEqual(Ast.AddressSpace.function, r.ok.bindings[0].address_space.?);
}

test "tparam_ptr_runtime_array: rejects pointer to non-array" {
    const sigs = [_]OverloadSig{.{
        .tparam_count = 2,
        .params = &.{.{ .tparam_ptr_runtime_array = .{ .as_idx = 0, .am_idx = 1 } }},
        .result = .{ .fixed = Types.U32 },
    }};
    const ptr = Types.Pointer{
        .address_space = .storage,
        .element = Types.F32,
        .access_mode = .read,
    };
    const r = resolve(&sigs, &[_]?Types.Type{.{ .pointer = &ptr }});
    try std.testing.expect(r == .err);
}

test "tparam_ptr_runtime_array: rejects non-pointer arg" {
    const sigs = [_]OverloadSig{.{
        .tparam_count = 2,
        .params = &.{.{ .tparam_ptr_runtime_array = .{ .as_idx = 0, .am_idx = 1 } }},
        .result = .{ .fixed = Types.U32 },
    }};
    const r = resolve(&sigs, &[_]?Types.Type{Types.U32});
    try std.testing.expect(r == .err);
}

test "buildPatternType: tparam_ptr_runtime_array returns null (result-position unsupported)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var bindings: [max_tparams]Binding = @splat(.{});
    const pat: Pattern = .{ .tparam_ptr_runtime_array = .{ .as_idx = 0, .am_idx = 1 } };
    const t = try buildPatternType(arena_state.allocator(), pat, &bindings);
    try std.testing.expect(t == null);
}
