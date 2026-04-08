//! compute.toys integration tests — ported from Go's compute_toys_test.go.
//! Tests that the compute.toys config correctly preserves platform-specific
//! names (uniforms, textures, samplers, helpers) while renaming local variables.

const std = @import("std");
const wgslender = @import("wgslender");

// =========================================================================
// Helpers
// =========================================================================

const compute_toys_keep_names: []const []const u8 = &.{
    "time",                          "mouse",          "custom",    "dispatch",
    "screen",                        "pass_in",        "pass_out",  "channel0",
    "channel1",                      "nearest",        "bilinear",  "trilinear",
    "nearest_repeat",                "bilinear_repeat", "trilinear_repeat",
    "_keyboard",                     "Time",           "Mouse",     "Custom",
    "DispatchInfo",                  "int",            "uint",      "float",
    "int2",                          "int3",           "int4",      "uint2",
    "uint3",                         "uint4",          "float2",    "float3",
    "float4",                        "bool2",          "bool3",     "bool4",
    "float2x2",                      "float2x3",       "float2x4",
    "float3x2",                      "float3x3",       "float3x4",
    "float4x2",                      "float4x3",       "float4x4",
    "keyDown",                       "assert",         "passStore", "passLoad",
    "passSampleLevelBilinearRepeat", "main_image",
};

fn computeToysOptions() wgslender.Minifier.Options {
    return .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
        .mangle_external_bindings = false,
        .tree_shaking = true,
        .keep_names = compute_toys_keep_names,
    };
}

fn computeToys(allocator: std.mem.Allocator, input: [:0]const u8) ![]const u8 {
    const r = try wgslender.minifyWithOptions(allocator, input, computeToysOptions());
    return r.code;
}

// =========================================================================
// compute.toys: preserves time uniform
// =========================================================================

test "compute.toys: preserves time uniform" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try computeToys(arena.allocator(),
        \\@compute @workgroup_size(16, 16)
        \\fn main_image(@builtin(global_invocation_id) id: vec3u) {
        \\    let t = time.elapsed;
        \\    let d = time.delta;
        \\    let f = time.frame;
        \\}
    );
    try std.testing.expect(std.mem.indexOf(u8, result, "time.elapsed") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "time.delta") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "time.frame") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "main_image") != null);
}

// =========================================================================
// compute.toys: preserves mouse uniform
// =========================================================================

test "compute.toys: preserves mouse uniform" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try computeToys(arena.allocator(),
        \\@compute @workgroup_size(16, 16)
        \\fn main_image(@builtin(global_invocation_id) id: vec3u) {
        \\    let p = mouse.pos;
        \\    let z = mouse.zoom;
        \\    let c = mouse.click;
        \\    let s = mouse.start;
        \\    let d = mouse.delta;
        \\}
    );
    try std.testing.expect(std.mem.indexOf(u8, result, "mouse.pos") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "mouse.zoom") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "mouse.click") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "mouse.start") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "mouse.delta") != null);
}

// =========================================================================
// compute.toys: preserves texture bindings
// =========================================================================

test "compute.toys: preserves texture bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try computeToys(arena.allocator(),
        \\@compute @workgroup_size(16, 16)
        \\fn main_image(@builtin(global_invocation_id) id: vec3u) {
        \\    let size = textureDimensions(screen);
        \\    textureStore(screen, id.xy, vec4f(1.0));
        \\    let p = passLoad(0, vec2i(0), 0);
        \\    passStore(0, vec2i(0), vec4f(1.0));
        \\    let c0 = textureSampleLevel(channel0, bilinear, vec2f(0.5), 0.0);
        \\    let c1 = textureSampleLevel(channel1, trilinear, vec2f(0.5), 0.0);
        \\}
    );
    try std.testing.expect(std.mem.indexOf(u8, result, "screen") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "passLoad") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "passStore") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "channel0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "channel1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "bilinear") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "trilinear") != null);
}

// =========================================================================
// compute.toys: preserves samplers
// =========================================================================

test "compute.toys: preserves samplers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try computeToys(arena.allocator(),
        \\@compute @workgroup_size(16, 16)
        \\fn main_image(@builtin(global_invocation_id) id: vec3u) {
        \\    let a = textureSampleLevel(channel0, nearest, vec2f(0.5), 0.0);
        \\    let b = textureSampleLevel(channel0, bilinear, vec2f(0.5), 0.0);
        \\    let c = textureSampleLevel(channel0, trilinear, vec2f(0.5), 0.0);
        \\    let d = textureSampleLevel(channel0, nearest_repeat, vec2f(0.5), 0.0);
        \\    let e = textureSampleLevel(channel0, bilinear_repeat, vec2f(0.5), 0.0);
        \\    let f = textureSampleLevel(channel0, trilinear_repeat, vec2f(0.5), 0.0);
        \\}
    );
    try std.testing.expect(std.mem.indexOf(u8, result, "nearest") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "bilinear") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "trilinear") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "nearest_repeat") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "bilinear_repeat") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "trilinear_repeat") != null);
}

// =========================================================================
// compute.toys: preserves keyDown helper
// =========================================================================

test "compute.toys: preserves keyDown helper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try computeToys(arena.allocator(),
        \\@compute @workgroup_size(16, 16)
        \\fn main_image(@builtin(global_invocation_id) id: vec3u) {
        \\    if (keyDown(32u)) {
        \\        textureStore(screen, id.xy, vec4f(1.0));
        \\    }
        \\}
    );
    try std.testing.expect(std.mem.indexOf(u8, result, "keyDown") != null);
}

// =========================================================================
// compute.toys: renames local variables
// =========================================================================

test "compute.toys: renames local variables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try computeToys(arena.allocator(),
        \\fn myHelperFunction(inputValue: f32) -> f32 {
        \\    let intermediateResult = inputValue * 2.0;
        \\    let finalResult = intermediateResult + 1.0;
        \\    return finalResult;
        \\}
        \\
        \\@compute @workgroup_size(16, 16)
        \\fn main_image(@builtin(global_invocation_id) invocationId: vec3u) {
        \\    let computedValue = myHelperFunction(time.elapsed);
        \\    let screenSize = textureDimensions(screen);
        \\    textureStore(screen, vec2i(invocationId.xy), vec4f(computedValue, screenSize.x, 0.0, 1.0));
        \\}
    );
    // Preserved names must appear
    try std.testing.expect(std.mem.indexOf(u8, result, "time.elapsed") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "main_image") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "screen") != null);
    // Local/helper names must NOT appear (they should be renamed)
    try std.testing.expect(std.mem.indexOf(u8, result, "myHelperFunction") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "inputValue") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "intermediateResult") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "finalResult") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "computedValue") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "invocationId") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "screenSize") == null);
}

// =========================================================================
// compute.toys: preserves type aliases
// =========================================================================

test "compute.toys: preserves type aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try computeToys(arena.allocator(),
        \\fn useAliases() -> float4 {
        \\    let a: int = 1;
        \\    let b: uint = 2u;
        \\    let c: float = 3.0;
        \\    let d: float2 = vec2f(1.0, 2.0);
        \\    let e: float3 = vec3f(1.0);
        \\    let f: float4 = vec4f(1.0);
        \\    return f;
        \\}
        \\
        \\@compute @workgroup_size(16, 16)
        \\fn main_image(@builtin(global_invocation_id) id: vec3u) {
        \\    let result = useAliases();
        \\}
    );
    try std.testing.expect(std.mem.indexOf(u8, result, "int") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "uint") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "float") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "float2") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "float3") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "float4") != null);
}

// =========================================================================
// compute.toys: preserves pass buffer helpers
// =========================================================================

test "compute.toys: preserves pass buffer helpers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try computeToys(arena.allocator(),
        \\@compute @workgroup_size(16, 16)
        \\fn main_image(@builtin(global_invocation_id) id: vec3u) {
        \\    let prev = passLoad(0, vec2i(id.xy), 0);
        \\    passStore(0, vec2i(id.xy), prev * 0.99);
        \\    let sampled = passSampleLevelBilinearRepeat(0, vec2f(0.5), 0.0);
        \\}
    );
    try std.testing.expect(std.mem.indexOf(u8, result, "passLoad") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "passStore") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "passSampleLevelBilinearRepeat") != null);
}

// =========================================================================
// compute.toys: struct type renaming
// =========================================================================

fn fullMinify(allocator: std.mem.Allocator, input: [:0]const u8) ![]const u8 {
    const r = try wgslender.minifyWithOptions(allocator, input, .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
    });
    return r.code;
}

test "compute.toys: struct type renaming - function parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try fullMinify(arena.allocator(),
        \\struct MyStruct { x: f32 }
        \\fn doSomething(s: MyStruct) -> f32 {
        \\    return s.x;
        \\}
    );
    try std.testing.expect(std.mem.indexOf(u8, result, "MyStruct") == null);
}

test "compute.toys: struct type renaming - return type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try fullMinify(arena.allocator(),
        \\struct MyStruct { x: f32 }
        \\fn createStruct() -> MyStruct {
        \\    return MyStruct(1.0);
        \\}
    );
    try std.testing.expect(std.mem.indexOf(u8, result, "MyStruct") == null);
}

test "compute.toys: struct type renaming - var declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try fullMinify(arena.allocator(),
        \\struct MyStruct { x: f32 }
        \\fn test() {
        \\    var s: MyStruct;
        \\    s.x = 1.0;
        \\}
    );
    try std.testing.expect(std.mem.indexOf(u8, result, "MyStruct") == null);
}

test "compute.toys: struct type renaming - let declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try fullMinify(arena.allocator(),
        \\struct MyStruct { x: f32 }
        \\fn test() {
        \\    let s: MyStruct = MyStruct(1.0);
        \\}
    );
    try std.testing.expect(std.mem.indexOf(u8, result, "MyStruct") == null);
}

test "compute.toys: struct type renaming - multiple usages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try fullMinify(arena.allocator(),
        \\struct Transform2D {
        \\    pos: vec2f,
        \\    scale: vec2f,
        \\}
        \\fn transform(uv: vec2f, t: Transform2D) -> vec2f {
        \\    return (uv - t.pos) / t.scale;
        \\}
        \\fn createTransform() -> Transform2D {
        \\    return Transform2D(vec2f(0.0), vec2f(1.0));
        \\}
    );
    try std.testing.expect(std.mem.indexOf(u8, result, "Transform2D") == null);
}

// =========================================================================
// compute.toys: preserves dispatch info
// =========================================================================

test "compute.toys: preserves dispatch info" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try computeToys(arena.allocator(),
        \\@compute @workgroup_size(16, 16)
        \\fn main_image(@builtin(global_invocation_id) id: vec3u) {
        \\    let dispatchId = dispatch.id;
        \\}
    );
    try std.testing.expect(std.mem.indexOf(u8, result, "dispatch.id") != null);
}

// =========================================================================
// compute.toys: per-file size reduction
// =========================================================================

fn expectSizeReduction(allocator: std.mem.Allocator, source_bytes: []const u8) !void {
    const buf = try allocator.alloc(u8, source_bytes.len + 1);
    @memcpy(buf[0..source_bytes.len], source_bytes);
    buf[source_bytes.len] = 0;
    const source = buf[0..source_bytes.len :0];

    const r = try wgslender.minifyWithOptions(allocator, source, computeToysOptions());
    try std.testing.expectEqual(@as(usize, 0), r.errors.len);
    try std.testing.expect(r.minified_size < r.original_size);
}

test "compute.toys: size reduction circle_sample.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectSizeReduction(arena.allocator(), @import("semantic_data").ct_circle_sample);
}

test "compute.toys: size reduction bridge.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectSizeReduction(arena.allocator(), @import("semantic_data").ct_bridge);
}

test "compute.toys: size reduction cubes_in_space.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectSizeReduction(arena.allocator(), @import("semantic_data").ct_cubes_in_space);
}

test "compute.toys: size reduction jitter_starfield.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectSizeReduction(arena.allocator(), @import("semantic_data").ct_jitter_starfield);
}

test "compute.toys: size reduction mouse_draw.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectSizeReduction(arena.allocator(), @import("semantic_data").ct_mouse_draw);
}

test "compute.toys: size reduction prelude.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectSizeReduction(arena.allocator(), @import("semantic_data").ct_prelude);
}

test "compute.toys: size reduction spaced.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectSizeReduction(arena.allocator(), @import("semantic_data").ct_spaced);
}
