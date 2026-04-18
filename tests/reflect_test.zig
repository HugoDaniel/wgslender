//! Reflect tests.
//! Tests the combined minification and reflection functionality.

const std = @import("std");
const wgslender = @import("wgslender");

// =========================================================================
// TestMinifyAndReflect
// =========================================================================

test "reflect: minify and reflect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source: [:0]const u8 =
        \\struct Uniforms {
        \\    time: f32,
        \\    resolution: vec2f,
        \\}
        \\
        \\@group(0) @binding(0) var<uniform> uniforms: Uniforms;
        \\@group(0) @binding(1) var texSampler: sampler;
        \\@group(0) @binding(2) var texture: texture_2d<f32>;
        \\
        \\@fragment
        \\fn main(@location(0) uv: vec2f) -> @location(0) vec4f {
        \\    let t = uniforms.time;
        \\    return textureSample(texture, texSampler, uv);
        \\}
    ;

    // Minify
    const result = try wgslender.minifyWithOptions(allocator, source, .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = false,
        .tree_shaking = false,
    });

    // Check that minification worked
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
    try std.testing.expect(result.code.len > 0);
    try std.testing.expect(result.minified_size < result.original_size);

    // Reflect on the original source
    const reflect_result = try wgslender.reflect(allocator, source);

    // Check that reflection worked
    try std.testing.expect(reflect_result.bindings.items.len > 0);
    try std.testing.expect(reflect_result.entry_points.items.len > 0);

    // Check for the uniforms binding
    var found_uniforms = false;
    for (reflect_result.bindings.items) |b| {
        if (std.mem.eql(u8, b.name, "uniforms")) {
            found_uniforms = true;
            try std.testing.expectEqual(@as(i32, 0), b.group);
            try std.testing.expectEqual(@as(i32, 0), b.binding);
        }
    }
    try std.testing.expect(found_uniforms);

    // Check for entry point
    var found_main = false;
    for (reflect_result.entry_points.items) |ep| {
        if (std.mem.eql(u8, ep.name, "main")) {
            found_main = true;
            try std.testing.expectEqualStrings("fragment", ep.stage);
        }
    }
    try std.testing.expect(found_main);
}

// =========================================================================
// TestMinifyAndReflectCombined — uses minifyAndReflect for shared renamer
// =========================================================================

test "reflect: minify and reflect combined" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source: [:0]const u8 =
        \\struct Uniforms {
        \\    time: f32,
        \\    resolution: vec2f,
        \\}
        \\
        \\@group(0) @binding(0) var<uniform> uniforms: Uniforms;
        \\@group(0) @binding(1) var texSampler: sampler;
        \\
        \\@fragment
        \\fn main(@location(0) uv: vec2f) -> @location(0) vec4f {
        \\    let t = uniforms.time;
        \\    return vec4f(t, 0.0, 0.0, 1.0);
        \\}
    ;

    const result = try wgslender.minifyAndReflect(allocator, source, .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = false,
        .tree_shaking = false,
    });

    // Minification should succeed
    try std.testing.expectEqual(@as(usize, 0), result.minify.errors.len);
    try std.testing.expect(result.minify.code.len > 0);
    try std.testing.expect(result.minify.minified_size < result.minify.original_size);

    // Reflection should have bindings with mapped names
    try std.testing.expect(result.reflect.bindings.items.len >= 2);
    try std.testing.expect(result.reflect.entry_points.items.len > 0);

    // The uniforms binding should have original name "uniforms" but a mapped name
    // that differs (since identifiers are minified). The mapped name should appear
    // in the minified code.
    for (result.reflect.bindings.items) |b| {
        if (b.group == 0 and b.binding == 0) {
            try std.testing.expectEqualStrings("uniforms", b.name);
            // name_mapped should appear in the minified output
            try std.testing.expect(std.mem.indexOf(u8, result.minify.code, b.name_mapped) != null);
        }
    }

    // Entry point "main" keeps its name (entry points are not renamed)
    var found_main = false;
    for (result.reflect.entry_points.items) |ep| {
        if (std.mem.eql(u8, ep.name, "main")) {
            found_main = true;
        }
    }
    try std.testing.expect(found_main);
}

// =========================================================================
// TestMinifyAndReflectCombinedParseError
// =========================================================================

test "reflect: minify and reflect combined parse error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source: [:0]const u8 = "fn invalid( { }";

    const result = try wgslender.minifyAndReflect(allocator, source, wgslender.Minifier.defaultOptions());
    try std.testing.expect(result.minify.errors.len > 0);
    try std.testing.expect(result.reflect.errors.items.len > 0);
}

// =========================================================================
// TestMinifyAndReflectParseError
// =========================================================================

test "reflect: minify and reflect parse error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source: [:0]const u8 = "fn invalid( { }";

    // Minify should return errors
    const result = try wgslender.minifyWithOptions(allocator, source, wgslender.Minifier.defaultOptions());
    try std.testing.expect(result.errors.len > 0);
}

// =========================================================================
// TestMinifyAndReflectWithTreeShaking
// =========================================================================

test "reflect: minify and reflect with tree shaking" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source: [:0]const u8 =
        \\fn unused() -> i32 {
        \\    return 42;
        \\}
        \\
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\}
    ;

    // Minify with tree shaking
    const result = try wgslender.minifyWithOptions(allocator, source, .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = false,
        .tree_shaking = true,
    });

    try std.testing.expectEqual(@as(usize, 0), result.errors.len);

    // unused function should be eliminated
    try std.testing.expect(result.symbols_dead > 0);

    // Reflect original, find entry point "main"
    const reflect_result = try wgslender.reflect(allocator, source);

    var found_main = false;
    for (reflect_result.entry_points.items) |ep| {
        if (std.mem.eql(u8, ep.name, "main")) {
            found_main = true;
        }
    }
    try std.testing.expect(found_main);
}

// =========================================================================
// TestMinifyAndReflectStructLayout
// =========================================================================

test "reflect: minify and reflect struct layout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source: [:0]const u8 =
        \\struct MyStruct {
        \\    a: f32,
        \\    b: vec3f,
        \\    c: mat4x4f,
        \\}
        \\
        \\@group(0) @binding(0) var<uniform> data: MyStruct;
        \\
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\    let x = data.a;
        \\}
    ;

    // Minify
    const result = try wgslender.minifyWithOptions(allocator, source, .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = false,
        .tree_shaking = false,
    });

    try std.testing.expectEqual(@as(usize, 0), result.errors.len);

    // Reflect original
    const reflect_result = try wgslender.reflect(allocator, source);

    // Check struct layout is included
    try std.testing.expect(reflect_result.structs.count() > 0);

    // Find a struct with 3 fields
    var found_struct = false;
    var iter = reflect_result.structs.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.fields.items.len == 3) {
            found_struct = true;
            // Check first field name is "a"
            try std.testing.expectEqualStrings("a", entry.value_ptr.fields.items[0].name);
        }
    }
    try std.testing.expect(found_struct);
}

// =========================================================================
// TestConvenienceMinifyFunction
// =========================================================================

test "reflect: convenience minify function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source: [:0]const u8 = "fn foo() { let x = 1; }";

    // Test with default options (wgslender.minify)
    const result = try wgslender.minify(allocator, source);
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
    try std.testing.expect(result.code.len > 0);

    // Test with custom options (minify_whitespace only)
    const result2 = try wgslender.minifyWithOptions(allocator, source, .{
        .minify_whitespace = true,
        .minify_identifiers = false,
        .minify_syntax = false,
        .tree_shaking = false,
    });
    try std.testing.expectEqual(@as(usize, 0), result2.errors.len);
}

// =========================================================================
// Reflect External Tests
// =========================================================================

fn reflectSource(allocator: std.mem.Allocator, source: [:0]const u8) !wgslender.Reflect.ReflectResult {
    return wgslender.reflect(allocator, source);
}

fn findBinding(bindings: []const wgslender.Reflect.BindingInfo, name: []const u8) ?*const wgslender.Reflect.BindingInfo {
    for (bindings) |*b| {
        if (std.mem.eql(u8, b.name, name)) return b;
    }
    return null;
}

// --- Struct Layout Tests ---

test "reflect: basic struct layout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\struct Inputs {
        \\    time: f32,
        \\    resolution: vec2<u32>,
        \\    brightness: f32,
        \\}
        \\@group(0) @binding(0) var<uniform> u: Inputs;
    );

    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.bindings.items.len);

    const b = result.bindings.items[0];
    try std.testing.expectEqual(@as(i32, 0), b.group);
    try std.testing.expectEqual(@as(i32, 0), b.binding);
    try std.testing.expectEqualStrings("u", b.name);
    try std.testing.expectEqualStrings("uniform", b.address_space);
    try std.testing.expectEqualStrings("Inputs", b.typ);

    const layout = b.layout orelse return error.TestExpectedLayout;
    try std.testing.expectEqual(@as(u32, 8), layout.alignment);
    try std.testing.expectEqual(@as(u32, 24), layout.size);
    try std.testing.expectEqual(@as(usize, 3), layout.fields.items.len);

    // time: f32 (offset 0, size 4, align 4)
    try std.testing.expectEqualStrings("time", layout.fields.items[0].name);
    try std.testing.expectEqual(@as(u32, 0), layout.fields.items[0].offset);
    try std.testing.expectEqual(@as(u32, 4), layout.fields.items[0].size);
    try std.testing.expectEqual(@as(u32, 4), layout.fields.items[0].alignment);
    // resolution: vec2<u32> (offset 8, size 8, align 8)
    try std.testing.expectEqualStrings("resolution", layout.fields.items[1].name);
    try std.testing.expectEqual(@as(u32, 8), layout.fields.items[1].offset);
    try std.testing.expectEqual(@as(u32, 8), layout.fields.items[1].size);
    try std.testing.expectEqual(@as(u32, 8), layout.fields.items[1].alignment);
    // brightness: f32 (offset 16, size 4, align 4)
    try std.testing.expectEqual(@as(u32, 16), layout.fields.items[2].offset);
}

test "reflect: vec3 alignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\struct WithVec3 {
        \\    a: f32,
        \\    b: vec3<f32>,
        \\    c: f32,
        \\}
        \\@group(0) @binding(0) var<uniform> u: WithVec3;
    );

    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    const layout = result.bindings.items[0].layout orelse return error.TestExpectedLayout;
    try std.testing.expectEqual(@as(u32, 16), layout.alignment);
    try std.testing.expectEqual(@as(u32, 32), layout.size);
    // a: offset 0, b: offset 16 (aligned to 16, size 12), c: offset 28
    try std.testing.expectEqual(@as(u32, 0), layout.fields.items[0].offset);
    try std.testing.expectEqual(@as(u32, 16), layout.fields.items[1].offset);
    try std.testing.expectEqual(@as(u32, 12), layout.fields.items[1].size);
    try std.testing.expectEqual(@as(u32, 16), layout.fields.items[1].alignment);
    try std.testing.expectEqual(@as(u32, 28), layout.fields.items[2].offset);
}

test "reflect: nested struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\struct Inner {
        \\    x: f32,
        \\    y: f32,
        \\}
        \\struct Outer {
        \\    a: f32,
        \\    inner: Inner,
        \\    b: f32,
        \\}
        \\@group(0) @binding(0) var<uniform> u: Outer;
    );

    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    const layout = result.bindings.items[0].layout orelse return error.TestExpectedLayout;
    try std.testing.expectEqual(@as(u32, 16), layout.size);
    try std.testing.expectEqual(@as(usize, 3), layout.fields.items.len);
    const inner_field = layout.fields.items[1];
    try std.testing.expectEqualStrings("inner", inner_field.name);
    const inner_layout = inner_field.layout orelse return error.TestExpectedLayout;
    try std.testing.expectEqual(@as(u32, 8), inner_layout.size);
}

test "reflect: matrix layout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc, "struct WithMatrix { m2x2: mat2x2f, m3x3: mat3x3f, m4x4: mat4x4f, }");
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    const layout = result.structs.get("WithMatrix") orelse return error.TestExpectedStruct;
    try std.testing.expectEqual(@as(u32, 128), layout.size);
    // m2x2: offset 0, size 16, align 8
    try std.testing.expectEqual(@as(u32, 0), layout.fields.items[0].offset);
    try std.testing.expectEqual(@as(u32, 16), layout.fields.items[0].size);
    try std.testing.expectEqual(@as(u32, 8), layout.fields.items[0].alignment);
    // m3x3: offset 16, size 48, align 16
    try std.testing.expectEqual(@as(u32, 16), layout.fields.items[1].offset);
    try std.testing.expectEqual(@as(u32, 48), layout.fields.items[1].size);
    // m4x4: offset 64, size 64, align 16
    try std.testing.expectEqual(@as(u32, 64), layout.fields.items[2].offset);
    try std.testing.expectEqual(@as(u32, 64), layout.fields.items[2].size);
}

test "reflect: array layout in struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc, "struct WithArray { values: array<f32, 4>, }");
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    const layout = result.structs.get("WithArray") orelse return error.TestExpectedStruct;
    try std.testing.expectEqual(@as(usize, 1), layout.fields.items.len);
    try std.testing.expectEqual(@as(u32, 16), layout.fields.items[0].size);
    try std.testing.expectEqual(@as(u32, 4), layout.fields.items[0].alignment);
}

test "reflect: medium struct size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\struct custom {
        \\    mode: u32,
        \\    power: f32,
        \\    range_: f32,
        \\    innerAngle: f32,
        \\    outerAngle: f32,
        \\    direction: vec3f,
        \\    position: vec3f,
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    const layout = result.structs.get("custom") orelse return error.TestExpectedStruct;
    try std.testing.expectEqual(@as(u32, 64), layout.size);
}

test "reflect: struct with array of structs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\struct Light {
        \\    mode: u32,
        \\    power: f32,
        \\    range_: f32,
        \\    innerAngle: f32,
        \\    outerAngle: f32,
        \\    direction: vec3f,
        \\    position: vec3f,
        \\}
        \\struct custom {
        \\    colorMult: vec4f,
        \\    specularFactor: f32,
        \\    lights: array<Light, 2>,
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    const layout = result.structs.get("custom") orelse return error.TestExpectedStruct;
    try std.testing.expectEqual(@as(u32, 160), layout.size);
}

test "reflect: four matrices struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\struct custom {
        \\    projectionMatrix: mat4x4f,
        \\    viewMatrix: mat4x4f,
        \\    modelMatrix: mat4x4f,
        \\    normalMatrix: mat4x4f,
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    const layout = result.structs.get("custom") orelse return error.TestExpectedStruct;
    try std.testing.expectEqual(@as(u32, 256), layout.size);
}

test "reflect: mixed vectors struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\struct custom {
        \\    position: vec4f,
        \\    texcoord: vec2f,
        \\    normal: vec3f,
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    const layout = result.structs.get("custom") orelse return error.TestExpectedStruct;
    try std.testing.expectEqual(@as(u32, 48), layout.size);
}

test "reflect: single vec3f struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc, "struct custom { orientation: vec3f }");
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    const layout = result.structs.get("custom") orelse return error.TestExpectedStruct;
    try std.testing.expectEqual(@as(u32, 16), layout.size);
}

test "reflect: two vec3f struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc, "struct custom { orientation: vec3f, normal: vec3f }");
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    const layout = result.structs.get("custom") orelse return error.TestExpectedStruct;
    try std.testing.expectEqual(@as(u32, 32), layout.size);
    try std.testing.expectEqual(@as(u32, 0), layout.fields.items[0].offset);
    try std.testing.expectEqual(@as(u32, 16), layout.fields.items[1].offset);
}

test "reflect: complex nested struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\struct info { velocity: vec3f }
        \\struct custom {
        \\    orientation: vec3f,
        \\    size: f32,
        \\    direction: array<vec3f, 2>,
        \\    scale: f32,
        \\    info: info,
        \\    friction: f32,
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    const layout = result.structs.get("custom") orelse return error.TestExpectedStruct;
    try std.testing.expectEqual(@as(u32, 96), layout.size);
}

test "reflect: struct with nested struct and vec3f" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\struct info { velocity: vec3f }
        \\struct custom {
        \\    orientation: vec3f,
        \\    size: f32,
        \\    scale: f32,
        \\    info: info,
        \\    friction: f32,
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    const layout = result.structs.get("custom") orelse return error.TestExpectedStruct;
    try std.testing.expectEqual(@as(u32, 64), layout.size);
}

test "reflect: complex struct with arrays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\struct info { velocity: vec3f }
        \\struct custom {
        \\    scale: f32,
        \\    orientation: array<vec2f, 3>,
        \\    size: vec2f,
        \\    pos: vec2f,
        \\    info: array<info, 2>,
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    const layout = result.structs.get("custom") orelse return error.TestExpectedStruct;
    try std.testing.expectEqual(@as(u32, 80), layout.size);
}

// --- Bindings & Entry Points Tests ---

test "reflect: multiple bindings across groups" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\struct Uniforms { mvp: mat4x4f, }
        \\@group(0) @binding(0) var<uniform> uniforms: Uniforms;
        \\@group(0) @binding(1) var texSampler: sampler;
        \\@group(0) @binding(2) var texture: texture_2d<f32>;
        \\@group(1) @binding(0) var<storage, read_write> data: array<f32>;
    );

    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    try std.testing.expectEqual(@as(usize, 4), result.bindings.items.len);

    const ub = findBinding(result.bindings.items, "uniforms") orelse return error.TestBindingNotFound;
    try std.testing.expectEqual(@as(i32, 0), ub.group);
    try std.testing.expectEqual(@as(i32, 0), ub.binding);
    try std.testing.expectEqualStrings("uniform", ub.address_space);
    try std.testing.expect(ub.layout != null);

    const sb = findBinding(result.bindings.items, "texSampler") orelse return error.TestBindingNotFound;
    try std.testing.expectEqual(@as(i32, 0), sb.group);
    try std.testing.expectEqual(@as(i32, 1), sb.binding);
    try std.testing.expectEqualStrings("handle", sb.address_space);
    try std.testing.expectEqualStrings("sampler", sb.typ);
    try std.testing.expect(sb.layout == null);

    const db = findBinding(result.bindings.items, "data") orelse return error.TestBindingNotFound;
    try std.testing.expectEqual(@as(i32, 1), db.group);
    try std.testing.expectEqualStrings("storage", db.address_space);
    try std.testing.expectEqualStrings("read_write", db.access_mode);
}

test "reflect: sampler and sampler_comparison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\@group(0) @binding(0) var s: sampler;
        \\@group(0) @binding(1) var sc: sampler_comparison;
    );
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    try std.testing.expectEqual(@as(usize, 2), result.bindings.items.len);
    try std.testing.expectEqualStrings("sampler", result.bindings.items[0].typ);
    try std.testing.expectEqualStrings("sampler_comparison", result.bindings.items[1].typ);
}

test "reflect: texture bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\@group(0) @binding(0) var t: texture_2d<f32>;
        \\@group(0) @binding(1) var s: texture_storage_2d<rgba8unorm, write>;
        \\@group(0) @binding(2) var d: texture_depth_2d;
    );
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    try std.testing.expectEqual(@as(usize, 3), result.bindings.items.len);
}

test "reflect: handle type sampler_comparison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc, "@group(0) @binding(0) var s: sampler_comparison;");
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.bindings.items.len);
    try std.testing.expectEqualStrings("sampler_comparison", result.bindings.items[0].typ);
    try std.testing.expectEqualStrings("handle", result.bindings.items[0].address_space);
}

test "reflect: entry points" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\@compute @workgroup_size(8, 8, 1)
        \\fn main() {}
        \\
        \\@vertex
        \\fn vertMain() -> @builtin(position) vec4f {
        \\    return vec4f(0.0);
        \\}
        \\
        \\@fragment
        \\fn fragMain() -> @location(0) vec4f {
        \\    return vec4f(1.0);
        \\}
        \\
        \\fn helperFunc() {}
    );

    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    try std.testing.expectEqual(@as(usize, 3), result.entry_points.items.len);

    var compute_found = false;
    var vertex_found = false;
    var fragment_found = false;
    for (result.entry_points.items) |ep| {
        if (std.mem.eql(u8, ep.stage, "compute")) {
            compute_found = true;
            try std.testing.expectEqualStrings("main", ep.name);
            try std.testing.expectEqual(@as(u32, 8), ep.workgroup_size[0]);
            try std.testing.expectEqual(@as(u32, 8), ep.workgroup_size[1]);
            try std.testing.expectEqual(@as(u32, 1), ep.workgroup_size[2]);
        } else if (std.mem.eql(u8, ep.stage, "vertex")) {
            vertex_found = true;
            try std.testing.expectEqualStrings("vertMain", ep.name);
        } else if (std.mem.eql(u8, ep.stage, "fragment")) {
            fragment_found = true;
            try std.testing.expectEqualStrings("fragMain", ep.name);
        }
    }
    try std.testing.expect(compute_found);
    try std.testing.expect(vertex_found);
    try std.testing.expect(fragment_found);
}

test "reflect: workgroup size variants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cases = .{
        .{ "@compute @workgroup_size(1) fn main() {}", [3]u32{ 1, 1, 1 } },
        .{ "@compute @workgroup_size(64) fn main() {}", [3]u32{ 64, 1, 1 } },
        .{ "@compute @workgroup_size(8, 8) fn main() {}", [3]u32{ 8, 8, 1 } },
        .{ "@compute @workgroup_size(4, 4, 4) fn main() {}", [3]u32{ 4, 4, 4 } },
    };

    inline for (cases) |c| {
        const r = try reflectSource(alloc, c[0]);
        try std.testing.expectEqual(@as(usize, 0), r.errors.items.len);
        try std.testing.expectEqual(@as(usize, 1), r.entry_points.items.len);
        try std.testing.expectEqual(c[1], r.entry_points.items[0].workgroup_size);
    }
}

// --- Array Binding Tests ---

test "reflect: simple array binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc, "@group(0) @binding(0) var<storage> data: array<f32, 100>;");
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.bindings.items.len);

    const b = result.bindings.items[0];
    try std.testing.expectEqualStrings("data", b.name);
    try std.testing.expectEqualStrings("array<f32, 100>", b.typ);
    try std.testing.expect(b.layout == null);

    const arr = b.array orelse return error.TestExpectedArray;
    try std.testing.expectEqual(@as(u32, 1), arr.depth);
    try std.testing.expectEqual(@as(?i32, 100), arr.element_count);
    try std.testing.expectEqual(@as(u32, 4), arr.element_stride);
    try std.testing.expectEqual(@as(?i32, 400), arr.total_size);
    try std.testing.expectEqualStrings("f32", arr.element_type);
    try std.testing.expect(arr.element_layout == null);
    try std.testing.expect(arr.nested == null);
}

test "reflect: runtime-sized array binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc, "@group(0) @binding(0) var<storage> data: array<f32>;");
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    const arr = result.bindings.items[0].array orelse return error.TestExpectedArray;
    try std.testing.expectEqual(@as(u32, 1), arr.depth);
    try std.testing.expectEqual(@as(?i32, null), arr.element_count);
    try std.testing.expectEqual(@as(?i32, null), arr.total_size);
    try std.testing.expectEqual(@as(u32, 4), arr.element_stride);
}

test "reflect: array of structs binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\struct Particle {
        \\    pos: vec3f,
        \\    vel: f32,
        \\}
        \\@group(0) @binding(0) var<storage, read_write> data: array<Particle, 10000>;
    );

    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    const b = result.bindings.items[0];
    try std.testing.expectEqualStrings("read_write", b.access_mode);

    const arr = b.array orelse return error.TestExpectedArray;
    try std.testing.expectEqual(@as(?i32, 10000), arr.element_count);
    try std.testing.expectEqualStrings("Particle", arr.element_type);
    const el = arr.element_layout orelse return error.TestExpectedLayout;
    try std.testing.expectEqual(@as(u32, 16), el.size);
    try std.testing.expectEqual(@as(u32, 16), arr.element_stride);
    try std.testing.expectEqual(@as(?i32, 160000), arr.total_size);
    try std.testing.expectEqual(@as(usize, 2), el.fields.items.len);
    try std.testing.expectEqualStrings("pos", el.fields.items[0].name);
    try std.testing.expectEqualStrings("vel", el.fields.items[1].name);
}

test "reflect: nested array binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        "@group(0) @binding(0) var<storage> matrix: array<array<f32, 4>, 10>;"
    );
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    const outer = result.bindings.items[0].array orelse return error.TestExpectedArray;
    try std.testing.expectEqual(@as(u32, 1), outer.depth);
    try std.testing.expectEqual(@as(?i32, 10), outer.element_count);
    try std.testing.expectEqual(@as(u32, 16), outer.element_stride);
    try std.testing.expectEqual(@as(?i32, 160), outer.total_size);
    try std.testing.expect(outer.element_layout == null);

    const inner = outer.nested orelse return error.TestExpectedArray;
    try std.testing.expectEqual(@as(u32, 2), inner.depth);
    try std.testing.expectEqual(@as(?i32, 4), inner.element_count);
    try std.testing.expectEqualStrings("f32", inner.element_type);
    try std.testing.expectEqual(@as(u32, 4), inner.element_stride);
    try std.testing.expectEqual(@as(?i32, 16), inner.total_size);
    try std.testing.expect(inner.nested == null);
}

test "reflect: deeply nested array binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        "@group(0) @binding(0) var<storage> tensor: array<array<array<f32, 2>, 3>, 4>;"
    );
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);

    const l1 = result.bindings.items[0].array orelse return error.TestExpectedArray;
    try std.testing.expectEqual(@as(u32, 1), l1.depth);
    try std.testing.expectEqual(@as(?i32, 4), l1.element_count);

    const l2 = l1.nested orelse return error.TestExpectedArray;
    try std.testing.expectEqual(@as(u32, 2), l2.depth);
    try std.testing.expectEqual(@as(?i32, 3), l2.element_count);

    const l3 = l2.nested orelse return error.TestExpectedArray;
    try std.testing.expectEqual(@as(u32, 3), l3.depth);
    try std.testing.expectEqual(@as(?i32, 2), l3.element_count);
    try std.testing.expectEqualStrings("f32", l3.element_type);
    try std.testing.expect(l3.nested == null);
}

test "reflect: vec3 array stride" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc, "@group(0) @binding(0) var<storage> data: array<vec3f, 10>;");
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    const arr = result.bindings.items[0].array orelse return error.TestExpectedArray;
    try std.testing.expectEqual(@as(u32, 16), arr.element_stride);
    try std.testing.expectEqual(@as(?i32, 160), arr.total_size);
}

test "reflect: uniform array in struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\struct Data { values: array<f32, 4> }
        \\@group(0) @binding(0) var<uniform> u: Data;
    );
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    const b = result.bindings.items[0];
    try std.testing.expectEqualStrings("uniform", b.address_space);
    try std.testing.expect(b.array == null); // struct, not array
    try std.testing.expect(b.layout != null);
}

test "reflect: atomic array elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        "@group(0) @binding(0) var<storage, read_write> counters: array<atomic<u32>, 64>;"
    );
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    const arr = result.bindings.items[0].array orelse return error.TestExpectedArray;
    try std.testing.expectEqualStrings("atomic<u32>", arr.element_type);
    try std.testing.expectEqual(@as(u32, 4), arr.element_stride);
}

test "reflect: mat4x4 array elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        "@group(0) @binding(0) var<storage> bones: array<mat4x4f, 100>;"
    );
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    const arr = result.bindings.items[0].array orelse return error.TestExpectedArray;
    try std.testing.expectEqualStrings("mat4x4f", arr.element_type);
    try std.testing.expectEqual(@as(u32, 64), arr.element_stride);
    try std.testing.expectEqual(@as(?i32, 6400), arr.total_size);
}

test "reflect: mixed array and non-array bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\struct Uniforms { time: f32 }
        \\@group(0) @binding(0) var<uniform> uniforms: Uniforms;
        \\@group(0) @binding(1) var<storage> positions: array<vec4f, 1000>;
        \\@group(0) @binding(2) var texSampler: sampler;
        \\@group(0) @binding(3) var<storage, read_write> velocities: array<vec4f>;
    );

    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    try std.testing.expectEqual(@as(usize, 4), result.bindings.items.len);

    const u = findBinding(result.bindings.items, "uniforms") orelse return error.TestBindingNotFound;
    try std.testing.expect(u.array == null);
    try std.testing.expect(u.layout != null);

    const p = findBinding(result.bindings.items, "positions") orelse return error.TestBindingNotFound;
    const parr = p.array orelse return error.TestExpectedArray;
    try std.testing.expectEqual(@as(?i32, 1000), parr.element_count);
    try std.testing.expect(p.layout == null);

    const s = findBinding(result.bindings.items, "texSampler") orelse return error.TestBindingNotFound;
    try std.testing.expect(s.array == null);

    const v = findBinding(result.bindings.items, "velocities") orelse return error.TestBindingNotFound;
    const varr = v.array orelse return error.TestExpectedArray;
    try std.testing.expectEqual(@as(?i32, null), varr.element_count);
}

test "reflect: nested struct in array binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\struct Inner { x: f32, y: f32, }
        \\struct Outer { a: f32, inner: Inner, b: f32, }
        \\@group(0) @binding(0) var<storage> data: array<Outer, 100>;
    );

    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    const arr = result.bindings.items[0].array orelse return error.TestExpectedArray;
    const el = arr.element_layout orelse return error.TestExpectedLayout;
    try std.testing.expectEqual(@as(u32, 16), el.size);
    try std.testing.expectEqual(@as(usize, 3), el.fields.items.len);
    try std.testing.expectEqualStrings("inner", el.fields.items[1].name);
    try std.testing.expect(el.fields.items[1].layout != null);
}

test "reflect: empty struct array binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Main goal: don't crash
    const result = try reflectSource(alloc,
        \\struct Empty {}
        \\@group(0) @binding(0) var<storage> data: array<Empty, 10>;
    );
    _ = result;
}

test "reflect: zero-size array binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Main goal: don't crash
    const result = try reflectSource(alloc, "@group(0) @binding(0) var<storage> data: array<f32, 0>;");
    _ = result;
}

test "reflect: large count array binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc, "@group(0) @binding(0) var<storage> data: array<f32, 1000000>;");
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    const arr = result.bindings.items[0].array orelse return error.TestExpectedArray;
    try std.testing.expectEqual(@as(?i32, 1000000), arr.element_count);
    try std.testing.expectEqual(@as(?i32, 4000000), arr.total_size);
}

// --- Real Shader Tests ---

test "reflect: real shader with array of structs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\struct StarParticle {
        \\  pos : vec4f,
        \\  vel : vec4f,
        \\}
        \\struct StarsParticles {
        \\  particles : array<StarParticle>,
        \\}
        \\struct StarsSimParams {
        \\  deltaT: f32,
        \\  simId: f32,
        \\  rule1Distance: f32,
        \\  rule2Distance: f32,
        \\  rule3Distance: f32,
        \\  rule1Scale: f32,
        \\  rule2Scale: f32,
        \\  rule3Scale: f32,
        \\}
        \\@binding(0) @group(0) var<storage, read> particlesA : StarsParticles;
        \\@binding(1) @group(0) var<storage, read_write> particlesB : StarsParticles;
        \\@binding(2) @group(0) var<uniform> params : StarsSimParams;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id : vec3u) {
        \\  let index = id.x;
        \\  particlesB.particles[index].pos = particlesA.particles[index].pos;
        \\}
    );

    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    try std.testing.expectEqual(@as(usize, 3), result.bindings.items.len);

    const pa = findBinding(result.bindings.items, "particlesA") orelse return error.TestBindingNotFound;
    try std.testing.expectEqualStrings("storage", pa.address_space);
    try std.testing.expectEqualStrings("StarsParticles", pa.typ);
    try std.testing.expect(pa.array == null); // struct type, not array
    try std.testing.expect(pa.layout != null);

    const params = findBinding(result.bindings.items, "params") orelse return error.TestBindingNotFound;
    try std.testing.expectEqualStrings("uniform", params.address_space);
    const params_layout = params.layout orelse return error.TestExpectedLayout;
    try std.testing.expectEqual(@as(usize, 8), params_layout.fields.items.len);
    try std.testing.expectEqual(@as(u32, 32), params_layout.size);

    try std.testing.expectEqual(@as(usize, 1), result.entry_points.items.len);
    try std.testing.expectEqualStrings("main", result.entry_points.items[0].name);
    try std.testing.expectEqualStrings("compute", result.entry_points.items[0].stage);
    try std.testing.expectEqual(@as(u32, 64), result.entry_points.items[0].workgroup_size[0]);
}

test "reflect: real shader direct array binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\struct Particle {
        \\  position: vec4f,
        \\  velocity: vec4f,
        \\  color: vec4f,
        \\}
        \\@group(0) @binding(0) var<storage, read> inputParticles: array<Particle>;
        \\@group(0) @binding(1) var<storage, read_write> outputParticles: array<Particle>;
        \\@group(0) @binding(2) var<storage> fixedParticles: array<Particle, 1000>;
        \\@compute @workgroup_size(256)
        \\fn simulate(@builtin(global_invocation_id) id: vec3u) {
        \\  let i = id.x;
        \\  outputParticles[i] = inputParticles[i];
        \\}
    );

    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    try std.testing.expectEqual(@as(usize, 3), result.bindings.items.len);

    const inp = findBinding(result.bindings.items, "inputParticles") orelse return error.TestBindingNotFound;
    const inp_arr = inp.array orelse return error.TestExpectedArray;
    try std.testing.expectEqual(@as(?i32, null), inp_arr.element_count);
    try std.testing.expectEqualStrings("Particle", inp_arr.element_type);
    const inp_el = inp_arr.element_layout orelse return error.TestExpectedLayout;
    try std.testing.expectEqual(@as(u32, 48), inp_el.size);
    try std.testing.expectEqual(@as(u32, 48), inp_arr.element_stride);
    try std.testing.expect(inp.layout == null);

    const fixed = findBinding(result.bindings.items, "fixedParticles") orelse return error.TestBindingNotFound;
    const fixed_arr = fixed.array orelse return error.TestExpectedArray;
    try std.testing.expectEqual(@as(?i32, 1000), fixed_arr.element_count);
    try std.testing.expectEqual(@as(?i32, 48000), fixed_arr.total_size);
}

test "reflect: complex real shader with camera/lights" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\struct Camera {
        \\  view: mat4x4f,
        \\  projection: mat4x4f,
        \\  position: vec3f,
        \\  _pad: f32,
        \\}
        \\struct Light {
        \\  color: vec3f,
        \\  intensity: f32,
        \\  position: vec3f,
        \\  range: f32,
        \\}
        \\@group(0) @binding(0) var<uniform> camera: Camera;
        \\@group(0) @binding(1) var<storage> lights: array<Light, 16>;
        \\@group(1) @binding(0) var albedoTexture: texture_2d<f32>;
        \\@group(1) @binding(1) var normalTexture: texture_2d<f32>;
        \\@group(1) @binding(2) var texSampler: sampler;
        \\@fragment
        \\fn main() -> @location(0) vec4f {
        \\  return vec4f(1.0);
        \\}
    );

    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    try std.testing.expectEqual(@as(usize, 5), result.bindings.items.len);

    const cam = findBinding(result.bindings.items, "camera") orelse return error.TestBindingNotFound;
    const cam_layout = cam.layout orelse return error.TestExpectedLayout;
    try std.testing.expectEqual(@as(u32, 144), cam_layout.size);

    const lights = findBinding(result.bindings.items, "lights") orelse return error.TestBindingNotFound;
    const lights_arr = lights.array orelse return error.TestExpectedArray;
    try std.testing.expectEqual(@as(?i32, 16), lights_arr.element_count);
    const light_el = lights_arr.element_layout orelse return error.TestExpectedLayout;
    try std.testing.expectEqual(@as(u32, 32), light_el.size);
    try std.testing.expectEqual(@as(u32, 32), lights_arr.element_stride);

    const tex = findBinding(result.bindings.items, "albedoTexture") orelse return error.TestBindingNotFound;
    try std.testing.expect(tex.array == null);
    try std.testing.expectEqualStrings("handle", tex.address_space);

    try std.testing.expectEqual(@as(usize, 1), result.entry_points.items.len);
    try std.testing.expectEqualStrings("fragment", result.entry_points.items[0].stage);
}

// --- Mapped Names Tests ---

test "reflect: mapped names without renamer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\struct MyStruct {
        \\    position: vec3f,
        \\    color: vec4f,
        \\}
        \\@group(0) @binding(0) var<storage> data: array<MyStruct>;
    );
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);

    const b = result.bindings.items[0];
    try std.testing.expectEqualStrings(b.name, b.name_mapped);
    try std.testing.expectEqualStrings(b.typ, b.type_mapped);

    const arr = b.array orelse return error.TestExpectedArray;
    try std.testing.expectEqualStrings(arr.element_type, arr.element_type_mapped);

    const sl = result.structs.get("MyStruct") orelse return error.TestExpectedStruct;
    for (sl.fields.items) |field| {
        try std.testing.expectEqualStrings(field.name, field.name_mapped);
        try std.testing.expectEqualStrings(field.typ, field.type_mapped);
    }
}

test "reflect: mapped names with renamer (via minifyAndReflect)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try wgslender.minifyAndReflect(alloc,
        \\struct Particle {
        \\    position: vec3f,
        \\    velocity: vec3f,
        \\}
        \\@group(0) @binding(0) var<storage> particles: array<Particle>;
        \\@compute @workgroup_size(64)
        \\fn main() {}
    , .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .tree_shaking = false,
    });

    try std.testing.expectEqual(@as(usize, 0), result.minify.errors.len);

    // With renamer, mapped names should differ from original
    const b = result.reflect.bindings.items[0];
    try std.testing.expectEqualStrings("particles", b.name);
    // name_mapped should appear in minified code
    try std.testing.expect(std.mem.indexOf(u8, result.minify.code, b.name_mapped) != null);
}

test "reflect: field mapped names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\struct MyStruct {
        \\    position: vec3f,
        \\    velocity: vec4f,
        \\}
        \\@group(0) @binding(0) var<uniform> u: MyStruct;
    );
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    const layout = result.bindings.items[0].layout orelse return error.TestExpectedLayout;
    for (layout.fields.items) |field| {
        try std.testing.expectEqualStrings(field.name, field.name_mapped);
        try std.testing.expectEqualStrings(field.typ, field.type_mapped);
    }
}

// --- Generic Type Tests ---

test "reflect: generic vector types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cases = .{
        .{ "struct S { v: vec2<f32> } @group(0) @binding(0) var<uniform> u: S;", 8, 8 },
        .{ "struct S { v: vec3<f32> } @group(0) @binding(0) var<uniform> u: S;", 12, 16 },
        .{ "struct S { v: vec4<f32> } @group(0) @binding(0) var<uniform> u: S;", 16, 16 },
        .{ "struct S { v: vec2<i32> } @group(0) @binding(0) var<uniform> u: S;", 8, 8 },
        .{ "struct S { v: vec3<u32> } @group(0) @binding(0) var<uniform> u: S;", 12, 16 },
        .{ "struct S { v: vec4<bool> } @group(0) @binding(0) var<uniform> u: S;", 16, 16 },
        .{ "struct S { v: vec2<f16> } @group(0) @binding(0) var<uniform> u: S;", 4, 4 },
        .{ "struct S { v: vec3<f16> } @group(0) @binding(0) var<uniform> u: S;", 6, 8 },
        .{ "struct S { v: vec4<f16> } @group(0) @binding(0) var<uniform> u: S;", 8, 8 },
    };

    inline for (cases) |c| {
        const r = try reflectSource(alloc, c[0]);
        try std.testing.expectEqual(@as(usize, 0), r.errors.items.len);
        const layout = r.bindings.items[0].layout orelse return error.TestExpectedLayout;
        try std.testing.expectEqual(@as(u32, c[1]), layout.fields.items[0].size);
        try std.testing.expectEqual(@as(u32, c[2]), layout.fields.items[0].alignment);
    }
}

test "reflect: generic matrix types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cases = .{
        .{ "struct S { m: mat2x2<f32> } @group(0) @binding(0) var<uniform> u: S;", 16, 8 },
        .{ "struct S { m: mat3x3<f32> } @group(0) @binding(0) var<uniform> u: S;", 48, 16 },
        .{ "struct S { m: mat4x4<f32> } @group(0) @binding(0) var<uniform> u: S;", 64, 16 },
        .{ "struct S { m: mat2x3<f32> } @group(0) @binding(0) var<uniform> u: S;", 32, 16 },
        .{ "struct S { m: mat3x4<f32> } @group(0) @binding(0) var<uniform> u: S;", 48, 16 },
    };

    inline for (cases) |c| {
        const r = try reflectSource(alloc, c[0]);
        try std.testing.expectEqual(@as(usize, 0), r.errors.items.len);
        const layout = r.bindings.items[0].layout orelse return error.TestExpectedLayout;
        try std.testing.expectEqual(@as(u32, c[1]), layout.fields.items[0].size);
        try std.testing.expectEqual(@as(u32, c[2]), layout.fields.items[0].alignment);
    }
}

test "reflect: pointer type in struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc, "struct S { p: ptr<function, f32> }");
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    const layout = result.structs.get("S") orelse return error.TestExpectedStruct;
    try std.testing.expectEqual(@as(usize, 1), layout.fields.items.len);
}

test "reflect: atomic types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\struct S { a: atomic<u32>, b: atomic<i32> }
        \\@group(0) @binding(0) var<storage, read_write> s: S;
    );
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    const layout = result.bindings.items[0].layout orelse return error.TestExpectedLayout;
    try std.testing.expectEqual(@as(usize, 2), layout.fields.items.len);
    for (layout.fields.items) |field| {
        try std.testing.expectEqual(@as(u32, 4), field.size);
        try std.testing.expectEqual(@as(u32, 4), field.alignment);
    }
}

// --- Edge Cases ---

test "reflect: parse errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Use the same source from the existing MinifyAndReflectParseError test
    const result = try wgslender.minifyWithOptions(alloc, "fn invalid( { }", wgslender.Minifier.defaultOptions());
    // The minifier should report parse errors
    try std.testing.expect(result.errors.len > 0);
}

test "reflect: empty shader" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc, "");
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    try std.testing.expectEqual(@as(usize, 0), result.bindings.items.len);
    try std.testing.expectEqual(@as(usize, 0), result.entry_points.items.len);
}

test "reflect: array of vec2f struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc, "struct custom { orientation: array<vec2f, 3> }");
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    const layout = result.structs.get("custom") orelse return error.TestExpectedStruct;
    try std.testing.expectEqual(@as(u32, 24), layout.size);
}

test "reflect: private var not in bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc, "var<private> data: array<f32, 10>;");
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    try std.testing.expectEqual(@as(usize, 0), result.bindings.items.len);
}

// --- name_offset: byte offsets point at declared names in source ---

test "reflect: name_offset points at binding name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source: [:0]const u8 =
        "@group(0) @binding(0) var<uniform> uniforms: f32;";
    const result = try reflectSource(alloc, source);
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.bindings.items.len);

    const b = result.bindings.items[0];
    const off = b.name_offset;
    try std.testing.expect(off > 0);
    try std.testing.expect(off + b.name.len <= source.len);
    try std.testing.expectEqualStrings(b.name, source[off .. off + b.name.len]);
}

test "reflect: name_offset points at entry point name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source: [:0]const u8 =
        "@compute @workgroup_size(1) fn simulate() {}";
    const result = try reflectSource(alloc, source);
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.entry_points.items.len);

    const ep = result.entry_points.items[0];
    const off = ep.name_offset;
    try std.testing.expect(off > 0);
    try std.testing.expectEqualStrings(ep.name, source[off .. off + ep.name.len]);
}

test "reflect: name_offset points at field names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source: [:0]const u8 =
        "struct Uniforms { time: f32, color: vec3f, }" ++
        " @group(0) @binding(0) var<uniform> u: Uniforms;";
    const result = try reflectSource(alloc, source);
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);

    const layout = result.structs.get("Uniforms") orelse return error.TestExpectedStruct;
    try std.testing.expectEqual(@as(usize, 2), layout.fields.items.len);
    for (layout.fields.items) |field| {
        const off = field.name_offset;
        try std.testing.expect(off > 0);
        try std.testing.expectEqualStrings(field.name, source[off .. off + field.name.len]);
    }
}
