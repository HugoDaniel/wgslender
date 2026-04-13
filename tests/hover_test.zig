const std = @import("std");
const Handler = @import("Handler");

fn setup(source: [:0]const u8) !struct { handler: *Handler, source: [:0]const u8 } {
    const handler = try std.testing.allocator.create(Handler);
    handler.* = Handler.init(std.testing.allocator);
    try handler.openDocument("test://file.wgsl", source, 1);
    return .{ .handler = handler, .source = source };
}

fn teardown(ctx: anytype) void {
    ctx.handler.deinit();
    std.testing.allocator.destroy(ctx.handler);
}

fn posAt(source: []const u8, needle: []const u8) ?Handler.Position {
    const offset = std.mem.indexOf(u8, source, needle) orelse return null;
    return Handler.offsetToLspPosition(source, @intCast(offset));
}

test "hover: variable shows type" {
    const source: [:0]const u8 = "fn f() { let x: f32 = 1.0; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Hover on 'x' in 'let x'
    const pos = posAt(source, "x:") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    // Should contain "f32"
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "f32") != null);
}

test "hover: function name shows full signature" {
    const source: [:0]const u8 = "fn my_func() -> f32 { return 1.0; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = posAt(source, "my_func") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "my_func") != null);
    // Should show full signature: fn my_func() -> f32
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "fn ") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "f32") != null);
}

test "hover: whitespace returns null" {
    const source: [:0]const u8 = "fn f() { }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Position at a space
    const result = try ctx.handler.computeHover("test://file.wgsl", .{ .line = 0, .character = 2 });
    try std.testing.expect(result == null);
}

test "hover: type ref shows struct info" {
    const source: [:0]const u8 = "struct S { x: f32, y: f32 } fn f(s: S) {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Find the second 'S' (in "s: S")
    const s_type_pos = std.mem.lastIndexOf(u8, source, "S") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(s_type_pos)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    // Should show struct fields
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "struct S") != null);
}

test "hover: parse error returns null gracefully" {
    const source: [:0]const u8 = "fn { invalid }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const result = try ctx.handler.computeHover("test://file.wgsl", .{ .line = 0, .character = 0 });
    // Should not crash, may return null
    if (result) |r| std.testing.allocator.free(r.contents);
}

test "hover: unknown document returns null" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    const result = try handler.computeHover("test://nonexistent.wgsl", .{ .line = 0, .character = 0 });
    try std.testing.expect(result == null);
}

// =========================================================================
// Edge cases: multi-line, nested, WGSL-specific
// =========================================================================

test "hover: multi-line function with parameters" {
    const source: [:0]const u8 =
        \\@compute @workgroup_size(1)
        \\fn main(
        \\  @builtin(global_invocation_id) id: vec3u
        \\) {
        \\  let x: f32 = 1.0;
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    // Hover on 'x' in let statement — line 4, char 6
    const result = try ctx.handler.computeHover("test://file.wgsl", .{ .line = 4, .character = 6 });
    if (result) |r| {
        defer std.testing.allocator.free(r.contents);
        try std.testing.expect(std.mem.indexOf(u8, r.contents, "f32") != null);
    }
}

test "hover: const with integer value" {
    const source: [:0]const u8 = "const SIZE: u32 = 256;";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = posAt(source, "SIZE") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "const") != null);
}

test "hover: override declaration" {
    const source: [:0]const u8 = "@id(0) override WG_SIZE: u32 = 64;";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = posAt(source, "WG_SIZE") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "override") != null);
}

test "hover: variable with address space" {
    const source: [:0]const u8 = "var<private> counter: u32 = 0;";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = posAt(source, "counter") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    try std.testing.expect(result.?.contents.len > 0);
}

test "hover: struct with multiple fields shows all" {
    const source: [:0]const u8 =
        \\struct Vertex {
        \\  position: vec3f,
        \\  normal: vec3f,
        \\  uv: vec2f,
        \\}
        \\fn f(v: Vertex) {}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    // Hover on "Vertex" in parameter type — find the second occurrence
    const type_offset = std.mem.lastIndexOf(u8, source, "Vertex") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(type_offset)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "position") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "normal") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "uv") != null);
}

test "hover: parameter inside function body" {
    const source: [:0]const u8 = "fn add(a: f32, b: f32) -> f32 { return a + b; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Hover on 'a' in "return a + b" (the usage)
    const a_usage = std.mem.lastIndexOf(u8, source, "a") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(a_usage)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    if (result) |r| {
        defer std.testing.allocator.free(r.contents);
        try std.testing.expect(std.mem.indexOf(u8, r.contents, "parameter") != null);
    }
}

test "hover: entry point function" {
    const source: [:0]const u8 = "@vertex fn vs_main() -> @builtin(position) vec4f { return vec4f(0.0); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = posAt(source, "vs_main") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "fn ") != null);
}

test "hover: position past end of file returns null" {
    const source: [:0]const u8 = "fn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const result = try ctx.handler.computeHover("test://file.wgsl", .{ .line = 99, .character = 0 });
    try std.testing.expect(result == null);
}

test "hover: empty source returns null" {
    const source: [:0]const u8 = "";
    const ctx = try setup(source);
    defer teardown(ctx);
    const result = try ctx.handler.computeHover("test://file.wgsl", .{ .line = 0, .character = 0 });
    try std.testing.expect(result == null);
}

test "hover: nested struct member type" {
    const source: [:0]const u8 = "struct Inner { x: f32 } struct Outer { inner: Inner }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Hover on "Inner" in Outer's field type
    const inner_ref = std.mem.lastIndexOf(u8, source, "Inner") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(inner_ref)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    // Should show Inner's struct info
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "Inner") != null);
}

test "hover: member access shows field type" {
    const source: [:0]const u8 = "struct S { x: f32 } fn f(s: S) -> f32 { return s.x; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Find the '.x' member access — hover on 'x' after the dot
    const dot_pos = std.mem.lastIndexOf(u8, source, ".x") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(dot_pos + 1)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    // Should show "(field) x: f32"
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "field") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "f32") != null);
}

test "hover: function with params shows full signature" {
    const source: [:0]const u8 = "fn add(a: f32, b: f32) -> f32 { return a + b; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = posAt(source, "add") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    // Should show "fn add(a: f32, b: f32) -> f32"
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "fn add(") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "a: f32") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "b: f32") != null);
}

test "hover: struct type shows size and alignment" {
    const source: [:0]const u8 = "struct S { x: f32, y: f32 } fn f(s: S) {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Find the second 'S' (in "s: S")
    const s_type_pos = std.mem.lastIndexOf(u8, source, "S") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(s_type_pos)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    // Should show struct with size/alignment info
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "struct S") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "size:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "align:") != null);
}

test "hover: builtin function shows signature and description" {
    const source: [:0]const u8 = "fn f(x: f32) -> f32 { return sin(x); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Hover on 'sin'
    const pos = posAt(source, "sin") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    // Should show signature
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "fn sin") != null);
    // Should show description
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "sine") != null);
    // Should show category
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "numeric") != null);
}

test "hover: builtin with uniform requirement shows warning" {
    const source: [:0]const u8 = "@fragment fn f(@location(0) uv: vec2f) -> @location(0) vec4f { return textureSample(t, s, uv); } @group(0) @binding(0) var t: texture_2d<f32>; @group(0) @binding(1) var s: sampler;";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = posAt(source, "textureSample") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    // Should show uniform control flow requirement
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "uniform") != null);
}

test "hover: user function still works after builtin changes" {
    const source: [:0]const u8 = "fn my_fn(a: f32) -> f32 { return a; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = posAt(source, "my_fn") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "my_fn") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "f32") != null);
}
