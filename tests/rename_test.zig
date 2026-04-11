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

test "rename: variable updates all occurrences" {
    const source: [:0]const u8 = "const x: f32 = 1.0; fn f() -> f32 { return x; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 6) orelse return error.TestUnexpectedResult;
    const edits = try ctx.handler.computeRename("test://file.wgsl", pos, "y");
    try std.testing.expect(edits != null);
    defer std.testing.allocator.free(edits.?);
    // Should have 2 edits: declaration + usage
    try std.testing.expectEqual(@as(usize, 2), edits.?.len);
    for (edits.?) |edit| {
        try std.testing.expectEqualStrings("y", edit.new_text);
    }
}

test "rename: reject keyword as new name" {
    const source: [:0]const u8 = "fn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 3) orelse return error.TestUnexpectedResult;
    const edits = try ctx.handler.computeRename("test://file.wgsl", pos, "return");
    try std.testing.expect(edits == null);
}

test "rename: reject reserved word" {
    const source: [:0]const u8 = "fn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 3) orelse return error.TestUnexpectedResult;
    const edits = try ctx.handler.computeRename("test://file.wgsl", pos, "class");
    try std.testing.expect(edits == null);
}

test "rename: reject __ prefix" {
    const source: [:0]const u8 = "fn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 3) orelse return error.TestUnexpectedResult;
    const edits = try ctx.handler.computeRename("test://file.wgsl", pos, "__reserved");
    try std.testing.expect(edits == null);
}

test "rename: reject empty name" {
    const source: [:0]const u8 = "fn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 3) orelse return error.TestUnexpectedResult;
    const edits = try ctx.handler.computeRename("test://file.wgsl", pos, "");
    try std.testing.expect(edits == null);
}

test "rename: prepareRename returns identifier range" {
    const source: [:0]const u8 = "fn my_func() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 3) orelse return error.TestUnexpectedResult;
    const range = try ctx.handler.prepareRename("test://file.wgsl", pos);
    try std.testing.expect(range != null);
    try std.testing.expectEqual(@as(u32, 3), range.?.start.character);
    try std.testing.expectEqual(@as(u32, 10), range.?.end.character);
}

test "rename: prepareRename on whitespace returns null" {
    const source: [:0]const u8 = "fn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const result = try ctx.handler.prepareRename("test://file.wgsl", .{ .line = 0, .character = 2 });
    try std.testing.expect(result == null);
}

test "rename: struct updates type annotations" {
    const source: [:0]const u8 = "struct Pt { x: f32 } fn f(p: Pt) {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 7) orelse return error.TestUnexpectedResult; // 'P' in "Pt"
    const edits = try ctx.handler.computeRename("test://file.wgsl", pos, "Point");
    try std.testing.expect(edits != null);
    defer std.testing.allocator.free(edits.?);
    // Declaration + type ref = 2
    try std.testing.expectEqual(@as(usize, 2), edits.?.len);
}

test "isValidWgslIdentifier: valid names" {
    try std.testing.expect(Handler.isValidWgslIdentifier("x"));
    try std.testing.expect(Handler.isValidWgslIdentifier("my_var"));
    try std.testing.expect(Handler.isValidWgslIdentifier("_private"));
    try std.testing.expect(Handler.isValidWgslIdentifier("a123"));
}

test "isValidWgslIdentifier: invalid names" {
    try std.testing.expect(!Handler.isValidWgslIdentifier(""));
    try std.testing.expect(!Handler.isValidWgslIdentifier("__reserved"));
    try std.testing.expect(!Handler.isValidWgslIdentifier("return"));
    try std.testing.expect(!Handler.isValidWgslIdentifier("class"));
    try std.testing.expect(!Handler.isValidWgslIdentifier("123abc"));
    try std.testing.expect(!Handler.isValidWgslIdentifier("fn"));
}
