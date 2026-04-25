//! Tests for `MinifySettings.resolve` — the precedence-merge used by the
//! LSP handler to combine magic-comment, workspace, and project-config
//! layers into the effective minify mode state.

const std = @import("std");
const wgslender = @import("wgslender");
const MinifySettings = wgslender.MinifySettings;

test "resolve: empty layers produce off mode with all sub-switches off" {
    const eff = MinifySettings.resolve(.{}, .{}, .{});
    try std.testing.expectEqual(MinifySettings.Mode.off, eff.mode);
    try std.testing.expect(!eff.insights.function_size);
    try std.testing.expect(!eff.insights.decl_size);
    try std.testing.expect(!eff.insights.total_size);
    try std.testing.expect(!eff.lints.enabled);
    try std.testing.expect(!eff.insightsActive());
    try std.testing.expect(!eff.lintsActive());
}

test "resolve: project mode=insights turns on all insights sub-switches" {
    const eff = MinifySettings.resolve(.{ .mode = .insights }, .{}, .{});
    try std.testing.expectEqual(MinifySettings.Mode.insights, eff.mode);
    try std.testing.expect(eff.insights.function_size);
    try std.testing.expect(eff.insights.decl_size);
    try std.testing.expect(eff.insights.total_size);
    try std.testing.expect(!eff.lints.enabled);
    try std.testing.expect(eff.insightsActive());
    try std.testing.expect(!eff.lintsActive());
}

test "resolve: project mode=strict turns on lints in addition to insights" {
    const eff = MinifySettings.resolve(.{ .mode = .strict }, .{}, .{});
    try std.testing.expectEqual(MinifySettings.Mode.strict, eff.mode);
    try std.testing.expect(eff.insights.function_size);
    try std.testing.expect(eff.lints.enabled);
    try std.testing.expect(eff.insightsActive());
    try std.testing.expect(eff.lintsActive());
}

test "resolve: workspace overrides project mode" {
    const eff = MinifySettings.resolve(
        .{ .mode = .insights },
        .{ .mode = .strict },
        .{},
    );
    try std.testing.expectEqual(MinifySettings.Mode.strict, eff.mode);
    try std.testing.expect(eff.lints.enabled);
}

test "resolve: magic comment overrides workspace and project" {
    const eff = MinifySettings.resolve(
        .{ .mode = .strict },
        .{ .mode = .insights },
        .{ .mode = .off },
    );
    try std.testing.expectEqual(MinifySettings.Mode.off, eff.mode);
    try std.testing.expect(!eff.insightsActive());
}

test "resolve: explicit function_size=false overrides mode-derived true" {
    const eff = MinifySettings.resolve(
        .{ .mode = .insights, .function_size = false },
        .{},
        .{},
    );
    try std.testing.expectEqual(MinifySettings.Mode.insights, eff.mode);
    try std.testing.expect(!eff.insights.function_size);
    try std.testing.expect(eff.insights.decl_size);
    try std.testing.expect(eff.insights.total_size);
}

test "resolve: higher-precedence sub-switch beats lower-precedence" {
    const eff = MinifySettings.resolve(
        .{ .mode = .insights, .decl_size = false },
        .{ .decl_size = true },
        .{},
    );
    try std.testing.expect(eff.insights.decl_size);
}

test "resolve: format propagates from workspace when project is null" {
    const eff = MinifySettings.resolve(
        .{ .mode = .insights },
        .{ .format = .both },
        .{},
    );
    try std.testing.expectEqual(MinifySettings.InsightsFormat.both, eff.insights.format);
}

test "resolve: magic comment format wins over workspace" {
    const eff = MinifySettings.resolve(
        .{ .mode = .insights },
        .{ .format = .delta },
        .{ .format = .bytes },
    );
    try std.testing.expectEqual(MinifySettings.InsightsFormat.bytes, eff.insights.format);
}

test "resolve: explicit lints_enabled=false in strict mode disables lints" {
    const eff = MinifySettings.resolve(
        .{ .mode = .strict, .lints_enabled = false },
        .{},
        .{},
    );
    try std.testing.expectEqual(MinifySettings.Mode.strict, eff.mode);
    try std.testing.expect(!eff.lints.enabled);
    try std.testing.expect(!eff.lintsActive());
}

test "resolve: explicit lints_enabled=true in insights mode enables lints" {
    const eff = MinifySettings.resolve(
        .{ .mode = .insights, .lints_enabled = true },
        .{},
        .{},
    );
    try std.testing.expectEqual(MinifySettings.Mode.insights, eff.mode);
    try std.testing.expect(eff.lints.enabled);
    // lintsActive() requires strict mode + enabled — so still false.
    try std.testing.expect(!eff.lintsActive());
}

// =========================================================================
// mangle_external_bindings — Phase 5b
// =========================================================================
//
// The field is a build-pipeline opt-in: when the user runs the CLI with
// `--mangle-external-bindings`, the LSP needs to know so M0100 (the hint
// that flags external bindings as un-renameable) can be silenced.

test "resolve: mangle_external_bindings defaults to false" {
    const eff = MinifySettings.resolve(.{}, .{}, .{});
    try std.testing.expect(!eff.mangle_external_bindings);
}

test "resolve: project mangle_external_bindings=true propagates" {
    const eff = MinifySettings.resolve(
        .{ .mangle_external_bindings = true },
        .{},
        .{},
    );
    try std.testing.expect(eff.mangle_external_bindings);
}

test "resolve: workspace mangle_external_bindings overrides project" {
    const eff = MinifySettings.resolve(
        .{ .mangle_external_bindings = false },
        .{ .mangle_external_bindings = true },
        .{},
    );
    try std.testing.expect(eff.mangle_external_bindings);
}

test "resolve: magic mangle_external_bindings beats workspace + project" {
    const eff = MinifySettings.resolve(
        .{ .mangle_external_bindings = false },
        .{ .mangle_external_bindings = false },
        .{ .mangle_external_bindings = true },
    );
    try std.testing.expect(eff.mangle_external_bindings);
}

test "resolve: workspace null leaves project mangle_external_bindings intact" {
    const eff = MinifySettings.resolve(
        .{ .mangle_external_bindings = true },
        .{},
        .{},
    );
    try std.testing.expect(eff.mangle_external_bindings);
}

test "Mode.fromString: accepts exactly the three canonical values" {
    try std.testing.expectEqual(MinifySettings.Mode.off, MinifySettings.Mode.fromString("off").?);
    try std.testing.expectEqual(MinifySettings.Mode.insights, MinifySettings.Mode.fromString("insights").?);
    try std.testing.expectEqual(MinifySettings.Mode.strict, MinifySettings.Mode.fromString("strict").?);
    try std.testing.expectEqual(@as(?MinifySettings.Mode, null), MinifySettings.Mode.fromString("Insights"));
    try std.testing.expectEqual(@as(?MinifySettings.Mode, null), MinifySettings.Mode.fromString(""));
    try std.testing.expectEqual(@as(?MinifySettings.Mode, null), MinifySettings.Mode.fromString("loud"));
}

test "InsightsFormat.fromString: accepts exactly delta/bytes/both" {
    try std.testing.expectEqual(MinifySettings.InsightsFormat.delta, MinifySettings.InsightsFormat.fromString("delta").?);
    try std.testing.expectEqual(MinifySettings.InsightsFormat.bytes, MinifySettings.InsightsFormat.fromString("bytes").?);
    try std.testing.expectEqual(MinifySettings.InsightsFormat.both, MinifySettings.InsightsFormat.fromString("both").?);
    try std.testing.expectEqual(@as(?MinifySettings.InsightsFormat, null), MinifySettings.InsightsFormat.fromString("DELTA"));
    try std.testing.expectEqual(@as(?MinifySettings.InsightsFormat, null), MinifySettings.InsightsFormat.fromString(""));
}

// =========================================================================
// Config.parseJson "lsp" section — project-config layer
// =========================================================================

test "Config: empty lsp section yields empty Partial" {
    const cfg = try wgslender.Config.parseJson(std.testing.allocator, "{}");
    try std.testing.expectEqual(@as(?MinifySettings.Mode, null), cfg.lsp_minify.mode);
    try std.testing.expectEqual(@as(?bool, null), cfg.lsp_minify.function_size);
    try std.testing.expectEqual(@as(?bool, null), cfg.lsp_minify.lints_enabled);
}

test "Config: lsp.minifyMode=insights parses into Partial" {
    const cfg = try wgslender.Config.parseJson(
        std.testing.allocator,
        "{\"lsp\":{\"minifyMode\":\"insights\"}}",
    );
    try std.testing.expectEqual(MinifySettings.Mode.insights, cfg.lsp_minify.mode.?);
}

test "Config: lsp.minifyMode=strict parses" {
    const cfg = try wgslender.Config.parseJson(
        std.testing.allocator,
        "{\"lsp\":{\"minifyMode\":\"strict\"}}",
    );
    try std.testing.expectEqual(MinifySettings.Mode.strict, cfg.lsp_minify.mode.?);
}

test "Config: lsp.minifyMode=off parses" {
    const cfg = try wgslender.Config.parseJson(
        std.testing.allocator,
        "{\"lsp\":{\"minifyMode\":\"off\"}}",
    );
    try std.testing.expectEqual(MinifySettings.Mode.off, cfg.lsp_minify.mode.?);
}

test "Config: lsp.minifyMode with unknown value leaves Partial empty" {
    // Permissive: matches existing behaviour for wrong-type fields.
    const cfg = try wgslender.Config.parseJson(
        std.testing.allocator,
        "{\"lsp\":{\"minifyMode\":\"loud\"}}",
    );
    try std.testing.expectEqual(@as(?MinifySettings.Mode, null), cfg.lsp_minify.mode);
}

test "Config: lsp.minifyInsights nested fields parse" {
    const cfg = try wgslender.Config.parseJson(
        std.testing.allocator,
        \\{"lsp":{"minifyInsights":{"format":"both","functionSize":false,"declSize":false,"totalSize":true}}}
        ,
    );
    try std.testing.expectEqual(MinifySettings.InsightsFormat.both, cfg.lsp_minify.format.?);
    try std.testing.expectEqual(@as(?bool, false), cfg.lsp_minify.function_size);
    try std.testing.expectEqual(@as(?bool, false), cfg.lsp_minify.decl_size);
    try std.testing.expectEqual(@as(?bool, true), cfg.lsp_minify.total_size);
}

test "Config: lsp.minifyLints.enabled parses" {
    const cfg = try wgslender.Config.parseJson(
        std.testing.allocator,
        "{\"lsp\":{\"minifyLints\":{\"enabled\":true}}}",
    );
    try std.testing.expectEqual(@as(?bool, true), cfg.lsp_minify.lints_enabled);
}

test "Config: lsp.mangleExternalBindings parses into Partial" {
    const cfg = try wgslender.Config.parseJson(
        std.testing.allocator,
        "{\"lsp\":{\"mangleExternalBindings\":true}}",
    );
    try std.testing.expectEqual(@as(?bool, true), cfg.lsp_minify.mangle_external_bindings);
}

test "Config: lsp.mangleExternalBindings absent leaves Partial null" {
    const cfg = try wgslender.Config.parseJson(
        std.testing.allocator,
        "{\"lsp\":{\"minifyMode\":\"strict\"}}",
    );
    try std.testing.expectEqual(@as(?bool, null), cfg.lsp_minify.mangle_external_bindings);
}

test "Config: lsp section with wrong types silently ignored" {
    // mirrors existing permissive parsing for other Config fields
    const cfg = try wgslender.Config.parseJson(
        std.testing.allocator,
        \\{"lsp":{"minifyMode":42,"minifyInsights":"nope","minifyLints":true}}
        ,
    );
    try std.testing.expectEqual(@as(?MinifySettings.Mode, null), cfg.lsp_minify.mode);
    try std.testing.expectEqual(@as(?bool, null), cfg.lsp_minify.function_size);
    try std.testing.expectEqual(@as(?bool, null), cfg.lsp_minify.lints_enabled);
}

test "Config: non-lsp fields unaffected by adding lsp section" {
    const cfg = try wgslender.Config.parseJson(
        std.testing.allocator,
        \\{"minifyWhitespace":true,"lsp":{"minifyMode":"insights"}}
        ,
    );
    try std.testing.expectEqual(@as(?bool, true), cfg.minify_whitespace);
    try std.testing.expectEqual(MinifySettings.Mode.insights, cfg.lsp_minify.mode.?);
}
