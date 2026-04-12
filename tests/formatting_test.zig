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

test "formatting: produces output" {
    const source: [:0]const u8 = "fn   f()   {   }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const edit = try ctx.handler.computeFormatting("test://file.wgsl");
    try std.testing.expect(edit != null);
    defer std.testing.allocator.free(edit.?.new_text);
    // The formatted output should be non-empty
    try std.testing.expect(edit.?.new_text.len > 0);
    // Range should cover the whole document
    try std.testing.expectEqual(@as(u32, 0), edit.?.range.start.line);
    try std.testing.expectEqual(@as(u32, 0), edit.?.range.start.character);
}

test "formatting: parse error returns null" {
    const source: [:0]const u8 = "fn { invalid }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const edit = try ctx.handler.computeFormatting("test://file.wgsl");
    try std.testing.expect(edit == null);
}

test "formatting: unknown document returns null" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    const edit = try handler.computeFormatting("test://nonexistent.wgsl");
    try std.testing.expect(edit == null);
}

test "formatting: multi-line source" {
    const source: [:0]const u8 =
        \\struct  S  {  x:  f32  }
        \\fn   f(s:S)->f32{return   s.x;}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const edit = try ctx.handler.computeFormatting("test://file.wgsl");
    try std.testing.expect(edit != null);
    defer std.testing.allocator.free(edit.?.new_text);
    try std.testing.expect(edit.?.new_text.len > 0);
    // Range should start at 0,0
    try std.testing.expectEqual(@as(u32, 0), edit.?.range.start.line);
    try std.testing.expectEqual(@as(u32, 0), edit.?.range.start.character);
}

test "formatting: empty source" {
    const source: [:0]const u8 = "";
    const ctx = try setup(source);
    defer teardown(ctx);
    const edit = try ctx.handler.computeFormatting("test://file.wgsl");
    // Empty source should either return null or an empty edit
    if (edit) |e| {
        defer std.testing.allocator.free(e.new_text);
    }
}

test "formatting: valid shader formats cleanly" {
    const source: [:0]const u8 = "@compute @workgroup_size(1) fn main() { let x: f32 = 1.0; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const edit = try ctx.handler.computeFormatting("test://file.wgsl");
    try std.testing.expect(edit != null);
    defer std.testing.allocator.free(edit.?.new_text);
    // Formatted output should contain the essential parts
    try std.testing.expect(std.mem.indexOf(u8, edit.?.new_text, "fn") != null);
    try std.testing.expect(std.mem.indexOf(u8, edit.?.new_text, "main") != null);
}

test "formatting: preserves struct content" {
    const source: [:0]const u8 = "struct Vertex { position: vec3f, normal: vec3f }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const edit = try ctx.handler.computeFormatting("test://file.wgsl");
    try std.testing.expect(edit != null);
    defer std.testing.allocator.free(edit.?.new_text);
    try std.testing.expect(std.mem.indexOf(u8, edit.?.new_text, "position") != null);
    try std.testing.expect(std.mem.indexOf(u8, edit.?.new_text, "normal") != null);
}
