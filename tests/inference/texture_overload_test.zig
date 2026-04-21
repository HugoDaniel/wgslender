//! Texture builtin return-type inference — WGSL §17.7.
//!
//! Pins that each texture builtin returns the correct scalar/vector
//! type given the sampled texture's element type or the storage
//! texture's texel format. Also pins textureDimensions width per
//! texture dimension and the depth-texture quirks (scalar f32 from
//! sample/load, vec4<f32> from gather).

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

// -------------------------------------------------------------------------
// textureSample — returns vec4<element>.
// -------------------------------------------------------------------------

test "§17.7.14: textureSample on texture_2d<f32> returns vec4<f32>" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var samp: sampler;
        \\@fragment
        \\fn f() -> @location(0) vec4f {
        \\  return textureSample(tex, samp, vec2f(0.0));
        \\}
    , "textureSample f32");
}

test "§17.7.14: textureSample on texture_cube<f32> returns vec4<f32>" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_cube<f32>;
        \\@group(0) @binding(1) var samp: sampler;
        \\@fragment
        \\fn f() -> @location(0) vec4f {
        \\  return textureSample(tex, samp, vec3f(0.0));
        \\}
    , "textureSample cube");
}

// -------------------------------------------------------------------------
// textureSample on depth textures — returns f32.
// -------------------------------------------------------------------------

test "§17.7.14: textureSample on texture_depth_2d returns f32" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_depth_2d;
        \\@group(0) @binding(1) var samp: sampler;
        \\@fragment
        \\fn f() -> @location(0) f32 {
        \\  return textureSample(tex, samp, vec2f(0.0));
        \\}
    , "textureSample depth_2d");
}

test "§17.7.14: textureSample on texture_depth_cube returns f32" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_depth_cube;
        \\@group(0) @binding(1) var samp: sampler;
        \\@fragment
        \\fn f() -> @location(0) f32 {
        \\  return textureSample(tex, samp, vec3f(0.0));
        \\}
    , "textureSample depth_cube");
}

// -------------------------------------------------------------------------
// textureSampleLevel / textureSampleGrad / textureSampleBias.
// -------------------------------------------------------------------------

test "§17.7.17: textureSampleLevel returns vec4<f32>" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var samp: sampler;
        \\fn f() -> vec4f {
        \\  return textureSampleLevel(tex, samp, vec2f(0.0), 0.0);
        \\}
    , "textureSampleLevel f32");
}

test "§17.7.16: textureSampleGrad returns vec4<f32>" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var samp: sampler;
        \\fn f() -> vec4f {
        \\  return textureSampleGrad(tex, samp, vec2f(0.0), vec2f(0.0), vec2f(0.0));
        \\}
    , "textureSampleGrad");
}

test "§17.7.15: textureSampleBias (fragment) returns vec4<f32>" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var samp: sampler;
        \\@fragment
        \\fn f() -> @location(0) vec4f {
        \\  return textureSampleBias(tex, samp, vec2f(0.0), 0.0);
        \\}
    , "textureSampleBias");
}

// -------------------------------------------------------------------------
// textureSampleCompare — always returns f32.
// -------------------------------------------------------------------------

test "§17.7.18: textureSampleCompare on depth returns f32" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_depth_2d;
        \\@group(0) @binding(1) var samp: sampler_comparison;
        \\@fragment
        \\fn f() -> @location(0) f32 {
        \\  return textureSampleCompare(tex, samp, vec2f(0.0), 0.5);
        \\}
    , "textureSampleCompare");
}

test "§17.7.19: textureSampleCompareLevel returns f32" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_depth_2d;
        \\@group(0) @binding(1) var samp: sampler_comparison;
        \\fn f() -> f32 {
        \\  return textureSampleCompareLevel(tex, samp, vec2f(0.0), 0.5);
        \\}
    , "textureSampleCompareLevel");
}

// -------------------------------------------------------------------------
// textureLoad on sampled textures (i32/u32/f32) + depth.
// -------------------------------------------------------------------------

test "§17.7.9: textureLoad on texture_2d<f32> returns vec4<f32>" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\fn f() -> vec4f {
        \\  return textureLoad(tex, vec2i(0, 0), 0);
        \\}
    , "textureLoad f32");
}

test "§17.7.9: textureLoad on texture_2d<i32> returns vec4<i32>" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_2d<i32>;
        \\fn f() -> vec4i {
        \\  return textureLoad(tex, vec2i(0, 0), 0);
        \\}
    , "textureLoad i32");
}

test "§17.7.9: textureLoad on texture_2d<u32> returns vec4<u32>" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_2d<u32>;
        \\fn f() -> vec4u {
        \\  return textureLoad(tex, vec2i(0, 0), 0);
        \\}
    , "textureLoad u32");
}

test "§17.7.9: textureLoad on texture_depth_2d returns f32" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_depth_2d;
        \\fn f() -> f32 {
        \\  return textureLoad(tex, vec2i(0, 0), 0);
        \\}
    , "textureLoad depth_2d");
}

// -------------------------------------------------------------------------
// textureLoad on storage textures.
// -------------------------------------------------------------------------

test "§17.7.9: textureLoad on read-only storage texture_storage_2d<rgba8unorm>" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_storage_2d<rgba8unorm, read>;
        \\fn f() -> vec4f {
        \\  return textureLoad(tex, vec2i(0, 0));
        \\}
    , "textureLoad storage rgba8unorm");
}

test "§17.7.9: textureLoad on texture_storage_2d<r32uint, read> returns vec4<u32>" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_storage_2d<r32uint, read>;
        \\fn f() -> vec4u {
        \\  return textureLoad(tex, vec2i(0, 0));
        \\}
    , "textureLoad storage r32uint");
}

// -------------------------------------------------------------------------
// textureStore — void return.
// -------------------------------------------------------------------------

test "§17.7.13: textureStore on texture_storage_2d<rgba8unorm,write> is void" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_storage_2d<rgba8unorm, write>;
        \\fn f() {
        \\  textureStore(tex, vec2i(0, 0), vec4f(1.0));
        \\}
    , "textureStore");
}

// -------------------------------------------------------------------------
// textureDimensions — returns u32 or vecN<u32>.
// -------------------------------------------------------------------------

test "§17.7.2: textureDimensions on texture_1d returns u32" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_1d<f32>;
        \\fn f() -> u32 {
        \\  return textureDimensions(tex);
        \\}
    , "dims 1d");
}

test "§17.7.2: textureDimensions on texture_2d returns vec2<u32>" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\fn f() -> vec2u {
        \\  return textureDimensions(tex);
        \\}
    , "dims 2d");
}

test "§17.7.2: textureDimensions on texture_3d returns vec3<u32>" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_3d<f32>;
        \\fn f() -> vec3u {
        \\  return textureDimensions(tex);
        \\}
    , "dims 3d");
}

test "§17.7.2: textureDimensions on texture_cube returns vec2<u32>" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_cube<f32>;
        \\fn f() -> vec2u {
        \\  return textureDimensions(tex);
        \\}
    , "dims cube");
}

test "§17.7.2: textureDimensions on texture_2d_array returns vec2<u32>" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_2d_array<f32>;
        \\fn f() -> vec2u {
        \\  return textureDimensions(tex);
        \\}
    , "dims 2d_array");
}

// -------------------------------------------------------------------------
// textureNumLayers / textureNumLevels / textureNumSamples → u32.
// -------------------------------------------------------------------------

test "§17.7.3: textureNumLayers returns u32" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_2d_array<f32>;
        \\fn f() -> u32 {
        \\  return textureNumLayers(tex);
        \\}
    , "numLayers");
}

test "§17.7.4: textureNumLevels returns u32" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\fn f() -> u32 {
        \\  return textureNumLevels(tex);
        \\}
    , "numLevels");
}

test "§17.7.5: textureNumSamples returns u32" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_multisampled_2d<f32>;
        \\fn f() -> u32 {
        \\  return textureNumSamples(tex);
        \\}
    , "numSamples");
}

// -------------------------------------------------------------------------
// textureGather / textureGatherCompare.
// -------------------------------------------------------------------------

test "§17.7.6: textureGather on texture_2d<f32> returns vec4<f32>" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var samp: sampler;
        \\@fragment
        \\fn f() -> @location(0) vec4f {
        \\  return textureGather(0, tex, samp, vec2f(0.0));
        \\}
    , "textureGather f32");
}

test "§17.7.6: textureGather on texture_depth_2d returns vec4<f32>" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_depth_2d;
        \\@group(0) @binding(1) var samp: sampler;
        \\@fragment
        \\fn f() -> @location(0) vec4f {
        \\  return textureGather(tex, samp, vec2f(0.0));
        \\}
    , "textureGather depth_2d");
}

test "§17.7.7: textureGatherCompare returns vec4<f32>" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_depth_2d;
        \\@group(0) @binding(1) var samp: sampler_comparison;
        \\@fragment
        \\fn f() -> @location(0) vec4f {
        \\  return textureGatherCompare(tex, samp, vec2f(0.0), 0.5);
        \\}
    , "textureGatherCompare");
}

// -------------------------------------------------------------------------
// textureSampleBaseClampToEdge — external textures.
// -------------------------------------------------------------------------

test "§17.7.14: textureSampleBaseClampToEdge on texture_external returns vec4<f32>" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_external;
        \\@group(0) @binding(1) var samp: sampler;
        \\@fragment
        \\fn f() -> @location(0) vec4f {
        \\  return textureSampleBaseClampToEdge(tex, samp, vec2f(0.0));
        \\}
    , "textureSampleBaseClampToEdge");
}

// -------------------------------------------------------------------------
// Arity errors.
// -------------------------------------------------------------------------

test "§17.7: textureSample without enough args rejected" {
    var r = try validate(
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\fn f() -> vec4f {
        \\  return textureSample(tex);
        \\}
    );
    defer r.deinit(std.testing.allocator);
    var saw = false;
    for (r.diagnostics.items()) |d| {
        if (std.mem.indexOf(u8, d.message, "textureSample") != null) saw = true;
    }
    if (!saw) {
        dump("expected arity / arg error on textureSample", r);
        return error.TestUnexpectedResult;
    }
}

// -------------------------------------------------------------------------
// Storage-texture access mode enforcement — §17.7.11 / §17.7.13.
// textureLoad requires read/read_write; textureStore requires write/read_write.
// -------------------------------------------------------------------------

fn hasMessage(r: wgslender.Validator.Result, needle: []const u8) bool {
    for (r.diagnostics.items()) |d| {
        if (d.severity != .@"error") continue;
        if (std.mem.indexOf(u8, d.message, needle) != null) return true;
    }
    return false;
}

test "§17.7.11: textureStore on read-only storage rejected" {
    var r = try validate(
        \\@group(0) @binding(0) var tex: texture_storage_2d<rgba8unorm, read>;
        \\fn f() {
        \\  textureStore(tex, vec2<i32>(0), vec4f(0.0));
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (!hasMessage(r, "textureStore")) {
        dump("expected textureStore access error on read-only storage", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.7.11: textureStore on write storage valid" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_storage_2d<rgba8unorm, write>;
        \\fn f() {
        \\  textureStore(tex, vec2<i32>(0), vec4f(0.0));
        \\}
    , "textureStore write storage");
}

test "§17.7.11: textureStore on read_write storage valid" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_storage_2d<rgba8unorm, read_write>;
        \\fn f() {
        \\  textureStore(tex, vec2<i32>(0), vec4f(0.0));
        \\}
    , "textureStore read_write storage");
}

test "§17.7.13: textureLoad on write-only storage rejected" {
    var r = try validate(
        \\@group(0) @binding(0) var tex: texture_storage_2d<rgba8unorm, write>;
        \\fn f() -> vec4f {
        \\  return textureLoad(tex, vec2<i32>(0));
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (!hasMessage(r, "textureLoad")) {
        dump("expected textureLoad access error on write-only storage", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.7.13: textureLoad on read storage valid" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_storage_2d<rgba8unorm, read>;
        \\fn f() -> vec4f {
        \\  return textureLoad(tex, vec2<i32>(0));
        \\}
    , "textureLoad read storage");
}

test "§17.7.13: textureLoad on read_write storage valid" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_storage_2d<rgba8unorm, read_write>;
        \\fn f() -> vec4f {
        \\  return textureLoad(tex, vec2<i32>(0));
        \\}
    , "textureLoad read_write storage");
}

test "§17.7.13: textureLoad on sampled texture unaffected (no access mode)" {
    try validMustPass(
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\fn f() -> vec4f {
        \\  return textureLoad(tex, vec2<i32>(0), 0);
        \\}
    , "textureLoad on sampled texture");
}
