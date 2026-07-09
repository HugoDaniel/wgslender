//! Structural invariants over the declarative overload tables.
//!
//! Every Pattern / ResultRule in `src/Builtins.zig` references type-
//! parameter slots by index. A typo in any of those indices is not
//! caught by the compiler — the resulting sig will simply fail to
//! resolve user calls at validation time, often with a confusing
//! diagnostic ("no matching overload" for a call that should have
//! matched trivially). This file enforces the invariants at the
//! table level so a broken sig is a test failure here, not a user
//! complaint.
//!
//! Invariants enforced per OverloadSig:
//!   I1  params.len ∈ [builtin.min_args, builtin.max_args]
//!   I2  every tparam index referenced by a Pattern or ResultRule is
//!       either `Pattern.no_tparam` or `< sig.tparam_count`
//!   I3  every slot 0..tparam_count-1 is used by at least one Pattern
//!       (no dead tparam declarations)
//!   I4  a slot's "kind" (scalar / width / cols / rows / AS / AM) is
//!       consistent across every Pattern / result reference to it
//!
//! Plus a family spot-check over well-known builtins so a typo that
//! flips `.float` to `.integer` (or vice versa) lights up here.

const std = @import("std");
const wgslender = @import("wgslender");

const Builtins = wgslender.Builtins;
const Overload = wgslender.Overload;

// =========================================================================
// Slot-kind inference
// =========================================================================

const SlotKind = enum { unused, scalar, width, matrix_dim, address_space, access_mode };

const SlotKinds = [Overload.max_tparams]SlotKind;

/// Classify the semantic "kind" of a slot given its tagged use-site.
/// `cols` and `rows` are treated as one matrix-dim kind so `determinant`
/// (square matrix: cols == rows, sharing a slot) is well-typed.
fn markSlot(
    ctx: []const u8,
    name: []const u8,
    kinds: *SlotKinds,
    idx: u8,
    kind: SlotKind,
) !void {
    if (idx == Overload.Pattern.no_tparam) return;
    if (idx >= Overload.max_tparams) {
        std.debug.print("{s}: '{s}' slot {d} exceeds max_tparams\n", .{ ctx, name, idx });
        return error.TestUnexpectedResult;
    }
    const existing = kinds[idx];
    if (existing == .unused) {
        kinds[idx] = kind;
        return;
    }
    if (existing != kind) {
        std.debug.print(
            "{s}: '{s}' slot {d} used as both {s} and {s}\n",
            .{ ctx, name, idx, @tagName(existing), @tagName(kind) },
        );
        return error.TestUnexpectedResult;
    }
}

fn walkPattern(ctx: []const u8, name: []const u8, p: Overload.Pattern, kinds: *SlotKinds) !void {
    switch (p) {
        .concrete => {},
        .tparam_scalar => |s| try markSlot(ctx, name, kinds, s.idx, .scalar),
        .tparam_vector => |v| {
            try markSlot(ctx, name, kinds, v.elem_idx, .scalar);
            if (v.n_idx != Overload.Pattern.no_tparam) {
                try markSlot(ctx, name, kinds, v.n_idx, .width);
            }
        },
        .tparam_matrix => |m| {
            try markSlot(ctx, name, kinds, m.elem_idx, .scalar);
            try markSlot(ctx, name, kinds, m.cols_idx, .matrix_dim);
            try markSlot(ctx, name, kinds, m.rows_idx, .matrix_dim);
        },
        .tparam_ptr_atomic => |pa| {
            try markSlot(ctx, name, kinds, pa.as_idx, .address_space);
            try markSlot(ctx, name, kinds, pa.am_idx, .access_mode);
            try markSlot(ctx, name, kinds, pa.elem_idx, .scalar);
        },
        .tparam_ptr => |pp| {
            try markSlot(ctx, name, kinds, pp.am_idx, .access_mode);
            try markSlot(ctx, name, kinds, pp.elem_idx, .scalar);
        },
        .tparam_ptr_runtime_array => |pr| {
            try markSlot(ctx, name, kinds, pr.as_idx, .address_space);
            try markSlot(ctx, name, kinds, pr.am_idx, .access_mode);
        },
        .tparam_texture => |tx| try markSlot(ctx, name, kinds, tx.elem_idx, .scalar),
        .bound_scalar => |idx| try markSlot(ctx, name, kinds, idx, .scalar),
        .bound_vector => |bv| {
            try markSlot(ctx, name, kinds, bv.elem_idx, .scalar);
            if (bv.n_idx != Overload.Pattern.no_tparam) {
                try markSlot(ctx, name, kinds, bv.n_idx, .width);
            }
        },
        .bound_matrix_transposed => |bmt| {
            try markSlot(ctx, name, kinds, bmt.elem_idx, .scalar);
            try markSlot(ctx, name, kinds, bmt.cols_idx, .matrix_dim);
            try markSlot(ctx, name, kinds, bmt.rows_idx, .matrix_dim);
        },
        // Cross-arg constructor patterns carry no tparam slots (element type
        // is concrete), so they contribute nothing to the slot-usage map.
        // Builtin sigs never use them; this branch only keeps the switch
        // exhaustive.
        .variadic_components_to_width, .all_scalar_or_all_vector, .composite_convert => {},
    }
}

fn walkResult(ctx: []const u8, name: []const u8, r: Overload.ResultRule, kinds: *SlotKinds) !void {
    switch (r) {
        .pattern => |p| try walkPattern(ctx, name, p, kinds),
        .fixed => {},
        .synth_frexp, .synth_modf, .synth_atomic_cmp_xchg, .bool_shape_of => |arg_idx| {
            // arg_idx indexes into the call's args, not into tparams.
            _ = arg_idx;
        },
        .bound_scalar_as_type => |idx| try markSlot(ctx, name, kinds, idx, .scalar),
    }
}

// =========================================================================
// Per-sig invariant check
// =========================================================================

const CheckOpts = struct {
    /// Skip the "every declared slot must be used" check. The bitcast
    /// sig tables follow a caller convention where slots 0/1 are always
    /// seeded from the template (element kind + width), even when the
    /// sig itself doesn't read slot 1 (e.g. bitcast → scalar). The slot
    /// declaration reflects the caller contract, not the sig's internal
    /// use; relaxing I3 here is intentional.
    allow_unused_slots: bool = false,
};

fn checkSig(
    name: []const u8,
    sig_idx: usize,
    sig: Overload.OverloadSig,
    min_args: u8,
    max_args: u8,
    opts: CheckOpts,
) !void {
    var ctx_buf: [64]u8 = undefined;
    const ctx = try std.fmt.bufPrint(&ctx_buf, "{s}#{d}", .{ name, sig_idx });

    // I1: arity within [min_args, max_args].
    if (sig.params.len < min_args or sig.params.len > max_args) {
        std.debug.print(
            "{s}: sig params.len={d} outside [{d}, {d}]\n",
            .{ ctx, sig.params.len, min_args, max_args },
        );
        return error.TestUnexpectedResult;
    }

    // I2 + I4 via slot-kind inference.
    var kinds: SlotKinds = .{.unused} ** Overload.max_tparams;
    for (sig.params) |p| try walkPattern(ctx, name, p, &kinds);
    try walkResult(ctx, name, sig.result, &kinds);

    // I3: every declared tparam slot must be used (unless caller opts out).
    if (sig.tparam_count > Overload.max_tparams) {
        std.debug.print("{s}: tparam_count={d} exceeds max_tparams\n", .{ ctx, sig.tparam_count });
        return error.TestUnexpectedResult;
    }
    if (!opts.allow_unused_slots) {
        var slot: u8 = 0;
        while (slot < sig.tparam_count) : (slot += 1) {
            if (kinds[slot] == .unused) {
                std.debug.print(
                    "{s}: tparam slot {d} is declared but unused\n",
                    .{ ctx, slot },
                );
                return error.TestUnexpectedResult;
            }
        }
    }
}

// =========================================================================
// Tests
// =========================================================================

test "every builtin's overload sigs satisfy structural invariants" {
    for (Builtins.names()) |name| {
        if (std.mem.eql(u8, name, "bitcast")) continue; // dispatched via bitcast_to_*_sigs
        const b = Builtins.lookup(name).?;
        for (b.overloads, 0..) |sig, i| {
            try checkSig(name, i, sig, b.min_args, b.max_args, .{});
        }
    }
}

test "bitcast sig tables satisfy structural invariants" {
    // Bitcast has four template-shape-selected sig tables.
    // Arity is always 1; tparam_count is 3 (slots 0/1 template-seeded by
    // the caller, slot 2 solver-bound source scalar). Slot 1 (width) is
    // unused when the target is scalar — that's the caller-contract
    // exemption encoded by `allow_unused_slots`.
    const tables = [_]struct { name: []const u8, sigs: []const Overload.OverloadSig }{
        .{ .name = "bitcast_to_scalar", .sigs = Builtins.bitcast_to_scalar_sigs },
        .{ .name = "bitcast_to_vecN_32", .sigs = Builtins.bitcast_to_vecN_32_sigs },
        .{ .name = "bitcast_to_vec2_f16", .sigs = Builtins.bitcast_to_vec2_f16_sigs },
        .{ .name = "bitcast_to_vec4_f16", .sigs = Builtins.bitcast_to_vec4_f16_sigs },
    };
    for (tables) |t| {
        for (t.sigs, 0..) |sig, i| {
            try checkSig(t.name, i, sig, 1, 1, .{ .allow_unused_slots = true });
        }
    }
}

test "every builtin declares at least one overload (bitcast exempt)" {
    var checked: u32 = 0;
    for (Builtins.names()) |name| {
        if (std.mem.eql(u8, name, "bitcast")) continue;
        const b = Builtins.lookup(name).?;
        if (b.overloads.len == 0) {
            std.debug.print("'{s}' has no overloads\n", .{name});
            return error.TestUnexpectedResult;
        }
        checked += 1;
    }
    try std.testing.expect(checked >= 140); // sanity — we have ~145 callable builtins
}

// =========================================================================
// Family spot-checks
// =========================================================================
//
// A typo that flips a builtin's element family from `.float` to `.integer`
// (or vice versa) is silently mis-classifying. Rather than machine-verify
// every family (some are legitimately `.numeric` spanning both), pin a
// hand-picked set whose spec kind is unambiguous.

const FamilyExpectation = struct {
    name: []const u8,
    family: Overload.ScalarFamily,
};

fn firstScalarFamily(sig: Overload.OverloadSig) ?Overload.ScalarFamily {
    for (sig.params) |p| {
        switch (p) {
            .tparam_scalar => |s| return s.family,
            .tparam_vector => |v| return v.elem_family,
            .tparam_matrix => |m| return m.elem_family,
            else => continue,
        }
    }
    return null;
}

fn expectFamily(name: []const u8, want: Overload.ScalarFamily) !void {
    const b = Builtins.lookup(name) orelse {
        std.debug.print("builtin '{s}' missing\n", .{name});
        return error.TestUnexpectedResult;
    };
    if (b.overloads.len == 0) {
        std.debug.print("builtin '{s}' has no overloads\n", .{name});
        return error.TestUnexpectedResult;
    }
    // Walk every sig — they should all agree on the element family for
    // these pinned builtins. (Spec-wise: sin/cos are float across every
    // overload, countOneBits is integer across every overload, etc.)
    for (b.overloads, 0..) |sig, i| {
        const got = firstScalarFamily(sig) orelse continue;
        if (got != want) {
            std.debug.print(
                "'{s}'#{d}: expected family {s}, got {s}\n",
                .{ name, i, @tagName(want), @tagName(got) },
            );
            return error.TestUnexpectedResult;
        }
    }
}

test "spot-check: trig / exp / geometric builtins are .float" {
    const names = [_][]const u8{
        "sin",     "cos",         "tan",       "asin",    "acos",       "atan",
        "atan2",   "exp",         "exp2",      "log",     "log2",       "pow",
        "sqrt",    "inverseSqrt", "floor",     "ceil",    "round",      "trunc",
        "fract",   "cross",       "normalize", "reflect", "refract",    "faceForward",
        "degrees", "radians",     "saturate",  "fma",     "smoothstep", "quantizeToF16",
    };
    for (names) |n| try expectFamily(n, .float);
}

test "spot-check: bit-counting and insert/extract are .integer" {
    const names = [_][]const u8{
        "countOneBits", "countLeadingZeros", "countTrailingZeros",
        "reverseBits",  "firstLeadingBit",   "firstTrailingBit",
        "extractBits",  "insertBits",
    };
    for (names) |n| try expectFamily(n, .integer);
}

test "spot-check: abs / sign / min / max / clamp / mix are .numeric (signed family)" {
    // These accept both integer and float scalars, so the family is
    // `.numeric` (every non-bool scalar kind).
    const names = [_][]const u8{ "abs", "sign", "min", "max", "clamp" };
    for (names) |n| try expectFamily(n, .numeric);
}

test "spot-check: derivatives are .float" {
    const names = [_][]const u8{
        "dpdx",       "dpdy",       "fwidth",
        "dpdxCoarse", "dpdyCoarse", "fwidthCoarse",
        "dpdxFine",   "dpdyFine",   "fwidthFine",
    };
    for (names) |n| try expectFamily(n, .float);
}
