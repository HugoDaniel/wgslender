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

test "highlight: variable with reads and writes" {
    const source: [:0]const u8 = "var<private> x: f32 = 1.0; fn f() { x = 2.0; let a = x; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Position on 'x' declaration
    const pos = posAt(source, "x:") orelse return error.TestUnexpectedResult;
    const highlights = try ctx.handler.computeDocumentHighlight("test://file.wgsl", pos);
    try std.testing.expect(highlights != null);
    defer std.testing.allocator.free(highlights.?);
    // Declaration (write) + assignment LHS (write) + read in let = 3
    try std.testing.expectEqual(@as(usize, 3), highlights.?.len);
    // First is declaration (write)
    try std.testing.expectEqual(Handler.HighlightKind.write, highlights.?[0].kind);
    // Second is assignment LHS (write)
    try std.testing.expectEqual(Handler.HighlightKind.write, highlights.?[1].kind);
    // Third is read usage
    try std.testing.expectEqual(Handler.HighlightKind.read, highlights.?[2].kind);
}

test "highlight: const symbol all reads" {
    const source: [:0]const u8 = "const x: f32 = 1.0; fn f() -> f32 { let a = x; return x; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = posAt(source, "x:") orelse return error.TestUnexpectedResult;
    const highlights = try ctx.handler.computeDocumentHighlight("test://file.wgsl", pos);
    try std.testing.expect(highlights != null);
    defer std.testing.allocator.free(highlights.?);
    // Declaration (write) + 2 read usages = 3
    try std.testing.expectEqual(@as(usize, 3), highlights.?.len);
    try std.testing.expectEqual(Handler.HighlightKind.write, highlights.?[0].kind);
    try std.testing.expectEqual(Handler.HighlightKind.read, highlights.?[1].kind);
    try std.testing.expectEqual(Handler.HighlightKind.read, highlights.?[2].kind);
}

test "highlight: whitespace returns null" {
    const source: [:0]const u8 = "fn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const result = try ctx.handler.computeDocumentHighlight("test://file.wgsl", .{ .line = 0, .character = 2 });
    try std.testing.expect(result == null);
}

test "highlight: unknown document returns null" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    const result = try handler.computeDocumentHighlight("test://nonexistent.wgsl", .{ .line = 0, .character = 0 });
    try std.testing.expect(result == null);
}

test "highlight: struct type references" {
    const source: [:0]const u8 = "struct S { x: f32 } fn a(s: S) {} fn b(s: S) {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Position on struct name 'S'
    const pos = Handler.offsetToLspPosition(source, 7) orelse return error.TestUnexpectedResult;
    const highlights = try ctx.handler.computeDocumentHighlight("test://file.wgsl", pos);
    try std.testing.expect(highlights != null);
    defer std.testing.allocator.free(highlights.?);
    // Declaration (write) + 2 type refs (read) = 3
    try std.testing.expectEqual(@as(usize, 3), highlights.?.len);
    try std.testing.expectEqual(Handler.HighlightKind.write, highlights.?[0].kind);
}

test "highlight: function parameter" {
    const source: [:0]const u8 = "fn f(x: f32) -> f32 { return x; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = posAt(source, "x:") orelse return error.TestUnexpectedResult;
    const highlights = try ctx.handler.computeDocumentHighlight("test://file.wgsl", pos);
    try std.testing.expect(highlights != null);
    defer std.testing.allocator.free(highlights.?);
    // Declaration (write) + 1 read = 2
    try std.testing.expectEqual(@as(usize, 2), highlights.?.len);
    try std.testing.expectEqual(Handler.HighlightKind.write, highlights.?[0].kind);
    try std.testing.expectEqual(Handler.HighlightKind.read, highlights.?[1].kind);
}
