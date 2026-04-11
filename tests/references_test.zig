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

test "references: variable with multiple usages" {
    const source: [:0]const u8 = "const x: f32 = 1.0; fn f() -> f32 { let a = x; let b = x; return x; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Position on declaration of 'x'
    const pos = Handler.offsetToLspPosition(source, 6) orelse return error.TestUnexpectedResult; // 'x' in "const x"
    const refs = try ctx.handler.computeReferences("test://file.wgsl", pos, true);
    try std.testing.expect(refs != null);
    defer std.testing.allocator.free(refs.?);
    // Declaration + 3 usages = 4
    try std.testing.expectEqual(@as(usize, 4), refs.?.len);
}

test "references: exclude declaration" {
    const source: [:0]const u8 = "const x: f32 = 1.0; fn f() -> f32 { return x; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 6) orelse return error.TestUnexpectedResult;
    const refs_with = try ctx.handler.computeReferences("test://file.wgsl", pos, true);
    try std.testing.expect(refs_with != null);
    defer std.testing.allocator.free(refs_with.?);
    const refs_without = try ctx.handler.computeReferences("test://file.wgsl", pos, false);
    try std.testing.expect(refs_without != null);
    defer std.testing.allocator.free(refs_without.?);
    try std.testing.expect(refs_with.?.len == refs_without.?.len + 1);
}

test "references: struct type used in annotations" {
    const source: [:0]const u8 = "struct S { x: f32 } fn a(s: S) {} fn b(s: S) {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Position on struct name
    const pos = Handler.offsetToLspPosition(source, 7) orelse return error.TestUnexpectedResult; // 'S' in "struct S"
    const refs = try ctx.handler.computeReferences("test://file.wgsl", pos, true);
    try std.testing.expect(refs != null);
    defer std.testing.allocator.free(refs.?);
    // Declaration + 2 type refs = 3
    try std.testing.expectEqual(@as(usize, 3), refs.?.len);
}

test "references: unused symbol returns only declaration" {
    const source: [:0]const u8 = "fn unused_fn() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 3) orelse return error.TestUnexpectedResult;
    const refs = try ctx.handler.computeReferences("test://file.wgsl", pos, true);
    try std.testing.expect(refs != null);
    defer std.testing.allocator.free(refs.?);
    try std.testing.expectEqual(@as(usize, 1), refs.?.len);
}

test "references: whitespace returns null" {
    const source: [:0]const u8 = "fn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const result = try ctx.handler.computeReferences("test://file.wgsl", .{ .line = 0, .character = 2 }, true);
    try std.testing.expect(result == null);
}
