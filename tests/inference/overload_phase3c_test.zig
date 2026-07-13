//! Phase 3c coverage for the declarative overload engine — the
//! `Pattern.tparam_texture` extension (Task #9). Exercises every
//! texture-kind / dimension combination the new pattern variant must
//! handle, plus the migrated texture builtins (textureLoad,
//! textureStore, textureDimensions, textureNumLayers/Levels/Samples).
//!
//! Structure mirrors `overload_phase2_test.zig`: positive tests use
//! `analyze` + `expectLetString` to pin the inferred type, rejections
//! use `validate` + `hasError` on the diagnostic message.
//!
//! Sampling / gather families still ride the legacy path and are not
//! exercised here — their migration is a follow-up phase.

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

fn hasErrorWithCode(r: wgslender.Validator.Result, code: []const u8) bool {
    for (r.diagnostics.items()) |d| {
        if (d.severity != .@"error") continue;
        if (std.mem.eql(u8, d.code, code)) return true;
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
// textureLoad — sampled textures
// =========================================================================

test "textureLoad(texture_1d<f32>, i32, i32) → vec4<f32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_1d<f32>;
        \\fn f() { let x = textureLoad(t, 0i, 0i); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<f32>");
}

test "textureLoad(texture_2d<f32>, vec2<i32>, i32) → vec4<f32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_2d<f32>;
        \\fn f() { let x = textureLoad(t, vec2<i32>(0, 0), 0i); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<f32>");
}

test "textureLoad(texture_2d<i32>, vec2<i32>, i32) → vec4<i32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_2d<i32>;
        \\fn f() { let x = textureLoad(t, vec2<i32>(0, 0), 0i); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<i32>");
}

test "textureLoad(texture_2d<u32>, vec2<i32>, i32) → vec4<u32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_2d<u32>;
        \\fn f() { let x = textureLoad(t, vec2<i32>(0, 0), 0i); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<u32>");
}

test "textureLoad(texture_2d<f32>) accepts u32 coord + level" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_2d<f32>;
        \\fn f() { let x = textureLoad(t, vec2<u32>(0u, 0u), 0u); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<f32>");
}

test "textureLoad(texture_2d_array<f32>, vec2<i32>, i32, i32) → vec4<f32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_2d_array<f32>;
        \\fn f() { let x = textureLoad(t, vec2<i32>(0, 0), 0i, 0i); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<f32>");
}

test "textureLoad(texture_3d<f32>, vec3<i32>, i32) → vec4<f32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_3d<f32>;
        \\fn f() { let x = textureLoad(t, vec3<i32>(0, 0, 0), 0i); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<f32>");
}

// =========================================================================
// textureLoad — multisampled
// =========================================================================

test "textureLoad(texture_multisampled_2d<f32>, vec2<i32>, i32) → vec4<f32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_multisampled_2d<f32>;
        \\fn f() { let x = textureLoad(t, vec2<i32>(0, 0), 0i); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<f32>");
}

// =========================================================================
// textureLoad — depth textures
// =========================================================================

test "textureLoad(texture_depth_2d, vec2<i32>, i32) → f32" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_depth_2d;
        \\fn f() { let x = textureLoad(t, vec2<i32>(0, 0), 0i); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "f32");
}

test "textureLoad(texture_depth_2d_array, vec2<i32>, i32, i32) → f32" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_depth_2d_array;
        \\fn f() { let x = textureLoad(t, vec2<i32>(0, 0), 0i, 0i); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "f32");
}

test "textureLoad(texture_depth_multisampled_2d, vec2<i32>, i32) → f32" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_depth_multisampled_2d;
        \\fn f() { let x = textureLoad(t, vec2<i32>(0, 0), 0i); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "f32");
}

// =========================================================================
// textureLoad — external
// =========================================================================

test "textureLoad(texture_external, vec2<i32>) → vec4<f32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_external;
        \\fn f() { let x = textureLoad(t, vec2<i32>(0, 0)); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<f32>");
}

// =========================================================================
// textureLoad — storage textures
// =========================================================================

test "textureLoad(texture_storage_2d<rgba8unorm, read>, vec2<i32>) → vec4<f32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_storage_2d<rgba8unorm, read>;
        \\fn f() { let x = textureLoad(t, vec2<i32>(0, 0)); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<f32>");
}

test "textureLoad(texture_storage_2d<rg32sint, read>, vec2<i32>) → vec4<i32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_storage_2d<rg32sint, read>;
        \\fn f() { let x = textureLoad(t, vec2<i32>(0, 0)); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<i32>");
}

test "textureLoad(texture_storage_2d<r32uint, read_write>, vec2<i32>) → vec4<u32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_storage_2d<r32uint, read_write>;
        \\fn f() { let x = textureLoad(t, vec2<i32>(0, 0)); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<u32>");
}

test "textureLoad(texture_storage_3d<rgba8unorm, read>, vec3<i32>) → vec4<f32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_storage_3d<rgba8unorm, read>;
        \\fn f() { let x = textureLoad(t, vec3<i32>(0, 0, 0)); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<f32>");
}

// =========================================================================
// textureLoad — rejections
// =========================================================================

test "textureLoad rejects float coord (E0203)" {
    var r = try validate(
        \\@group(0) @binding(0) var t: texture_2d<f32>;
        \\fn f() { let x = textureLoad(t, vec2<f32>(0.0, 0.0), 0i); }
    );
    defer r.deinit();
    try std.testing.expect(hasErrorWithCode(r, "E0203"));
}

test "textureLoad rejects wrong-dim coord (vec3 on texture_2d)" {
    var r = try validate(
        \\@group(0) @binding(0) var t: texture_2d<f32>;
        \\fn f() { let x = textureLoad(t, vec3<i32>(0, 0, 0), 0i); }
    );
    defer r.deinit();
    try std.testing.expect(anyError(r));
}

test "textureLoad rejects missing level arg" {
    var r = try validate(
        \\@group(0) @binding(0) var t: texture_2d<f32>;
        \\fn f() { let x = textureLoad(t, vec2<i32>(0, 0)); }
    );
    defer r.deinit();
    try std.testing.expect(anyError(r));
}

test "textureLoad(texture_storage_2d<_, write>) rejected by side-check" {
    // The storage-access side-validation fires BEFORE overload resolution
    // and must produce the human-readable access-mode message rather than
    // a generic "no matching overload". The exact quoting is pinned by
    // the `addErrorWithCodeR` call at `Validator.zig` (textureLoad side
    // check — requires 'read' or 'read_write' on storage textures).
    var r = try validate(
        \\@group(0) @binding(0) var t: texture_storage_2d<rgba8unorm, write>;
        \\fn f() { let x = textureLoad(t, vec2<i32>(0, 0)); }
    );
    defer r.deinit();
    try std.testing.expect(hasErrorWithCode(r, "E0203"));
    try std.testing.expect(hasErrorContaining(r, "storage texture"));
    try std.testing.expect(hasErrorContaining(r, "'read_write'"));
}

test "textureLoad diagnostic includes rendered texture type" {
    // Passing a non-texture arg must produce a readable diagnostic —
    // verifies the Texture.string() renderer doesn't regress other types.
    var r = try validate(
        \\fn f() { let x = textureLoad(vec4<f32>(0.0), vec2<i32>(0, 0), 0i); }
    );
    defer r.deinit();
    try std.testing.expect(hasErrorWithCode(r, "E0203"));
    try std.testing.expect(hasErrorContaining(r, "vec4<f32>"));
}

// =========================================================================
// textureStore
// =========================================================================

test "textureStore(texture_storage_2d<rgba8unorm, write>, vec2<i32>, vec4<f32>) accepted" {
    var r = try validate(
        \\@group(0) @binding(0) var t: texture_storage_2d<rgba8unorm, write>;
        \\fn f() { textureStore(t, vec2<i32>(0, 0), vec4<f32>(1.0)); }
    );
    defer r.deinit();
    try std.testing.expect(!anyError(r));
}

test "textureStore(texture_storage_3d, vec3<i32>, vec4<f32>) accepted" {
    var r = try validate(
        \\@group(0) @binding(0) var t: texture_storage_3d<rgba8unorm, write>;
        \\fn f() { textureStore(t, vec3<i32>(0, 0, 0), vec4<f32>(1.0)); }
    );
    defer r.deinit();
    try std.testing.expect(!anyError(r));
}

test "textureStore(texture_storage_2d_array, vec2<i32>, i32, vec4<f32>) accepted" {
    var r = try validate(
        \\@group(0) @binding(0) var t: texture_storage_2d_array<rgba8unorm, write>;
        \\fn f() { textureStore(t, vec2<i32>(0, 0), 0i, vec4<f32>(1.0)); }
    );
    defer r.deinit();
    try std.testing.expect(!anyError(r));
}

test "textureStore value element must match texel-format channel" {
    // rg32sint is an integer format → vec4<i32>, passing vec4<f32> fails.
    var r = try validate(
        \\@group(0) @binding(0) var t: texture_storage_2d<rg32sint, write>;
        \\fn f() { textureStore(t, vec2<i32>(0, 0), vec4<f32>(1.0)); }
    );
    defer r.deinit();
    try std.testing.expect(hasErrorWithCode(r, "E0203"));
}

test "textureStore on read-only storage rejected by side-check" {
    var r = try validate(
        \\@group(0) @binding(0) var t: texture_storage_2d<rgba8unorm, read>;
        \\fn f() { textureStore(t, vec2<i32>(0, 0), vec4<f32>(1.0)); }
    );
    defer r.deinit();
    try std.testing.expect(hasErrorWithCode(r, "E0203"));
    try std.testing.expect(hasErrorContaining(r, "write"));
}

// =========================================================================
// textureDimensions
// =========================================================================

test "textureDimensions(texture_1d) → u32" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_1d<f32>;
        \\fn f() { let x = textureDimensions(t); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "u32");
}

test "textureDimensions(texture_2d) → vec2<u32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_2d<f32>;
        \\fn f() { let x = textureDimensions(t); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec2<u32>");
}

test "textureDimensions(texture_3d) → vec3<u32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_3d<f32>;
        \\fn f() { let x = textureDimensions(t); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec3<u32>");
}

test "textureDimensions(texture_cube) → vec2<u32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_cube<f32>;
        \\fn f() { let x = textureDimensions(t); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec2<u32>");
}

test "textureDimensions(texture_depth_cube) → vec2<u32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_depth_cube;
        \\fn f() { let x = textureDimensions(t); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec2<u32>");
}

test "textureDimensions(texture_2d, level) → vec2<u32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_2d<f32>;
        \\fn f() { let x = textureDimensions(t, 0i); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec2<u32>");
}

test "textureDimensions(texture_storage_2d<_, write>) → vec2<u32>" {
    // textureDimensions works on write-only storage; no read access needed.
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_storage_2d<rgba8unorm, write>;
        \\fn f() { let x = textureDimensions(t); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec2<u32>");
}

test "textureDimensions(texture_external) → vec2<u32>" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_external;
        \\fn f() { let x = textureDimensions(t); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec2<u32>");
}

test "textureDimensions(texture_multisampled_2d, level) rejected — no level arg" {
    var r = try validate(
        \\@group(0) @binding(0) var t: texture_multisampled_2d<f32>;
        \\fn f() { let x = textureDimensions(t, 0i); }
    );
    defer r.deinit();
    try std.testing.expect(anyError(r));
}

test "textureDimensions(texture_storage_2d, level) rejected — no level arg" {
    var r = try validate(
        \\@group(0) @binding(0) var t: texture_storage_2d<rgba8unorm, read>;
        \\fn f() { let x = textureDimensions(t, 0i); }
    );
    defer r.deinit();
    try std.testing.expect(anyError(r));
}

// =========================================================================
// textureNumLayers / Levels / Samples
// =========================================================================

test "textureNumLayers(texture_2d_array<f32>) → u32" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_2d_array<f32>;
        \\fn f() { let x = textureNumLayers(t); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "u32");
}

test "textureNumLayers(texture_cube_array<f32>) → u32" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_cube_array<f32>;
        \\fn f() { let x = textureNumLayers(t); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "u32");
}

test "textureNumLayers(texture_2d<f32>) rejected — not array-capable" {
    var r = try validate(
        \\@group(0) @binding(0) var t: texture_2d<f32>;
        \\fn f() { let x = textureNumLayers(t); }
    );
    defer r.deinit();
    try std.testing.expect(anyError(r));
}

test "textureNumLevels(texture_2d<f32>) → u32" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_2d<f32>;
        \\fn f() { let x = textureNumLevels(t); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "u32");
}

test "textureNumLevels(texture_multisampled_2d<f32>) rejected — not mippable" {
    var r = try validate(
        \\@group(0) @binding(0) var t: texture_multisampled_2d<f32>;
        \\fn f() { let x = textureNumLevels(t); }
    );
    defer r.deinit();
    try std.testing.expect(anyError(r));
}

test "textureNumLevels(texture_storage_2d) rejected — storage not mippable" {
    var r = try validate(
        \\@group(0) @binding(0) var t: texture_storage_2d<rgba8unorm, read>;
        \\fn f() { let x = textureNumLevels(t); }
    );
    defer r.deinit();
    try std.testing.expect(anyError(r));
}

test "textureNumSamples(texture_multisampled_2d<f32>) → u32" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_multisampled_2d<f32>;
        \\fn f() { let x = textureNumSamples(t); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "u32");
}

test "textureNumSamples(texture_depth_multisampled_2d) → u32" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_depth_multisampled_2d;
        \\fn f() { let x = textureNumSamples(t); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "u32");
}

test "textureNumSamples(texture_2d<f32>) rejected — not multisampled" {
    var r = try validate(
        \\@group(0) @binding(0) var t: texture_2d<f32>;
        \\fn f() { let x = textureNumSamples(t); }
    );
    defer r.deinit();
    try std.testing.expect(anyError(r));
}
