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

test "incremental sync: insert text" {
    const ctx = try setup("fn f() {}");
    defer teardown(ctx);
    // Insert " -> f32" after "()"
    try ctx.handler.changeDocumentIncremental("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 6 },
        .end = .{ .line = 0, .character = 6 },
    }, " -> f32");
    const source = ctx.handler.getDocumentSource("test://file.wgsl") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("fn f() -> f32 {}", source);
}

test "incremental sync: delete range" {
    const ctx = try setup("fn f() { let x = 1; }");
    defer teardown(ctx);
    // Delete "let x = 1; " (chars 9 to 20)
    try ctx.handler.changeDocumentIncremental("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 9 },
        .end = .{ .line = 0, .character = 20 },
    }, "");
    const source = ctx.handler.getDocumentSource("test://file.wgsl") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("fn f() { }", source);
}

test "incremental sync: replace range" {
    const ctx = try setup("fn f() { let x = 1; }");
    defer teardown(ctx);
    // Replace "x" with "my_var"
    try ctx.handler.changeDocumentIncremental("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 13 },
        .end = .{ .line = 0, .character = 14 },
    }, "my_var");
    const source = ctx.handler.getDocumentSource("test://file.wgsl") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("fn f() { let my_var = 1; }", source);
}

test "incremental sync: multi-line edit" {
    const ctx = try setup("fn f() {\n  let x = 1;\n}");
    defer teardown(ctx);
    // Insert a new line after "let x = 1;" (line 1, char 12 = end of "  let x = 1;")
    try ctx.handler.changeDocumentIncremental("test://file.wgsl", .{
        .start = .{ .line = 1, .character = 12 },
        .end = .{ .line = 1, .character = 12 },
    }, "\n  let y = 2;");
    const source = ctx.handler.getDocumentSource("test://file.wgsl") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("fn f() {\n  let x = 1;\n  let y = 2;\n}", source);
}

test "incremental sync: invalidates analysis cache" {
    const ctx = try setup("fn f() {}");
    defer teardown(ctx);
    _ = try ctx.handler.analyzeDocument("test://file.wgsl");
    const doc = ctx.handler.documents.getPtr("test://file.wgsl").?;
    try std.testing.expect(doc.analysis != null);
    try ctx.handler.changeDocumentIncremental("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 0, .character = 0 },
    }, "// comment\n");
    const doc2 = ctx.handler.documents.getPtr("test://file.wgsl").?;
    try std.testing.expect(doc2.analysis == null);
}

test "incremental sync: edit at start of file" {
    const ctx = try setup("fn f() {}");
    defer teardown(ctx);
    try ctx.handler.changeDocumentIncremental("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 0, .character = 0 },
    }, "// header\n");
    const source = ctx.handler.getDocumentSource("test://file.wgsl") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("// header\nfn f() {}", source);
}
