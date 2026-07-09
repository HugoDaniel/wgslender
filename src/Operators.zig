//! Declarative binary/unary operator overload signatures, resolved through the
//! shared `Overload` engine — the operator analogue of `Builtins.zig`.
//!
//! WGSL specifies operators as overload sets exactly like builtins (§8.7): a
//! candidate list, ranked by conversion cost, with the winner's result rule
//! materialized from the tparam bindings. This module holds those sig sets so
//! the validator's `binaryViaEngine` / `unaryViaEngine` call sites stay a thin
//! resolve-and-materialize shell (mirroring `ctorViaEngine`) instead of nine
//! hand-rolled per-operator checkers.
//!
//! Families are migrated onto this path one commit at a time (Block 2.1).
//! `binarySigs` returns an empty set for operators still handled by their
//! legacy checker; the validator only routes migrated operators here, so an
//! empty set is never actually resolved against.
//!
//! Value-dependent post-checks (division-by-zero, shift-amount-vs-bitwidth)
//! are NOT expressible as overloads and stay at the call site, applied after a
//! successful resolve — the same split `Builtins`/`textureStore` use.

const std = @import("std");
const Ast = @import("Ast.zig");
const Types = @import("Types.zig");
const Overload = @import("Overload.zig");

const Sig = Overload.OverloadSig;
const Pattern = Overload.Pattern;

// A `bool^bool -> bool` overload, shared by logical and bitwise families.
const bool_pair: [2]Pattern = .{ .{ .concrete = Types.Bool }, .{ .concrete = Types.Bool } };

/// Logical `&&` / `||` (§8.7): both operands must be *scalar* `bool`; result
/// `bool`. No vector form — the short-circuit logical operators are scalar-only
/// (unlike the bitwise `&`/`|` which also accept `bool`).
const logical_sigs = [_]Sig{
    .{ .tparam_count = 0, .params = &bool_pair, .result = .{ .fixed = Types.Bool } },
};

/// Bitwise `&` / `|` / `^` (§8.9): `bool^bool -> bool`, or `T^T -> T` for a
/// common integer scalar, or `vecN<T>^vecN<T> -> vecN<T>` for a common integer
/// element and matching width. Mixed-sign, width-mismatched, and scalar↔vector
/// pairs have no matching overload — the engine rejects them (the old checker
/// silently failed on these).
const bitwise_sigs = [_]Sig{
    .{ .tparam_count = 0, .params = &bool_pair, .result = .{ .fixed = Types.Bool } },
    .{
        .tparam_count = 1,
        .params = &.{
            .{ .tparam_scalar = .{ .idx = 0, .family = .integer } },
            .{ .tparam_scalar = .{ .idx = 0, .family = .integer } },
        },
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    },
    .{
        .tparam_count = 2,
        .params = &.{
            .{ .tparam_vector = .{ .elem_idx = 0, .elem_family = .integer, .n_idx = 1 } },
            .{ .tparam_vector = .{ .elem_idx = 0, .elem_family = .integer, .n_idx = 1 } },
        },
        .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_idx = 1 } } },
    },
};

/// Shift `<<` / `>>` (§8.7). Asymmetric: the left operand is any integer
/// (`i32`/`u32`/abstract-int) scalar or vector, the *shift amount* is `u32`
/// (abstract-int accepted, concretizing to u32) with a matching shape, and the
/// result is the **left** operand's type — not a common type. The scalar and
/// vector forms don't share the amount's element tparam with the result, so the
/// amount's kind never leaks into the result. Amount kinds outside `u32`/abstract
/// (e.g. `i32`), width mismatches, and scalar↔vector shape mismatches have no
/// matching overload; the value-dependent bit-width check (§8.7) is a call-site
/// post-check applied after a successful resolve.
const shift_sigs = [_]Sig{
    .{
        .tparam_count = 2,
        .params = &.{
            .{ .tparam_scalar = .{ .idx = 0, .family = .integer } },
            .{ .tparam_scalar = .{ .idx = 1, .family = .u32_or_abstract } },
        },
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    },
    .{
        .tparam_count = 3,
        .params = &.{
            .{ .tparam_vector = .{ .elem_idx = 0, .elem_family = .integer, .n_idx = 1 } },
            .{ .tparam_vector = .{ .elem_idx = 2, .elem_family = .u32_or_abstract, .n_idx = 1 } },
        },
        .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_idx = 1 } } },
    },
};

/// Comparison `<` / `<=` / `>` / `>=` (§8.7): a common numeric scalar
/// (`T < T -> bool`) or a common numeric vector of matching width
/// (`vecN<T> < vecN<T> -> vecN<bool>`). Bool operands have no comparison form
/// (only `==`/`!=` compare bools); matrices and other composites match
/// neither sig. The shared element tparam (idx 0) enforces the common-type
/// requirement, so mixed-sign (`1i < 1u`), int-vs-float, and element- or
/// width-mismatched vector pairs have no matching overload. The result is
/// bool-shaped like the operand, independent of its element type.
const comparison_sigs = [_]Sig{
    .{
        .tparam_count = 1,
        .params = &.{
            .{ .tparam_scalar = .{ .idx = 0, .family = .numeric } },
            .{ .tparam_scalar = .{ .idx = 0, .family = .numeric } },
        },
        .result = .{ .bool_shape_of = 0 },
    },
    .{
        .tparam_count = 2,
        .params = &.{
            .{ .tparam_vector = .{ .elem_idx = 0, .elem_family = .numeric, .n_idx = 1 } },
            .{ .tparam_vector = .{ .elem_idx = 0, .elem_family = .numeric, .n_idx = 1 } },
        },
        .result = .{ .bool_shape_of = 0 },
    },
};

/// Equality `==` / `!=` (§8.7): any common scalar (`T == T -> bool`) or any
/// common vector of matching width (`vecN<T> == vecN<T> -> vecN<bool>`).
/// Unlike comparison, bool operands ARE comparable, so the element family is
/// `.any`. The shared element tparam (idx 0) enforces the common-type
/// requirement — mixed-sign, scalar-bool-vs-int, and element/width-mismatched
/// pairs have no matching overload. Matrices and other composites match
/// neither sig: WGSL has no matrix/struct/array equality, and the result is
/// always bool-shaped like the operand.
const equality_sigs = [_]Sig{
    .{
        .tparam_count = 1,
        .params = &.{
            .{ .tparam_scalar = .{ .idx = 0, .family = .any } },
            .{ .tparam_scalar = .{ .idx = 0, .family = .any } },
        },
        .result = .{ .bool_shape_of = 0 },
    },
    .{
        .tparam_count = 2,
        .params = &.{
            .{ .tparam_vector = .{ .elem_idx = 0, .elem_family = .any, .n_idx = 1 } },
            .{ .tparam_vector = .{ .elem_idx = 0, .elem_family = .any, .n_idx = 1 } },
        },
        .result = .{ .bool_shape_of = 0 },
    },
};

// -- Arithmetic `+ - * / %` (§8.7) -----------------------------------------
//
// All five arithmetic operators share the scalar / vector / scalar-broadcast
// forms below; they differ only in the composite (matrix) forms each one
// additionally admits — `+`/`-` add same-shape matrices, `*` adds the
// matrix/vector/scalar products, and `/`/`%` admit no composite form. The
// element family is `.numeric` (no bool): the old `commonType`-identity fast
// path wrongly accepted `bool` arithmetic and returned a `bool` result. The
// shared element tparam (idx 0) enforces the common-type requirement; the
// shared width tparam (idx 1) rejects width mismatches.

/// `T op T -> T` for a common numeric scalar.
const arith_scalar = Sig{ .tparam_count = 1, .params = &.{
    .{ .tparam_scalar = .{ .idx = 0, .family = .numeric } },
    .{ .tparam_scalar = .{ .idx = 0, .family = .numeric } },
}, .result = .{ .pattern = .{ .bound_scalar = 0 } } };

/// `vecN<T> op vecN<T> -> vecN<T>` (component-wise).
const arith_vec = Sig{ .tparam_count = 2, .params = &.{
    .{ .tparam_vector = .{ .elem_idx = 0, .elem_family = .numeric, .n_idx = 1 } },
    .{ .tparam_vector = .{ .elem_idx = 0, .elem_family = .numeric, .n_idx = 1 } },
}, .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_idx = 1 } } } };

/// `vecN<T> op T -> vecN<T>` (scalar broadcast; the scalar shares the vector's
/// element tparam, so `vec2<i32> + 1u` is rejected as a common-type failure).
const arith_vec_scalar = Sig{ .tparam_count = 2, .params = &.{
    .{ .tparam_vector = .{ .elem_idx = 0, .elem_family = .numeric, .n_idx = 1 } },
    .{ .tparam_scalar = .{ .idx = 0, .family = .numeric } },
}, .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_idx = 1 } } } };

/// `T op vecN<T> -> vecN<T>` (scalar broadcast, scalar first).
const arith_scalar_vec = Sig{ .tparam_count = 2, .params = &.{
    .{ .tparam_scalar = .{ .idx = 0, .family = .numeric } },
    .{ .tparam_vector = .{ .elem_idx = 0, .elem_family = .numeric, .n_idx = 1 } },
}, .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_idx = 1 } } } };

/// The four scalar/vector forms every arithmetic operator shares.
const arith_scalar_vector_forms = [_]Sig{ arith_scalar, arith_vec, arith_vec_scalar, arith_scalar_vec };

/// Addition / subtraction `+` `-` (§8.7): the shared scalar/vector forms plus
/// same-shape matrix `matCxR<T> +/- matCxR<T> -> matCxR<T>`. Both operands
/// share the cols (idx 1) and rows (idx 2) tparams, so only identical
/// dimensions add — `mat2x3 + mat3x2` fails to unify. Matrices are float-only.
const addsub_sigs = arith_scalar_vector_forms ++ [_]Sig{
    .{ .tparam_count = 3, .params = &.{
        .{ .tparam_matrix = .{ .elem_idx = 0, .elem_family = .float, .cols_idx = 1, .rows_idx = 2 } },
        .{ .tparam_matrix = .{ .elem_idx = 0, .elem_family = .float, .cols_idx = 1, .rows_idx = 2 } },
    }, .result = .{ .pattern = .{ .tparam_matrix = .{ .elem_idx = 0, .elem_family = .float, .cols_idx = 1, .rows_idx = 2 } } } },
};

/// Division `/` (§8.7): the shared scalar / vector / scalar-broadcast forms
/// only — WGSL defines no matrix division, so unlike `+`/`-` there is no
/// composite form. The old `commonType`-based `divResultType` fast path wrongly
/// accepted `bool` operands (returning `bool`) and same-shape `matCxR / matCxR`
/// (returning a matrix); neither matches a sig here, so both now report
/// `E0201`. The value-dependent const division-by-zero check is not
/// overload-expressible and stays a call-site post-check.
const div_sigs = arith_scalar_vector_forms;

/// Overload set for a binary operator, or an empty set for operators whose
/// legacy checker still owns them (only migrated operators are routed here by
/// the validator, so the empty set is never resolved against).
pub fn binarySigs(op: Ast.BinaryOp) []const Sig {
    return switch (op) {
        .logical_and, .logical_or => &logical_sigs,
        .@"and", .@"or", .xor => &bitwise_sigs,
        .shl, .shr => &shift_sigs,
        .lt, .le, .gt, .ge => &comparison_sigs,
        .eq, .ne => &equality_sigs,
        .add, .sub => &addsub_sigs,
        .div => &div_sigs,
        else => &.{},
    };
}
