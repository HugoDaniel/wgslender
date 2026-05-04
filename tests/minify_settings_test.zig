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

test "resolve: explicit function_size=true overrides mode=off-derived false" {
    const eff = MinifySettings.resolve(
        .{ .mode = .off, .function_size = true },
        .{},
        .{},
    );
    try std.testing.expectEqual(MinifySettings.Mode.off, eff.mode);
    try std.testing.expect(eff.insights.function_size);
    try std.testing.expect(!eff.insights.decl_size);
    try std.testing.expect(!eff.insights.total_size);
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
// budget_bytes — Phase 6
// =========================================================================
//
// Confirm that the field threads through `Partial` → `Effective` and
// respects the standard magic > workspace > project precedence. Tri-state
// (`?u32`) means a zero budget is meaningful (M0500 fires on anything),
// distinct from "unset" (rule no-ops).

test "resolve: budget_bytes defaults to null" {
    const eff = MinifySettings.resolve(.{}, .{}, .{});
    try std.testing.expectEqual(@as(?u32, null), eff.budget_bytes);
}

test "resolve: project budget_bytes propagates" {
    const eff = MinifySettings.resolve(
        .{ .budget_bytes = 4096 },
        .{},
        .{},
    );
    try std.testing.expectEqual(@as(?u32, 4096), eff.budget_bytes);
}

test "resolve: workspace budget_bytes overrides project" {
    const eff = MinifySettings.resolve(
        .{ .budget_bytes = 4096 },
        .{ .budget_bytes = 8192 },
        .{},
    );
    try std.testing.expectEqual(@as(?u32, 8192), eff.budget_bytes);
}

test "resolve: workspace null leaves project budget_bytes intact" {
    const eff = MinifySettings.resolve(
        .{ .budget_bytes = 4096 },
        .{},
        .{},
    );
    try std.testing.expectEqual(@as(?u32, 4096), eff.budget_bytes);
}

test "resolve: budget_bytes=0 is meaningful (distinct from null)" {
    const eff = MinifySettings.resolve(
        .{ .budget_bytes = 0 },
        .{},
        .{},
    );
    try std.testing.expectEqual(@as(?u32, 0), eff.budget_bytes);
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

test "Config: lsp.minifyLints.budgetBytes parses into Partial" {
    const cfg = try wgslender.Config.parseJson(
        std.testing.allocator,
        "{\"lsp\":{\"minifyLints\":{\"budgetBytes\":4096}}}",
    );
    try std.testing.expectEqual(@as(?u32, 4096), cfg.lsp_minify.budget_bytes);
}

test "Config: lsp.minifyLints.budgetBytes negative silently ignored" {
    const cfg = try wgslender.Config.parseJson(
        std.testing.allocator,
        "{\"lsp\":{\"minifyLints\":{\"budgetBytes\":-1}}}",
    );
    try std.testing.expectEqual(@as(?u32, null), cfg.lsp_minify.budget_bytes);
}

test "Config: lsp.minifyLints.budgetBytes absent leaves Partial null" {
    const cfg = try wgslender.Config.parseJson(
        std.testing.allocator,
        "{\"lsp\":{\"minifyLints\":{\"enabled\":true}}}",
    );
    try std.testing.expectEqual(@as(?u32, null), cfg.lsp_minify.budget_bytes);
}

test "Config: top-level mangleExternalBindings parses (single source of truth)" {
    const cfg = try wgslender.Config.parseJson(
        std.testing.allocator,
        "{\"mangleExternalBindings\":true}",
    );
    try std.testing.expectEqual(@as(?bool, true), cfg.mangle_external_bindings);
}

test "Config: legacy lsp.mangleExternalBindings is silently ignored" {
    // Schema break: the nested `lsp.mangleExternalBindings` key is no
    // longer parsed. Permissive JSON parsing means the LSP just drops
    // the unknown key — clients that pushed the old shape will see
    // their value treated as absent.
    const cfg = try wgslender.Config.parseJson(
        std.testing.allocator,
        "{\"lsp\":{\"mangleExternalBindings\":true}}",
    );
    try std.testing.expectEqual(@as(?bool, null), cfg.mangle_external_bindings);
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
