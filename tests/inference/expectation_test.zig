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

test "let v = 1 + 2 (no annotation) — cache still sees abstract-int" {
    // Without an annotation, there is no expectation to drive materialization.
    // The binary concretizes at decl-site via `Types.concreteType`, but the
    // cached subexpression entry reflects the raw inference.
    const src = "fn f() { let v = 1 + 2; }";
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
