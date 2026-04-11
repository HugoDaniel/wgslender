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

fn hasItem(items: []const Handler.CompletionItem, label: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.label, label)) return true;
    }
    return false;
}

test "completion: general includes keywords" {
    const source: [:0]const u8 = "fn f() { }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Position in empty function body (after space)
    const items = try ctx.handler.computeCompletion("test://file.wgsl", .{ .line = 0, .character = 9 });
    defer std.testing.allocator.free(items);
    try std.testing.expect(hasItem(items, "return"));
    try std.testing.expect(hasItem(items, "let"));
    try std.testing.expect(hasItem(items, "var"));
    try std.testing.expect(hasItem(items, "if"));
}

test "completion: general includes builtins" {
    const source: [:0]const u8 = "fn f() { }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const items = try ctx.handler.computeCompletion("test://file.wgsl", .{ .line = 0, .character = 9 });
    defer std.testing.allocator.free(items);
    try std.testing.expect(hasItem(items, "sin"));
    try std.testing.expect(hasItem(items, "cos"));
    try std.testing.expect(hasItem(items, "dot"));
}

test "completion: general includes type names" {
    const source: [:0]const u8 = "fn f() { }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const items = try ctx.handler.computeCompletion("test://file.wgsl", .{ .line = 0, .character = 9 });
    defer std.testing.allocator.free(items);
    try std.testing.expect(hasItem(items, "f32"));
    try std.testing.expect(hasItem(items, "vec3"));
    try std.testing.expect(hasItem(items, "mat4x4"));
}

test "completion: general includes module symbols" {
    const source: [:0]const u8 = "const MY_CONST: f32 = 1.0; fn f() { }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const items = try ctx.handler.computeCompletion("test://file.wgsl", .{ .line = 0, .character = 36 });
    defer std.testing.allocator.free(items);
    try std.testing.expect(hasItem(items, "MY_CONST"));
}

test "completion: after @ lists attributes" {
    const source: [:0]const u8 = "@";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Position right after '@'
    const items = try ctx.handler.computeCompletion("test://file.wgsl", .{ .line = 0, .character = 1 });
    defer std.testing.allocator.free(items);
    try std.testing.expect(hasItem(items, "vertex"));
    try std.testing.expect(hasItem(items, "fragment"));
    try std.testing.expect(hasItem(items, "compute"));
    try std.testing.expect(hasItem(items, "group"));
    try std.testing.expect(hasItem(items, "binding"));
    try std.testing.expect(hasItem(items, "location"));
    // Should NOT contain keywords
    try std.testing.expect(!hasItem(items, "fn"));
}

test "completion: empty file returns keywords and types" {
    const source: [:0]const u8 = "";
    const ctx = try setup(source);
    defer teardown(ctx);
    const items = try ctx.handler.computeCompletion("test://file.wgsl", .{ .line = 0, .character = 0 });
    defer std.testing.allocator.free(items);
    try std.testing.expect(items.len > 0);
    try std.testing.expect(hasItem(items, "fn"));
    try std.testing.expect(hasItem(items, "struct"));
}

test "completion: unknown document returns empty" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    const items = try handler.computeCompletion("test://nonexistent.wgsl", .{ .line = 0, .character = 0 });
    try std.testing.expectEqual(@as(usize, 0), items.len);
}
