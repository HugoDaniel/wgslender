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

test "call hierarchy: prepare on function" {
    const source: [:0]const u8 = "fn helper() {} fn main() { helper(); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 3) orelse return error.TestUnexpectedResult; // 'h' in helper
    const item = try ctx.handler.prepareCallHierarchy("test://file.wgsl", pos);
    try std.testing.expect(item != null);
    try std.testing.expectEqualStrings("helper", item.?.name);
}

test "call hierarchy: prepare on non-function returns null" {
    const source: [:0]const u8 = "const x: f32 = 1.0;";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 6) orelse return error.TestUnexpectedResult;
    const item = try ctx.handler.prepareCallHierarchy("test://file.wgsl", pos);
    try std.testing.expect(item == null);
}

test "call hierarchy: incoming calls" {
    const source: [:0]const u8 = "fn target() {} fn caller_a() { target(); } fn caller_b() { target(); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const calls = try ctx.handler.computeIncomingCalls("test://file.wgsl", "target");
    defer {
        for (calls) |c| std.testing.allocator.free(c.from_ranges);
        std.testing.allocator.free(calls);
    }
    try std.testing.expectEqual(@as(usize, 2), calls.len);
}

test "call hierarchy: outgoing calls" {
    const source: [:0]const u8 = "fn a() {} fn b() {} fn caller() { a(); b(); a(); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const calls = try ctx.handler.computeOutgoingCalls("test://file.wgsl", "caller");
    defer {
        for (calls) |c| std.testing.allocator.free(c.from_ranges);
        std.testing.allocator.free(calls);
    }
    // Should have calls to 'a' and 'b'
    try std.testing.expectEqual(@as(usize, 2), calls.len);
}

test "call hierarchy: function with no calls" {
    const source: [:0]const u8 = "fn isolated() { let x = 1; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const calls = try ctx.handler.computeOutgoingCalls("test://file.wgsl", "isolated");
    defer std.testing.allocator.free(calls);
    try std.testing.expectEqual(@as(usize, 0), calls.len);
}

// =========================================================================
// Edge cases
// =========================================================================

test "call hierarchy: chain of calls a->b->c" {
    const source: [:0]const u8 = "fn c() {} fn b() { c(); } fn a() { b(); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // a's outgoing calls should include b
    const out_a = try ctx.handler.computeOutgoingCalls("test://file.wgsl", "a");
    defer {
        for (out_a) |c| std.testing.allocator.free(c.from_ranges);
        std.testing.allocator.free(out_a);
    }
    try std.testing.expectEqual(@as(usize, 1), out_a.len);

    // b's incoming should include a
    const in_b = try ctx.handler.computeIncomingCalls("test://file.wgsl", "b");
    defer {
        for (in_b) |c| std.testing.allocator.free(c.from_ranges);
        std.testing.allocator.free(in_b);
    }
    try std.testing.expectEqual(@as(usize, 1), in_b.len);
}

test "call hierarchy: multiple calls to same function" {
    const source: [:0]const u8 = "fn helper() {} fn main() { helper(); helper(); helper(); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const out = try ctx.handler.computeOutgoingCalls("test://file.wgsl", "main");
    defer {
        for (out) |c| std.testing.allocator.free(c.from_ranges);
        std.testing.allocator.free(out);
    }
    // Should have 1 entry for helper, with 3 call locations
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqual(@as(usize, 3), out[0].from_ranges.len);
}

test "call hierarchy: prepare on whitespace returns null" {
    const source: [:0]const u8 = "fn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const item = try ctx.handler.prepareCallHierarchy("test://file.wgsl", .{ .line = 0, .character = 2 });
    try std.testing.expect(item == null);
}

test "call hierarchy: nonexistent function returns empty" {
    const source: [:0]const u8 = "fn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const calls = try ctx.handler.computeOutgoingCalls("test://file.wgsl", "nonexistent");
    defer std.testing.allocator.free(calls);
    try std.testing.expectEqual(@as(usize, 0), calls.len);
}

test "call hierarchy: incoming calls from nested expressions" {
    const source: [:0]const u8 = "fn target() -> f32 { return 1.0; } fn caller() { let x = target() + target(); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const calls = try ctx.handler.computeIncomingCalls("test://file.wgsl", "target");
    defer {
        for (calls) |c| std.testing.allocator.free(c.from_ranges);
        std.testing.allocator.free(calls);
    }
    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqual(@as(usize, 2), calls[0].from_ranges.len);
}
