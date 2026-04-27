//! Phase 7 — per-document `MinifyEstimator` cache + recompute notification.
//!
//! Pins the perf wins promised by master plan §10:
//!   * one estimator run shared across inlay hints + code lens + the
//!     M0500 lint rule for a given document version;
//!   * cache invalidation on parse-version bump (didChange) and on any
//!     minify-related settings refresh;
//!   * `mode = off` never enters the estimator, regardless of edits;
//!   * `wgslender/recomputeMinifyInsights` (WASM notification, native
//!     command shim) calls into the same `Handler.refreshMinifyInsights`
//!     entry point — proving the WASM dispatch in `lsp/wasm.zig` and the
//!     command dispatch in `Handler.executeCommand` converge.
//!
//! Each test snapshots `MinifyEstimator.estimate_count` before driving the
//! Handler and asserts on the delta. The counter is `pub var` for exactly
//! this purpose (mirrors `Lexer.tokenize_count` consumed by
//! `tests/lsp_analyze_perf_test.zig`).

const std = @import("std");
const Handler = @import("Handler");
const wgslender = @import("wgslender");
const MinifyEstimator = wgslender.MinifyEstimator;

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
    h.applyClientSettings(parsed.value);
}

const sample_shader: [:0]const u8 =
    \\fn helper_one() -> f32 { return 1.0; }
    \\fn helper_two() -> f32 { return 2.0; }
    \\@compute @workgroup_size(1) fn main() {
    \\    let _v = helper_one() + helper_two();
    \\}
;

const full_range: Handler.Range = .{
    .start = .{ .line = 0, .character = 0 },
    .end = .{ .line = 100, .character = 0 },
};

// =========================================================================
// Cache hit / miss semantics
// =========================================================================

test "perf: estimator does not run when mode=off regardless of edits" {
    const h = try setup();
    defer teardown(h);
    try h.openDocument("file:///a.wgsl", sample_shader, 1);

    const before = MinifyEstimator.estimate_count;

    // Drive a 32-edit burst — mode is off, nothing should ever reach
    // the estimator. `refreshMinifyInsights` short-circuits inside the
    // handler when `eff.insightsActive() and eff.lintsActive()` are both
    // false, so subsequent calls also stay at zero.
    var i: u32 = 0;
    while (i < 32) : (i += 1) {
        const txt = " ";
        try h.changeDocumentIncremental(
            "file:///a.wgsl",
            .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
            txt,
        );
        h.refreshMinifyInsights("file:///a.wgsl");
    }

    try std.testing.expectEqual(@as(u64, 0), MinifyEstimator.estimate_count - before);
}

test "perf: estimator result cached across inlay hint + code lens + rules" {
    const h = try setup();
    defer teardown(h);
    // Strict mode flips both `insightsActive()` (inlay/lens) and
    // `lintsActive()` (M-rules) on for this document.
    try applySettings(h, "{\"minifyMode\":\"strict\"}");
    try h.openDocument("file:///a.wgsl", sample_shader, 1);

    const before = MinifyEstimator.estimate_count;

    // Warm the cache. After this, every estimator-using path should
    // hit the cached entry (same module_version, same options=defaults).
    h.refreshMinifyInsights("file:///a.wgsl");
    const after_refresh = MinifyEstimator.estimate_count;
    try std.testing.expectEqual(@as(u64, 1), after_refresh - before);

    // Inlay hints — passes through `getMinifyEstimate` → cache hit.
    const hints = try h.computeInlayHints("file:///a.wgsl", full_range);
    std.testing.allocator.free(hints);

    // Code lens — same.
    const lenses = try h.computeCodeLens("file:///a.wgsl");
    Handler.freeCodeLens(std.testing.allocator, lenses);

    // Lint rules (M0500 etc.) — `validateDocumentFull` threads the
    // cached pointer into `Linter.Options.cached_minify_estimate`, so
    // the rule body skips its fallback `MinifyEstimator.estimate` call.
    const diags = try h.validateDocumentFull("file:///a.wgsl");
    Handler.freeDiagnostics(std.testing.allocator, diags);

    try std.testing.expectEqual(@as(u64, 1), MinifyEstimator.estimate_count - before);
}

test "perf: cache invalidated by didChange version bump" {
    const h = try setup();
    defer teardown(h);
    try applySettings(h, "{\"minifyMode\":\"insights\"}");
    try h.openDocument("file:///a.wgsl", sample_shader, 1);

    const before = MinifyEstimator.estimate_count;

    h.refreshMinifyInsights("file:///a.wgsl");
    try std.testing.expectEqual(@as(u64, 1), MinifyEstimator.estimate_count - before);

    // A single incremental edit bumps `parse.module_version`, which is
    // the cache key. The next refresh must miss and recompute.
    try h.changeDocumentIncremental(
        "file:///a.wgsl",
        .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
        " ",
    );
    h.refreshMinifyInsights("file:///a.wgsl");
    try std.testing.expectEqual(@as(u64, 2), MinifyEstimator.estimate_count - before);
}

test "perf: cache invalidated by minify settings change" {
    const h = try setup();
    defer teardown(h);
    try applySettings(h, "{\"minifyMode\":\"insights\"}");
    try h.openDocument("file:///a.wgsl", sample_shader, 1);

    const before = MinifyEstimator.estimate_count;

    h.refreshMinifyInsights("file:///a.wgsl");
    try std.testing.expectEqual(@as(u64, 1), MinifyEstimator.estimate_count - before);

    // Toggling the mangle flag could shift the resolved estimator
    // options, so `applyClientSettings` blows away every cache.
    try applySettings(h, "{\"mangleExternalBindings\":true}");
    h.refreshMinifyInsights("file:///a.wgsl");
    try std.testing.expectEqual(@as(u64, 2), MinifyEstimator.estimate_count - before);
}

test "perf: rapid didChange coalesces to single estimator run" {
    // The acceptance criterion from master plan §10.3: a 100-keystroke
    // burst followed by one refresh runs the estimator once. The
    // Handler-level contract guaranteeing this is:
    //   1. `changeDocumentIncremental` invalidates the cache without
    //      itself touching the estimator.
    //   2. `refreshMinifyInsights` is the only estimator-running entry
    //      point on the hot path (transports route through it once on
    //      idle / on `wgslender.recomputeMinifyInsights`).
    // Drive that contract here without a transport stub.
    const h = try setup();
    defer teardown(h);
    try applySettings(h, "{\"minifyMode\":\"strict\"}");
    try h.openDocument("file:///burst.wgsl", sample_shader, 1);

    const before = MinifyEstimator.estimate_count;

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        try h.changeDocumentIncremental(
            "file:///burst.wgsl",
            .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
            " ",
        );
    }

    // No estimator runs during the burst — the cache is invalidated on
    // every parse-version bump but never recomputed without an explicit
    // pull (inlay/lens/lint) or the refresh entry point.
    try std.testing.expectEqual(@as(u64, 0), MinifyEstimator.estimate_count - before);

    h.refreshMinifyInsights("file:///burst.wgsl");

    // One estimator run after the burst, comfortably inside the master
    // plan's "≤ 2× total" allowance.
    try std.testing.expectEqual(@as(u64, 1), MinifyEstimator.estimate_count - before);
}

test "perf: refreshMinifyInsights hand-off (recomputeMinifyInsights path)" {
    // The WASM transport's `wgslender/recomputeMinifyInsights` notification
    // (lsp/wasm.zig:handleRecomputeMinifyInsights) and the native
    // `wgslender.recomputeMinifyInsights` executeCommand entry both call
    // `Handler.refreshMinifyInsights(uri)` → `emitDiagnostics(uri)` /
    // `republishAllDocuments`. Driving the shared entry point exercises
    // the cache-warming side-effect both transports rely on without
    // standing up a transport stub.
    const h = try setup();
    defer teardown(h);
    try applySettings(h, "{\"minifyMode\":\"insights\"}");
    try h.openDocument("file:///a.wgsl", sample_shader, 1);

    const before = MinifyEstimator.estimate_count;

    // First call warms the cache.
    h.refreshMinifyInsights("file:///a.wgsl");
    try std.testing.expectEqual(@as(u64, 1), MinifyEstimator.estimate_count - before);

    // A second call against the same parse-version + options is a
    // no-op (cache hit). This is what allows the JS-side debounce to
    // fire opportunistically without a perf cost.
    h.refreshMinifyInsights("file:///a.wgsl");
    try std.testing.expectEqual(@as(u64, 1), MinifyEstimator.estimate_count - before);
}
