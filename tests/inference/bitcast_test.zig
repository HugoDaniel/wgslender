//! `bitcast<T>(e)` — WGSL §17.9.5.
//!
//! The spec defines six overload forms over concrete 32-bit numerics
//! and f16 vectors:
//!   1. scalar ↔ scalar (i32 ↔ u32 ↔ f32)
//!   2. vecN<T> ↔ vecN<S> where T,S ∈ {i32,u32,f32}
//!   3. i32/u32/f32 → vec2h
//!   4. vec2h → i32/u32/f32
//!   5. vec2<i32/u32/f32> → vec4h
//!   6. vec4h → vec2<i32/u32/f32>
//! Abstract-numeric inputs concretize automatically before the cast
//! (AbstractInt → i32, AbstractFloat → f32).
//! Bool, pointer, matrix, array, atomic, struct, and handle operands
//! are all rejected.

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

// -------------------------------------------------------------------------
// Form 1 — scalar ↔ scalar.
// -------------------------------------------------------------------------

test "§17.9.5 form 1: bitcast<u32>(1i) valid" {
    var r = try validate("fn f() { let x = bitcast<u32>(1i); }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("expected no error on i32→u32", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.9.5 form 1: bitcast<i32>(1u) valid" {
    var r = try validate("fn f() { let x = bitcast<i32>(1u); }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("expected no error on u32→i32", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.9.5 form 1: bitcast<f32>(1u) valid" {
    var r = try validate("fn f() { let x = bitcast<f32>(1u); }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("expected no error on u32→f32", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.9.5 form 1: bitcast<u32>(1.0f) valid" {
    var r = try validate("fn f() { let x = bitcast<u32>(1.0f); }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("expected no error on f32→u32", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.9.5 form 1: bitcast<i32>(1.0f) valid" {
    var r = try validate("fn f() { let x = bitcast<i32>(1.0f); }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("expected no error on f32→i32", r);
        return error.TestUnexpectedResult;
    }
}

// -------------------------------------------------------------------------
// Abstract-numeric inputs auto-concretize.
// -------------------------------------------------------------------------

test "§17.9.5: bitcast<u32>(1) valid (AbstractInt → i32 → bits → u32)" {
    var r = try validate("fn f() { let x = bitcast<u32>(1); }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("expected no error on bitcast<u32>(1)", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.9.5: bitcast<i32>(1) valid (AbstractInt → i32 identity)" {
    var r = try validate("fn f() { let x = bitcast<i32>(1); }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("expected no error on bitcast<i32>(1)", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.9.5: bitcast<f32>(1) valid (abstract-int → i32 → bits → f32)" {
    var r = try validate("fn f() { let x = bitcast<f32>(1); }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("expected no error on bitcast<f32>(1)", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.9.5: bitcast<u32>(1.5) valid (AbstractFloat → f32 → bits → u32)" {
    var r = try validate("fn f() { let x = bitcast<u32>(1.5); }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("expected no error on bitcast<u32>(1.5)", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.9.5: bitcast<i32>(1.5) valid" {
    var r = try validate("fn f() { let x = bitcast<i32>(1.5); }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("expected no error on bitcast<i32>(1.5)", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.9.5: bitcast<vec2u>(vec2(1, 2)) valid (abstract-int vector)" {
    var r = try validate("fn f() { let x = bitcast<vec2u>(vec2(1, 2)); }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("expected no error on abstract-int vec2 bitcast", r);
        return error.TestUnexpectedResult;
    }
}

// -------------------------------------------------------------------------
// Form 2 — vecN<T> ↔ vecN<S>, same-N same-bits.
// -------------------------------------------------------------------------

test "§17.9.5 form 2: bitcast<vec2u>(vec2i(1, 2)) valid" {
    var r = try validate("fn f() { let x = bitcast<vec2u>(vec2i(1, 2)); }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("expected no error on vec2i→vec2u", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.9.5 form 2: bitcast<vec3f>(vec3u(1u, 2u, 3u)) valid" {
    var r = try validate("fn f() { let x = bitcast<vec3f>(vec3u(1u, 2u, 3u)); }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("expected no error on vec3u→vec3f", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.9.5 form 2: bitcast<vec4i>(vec4f(1.0, 2.0, 3.0, 4.0)) valid" {
    var r = try validate("fn f() { let x = bitcast<vec4i>(vec4f(1.0, 2.0, 3.0, 4.0)); }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("expected no error on vec4f→vec4i", r);
        return error.TestUnexpectedResult;
    }
}

// -------------------------------------------------------------------------
// Form 3/4/5/6 — f16 interop with 32-bit types, via bit-width equality.
// (All gated on `enable f16`.)
// -------------------------------------------------------------------------

test "§17.9.5 form 3: bitcast<vec2h>(1u) valid (32-bit → vec2h)" {
    var r = try validate(
        \\enable f16;
        \\fn f() { let x = bitcast<vec2h>(1u); }
    );
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("expected no error on u32→vec2h", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.9.5 form 3: bitcast<vec2h>(1.0f) valid" {
    var r = try validate(
        \\enable f16;
        \\fn f() { let x = bitcast<vec2h>(1.0f); }
    );
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("expected no error on f32→vec2h", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.9.5 form 4: bitcast<u32>(vec2h(1.0h, 2.0h)) valid" {
    var r = try validate(
        \\enable f16;
        \\fn f() { let x = bitcast<u32>(vec2h(1.0h, 2.0h)); }
    );
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("expected no error on vec2h→u32", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.9.5 form 5: bitcast<vec4h>(vec2u(0u, 0u)) valid" {
    var r = try validate(
        \\enable f16;
        \\fn f() { let x = bitcast<vec4h>(vec2u(0u, 0u)); }
    );
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("expected no error on vec2<u32>→vec4h", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.9.5 form 6: bitcast<vec2u>(vec4h(0h,0h,0h,0h)) valid" {
    var r = try validate(
        \\enable f16;
        \\fn f() { let x = bitcast<vec2u>(vec4h(0h,0h,0h,0h)); }
    );
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("expected no error on vec4h→vec2u", r);
        return error.TestUnexpectedResult;
    }
}

// -------------------------------------------------------------------------
// Non-matching bit-widths — rejected.
// -------------------------------------------------------------------------

test "§17.9.5: bitcast<vec2u>(1u) rejected (32 vs 64 bits)" {
    var r = try validate("fn f() { let x = bitcast<vec2u>(1u); }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "same bit-width")) {
        dump("expected bit-width error on bitcast<vec2u>(1u)", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.9.5: bitcast<u32>(vec2u(1u, 2u)) rejected (64 vs 32 bits)" {
    var r = try validate("fn f() { let x = bitcast<u32>(vec2u(1u, 2u)); }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "same bit-width")) {
        dump("expected bit-width error on bitcast<u32>(vec2u)", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.9.5: bitcast<vec3u>(vec2f(...)) rejected (96 vs 64 bits)" {
    var r = try validate("fn f() { let x = bitcast<vec3u>(vec2f(1.0, 2.0)); }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "same bit-width")) {
        dump("expected bit-width error on vec3u←vec2f", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.9.5: bitcast<vec2h>(vec2u) rejected (32 vs 64 bits)" {
    var r = try validate(
        \\enable f16;
        \\fn f() { let x = bitcast<vec2h>(vec2u(1u, 2u)); }
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "same bit-width")) {
        dump("expected bit-width error on vec2h←vec2u", r);
        return error.TestUnexpectedResult;
    }
}

// -------------------------------------------------------------------------
// Source type domain — reject non-numerics.
// -------------------------------------------------------------------------

test "§17.9.5: bitcast<u32>(true) rejected (bool)" {
    var r = try validate("fn f() { let x = bitcast<u32>(true); }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "cannot bitcast from")) {
        dump("expected 'cannot bitcast from bool' error", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.9.5: bitcast<u32>(vec2<bool>(true,false)) rejected" {
    var r = try validate("fn f() { let x = bitcast<u32>(vec2<bool>(true, false)); }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "cannot bitcast from")) {
        dump("expected bool-vector rejection", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.9.5: bitcast<u32>(&x) rejected (pointer)" {
    var r = try validate(
        \\fn f() {
        \\  var y: i32 = 0;
        \\  let x = bitcast<u32>(&y);
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "cannot bitcast from")) {
        dump("expected pointer rejection", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.9.5: bitcast<u32>(mat2x2f(...)) rejected (matrix)" {
    var r = try validate("fn f() { let x = bitcast<u32>(mat2x2f(1.0, 2.0, 3.0, 4.0)); }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "cannot bitcast from")) {
        dump("expected matrix rejection", r);
        return error.TestUnexpectedResult;
    }
}

// -------------------------------------------------------------------------
// Destination type domain.
// -------------------------------------------------------------------------

test "§17.9.5: bitcast<bool>(1u) rejected (bool destination)" {
    var r = try validate("fn f() { let x = bitcast<bool>(1u); }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "cannot bitcast to")) {
        dump("expected bool destination rejection", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.9.5: bitcast to bool-vector alias rejected" {
    // Parser rejects `>>` template close without a space, so alias via struct
    // is the pragmatic path for this check. The validator still sees
    // `vec2<bool>` as the destination type when resolved via the alias.
    var r = try validate(
        \\alias BVec = vec2<bool>;
        \\fn f() { let x = bitcast<BVec>(vec2u(1u, 2u)); }
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "cannot bitcast to")) {
        dump("expected bool-vector destination rejection", r);
        return error.TestUnexpectedResult;
    }
}

// -------------------------------------------------------------------------
// Arity errors.
// -------------------------------------------------------------------------

test "§17.9.5: bitcast<u32>() with no args rejected" {
    var r = try validate("fn f() { let x = bitcast<u32>(); }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "'bitcast' requires exactly 1 argument")) {
        dump("expected arity error for 0-arg bitcast", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.9.5: bitcast<u32>(1u, 2u) rejected (too many args)" {
    var r = try validate("fn f() { let x = bitcast<u32>(1u, 2u); }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "'bitcast' requires exactly 1 argument")) {
        dump("expected arity error for 2-arg bitcast", r);
        return error.TestUnexpectedResult;
    }
}

// -------------------------------------------------------------------------
// Identity and nested.
// -------------------------------------------------------------------------

test "§17.9.5: bitcast<i32>(bitcast<u32>(1i)) valid (nested)" {
    var r = try validate("fn f() { let x = bitcast<i32>(bitcast<u32>(1i)); }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("expected no error on nested bitcast", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.9.5: bitcast<u32>(1u) identity valid" {
    var r = try validate("fn f() { let x = bitcast<u32>(1u); }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("expected no error on identity bitcast", r);
        return error.TestUnexpectedResult;
    }
}

// -------------------------------------------------------------------------
// Return type inference — `let r = bitcast<f32>(1u)` → r has type f32.
// Observed via an arithmetic-compatibility check.
// -------------------------------------------------------------------------

test "§17.9.5: bitcast result type = template (usable in f32 context)" {
    var r = try validate(
        \\fn f() -> f32 {
        \\  let x = bitcast<f32>(1u);
        \\  return x + 1.0;
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("expected no error on f32+bitcast<f32> context", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.9.5: bitcast result type = vec2u (indexable)" {
    var r = try validate(
        \\fn f() -> u32 {
        \\  let x = bitcast<vec2u>(vec2i(1, 2));
        \\  return x[0];
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("expected no error on bitcast<vec2u> + index", r);
        return error.TestUnexpectedResult;
    }
}
