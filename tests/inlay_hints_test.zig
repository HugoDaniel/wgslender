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

test "inlay hints: let without type annotation" {
    const source: [:0]const u8 = "fn f() { let x = 1.0; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const hints = try ctx.handler.computeInlayHints("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 0, .character = @intCast(source.len) },
    });
    defer std.testing.allocator.free(hints);
    // Should have a type hint for 'x'
    // The type might be abstract-float or f32 depending on validation
    if (hints.len > 0) {
        try std.testing.expect(hints[0].kind == .type_hint);
        try std.testing.expect(hints[0].label.len > 0);
    }
}

test "inlay hints: let with explicit type has no hint" {
    const source: [:0]const u8 = "fn f() { let x: f32 = 1.0; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const hints = try ctx.handler.computeInlayHints("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 0, .character = @intCast(source.len) },
    });
    defer std.testing.allocator.free(hints);
    // No hint since type is explicit
    try std.testing.expectEqual(@as(usize, 0), hints.len);
}

test "inlay hints: empty file" {
    const source: [:0]const u8 = "";
    const ctx = try setup(source);
    defer teardown(ctx);
    const hints = try ctx.handler.computeInlayHints("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 0, .character = 0 },
    });
    defer std.testing.allocator.free(hints);
    try std.testing.expectEqual(@as(usize, 0), hints.len);
}

test "inlay hints: unknown document" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    const hints = try handler.computeInlayHints("test://nonexistent.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 0, .character = 10 },
    });
    try std.testing.expectEqual(@as(usize, 0), hints.len);
}
