//! LSP-layer tests for the minifier-mode settings plumbing:
//!   - `applyClientSettings` parses the minify.* fields into a Partial.
//!   - The Handler exposes an `effectiveMinify()` accessor that merges
//!     project + workspace + magic-comment layers via `MinifySettings.resolve`.
//!   - `workspace/executeCommand` dispatches `wgslender.setMinifyMode` and
//!     `wgslender.toggleMinifyMode`.

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

test "minify settings: default effective mode is off" {
    const h = try setup();
    defer teardown(h);
    const eff = h.effectiveMinify();
    try std.testing.expectEqual(MinifySettings.Mode.off, eff.mode);
    try std.testing.expect(!eff.insightsActive());
    try std.testing.expect(!eff.lintsActive());
}

test "applyClientSettings: minifyMode=insights enables insights" {
    const h = try setup();
    defer teardown(h);

    var parsed = try parseJson("{\"minifyMode\":\"insights\"}");
    defer parsed.deinit();
    h.applyClientSettings(parsed.value);

    const eff = h.effectiveMinify();
    try std.testing.expectEqual(MinifySettings.Mode.insights, eff.mode);
    try std.testing.expect(eff.insightsActive());
    try std.testing.expect(!eff.lintsActive());
}

test "applyClientSettings: minifyMode=strict enables insights + lints" {
    const h = try setup();
    defer teardown(h);

    var parsed = try parseJson("{\"minifyMode\":\"strict\"}");
    defer parsed.deinit();
    h.applyClientSettings(parsed.value);

    const eff = h.effectiveMinify();
    try std.testing.expectEqual(MinifySettings.Mode.strict, eff.mode);
    try std.testing.expect(eff.insightsActive());
    try std.testing.expect(eff.lintsActive());
}

test "applyClientSettings: minifyMode=off turns everything off" {
    const h = try setup();
    defer teardown(h);

    var on = try parseJson("{\"minifyMode\":\"strict\"}");
    defer on.deinit();
    h.applyClientSettings(on.value);

    var off = try parseJson("{\"minifyMode\":\"off\"}");
    defer off.deinit();
    h.applyClientSettings(off.value);

    const eff = h.effectiveMinify();
    try std.testing.expectEqual(MinifySettings.Mode.off, eff.mode);
    try std.testing.expect(!eff.insightsActive());
}

test "applyClientSettings: unknown minifyMode value silently ignored" {
    const h = try setup();
    defer teardown(h);

    var parsed = try parseJson("{\"minifyMode\":\"loud\"}");
    defer parsed.deinit();
    h.applyClientSettings(parsed.value);

    try std.testing.expectEqual(MinifySettings.Mode.off, h.effectiveMinify().mode);
}

test "applyClientSettings: minifyInsights.format parses" {
    const h = try setup();
    defer teardown(h);

    var parsed = try parseJson(
        \\{"minifyMode":"insights","minifyInsights":{"format":"both"}}
    );
    defer parsed.deinit();
    h.applyClientSettings(parsed.value);

    const eff = h.effectiveMinify();
    try std.testing.expectEqual(MinifySettings.InsightsFormat.both, eff.insights.format);
}

test "applyClientSettings: minifyInsights sub-switches parse" {
    const h = try setup();
    defer teardown(h);

    var parsed = try parseJson(
        \\{"minifyMode":"insights","minifyInsights":{"functionSize":false,"declSize":false,"totalSize":true}}
    );
    defer parsed.deinit();
    h.applyClientSettings(parsed.value);

    const eff = h.effectiveMinify();
    try std.testing.expect(!eff.insights.function_size);
    try std.testing.expect(!eff.insights.decl_size);
    try std.testing.expect(eff.insights.total_size);
}

test "applyClientSettings: minifyLints.enabled=false in strict keeps lints off" {
    const h = try setup();
    defer teardown(h);

    var parsed = try parseJson(
        \\{"minifyMode":"strict","minifyLints":{"enabled":false}}
    );
    defer parsed.deinit();
    h.applyClientSettings(parsed.value);

    const eff = h.effectiveMinify();
    try std.testing.expectEqual(MinifySettings.Mode.strict, eff.mode);
    try std.testing.expect(!eff.lints.enabled);
    try std.testing.expect(!eff.lintsActive());
}

test "applyClientSettings: preserves existing non-minify fields" {
    const h = try setup();
    defer teardown(h);

    var p = try parseJson(
        \\{"inlayHints":{"enabled":false},"minifyMode":"insights"}
    );
    defer p.deinit();
    h.applyClientSettings(p.value);

    try std.testing.expect(!h.settings.inlay_hints_enabled);
    try std.testing.expectEqual(MinifySettings.Mode.insights, h.effectiveMinify().mode);
}

// =========================================================================
// workspace/executeCommand dispatch
// =========================================================================

test "executeCommand: wgslender.setMinifyMode \"insights\" sets mode" {
    const h = try setup();
    defer teardown(h);

    var args = try parseJson("[\"insights\"]");
    defer args.deinit();

    try h.executeCommand("wgslender.setMinifyMode", args.value.array.items);
    try std.testing.expectEqual(MinifySettings.Mode.insights, h.effectiveMinify().mode);
}

test "executeCommand: wgslender.setMinifyMode \"strict\" sets mode" {
    const h = try setup();
    defer teardown(h);

    var args = try parseJson("[\"strict\"]");
    defer args.deinit();

    try h.executeCommand("wgslender.setMinifyMode", args.value.array.items);
    try std.testing.expectEqual(MinifySettings.Mode.strict, h.effectiveMinify().mode);
}

test "executeCommand: wgslender.setMinifyMode with invalid value errors" {
    const h = try setup();
    defer teardown(h);

    var args = try parseJson("[\"loud\"]");
    defer args.deinit();

    try std.testing.expectError(
        error.InvalidParams,
        h.executeCommand("wgslender.setMinifyMode", args.value.array.items),
    );
}

test "executeCommand: wgslender.setMinifyMode with wrong arg shape errors" {
    const h = try setup();
    defer teardown(h);

    var args = try parseJson("[42]");
    defer args.deinit();

    try std.testing.expectError(
        error.InvalidParams,
        h.executeCommand("wgslender.setMinifyMode", args.value.array.items),
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

test "executeCommand: wgslender.toggleMinifyMode cycles off → insights → strict → off" {
    const h = try setup();
    defer teardown(h);

    var args = try parseJson("[]");
    defer args.deinit();

    try std.testing.expectEqual(MinifySettings.Mode.off, h.effectiveMinify().mode);

    try h.executeCommand("wgslender.toggleMinifyMode", args.value.array.items);
    try std.testing.expectEqual(MinifySettings.Mode.insights, h.effectiveMinify().mode);

    try h.executeCommand("wgslender.toggleMinifyMode", args.value.array.items);
    try std.testing.expectEqual(MinifySettings.Mode.strict, h.effectiveMinify().mode);

    try h.executeCommand("wgslender.toggleMinifyMode", args.value.array.items);
    try std.testing.expectEqual(MinifySettings.Mode.off, h.effectiveMinify().mode);
}
