//! Tests for `Handler.applyClientSettings` + the settings plumbing used by
//! `workspace/configuration` and `workspace/didChangeConfiguration`.
//!
//! Parsing uses the same permissive, merge-semantic approach as
//! `src/Config.zig`: wrong types are silently ignored, unset fields stay
//! at their prior value. This mirrors behaviour editors expect.

const std = @import("std");
const Handler = @import("Handler");

fn setup() !*Handler {
    const handler = try std.testing.allocator.create(Handler);
    handler.* = Handler.init(std.testing.allocator);
    return handler;
}

fn teardown(handler: *Handler) void {
    handler.deinit();
    std.testing.allocator.destroy(handler);
}

fn parseJson(json: []const u8) !std.json.Parsed(std.json.Value) {
    return try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        json,
        .{ .ignore_unknown_fields = true, .max_value_len = null },
    );
}

test "settings: defaults enable every feature" {
    const handler = try setup();
    defer teardown(handler);
    try std.testing.expect(handler.settings.inlay_hints_enabled);
    try std.testing.expect(handler.settings.diagnostics_enabled);
}

test "applyClientSettings: disables inlay hints only" {
    const handler = try setup();
    defer teardown(handler);

    var parsed = try parseJson("{\"inlayHints\":{\"enabled\":false}}");
    defer parsed.deinit();
    handler.applyClientSettings(parsed.value);

    try std.testing.expect(!handler.settings.inlay_hints_enabled);
    try std.testing.expect(handler.settings.diagnostics_enabled);
}

test "applyClientSettings: disables diagnostics only" {
    const handler = try setup();
    defer teardown(handler);

    var parsed = try parseJson("{\"diagnostics\":{\"enabled\":false}}");
    defer parsed.deinit();
    handler.applyClientSettings(parsed.value);

    try std.testing.expect(handler.settings.inlay_hints_enabled);
    try std.testing.expect(!handler.settings.diagnostics_enabled);
}

test "applyClientSettings: successive calls merge" {
    const handler = try setup();
    defer teardown(handler);

    var first = try parseJson("{\"inlayHints\":{\"enabled\":false}}");
    defer first.deinit();
    handler.applyClientSettings(first.value);

    var second = try parseJson("{\"diagnostics\":{\"enabled\":false}}");
    defer second.deinit();
    handler.applyClientSettings(second.value);

    try std.testing.expect(!handler.settings.inlay_hints_enabled);
    try std.testing.expect(!handler.settings.diagnostics_enabled);
}

test "applyClientSettings: ill-typed fields leave settings unchanged" {
    const handler = try setup();
    defer teardown(handler);

    // enabled is a string — should be ignored.
    var parsed = try parseJson("{\"inlayHints\":{\"enabled\":\"no\"},\"diagnostics\":{\"enabled\":42}}");
    defer parsed.deinit();
    handler.applyClientSettings(parsed.value);

    try std.testing.expect(handler.settings.inlay_hints_enabled);
    try std.testing.expect(handler.settings.diagnostics_enabled);
}

test "applyClientSettings: non-object root ignored" {
    const handler = try setup();
    defer teardown(handler);

    // JSON array — not an object.
    var parsed = try parseJson("[{\"inlayHints\":{\"enabled\":false}}]");
    defer parsed.deinit();
    handler.applyClientSettings(parsed.value);

    try std.testing.expect(handler.settings.inlay_hints_enabled);
    try std.testing.expect(handler.settings.diagnostics_enabled);
}

test "applyClientSettings: nested non-object containers ignored" {
    const handler = try setup();
    defer teardown(handler);

    // inlayHints is a string rather than an object.
    var parsed = try parseJson("{\"inlayHints\":\"off\",\"diagnostics\":null}");
    defer parsed.deinit();
    handler.applyClientSettings(parsed.value);

    try std.testing.expect(handler.settings.inlay_hints_enabled);
    try std.testing.expect(handler.settings.diagnostics_enabled);
}

test "settings wiring: disabled inlay hints short-circuits computeInlayHints" {
    const source: [:0]const u8 = "fn f() { let x = 1.0; }";
    const handler = try setup();
    defer teardown(handler);
    try handler.openDocument("test://file.wgsl", source, 1);

    // Baseline: hints are produced for an inferred let binding.
    const with_hints = try handler.computeInlayHints("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 0, .character = @intCast(source.len) },
    });
    defer std.testing.allocator.free(with_hints);
    try std.testing.expect(with_hints.len > 0);

    // Now disable and re-query — must return an empty slice.
    handler.settings.inlay_hints_enabled = false;
    const without_hints = try handler.computeInlayHints("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 0, .character = @intCast(source.len) },
    });
    defer std.testing.allocator.free(without_hints);
    try std.testing.expectEqual(@as(usize, 0), without_hints.len);
}
