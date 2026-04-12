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

test "folding: function body" {
    const source: [:0]const u8 =
        \\fn main() {
        \\  let x = 1;
        \\  let y = 2;
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const ranges = try ctx.handler.computeFoldingRanges("test://file.wgsl");
    defer std.testing.allocator.free(ranges);
    try std.testing.expectEqual(@as(usize, 1), ranges.len);
    try std.testing.expectEqual(@as(u32, 0), ranges[0].start_line);
    try std.testing.expectEqual(@as(u32, 3), ranges[0].end_line);
}

test "folding: struct" {
    const source: [:0]const u8 =
        \\struct Point {
        \\  x: f32,
        \\  y: f32,
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const ranges = try ctx.handler.computeFoldingRanges("test://file.wgsl");
    defer std.testing.allocator.free(ranges);
    try std.testing.expectEqual(@as(usize, 1), ranges.len);
    try std.testing.expectEqual(@as(u32, 0), ranges[0].start_line);
}

test "folding: single-line function no fold" {
    const source: [:0]const u8 = "fn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const ranges = try ctx.handler.computeFoldingRanges("test://file.wgsl");
    defer std.testing.allocator.free(ranges);
    // Single line — no fold
    try std.testing.expectEqual(@as(usize, 0), ranges.len);
}

test "folding: multiple declarations" {
    const source: [:0]const u8 =
        \\struct S {
        \\  x: f32,
        \\}
        \\fn f() {
        \\  let a = 1;
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const ranges = try ctx.handler.computeFoldingRanges("test://file.wgsl");
    defer std.testing.allocator.free(ranges);
    try std.testing.expectEqual(@as(usize, 2), ranges.len);
}

test "folding: empty file" {
    const source: [:0]const u8 = "";
    const ctx = try setup(source);
    defer teardown(ctx);
    const ranges = try ctx.handler.computeFoldingRanges("test://file.wgsl");
    defer std.testing.allocator.free(ranges);
    try std.testing.expectEqual(@as(usize, 0), ranges.len);
}

// =========================================================================
// Edge cases
// =========================================================================

test "folding: entry point with attributes spans from name" {
    const source: [:0]const u8 =
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\  let x = 1;
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const ranges = try ctx.handler.computeFoldingRanges("test://file.wgsl");
    defer std.testing.allocator.free(ranges);
    try std.testing.expect(ranges.len >= 1);
}

test "folding: deeply nested struct" {
    const source: [:0]const u8 =
        \\struct Outer {
        \\  a: f32,
        \\  b: f32,
        \\  c: f32,
        \\  d: f32,
        \\  e: f32,
        \\  f: f32,
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const ranges = try ctx.handler.computeFoldingRanges("test://file.wgsl");
    defer std.testing.allocator.free(ranges);
    try std.testing.expectEqual(@as(usize, 1), ranges.len);
    // Should span multiple lines
    try std.testing.expect(ranges[0].end_line > ranges[0].start_line + 2);
}

test "folding: many functions" {
    const source: [:0]const u8 =
        \\fn a() {
        \\  let x = 1;
        \\}
        \\fn b() {
        \\  let y = 2;
        \\}
        \\fn c() {
        \\  let z = 3;
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const ranges = try ctx.handler.computeFoldingRanges("test://file.wgsl");
    defer std.testing.allocator.free(ranges);
    try std.testing.expectEqual(@as(usize, 3), ranges.len);
}

test "folding: unknown document" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    const ranges = try handler.computeFoldingRanges("test://nonexistent.wgsl");
    try std.testing.expectEqual(@as(usize, 0), ranges.len);
}
