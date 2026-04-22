//! Cache coverage for `AnalysisResult.expr_types` — every expression kind
//! that carries a stable `loc` should land in the cache so LSP hover and
//! future type-aware passes can query any sub-expression without hitting
//! misses on `literal`, `ident`, or `unary` nodes.
//!
//! Paren expressions intentionally *don't* register their own key — the
//! inner expression already does — so a `(x)` hover resolves to `x`.

const std = @import("std");
const wgslender = @import("wgslender");

fn analyze(src: [:0]const u8) !wgslender.Validator.AnalysisResult {
    return wgslender.analyzeWithOptions(std.testing.allocator, src, .{});
}

fn lookup(r: *const wgslender.Validator.AnalysisResult, loc: u32) ?wgslender.Validator.ExprTypeInfo {
    return r.expr_types.get(loc);
}

fn offsetOf(src: []const u8, needle: []const u8) ?u32 {
    const idx = std.mem.indexOf(u8, src, needle) orelse return null;
    return @intCast(idx);
}

test "literal, ident, binary, unary, call, index, member all land in expr_types" {
    const src =
        \\fn f() {
        \\    var a: array<i32, 4>;
        \\    var v: vec3<f32>;
        \\    let x = -1 + 2;
        \\    let y = a[0];
        \\    let z = v.x;
        \\    let w = min(1, 2);
        \\}
    ;
    var r = try analyze(src);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r.valid);

    // Literal `2` — at the source offset of the byte '2' after the '+'.
    // Use a unique search anchor to pin its position.
    const lit2_off = offsetOf(src, "+ 2").? + 2;
    try std.testing.expect(lookup(&r, lit2_off) != null);

    // Ident `a` in `a[0]` — starts at the 'a' after `let y = `.
    const ident_a_off = offsetOf(src, "= a[0]").? + 2;
    try std.testing.expect(lookup(&r, ident_a_off) != null);

    // Binary `+` — operator position in `-1 + 2`.
    const plus_off = offsetOf(src, "+ 2").?;
    try std.testing.expect(lookup(&r, plus_off) != null);

    // Unary `-` — operator position in `-1`.
    const neg_off = offsetOf(src, "-1").?;
    try std.testing.expect(lookup(&r, neg_off) != null);

    // Index `[` — open bracket in `a[0]`.
    const idx_off = offsetOf(src, "[0]").?;
    try std.testing.expect(lookup(&r, idx_off) != null);

    // Member `.` — dot in `v.x`.
    const dot_off = offsetOf(src, ".x").?;
    try std.testing.expect(lookup(&r, dot_off) != null);

    // Call `(` — open paren in `min(1, 2)`.
    const call_off = offsetOf(src, "min(").? + 3;
    try std.testing.expect(lookup(&r, call_off) != null);
}

test "paren expression caches the inner expression, not the paren itself" {
    const src = "fn f() { let y = (1 + 2); }";
    var r = try analyze(src);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r.valid);

    // Binary `+` inside the parens is cached at the operator position.
    const plus_off = offsetOf(src, "+ 2").?;
    try std.testing.expect(lookup(&r, plus_off) != null);

    // The outer `(` does NOT have its own entry.
    const paren_off = offsetOf(src, "(1").?;
    try std.testing.expect(lookup(&r, paren_off) == null);
}
