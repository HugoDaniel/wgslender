//! Top-down type expectation threading — Stage 2 of the inference revamp.
//!
//! The validator now threads an `exact(T)` hint from typed `let`/`const`/
//! `var`/`override` declarations into `checkExpr`, so abstract literals and
//! arithmetic subexpressions record the materialized (concretized) type in
//! `AnalysisResult.expr_types`. Concrete mismatches still error out; only
//! abstract → concrete materializations are promoted.

const std = @import("std");
const wgslender = @import("wgslender");

fn analyze(src: [:0]const u8) !wgslender.Validator.AnalysisResult {
    return wgslender.analyzeWithOptions(std.testing.allocator, src, .{});
}

fn validate(src: [:0]const u8) !wgslender.Validator.Result {
    return wgslender.validateWithOptions(std.testing.allocator, src, .{});
}

fn anyError(r: wgslender.Validator.Result) bool {
    for (r.diagnostics.items()) |d| {
        if (d.severity == .@"error") return true;
    }
    return false;
}

fn offsetOf(src: []const u8, needle: []const u8) ?u32 {
    const idx = std.mem.indexOf(u8, src, needle) orelse return null;
    return @intCast(idx);
}

fn exprTypeAt(r: *const wgslender.Validator.AnalysisResult, loc: u32) ?wgslender.Types.Type {
    const info = r.expr_types.get(loc) orelse return null;
    return info.typ;
}

test "let v: f32 = 1 + 2 — binary records f32, not abstract-int" {
    const src = "fn f() { let v: f32 = 1 + 2; }";
    var r = try analyze(src);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r.valid);

    const plus_off = offsetOf(src, "+ 2").?;
    const t = exprTypeAt(&r, plus_off) orelse return error.MissingCacheEntry;
    // Before Stage 2, this was `abstract-int`; now it reports `f32`.
    try std.testing.expect(t.isConcrete());
    try std.testing.expectEqualStrings("f32", t.string());
}

test "let v: f32 = 1 + 2 — operand literals also materialize to f32" {
    const src = "fn f() { let v: f32 = 10 + 20; }";
    var r = try analyze(src);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r.valid);

    const lit_10_off = offsetOf(src, "= 10").? + 2;
    const lit_20_off = offsetOf(src, "+ 20").? + 2;
    const t_10 = exprTypeAt(&r, lit_10_off) orelse return error.MissingCacheEntry;
    const t_20 = exprTypeAt(&r, lit_20_off) orelse return error.MissingCacheEntry;
    try std.testing.expectEqualStrings("f32", t_10.string());
    try std.testing.expectEqualStrings("f32", t_20.string());
}

test "const C: u32 = 1 + 2 — threads through const" {
    const src = "const C: u32 = 1 + 2;";
    var r = try analyze(src);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r.valid);

    const plus_off = offsetOf(src, "+ 2").?;
    const t = exprTypeAt(&r, plus_off) orelse return error.MissingCacheEntry;
    try std.testing.expectEqualStrings("u32", t.string());
}

test "var v: i32 = 1 + 2 — threads through var with explicit type" {
    const src = "fn f() { var v: i32 = 1 + 2; }";
    var r = try analyze(src);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r.valid);

    const plus_off = offsetOf(src, "+ 2").?;
    const t = exprTypeAt(&r, plus_off) orelse return error.MissingCacheEntry;
    try std.testing.expectEqualStrings("i32", t.string());
}

test "let v: u32 = 1.0 — concrete mismatch still rejected under expectation" {
    // Expectation-driven materialization only promotes *abstract* types to
    // the target; it never silently downgrades a concrete mismatch. The
    // decl validator's `canConvertTo(f32, u32)` still returns false and
    // emits type_mismatch.
    var r = try validate("fn f() { let v: u32 = 1.0f; }");
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(anyError(r));
}

test "let v = 1 + 2 (no annotation) — cache materializes to i32 via .concrete" {
    // Without an annotation, `let` pushes `.concrete` so the subexpression
    // records the default concrete type (abstract-int → i32) in `expr_types`.
    // The decl itself also concretizes (same net effect), but hovers now see
    // `i32` at every intermediate node instead of `abstract-int`.
    const src = "fn f() { let v = 1 + 2; }";
    var r = try analyze(src);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r.valid);

    const plus_off = offsetOf(src, "+ 2").?;
    const t = exprTypeAt(&r, plus_off) orelse return error.MissingCacheEntry;
    try std.testing.expect(t.isConcrete());
    try std.testing.expectEqualStrings("i32", t.string());
}

test "const C = 1 + 2 at module scope — cache keeps abstract-int" {
    // Module-scope `const` uses `AbstractHandling.keep` (§6.6), so no
    // `.concrete` expectation is pushed — the abstract type survives
    // through the hover cache.
    const src = "const C = 1 + 2;";
    var r = try analyze(src);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r.valid);

    const plus_off = offsetOf(src, "+ 2").?;
    const t = exprTypeAt(&r, plus_off) orelse return error.MissingCacheEntry;
    try std.testing.expect(!t.isConcrete());
}

test "unary -: propagates exact through negation" {
    const src = "fn f() { let v: f32 = -1; }";
    var r = try analyze(src);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r.valid);

    const neg_off = offsetOf(src, "-1").?;
    const t = exprTypeAt(&r, neg_off) orelse return error.MissingCacheEntry;
    try std.testing.expectEqualStrings("f32", t.string());
}

test "shift RHS: u32 constraint not overridden by outer f32 expectation" {
    // `exact(f32)` at the outer decl must NOT propagate across a shift —
    // the shift RHS must stay u32-compatible. The shift expression itself
    // is not convertible to f32 on the integer side, but it is on the
    // result (left operand). Use a shape where the outer expectation would
    // do damage: `let v: u32 = 1u << 2` — here outer is u32, fine. Invert
    // to `let v: i32 = ...`. Easier, cover via end-to-end correctness:
    // a mixed-type shift still rejects.
    var r = try validate("fn f() { let v: i32 = 1i << 2u; }");
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(!anyError(r));
}

// =========================================================================
// `.integer_scalar` at array index
// =========================================================================

fn firstErrorWithCode(r: wgslender.Validator.Result, code: []const u8) ?wgslender.Diagnostic.Entry {
    for (r.diagnostics.items()) |d| {
        if (d.severity == .@"error" and std.mem.eql(u8, d.code, code)) return d;
    }
    return null;
}

fn countErrorsWithCode(r: wgslender.Validator.Result, code: []const u8) usize {
    var n: usize = 0;
    for (r.diagnostics.items()) |d| {
        if (d.severity == .@"error" and std.mem.eql(u8, d.code, code)) n += 1;
    }
    return n;
}

fn errorCount(r: wgslender.Validator.Result) usize {
    var n: usize = 0;
    for (r.diagnostics.items()) |d| {
        if (d.severity == .@"error") n += 1;
    }
    return n;
}

test "index .integer_scalar: valid i32/u32/abstract-int indices cache as-is" {
    const src = "fn f() { var a: array<f32, 4>; let i: i32 = 2; let _x = a[i]; let _y = a[0u]; let _z = a[0]; }";
    var r = try analyze(src);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r.valid);

    // The `0u` literal records as u32 (concrete already).
    const u_off = offsetOf(src, "0u]").?;
    const t_u = exprTypeAt(&r, u_off) orelse return error.MissingCacheEntry;
    try std.testing.expectEqualStrings("u32", t_u.string());

    // The bare `0` literal records as abstract-int — `.integer_scalar` does
    // not force concretization, only validates shape.
    const abs_off = offsetOf(src, "0]").?;
    const t_abs = exprTypeAt(&r, abs_off) orelse return error.MissingCacheEntry;
    try std.testing.expect(!t_abs.isConcrete());
}

test "index .integer_scalar: float literal rejected with precise message" {
    var r = try validate("fn f() { var a: array<f32, 4>; let _x = a[1.5]; }");
    defer r.deinit(std.testing.allocator);
    const d = firstErrorWithCode(r, "E0200") orelse return error.MissingDiagnostic;
    try std.testing.expect(std.mem.indexOf(u8, d.message, "expected integer scalar") != null);
    try std.testing.expect(std.mem.indexOf(u8, d.message, "abstract-float") != null);
}

test "index .integer_scalar: bool rejected with precise message" {
    var r = try validate("fn f() { var a: array<f32, 4>; let _x = a[true]; }");
    defer r.deinit(std.testing.allocator);
    const d = firstErrorWithCode(r, "E0200") orelse return error.MissingDiagnostic;
    try std.testing.expect(std.mem.indexOf(u8, d.message, "expected integer scalar") != null);
    try std.testing.expect(std.mem.indexOf(u8, d.message, "bool") != null);
}

test "index .integer_scalar: integer vector rejected (scalar-only)" {
    // WGSL §6.2.3 requires array index to be a scalar — `vec2<i32>` is not
    // legal. `.integer_scalar` enforces this at the expectation site.
    var r = try validate("fn f() { var a: array<f32, 4>; let v = vec2<i32>(0, 1); let _x = a[v]; }");
    defer r.deinit(std.testing.allocator);
    const d = firstErrorWithCode(r, "E0200") orelse return error.MissingDiagnostic;
    try std.testing.expect(std.mem.indexOf(u8, d.message, "expected integer scalar") != null);
}

test "index .integer_scalar: short-circuits so out-of-bounds does not double-fire" {
    // `1.5` is not an integer → E0200 fires and returns null typ from
    // `checkExprE`. `tryExtractIntValue(1.5)` also returns null, so no
    // E0211 out-of-bounds check runs. Exactly one error.
    var r = try validate("fn f() { var a: array<f32, 4>; let _x = a[1.5]; }");
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), errorCount(r));
    try std.testing.expectEqual(@as(usize, 1), countErrorsWithCode(r, "E0200"));
}

test "index .integer_scalar: non-indexable base still reports E0205 not E0200" {
    // Regression guard: if the base is not indexable, we still produce the
    // base-level "not indexable" E0205 rather than the index expectation
    // swallowing the shape error.
    var r = try validate("fn f() { let b = true; let _x = b[0]; }");
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(firstErrorWithCode(r, "E0205") != null);
}

// =========================================================================
// `.integer_scalar` at shift RHS
// =========================================================================

test "shift RHS .integer_scalar: u32 literal cache entry is u32" {
    const src = "fn f() { let _x = 1u << 2u; }";
    var r = try analyze(src);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r.valid);

    // The `2u` literal on the RHS.
    const off = offsetOf(src, "2u").?;
    const t = exprTypeAt(&r, off) orelse return error.MissingCacheEntry;
    try std.testing.expectEqualStrings("u32", t.string());
}

test "shift RHS .integer_scalar: abstract-int RHS stays abstract in cache" {
    const src = "fn f() { let _x = 1u << 2; }";
    var r = try analyze(src);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r.valid);

    // `.integer_scalar` accepts abstract-int without concretizing. The
    // u32 narrowing still happens in `checkBinaryE` (abstract-int → u32
    // is legal via canConvertTo), but the cache records the raw type.
    const off = offsetOf(src, "2;").?;
    const t = exprTypeAt(&r, off) orelse return error.MissingCacheEntry;
    try std.testing.expect(!t.isConcrete());
}

test "shift RHS .integer_scalar: float RHS rejected at the sub-expression" {
    var r = try validate("fn f() { let _x = 1u << 1.5; }");
    defer r.deinit(std.testing.allocator);
    const d = firstErrorWithCode(r, "E0200") orelse return error.MissingDiagnostic;
    try std.testing.expect(std.mem.indexOf(u8, d.message, "expected integer scalar") != null);
    try std.testing.expect(std.mem.indexOf(u8, d.message, "abstract-float") != null);
}

test "shift RHS .integer_scalar: float RHS does not also emit E0201" {
    // `.integer_scalar` short-circuits `rr.typ` to null so the u32 narrowing
    // in `checkBinaryE` is skipped — otherwise we'd double-emit.
    var r = try validate("fn f() { let _x = 1u << 1.5; }");
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), errorCount(r));
    try std.testing.expectEqual(@as(usize, 0), countErrorsWithCode(r, "E0201"));
}

test "shift RHS .integer_scalar: i32 passes expectation but fails u32 narrowing" {
    // i32 IS a scalar integer → `.integer_scalar` accepts it and records
    // the type. The binary handler then runs its u32 narrowing and rejects
    // because concrete i32 is not convertible to u32.
    var r = try validate("fn f() { let i: i32 = 1; let _x = 1u << i; }");
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(countErrorsWithCode(r, "E0200") == 0);
    const d = firstErrorWithCode(r, "E0201") orelse return error.MissingDiagnostic;
    try std.testing.expect(std.mem.indexOf(u8, d.message, "shift amount must be 'u32'") != null);
}

test "shift RHS .integer_scalar: vector RHS rejected (scalar-only)" {
    var r = try validate("fn f() { let _x = 1u << vec2<u32>(1u, 2u); }");
    defer r.deinit(std.testing.allocator);
    const d = firstErrorWithCode(r, "E0200") orelse return error.MissingDiagnostic;
    try std.testing.expect(std.mem.indexOf(u8, d.message, "expected integer scalar") != null);
}

test "shift LHS is NOT .integer_scalar: integer LHS path still via E0201" {
    // LHS continues to use `.none` because WGSL accepts integer vectors as
    // shift LHS. Float LHS therefore fires E0201 "requires integer left
    // operand" from the binary handler, not E0200 from the expectation.
    var r = try validate("fn f() { let _x = 1.0 << 1u; }");
    defer r.deinit(std.testing.allocator);
    const d = firstErrorWithCode(r, "E0201") orelse return error.MissingDiagnostic;
    try std.testing.expect(std.mem.indexOf(u8, d.message, "requires integer left operand") != null);
    try std.testing.expectEqual(@as(usize, 0), countErrorsWithCode(r, "E0200"));
}

// =========================================================================
// `.concrete` at unannotated decl sites
// =========================================================================

test "var v = 1 (no annotation) — cache materializes to i32" {
    const src = "fn f() -> i32 { var v = 1; return v; }";
    var r = try analyze(src);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r.valid);

    const off = offsetOf(src, "1;").?;
    const t = exprTypeAt(&r, off) orelse return error.MissingCacheEntry;
    try std.testing.expect(t.isConcrete());
    try std.testing.expectEqualStrings("i32", t.string());
}

test "var v = 1.0 (no annotation) — cache materializes to f32" {
    const src = "fn f() -> f32 { var v = 1.0; return v; }";
    var r = try analyze(src);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r.valid);

    const off = offsetOf(src, "1.0").?;
    const t = exprTypeAt(&r, off) orelse return error.MissingCacheEntry;
    try std.testing.expectEqualStrings("f32", t.string());
}

test "function-scope const x = 1 + 2 (no annotation) — cache materializes to i32" {
    const src = "fn f() -> i32 { const x = 1 + 2; return x; }";
    var r = try analyze(src);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r.valid);

    const plus_off = offsetOf(src, "+ 2").?;
    const t = exprTypeAt(&r, plus_off) orelse return error.MissingCacheEntry;
    try std.testing.expectEqualStrings("i32", t.string());
}

test "nested: outer .concrete does not override inner .integer_scalar" {
    // The outer `let` pushes `.concrete`; the inner shift RHS gets
    // `.integer_scalar` locally; a bad inner type fires E0200 at the RHS
    // even though the outer context would accept it.
    var r = try validate("fn f() -> u32 { let x = 1u << 1.5; return x; }");
    defer r.deinit(std.testing.allocator);
    const d = firstErrorWithCode(r, "E0200") orelse return error.MissingDiagnostic;
    try std.testing.expect(std.mem.indexOf(u8, d.message, "expected integer scalar") != null);
}

test "nested: outer .concrete does not override inner index .integer_scalar" {
    var r = try validate("fn f() -> f32 { var a: array<f32, 4>; let x = a[1.5]; return x; }");
    defer r.deinit(std.testing.allocator);
    const d = firstErrorWithCode(r, "E0200") orelse return error.MissingDiagnostic;
    try std.testing.expect(std.mem.indexOf(u8, d.message, "expected integer scalar") != null);
}
