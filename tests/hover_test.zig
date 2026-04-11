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

test "hover: function name shows info" {
    const source: [:0]const u8 = "fn my_func() -> f32 { return 1.0; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = posAt(source, "my_func") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "my_func") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "function") != null);
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
