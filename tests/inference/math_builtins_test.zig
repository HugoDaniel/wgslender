//! Math-builtin domain enforcement — WGSL §17.5.
//!
//! Pins that each math builtin accepts only the scalar family its
//! overload set defines:
//!   * Float-only — sin, cos, sqrt, log, pow, … (accepts f16/f32
//!     scalars, float vectors, float matrices for determinant/
//!     transpose, and abstract numerics).
//!   * Integer-only — countOneBits, reverseBits, firstLeadingBit, …
//!     (accepts i32/u32 scalars and vectors).
//!   * Numeric-any — abs, sign, min, max, clamp (accepts either
//!     family).
//!
//! `dot` is deliberately numeric-any per §17.5.15 even though most
//! vector-algebra helpers are float-only.
//!
//! Post-Phase-2 (Task #9): domain enforcement lives in the declarative
//! overload signatures in `Builtins.sig_entries`; the legacy
//! `mathBuiltinDomain` switch has been retired. Rejection errors now
//! read "no matching overload for 'X': argument N has type 'Y'".

const std = @import("std");
const wgslender = @import("wgslender");

fn validate(src: [:0]const u8) !wgslender.Validator.Result {
    return wgslender.validateWithOptions(std.testing.allocator, src, .{});
}

fn hasErrorContaining(r: wgslender.Validator.Result, needle: []const u8) bool {
    for (r.diagnostics.items()) |d| {
        if (d.severity != .@"error") continue;
        if (std.mem.indexOf(u8, d.message, needle) != null) return true;
    }
    return false;
}

fn anyError(r: wgslender.Validator.Result) bool {
    for (r.diagnostics.items()) |d| {
        if (d.severity == .@"error") return true;
    }
    return false;
}

fn dump(label: []const u8, r: wgslender.Validator.Result) void {
    std.debug.print("\n{s}:\n", .{label});
    for (r.diagnostics.items()) |d| {
        std.debug.print(
            "  [{s}] {s}: {s}\n",
            .{ d.code, d.severity.string(), d.message },
        );
    }
}

fn validMustPass(src: [:0]const u8, label: []const u8) !void {
    var r = try validate(src);
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump(label, r);
        return error.TestUnexpectedResult;
    }
}

fn expectNoMatchingOverload(src: [:0]const u8, label: []const u8) !void {
    var r = try validate(src);
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "no matching overload")) {
        dump(label, r);
        return error.TestUnexpectedResult;
    }
}

// Kept as aliases so every rejection call site stays self-documenting:
// the test name says "float-only" or "int-only", the helper name says the
// same, and the runtime needle is the engine's generic error.
const expectFloatOnlyReject = expectNoMatchingOverload;
const expectIntOnlyReject = expectNoMatchingOverload;

// -------------------------------------------------------------------------
// Float-only unaries — positive cases.
// -------------------------------------------------------------------------

test "§17.5: sin(1.0) valid" {
    try validMustPass("fn f() { let x = sin(1.0); }", "sin(1.0)");
}

test "§17.5: sin(1.0f) valid" {
    try validMustPass("fn f() { let x = sin(1.0f); }", "sin(1.0f)");
}

test "§17.5: sin(vec3f(1.0)) valid (float vector)" {
    try validMustPass("fn f() { let x = sin(vec3f(1.0)); }", "sin(vec3f)");
}

test "§17.5: sqrt(2.0) valid" {
    try validMustPass("fn f() { let x = sqrt(2.0); }", "sqrt");
}

test "§17.5: floor(1.5f) valid" {
    try validMustPass("fn f() { let x = floor(1.5f); }", "floor");
}

test "§17.5: ceil(1.5) valid" {
    try validMustPass("fn f() { let x = ceil(1.5); }", "ceil");
}

test "§17.5: exp(1.0) valid" {
    try validMustPass("fn f() { let x = exp(1.0); }", "exp");
}

test "§17.5: log2(4.0) valid" {
    try validMustPass("fn f() { let x = log2(4.0); }", "log2");
}

test "§17.5: pow(2.0, 3.0) valid" {
    try validMustPass("fn f() { let x = pow(2.0, 3.0); }", "pow");
}

test "§17.5: atan2(1.0, 2.0) valid" {
    try validMustPass("fn f() { let x = atan2(1.0, 2.0); }", "atan2");
}

// -------------------------------------------------------------------------
// Float-only — rejections.
// -------------------------------------------------------------------------

test "§17.5: sin(1u) rejected" {
    try expectFloatOnlyReject("fn f() { let x = sin(1u); }", "sin(1u)");
}

test "§17.5: sin(1i) rejected" {
    try expectFloatOnlyReject("fn f() { let x = sin(1i); }", "sin(1i)");
}

test "§17.5: floor(1u) rejected" {
    try expectFloatOnlyReject("fn f() { let x = floor(1u); }", "floor(1u)");
}

test "§17.5: sqrt(4i) rejected" {
    try expectFloatOnlyReject("fn f() { let x = sqrt(4i); }", "sqrt(4i)");
}

test "§17.5: pow(2u, 3u) rejected" {
    try expectFloatOnlyReject("fn f() { let x = pow(2u, 3u); }", "pow u32");
}

test "§17.5: sin(vec3u(1u)) rejected" {
    try expectFloatOnlyReject("fn f() { let x = sin(vec3u(1u)); }", "sin vec3u");
}

test "§17.5: length(1u) rejected" {
    try expectFloatOnlyReject("fn f() { let x = length(1u); }", "length(1u)");
}

test "§17.5: distance(vec2u(0u,0u), vec2u(1u,1u)) rejected" {
    try expectFloatOnlyReject(
        "fn f() { let x = distance(vec2u(0u, 0u), vec2u(1u, 1u)); }",
        "distance vec2u",
    );
}

test "§17.5: cross(vec3i(0,0,0), vec3i(1,1,1)) rejected" {
    try expectFloatOnlyReject(
        "fn f() { let x = cross(vec3i(0, 0, 0), vec3i(1, 1, 1)); }",
        "cross vec3i",
    );
}

test "§17.5: normalize(vec3u(1u)) rejected" {
    try expectFloatOnlyReject("fn f() { let x = normalize(vec3u(1u)); }", "normalize u");
}

// -------------------------------------------------------------------------
// Matrix-accepting float-only — transpose / determinant positive.
// -------------------------------------------------------------------------

test "§17.5.50: transpose(mat2x2f(...)) valid" {
    try validMustPass(
        "fn f() { let x = transpose(mat2x2f(1.0, 2.0, 3.0, 4.0)); }",
        "transpose mat2x2f",
    );
}

test "§17.5.21: determinant(mat2x2f(...)) valid" {
    try validMustPass(
        "fn f() { let x = determinant(mat2x2f(1.0, 2.0, 3.0, 4.0)); }",
        "determinant mat2x2f",
    );
}

// -------------------------------------------------------------------------
// Integer-only bit-manipulation — positive cases.
// -------------------------------------------------------------------------

test "§17.5.10: countOneBits(1u) valid" {
    try validMustPass("fn f() { let x = countOneBits(1u); }", "countOneBits u32");
}

test "§17.5.11: countTrailingZeros(1i) valid" {
    try validMustPass("fn f() { let x = countTrailingZeros(1i); }", "countTrailingZeros i32");
}

test "§17.5.41: reverseBits(vec2u(1u,2u)) valid" {
    try validMustPass("fn f() { let x = reverseBits(vec2u(1u, 2u)); }", "reverseBits vec2u");
}

test "§17.5.23: firstLeadingBit(vec4i(1,2,3,4)) valid" {
    try validMustPass(
        "fn f() { let x = firstLeadingBit(vec4i(1, 2, 3, 4)); }",
        "firstLeadingBit vec4i",
    );
}

// -------------------------------------------------------------------------
// Integer-only — rejections.
// -------------------------------------------------------------------------

test "§17.5.10: countOneBits(1.0f) rejected" {
    try expectIntOnlyReject("fn f() { let x = countOneBits(1.0f); }", "countOneBits f32");
}

test "§17.5.11: countTrailingZeros(1.5) rejected" {
    try expectIntOnlyReject(
        "fn f() { let x = countTrailingZeros(1.5); }",
        "countTrailingZeros abstract-float",
    );
}

test "§17.5.41: reverseBits(vec2f(1.0, 2.0)) rejected" {
    try expectIntOnlyReject(
        "fn f() { let x = reverseBits(vec2f(1.0, 2.0)); }",
        "reverseBits vec2f",
    );
}

// -------------------------------------------------------------------------
// Numeric-any — abs / sign / min / max / clamp work on either.
// -------------------------------------------------------------------------

test "§17.5.1: abs(1i) valid" {
    try validMustPass("fn f() { let x = abs(1i); }", "abs i32");
}

test "§17.5.1: abs(1u) valid" {
    try validMustPass("fn f() { let x = abs(1u); }", "abs u32");
}

test "§17.5.1: abs(1.0) valid" {
    try validMustPass("fn f() { let x = abs(1.0); }", "abs abstract-float");
}

test "§17.5.1: abs(vec3i(-1,0,1)) valid" {
    try validMustPass("fn f() { let x = abs(vec3i(-1, 0, 1)); }", "abs vec3i");
}

test "§17.5.43: sign(-1i) valid" {
    try validMustPass("fn f() { let x = sign(-1i); }", "sign i32");
}

test "§17.5.33: min(1u, 2u) valid (same_as_arg numeric)" {
    try validMustPass("fn f() { let x = min(1u, 2u); }", "min u32");
}

test "§17.5.33: min(5, 0u) valid (abstract → u32)" {
    try validMustPass("fn f() { let x = min(5, 0u); }", "min mixed");
}

test "§17.5.33: max(1i, 2i) valid" {
    try validMustPass("fn f() { let x = max(1i, 2i); }", "max i32");
}

test "§17.5.12: clamp(5, 0, 10) valid (all abstract-int)" {
    try validMustPass("fn f() { let x = clamp(5, 0, 10); }", "clamp abstract");
}

test "§17.5.12: clamp(vec3f(0.5), vec3f(0.0), vec3f(1.0)) valid" {
    try validMustPass(
        "fn f() { let x = clamp(vec3f(0.5), vec3f(0.0), vec3f(1.0)); }",
        "clamp vec3f",
    );
}

// -------------------------------------------------------------------------
// Numeric-any — reject bool.
// -------------------------------------------------------------------------

test "§17.5.1: abs(true) rejected (not numeric)" {
    var r = try validate("fn f() { let x = abs(true); }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "no matching overload")) {
        dump("expected numeric error on abs(true)", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.5.33: min(true, false) rejected" {
    var r = try validate("fn f() { let x = min(true, false); }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "no matching overload")) {
        dump("expected numeric error on min(bool)", r);
        return error.TestUnexpectedResult;
    }
}

// -------------------------------------------------------------------------
// dot is numeric-any per §17.5.15 — explicit positive cases.
// -------------------------------------------------------------------------

test "§17.5.15: dot(vec3u(1u), vec3u(1u)) valid" {
    try validMustPass(
        "fn f() { let x = dot(vec3u(1u, 2u, 3u), vec3u(1u, 2u, 3u)); }",
        "dot vec3u",
    );
}

test "§17.5.15: dot(vec3i, vec3i) valid" {
    try validMustPass(
        "fn f() { let x = dot(vec3i(1, 2, 3), vec3i(1, 2, 3)); }",
        "dot vec3i",
    );
}

test "§17.5.15: dot(vec3f, vec3f) valid" {
    try validMustPass(
        "fn f() { let x = dot(vec3f(1.0), vec3f(2.0)); }",
        "dot vec3f",
    );
}

// -------------------------------------------------------------------------
// Abstract-numeric inputs are still accepted.
// -------------------------------------------------------------------------

test "§17.5: sin(1) valid (AbstractInt → AbstractFloat → f32)" {
    // With our current tree-shape propagation the abstract-int concretizes
    // to f32 at the argument site (since sin is float-only).
    try validMustPass("fn f() { let x = sin(1); }", "sin abstract-int");
}

test "§17.5: sqrt(4) valid" {
    try validMustPass("fn f() { let x = sqrt(4); }", "sqrt abstract-int");
}

test "§17.5: pow(2, 3) valid (both abstract-int → AbstractFloat)" {
    try validMustPass("fn f() { let x = pow(2, 3); }", "pow abstract-int");
}

test "§17.5: abs(1) valid (numeric-any)" {
    try validMustPass("fn f() { let x = abs(1); }", "abs abstract-int");
}

test "§17.5: countOneBits(1) valid (abstract-int concretizes to i32)" {
    try validMustPass("fn f() { let x = countOneBits(1); }", "countOneBits abstract-int");
}

// -------------------------------------------------------------------------
// Lexer / parser fix: `1.f`, `2.h`, `3.` literals parsed correctly.
// These regressed previously because scanNumberText didn't match the
// lexer's decision for the `digit . suffix` shape.
// -------------------------------------------------------------------------

test "lit: 1.f is f32 (parser scanNumberText fix)" {
    try validMustPass(
        \\fn f() {
        \\  let x = 1.f;
        \\  let r: f32 = x;
        \\}
    , "1.f");
}

test "lit: 2. is abstract-float" {
    try validMustPass(
        \\fn f() {
        \\  let x = 2.;
        \\  let r: f32 = x;
        \\}
    , "2.");
}

test "lit: pow(1.f, 2.f) valid" {
    try validMustPass("fn f() { let x = pow(1.f, 2.f); }", "pow(1.f, 2.f)");
}
