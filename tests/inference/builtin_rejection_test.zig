//! Negative-case corpus for builtin overload resolution.
//!
//! Every builtin family is exercised with three failure modes:
//!   - wrong arity           → E0202 (invalid_arg_count)
//!   - wrong element type    → E0203 (invalid_arg_type) with
//!                             "argument N has type 'T'" pointing at
//!                             the actual offending arg
//!   - wrong shape           → E0203 likewise
//!
//! The first-bad-arg assertion is the load-bearing part: a previous
//! iteration of the solver reported every rejection as "argument 1"
//! regardless of where the real mismatch was. Tests here pin the
//! correct 1-based index so that regression can't land silently.

const std = @import("std");
const wgslender = @import("wgslender");

const Diagnostic = wgslender.Diagnostic;

fn validate(src: [:0]const u8) !wgslender.Validator.Result {
    return wgslender.validateWithOptions(std.testing.allocator, src, .{});
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

fn expectCode(
    label: []const u8,
    src: [:0]const u8,
    want_code: []const u8,
) !void {
    var r = try validate(src);
    defer r.deinit(std.testing.allocator);

    for (r.diagnostics.items()) |d| {
        if (d.severity != .@"error") continue;
        if (std.mem.eql(u8, d.code, want_code)) return;
    }
    std.debug.print(
        "{s}: expected diagnostic code {s}, got:\n",
        .{ label, want_code },
    );
    dump(label, r);
    return error.TestUnexpectedResult;
}

/// Assert E0203 fires AND the message contains "argument N" with the
/// given 1-based index. Regressions that collapsed every failure to
/// argument 1 blew past earlier iterations of this test.
fn expectBadArg(
    label: []const u8,
    src: [:0]const u8,
    want_arg_1based: u32,
) !void {
    var r = try validate(src);
    defer r.deinit(std.testing.allocator);

    var arg_buf: [32]u8 = undefined;
    const arg_needle = try std.fmt.bufPrint(&arg_buf, "argument {d}", .{want_arg_1based});

    for (r.diagnostics.items()) |d| {
        if (d.severity != .@"error") continue;
        if (!std.mem.eql(u8, d.code, Diagnostic.Code.invalid_arg_type)) continue;
        if (std.mem.indexOf(u8, d.message, arg_needle) != null) return;
    }
    std.debug.print(
        "{s}: expected E0203 with '{s}' in message, got:\n",
        .{ label, arg_needle },
    );
    dump(label, r);
    return error.TestUnexpectedResult;
}

// =========================================================================
// Fixture generators — keep WGSL construction in one place so the
// per-family loops stay tight.
// =========================================================================

fn wrapMain(comptime body: []const u8) [:0]const u8 {
    return "fn test_fn() { " ++ body ++ " }";
}

// =========================================================================
// Float-family unary (sin, cos, ..., saturate, quantizeToF16)
// =========================================================================

test "unary float builtins reject non-float scalar" {
    const names = [_][]const u8{
        "sin",     "cos",       "tan",         "asin",      "acos",       "atan",
        "sinh",    "cosh",      "tanh",        "asinh",     "acosh",      "atanh",
        "exp",     "exp2",      "log",         "log2",      "sqrt",       "inverseSqrt",
        "floor",   "ceil",      "round",       "trunc",     "fract",      "saturate",
        "degrees", "radians",   "quantizeToF16",
    };
    for (names) |n| {
        var buf: [128]u8 = undefined;
        const body = try std.fmt.bufPrint(&buf, "let r = {s}(true);", .{n});
        const src = try std.testing.allocator.dupeZ(u8, body);
        defer std.testing.allocator.free(src);
        const fixture: [:0]const u8 = try std.testing.allocator.allocSentinel(u8, src.len + 31, 0);
        defer std.testing.allocator.free(fixture);
        _ = try std.fmt.bufPrint(@constCast(fixture), "fn test_fn() {{ {s} }}", .{src});
        try expectBadArg(n, fixture, 1);
    }
}

test "unary float builtins reject wrong arity" {
    // sin() — no args when min=1,max=1.
    try expectCode("sin()", wrapMain("let r = sin();"), Diagnostic.Code.invalid_arg_count);
    try expectCode("cos(a,b)", wrapMain("let r = cos(1.0, 2.0);"), Diagnostic.Code.invalid_arg_count);
    try expectCode("sqrt()", wrapMain("let r = sqrt();"), Diagnostic.Code.invalid_arg_count);
    try expectCode("fract(a,b)", wrapMain("let r = fract(1.0, 2.0);"), Diagnostic.Code.invalid_arg_count);
}

// =========================================================================
// Float-family binary (atan2, pow, step)
// =========================================================================

test "binary float builtins reject bool in second arg" {
    // pow(1.0, true) — argument 2 is bool, not float.
    try expectBadArg("pow(f,b)", wrapMain("let r = pow(1.0, true);"), 2);
    try expectBadArg("atan2(f,b)", wrapMain("let r = atan2(1.0, true);"), 2);
    try expectBadArg("step(f,b)", wrapMain("let r = step(1.0, true);"), 2);
}

test "binary float builtins reject bool in first arg" {
    try expectBadArg("pow(b,f)", wrapMain("let r = pow(true, 1.0);"), 1);
    try expectBadArg("atan2(b,f)", wrapMain("let r = atan2(true, 1.0);"), 1);
}

test "binary float builtins reject wrong arity" {
    try expectCode("pow()", wrapMain("let r = pow();"), Diagnostic.Code.invalid_arg_count);
    try expectCode("pow(a)", wrapMain("let r = pow(1.0);"), Diagnostic.Code.invalid_arg_count);
    try expectCode("atan2(a,b,c)", wrapMain("let r = atan2(1.0, 2.0, 3.0);"), Diagnostic.Code.invalid_arg_count);
}

// =========================================================================
// Float-family ternary (smoothstep, fma)
// =========================================================================

test "ternary float builtins point at correct bad arg" {
    try expectBadArg("smoothstep(f,b,f)", wrapMain("let r = smoothstep(1.0, true, 2.0);"), 2);
    try expectBadArg("smoothstep(f,f,b)", wrapMain("let r = smoothstep(1.0, 2.0, true);"), 3);
    try expectBadArg("fma(b,f,f)", wrapMain("let r = fma(true, 1.0, 2.0);"), 1);
    try expectBadArg("fma(f,f,b)", wrapMain("let r = fma(1.0, 2.0, true);"), 3);
}

// =========================================================================
// Integer-family (countOneBits, reverseBits, extractBits, insertBits)
// =========================================================================

test "integer-only builtins reject float arg" {
    const names = [_][]const u8{
        "countOneBits",      "countLeadingZeros", "countTrailingZeros",
        "reverseBits",       "firstLeadingBit",   "firstTrailingBit",
    };
    for (names) |n| {
        var fixture_buf: [128]u8 = undefined;
        const fixture = try std.fmt.bufPrint(&fixture_buf, "fn test_fn() {{ let r = {s}(1.0); }}", .{n});
        const src = try std.testing.allocator.dupeZ(u8, fixture);
        defer std.testing.allocator.free(src);
        try expectBadArg(n, src, 1);
    }
}

test "integer-only builtins reject bool arg" {
    try expectBadArg("countOneBits(b)", wrapMain("let r = countOneBits(true);"), 1);
    try expectBadArg("reverseBits(b)", wrapMain("let r = reverseBits(true);"), 1);
}

test "extractBits / insertBits point at correct bad arg" {
    // extractBits(e: T, offset: u32, count: u32) — offset must be integer.
    try expectBadArg("extractBits(i,f,u)", wrapMain("let r = extractBits(1, 1.0, 2u);"), 2);
    try expectBadArg("extractBits(i,u,f)", wrapMain("let r = extractBits(1, 1u, 2.0);"), 3);

    // insertBits(e: T, newbits: T, offset: u32, count: u32).
    try expectBadArg("insertBits(i,i,f,u)", wrapMain("let r = insertBits(1, 2, 1.0, 4u);"), 3);
    try expectBadArg("insertBits(i,i,u,f)", wrapMain("let r = insertBits(1, 2, 1u, 4.0);"), 4);
}

// =========================================================================
// Numeric-any (abs, sign, min, max, clamp)
// =========================================================================

test "numeric-any builtins still reject bool" {
    try expectBadArg("abs(b)", wrapMain("let r = abs(true);"), 1);
    try expectBadArg("sign(b)", wrapMain("let r = sign(true);"), 1);
    try expectBadArg("min(b,i)", wrapMain("let r = min(true, 1);"), 1);
    try expectBadArg("min(i,b)", wrapMain("let r = min(1, true);"), 2);
    try expectBadArg("max(i,b)", wrapMain("let r = max(1, true);"), 2);
    try expectBadArg("clamp(b,i,i)", wrapMain("let r = clamp(true, 1, 2);"), 1);
    try expectBadArg("clamp(i,b,i)", wrapMain("let r = clamp(1, true, 2);"), 2);
    try expectBadArg("clamp(i,i,b)", wrapMain("let r = clamp(1, 2, true);"), 3);
}

test "numeric-any builtins reject wrong arity" {
    try expectCode("abs()", wrapMain("let r = abs();"), Diagnostic.Code.invalid_arg_count);
    try expectCode("min(a)", wrapMain("let r = min(1);"), Diagnostic.Code.invalid_arg_count);
    try expectCode("clamp(a,b)", wrapMain("let r = clamp(1,2);"), Diagnostic.Code.invalid_arg_count);
    try expectCode("clamp(a,b,c,d)", wrapMain("let r = clamp(1,2,3,4);"), Diagnostic.Code.invalid_arg_count);
}

// =========================================================================
// Vector geometric (dot, cross, length, distance, normalize, reflect, refract)
// =========================================================================

test "vector geometric builtins reject scalar where vector expected" {
    // cross takes two vec3<f32>; passing scalars must fail.
    try expectBadArg("cross(s,v)", wrapMain("let r = cross(1.0, vec3f(1,2,3));"), 1);
    try expectBadArg("cross(v,s)", wrapMain("let r = cross(vec3f(1,2,3), 1.0);"), 2);

    // reflect(e1: vecN<f32>, e2: vecN<f32>)
    try expectBadArg("reflect(s,v)", wrapMain("let r = reflect(1.0, vec3f(0));"), 1);

    // refract(e1: vecN<f32>, e2: vecN<f32>, e3: f32)
    try expectBadArg("refract(v,v,v)", wrapMain("let r = refract(vec3f(0), vec3f(0), vec3f(0));"), 3);
}

test "vector geometric builtins reject bool element" {
    try expectBadArg("dot(vb,vb)", wrapMain("let r = dot(vec2<bool>(true,false), vec2<bool>(true,false));"), 1);
    try expectBadArg("length(vb)", wrapMain("let r = length(vec2<bool>(true,false));"), 1);
}

test "vector geometric builtins reject wrong arity" {
    try expectCode("dot()", wrapMain("let r = dot();"), Diagnostic.Code.invalid_arg_count);
    try expectCode("cross(a)", wrapMain("let r = cross(vec3f(1));"), Diagnostic.Code.invalid_arg_count);
    try expectCode("refract(a,b)", wrapMain("let r = refract(vec3f(0), vec3f(0));"), Diagnostic.Code.invalid_arg_count);
}

// =========================================================================
// Matrix (determinant, transpose)
// =========================================================================

test "matrix builtins reject non-matrix" {
    try expectBadArg("determinant(s)", wrapMain("let r = determinant(1.0);"), 1);
    try expectBadArg("transpose(s)", wrapMain("let r = transpose(1.0);"), 1);
    try expectBadArg("determinant(v)", wrapMain("let r = determinant(vec3f(0));"), 1);
}

test "determinant rejects non-square matrix" {
    // `determinant` is only defined on square matrices — mat2x3 must reject.
    try expectBadArg("determinant(mat2x3)", wrapMain("let r = determinant(mat2x3<f32>());"), 1);
}

test "matrix builtins reject wrong arity" {
    try expectCode("transpose()", wrapMain("let r = transpose();"), Diagnostic.Code.invalid_arg_count);
    try expectCode("determinant(a,b)", wrapMain("let r = determinant(mat2x2<f32>(), mat2x2<f32>());"), Diagnostic.Code.invalid_arg_count);
}

// =========================================================================
// Logical (select, all, any)
// =========================================================================

test "select rejects non-bool condition" {
    // select(false_val, true_val, cond: bool)
    try expectBadArg("select(_,_,i)", wrapMain("let r = select(0, 1, 2);"), 3);
    try expectBadArg("select(_,_,f)", wrapMain("let r = select(0.0, 1.0, 0.5);"), 3);
}

test "select rejects mismatched true/false types" {
    // The solver binds T from arg 1 and expects arg 2 to match. Use
    // explicit concrete scalars so abstract-int promotion doesn't
    // silently unify them.
    try expectBadArg("select(i,u,b)", wrapMain("let r = select(1i, 1u, true);"), 2);
}

test "all / any reject non-bool" {
    try expectBadArg("all(i)", wrapMain("let r = all(1);"), 1);
    try expectBadArg("any(f)", wrapMain("let r = any(1.0);"), 1);
    try expectBadArg("all(v_int)", wrapMain("let r = all(vec2<i32>(0));"), 1);
}

test "select / all / any reject wrong arity" {
    try expectCode("select(a)", wrapMain("let r = select(1);"), Diagnostic.Code.invalid_arg_count);
    try expectCode("select(a,b)", wrapMain("let r = select(1,2);"), Diagnostic.Code.invalid_arg_count);
    try expectCode("all()", wrapMain("let r = all();"), Diagnostic.Code.invalid_arg_count);
    try expectCode("any(a,b)", wrapMain("let r = any(true, false);"), Diagnostic.Code.invalid_arg_count);
}

// =========================================================================
// Derivatives — require uniform flow + float family
// =========================================================================

test "derivatives reject non-float" {
    // Use explicit `i32` / bool so abstract-int → abstract-float promotion
    // (which would make `dpdx(1)` legal) doesn't sneak the call through.
    try expectBadArg("dpdx(i)", "@fragment fn f() { let r = dpdx(1i); }", 1);
    try expectBadArg("dpdy(b)", "@fragment fn f() { let r = dpdy(true); }", 1);
    try expectBadArg("fwidth(i)", "@fragment fn f() { let r = fwidth(1i); }", 1);
}

test "derivatives reject wrong arity" {
    try expectCode("dpdx()", "@fragment fn f() { let r = dpdx(); }", Diagnostic.Code.invalid_arg_count);
    try expectCode("dpdy(a,b)", "@fragment fn f() { let r = dpdy(1.0, 2.0); }", Diagnostic.Code.invalid_arg_count);
}

// =========================================================================
// Packing (pack2x16*, pack4x8*, pack4xI8*, pack4xU8*, dot4*)
// =========================================================================

test "pack builtins reject wrong vector element" {
    try expectBadArg("pack2x16snorm(v_i)", wrapMain("let r = pack2x16snorm(vec2<i32>(0));"), 1);
    try expectBadArg("pack4x8snorm(v_i)", wrapMain("let r = pack4x8snorm(vec4<i32>(0));"), 1);
    try expectBadArg("pack4xI8(v_f)", wrapMain("let r = pack4xI8(vec4<f32>(0));"), 1);
    try expectBadArg("pack4xU8(v_f)", wrapMain("let r = pack4xU8(vec4<f32>(0));"), 1);
}

test "pack builtins reject wrong arity" {
    try expectCode("pack2x16snorm()", wrapMain("let r = pack2x16snorm();"), Diagnostic.Code.invalid_arg_count);
    try expectCode("pack4x8snorm(a,b)", wrapMain("let r = pack4x8snorm(vec4<f32>(0), vec4<f32>(0));"), Diagnostic.Code.invalid_arg_count);
}

test "unpack builtins reject non-u32" {
    try expectBadArg("unpack2x16float(f)", wrapMain("let r = unpack2x16float(1.0);"), 1);
    // `1` is abstract_int and converts to u32 for free; use explicit i32.
    try expectBadArg("unpack4xI8(i)", wrapMain("let r = unpack4xI8(1i);"), 1);
}

test "dot4I8Packed / dot4U8Packed reject non-u32" {
    try expectBadArg("dot4I8Packed(f,u)", wrapMain("let r = dot4I8Packed(1.0, 1u);"), 1);
    try expectBadArg("dot4I8Packed(u,f)", wrapMain("let r = dot4I8Packed(1u, 1.0);"), 2);
    try expectBadArg("dot4U8Packed(u,b)", wrapMain("let r = dot4U8Packed(1u, true);"), 2);
}

// =========================================================================
// Atomics
// =========================================================================
//
// Atomic ops require a pointer<atomic<T>, ...> first arg. Passing a
// non-pointer, a non-atomic pointer, or a mismatched element type all
// fail via the overload engine.

const atomic_fixture_prelude =
    \\var<workgroup> g: atomic<u32>;
    \\
;

test "atomicLoad rejects wrong arity" {
    try expectCode(
        "atomicLoad()",
        atomic_fixture_prelude ++ "fn test_fn() { let r = atomicLoad(); }",
        Diagnostic.Code.invalid_arg_count,
    );
    try expectCode(
        "atomicLoad(a,b)",
        atomic_fixture_prelude ++ "fn test_fn() { let r = atomicLoad(&g, 1u); }",
        Diagnostic.Code.invalid_arg_count,
    );
}

test "atomicAdd rejects wrong value type" {
    // g is atomic<u32>; passing an f32 second arg must fail on argument 2.
    try expectBadArg(
        "atomicAdd(p,f)",
        atomic_fixture_prelude ++ "fn test_fn() { let r = atomicAdd(&g, 1.0); }",
        2,
    );
}

test "atomicStore rejects wrong arity" {
    try expectCode(
        "atomicStore(a)",
        atomic_fixture_prelude ++ "fn test_fn() { atomicStore(&g); }",
        Diagnostic.Code.invalid_arg_count,
    );
}

// =========================================================================
// Textures (sampling / loading)
// =========================================================================
//
// Only a couple cases here — more exhaustive coverage lives in
// texture_overload_test.zig. These pins catch the specific ergonomic
// regression where `first_bad_arg` was collapsing to 0/1 regardless.

const tex_prelude =
    \\@group(0) @binding(0) var tex: texture_2d<f32>;
    \\@group(0) @binding(1) var samp: sampler;
    \\
;

test "textureSample rejects wrong arity" {
    try expectCode(
        "textureSample()",
        tex_prelude ++ "@fragment fn f() { let r = textureSample(); }",
        Diagnostic.Code.invalid_arg_count,
    );
}

test "textureSample rejects non-float coord" {
    // textureSample(tex, sampler, coord: vec2<f32>) — passing int vec on
    // arg 3 must fail on argument 3.
    try expectBadArg(
        "textureSample(t,s,vi)",
        tex_prelude ++ "@fragment fn f() { let r = textureSample(tex, samp, vec2<i32>(0,0)); }",
        3,
    );
}

// =========================================================================
// arrayLength
// =========================================================================

const array_len_prelude =
    \\struct Buf { data: array<f32> };
    \\@group(0) @binding(0) var<storage, read> buf: Buf;
    \\
;

test "arrayLength rejects non-pointer arg" {
    // Passing the struct value, not a pointer to its array field.
    try expectBadArg(
        "arrayLength(&buf)",
        array_len_prelude ++ "fn test_fn() { let r = arrayLength(&buf); }",
        1,
    );
}

test "arrayLength rejects wrong arity" {
    try expectCode(
        "arrayLength()",
        array_len_prelude ++ "fn test_fn() { let r = arrayLength(); }",
        Diagnostic.Code.invalid_arg_count,
    );
}

// =========================================================================
// Barriers (zero-arg — arity failure only)
// =========================================================================

test "barriers reject non-zero arity" {
    try expectCode(
        "workgroupBarrier(a)",
        "@compute @workgroup_size(1) fn cs() { workgroupBarrier(1u); }",
        Diagnostic.Code.invalid_arg_count,
    );
    try expectCode(
        "storageBarrier(a)",
        "@compute @workgroup_size(1) fn cs() { storageBarrier(1u); }",
        Diagnostic.Code.invalid_arg_count,
    );
}

// =========================================================================
// frexp / modf — single float arg
// =========================================================================

test "frexp / modf reject non-float" {
    // Explicit i32 / bool — abstract_int → abstract_float conversion would
    // otherwise make `frexp(1)` legal per WGSL literal typing rules.
    try expectBadArg("frexp(i)", wrapMain("let r = frexp(1i);"), 1);
    try expectBadArg("modf(i)", wrapMain("let r = modf(1i);"), 1);
    try expectBadArg("frexp(b)", wrapMain("let r = frexp(true);"), 1);
}

test "frexp / modf reject wrong arity" {
    try expectCode("frexp()", wrapMain("let r = frexp();"), Diagnostic.Code.invalid_arg_count);
    try expectCode("modf(a,b)", wrapMain("let r = modf(1.0, 2.0);"), Diagnostic.Code.invalid_arg_count);
}

// =========================================================================
// bitcast<T>(e) — template-seeded dispatch
// =========================================================================

test "bitcast rejects f16 source (not in concrete_32 family)" {
    // bitcast source scalar must be i32/u32/f32; f16 is excluded from the
    // concrete_32 family. Message path differs (bitcast has its own
    // dispatcher), so just confirm *some* error fires.
    var r = try validate(wrapMain("let r = bitcast<f32>(1.0h);"));
    defer r.deinit(std.testing.allocator);
    var has_err = false;
    for (r.diagnostics.items()) |d| {
        if (d.severity == .@"error") {
            has_err = true;
            break;
        }
    }
    if (!has_err) {
        dump("bitcast<f32>(1.0h)", r);
        return error.TestUnexpectedResult;
    }
}

test "bitcast rejects wrong arity" {
    try expectCode(
        "bitcast<f32>()",
        wrapMain("let r = bitcast<f32>();"),
        Diagnostic.Code.invalid_arg_count,
    );
}

// =========================================================================
// Mix — the odd one out in the ternary family
// =========================================================================

test "mix reject bool element" {
    try expectBadArg("mix(b,f,f)", wrapMain("let r = mix(true, 1.0, 0.5);"), 1);
    try expectBadArg("mix(f,b,f)", wrapMain("let r = mix(1.0, true, 0.5);"), 2);
    try expectBadArg("mix(f,f,b)", wrapMain("let r = mix(1.0, 2.0, true);"), 3);
}

test "mix rejects wrong arity" {
    try expectCode("mix()", wrapMain("let r = mix();"), Diagnostic.Code.invalid_arg_count);
    try expectCode("mix(a)", wrapMain("let r = mix(1.0);"), Diagnostic.Code.invalid_arg_count);
    try expectCode("mix(a,b,c,d)", wrapMain("let r = mix(1.0, 2.0, 3.0, 4.0);"), Diagnostic.Code.invalid_arg_count);
}
