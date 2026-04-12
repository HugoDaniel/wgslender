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

fn freeSelectionChain(gpa: std.mem.Allocator, sel: ?*const Handler.SelectionRangeInfo) void {
    var current = sel;
    while (current) |node| {
        const parent = node.parent;
        gpa.destroy(@constCast(node));
        current = parent;
    }
}

test "selection range: cursor on function name" {
    const source: [:0]const u8 = "fn my_func() {\n  let x = 1;\n}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 3) orelse return error.TestUnexpectedResult; // 'm' in my_func
    const sel = try ctx.handler.computeSelectionRange("test://file.wgsl", pos);
    try std.testing.expect(sel != null);
    defer freeSelectionChain(std.testing.allocator, sel);
    // Innermost range should be the function name
    try std.testing.expectEqual(@as(u32, 3), sel.?.range.start.character);
    // Should have a parent (function range or file range)
    try std.testing.expect(sel.?.parent != null);
}

test "selection range: parent chain increases" {
    const source: [:0]const u8 = "fn f() {\n  let x = 1;\n}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 3) orelse return error.TestUnexpectedResult;
    const sel = try ctx.handler.computeSelectionRange("test://file.wgsl", pos);
    try std.testing.expect(sel != null);
    defer freeSelectionChain(std.testing.allocator, sel);
    // Walk the chain and verify ranges don't shrink
    var current: ?*const Handler.SelectionRangeInfo = sel;
    var prev_end_line: u32 = 0;
    while (current) |node| {
        try std.testing.expect(node.range.end.line >= prev_end_line);
        prev_end_line = node.range.end.line;
        current = node.parent;
    }
}

test "selection range: top parent covers file" {
    const source: [:0]const u8 = "fn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const sel = try ctx.handler.computeSelectionRange("test://file.wgsl", .{ .line = 0, .character = 5 });
    try std.testing.expect(sel != null);
    defer freeSelectionChain(std.testing.allocator, sel);
    // Find the topmost node
    var top: *const Handler.SelectionRangeInfo = sel.?;
    while (top.parent) |p| top = p;
    // Should start at 0,0
    try std.testing.expectEqual(@as(u32, 0), top.range.start.line);
    try std.testing.expectEqual(@as(u32, 0), top.range.start.character);
}

test "selection range: unknown document" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    const result = try handler.computeSelectionRange("test://nonexistent.wgsl", .{ .line = 0, .character = 0 });
    try std.testing.expect(result == null);
}
