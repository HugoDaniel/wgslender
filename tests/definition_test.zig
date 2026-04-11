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
