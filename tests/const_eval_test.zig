//! Characterization pins for the two const-expression evaluators that
//! `docs/deferred/consteval-extraction.md` unifies into `src/ConstEval.zig`.
//!
//! These lock TODAY's *divergent* semantics through the public API surfaces
//! (`analyze` → `const_values`, `reflect` → array `element_count`) so the
//! extraction (Blocks C1/C2) can be proven byte-identical:
//!
//!   * Validator side (`tryExtractIntValue` family): **saturating** integer
//!     arithmetic, an int-only domain (no `.call`/float folding), and a depth
//!     cap of 32.
//!   * Reflect side (`LayoutComputer.evalConst`): **wrapping** integer
//!     arithmetic, a full `{int,float,bool}` domain, and a depth cap of 64.
//!
//! The wrap-vs-saturate contrast lives *only* here; the member-access and
//! memoized-chain reflect paths are already densely pinned in
//! `tests/reflect_test.zig` ("const member access on struct constructor",
//! "const chain unlocks runtime-sized recovery") and are referenced, not
//! duplicated.

const std = @import("std");
const wgslender = @import("wgslender");

// =========================================================================
// Observation helpers (public-surface only)
// =========================================================================

/// The folded integer value the Validator recorded for the module-scope
/// `const` named `name`, or null when the validator did not fold it (the
/// initializer is not int-reducible, or the symbol is not a `const`).
fn validatorConstValue(result: *const wgslender.Validator.AnalysisResult, name: []const u8) ?i64 {
    const module = result.module orelse return null;
    for (module.symbols.items, 0..) |sym, idx| {
        if (sym.kind == .@"const" and std.mem.eql(u8, sym.original_name, name)) {
            return result.const_values.get(@intCast(idx));
        }
    }
    return null;
}

/// The array element count the Reflect interpreter resolved for the binding
/// named `binding` (null = runtime-sized / not const-evaluable).
fn reflectArrayCount(result: *const wgslender.Reflect.ReflectResult, binding: []const u8) ?i32 {
    for (result.bindings.items) |*b| {
        if (std.mem.eql(u8, b.name, binding)) {
            const arr = b.array orelse return null;
            return arr.element_count;
        }
    }
    return null;
}

fn hasCode(result: *const wgslender.Validator.AnalysisResult, code: []const u8) bool {
    for (result.diagnostics.items()) |d| {
        if (std.mem.eql(u8, d.code, code)) return true;
    }
    return false;
}

/// `const D = ((((...1...))));` with `depth` parentheses — a chain the parser
/// accepts (limit 256) but whose folding straddles the evaluator's own cap.
fn buildParenConst(arena: std.mem.Allocator, name: []const u8, depth: u32) ![:0]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "const ");
    try buf.appendSlice(arena, name);
    try buf.appendSlice(arena, " = ");
    try buf.appendNTimes(arena, '(', depth);
    try buf.append(arena, '1');
    try buf.appendNTimes(arena, ')', depth);
    try buf.append(arena, ';');
    return buf.toOwnedSliceSentinel(arena, 0);
}

// =========================================================================
// Validator side — saturating, int-only, depth 32
// =========================================================================

test "const_eval[validator]: integer add overflow saturates (not wraps)" {
    const a = std.testing.allocator;
    // i64::MAX + 1. The Validator's extractor uses saturating `+|`, so the
    // folded value clamps to i64::MAX — it does NOT wrap to i64::MIN the way
    // the Reflect interpreter's `+%` would (see the reflect pin below).
    var result = try wgslender.analyzeWithOptions(a, "const N = 9223372036854775807 + 1;", .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(?i64, 9223372036854775807), validatorConstValue(&result, "N"));
}

test "const_eval[validator]: integer multiply overflow saturates" {
    const a = std.testing.allocator;
    var result = try wgslender.analyzeWithOptions(a, "const M = 9223372036854775807 * 2;", .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(?i64, 9223372036854775807), validatorConstValue(&result, "M"));
}

test "const_eval[validator]: negation saturates at i64::MIN" {
    const a = std.testing.allocator;
    // `-(i64::MIN)` cannot be represented; `0 -| val` saturates to i64::MAX.
    var result = try wgslender.analyzeWithOptions(a, "const G = -(-9223372036854775807 - 1);", .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(?i64, 9223372036854775807), validatorConstValue(&result, "G"));
}

test "const_eval[validator]: folds bitwise + shift over const idents" {
    const a = std.testing.allocator;
    const src =
        \\const BASE = 1;
        \\const SHIFTED = BASE << 4;
        \\const MASKED = (SHIFTED | 3) & 255;
    ;
    var result = try wgslender.analyzeWithOptions(a, src, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(?i64, 16), validatorConstValue(&result, "SHIFTED"));
    try std.testing.expectEqual(@as(?i64, 19), validatorConstValue(&result, "MASKED"));
}

test "const_eval[validator]: float-chain const is invisible to the folder" {
    const a = std.testing.allocator;
    // Reflect fully evaluates `u32(sin(radians(90)) + 3)` to 4 (see
    // tests/reflect_test.zig "const float math feeds u32 cast in array
    // size"). The Validator's int-only extractor has no `.call`/float path,
    // so it folds NOTHING here — `const_values` gets no entry for K. This
    // capability gap is deliberate today; ConstEval C3 is where it closes.
    const src =
        \\const K = u32(sin(radians(90)) + 3);
        \\const PLAIN = 4;
    ;
    var result = try wgslender.analyzeWithOptions(a, src, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(?i64, null), validatorConstValue(&result, "K"));
    try std.testing.expectEqual(@as(?i64, 4), validatorConstValue(&result, "PLAIN"));
}

test "const_eval[validator]: folding beyond any cap yields no value" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    // 100 nested parens: parses cleanly (< 256) but exceeds BOTH the current
    // folder cap (32) and its post-ConstEval-C2 successor (64), so this stays
    // unfolded across the whole extraction — a stable "a cap exists" pin.
    const src = try buildParenConst(arena.allocator(), "DEEP", 100);
    var result = try wgslender.analyzeWithOptions(a, src, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(?i64, null), validatorConstValue(&result, "DEEP"));
}

test "const_eval[validator]: depth-cap boundary is 32 (guarded — C2 widens to 64)" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    // 32 parens fold (literal reached at depth 32, `32 > 32` is false);
    // 33 parens do not (depth 33 > 32 → null). ⚠ ConstEval C2 unifies the cap
    // on 64: when it lands, the 33-deep case starts folding to 1 and THIS
    // expectation flips (documented, guarded behavior change).
    const at_cap = try buildParenConst(arena.allocator(), "AT_CAP", 32);
    var r_at = try wgslender.analyzeWithOptions(a, at_cap, .{});
    defer r_at.deinit();
    try std.testing.expectEqual(@as(?i64, 1), validatorConstValue(&r_at, "AT_CAP"));

    const over_cap = try buildParenConst(arena.allocator(), "OVER_CAP", 33);
    var r_over = try wgslender.analyzeWithOptions(a, over_cap, .{});
    defer r_over.deinit();
    try std.testing.expectEqual(@as(?i64, null), validatorConstValue(&r_over, "OVER_CAP"));
}

test "const_eval[validator]: const_assert folds integer comparison — true passes" {
    const a = std.testing.allocator;
    var result = try wgslender.analyzeWithOptions(a, "const_assert(2 + 2 == 4);", .{});
    defer result.deinit();
    try std.testing.expect(result.valid);
    try std.testing.expect(!hasCode(&result, wgslender.Diagnostic.Code.const_assert_failed));
}

test "const_eval[validator]: const_assert folds integer comparison — false fails E0807" {
    const a = std.testing.allocator;
    var result = try wgslender.analyzeWithOptions(a, "const_assert(2 + 2 == 5);", .{});
    defer result.deinit();
    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(&result, wgslender.Diagnostic.Code.const_assert_failed));
}

// =========================================================================
// Reflect side — wrapping, full domain, depth 64
// =========================================================================

test "const_eval[reflect]: integer add overflow wraps to an unknown array size" {
    const a = std.testing.allocator;
    // Same source the validator folds to i64::MAX above, but the Reflect
    // interpreter uses wrapping `+%`: i64::MAX +% 1 = i64::MIN, a negative
    // value that `evaluateConstExpr` maps to -1 → element_count == null.
    var result = try wgslender.reflect(a,
        \\const N = 9223372036854775807 + 1;
        \\@group(0) @binding(0) var<uniform> u: array<f32, N>;
    );
    defer result.deinit(a);
    try std.testing.expectEqual(@as(?i32, null), reflectArrayCount(&result, "u"));
}

test "const_eval[reflect]: full domain folds float chain into an int array size" {
    const a = std.testing.allocator;
    // The capability the validator lacks: `u32(sin(radians(90)) + 3)` → 4.
    // Kept compact here as the counterpart to the validator-invisibility pin;
    // the exhaustive float-chain coverage lives in tests/reflect_test.zig.
    var result = try wgslender.reflect(a,
        \\const K = u32(sin(radians(90)) + 3);
        \\@group(0) @binding(0) var<uniform> u: array<vec4f, K>;
    );
    defer result.deinit(a);
    try std.testing.expectEqual(@as(?i32, 4), reflectArrayCount(&result, "u"));
}
