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

    const result = try reflectSource(alloc, "@group(0) @binding(0) var<storage> matrix: array<array<f32, 4>, 10>;");
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

    const result = try reflectSource(alloc, "@group(0) @binding(0) var<storage> tensor: array<array<array<f32, 2>, 3>, 4>;");
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

    const result = try reflectSource(alloc, "@group(0) @binding(0) var<storage, read_write> counters: array<atomic<u32>, 64>;");
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    const arr = result.bindings.items[0].array orelse return error.TestExpectedArray;
    try std.testing.expectEqualStrings("atomic<u32>", arr.element_type);
    try std.testing.expectEqual(@as(u32, 4), arr.element_stride);
}

test "reflect: mat4x4 array elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc, "@group(0) @binding(0) var<storage> bones: array<mat4x4f, 100>;");
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

// --- Alias Chain Resolution (parity with wgsl_reflect) ---

test "reflect: alias chain resolves to underlying struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source: [:0]const u8 =
        \\struct Foo {
        \\  a: u32,
        \\  b: f32,
        \\}
        \\alias foo1 = Foo;
        \\alias foo2 = foo1;
        \\alias foo3 = foo2;
        \\@group(0) @binding(1) var<storage> materials: foo3;
    ;
    const result = try reflectSource(alloc, source);
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);

    const b = findBinding(result.bindings.items, "materials") orelse return error.TestExpectedBinding;
    const layout = b.layout orelse return error.TestExpectedLayout;
    try std.testing.expectEqual(@as(u32, 8), layout.size);
    try std.testing.expectEqual(@as(usize, 2), layout.fields.items.len);
    try std.testing.expectEqualStrings("a", layout.fields.items[0].name);
    try std.testing.expectEqual(@as(u32, 0), layout.fields.items[0].offset);
    try std.testing.expectEqualStrings("b", layout.fields.items[1].name);
    try std.testing.expectEqual(@as(u32, 4), layout.fields.items[1].offset);
}

test "reflect: alias chain to array of struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source: [:0]const u8 =
        \\struct Foo {
        \\  a: u32,
        \\  b: f32,
        \\}
        \\alias foo1 = Foo;
        \\alias foo2 = foo1;
        \\alias foo3 = foo2;
        \\@group(0) @binding(1) var<storage> materials: array<foo3, 10>;
    ;
    const result = try reflectSource(alloc, source);
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);

    const b = findBinding(result.bindings.items, "materials") orelse return error.TestExpectedBinding;
    const arr = b.array orelse return error.TestExpectedArray;
    try std.testing.expectEqual(@as(?i32, 10), arr.element_count);
    try std.testing.expectEqual(@as(u32, 8), arr.element_stride);
    try std.testing.expectEqual(@as(?i32, 80), arr.total_size);
    const elem_layout = arr.element_layout orelse return error.TestExpectedElementLayout;
    try std.testing.expectEqual(@as(usize, 2), elem_layout.fields.items.len);
}

test "reflect: alias-of-array binding resolves array info" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source: [:0]const u8 =
        \\struct Light {
        \\  power: f32,
        \\  position: vec2<i32>,
        \\}
        \\alias LightArray = array<Light, 3>;
        \\@group(0) @binding(0) var<uniform> lights: LightArray;
    ;
    const result = try reflectSource(alloc, source);
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);

    const b = findBinding(result.bindings.items, "lights") orelse return error.TestExpectedBinding;
    const arr = b.array orelse return error.TestExpectedArray;
    try std.testing.expectEqual(@as(?i32, 3), arr.element_count);
}

// --- Const-Expression Evaluator (parity with wgsl_reflect) ---

test "reflect: const arithmetic in array size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source: [:0]const u8 =
        \\const NUM_COLORS = 10 + 2;
        \\@group(0) @binding(0) var<uniform> uni: array<vec4f, NUM_COLORS>;
    ;
    const result = try reflectSource(alloc, source);
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);

    const b = findBinding(result.bindings.items, "uni") orelse return error.TestExpectedBinding;
    const arr = b.array orelse return error.TestExpectedArray;
    try std.testing.expectEqual(@as(?i32, 12), arr.element_count);
    try std.testing.expectEqual(@as(u32, 16), arr.element_stride);
    try std.testing.expectEqual(@as(?i32, 16 * 12), arr.total_size);
}

test "reflect: const float math feeds u32 cast in array size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // wgsl_reflect's `const2` test: NUM_COLORS = u32(sin(radians(90)) + 3) = u32(4.0) = 4.
    const source: [:0]const u8 =
        \\const FOO = radians(90);
        \\const BAR = sin(FOO);
        \\const NUM_COLORS = u32(BAR + 3);
        \\@group(0) @binding(0) var<uniform> uni: array<vec4f, NUM_COLORS>;
    ;
    const result = try reflectSource(alloc, source);
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);

    const b = findBinding(result.bindings.items, "uni") orelse return error.TestExpectedBinding;
    const arr = b.array orelse return error.TestExpectedArray;
    try std.testing.expectEqual(@as(?i32, 4), arr.element_count);
    try std.testing.expectEqual(@as(?i32, 16 * 4), arr.total_size);
}

test "reflect: const member access on struct constructor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The parser now accepts `.member` directly inside an `array<T, ...>`
    // template position; the direct-shape port lives in
    // `tests/reflect_wgslreflect_test.zig` ("alias struct"). This test
    // is kept as a back-stop using an intermediate const so a regression
    // in either evalMember or the parser fix surfaces independently.
    const source: [:0]const u8 =
        \\alias foo = u32;
        \\alias bar = foo;
        \\struct Vehicle {
        \\  num_wheels: bar,
        \\  mass_kg: f32,
        \\}
        \\alias Car = Vehicle;
        \\const num_cars = 2 * 2;
        \\struct Ship {
        \\  cars: array<Car, num_cars>,
        \\}
        \\const a_bicycle = Car(2, 10.5);
        \\const bike_wheels = a_bicycle.num_wheels;
        \\struct Ocean {
        \\  things: array<Ship, bike_wheels>,
        \\}
        \\@group(0) @binding(0) var<uniform> ocean: Ocean;
    ;
    const result = try reflectSource(alloc, source);
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);

    // Vehicle = {u32, f32} = 8 bytes; Ship.cars = array<Car, 4> = 32;
    // Ocean.things = array<Ship, bike_wheels=2> = 64.
    const b = findBinding(result.bindings.items, "ocean") orelse return error.TestExpectedBinding;
    const layout = b.layout orelse return error.TestExpectedLayout;
    try std.testing.expectEqual(@as(u32, 64), layout.size);
}

test "reflect: const chain unlocks runtime-sized recovery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Without const evaluation, this binding's array would be reported with
    // element_count == null (treated as runtime-sized). With evaluation,
    // count == 4.
    const source: [:0]const u8 =
        \\const N = 2 * 2;
        \\@group(0) @binding(0) var<uniform> u: array<f32, N>;
    ;
    const result = try reflectSource(alloc, source);
    const b = findBinding(result.bindings.items, "u") orelse return error.TestExpectedBinding;
    const arr = b.array orelse return error.TestExpectedArray;
    try std.testing.expectEqual(@as(?i32, 4), arr.element_count);
}

test "reflect: array<T, struct.member> resolves elementCount" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The user-reported repro for the template-arg postfix bug. Before
    // the parser fix, the `.x` was silently dropped — array reflected as
    // runtime-sized with count == null. Now evalMember resolves
    // `Pair(4u, 0u).x → 4`.
    const source: [:0]const u8 =
        \\struct Pair { x: u32, y: u32 }
        \\const P = Pair(4u, 0u);
        \\@group(0) @binding(0) var<uniform> u: array<f32, P.x>;
    ;
    const result = try reflectSource(alloc, source);
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);

    const b = findBinding(result.bindings.items, "u") orelse return error.TestExpectedBinding;
    const arr = b.array orelse return error.TestExpectedArray;
    try std.testing.expectEqual(@as(?i32, 4), arr.element_count);
    try std.testing.expectEqual(@as(?i32, 16), arr.total_size);
}

test "reflect: array<T, struct.member + N> resolves elementCount" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Combines the postfix .member parse with the binary-add path so
    // both AST shapes have to land for elementCount to resolve.
    const source: [:0]const u8 =
        \\struct Pair { x: u32, y: u32 }
        \\const P = Pair(4u, 0u);
        \\@group(0) @binding(0) var<uniform> u: array<f32, P.x + 1>;
    ;
    const result = try reflectSource(alloc, source);
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);

    const b = findBinding(result.bindings.items, "u") orelse return error.TestExpectedBinding;
    const arr = b.array orelse return error.TestExpectedArray;
    try std.testing.expectEqual(@as(?i32, 5), arr.element_count);
}

test "reflect: alias-of-struct member layout in nested struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source: [:0]const u8 =
        \\struct Light {
        \\  power: f32,
        \\  position: vec2<i32>,
        \\}
        \\alias LightAlias = Light;
        \\alias LightArray = array<Light, 3>;
        \\struct Uniforms {
        \\  size: vec2<f32>,
        \\  light: LightAlias,
        \\  lights: LightArray,
        \\}
        \\@group(0) @binding(0) var<uniform> uni: Uniforms;
    ;
    const result = try reflectSource(alloc, source);
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);

    const b = findBinding(result.bindings.items, "uni") orelse return error.TestExpectedBinding;
    const layout = b.layout orelse return error.TestExpectedLayout;
    // Matches wgsl_reflect: size 72.
    try std.testing.expectEqual(@as(u32, 72), layout.size);

    // light (LightAlias → Light) should have its nested layout attached.
    const light_field = layout.fields.items[1];
    try std.testing.expectEqualStrings("light", light_field.name);
    try std.testing.expect(light_field.layout != null);

    // lights (LightArray → array<Light, 3>) is an array; the binding-level
    // layout doesn't carry the array element layout (that goes on `array`),
    // but the field's own size/alignment should be computed.
    const lights_field = layout.fields.items[2];
    try std.testing.expectEqualStrings("lights", lights_field.name);
    try std.testing.expect(lights_field.size > 0);
}

// =========================================================================
// TypeInfo (structured type tree on bindings/fields)
// =========================================================================

test "reflect: TypeInfo on scalar binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\@group(0) @binding(0) var<uniform> a1: f32;
    );
    const b = findBinding(result.bindings.items, "a1") orelse return error.TestExpectedBinding;
    const ti = b.type_info orelse return error.TestExpectedTypeInfo;
    try std.testing.expect(ti.* == .scalar);
    try std.testing.expectEqualStrings("f32", ti.scalar.name);
    try std.testing.expectEqual(@as(u32, 4), ti.scalar.size);
    try std.testing.expectEqual(@as(u32, 4), ti.scalar.alignment);
}

test "reflect: TypeInfo on vec3f binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\@group(0) @binding(0) var<uniform> v: vec3f;
    );
    const b = findBinding(result.bindings.items, "v") orelse return error.TestExpectedBinding;
    const ti = b.type_info orelse return error.TestExpectedTypeInfo;
    try std.testing.expect(ti.* == .vec);
    try std.testing.expectEqual(@as(u8, 3), ti.vec.width);
    try std.testing.expectEqual(@as(u32, 12), ti.vec.size);
    try std.testing.expectEqual(@as(u32, 16), ti.vec.alignment);
    try std.testing.expect(ti.vec.format.* == .scalar);
    try std.testing.expectEqualStrings("f32", ti.vec.format.scalar.name);
}

test "reflect: TypeInfo on mat3x3h binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\enable f16;
        \\@group(0) @binding(0) var<uniform> m: mat3x3h;
    );
    const b = findBinding(result.bindings.items, "m") orelse return error.TestExpectedBinding;
    const ti = b.type_info orelse return error.TestExpectedTypeInfo;
    try std.testing.expect(ti.* == .mat);
    try std.testing.expectEqual(@as(u8, 3), ti.mat.cols);
    try std.testing.expectEqual(@as(u8, 3), ti.mat.rows);
    try std.testing.expectEqual(@as(u32, 24), ti.mat.size);
    try std.testing.expectEqual(@as(u32, 8), ti.mat.alignment);
    try std.testing.expectEqual(@as(u32, 8), ti.mat.stride);
    try std.testing.expect(ti.mat.format.* == .scalar);
    try std.testing.expectEqualStrings("f16", ti.mat.format.scalar.name);
}

test "reflect: TypeInfo on nested array<array<vec3f, 5>, 6>" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\@group(0) @binding(0) var<uniform> a: array<array<vec3f, 5>, 6>;
    );
    const b = findBinding(result.bindings.items, "a") orelse return error.TestExpectedBinding;
    const ti = b.type_info orelse return error.TestExpectedTypeInfo;
    try std.testing.expect(ti.* == .array);
    try std.testing.expectEqual(@as(?u32, 6), ti.array.count);
    // outer stride = inner array size rounded up to inner alignment
    // inner array: 5 * 16 (vec3f stride) = 80, alignment 16
    // outer: count=6, stride=80, size=480
    try std.testing.expectEqual(@as(u32, 80), ti.array.stride);
    try std.testing.expectEqual(@as(?u32, 480), ti.array.size);

    const inner = ti.array.format;
    try std.testing.expect(inner.* == .array);
    try std.testing.expectEqual(@as(?u32, 5), inner.array.count);
    try std.testing.expectEqual(@as(u32, 16), inner.array.stride);
    try std.testing.expectEqual(@as(?u32, 80), inner.array.size);

    const leaf = inner.array.format;
    try std.testing.expect(leaf.* == .vec);
    try std.testing.expectEqual(@as(u8, 3), leaf.vec.width);
}

test "reflect: TypeInfo on struct ref" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\struct U { a: f32, b: vec3f, }
        \\@group(0) @binding(0) var<uniform> u: U;
    );
    const b = findBinding(result.bindings.items, "u") orelse return error.TestExpectedBinding;
    const ti = b.type_info orelse return error.TestExpectedTypeInfo;
    try std.testing.expect(ti.* == .@"struct");
    try std.testing.expectEqualStrings("U", ti.@"struct".name);
    try std.testing.expect(ti.@"struct".size > 0);
}

test "reflect: TypeInfo on storage texture (rgba8unorm, write)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\@group(0) @binding(0) var t: texture_storage_2d<rgba8unorm, write>;
    );
    const b = findBinding(result.bindings.items, "t") orelse return error.TestExpectedBinding;
    const ti = b.type_info orelse return error.TestExpectedTypeInfo;
    try std.testing.expect(ti.* == .texture);
    try std.testing.expectEqualStrings("rgba8unorm", ti.texture.format);
    try std.testing.expectEqual(@import("wgslender").Ast.AccessMode.write, ti.texture.access);
}

test "reflect: TypeInfo on sampled texture_2d<f32>" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\@group(0) @binding(0) var t: texture_2d<f32>;
    );
    const b = findBinding(result.bindings.items, "t") orelse return error.TestExpectedBinding;
    const ti = b.type_info orelse return error.TestExpectedTypeInfo;
    try std.testing.expect(ti.* == .texture);
    try std.testing.expectEqualStrings("f32", ti.texture.sample_type);
}

test "reflect: TypeInfo on comparison sampler" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\@group(0) @binding(0) var s: sampler_comparison;
    );
    const b = findBinding(result.bindings.items, "s") orelse return error.TestExpectedBinding;
    const ti = b.type_info orelse return error.TestExpectedTypeInfo;
    try std.testing.expect(ti.* == .sampler);
    try std.testing.expect(ti.sampler.comparison);
}

test "reflect: TypeInfo follows alias chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\struct Foo { x: f32 }
        \\alias Foo1 = Foo;
        \\alias Foo2 = Foo1;
        \\@group(0) @binding(0) var<uniform> u: Foo2;
    );
    const b = findBinding(result.bindings.items, "u") orelse return error.TestExpectedBinding;
    const ti = b.type_info orelse return error.TestExpectedTypeInfo;
    try std.testing.expect(ti.* == .@"struct");
    try std.testing.expectEqualStrings("Foo", ti.@"struct".name);
}

test "reflect: TypeInfo on FieldInfo of a struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\struct Inner { x: f32, y: f32 }
        \\struct Outer { a: vec3f, b: Inner }
        \\@group(0) @binding(0) var<uniform> u: Outer;
    );
    const b = findBinding(result.bindings.items, "u") orelse return error.TestExpectedBinding;
    const layout = b.layout orelse return error.TestExpectedLayout;
    try std.testing.expectEqual(@as(usize, 2), layout.fields.items.len);

    const fa = layout.fields.items[0];
    const ti_a = fa.type_info orelse return error.TestExpectedTypeInfo;
    try std.testing.expect(ti_a.* == .vec);
    try std.testing.expectEqual(@as(u8, 3), ti_a.vec.width);

    const fb = layout.fields.items[1];
    const ti_b = fb.type_info orelse return error.TestExpectedTypeInfo;
    try std.testing.expect(ti_b.* == .@"struct");
    try std.testing.expectEqualStrings("Inner", ti_b.@"struct".name);
}

test "reflect: TypeInfo JSON includes typeInfo key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\@group(0) @binding(0) var<uniform> v: vec3f;
    );
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try result.toJson(&buf, alloc);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"typeInfo\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"kind\":\"vec\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"width\":3") != null);
}

// =========================================================================
// @align / @size / @stride member-attribute layout overrides
// =========================================================================

test "reflect: @size grows member size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // From wgsl_reflect's struct_layout.js: `@size(16) x: f32` makes the
    // f32 occupy 16 bytes. struct A has fields u/v/w/x with sizes 4/4/8/16.
    const result = try reflectSource(alloc,
        \\struct A {
        \\  u: f32,
        \\  v: f32,
        \\  w: vec2<f32>,
        \\  @size(16) x: f32,
        \\}
        \\@group(0) @binding(0) var<uniform> a: A;
    );
    const b = findBinding(result.bindings.items, "a") orelse return error.TestExpectedBinding;
    const layout = b.layout orelse return error.TestExpectedLayout;
    try std.testing.expectEqual(@as(u32, 32), layout.size);
    try std.testing.expectEqual(@as(u32, 8), layout.alignment);

    const x = layout.fields.items[3];
    try std.testing.expectEqualStrings("x", x.name);
    try std.testing.expectEqual(@as(u32, 16), x.offset);
    try std.testing.expectEqual(@as(u32, 16), x.size);
    try std.testing.expectEqual(@as(u32, 4), x.alignment);
}

test "reflect: @align(16) bumps member alignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\struct S {
        \\  a: f32,
        \\  @align(16) b: f32,
        \\}
        \\@group(0) @binding(0) var<uniform> s: S;
    );
    const b = findBinding(result.bindings.items, "s") orelse return error.TestExpectedBinding;
    const layout = b.layout orelse return error.TestExpectedLayout;
    // a at 0, b forced to align 16 → offset 16. Struct size rounds to 32.
    try std.testing.expectEqual(@as(u32, 16), layout.alignment);
    try std.testing.expectEqual(@as(u32, 32), layout.size);
    try std.testing.expectEqual(@as(u32, 0), layout.fields.items[0].offset);
    try std.testing.expectEqual(@as(u32, 16), layout.fields.items[1].offset);
    try std.testing.expectEqual(@as(u32, 16), layout.fields.items[1].alignment);
}

test "reflect: struct_layout.js torture (struct B align=16 size=208)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\struct A {
        \\  u: f32,
        \\  v: f32,
        \\  w: vec2<f32>,
        \\  @size(16) x: f32,
        \\}
        \\struct B {
        \\  a: vec2<f32>,
        \\  b: vec3<f32>,
        \\  c: f32,
        \\  d: f32,
        \\  @align(16) e: A,
        \\  f: vec3<f32>,
        \\  g: array<A, 3>,
        \\  h: i32,
        \\}
        \\@group(0) @binding(0) var<uniform> uniform_buffer: B;
    );
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    const bind = findBinding(result.bindings.items, "uniform_buffer") orelse return error.TestExpectedBinding;
    const layout = bind.layout orelse return error.TestExpectedLayout;
    try std.testing.expectEqual(@as(u32, 16), layout.alignment);
    try std.testing.expectEqual(@as(u32, 208), layout.size);

    // Per offset table from wgsl_reflect's struct_layout.js:
    // a:0,8 / b:16,12 / c:28,4 / d:32,4 / e:48,32 / f:80,12 / g:96,96 / h:192,4
    const expected = [_]struct { name: []const u8, offset: u32, size: u32 }{
        .{ .name = "a", .offset = 0, .size = 8 },
        .{ .name = "b", .offset = 16, .size = 12 },
        .{ .name = "c", .offset = 28, .size = 4 },
        .{ .name = "d", .offset = 32, .size = 4 },
        .{ .name = "e", .offset = 48, .size = 32 },
        .{ .name = "f", .offset = 80, .size = 12 },
        .{ .name = "g", .offset = 96, .size = 96 },
        .{ .name = "h", .offset = 192, .size = 4 },
    };
    try std.testing.expectEqual(expected.len, layout.fields.items.len);
    for (expected, 0..) |e, i| {
        const f = layout.fields.items[i];
        try std.testing.expectEqualStrings(e.name, f.name);
        try std.testing.expectEqual(e.offset, f.offset);
        try std.testing.expectEqual(e.size, f.size);
    }
}

test "reflect: @align less than natural is ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // vec3f naturally aligns to 16. @align(4) is invalid (validator
    // emits diagnostic) — reflection silently keeps the natural value.
    const result = try reflectSource(alloc,
        \\struct S { @align(4) a: vec3<f32>, }
        \\@group(0) @binding(0) var<uniform> s: S;
    );
    const b = findBinding(result.bindings.items, "s") orelse return error.TestExpectedBinding;
    const layout = b.layout orelse return error.TestExpectedLayout;
    try std.testing.expectEqual(@as(u32, 16), layout.alignment);
    try std.testing.expectEqual(@as(u32, 16), layout.fields.items[0].alignment);
}

test "reflect: @stride overrides array stride" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // f32 array has natural stride 4; @stride(8) makes each element take
    // 8 bytes. count=4 → total 32. Member alignment unchanged (4).
    const result = try reflectSource(alloc,
        \\struct S { @stride(8) data: array<f32, 4>, }
        \\@group(0) @binding(0) var<storage, read> s: S;
    );
    const b = findBinding(result.bindings.items, "s") orelse return error.TestExpectedBinding;
    const layout = b.layout orelse return error.TestExpectedLayout;
    try std.testing.expectEqual(@as(u32, 32), layout.fields.items[0].size);

    const ti = layout.fields.items[0].type_info orelse return error.TestExpectedTypeInfo;
    try std.testing.expect(ti.* == .array);
    try std.testing.expectEqual(@as(u32, 8), ti.array.stride);
    try std.testing.expectEqual(@as(?u32, 32), ti.array.size);
}

test "reflect: @size override propagates to TypeInfo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\struct S { @size(16) x: f32, }
        \\@group(0) @binding(0) var<uniform> s: S;
    );
    const b = findBinding(result.bindings.items, "s") orelse return error.TestExpectedBinding;
    const layout = b.layout orelse return error.TestExpectedLayout;
    const ti = layout.fields.items[0].type_info orelse return error.TestExpectedTypeInfo;
    try std.testing.expect(ti.* == .scalar);
    try std.testing.expectEqual(@as(u32, 16), ti.scalar.size);
}

// =========================================================================
// @override constants + workgroup_size linkage
// =========================================================================

test "reflect: collects @id-tagged overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\@id(0) override WG_X: u32 = 64u;
        \\@id(1) override WG_Y: u32 = 1u;
        \\override WG_Z: u32;
        \\@compute @workgroup_size(WG_X, WG_Y, WG_Z)
        \\fn main() {}
    );
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    try std.testing.expectEqual(@as(usize, 3), result.overrides.items.len);

    // overrides[0] = @id(0) WG_X
    try std.testing.expectEqualStrings("WG_X", result.overrides.items[0].name);
    try std.testing.expectEqual(@as(?u32, 0), result.overrides.items[0].id);
    try std.testing.expectEqualStrings("u32", result.overrides.items[0].typ);
    try std.testing.expectEqualStrings("64u", result.overrides.items[0].default);

    // overrides[2] = WG_Z (no id, no default)
    try std.testing.expectEqualStrings("WG_Z", result.overrides.items[2].name);
    try std.testing.expectEqual(@as(?u32, null), result.overrides.items[2].id);
    try std.testing.expectEqualStrings("", result.overrides.items[2].default);
}

test "reflect: workgroup_size with override identifiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\override WG_X: u32 = 64u;
        \\override WG_Y: u32 = 1u;
        \\override WG_Z: u32 = 1u;
        \\@compute @workgroup_size(WG_X, WG_Y, WG_Z)
        \\fn main() {}
    );
    try std.testing.expectEqual(@as(usize, 1), result.entry_points.items.len);
    const ep = result.entry_points.items[0];
    try std.testing.expect(ep.has_workgroup_size);
    // Each axis is override-driven → reported as 0.
    try std.testing.expectEqual([3]u32{ 0, 0, 0 }, ep.workgroup_size);
    // overrides list captures the names in argument order.
    try std.testing.expectEqual(@as(usize, 3), ep.overrides.items.len);
    try std.testing.expectEqualStrings("WG_X", ep.overrides.items[0]);
    try std.testing.expectEqualStrings("WG_Y", ep.overrides.items[1]);
    try std.testing.expectEqualStrings("WG_Z", ep.overrides.items[2]);
}

test "reflect: workgroup_size mixed literal + override" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\override WG_X: u32 = 64u;
        \\@compute @workgroup_size(WG_X, 8, 1)
        \\fn main() {}
    );
    const ep = result.entry_points.items[0];
    try std.testing.expectEqual([3]u32{ 0, 8, 1 }, ep.workgroup_size);
    try std.testing.expectEqual(@as(usize, 1), ep.overrides.items.len);
    try std.testing.expectEqualStrings("WG_X", ep.overrides.items[0]);
}

test "reflect: workgroup_size from const-expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\const WG: u32 = 8u * 2u;
        \\@compute @workgroup_size(WG, 1, 1)
        \\fn main() {}
    );
    const ep = result.entry_points.items[0];
    try std.testing.expectEqual([3]u32{ 16, 1, 1 }, ep.workgroup_size);
    try std.testing.expectEqual(@as(usize, 0), ep.overrides.items.len);
}

test "reflect: override JSON output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\@id(7) override S: f32 = 0.5;
        \\@compute @workgroup_size(1)
        \\fn main() {}
    );
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try result.toJson(&buf, alloc);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"overrides\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"id\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"name\":\"S\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"default\":\"0.5\"") != null);
}

// =========================================================================
// Entry-point inputs / outputs (@location, @builtin, @interpolate)
// =========================================================================

test "reflect: vertex_main inputs by @location" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\@vertex
        \\fn vs_main(@location(0) position: vec3<f32>, @location(1) color: vec4<f32>) -> @builtin(position) vec4<f32> {
        \\  return vec4<f32>(position, 1.0);
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), result.entry_points.items.len);
    const ep = result.entry_points.items[0];
    try std.testing.expectEqualStrings("vertex", ep.stage);

    try std.testing.expectEqual(@as(usize, 2), ep.inputs.items.len);
    try std.testing.expectEqualStrings("position", ep.inputs.items[0].name);
    try std.testing.expectEqual(@as(?u32, 0), ep.inputs.items[0].location);
    try std.testing.expectEqualStrings("color", ep.inputs.items[1].name);
    try std.testing.expectEqual(@as(?u32, 1), ep.inputs.items[1].location);

    try std.testing.expectEqual(@as(usize, 1), ep.outputs.items.len);
    try std.testing.expectEqualStrings("position", ep.outputs.items[0].builtin);
}

test "reflect: struct-typed return flattens into outputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\struct VsOut {
        \\  @builtin(position) pos: vec4<f32>,
        \\  @location(0) color: vec3<f32>,
        \\  @location(1) @interpolate(flat) idx: u32,
        \\}
        \\@vertex fn vs() -> VsOut { var o: VsOut; return o; }
    );
    const ep = result.entry_points.items[0];
    try std.testing.expectEqual(@as(usize, 3), ep.outputs.items.len);

    try std.testing.expectEqualStrings("pos", ep.outputs.items[0].name);
    try std.testing.expectEqualStrings("position", ep.outputs.items[0].builtin);

    try std.testing.expectEqualStrings("color", ep.outputs.items[1].name);
    try std.testing.expectEqual(@as(?u32, 0), ep.outputs.items[1].location);

    try std.testing.expectEqualStrings("idx", ep.outputs.items[2].name);
    try std.testing.expectEqual(@as(?u32, 1), ep.outputs.items[2].location);
    const ii = ep.outputs.items[2].interpolate orelse return error.TestExpectedInterpolate;
    try std.testing.expectEqualStrings("flat", ii.type);
}

test "reflect: struct-typed parameter flattens into inputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\struct FsIn {
        \\  @location(0) uv: vec2<f32>,
        \\  @builtin(position) coord: vec4<f32>,
        \\}
        \\@fragment fn fs(in: FsIn) -> @location(0) vec4<f32> { return vec4<f32>(0.0); }
    );
    const ep = result.entry_points.items[0];
    try std.testing.expectEqual(@as(usize, 2), ep.inputs.items.len);
    try std.testing.expectEqualStrings("uv", ep.inputs.items[0].name);
    try std.testing.expectEqual(@as(?u32, 0), ep.inputs.items[0].location);
    try std.testing.expectEqualStrings("coord", ep.inputs.items[1].name);
    try std.testing.expectEqualStrings("position", ep.inputs.items[1].builtin);

    try std.testing.expectEqual(@as(usize, 1), ep.outputs.items.len);
    try std.testing.expectEqual(@as(?u32, 0), ep.outputs.items[0].location);
}

test "reflect: @interpolate type+sampling captured" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\@vertex
        \\fn vs(@location(0) @interpolate(linear, centroid) p: vec2<f32>) -> @builtin(position) vec4<f32> {
        \\  return vec4<f32>(p, 0.0, 1.0);
        \\}
    );
    const ep = result.entry_points.items[0];
    const ii = ep.inputs.items[0].interpolate orelse return error.TestExpectedInterpolate;
    try std.testing.expectEqualStrings("linear", ii.type);
    try std.testing.expectEqualStrings("centroid", ii.sampling);
}

test "reflect: compute entry has empty inputs/outputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\@compute @workgroup_size(8, 8) fn cs(@builtin(global_invocation_id) gid: vec3<u32>) {}
    );
    const ep = result.entry_points.items[0];
    // @builtin(global_invocation_id) is still classified as an input.
    try std.testing.expectEqual(@as(usize, 1), ep.inputs.items.len);
    try std.testing.expectEqualStrings("global_invocation_id", ep.inputs.items[0].builtin);
    try std.testing.expectEqual(@as(usize, 0), ep.outputs.items.len);
}

test "reflect: entry I/O JSON output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\@vertex fn vs(@location(0) p: vec3<f32>) -> @builtin(position) vec4<f32> {
        \\  return vec4<f32>(p, 1.0);
        \\}
    );
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try result.toJson(&buf, alloc);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"inputs\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"outputs\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"location\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"builtin\":\"position\"") != null);
}

// =========================================================================
// Call graph + per-entry-point resource attribution
// =========================================================================

fn findFunction(fns: []const wgslender.Reflect.FunctionInfo, name: []const u8) ?*const wgslender.Reflect.FunctionInfo {
    for (fns) |*f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

fn findEntryByName(eps: []const wgslender.Reflect.EntryPointInfo, name: []const u8) ?*const wgslender.Reflect.EntryPointInfo {
    for (eps) |*e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

test "reflect: function direct resources collected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\@group(0) @binding(0) var<uniform> u: f32;
        \\@group(0) @binding(1) var<storage, read_write> s: array<f32>;
        \\fn helper() -> f32 { return u + s[0]; }
        \\@compute @workgroup_size(1) fn cs() { let x = helper(); }
    );
    const helper = findFunction(result.functions.items, "helper") orelse return error.TestExpectedFunction;
    try std.testing.expectEqual(@as(usize, 2), helper.direct_resources.items.len);
    try std.testing.expectEqualStrings("u", helper.direct_resources.items[0]);
    try std.testing.expectEqualStrings("s", helper.direct_resources.items[1]);
    try std.testing.expectEqual(@as(usize, 0), helper.calls.items.len);

    const cs = findFunction(result.functions.items, "cs") orelse return error.TestExpectedFunction;
    try std.testing.expectEqual(@as(usize, 1), cs.calls.items.len);
    try std.testing.expectEqualStrings("helper", cs.calls.items[0]);
    try std.testing.expectEqual(@as(usize, 0), cs.direct_resources.items.len);
}

test "reflect: transitive resources flow to entry point" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\@group(0) @binding(0) var<uniform> u1: f32;
        \\@group(0) @binding(1) var<uniform> u2: f32;
        \\@group(0) @binding(2) var<uniform> u3: f32;
        \\fn inner() -> f32 { return u3; }
        \\fn middle() -> f32 { return u2 + inner(); }
        \\@compute @workgroup_size(1) fn cs() { let x = u1 + middle(); }
    );
    const ep = findEntryByName(result.entry_points.items, "cs") orelse return error.TestExpectedEntry;
    try std.testing.expectEqual(@as(usize, 3), ep.resources.items.len);
    // Order = first-observed during BFS (entry, then callees).
    try std.testing.expectEqualStrings("u1", ep.resources.items[0]);
    try std.testing.expectEqualStrings("u2", ep.resources.items[1]);
    try std.testing.expectEqualStrings("u3", ep.resources.items[2]);
}

test "reflect: in_use marks reachable functions only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\fn used() -> f32 { return 1.0; }
        \\fn unused() -> f32 { return 2.0; }
        \\@compute @workgroup_size(1) fn cs() { let x = used(); }
    );
    try std.testing.expect((findFunction(result.functions.items, "used") orelse return error.TestExpectedFunction).in_use);
    try std.testing.expect((findFunction(result.functions.items, "cs") orelse return error.TestExpectedFunction).in_use);
    try std.testing.expect(!(findFunction(result.functions.items, "unused") orelse return error.TestExpectedFunction).in_use);
}

test "reflect: textureSample records bidirectional relations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\@group(0) @binding(0) var samp: sampler;
        \\@group(0) @binding(1) var tex: texture_2d<f32>;
        \\@fragment fn fs(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
        \\  return textureSample(tex, samp, uv);
        \\}
    );
    const tex = findBinding(result.bindings.items, "tex") orelse return error.TestExpectedBinding;
    const samp = findBinding(result.bindings.items, "samp") orelse return error.TestExpectedBinding;
    try std.testing.expectEqual(@as(usize, 1), tex.relations.items.len);
    try std.testing.expectEqualStrings("samp", tex.relations.items[0]);
    try std.testing.expectEqual(@as(usize, 1), samp.relations.items.len);
    try std.testing.expectEqualStrings("tex", samp.relations.items[0]);
}

test "reflect: transitive overrides flow to entry point" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\override SCALE: f32 = 1.0;
        \\override BIAS: f32 = 0.0;
        \\fn helper(x: f32) -> f32 { return x * SCALE + BIAS; }
        \\@compute @workgroup_size(1) fn cs() { let _x = helper(1.0); }
    );
    const ep = findEntryByName(result.entry_points.items, "cs") orelse return error.TestExpectedEntry;
    try std.testing.expectEqual(@as(usize, 2), ep.overrides.items.len);
    try std.testing.expectEqualStrings("SCALE", ep.overrides.items[0]);
    try std.testing.expectEqualStrings("BIAS", ep.overrides.items[1]);
}

test "reflect: shadowed local var doesn't pollute resources" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\@group(0) @binding(0) var<uniform> u1: f32;
        \\@group(0) @binding(1) var<uniform> u2: f32;
        \\@vertex fn vs() -> @builtin(position) vec4<f32> {
        \\  var u2: f32 = 5.0;       // shadows global u2
        \\  return vec4<f32>(u1 + u2, 0.0, 0.0, 1.0);
        \\}
    );
    const ep = findEntryByName(result.entry_points.items, "vs") orelse return error.TestExpectedEntry;
    // The shadowed local `u2` rebinds the symbol, so the global `u2`
    // shouldn't surface in resources.
    try std.testing.expectEqual(@as(usize, 1), ep.resources.items.len);
    try std.testing.expectEqualStrings("u1", ep.resources.items[0]);
}

test "reflect: functions JSON output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\@compute @workgroup_size(1) fn cs() {}
    );
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try result.toJson(&buf, alloc);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"functions\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"inUse\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"directResources\":") != null);
}

// =========================================================================
// JSON schema versioning + v2 subset views
// =========================================================================

test "reflect: v2 JSON has version marker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\@group(0) @binding(0) var<uniform> u: vec3f;
    );
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try result.toJsonVersion(&buf, alloc, .v2);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"version\":2") != null);
}

test "reflect: v1 JSON omits version + subset views" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\@group(0) @binding(0) var<uniform> u: vec3f;
        \\@group(0) @binding(1) var samp: sampler;
    );
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try result.toJsonVersion(&buf, alloc, .v1);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"version\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"uniforms\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"samplers\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"aliases\":") == null);
    // bindings[] is still present in v1 — that's the only place a sampler appears.
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"bindings\":[") != null);
}

test "reflect: v2 subset views filter bindings by kind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\struct U { v: vec4f }
        \\struct S { data: array<f32> }
        \\@group(0) @binding(0) var<uniform> u: U;
        \\@group(0) @binding(1) var<storage, read_write> s: S;
        \\@group(0) @binding(2) var tex: texture_2d<f32>;
        \\@group(0) @binding(3) var samp: sampler;
        \\@group(0) @binding(4) var depth: texture_depth_2d;
        \\@group(0) @binding(5) var compare: sampler_comparison;
        \\@compute @workgroup_size(1) fn cs() {
        \\  let _ = u.v + textureSampleLevel(tex, samp, vec2f(0.0), 0.0);
        \\  s.data[0] = textureSampleCompareLevel(depth, compare, vec2f(0.0), 0.0);
        \\}
    );
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try result.toJsonVersion(&buf, alloc, .v2);

    // Each bucket exists.
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"uniforms\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"storage\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"textures\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"samplers\":[") != null);

    // u went into uniforms, s into storage. Sanity-check the "uniforms" bucket
    // contains "u" and not the storage var, by slicing between markers.
    const u_key = std.mem.indexOf(u8, buf.items, "\"uniforms\":[").?;
    const u_end = u_key + (std.mem.indexOf(u8, buf.items[u_key..], "],").?);
    const u_slice = buf.items[u_key..u_end];
    try std.testing.expect(std.mem.indexOf(u8, u_slice, "\"name\":\"u\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, u_slice, "\"name\":\"s\"") == null);
}

test "reflect: v2 aliases captured" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\alias Color = vec3f;
        \\alias Material = u32;
        \\@group(0) @binding(0) var<uniform> color: Color;
    );
    try std.testing.expectEqual(@as(usize, 2), result.aliases.items.len);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try result.toJsonVersion(&buf, alloc, .v2);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"aliases\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"name\":\"Color\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"name\":\"Material\"") != null);
}

test "reflect: v1 JSON does not surface aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\alias Color = vec3f;
    );
    // Collected internally even when v1 hides them — keeps the in-memory
    // shape stable across format choices.
    try std.testing.expectEqual(@as(usize, 1), result.aliases.items.len);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try result.toJsonVersion(&buf, alloc, .v1);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"aliases\":") == null);
}

test "reflect: storage texture lands in textures[] subset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try reflectSource(alloc,
        \\@group(0) @binding(0) var img: texture_storage_2d<rgba8unorm, write>;
    );
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try result.toJsonVersion(&buf, alloc, .v2);
    const tex_key = std.mem.indexOf(u8, buf.items, "\"textures\":[").?;
    const tex_end = tex_key + (std.mem.indexOf(u8, buf.items[tex_key..], "],").?);
    try std.testing.expect(std.mem.indexOf(u8, buf.items[tex_key..tex_end], "\"name\":\"img\"") != null);
}
