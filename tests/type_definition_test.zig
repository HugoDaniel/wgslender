const std = @import("std");
const Handler = @import("Handler");

fn setup(source: [:0]const u8) !struct { handler: *Handler } {
    const handler = try std.testing.allocator.create(Handler);
    handler.* = Handler.init(std.testing.allocator);
    try handler.openDocument("test://file.wgsl", source, 1);
    return .{ .handler = handler };
}

fn teardown(ctx: anytype) void {
    ctx.handler.deinit();
    std.testing.allocator.destroy(ctx.handler);
}

test "type definition: variable of struct type" {
    const source: [:0]const u8 = "struct Point { x: f32, y: f32 } fn f(p: Point) {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Find 'p' parameter
    const p_pos = std.mem.indexOf(u8, source, "(p:") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(p_pos + 1)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeTypeDefinition("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    // Should point to "Point" in struct declaration
    try std.testing.expectEqual(@as(u32, 0), result.?.start.line);
    try std.testing.expectEqual(@as(u32, 7), result.?.start.character);
}

test "type definition: scalar type returns null" {
    const source: [:0]const u8 = "fn f() { let x: f32 = 1.0; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 13) orelse return error.TestUnexpectedResult; // 'x'
    const result = try ctx.handler.computeTypeDefinition("test://file.wgsl", pos);
    try std.testing.expect(result == null);
}

test "type definition: whitespace returns null" {
    const source: [:0]const u8 = "fn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const result = try ctx.handler.computeTypeDefinition("test://file.wgsl", .{ .line = 0, .character = 2 });
    try std.testing.expect(result == null);
}

test "type definition: unknown document" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    const result = try handler.computeTypeDefinition("test://nonexistent.wgsl", .{ .line = 0, .character = 0 });
    try std.testing.expect(result == null);
}
