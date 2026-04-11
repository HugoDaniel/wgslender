//! Determinism / reproducibility tests.
//!
//! Verifies that repeated runs of each pipeline operation produce
//! byte-identical output. Catches nondeterminism from hash map iteration
//! order, allocation patterns, or other sources.

const std = @import("std");
const wgslender = @import("wgslender");

// A complex shader that exercises all pipeline stages: structs, bindings,
// multiple functions, dead code, constants, various expression types.
const complex_shader: [:0]const u8 =
    \\struct Params {
    \\  time: f32,
    \\  resolution: vec2f,
    \\  frame: u32,
    \\}
    \\
    \\struct Vertex {
    \\  @builtin(position) pos: vec4f,
    \\  @location(0) uv: vec2f,
    \\}
    \\
    \\@group(0) @binding(0) var<uniform> params: Params;
    \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
    \\@group(0) @binding(2) var tex: texture_2d<f32>;
    \\@group(0) @binding(3) var samp: sampler;
    \\
    \\const PI = 3.14159265;
    \\const TWO_PI = PI * 2.0;
    \\
    \\fn helper(x: f32, y: f32) -> f32 {
    \\  return sqrt(x * x + y * y);
    \\}
    \\
    \\fn unused_fn() -> f32 {
    \\  return 42.0;
    \\}
    \\
    \\fn transform(v: vec2f) -> vec2f {
    \\  let angle = atan2(v.y, v.x);
    \\  let r = helper(v.x, v.y);
    \\  return vec2f(cos(angle + params.time) * r, sin(angle + params.time) * r);
    \\}
    \\
    \\@compute @workgroup_size(8, 8)
    \\fn main(@builtin(global_invocation_id) id: vec3u) {
    \\  let idx = id.x + id.y * u32(params.resolution.x);
    \\  let uv = vec2f(f32(id.x), f32(id.y)) / params.resolution;
    \\  let t = transform(uv - 0.5);
    \\  let dist = helper(t.x, t.y);
    \\  let value = sin(dist * TWO_PI + params.time);
    \\  output[idx] = value;
    \\}
;

const runs = 10;

// =========================================================================
// Minify determinism
// =========================================================================

fn runMinifyDeterminism(options: wgslender.Minifier.Options) !void {
    const a = std.testing.allocator;
    var reference: ?[]const u8 = null;
    var ref_buf: [8192]u8 = undefined;

    for (0..runs) |_| {
        var result = try wgslender.minifyWithOptions(a, complex_shader, options);
        defer result.deinit(a);

        if (reference) |ref| {
            try std.testing.expectEqualStrings(ref, result.code);
        } else {
            // Copy reference to stack buffer so it survives result.deinit
            @memcpy(ref_buf[0..result.code.len], result.code);
            reference = ref_buf[0..result.code.len];
        }
    }
}

test "determinism: minify default options" {
    try runMinifyDeterminism(.{});
}

test "determinism: minify with identifier renaming" {
    try runMinifyDeterminism(.{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
    });
}

test "determinism: minify with sort+scope-local rename" {
    try runMinifyDeterminism(.{
        .sort_declarations = true,
        .scope_local_rename = true,
    });
}

test "determinism: minify with tree shaking" {
    try runMinifyDeterminism(.{
        .tree_shaking = true,
    });
}

// =========================================================================
// Source map determinism
// =========================================================================

test "determinism: minify with source map" {
    const a = std.testing.allocator;
    var ref_code: ?[]const u8 = null;
    var ref_mappings: ?[]const u8 = null;
    var code_buf: [8192]u8 = undefined;
    var map_buf: [8192]u8 = undefined;

    for (0..runs) |_| {
        var result = try wgslender.minifyWithOptions(a, complex_shader, .{
            .generate_source_map = true,
        });
        defer result.deinit(a);

        if (ref_code) |rc| {
            try std.testing.expectEqualStrings(rc, result.code);
            if (result.source_map) |sm| {
                try std.testing.expectEqualStrings(ref_mappings.?, sm.mappings);
            }
        } else {
            @memcpy(code_buf[0..result.code.len], result.code);
            ref_code = code_buf[0..result.code.len];
            if (result.source_map) |sm| {
                @memcpy(map_buf[0..sm.mappings.len], sm.mappings);
                ref_mappings = map_buf[0..sm.mappings.len];
            }
        }
    }
}

// =========================================================================
// Validate determinism
// =========================================================================

test "determinism: validate" {
    const a = std.testing.allocator;
    var ref_valid: ?bool = null;

    for (0..runs) |_| {
        var result = try wgslender.validateWithOptions(a, complex_shader, .{});
        defer result.deinit(a);

        if (ref_valid) |rv| {
            try std.testing.expectEqual(rv, result.valid);
        } else {
            ref_valid = result.valid;
        }
    }
}

// =========================================================================
// Reflect determinism
// =========================================================================

test "determinism: reflect" {
    const a = std.testing.allocator;
    var ref_bindings: ?usize = null;
    var ref_entries: ?usize = null;

    for (0..runs) |_| {
        var result = try wgslender.reflect(a, complex_shader);
        defer result.deinit(a);

        if (ref_bindings) |rb| {
            try std.testing.expectEqual(rb, result.bindings.items.len);
            try std.testing.expectEqual(ref_entries.?, result.entry_points.items.len);
        } else {
            ref_bindings = result.bindings.items.len;
            ref_entries = result.entry_points.items.len;
        }
    }
}

// =========================================================================
// Compile determinism
// =========================================================================

test "determinism: compile produces identical WASM" {
    const a = std.testing.allocator;
    var ref_wasm: ?[]const u8 = null;
    var wasm_buf: [16384]u8 = undefined;

    for (0..runs) |_| {
        var result = wgslender.Compiler.compile(a, complex_shader, .{}) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer result.deinit(a);

        if (ref_wasm) |rw| {
            try std.testing.expectEqualSlices(u8, rw, result.wasm);
        } else {
            @memcpy(wasm_buf[0..result.wasm.len], result.wasm);
            ref_wasm = wasm_buf[0..result.wasm.len];
        }
    }
}
