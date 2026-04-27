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

test "applyClientSettings: mangleExternalBindings=true sets workspace flag" {
    const h = try setup();
    defer teardown(h);

    var parsed = try parseJson("{\"mangleExternalBindings\":true}");
    defer parsed.deinit();
    h.applyClientSettings(parsed.value);

    const eff = h.effectiveMinify();
    try std.testing.expect(eff.mangle_external_bindings);
}

test "applyClientSettings: mangleExternalBindings absent leaves field false" {
    const h = try setup();
    defer teardown(h);

    var parsed = try parseJson("{\"minifyMode\":\"strict\"}");
    defer parsed.deinit();
    h.applyClientSettings(parsed.value);

    const eff = h.effectiveMinify();
    try std.testing.expect(!eff.mangle_external_bindings);
}

test "applyClientSettings: mangleExternalBindings wrong type silently ignored" {
    const h = try setup();
    defer teardown(h);

    var parsed = try parseJson("{\"mangleExternalBindings\":\"yes\"}");
    defer parsed.deinit();
    h.applyClientSettings(parsed.value);

    try std.testing.expect(!h.effectiveMinify().mangle_external_bindings);
}

test "applyClientSettings: minifyLints.severities populates per-code map" {
    const h = try setup();
    defer teardown(h);

    var parsed = try parseJson(
        \\{"minifyLints":{"severities":{"M0100":"warning","M0201":"off"}}}
    );
    defer parsed.deinit();
    h.applyClientSettings(parsed.value);

    try std.testing.expectEqual(@as(u32, 2), h.workspace_minify_severities.count());

    const m0100 = h.workspace_minify_severities.get("M0100") orelse {
        std.debug.print("no M0100 entry in severities map\n", .{});
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqual(wgslender.Diagnostic.Severity.warning, m0100);

    const m0201 = h.workspace_minify_severities.get("M0201") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(wgslender.Diagnostic.Severity.disabled, m0201);
}

test "applyClientSettings: severities accepts hint / info / warn / warning / error / off" {
    const h = try setup();
    defer teardown(h);

    var parsed = try parseJson(
        \\{"minifyLints":{"severities":{"M0100":"hint","M0101":"info","M0200":"warn","M0201":"warning","M0202":"error"}}}
    );
    defer parsed.deinit();
    h.applyClientSettings(parsed.value);

    try std.testing.expectEqual(wgslender.Diagnostic.Severity.hint, h.workspace_minify_severities.get("M0100").?);
    try std.testing.expectEqual(wgslender.Diagnostic.Severity.info, h.workspace_minify_severities.get("M0101").?);
    try std.testing.expectEqual(wgslender.Diagnostic.Severity.warning, h.workspace_minify_severities.get("M0200").?);
    try std.testing.expectEqual(wgslender.Diagnostic.Severity.warning, h.workspace_minify_severities.get("M0201").?);
    try std.testing.expectEqual(wgslender.Diagnostic.Severity.@"error", h.workspace_minify_severities.get("M0202").?);
}

test "applyClientSettings: severities empty object clears prior entries" {
    const h = try setup();
    defer teardown(h);

    var first = try parseJson(
        \\{"minifyLints":{"severities":{"M0100":"warning"}}}
    );
    defer first.deinit();
    h.applyClientSettings(first.value);
    try std.testing.expectEqual(@as(u32, 1), h.workspace_minify_severities.count());

    var second = try parseJson(
        \\{"minifyLints":{"severities":{}}}
    );
    defer second.deinit();
    h.applyClientSettings(second.value);
    try std.testing.expectEqual(@as(u32, 0), h.workspace_minify_severities.count());
}

test "applyClientSettings: severities absent leaves prior map intact" {
    const h = try setup();
    defer teardown(h);

    var first = try parseJson(
        \\{"minifyLints":{"severities":{"M0100":"warning"}}}
    );
    defer first.deinit();
    h.applyClientSettings(first.value);

    var second = try parseJson("{\"minifyMode\":\"strict\"}");
    defer second.deinit();
    h.applyClientSettings(second.value);

    try std.testing.expectEqual(@as(u32, 1), h.workspace_minify_severities.count());
    try std.testing.expectEqual(wgslender.Diagnostic.Severity.warning, h.workspace_minify_severities.get("M0100").?);
}

test "applyClientSettings: invalid severity strings silently skipped" {
    const h = try setup();
    defer teardown(h);

    var parsed = try parseJson(
        \\{"minifyLints":{"severities":{"M0100":"loud","M0201":"warning"}}}
    );
    defer parsed.deinit();
    h.applyClientSettings(parsed.value);

    try std.testing.expectEqual(@as(u32, 1), h.workspace_minify_severities.count());
    try std.testing.expect(h.workspace_minify_severities.get("M0100") == null);
    try std.testing.expectEqual(wgslender.Diagnostic.Severity.warning, h.workspace_minify_severities.get("M0201").?);
}

test "applyClientSettings: severities non-object silently ignored" {
    const h = try setup();
    defer teardown(h);

    var parsed = try parseJson(
        \\{"minifyLints":{"severities":"warn-everything"}}
    );
    defer parsed.deinit();
    h.applyClientSettings(parsed.value);

    try std.testing.expectEqual(@as(u32, 0), h.workspace_minify_severities.count());
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

test "applyClientSettings: minifyLints.budgetBytes integer sets workspace field" {
    const h = try setup();
    defer teardown(h);

    var parsed = try parseJson(
        \\{"minifyLints":{"budgetBytes":4096}}
    );
    defer parsed.deinit();
    h.applyClientSettings(parsed.value);

    try std.testing.expectEqual(@as(?u32, 4096), h.effectiveMinify().budget_bytes);
}

test "applyClientSettings: minifyLints.budgetBytes negative integer treated as unset" {
    const h = try setup();
    defer teardown(h);

    var parsed = try parseJson(
        \\{"minifyLints":{"budgetBytes":-1}}
    );
    defer parsed.deinit();
    h.applyClientSettings(parsed.value);

    try std.testing.expectEqual(@as(?u32, null), h.effectiveMinify().budget_bytes);
}

test "applyClientSettings: minifyLints.budgetBytes wrong type silently ignored" {
    const h = try setup();
    defer teardown(h);

    var parsed = try parseJson(
        \\{"minifyLints":{"budgetBytes":"1024"}}
    );
    defer parsed.deinit();
    h.applyClientSettings(parsed.value);

    try std.testing.expectEqual(@as(?u32, null), h.effectiveMinify().budget_bytes);
}

test "applyClientSettings: minifyLints.budgetBytes=null clears prior value" {
    const h = try setup();
    defer teardown(h);

    var on = try parseJson(
        \\{"minifyLints":{"budgetBytes":2048}}
    );
    defer on.deinit();
    h.applyClientSettings(on.value);
    try std.testing.expectEqual(@as(?u32, 2048), h.effectiveMinify().budget_bytes);

    var off = try parseJson(
        \\{"minifyLints":{"budgetBytes":null}}
    );
    defer off.deinit();
    h.applyClientSettings(off.value);
    try std.testing.expectEqual(@as(?u32, null), h.effectiveMinify().budget_bytes);
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

// =========================================================================
// Phase 2 — magic-comment layer via effectiveMinifyFor(uri)
// =========================================================================

test "effectiveMinifyFor: magic comment overrides workspace minify.mode" {
    const h = try setup();
    defer teardown(h);

    var parsed = try parseJson("{\"minifyMode\":\"insights\"}");
    defer parsed.deinit();
    h.applyClientSettings(parsed.value);

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

    var parsed = try parseJson("{\"minifyMode\":\"insights\"}");
    defer parsed.deinit();
    h.applyClientSettings(parsed.value);

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

    var parsed = try parseJson("{\"minifyMode\":\"insights\"}");
    defer parsed.deinit();
    h.applyClientSettings(parsed.value);

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
