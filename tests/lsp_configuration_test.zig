//! Tests for `Handler.applyClientConfig` + the settings plumbing used by
//! `workspace/configuration` and `workspace/didChangeConfiguration`.
//!
//! The wire schema is identical to `wgslender.json`: the LSP-only feature
//! toggles live under the `lsp.*` namespace. Parsing is permissive —
//! wrong types are silently ignored, unset fields stay at their prior
//! value (workspace_config is replaced wholesale on every push, so the
//! "prior value" comes from the project layer, not the previous push).

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
    try std.testing.expect(handler.inlayHintsEnabled());
    try std.testing.expect(handler.diagnosticsEnabled());
}

test "applyClientConfig: disables inlay hints only" {
    const handler = try setup();
    defer teardown(handler);

    var parsed = try parseJson("{\"lsp\":{\"inlayHints\":{\"enabled\":false}}}");
    defer parsed.deinit();
    handler.applyClientConfig(parsed.value);

    try std.testing.expect(!handler.inlayHintsEnabled());
    try std.testing.expect(handler.diagnosticsEnabled());
}

test "applyClientConfig: disables diagnostics only" {
    const handler = try setup();
    defer teardown(handler);

    var parsed = try parseJson("{\"lsp\":{\"diagnostics\":{\"enabled\":false}}}");
    defer parsed.deinit();
    handler.applyClientConfig(parsed.value);

    try std.testing.expect(handler.inlayHintsEnabled());
    try std.testing.expect(!handler.diagnosticsEnabled());
}

test "applyClientConfig: each push replaces the workspace overlay" {
    const handler = try setup();
    defer teardown(handler);

    var first = try parseJson("{\"lsp\":{\"inlayHints\":{\"enabled\":false}}}");
    defer first.deinit();
    handler.applyClientConfig(first.value);

    var second = try parseJson("{\"lsp\":{\"diagnostics\":{\"enabled\":false}}}");
    defer second.deinit();
    handler.applyClientConfig(second.value);

    // The second push replaced the workspace layer wholesale — `inlayHints`
    // is no longer set there, so it falls back to the (default) `true`.
    try std.testing.expect(handler.inlayHintsEnabled());
    try std.testing.expect(!handler.diagnosticsEnabled());
}

test "applyClientConfig: ill-typed fields leave settings unchanged" {
    const handler = try setup();
    defer teardown(handler);

    // enabled is a string / int — should be ignored.
    var parsed = try parseJson("{\"lsp\":{\"inlayHints\":{\"enabled\":\"no\"},\"diagnostics\":{\"enabled\":42}}}");
    defer parsed.deinit();
    handler.applyClientConfig(parsed.value);

    try std.testing.expect(handler.inlayHintsEnabled());
    try std.testing.expect(handler.diagnosticsEnabled());
}

test "applyClientConfig: non-object root ignored" {
    const handler = try setup();
    defer teardown(handler);

    // JSON array — not an object.
    var parsed = try parseJson("[{\"lsp\":{\"inlayHints\":{\"enabled\":false}}}]");
    defer parsed.deinit();
    handler.applyClientConfig(parsed.value);

    try std.testing.expect(handler.inlayHintsEnabled());
    try std.testing.expect(handler.diagnosticsEnabled());
}

test "applyClientConfig: nested non-object containers ignored" {
    const handler = try setup();
    defer teardown(handler);

    // lsp.inlayHints is a string rather than an object.
    var parsed = try parseJson("{\"lsp\":{\"inlayHints\":\"off\",\"diagnostics\":null}}");
    defer parsed.deinit();
    handler.applyClientConfig(parsed.value);

    try std.testing.expect(handler.inlayHintsEnabled());
    try std.testing.expect(handler.diagnosticsEnabled());
}

test "settings wiring: disabled inlay hints short-circuits computeInlayHints" {
    const source: [:0]const u8 = "fn f() { let x = 1.0; }";
    const handler = try setup();
    defer teardown(handler);
    try handler.openDocument("test://file.wgsl", source, 1);

    // The type-annotation lane is opt-in; this test is about the master
    // switch, so give it a lane that produces hints.
    handler.workspace_config.lsp_inlay_type_annotations = true;

    // Baseline: hints are produced for an inferred let binding.
    const with_hints = try handler.computeInlayHints("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 0, .character = @intCast(source.len) },
    });
    defer std.testing.allocator.free(with_hints);
    try std.testing.expect(with_hints.len > 0);

    // Now disable and re-query — must return an empty slice.
    handler.workspace_config.lsp_inlay_hints_enabled = false;
    const without_hints = try handler.computeInlayHints("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 0, .character = @intCast(source.len) },
    });
    defer std.testing.allocator.free(without_hints);
    try std.testing.expectEqual(@as(usize, 0), without_hints.len);
}
