//! Cross-argument consistency for "all args share type" builtins — §17.5.
//!
//! WGSL does not define implicit conversions between signed and unsigned
//! integers, so `min(1i, 2u)` has no matching overload. Builtins whose
//! later arguments *legitimately* diverge in type (refract's scalar eta,
//! select's bool condition, ldexp's i32 exponent, mix's scalar blend) are
//! intentionally excluded.
//!
//! This file pins both halves:
//!   • positive cases: abstract widens, matching concrete scalars, vector
//!     matching, and the scalar-trail exceptions.
//!   • negative cases: mixed sign rejection across min/max/clamp/step/
//!     pow/atan2/smoothstep/fma/faceForward.

const std = @import("std");
const wgslender = @import("wgslender");

fn validate(src: [:0]const u8) !wgslender.Validator.Result {
    return wgslender.validateWithOptions(std.testing.allocator, src, .{});
}

fn anyError(r: wgslender.Validator.Result) bool {
    for (r.diagnostics.items()) |d| {
        if (d.severity == .@"error") return true;
    }
    return false;
}

fn hasErrorContaining(r: wgslender.Validator.Result, needle: []const u8) bool {
    for (r.diagnostics.items()) |d| {
        if (d.severity != .@"error") continue;
        if (std.mem.indexOf(u8, d.message, needle) != null) return true;
    }
    return false;
}

fn dump(label: []const u8, r: wgslender.Validator.Result) void {
    std.debug.print("\n{s}:\n", .{label});
    for (r.diagnostics.items()) |d| {
        std.debug.print("  [{s}] {s}: {s}\n", .{ d.code, d.severity.string(), d.message });
    }
}

// =========================================================================
// Negatives — mixed signed/unsigned integers have no shared overload
// =========================================================================

test "§17.5: min(i32, u32) rejected — no common type" {
    var r = try validate("fn f() { let x = min(1i, 2u); }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "no matching overload for 'min'")) {
        dump("expected min(i32,u32) rejection", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.5: max(i32, u32) rejected" {
    var r = try validate("fn f() { let x = max(1i, 2u); }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "no matching overload for 'max'")) {
        dump("expected max(i32,u32) rejection", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.5: clamp(i32, u32, i32) rejected — middle arg mismatch" {
    var r = try validate("fn f() { let x = clamp(1i, 0u, 5i); }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "no matching overload for 'clamp'")) {
        dump("expected clamp rejection", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.5: step(f32, i32) rejected — float vs int" {
    var r = try validate("fn f() { let x = step(1.0f, 2i); }");
    defer r.deinit(std.testing.allocator);
    if (!anyError(r)) {
        dump("expected step(f32,i32) rejection", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.5: pow(f32, i32) rejected" {
    var r = try validate("fn f() { let x = pow(2.0f, 3i); }");
    defer r.deinit(std.testing.allocator);
    if (!anyError(r)) {
        dump("expected pow(f32,i32) rejection", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.5: atan2(f32, i32) rejected" {
    var r = try validate("fn f() { let x = atan2(1.0f, 2i); }");
    defer r.deinit(std.testing.allocator);
    if (!anyError(r)) {
        dump("expected atan2(f32,i32) rejection", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.5: smoothstep(f32, f32, i32) rejected" {
    var r = try validate("fn f() { let x = smoothstep(0.0f, 1.0f, 5i); }");
    defer r.deinit(std.testing.allocator);
    if (!anyError(r)) {
        dump("expected smoothstep last-arg rejection", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.5: fma(f32, i32, f32) rejected" {
    var r = try validate("fn f() { let x = fma(1.0f, 2i, 3.0f); }");
    defer r.deinit(std.testing.allocator);
    if (!anyError(r)) {
        dump("expected fma second-arg rejection", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.5: min(vec3<i32>, vec3<u32>) rejected" {
    var r = try validate(
        \\fn f() { let x = min(vec3<i32>(1), vec3<u32>(2u)); }
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "no matching overload for 'min'")) {
        dump("expected vec3<i32> vs vec3<u32> rejection", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.5: max(f32, u32) rejected" {
    var r = try validate("fn f() { let x = max(1.0f, 2u); }");
    defer r.deinit(std.testing.allocator);
    if (!anyError(r)) {
        dump("expected max(f32,u32) rejection", r);
        return error.TestUnexpectedResult;
    }
}

// =========================================================================
// Positives — abstract widens, matching concrete, matching vectors
// =========================================================================

test "§17.5: min(i32, abstract) valid (abstract widens to i32)" {
    var r = try validate("fn f() { let x = min(1i, 2); }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("min(i32, abstract) should be valid", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.5: min(u32, abstract) valid" {
    var r = try validate("fn f() { let x = min(1u, 2); }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("min(u32, abstract) should be valid", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.5: min(abstract, abstract) valid" {
    var r = try validate("fn f() { let x = min(1, 2); }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("min(abstract, abstract) should be valid", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.5: min(vec2<f32>, vec2<f32>) valid" {
    var r = try validate("fn f() { let x = min(vec2<f32>(1.0), vec2<f32>(2.0)); }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("min on matching vectors should be valid", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.5: clamp(i32, i32, i32) valid" {
    var r = try validate("fn f() { let x = clamp(1i, 0i, 5i); }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("clamp i32 triple should be valid", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.5: fma(f32, f32, f32) valid" {
    var r = try validate("fn f() { let x = fma(1.0f, 2.0f, 3.0f); }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("fma all-f32 should be valid", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.5: faceForward(vec3f, vec3f, vec3f) valid" {
    var r = try validate(
        \\fn f() { let x = faceForward(vec3f(1.0), vec3f(0.0, 1.0, 0.0), vec3f(0.0, 0.0, 1.0)); }
    );
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("faceForward all-vec3f should be valid", r);
        return error.TestUnexpectedResult;
    }
}

// =========================================================================
// Deliberately excluded: builtins whose later args legitimately diverge
// =========================================================================

test "§17.5: refract(vec3f, vec3f, f32) valid — eta is scalar" {
    var r = try validate(
        \\fn f() { let x = refract(vec3f(1.0), vec3f(0.0, 0.0, 1.0), 1.5f); }
    );
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("refract scalar-eta should be valid", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.5: select(i32, i32, bool) valid — third arg is bool" {
    var r = try validate("fn f() { let x = select(1i, 2i, true); }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("select i32/i32/bool should be valid", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.5: ldexp(f32, i32) valid — second arg is signed int" {
    var r = try validate("fn f() { let x = ldexp(1.0f, 2i); }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("ldexp f32/i32 should be valid", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.5: mix(vec3f, vec3f, f32) valid — scalar blend" {
    var r = try validate(
        \\fn f() { let x = mix(vec3f(0.0), vec3f(1.0), 0.5f); }
    );
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("mix with scalar blend should be valid", r);
        return error.TestUnexpectedResult;
    }
}

// =========================================================================
// select condition — must be bool or vecN<bool>, NOT an arbitrary numeric
// =========================================================================

test "§17.10: select(i32, i32, i32) rejects non-bool condition" {
    var r = try validate("fn f() { let x = select(1i, 2i, 3i); }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "select")) {
        dump("expected select non-bool-cond rejection", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.10: select(f32, f32, f32) rejects non-bool condition" {
    var r = try validate("fn f() { let x = select(1.0f, 2.0f, 0.5f); }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "select")) {
        dump("expected select non-bool-cond rejection on f32", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.10: select(vec3i, vec3i, vec3<i32>) rejects non-bool-vec condition" {
    var r = try validate(
        \\fn f() { let x = select(vec3<i32>(1), vec3<i32>(2), vec3<i32>(0)); }
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "select")) {
        dump("expected select non-bool-vec-cond rejection", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.10: select(i32, i32, true) valid" {
    var r = try validate("fn f() { let x = select(1i, 2i, true); }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("select bool cond should be valid", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.10: select(vec3i, vec3i, vec3<bool>) valid" {
    var r = try validate(
        \\fn f() { let x = select(vec3<i32>(1), vec3<i32>(2), vec3<bool>(true)); }
    );
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("select vec<bool> cond should be valid", r);
        return error.TestUnexpectedResult;
    }
}

// =========================================================================
// all / any — accept bool or vecN<bool> ONLY
// =========================================================================

test "§17.10: all(vec3<i32>) rejected — not a bool vec" {
    var r = try validate("fn f() { let x = all(vec3<i32>(1)); }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "no matching overload for 'all'")) {
        dump("expected all(vec<i32>) rejection", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.10: any(vec3<f32>) rejected" {
    var r = try validate("fn f() { let x = any(vec3<f32>(1.0)); }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "no matching overload for 'any'")) {
        dump("expected any(vec<f32>) rejection", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.10: all(i32) rejected" {
    var r = try validate("fn f() { let x = all(1i); }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "no matching overload for 'all'")) {
        dump("expected all(i32) rejection", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.10: all(true) valid" {
    var r = try validate("fn f() { let x = all(true); }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("all(true) should be valid", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.10: all(vec3<bool>) valid" {
    var r = try validate(
        \\fn f() { let x = all(vec3<bool>(true)); }
    );
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("all(vec3<bool>) should be valid", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.10: any(vec4<bool>) valid" {
    var r = try validate(
        \\fn f() { let x = any(vec4<bool>(false)); }
    );
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("any(vec4<bool>) should be valid", r);
        return error.TestUnexpectedResult;
    }
}
