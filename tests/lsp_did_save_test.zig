//! LSP `textDocument/didSave` wiring tests.
//!
//! `didSave` is expected to be a lightweight hook — the client remains
//! authoritative over text, so the handler itself must not mutate source
//! or invalidate caches. Transport layers re-publish diagnostics on top
//! of the call; those assertions live with the transport code.

const std = @import("std");
const Handler = @import("Handler");

fn setup(source: [:0]const u8) !*Handler {
    const handler = try std.testing.allocator.create(Handler);
    handler.* = Handler.init(std.testing.allocator);
    try handler.openDocument("test://file.wgsl", source, 1);
    return handler;
}

fn teardown(handler: *Handler) void {
    handler.deinit();
    std.testing.allocator.destroy(handler);
}

test "didSave: source unchanged after save" {
    const source: [:0]const u8 = "fn f() { let x = 1.0; }";
    const handler = try setup(source);
    defer teardown(handler);

    const before = handler.getDocumentSource("test://file.wgsl").?;
    const before_copy = try std.testing.allocator.dupe(u8, before);
    defer std.testing.allocator.free(before_copy);

    handler.handleDidSave("test://file.wgsl");

    const after = handler.getDocumentSource("test://file.wgsl").?;
    try std.testing.expectEqualStrings(before_copy, after);
}

test "didSave: unknown URI is a no-op" {
    const handler = try std.testing.allocator.create(Handler);
    handler.* = Handler.init(std.testing.allocator);
    defer {
        handler.deinit();
        std.testing.allocator.destroy(handler);
    }

    // Must not crash / error.
    handler.handleDidSave("test://never-opened.wgsl");
    try std.testing.expect(handler.getDocumentSource("test://never-opened.wgsl") == null);
}

test "didSave: analysis cache preserved" {
    const source: [:0]const u8 = "fn f() { let x: f32 = 1.0; }";
    const handler = try setup(source);
    defer teardown(handler);

    const first = try handler.analyzeDocument("test://file.wgsl");
    handler.handleDidSave("test://file.wgsl");
    const second = try handler.analyzeDocument("test://file.wgsl");

    // Cache identity — didSave must not invalidate.
    try std.testing.expectEqual(@intFromPtr(first), @intFromPtr(second));
}
