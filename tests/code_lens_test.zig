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

fn freeLenses(lenses: []const Handler.CodeLensInfo) void {
    for (lenses) |l| std.testing.allocator.free(l.title);
    std.testing.allocator.free(lenses);
}

test "code lens: function with references" {
    const source: [:0]const u8 = "fn helper() {} fn a() { helper(); } fn b() { helper(); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const lenses = try ctx.handler.computeCodeLens("test://file.wgsl");
    defer freeLenses(lenses);
    // Should have lenses for helper, a, b
    try std.testing.expect(lenses.len >= 1);
    // Find the helper lens — it should have 2 references
    for (lenses) |l| {
        if (l.range.start.character == 3) { // "helper" starts at col 3
            try std.testing.expect(std.mem.indexOf(u8, l.title, "2") != null);
        }
    }
}

test "code lens: unused function shows 0" {
    const source: [:0]const u8 = "fn unused_fn() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const lenses = try ctx.handler.computeCodeLens("test://file.wgsl");
    defer freeLenses(lenses);
    try std.testing.expectEqual(@as(usize, 1), lenses.len);
    try std.testing.expect(std.mem.indexOf(u8, lenses[0].title, "0") != null);
}

test "code lens: struct with type refs" {
    const source: [:0]const u8 = "struct S { x: f32 } fn a(s: S) {} fn b(s: S) {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const lenses = try ctx.handler.computeCodeLens("test://file.wgsl");
    defer freeLenses(lenses);
    // Should have lens for struct S with 2 references
    try std.testing.expect(lenses.len >= 1);
}

test "code lens: empty file" {
    const source: [:0]const u8 = "";
    const ctx = try setup(source);
    defer teardown(ctx);
    const lenses = try ctx.handler.computeCodeLens("test://file.wgsl");
    defer freeLenses(lenses);
    try std.testing.expectEqual(@as(usize, 0), lenses.len);
}
