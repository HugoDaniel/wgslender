//! Minifier-mode settings shared between the CLI config loader, the LSP
//! handler, and the per-document magic-comment scanner.
//!
//! A `Partial` carries the keys a single layer provided; `resolve()` merges
//! layers in precedence order (magic > workspace > project > defaults) into
//! an `Effective` value the rest of the server reads.

const std = @import("std");
const options = @import("options.zig");

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

/// JSON-parsing specs for `Partial`. Dotted `json_override` paths target
/// the inner `lsp` object — callers (e.g. `Config.applyJsonValue`) pass
/// `lsp` as the JSON root, not the whole `wgslender.json` root. The
/// comptime guard below catches drift between the spec and the field
/// shape (renamed field, wrong type → build error).
pub const partial_specs = [_]options.OptionSpec{
    .{ .field = "mode", .kind = .{ .enum_opt = Mode }, .json_override = "minifyMode" },
    .{ .field = "format", .kind = .{ .enum_opt = InsightsFormat }, .json_override = "minifyInsights.format" },
    .{ .field = "function_size", .kind = .bool_opt, .json_override = "minifyInsights.functionSize" },
    .{ .field = "decl_size", .kind = .bool_opt, .json_override = "minifyInsights.declSize" },
    .{ .field = "total_size", .kind = .bool_opt, .json_override = "minifyInsights.totalSize" },
    .{ .field = "lints_enabled", .kind = .bool_opt, .json_override = "minifyLints.enabled" },
    // budget_bytes is intentionally JSON-only (mirrors `severities`):
    // embedding a project-wide byte budget in source would let any
    // contributor change it. The field's doc comment captures the
    // rationale; `magic_comment = false` enforces it at the parser.
    .{ .field = "budget_bytes", .kind = .u32_opt, .json_override = "minifyLints.budgetBytes", .magic_comment = false },
    .{ .field = "use_full_minify", .kind = .bool_opt, .json_override = "minifyEstimator.useFullMinify" },
};

comptime {
    options.assertSpecFieldsExist(Partial, &partial_specs);
}

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

/// Mode-derived defaults expressed as a synthetic `Partial`. The mode
/// implies which sub-switches are on by default; explicit fields from
/// any user layer overlay these.
///
///   - `off`      → all sub-switches off
///   - `insights` → insights on, lints off
///   - `strict`   → insights on, lints on
///
/// `format`, `budget_bytes`, and `use_full_minify` are not mode-derived
/// — they fall back to the `Effective` struct defaults instead.
fn modeDefaults(mode: Mode) Partial {
    return switch (mode) {
        .off => .{
            .function_size = false,
            .decl_size = false,
            .total_size = false,
            .lints_enabled = false,
        },
        .insights => .{
            .function_size = true,
            .decl_size = true,
            .total_size = true,
            .lints_enabled = false,
        },
        .strict => .{
            .function_size = true,
            .decl_size = true,
            .total_size = true,
            .lints_enabled = true,
        },
    };
}

/// Merge layers in precedence order: `magic` (highest) > `workspace` >
/// `project` > mode-derived defaults > hard-coded struct defaults.
/// Later-layer `null` fields defer to earlier layers; later-layer
/// concrete fields win. Mode-derived defaults — see `modeDefaults` —
/// flow through the same overlay machinery as a synthetic bottom layer,
/// so explicit fields from any user layer override them uniformly.
pub fn resolve(project: Partial, workspace: Partial, magic: Partial) Effective {
    const mode: Mode = magic.mode orelse workspace.mode orelse project.mode orelse .off;
    var eff: Effective = .{ .mode = mode };
    inline for ([_]Partial{ modeDefaults(mode), project, workspace, magic }) |layer| {
        if (layer.function_size) |v| eff.insights.function_size = v;
        if (layer.decl_size) |v| eff.insights.decl_size = v;
        if (layer.total_size) |v| eff.insights.total_size = v;
        if (layer.format) |v| eff.insights.format = v;
        if (layer.lints_enabled) |v| eff.lints.enabled = v;
        if (layer.budget_bytes) |v| eff.budget_bytes = v;
        if (layer.use_full_minify) |v| eff.use_full_minify = v;
    }
    return eff;
}
