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
