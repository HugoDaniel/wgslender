const std = @import("std");
const Handler = @import("Handler");
const fixtures = @import("formatting_fixtures.zig");

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
    const source: [:0]const u8 = fixtures.produces_output;
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
    const source: [:0]const u8 = fixtures.parse_error;
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
    const source: [:0]const u8 = fixtures.multi_line;
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
    const source: [:0]const u8 = fixtures.empty;
    const ctx = try setup(source);
    defer teardown(ctx);
    const edit = try ctx.handler.computeFormatting("test://file.wgsl");
    // Empty source should either return null or an empty edit
    if (edit) |e| {
        defer std.testing.allocator.free(e.new_text);
    }
}

test "formatting: valid shader formats cleanly" {
    const source: [:0]const u8 = fixtures.valid_shader;
    const ctx = try setup(source);
    defer teardown(ctx);
    const edit = try ctx.handler.computeFormatting("test://file.wgsl");
    try std.testing.expect(edit != null);
    defer std.testing.allocator.free(edit.?.new_text);
    // Formatted output should contain the essential parts
    try std.testing.expect(std.mem.indexOf(u8, edit.?.new_text, "fn") != null);
    try std.testing.expect(std.mem.indexOf(u8, edit.?.new_text, "main") != null);
}

test "formatting: preserves declarations unreachable from entry points" {
    // Formatting must be content-preserving. The formatter runs the minifier
    // pipeline with whitespace/identifier minification off, but tree shaking
    // must be off too — otherwise Format Document silently deletes any
    // helper not yet called from an entry point.
    const source: [:0]const u8 = fixtures.preserves_unreachable;
    const ctx = try setup(source);
    defer teardown(ctx);
    const edit = try ctx.handler.computeFormatting("test://file.wgsl");
    try std.testing.expect(edit != null);
    defer std.testing.allocator.free(edit.?.new_text);
    try std.testing.expect(std.mem.indexOf(u8, edit.?.new_text, "helper_unused") != null);
}

test "formatting: preserves literal spelling (no syntax minification)" {
    const source: [:0]const u8 = fixtures.valid_shader;
    const ctx = try setup(source);
    defer teardown(ctx);
    const edit = try ctx.handler.computeFormatting("test://file.wgsl");
    try std.testing.expect(edit != null);
    defer std.testing.allocator.free(edit.?.new_text);
    try std.testing.expect(std.mem.indexOf(u8, edit.?.new_text, "1.0") != null);
}

test "formatting: preserves struct content" {
    const source: [:0]const u8 = fixtures.preserves_struct;
    const ctx = try setup(source);
    defer teardown(ctx);
    const edit = try ctx.handler.computeFormatting("test://file.wgsl");
    try std.testing.expect(edit != null);
    defer std.testing.allocator.free(edit.?.new_text);
    try std.testing.expect(std.mem.indexOf(u8, edit.?.new_text, "position") != null);
    try std.testing.expect(std.mem.indexOf(u8, edit.?.new_text, "normal") != null);
}
