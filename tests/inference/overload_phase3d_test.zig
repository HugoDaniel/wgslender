//! Phase 3d coverage for the declarative overload engine — the sample
//! and gather families migrated onto `Pattern.tparam_texture` (Task #9).
//! Exercises every texture-kind / dimension combination these builtins
//! admit, plus offset-arg and array-index variants and the sampler-kind
//! discrimination (sampler vs sampler_comparison).
//!
//! Structure mirrors `overload_phase3c_test.zig`.

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
        std.debug.print("let '{s}' missing; diagnostics:\n", .{name});
        for (r.diagnostics.items()) |d| std.debug.print("  [{s}] {s}: {s}\n", .{ d.code, d.severity.string(), d.message });
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

fn hasErrorContaining(r: wgslender.Validator.Result, needle: []const u8) bool {
    for (r.diagnostics.items()) |d| {
        if (d.severity != .@"error") continue;
        if (std.mem.indexOf(u8, d.message, needle) != null) return true;
    }
    return false;
}

// =========================================================================
// textureSample — sampled textures return vec4<T>, depth textures return f32.
// =========================================================================

test "textureSample(texture_2d<f32>, sampler, vec2<f32>) → vec4<f32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_2d<f32>;
        \\@group(0) @binding(1) var s: sampler;
        \\fn f() { let x = textureSample(t, s, vec2<f32>(0.0, 0.0)); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<f32>");
}

test "textureSample(texture_2d<i32>, sampler, vec2<f32>) → vec4<i32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_2d<i32>;
        \\@group(0) @binding(1) var s: sampler;
        \\fn f() { let x = textureSample(t, s, vec2<f32>(0.0, 0.0)); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<i32>");
}

test "textureSample with offset vec2<i32> → vec4<T>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_2d<f32>;
        \\@group(0) @binding(1) var s: sampler;
        \\fn f() { let x = textureSample(t, s, vec2<f32>(0.0, 0.0), vec2<i32>(1, 1)); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<f32>");
}

test "textureSample(texture_2d_array, ..., array_index) → vec4<T>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_2d_array<f32>;
        \\@group(0) @binding(1) var s: sampler;
        \\fn f() { let x = textureSample(t, s, vec2<f32>(0.0, 0.0), 0i); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<f32>");
}

test "textureSample(texture_2d_array, ..., array_index, offset) → vec4<T>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_2d_array<f32>;
        \\@group(0) @binding(1) var s: sampler;
        \\fn f() { let x = textureSample(t, s, vec2<f32>(0.0, 0.0), 0i, vec2<i32>(0, 0)); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<f32>");
}

test "textureSample(texture_3d<f32>, sampler, vec3<f32>) → vec4<f32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_3d<f32>;
        \\@group(0) @binding(1) var s: sampler;
        \\fn f() { let x = textureSample(t, s, vec3<f32>(0.0, 0.0, 0.0)); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<f32>");
}

test "textureSample(texture_cube<f32>, sampler, vec3<f32>) → vec4<f32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_cube<f32>;
        \\@group(0) @binding(1) var s: sampler;
        \\fn f() { let x = textureSample(t, s, vec3<f32>(0.0, 0.0, 0.0)); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<f32>");
}

test "textureSample(texture_depth_2d, sampler, vec2<f32>) → f32" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_depth_2d;
        \\@group(0) @binding(1) var s: sampler;
        \\fn f() { let x = textureSample(t, s, vec2<f32>(0.0, 0.0)); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "f32");
}

test "textureSample(texture_depth_cube_array, sampler, vec3<f32>, arr_idx) → f32" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_depth_cube_array;
        \\@group(0) @binding(1) var s: sampler;
        \\fn f() { let x = textureSample(t, s, vec3<f32>(0.0, 0.0, 0.0), 0i); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "f32");
}

test "textureSample on storage texture rejected — no matching overload" {
    var r = try validate(
        \\@group(0) @binding(0) var t: texture_storage_2d<rgba8unorm, read>;
        \\@group(0) @binding(1) var s: sampler;
        \\fn f() { let x = textureSample(t, s, vec2<f32>(0.0, 0.0)); }
    );
    defer r.deinit();
    try std.testing.expect(anyError(r));
}

test "textureSample with sampler_comparison rejected — wrong sampler kind" {
    var r = try validate(
        \\@group(0) @binding(0) var t: texture_2d<f32>;
        \\@group(0) @binding(1) var s: sampler_comparison;
        \\fn f() { let x = textureSample(t, s, vec2<f32>(0.0, 0.0)); }
    );
    defer r.deinit();
    try std.testing.expect(anyError(r));
}

test "textureSample with vec3<f32> coord on texture_2d rejected" {
    var r = try validate(
        \\@group(0) @binding(0) var t: texture_2d<f32>;
        \\@group(0) @binding(1) var s: sampler;
        \\fn f() { let x = textureSample(t, s, vec3<f32>(0.0, 0.0, 0.0)); }
    );
    defer r.deinit();
    try std.testing.expect(anyError(r));
}

// =========================================================================
// textureSampleBias — sampled only, bias is f32.
// =========================================================================

test "textureSampleBias(texture_2d, sampler, vec2f, bias) → vec4<f32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_2d<f32>;
        \\@group(0) @binding(1) var s: sampler;
        \\fn f() { let x = textureSampleBias(t, s, vec2<f32>(0.0, 0.0), 0.5); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<f32>");
}

test "textureSampleBias(texture_cube_array, ..., arr_idx, bias) → vec4<f32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_cube_array<f32>;
        \\@group(0) @binding(1) var s: sampler;
        \\fn f() { let x = textureSampleBias(t, s, vec3<f32>(0.0, 0.0, 0.0), 0i, 0.5); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<f32>");
}

test "textureSampleBias on depth texture rejected" {
    var r = try validate(
        \\@group(0) @binding(0) var t: texture_depth_2d;
        \\@group(0) @binding(1) var s: sampler;
        \\fn f() { let x = textureSampleBias(t, s, vec2<f32>(0.0, 0.0), 0.5); }
    );
    defer r.deinit();
    try std.testing.expect(anyError(r));
}

// =========================================================================
// textureSampleGrad — sampled only, ddx/ddy share coord width.
// =========================================================================

test "textureSampleGrad(texture_2d, sampler, vec2f, ddx, ddy) → vec4<f32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_2d<f32>;
        \\@group(0) @binding(1) var s: sampler;
        \\fn f() {
        \\  let x = textureSampleGrad(t, s, vec2<f32>(0.0, 0.0), vec2<f32>(0.0, 0.0), vec2<f32>(0.0, 0.0));
        \\}
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<f32>");
}

test "textureSampleGrad(texture_3d, ..., ddx=vec3, ddy=vec3, offset=vec3i) → vec4<f32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_3d<f32>;
        \\@group(0) @binding(1) var s: sampler;
        \\fn f() {
        \\  let x = textureSampleGrad(t, s, vec3<f32>(0.0, 0.0, 0.0),
        \\                               vec3<f32>(0.0, 0.0, 0.0),
        \\                               vec3<f32>(0.0, 0.0, 0.0),
        \\                               vec3<i32>(0, 0, 0));
        \\}
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<f32>");
}

// =========================================================================
// textureSampleLevel — sampled (level: f32) and depth (level: i32).
// =========================================================================

test "textureSampleLevel(texture_2d, sampler, vec2f, f32) → vec4<f32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_2d<f32>;
        \\@group(0) @binding(1) var s: sampler;
        \\fn f() { let x = textureSampleLevel(t, s, vec2<f32>(0.0, 0.0), 0.0); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<f32>");
}

test "textureSampleLevel(texture_depth_2d, sampler, vec2f, i32) → f32" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_depth_2d;
        \\@group(0) @binding(1) var s: sampler;
        \\fn f() { let x = textureSampleLevel(t, s, vec2<f32>(0.0, 0.0), 0i); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "f32");
}

test "textureSampleLevel(texture_depth_2d_array, ..., arr_idx, i32, offset) → f32" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_depth_2d_array;
        \\@group(0) @binding(1) var s: sampler;
        \\fn f() { let x = textureSampleLevel(t, s, vec2<f32>(0.0, 0.0), 0i, 0i, vec2<i32>(0, 0)); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "f32");
}

// =========================================================================
// textureSampleCompare / textureSampleCompareLevel — depth + sampler_comparison.
// =========================================================================

test "textureSampleCompare(texture_depth_2d, sampler_comparison, vec2f, f32) → f32" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_depth_2d;
        \\@group(0) @binding(1) var s: sampler_comparison;
        \\fn f() { let x = textureSampleCompare(t, s, vec2<f32>(0.0, 0.0), 0.5); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "f32");
}

test "textureSampleCompareLevel(texture_depth_cube_array, ..., arr_idx, f32) → f32" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_depth_cube_array;
        \\@group(0) @binding(1) var s: sampler_comparison;
        \\fn f() { let x = textureSampleCompareLevel(t, s, vec3<f32>(0.0, 0.0, 0.0), 0i, 0.5); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "f32");
}

test "textureSampleCompare on non-depth texture rejected" {
    var r = try validate(
        \\@group(0) @binding(0) var t: texture_2d<f32>;
        \\@group(0) @binding(1) var s: sampler_comparison;
        \\fn f() { let x = textureSampleCompare(t, s, vec2<f32>(0.0, 0.0), 0.5); }
    );
    defer r.deinit();
    try std.testing.expect(anyError(r));
}

test "textureSampleCompare with non-comparison sampler rejected" {
    var r = try validate(
        \\@group(0) @binding(0) var t: texture_depth_2d;
        \\@group(0) @binding(1) var s: sampler;
        \\fn f() { let x = textureSampleCompare(t, s, vec2<f32>(0.0, 0.0), 0.5); }
    );
    defer r.deinit();
    try std.testing.expect(anyError(r));
}

// =========================================================================
// textureGather / textureGatherCompare.
// =========================================================================

test "textureGather(component, texture_2d<f32>, sampler, vec2f) → vec4<f32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_2d<f32>;
        \\@group(0) @binding(1) var s: sampler;
        \\fn f() { let x = textureGather(0i, t, s, vec2<f32>(0.0, 0.0)); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<f32>");
}

test "textureGather(component, texture_2d<u32>, sampler, vec2f) → vec4<u32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_2d<u32>;
        \\@group(0) @binding(1) var s: sampler;
        \\fn f() { let x = textureGather(0i, t, s, vec2<f32>(0.0, 0.0)); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<u32>");
}

test "textureGather(texture_depth_2d, sampler, vec2f) → vec4<f32> (no component)" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_depth_2d;
        \\@group(0) @binding(1) var s: sampler;
        \\fn f() { let x = textureGather(t, s, vec2<f32>(0.0, 0.0)); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<f32>");
}

test "textureGather(texture_depth_2d_array, ..., arr_idx, offset) → vec4<f32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_depth_2d_array;
        \\@group(0) @binding(1) var s: sampler;
        \\fn f() { let x = textureGather(t, s, vec2<f32>(0.0, 0.0), 0i, vec2<i32>(0, 0)); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<f32>");
}

test "textureGatherCompare(texture_depth_2d, sampler_comparison, vec2f, f32) → vec4<f32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_depth_2d;
        \\@group(0) @binding(1) var s: sampler_comparison;
        \\fn f() { let x = textureGatherCompare(t, s, vec2<f32>(0.0, 0.0), 0.5); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<f32>");
}

test "textureGather on texture_3d rejected — spec disallows 3d" {
    var r = try validate(
        \\@group(0) @binding(0) var t: texture_3d<f32>;
        \\@group(0) @binding(1) var s: sampler;
        \\fn f() { let x = textureGather(0i, t, s, vec3<f32>(0.0, 0.0, 0.0)); }
    );
    defer r.deinit();
    try std.testing.expect(anyError(r));
}

// =========================================================================
// textureSampleBaseClampToEdge — texture_2d<f32> or texture_external only.
// =========================================================================

test "textureSampleBaseClampToEdge(texture_2d<f32>, sampler, vec2f) → vec4<f32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_2d<f32>;
        \\@group(0) @binding(1) var s: sampler;
        \\fn f() { let x = textureSampleBaseClampToEdge(t, s, vec2<f32>(0.0, 0.0)); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<f32>");
}

test "textureSampleBaseClampToEdge(texture_external, sampler, vec2f) → vec4<f32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_external;
        \\@group(0) @binding(1) var s: sampler;
        \\fn f() { let x = textureSampleBaseClampToEdge(t, s, vec2<f32>(0.0, 0.0)); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<f32>");
}

test "textureSampleBaseClampToEdge on texture_2d<i32> rejected — f32-element only" {
    var r = try validate(
        \\@group(0) @binding(0) var t: texture_2d<i32>;
        \\@group(0) @binding(1) var s: sampler;
        \\fn f() { let x = textureSampleBaseClampToEdge(t, s, vec2<f32>(0.0, 0.0)); }
    );
    defer r.deinit();
    try std.testing.expect(anyError(r));
}
