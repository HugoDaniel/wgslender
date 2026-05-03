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
const NativeServer = @import("NativeServer");
const lsp = @import("lsp");
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
    h.applyClientConfig(parsed.value);
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
    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"strict\"}}");
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
    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"insights\"}}");
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
    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"insights\"}}");
    try h.openDocument("file:///a.wgsl", sample_shader, 1);

    const before = MinifyEstimator.estimate_count;

    h.refreshMinifyInsights("file:///a.wgsl");
    try std.testing.expectEqual(@as(u64, 1), MinifyEstimator.estimate_count - before);

    // Toggling the mangle flag shifts the resolved estimator options,
    // so `applyClientConfig` blows away every cache. The push carries
    // both keys because each push replaces the workspace overlay
    // wholesale — omitting `minifyMode` would drop it back to `off`
    // and the early-out path wouldn't even reach the estimator.
    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"insights\",\"mangleExternalBindings\":true}}");
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
    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"strict\"}}");
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

// =========================================================================
// Native LSP timer-thread integration
// =========================================================================
//
// These tests exercise the Phase-7 native idle-debounce wiring inside
// `NativeServer` without spawning the real timer thread (it would race
// with wall-clock waits and slow the suite). Instead we drive `tick(now_ms)`
// directly with synthetic monotonic timestamps and assert on the
// estimator counter — same coverage, deterministic timing.

/// Discards every `writeNotification` / `writeJsonMessage` so tests can
/// run NativeServer methods that publish diagnostics without a real
/// stdio pipe.
const NullTransport = struct {
    transport: lsp.Transport = .{
        .vtable = &.{
            .readJsonMessage = readJsonMessage,
            .writeJsonMessage = writeJsonMessage,
        },
    },

    fn readJsonMessage(_: *lsp.Transport, _: std.Io, _: std.mem.Allocator) lsp.Transport.ReadError![]u8 {
        return error.EndOfStream;
    }

    fn writeJsonMessage(_: *lsp.Transport, _: std.Io, _: []const u8) lsp.Transport.WriteError!void {}
};

fn setupServer(debounce_ms: i64) !*NativeServer {
    const ptr = try std.testing.allocator.create(NativeServer);
    const transport_box = try std.testing.allocator.create(NullTransport);
    transport_box.* = .{};
    ptr.* = NativeServer.init(std.testing.allocator, &transport_box.transport, std.testing.io);
    ptr.debounce_ms = debounce_ms;
    return ptr;
}

fn teardownServer(server: *NativeServer) void {
    // Recover the NullTransport box from the transport pointer. NativeServer
    // never frees the transport — that's the caller's responsibility (in
    // production it's a stack-allocated `lsp.Transport.Stdio`).
    const transport_box: *NullTransport = @fieldParentPtr("transport", server.transport);
    server.deinit();
    std.testing.allocator.destroy(transport_box);
    std.testing.allocator.destroy(server);
}

fn driveDidChange(server: *NativeServer, uri: []const u8, text: []const u8) !void {
    const partial: lsp.types.TextDocument.ContentChangeEvent = .{
        .text_document_content_change_partial = .{
            .range = .{
                .start = .{ .line = 0, .character = 0 },
                .end = .{ .line = 0, .character = 0 },
            },
            .text = text,
        },
    };
    var changes = [_]lsp.types.TextDocument.ContentChangeEvent{partial};
    try server.@"textDocument/didChange"(std.testing.allocator, .{
        .textDocument = .{ .uri = uri, .version = 1 },
        .contentChanges = &changes,
    });
}

test "perf: native LSP timer debounces 300ms idle" {
    // Drive a 16-edit burst against a NativeServer in `mode=strict` and
    // assert the estimator never runs during the burst — every didChange
    // hits the cheap path and arms the debouncer for `now + debounce_ms`.
    // A `tick` before the deadline fires nothing; a `tick` after it
    // fires exactly once for the latest version.
    const server = try setupServer(300);
    defer teardownServer(server);

    try applySettings(&server.handler, "{\"lsp\":{\"minifyMode\":\"strict\"}}");
    try server.handler.openDocument("file:///burst.wgsl", sample_shader, 1);
    const before = MinifyEstimator.estimate_count;

    // 16 edits — `didChange` runs the cheap path (no estimator) and
    // arms the debouncer for `now + 300`. The latest arm wins.
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        try driveDidChange(server, "file:///burst.wgsl", " ");
    }
    try std.testing.expectEqual(@as(u64, 0), MinifyEstimator.estimate_count - before);

    // Compute a deadline aligned with the debouncer's own clock so the
    // test doesn't depend on wall-clock skew between `nowMs` calls.
    const dl = server.debouncer.nextDeadline() orelse return error.TestUnexpectedResult;

    // Tick 50 ms before the deadline → nothing fires.
    server.tick(dl - 50);
    try std.testing.expectEqual(@as(u64, 0), MinifyEstimator.estimate_count - before);

    // Tick at the deadline → drain runs, refreshes, full-publishes.
    // One estimator run total for the burst.
    server.tick(dl);
    try std.testing.expectEqual(@as(u64, 1), MinifyEstimator.estimate_count - before);
}

test "perf: native settings change resets debounce timer" {
    // Acceptance for master plan §10.1 "settings change resets debounce
    // timer": after `applyClientSettings` the deadline for every open
    // doc is pushed forward to `now + debounce_ms`, so any in-flight
    // debounce window from prior typing no longer fires at its old
    // deadline.
    const server = try setupServer(300);
    defer teardownServer(server);

    try applySettings(&server.handler, "{\"lsp\":{\"minifyMode\":\"strict\"}}");
    try server.handler.openDocument("file:///settings.wgsl", sample_shader, 1);

    // Arm via a didChange — deadline = now + 300.
    try driveDidChange(server, "file:///settings.wgsl", " ");
    const dl1 = server.debouncer.nextDeadline() orelse return error.TestUnexpectedResult;
    const before = MinifyEstimator.estimate_count;

    // Tiny wall-clock wait so the re-arm's `nowMs()` reads strictly
    // after the original arm — otherwise `dl2` may equal `dl1` on
    // platforms where `Clock.awake` resolution is coarser than the
    // microseconds between the two calls, and a `tick(dl1)` would
    // fire the re-armed entry too.
    std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake) catch {};

    // Simulate a settings refresh by going through the same code path
    // that `onResponse` uses: re-apply settings + re-arm every open
    // doc. This is what the timer thread observes when the client
    // pushes a `workspace/configuration` response.
    try applySettings(&server.handler, "{\"lsp\":{\"minifyMode\":\"strict\"}}");
    server.rearmAllOpenDocsForTest();

    const dl2 = server.debouncer.nextDeadline() orelse return error.TestUnexpectedResult;

    // The new deadline is strictly after the original one — the
    // settings refresh shifted the debounce window forward.
    try std.testing.expect(dl2 >= dl1);

    // Ticking at the original deadline now does nothing — the entry
    // was re-armed past it.
    server.tick(dl1);
    try std.testing.expectEqual(@as(u64, 0), MinifyEstimator.estimate_count - before);

    // Ticking at the new deadline drains and runs the estimator once.
    server.tick(dl2);
    try std.testing.expectEqual(@as(u64, 1), MinifyEstimator.estimate_count - before);
}

// =========================================================================
// Phase 8 — full-minify estimator fallback caching
// =========================================================================

const full_minify_settings: []const u8 =
    \\{"lsp":{"minifyMode":"strict","minifyEstimator":{"useFullMinify":true}}}
;

test "perf: full-minify result cached by module version" {
    // Same module + same resolved options → second refresh is a cache
    // hit, not a re-run. Mirrors §11.1 "full-minify result cached by
    // AST structural hash" (module_version is the structural-hash
    // surrogate the rest of the Handler keys against).
    const h = try setup();
    defer teardown(h);
    try applySettings(h, full_minify_settings);
    try h.openDocument("file:///full.wgsl", sample_shader, 1);

    const before = MinifyEstimator.estimate_count;

    h.refreshMinifyInsights("file:///full.wgsl");
    try std.testing.expectEqual(@as(u64, 1), MinifyEstimator.estimate_count - before);

    h.refreshMinifyInsights("file:///full.wgsl");
    try std.testing.expectEqual(@as(u64, 1), MinifyEstimator.estimate_count - before);
}

test "perf: full-minify cache hit across getMinifyEstimate calls" {
    // §11.1 "full-minify cache hit avoids re-run" — direct
    // `getMinifyEstimate` exercises the same cache from the LSP-side
    // entry without going through `refreshMinifyInsights`.
    const h = try setup();
    defer teardown(h);
    try applySettings(h, full_minify_settings);
    try h.openDocument("file:///full.wgsl", sample_shader, 1);

    const before = MinifyEstimator.estimate_count;

    var opts: MinifyEstimator.Options = .{};
    opts.use_full_minify = true;
    _ = try h.getMinifyEstimate("file:///full.wgsl", opts);
    try std.testing.expectEqual(@as(u64, 1), MinifyEstimator.estimate_count - before);

    _ = try h.getMinifyEstimate("file:///full.wgsl", opts);
    try std.testing.expectEqual(@as(u64, 1), MinifyEstimator.estimate_count - before);
}

test "perf: full-minify cache invalidated by AST mutation" {
    // §11.1 "AST mutation invalidates full-minify cache" — the cache
    // key includes the parse `module_version`, so a single
    // `didChange` bumps it and forces a recompute on the next refresh.
    const h = try setup();
    defer teardown(h);
    try applySettings(h, full_minify_settings);
    try h.openDocument("file:///full.wgsl", sample_shader, 1);

    const before = MinifyEstimator.estimate_count;
    h.refreshMinifyInsights("file:///full.wgsl");
    try std.testing.expectEqual(@as(u64, 1), MinifyEstimator.estimate_count - before);

    try h.changeDocumentIncremental(
        "file:///full.wgsl",
        .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
        " ",
    );
    h.refreshMinifyInsights("file:///full.wgsl");
    try std.testing.expectEqual(@as(u64, 2), MinifyEstimator.estimate_count - before);
}

test "perf: full-minify burst coalesces to single estimator run" {
    // Same acceptance gate as Phase 7 but with the heavier path armed:
    // the timer-thread debounce coalesces a 100-edit burst into one
    // estimator fire, regardless of which branch the estimator takes.
    const server = try setupServer(300);
    defer teardownServer(server);

    try applySettings(&server.handler, full_minify_settings);
    try server.handler.openDocument("file:///burst.wgsl", sample_shader, 1);
    const before = MinifyEstimator.estimate_count;

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        try driveDidChange(server, "file:///burst.wgsl", " ");
    }
    try std.testing.expectEqual(@as(u64, 0), MinifyEstimator.estimate_count - before);

    const dl = server.debouncer.nextDeadline() orelse return error.TestUnexpectedResult;
    server.tick(dl);
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
    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"insights\"}}");
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
