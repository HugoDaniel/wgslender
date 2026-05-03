//! Minifier-mode settings shared between the CLI config loader, the LSP
//! handler, and the per-document magic-comment scanner.
//!
//! A `Partial` carries the keys a single layer provided; `resolve()` merges
//! layers in precedence order (magic > workspace > project > defaults) into
//! an `Effective` value the rest of the server reads.

const std = @import("std");

pub const Mode = enum {
    off,
    insights,
    strict,

    pub fn fromString(s: []const u8) ?Mode {
        if (std.mem.eql(u8, s, "off")) return .off;
        if (std.mem.eql(u8, s, "insights")) return .insights;
        if (std.mem.eql(u8, s, "strict")) return .strict;
        return null;
    }
};

pub const InsightsFormat = enum {
    delta,
    bytes,
    both,

    pub fn fromString(s: []const u8) ?InsightsFormat {
        if (std.mem.eql(u8, s, "delta")) return .delta;
        if (std.mem.eql(u8, s, "bytes")) return .bytes;
        if (std.mem.eql(u8, s, "both")) return .both;
        return null;
    }
};

pub const InsightsSwitches = struct {
    function_size: bool = true,
    decl_size: bool = true,
    total_size: bool = true,
    format: InsightsFormat = .delta,
};

pub const LintsSwitches = struct {
    enabled: bool = false,
};

/// A single configuration layer. Any field that is `null` means "this layer
/// did not set it"; the resolver falls through to the next layer.
pub const Partial = struct {
    mode: ?Mode = null,
    function_size: ?bool = null,
    decl_size: ?bool = null,
    total_size: ?bool = null,
    format: ?InsightsFormat = null,
    lints_enabled: ?bool = null,
    /// LSP-side budget for `M0500 minify/shader-exceeds-size-budget`.
    /// When the resolved value is non-null, the LSP forwards it as
    /// `{"maxBytes": N}` to the rule's `RuleOverride.options`. `null`
    /// keeps the rule a no-op (matches its CLI default — see the rule
    /// docstring for the rationale against a defensible default).
    /// JSON-only knob; magic comments do not set this field, mirroring
    /// the precedent for `severities` (§18 entry 13 of the design plan).
    budget_bytes: ?u32 = null,
    /// Phase 8 — opt-in: when true, the LSP runs the heavy
    /// full-minify estimator path (production renamer + gzip-of-output)
    /// instead of the cheap length-only estimator. Documented tradeoff:
    /// slower interactivity, ground-truth byte and gzip counts. JSON
    /// shape: `wgslender.minifyEstimator.useFullMinify`.
    use_full_minify: ?bool = null,
};

pub const Effective = struct {
    mode: Mode = .off,
    insights: InsightsSwitches = .{},
    lints: LintsSwitches = .{},
    /// Resolved view of `Partial.budget_bytes`. The Handler forwards this
    /// to M0500's `RuleOverride.options` when non-null; the total-size
    /// code lens compares against it to render the over-budget badge.
    /// `null` = unset (M0500 stays a no-op).
    budget_bytes: ?u32 = null,
    /// Resolved view of `Partial.use_full_minify`. The Handler folds
    /// this into the `MinifyEstimator.Options` it builds for the cache
    /// key, so flipping the setting forces a clean recompute via
    /// `invalidateAllMinifyCaches` + the new key mismatch.
    use_full_minify: bool = false,

    pub fn insightsActive(self: Effective) bool {
        return self.mode != .off;
    }

    pub fn lintsActive(self: Effective) bool {
        return self.mode == .strict and self.lints.enabled;
    }
};

/// Merge layers in precedence order: `magic` (highest) > `workspace` >
/// `project` > hard-coded defaults. Later-layer `null` fields defer to
/// earlier layers; later-layer concrete fields win.
///
/// `mode` alone also seeds the insights / lints sub-switches:
///   - `off`      → all sub-switches disabled
///   - `insights` → sub-switches on, lints off
///   - `strict`   → sub-switches on, lints on
/// Explicit sub-switch fields from any layer override the mode-derived
/// defaults.
pub fn resolve(project: Partial, workspace: Partial, magic: Partial) Effective {
    const mode: Mode = magic.mode orelse workspace.mode orelse project.mode orelse .off;

    var insights: InsightsSwitches = switch (mode) {
        .off => .{ .function_size = false, .decl_size = false, .total_size = false },
        .insights, .strict => .{},
    };
    var lints: LintsSwitches = .{ .enabled = mode == .strict };
    var budget_bytes: ?u32 = null;
    var use_full_minify: bool = false;

    inline for ([_]Partial{ project, workspace, magic }) |layer| {
        if (layer.function_size) |v| insights.function_size = v;
        if (layer.decl_size) |v| insights.decl_size = v;
        if (layer.total_size) |v| insights.total_size = v;
        if (layer.format) |v| insights.format = v;
        if (layer.lints_enabled) |v| lints.enabled = v;
        if (layer.budget_bytes) |v| budget_bytes = v;
        if (layer.use_full_minify) |v| use_full_minify = v;
    }

    return .{
        .mode = mode,
        .insights = insights,
        .lints = lints,
        .budget_bytes = budget_bytes,
        .use_full_minify = use_full_minify,
    };
}
