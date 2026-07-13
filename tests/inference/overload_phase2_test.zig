//! Phase 2 coverage for the declarative overload engine — the
//! `same_as_arg` family migration (Task #9). Exercises behaviors that
//! are *new* to the engine: the scalar/vector shape split, reducing
//! builtins returning element scalars, mix's three forms, cross's
//! fixed-width check, determinant's squareness constraint, and
//! abstract-int promotion into float overloads.
//!
//! Diagnostics-wording-style pins for `math_builtins_test.zig` and
//! inference-type pins for `overload_same_as_arg_test.zig` are
//! preserved verbatim; this file adds the missing behaviors.

const std = @import("std");
const wgslender = @import("wgslender");

fn analyze(src: [:0]const u8) !wgslender.Validator.AnalysisResult {
    return wgslender.analyzeWithOptions(std.testing.allocator, src, .{});
}

fn validate(src: [:0]const u8) !wgslender.Validator.Result {
    return wgslender.validateWithOptions(std.testing.allocator, src, .{});
}

fn letType(r: *const wgslender.Validator.AnalysisResult, name: []const u8) ?wgslender.Types.Type {
    const mod = r.module orelse return null;
    for (mod.symbols.items, 0..) |sym, idx| {
        if (sym.kind != .let) continue;
        if (!std.mem.eql(u8, sym.original_name, name)) continue;
        return r.symbol_types.get(@intCast(idx));
    }
    return null;
}

fn expectLetString(r: *const wgslender.Validator.AnalysisResult, name: []const u8, expected: []const u8) !void {
    const t = letType(r, name) orelse {
        std.debug.print("let '{s}' has no recorded type\n", .{name});
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqualStrings(expected, t.string());
}

fn anyError(r: wgslender.Validator.Result) bool {
    for (r.diagnostics.items()) |d| {
        if (d.severity == .@"error") return true;
    }
    return false;
}

fn hasError(r: wgslender.Validator.Result, needle: []const u8) bool {
    for (r.diagnostics.items()) |d| {
        if (d.severity != .@"error") continue;
        if (std.mem.indexOf(u8, d.message, needle) != null) return true;
    }
    return false;
}

fn expectRejected(src: [:0]const u8, needle: []const u8) !void {
    var r = try validate(src);
    defer r.deinit();
    try std.testing.expect(hasError(r, needle));
}

fn expectAccepted(src: [:0]const u8) !void {
    var r = try validate(src);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(!anyError(r));
}

// -------------------------------------------------------------------------
// Reducing builtins — return-type is the scalar element, not the container.
// -------------------------------------------------------------------------

test "length(vec3<f32>) → f32" {
    var r = try analyze("fn f() { let x = length(vec3<f32>(1.0, 2.0, 3.0)); }");
    defer r.deinit();
    try expectLetString(&r, "x", "f32");
}

test "length(vec2<f32>) → f32" {
    var r = try analyze("fn f() { let x = length(vec2<f32>(3.0, 4.0)); }");
    defer r.deinit();
    try expectLetString(&r, "x", "f32");
}

test "length(3.0f) → f32 (scalar form)" {
    var r = try analyze("fn f() { let x = length(3.0f); }");
    defer r.deinit();
    try expectLetString(&r, "x", "f32");
}

test "length(1u) rejected — integer arg" {
    try expectRejected(
        "fn f() { let x = length(1u); }",
        "no matching overload for 'length'",
    );
}

test "distance(vec3f, vec3f) → f32" {
    var r = try analyze("fn f() { let x = distance(vec3<f32>(0.0), vec3<f32>(1.0)); }");
    defer r.deinit();
    try expectLetString(&r, "x", "f32");
}

test "distance with mismatched widths rejected" {
    try expectRejected(
        "fn f() { let x = distance(vec2<f32>(0.0), vec3<f32>(1.0)); }",
        "no matching overload for 'distance'",
    );
}

test "dot(vec3<i32>, vec3<i32>) → i32 (numeric-any)" {
    var r = try analyze("fn f() { let x = dot(vec3<i32>(1, 2, 3), vec3<i32>(4, 5, 6)); }");
    defer r.deinit();
    try expectLetString(&r, "x", "i32");
}

test "dot(vec2<u32>, vec2<u32>) → u32" {
    var r = try analyze("fn f() { let x = dot(vec2<u32>(1u, 2u), vec2<u32>(3u, 4u)); }");
    defer r.deinit();
    try expectLetString(&r, "x", "u32");
}

test "dot(scalar, scalar) rejected — vector-only" {
    try expectRejected(
        "fn f() { let x = dot(1.0f, 2.0f); }",
        "no matching overload for 'dot'",
    );
}

// -------------------------------------------------------------------------
// Cross — fixed vec3 width.
// -------------------------------------------------------------------------

test "cross(vec3f, vec3f) → vec3<f32>" {
    var r = try analyze("fn f() { let x = cross(vec3<f32>(1.0, 0.0, 0.0), vec3<f32>(0.0, 1.0, 0.0)); }");
    defer r.deinit();
    try expectLetString(&r, "x", "vec3<f32>");
}

test "cross(vec2f, vec2f) rejected — wrong width" {
    try expectRejected(
        "fn f() { let x = cross(vec2<f32>(1.0, 0.0), vec2<f32>(0.0, 1.0)); }",
        "no matching overload for 'cross'",
    );
}

test "cross(vec4f, vec4f) rejected" {
    try expectRejected(
        "fn f() { let x = cross(vec4<f32>(1.0), vec4<f32>(0.0)); }",
        "no matching overload for 'cross'",
    );
}

// -------------------------------------------------------------------------
// Determinant — square-only.
// -------------------------------------------------------------------------

test "determinant(mat2x2f) → f32" {
    var r = try analyze("fn f() { let x = determinant(mat2x2<f32>(1.0, 2.0, 3.0, 4.0)); }");
    defer r.deinit();
    try expectLetString(&r, "x", "f32");
}

test "determinant(mat3x3f) → f32" {
    var r = try analyze(
        \\fn f() {
        \\  let m = mat3x3<f32>(1.0, 0.0, 0.0,
        \\                      0.0, 1.0, 0.0,
        \\                      0.0, 0.0, 1.0);
        \\  let x = determinant(m);
        \\}
    );
    defer r.deinit();
    try expectLetString(&r, "x", "f32");
}

test "determinant(mat2x3f) rejected — not square" {
    try expectRejected(
        \\fn f() { let x = determinant(mat2x3<f32>(1.0, 2.0, 3.0, 4.0, 5.0, 6.0)); }
    ,
        "no matching overload for 'determinant'",
    );
}

test "determinant(mat3x2f) rejected — not square" {
    try expectRejected(
        \\fn f() { let x = determinant(mat3x2<f32>(1.0, 2.0, 3.0, 4.0, 5.0, 6.0)); }
    ,
        "no matching overload for 'determinant'",
    );
}

// -------------------------------------------------------------------------
// mix — three forms: scalar, vec+vec+vec, vec+vec+scalar.
// -------------------------------------------------------------------------

test "mix(f32, f32, f32) → f32" {
    var r = try analyze("fn f() { let x = mix(0.0f, 1.0f, 0.5f); }");
    defer r.deinit();
    try expectLetString(&r, "x", "f32");
}

test "mix(vec3f, vec3f, vec3f) → vec3<f32>" {
    var r = try analyze(
        "fn f() { let x = mix(vec3<f32>(0.0), vec3<f32>(1.0), vec3<f32>(0.5)); }",
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec3<f32>");
}

test "mix(vec3f, vec3f, f32) → vec3<f32> (scalar blend)" {
    var r = try analyze(
        "fn f() { let x = mix(vec3<f32>(0.0), vec3<f32>(1.0), 0.5f); }",
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec3<f32>");
}

test "mix(vec3f, vec3f, vec2f) rejected — blend width mismatch" {
    try expectRejected(
        "fn f() { let x = mix(vec3<f32>(0.0), vec3<f32>(1.0), vec2<f32>(0.5)); }",
        "no matching overload for 'mix'",
    );
}

// -------------------------------------------------------------------------
// select — bool scalar cond, vecN<bool> cond, non-bool rejections.
// -------------------------------------------------------------------------

test "select(i32, i32, true) → i32" {
    var r = try analyze("fn f() { let x = select(1i, 2i, true); }");
    defer r.deinit();
    try expectLetString(&r, "x", "i32");
}

test "select(vec3i, vec3i, vec3<bool>) → vec3<i32>" {
    var r = try analyze(
        "fn f() { let x = select(vec3<i32>(1), vec3<i32>(2), vec3<bool>(true, false, true)); }",
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec3<i32>");
}

test "select(vec3i, vec3i, true) → vec3<i32> (scalar bool cond on vector)" {
    var r = try analyze(
        "fn f() { let x = select(vec3<i32>(1), vec3<i32>(2), true); }",
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec3<i32>");
}

test "select(bool, bool, true) → bool (T = bool)" {
    var r = try analyze("fn f() { let x = select(true, false, true); }");
    defer r.deinit();
    try expectLetString(&r, "x", "bool");
}

test "select cond must be bool — integer vec cond rejected" {
    try expectRejected(
        "fn f() { let x = select(vec3<i32>(1), vec3<i32>(2), vec3<i32>(0)); }",
        "no matching overload for 'select'",
    );
}

// -------------------------------------------------------------------------
// Vector-shape mismatches inside the same family.
// -------------------------------------------------------------------------

test "min(vec3f, vec4f) rejected — widths differ" {
    try expectRejected(
        "fn f() { let x = min(vec3<f32>(1.0), vec4<f32>(2.0)); }",
        "no matching overload for 'min'",
    );
}

test "min(1i, 2u) rejected — incompatible concrete kinds" {
    try expectRejected(
        "fn f() { let x = min(1i, 2u); }",
        "no matching overload for 'min'",
    );
}

// -------------------------------------------------------------------------
// Abstract-int → abstract-float promotion for float-only overloads.
// -------------------------------------------------------------------------

test "sin(1) valid — abstract_int promotes to abstract_float → f32 at let" {
    var r = try analyze("fn f() { let x = sin(1); }");
    defer r.deinit();
    try expectLetString(&r, "x", "f32");
}

test "pow(2, 3) valid — both abstract_int → abstract_float" {
    var r = try analyze("fn f() { let x = pow(2, 3); }");
    defer r.deinit();
    try expectLetString(&r, "x", "f32");
}

test "cross(vec3(1,2,3), vec3(4,5,6)) valid — element abstract_int → f32" {
    var r = try analyze("fn f() { let x = cross(vec3(1, 2, 3), vec3(4, 5, 6)); }");
    defer r.deinit();
    try expectLetString(&r, "x", "vec3<f32>");
}

// -------------------------------------------------------------------------
// Pack builtins — input vector shape must match.
// -------------------------------------------------------------------------

test "pack4x8snorm(vec4f) → u32" {
    var r = try analyze("fn f() { let x = pack4x8snorm(vec4<f32>(0.5)); }");
    defer r.deinit();
    try expectLetString(&r, "x", "u32");
}

test "pack4x8snorm(vec2f) rejected — wrong width" {
    try expectRejected(
        "fn f() { let x = pack4x8snorm(vec2<f32>(0.5)); }",
        "no matching overload for 'pack4x8snorm'",
    );
}

test "pack4xI8(vec4i) → u32" {
    var r = try analyze("fn f() { let x = pack4xI8(vec4<i32>(1, 2, 3, 4)); }");
    defer r.deinit();
    try expectLetString(&r, "x", "u32");
}

test "pack4xI8(vec4u) rejected — wrong element kind" {
    try expectRejected(
        "fn f() { let x = pack4xI8(vec4<u32>(1u)); }",
        "no matching overload for 'pack4xI8'",
    );
}

test "pack2x16float(vec2f) → u32" {
    var r = try analyze("fn f() { let x = pack2x16float(vec2<f32>(0.25, 0.75)); }");
    defer r.deinit();
    try expectLetString(&r, "x", "u32");
}

// -------------------------------------------------------------------------
// all/any — bool-only.
// -------------------------------------------------------------------------

test "all(true) → bool" {
    var r = try analyze("fn f() { let x = all(true); }");
    defer r.deinit();
    try expectLetString(&r, "x", "bool");
}

test "all(vec3<bool>(true)) → bool" {
    var r = try analyze("fn f() { let x = all(vec3<bool>(true)); }");
    defer r.deinit();
    try expectLetString(&r, "x", "bool");
}

test "any(vec2<bool>(false, true)) → bool" {
    var r = try analyze("fn f() { let x = any(vec2<bool>(false, true)); }");
    defer r.deinit();
    try expectLetString(&r, "x", "bool");
}

// -------------------------------------------------------------------------
// Bit builtins — integer scalar/vector + mixed u32 offset/count.
// -------------------------------------------------------------------------

test "extractBits(1u, 0u, 4u) → u32" {
    var r = try analyze("fn f() { let x = extractBits(1u, 0u, 4u); }");
    defer r.deinit();
    try expectLetString(&r, "x", "u32");
}

test "extractBits(vec2<i32>, 0u, 4u) → vec2<i32>" {
    var r = try analyze("fn f() { let x = extractBits(vec2<i32>(5, 6), 0u, 4u); }");
    defer r.deinit();
    try expectLetString(&r, "x", "vec2<i32>");
}

test "insertBits(1u, 0u, 0u, 4u) → u32" {
    var r = try analyze("fn f() { let x = insertBits(1u, 0u, 0u, 4u); }");
    defer r.deinit();
    try expectLetString(&r, "x", "u32");
}

test "extractBits with float arg rejected" {
    try expectRejected(
        "fn f() { let x = extractBits(1.0f, 0u, 4u); }",
        "no matching overload for 'extractBits'",
    );
}

// -------------------------------------------------------------------------
// Reflect / refract / faceForward — vector-only floats.
// -------------------------------------------------------------------------

test "reflect(vec3f, vec3f) → vec3<f32>" {
    var r = try analyze("fn f() { let x = reflect(vec3<f32>(1.0), vec3<f32>(0.0, 1.0, 0.0)); }");
    defer r.deinit();
    try expectLetString(&r, "x", "vec3<f32>");
}

test "refract(vec2f, vec2f, f32) → vec2<f32> — scalar eta preserved" {
    var r = try analyze(
        "fn f() { let x = refract(vec2<f32>(1.0, 0.0), vec2<f32>(0.0, 1.0), 1.5f); }",
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec2<f32>");
}

test "faceForward(vec3f, vec3f, vec3f) → vec3<f32>" {
    var r = try analyze(
        "fn f() { let x = faceForward(vec3<f32>(1.0), vec3<f32>(0.0), vec3<f32>(1.0)); }",
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec3<f32>");
}

test "normalize(vec3f) → vec3<f32>" {
    var r = try analyze("fn f() { let x = normalize(vec3<f32>(1.0, 2.0, 3.0)); }");
    defer r.deinit();
    try expectLetString(&r, "x", "vec3<f32>");
}

// -------------------------------------------------------------------------
// ldexp — mixed (T_float, J_int) signature.
// -------------------------------------------------------------------------

test "ldexp(1.0f, 2i) → f32" {
    var r = try analyze("fn f() { let x = ldexp(1.0f, 2i); }");
    defer r.deinit();
    try expectLetString(&r, "x", "f32");
}

test "ldexp(vec3f, vec3i) → vec3<f32>" {
    var r = try analyze(
        "fn f() { let x = ldexp(vec3<f32>(1.0), vec3<i32>(2, 3, 4)); }",
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec3<f32>");
}

test "ldexp(f32, f32) rejected — second arg must be integer" {
    try expectRejected(
        "fn f() { let x = ldexp(1.0f, 2.0f); }",
        "no matching overload for 'ldexp'",
    );
}
