//! Handler-level tests for the minifier-mode settings plumbing:
//!   - `effectiveMinify()` / `effectiveMinifyFor(uri)` resolve the
//!     project + workspace + magic-comment layers correctly.
//!   - `workspace/executeCommand` dispatches `wgslender.server.setMinifyMode`
//!     and `wgslender.server.toggleMinifyMode` against `workspace_config`.
//!
//! Per-key parser coverage lives in `src/Config.zig` tests now that the
//! LSP wire schema and `wgslender.json` share one parser
//! (`Config.applyJsonValue`). This file only exercises behaviour unique
//! to the Handler — the cross-layer resolve, the magic-comment
//! interaction, and the command dispatch.

const std = @import("std");
const Handler = @import("Handler");
const wgslender = @import("wgslender");
const MinifySettings = wgslender.MinifySettings;

fn setup() !*Handler {
    const h = try std.testing.allocator.create(Handler);
    h.* = Handler.init(std.testing.allocator);
    return h;
}

fn teardown(h: *Handler) void {
    h.deinit();
    std.testing.allocator.destroy(h);
}

fn parseJson(json: []const u8) !std.json.Parsed(std.json.Value) {
    return try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        json,
        .{ .ignore_unknown_fields = true, .max_value_len = null },
    );
}

fn applySettings(h: *Handler, json: []const u8) !void {
    var parsed = try parseJson(json);
    defer parsed.deinit();
    h.applyClientConfig(parsed.value);
}

// =========================================================================
// effectiveMinify — workspace layer only
// =========================================================================

test "minify settings: default effective mode is off" {
    const h = try setup();
    defer teardown(h);
    const eff = h.effectiveMinify();
    try std.testing.expectEqual(MinifySettings.Mode.off, eff.mode);
    try std.testing.expect(!eff.insightsActive());
    try std.testing.expect(!eff.lintsActive());
}

test "applyClientConfig: lsp.minifyMode=strict enables insights + lints" {
    const h = try setup();
    defer teardown(h);

    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"strict\"}}");

    const eff = h.effectiveMinify();
    try std.testing.expectEqual(MinifySettings.Mode.strict, eff.mode);
    try std.testing.expect(eff.insightsActive());
    try std.testing.expect(eff.lintsActive());
}

test "applyClientConfig: each push replaces the workspace overlay" {
    const h = try setup();
    defer teardown(h);

    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"strict\"}}");
    try std.testing.expectEqual(MinifySettings.Mode.strict, h.effectiveMinify().mode);

    // Second push doesn't carry minifyMode → workspace layer drops back
    // to empty for that field, falling through to the (default) `off`.
    try applySettings(h, "{\"lsp\":{\"inlayHints\":{\"enabled\":false}}}");
    try std.testing.expectEqual(MinifySettings.Mode.off, h.effectiveMinify().mode);
}

// =========================================================================
// executeCommand — wgslender.server.setMinifyMode + toggleMinifyMode
// =========================================================================

test "executeCommand: no advertised id trespasses in the editor's namespace" {
    // A client may turn every id in `executeCommandProvider.commands` into a
    // command of its own — vscode-languageclient registers a real VS Code
    // command for each. When these were plain `wgslender.*`, that collided
    // with the ids the editor extension registers itself and aborted its
    // `activate` on the second registration, leaving every command declared
    // after that line missing. `wgslender.*` is the editor's; ours is
    // `wgslender.server.*`.
    for (Handler.command_ids.native) |command| {
        try std.testing.expect(std.mem.startsWith(u8, command, "wgslender.server."));
    }
}

test "executeCommand: both transports advertise the same shared ids" {
    // The two lists drifted before they shared a source — native named five
    // commands and the WASM capabilities string three, one of which
    // (showMinifiedOutput) the WASM transport has always answered.
    for (Handler.command_ids.shared) |command| {
        try std.testing.expect(std.mem.indexOf(u8, Handler.capabilities_json, command) != null);

        var in_native = false;
        for (Handler.command_ids.native) |native_command| {
            if (std.mem.eql(u8, native_command, command)) in_native = true;
        }
        try std.testing.expect(in_native);
    }
}

test "executeCommand: an un-namespaced id is no longer dispatched" {
    const h = try setup();
    defer teardown(h);
    var args = try parseJson("[\"insights\"]");
    defer args.deinit();
    try std.testing.expectError(
        error.UnknownCommand,
        h.executeCommand("wgslender.setMinifyMode", args.value.array.items),
    );
}

test "executeCommand: wgslender.server.setMinifyMode \"insights\" sets mode" {
    const h = try setup();
    defer teardown(h);

    var args = try parseJson("[\"insights\"]");
    defer args.deinit();

    try h.executeCommand("wgslender.server.setMinifyMode", args.value.array.items);
    try std.testing.expectEqual(MinifySettings.Mode.insights, h.effectiveMinify().mode);
}

test "executeCommand: wgslender.server.setMinifyMode \"strict\" sets mode" {
    const h = try setup();
    defer teardown(h);

    var args = try parseJson("[\"strict\"]");
    defer args.deinit();

    try h.executeCommand("wgslender.server.setMinifyMode", args.value.array.items);
    try std.testing.expectEqual(MinifySettings.Mode.strict, h.effectiveMinify().mode);
}

test "executeCommand: wgslender.server.setMinifyMode with invalid value errors" {
    const h = try setup();
    defer teardown(h);

    var args = try parseJson("[\"loud\"]");
    defer args.deinit();

    try std.testing.expectError(
        error.InvalidParams,
        h.executeCommand("wgslender.server.setMinifyMode", args.value.array.items),
    );
}

test "executeCommand: wgslender.server.setMinifyMode with wrong arg shape errors" {
    const h = try setup();
    defer teardown(h);

    var args = try parseJson("[42]");
    defer args.deinit();

    try std.testing.expectError(
        error.InvalidParams,
        h.executeCommand("wgslender.server.setMinifyMode", args.value.array.items),
    );
}

test "executeCommand: unknown command errors" {
    const h = try setup();
    defer teardown(h);

    var args = try parseJson("[]");
    defer args.deinit();

    try std.testing.expectError(
        error.UnknownCommand,
        h.executeCommand("wgslender.nonexistent", args.value.array.items),
    );
}

test "executeCommand: wgslender.server.toggleMinifyMode cycles off → insights → strict → off" {
    const h = try setup();
    defer teardown(h);

    var args = try parseJson("[]");
    defer args.deinit();

    try std.testing.expectEqual(MinifySettings.Mode.off, h.effectiveMinify().mode);

    try h.executeCommand("wgslender.server.toggleMinifyMode", args.value.array.items);
    try std.testing.expectEqual(MinifySettings.Mode.insights, h.effectiveMinify().mode);

    try h.executeCommand("wgslender.server.toggleMinifyMode", args.value.array.items);
    try std.testing.expectEqual(MinifySettings.Mode.strict, h.effectiveMinify().mode);

    try h.executeCommand("wgslender.server.toggleMinifyMode", args.value.array.items);
    try std.testing.expectEqual(MinifySettings.Mode.off, h.effectiveMinify().mode);
}

// =========================================================================
// effectiveMinifyFor — magic-comment layer composes with project+workspace
// =========================================================================

test "effectiveMinifyFor: magic comment overrides workspace minify.mode" {
    const h = try setup();
    defer teardown(h);

    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"insights\"}}");

    try h.openDocument("file:///a.wgsl", "// wgslender-minify-strict\nfn main() {}\n", 1);

    const eff = h.effectiveMinifyFor("file:///a.wgsl");
    try std.testing.expectEqual(MinifySettings.Mode.strict, eff.mode);
    try std.testing.expect(eff.lintsActive());
}

test "effectiveMinifyFor: didChange updates magic layer" {
    const h = try setup();
    defer teardown(h);

    try h.openDocument("file:///a.wgsl", "// wgslender-minify-insights\nfn main() {}\n", 1);
    try std.testing.expectEqual(
        MinifySettings.Mode.insights,
        h.effectiveMinifyFor("file:///a.wgsl").mode,
    );

    try h.changeDocument("file:///a.wgsl", "// wgslender-minify-strict\nfn main() {}\n");
    try std.testing.expectEqual(
        MinifySettings.Mode.strict,
        h.effectiveMinifyFor("file:///a.wgsl").mode,
    );
}

test "effectiveMinifyFor: removing magic comment falls back to workspace" {
    const h = try setup();
    defer teardown(h);

    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"insights\"}}");

    try h.openDocument("file:///a.wgsl", "// wgslender-minify-strict\nfn main() {}\n", 1);
    try std.testing.expectEqual(
        MinifySettings.Mode.strict,
        h.effectiveMinifyFor("file:///a.wgsl").mode,
    );

    try h.changeDocument("file:///a.wgsl", "fn main() {}\n");
    try std.testing.expectEqual(
        MinifySettings.Mode.insights,
        h.effectiveMinifyFor("file:///a.wgsl").mode,
    );
}

test "effectiveMinifyFor: unknown URI falls back to workspace + project" {
    const h = try setup();
    defer teardown(h);

    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"insights\"}}");

    const eff = h.effectiveMinifyFor("file:///nonexistent.wgsl");
    try std.testing.expectEqual(MinifySettings.Mode.insights, eff.mode);
}

test "effectiveMinifyFor: default (no settings, no magic) is off" {
    const h = try setup();
    defer teardown(h);

    try h.openDocument("file:///a.wgsl", "fn main() {}\n", 1);
    const eff = h.effectiveMinifyFor("file:///a.wgsl");
    try std.testing.expectEqual(MinifySettings.Mode.off, eff.mode);
    try std.testing.expect(!eff.insightsActive());
}

test "effectiveMinifyFor: changeDocumentIncremental re-scans magic layer" {
    const h = try setup();
    defer teardown(h);

    // Source layout (column offsets 0-based):
    //   "// wgslender-minify-insights\n"
    //    0  3              20      28
    // `insights` occupies [20, 28); replace it with `strict` to flip mode.
    try h.openDocument("file:///a.wgsl", "// wgslender-minify-insights\nfn main() {}\n", 1);
    try std.testing.expectEqual(
        MinifySettings.Mode.insights,
        h.effectiveMinifyFor("file:///a.wgsl").mode,
    );

    try h.changeDocumentIncremental("file:///a.wgsl", .{
        .start = .{ .line = 0, .character = 20 },
        .end = .{ .line = 0, .character = 28 },
    }, "strict");
    try std.testing.expectEqual(
        MinifySettings.Mode.strict,
        h.effectiveMinifyFor("file:///a.wgsl").mode,
    );
}
