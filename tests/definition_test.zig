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

test "definition: variable usage jumps to declaration" {
    const source: [:0]const u8 = "const x: f32 = 1.0; fn f() -> f32 { return x; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Find the usage of 'x' in "return x"
    const x_usage = std.mem.lastIndexOf(u8, source, "x") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(x_usage)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeDefinition("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    // Should point to "const x" at line 0, char 6
    try std.testing.expectEqual(@as(u32, 0), result.?.start.line);
    try std.testing.expectEqual(@as(u32, 6), result.?.start.character);
}

test "definition: function call jumps to fn declaration" {
    const source: [:0]const u8 = "fn helper() {} fn main() { helper(); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Find "helper()" call (second occurrence)
    const call_pos = std.mem.lastIndexOf(u8, source, "helper") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(call_pos)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeDefinition("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    // Should point to "fn helper" at line 0, char 3
    try std.testing.expectEqual(@as(u32, 0), result.?.start.line);
    try std.testing.expectEqual(@as(u32, 3), result.?.start.character);
}

test "definition: type annotation jumps to struct" {
    const source: [:0]const u8 = "struct Point { x: f32 } fn f(p: Point) {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Find "Point" in parameter type
    const type_pos = std.mem.lastIndexOf(u8, source, "Point") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(type_pos)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeDefinition("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    // Should point to "struct Point" at line 0, char 7
    try std.testing.expectEqual(@as(u32, 0), result.?.start.line);
    try std.testing.expectEqual(@as(u32, 7), result.?.start.character);
}

test "definition: on declaration name itself returns own location" {
    const source: [:0]const u8 = "fn my_fn() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 3) orelse return error.TestUnexpectedResult; // 'm' in my_fn
    const result = try ctx.handler.computeDefinition("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u32, 3), result.?.start.character);
}

test "definition: whitespace returns null" {
    const source: [:0]const u8 = "fn f() { }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const result = try ctx.handler.computeDefinition("test://file.wgsl", .{ .line = 0, .character = 2 });
    try std.testing.expect(result == null);
}

test "definition: unknown document returns null" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    const result = try handler.computeDefinition("test://nonexistent.wgsl", .{ .line = 0, .character = 0 });
    try std.testing.expect(result == null);
}

// =========================================================================
// Edge cases
// =========================================================================

test "definition: multi-line function parameter usage" {
    const source: [:0]const u8 =
        \\fn compute(
        \\  x: f32,
        \\  y: f32,
        \\) -> f32 {
        \\  return x + y;
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    // Jump from 'x' in "return x + y" to 'x' parameter declaration
    const x_usage = std.mem.lastIndexOf(u8, source, "x") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(x_usage)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeDefinition("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    // Parameter 'x' is on line 1
    try std.testing.expectEqual(@as(u32, 1), result.?.start.line);
}

test "definition: const used across multiple functions" {
    const source: [:0]const u8 =
        \\const PI: f32 = 3.14159;
        \\fn circle_area(r: f32) -> f32 { return PI * r * r; }
        \\fn circumference(r: f32) -> f32 { return 2.0 * PI * r; }
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    // Jump from last 'PI' usage to declaration
    const pi_usage = std.mem.lastIndexOf(u8, source, "PI") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(pi_usage)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeDefinition("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u32, 0), result.?.start.line); // const PI is on line 0
}

test "definition: struct used as function return type" {
    const source: [:0]const u8 =
        \\struct Color { r: f32, g: f32, b: f32, a: f32 }
        \\fn red() -> Color { return Color(1.0, 0.0, 0.0, 1.0); }
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    // Jump from "Color" return type to struct
    const color_in_ret = std.mem.indexOf(u8, source, "-> Color") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(color_in_ret + 3)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeDefinition("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u32, 0), result.?.start.line);
}

test "definition: position past end of file returns null" {
    const source: [:0]const u8 = "fn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const result = try ctx.handler.computeDefinition("test://file.wgsl", .{ .line = 99, .character = 0 });
    try std.testing.expect(result == null);
}

test "definition: empty source returns null" {
    const source: [:0]const u8 = "";
    const ctx = try setup(source);
    defer teardown(ctx);
    const result = try ctx.handler.computeDefinition("test://file.wgsl", .{ .line = 0, .character = 0 });
    try std.testing.expect(result == null);
}

test "definition: override declaration" {
    const source: [:0]const u8 = "@id(0) override WG: u32 = 64; fn f() { let x = WG; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Jump from WG usage in function body to override declaration
    const wg_usage = std.mem.lastIndexOf(u8, source, "WG") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(wg_usage)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeDefinition("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u32, 0), result.?.start.line);
}

test "definition: alias type reference" {
    const source: [:0]const u8 = "alias Float = f32; fn f() -> Float { return 1.0; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Jump from Float usage to alias declaration
    const float_usage = std.mem.lastIndexOf(u8, source, "Float") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(float_usage)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeDefinition("test://file.wgsl", pos);
    try std.testing.expect(result != null);
}

// =========================================================================
// Struct field navigation (foo.bar -> field declaration)
// =========================================================================

test "definition: struct field on parameter base" {
    const source: [:0]const u8 = "struct P { x: f32, y: f32 } fn f(p: P) -> f32 { return p.x; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Cursor on the 'x' in 'p.x'
    const dot = std.mem.lastIndexOf(u8, source, ".x") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(dot + 1)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeDefinition("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    // 'x' is declared at offset 11 ("struct P { x"); single-char field.
    try std.testing.expectEqual(@as(u32, 0), result.?.start.line);
    try std.testing.expectEqual(@as(u32, 11), result.?.start.character);
    try std.testing.expectEqual(@as(u32, 0), result.?.end.line);
    try std.testing.expectEqual(@as(u32, 12), result.?.end.character);
}

test "definition: struct field on local var base" {
    const source: [:0]const u8 = "struct P { x: f32, y: f32 } fn f() -> f32 { var p: P = P(0.0, 0.0); return p.x; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const dot = std.mem.lastIndexOf(u8, source, ".x") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(dot + 1)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeDefinition("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u32, 0), result.?.start.line);
    try std.testing.expectEqual(@as(u32, 11), result.?.start.character);
    try std.testing.expectEqual(@as(u32, 0), result.?.end.line);
    try std.testing.expectEqual(@as(u32, 12), result.?.end.character);
}

test "definition: chained member access jumps to deepest field" {
    const source: [:0]const u8 = "struct B { v: f32 } struct A { b: B } fn f(a: A) -> f32 { return a.b.v; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Cursor on the 'v' in 'a.b.v'
    const dot_v = std.mem.lastIndexOf(u8, source, ".v") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(dot_v + 1)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeDefinition("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    // 'v' declared at offset 11 in "struct B { v: f32 }"
    try std.testing.expectEqual(@as(u32, 0), result.?.start.line);
    try std.testing.expectEqual(@as(u32, 11), result.?.start.character);
    try std.testing.expectEqual(@as(u32, 0), result.?.end.line);
    try std.testing.expectEqual(@as(u32, 12), result.?.end.character);
}

test "definition: chained member access jumps to intermediate field" {
    const source: [:0]const u8 = "struct B { v: f32 } struct A { b: B } fn f(a: A) -> f32 { return a.b.v; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Cursor on the 'b' in 'a.b.v' — should jump to A's field 'b'
    const dot_b = std.mem.lastIndexOf(u8, source, ".b") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(dot_b + 1)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeDefinition("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    // 'b' declared at offset 31 in "struct A { b: B }"
    try std.testing.expectEqual(@as(u32, 0), result.?.start.line);
    try std.testing.expectEqual(@as(u32, 31), result.?.start.character);
    try std.testing.expectEqual(@as(u32, 0), result.?.end.line);
    try std.testing.expectEqual(@as(u32, 32), result.?.end.character);
}

test "definition: pointer-base field via explicit deref" {
    const source: [:0]const u8 = "struct P { x: f32 } fn f() -> f32 { var p: P = P(0.0); let q = &p; return (*q).x; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Cursor on the 'x' in '(*q).x'
    const dot = std.mem.lastIndexOf(u8, source, ").x") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(dot + 2)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeDefinition("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u32, 0), result.?.start.line);
    try std.testing.expectEqual(@as(u32, 11), result.?.start.character);
    try std.testing.expectEqual(@as(u32, 0), result.?.end.line);
    try std.testing.expectEqual(@as(u32, 12), result.?.end.character);
}

test "definition: vector swizzle returns null" {
    const source: [:0]const u8 = "fn f() { let v = vec3f(0.0); let s = v.xyz; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const dot = std.mem.lastIndexOf(u8, source, ".xyz") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(dot + 1)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeDefinition("test://file.wgsl", pos);
    try std.testing.expect(result == null);
}

test "definition: unknown struct member returns null" {
    const source: [:0]const u8 = "struct P { x: f32 } fn f(p: P) -> f32 { return p.nope; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const dot = std.mem.lastIndexOf(u8, source, ".nope") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(dot + 1)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeDefinition("test://file.wgsl", pos);
    try std.testing.expect(result == null);
}

test "definition: const in @group attribute argument" {
    const source: [:0]const u8 = "const BG_INDEX: u32 = 0; @group(BG_INDEX) @binding(0) var<uniform> u: vec4f;";
    const ctx = try setup(source);
    defer teardown(ctx);
    const usage = std.mem.lastIndexOf(u8, source, "BG_INDEX") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(usage)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeDefinition("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u32, 0), result.?.start.line);
    try std.testing.expectEqual(@as(u32, 6), result.?.start.character);
}

test "definition: const in @binding attribute argument" {
    const source: [:0]const u8 = "const BIND_IDX: u32 = 0; @group(0) @binding(BIND_IDX) var<uniform> u: vec4f;";
    const ctx = try setup(source);
    defer teardown(ctx);
    const usage = std.mem.lastIndexOf(u8, source, "BIND_IDX") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(usage)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeDefinition("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u32, 0), result.?.start.line);
    try std.testing.expectEqual(@as(u32, 6), result.?.start.character);
}

test "definition: override in @workgroup_size attribute argument" {
    const source: [:0]const u8 = "override WG_X: u32 = 16; @compute @workgroup_size(WG_X) fn cs() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const usage = std.mem.lastIndexOf(u8, source, "WG_X") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(usage)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeDefinition("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u32, 0), result.?.start.line);
    try std.testing.expectEqual(@as(u32, 9), result.?.start.character);
}

test "definition: const in struct member @location attribute argument" {
    const source: [:0]const u8 = "const LOC: u32 = 0; struct V { @location(LOC) p: vec4f }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const usage = std.mem.lastIndexOf(u8, source, "LOC") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(usage)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeDefinition("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u32, 0), result.?.start.line);
    try std.testing.expectEqual(@as(u32, 6), result.?.start.character);
}

test "definition: const in fn parameter @location attribute argument" {
    const source: [:0]const u8 = "const PARAM_LOC: u32 = 0; fn vs(@location(PARAM_LOC) p: vec4f) -> vec4f { return p; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const usage = std.mem.lastIndexOf(u8, source, "PARAM_LOC") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(usage)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeDefinition("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u32, 0), result.?.start.line);
    try std.testing.expectEqual(@as(u32, 6), result.?.start.character);
}

test "definition: const in return-type @location attribute argument" {
    const source: [:0]const u8 = "const RET_LOC: u32 = 0; @vertex fn vs() -> @location(RET_LOC) vec4f { return vec4f(0); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const usage = std.mem.lastIndexOf(u8, source, "RET_LOC") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(usage)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeDefinition("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u32, 0), result.?.start.line);
    try std.testing.expectEqual(@as(u32, 6), result.?.start.character);
}

test "definition: unknown ident in attribute argument returns null" {
    const source: [:0]const u8 = "@group(NOPE_INDEX) @binding(0) var<uniform> u: vec4f;";
    const ctx = try setup(source);
    defer teardown(ctx);
    const usage = std.mem.lastIndexOf(u8, source, "NOPE_INDEX") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(usage)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeDefinition("test://file.wgsl", pos);
    try std.testing.expect(result == null);
}

test "definition: literal arg in attribute returns null" {
    const source: [:0]const u8 = "@group(0) @binding(0) var<uniform> u: vec4f;";
    const ctx = try setup(source);
    defer teardown(ctx);
    // First '0' lives at offset 7 (right after '@group(')
    const usage = std.mem.indexOf(u8, source, "0") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(usage)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeDefinition("test://file.wgsl", pos);
    try std.testing.expect(result == null);
}
