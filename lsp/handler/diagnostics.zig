//! Diagnostics: run wgslender validation and convert results into the
//! LSP-compatible diagnostic shape. This module owns the validate*
//! entry points (`validateDocument`, `validateDocumentFull`,
//! `validateDocumentCheap`), the diagnostic conversion helper, and
//! `freeDiagnostics`.

const std = @import("std");
const wgslender = @import("wgslender");

const Handler = @import("../Handler.zig");
const LspDiagnostic = Handler.LspDiagnostic;
const LspRelatedInfo = Handler.LspRelatedInfo;
const Range = Handler.Range;
const WgslDiagnostic = wgslender.Diagnostic;
const MinifySettings = wgslender.MinifySettings;
const MinifyEstimator = wgslender.MinifyEstimator;

/// Run wgslender validation and return LSP diagnostics.
/// Caller owns the returned slice — free with the same allocator.
pub fn validateDocument(handler: *Handler, source: []const u8) ![]LspDiagnostic {
    const source_z = try handler.gpa.dupeZ(u8, source);
    defer handler.gpa.free(source_z);

    var result = try wgslender.validateWithOptions(handler.gpa, source_z, .{});
    defer result.deinit();

    const entries = result.diagnostics.diagnostics.items;
    const diags = try handler.gpa.alloc(LspDiagnostic, entries.len);

    for (entries, 0..) |entry, i| {
        diags[i] = convertDiagnostic(handler.gpa, source_z, &entry);
    }

    return diags;
}

/// Validate a document using the analysis cache and append unused symbol warnings.
/// This is used by publishDiagnostics to produce a complete diagnostic set.
/// Phase 7: when the doc's effective minifier-mode requires lint output,
/// the cached `MinifyEstimator.EstimateResult` is threaded into the
/// linter so M0500 (and any future M-rule) shares the per-document
/// cache instead of re-running the estimator from scratch.
pub fn validateDocumentFull(handler: *Handler, uri: []const u8) ![]LspDiagnostic {
    return validateDocumentInner(handler, uri, .{ .include_minify_lints = true });
}

/// Phase 7 cheap path: validator + unused/dead-code warnings, without
/// the M-rule lint block. The push-on-`didChange` path on both transports
/// uses this so a 100-keystroke burst never enters the (potentially
/// estimator-heavy) minify lint pipeline. The full path runs from the
/// debounce timer (native) or the `wgslender/recomputeMinifyInsights`
/// notification (WASM), each call warming the cache exactly once.
pub fn validateDocumentCheap(handler: *Handler, uri: []const u8) ![]LspDiagnostic {
    return validateDocumentInner(handler, uri, .{ .include_minify_lints = false });
}

/// Outcome of the pull-mode `textDocument/diagnostic` decision tree.
/// Both transports share the same logic; only the wire encoding differs.
///
/// Ownership:
///   - `full.items` is allocated by `handler.gpa` (free with
///     `Handler.freeDiagnostics`). The disabled / unknown-URI fallbacks set
///     it to the empty literal `&.{}` — `freeDiagnostics` short-circuits on
///     zero-length input, so callers may free unconditionally.
///   - `result_id` (in either arm) is allocated on the `allocator` passed
///     to `producePullReport`. Native passes a per-request arena (freed
///     wholesale), so no explicit free is needed; WASM passes a long-lived
///     allocator and must free explicitly.
pub const PullReport = union(enum) {
    full: struct {
        items: []const LspDiagnostic,
        result_id: ?[]const u8,
    },
    unchanged: struct {
        result_id: []const u8,
    },
};

/// Pure pipeline behind the pull-mode `textDocument/diagnostic` handler.
/// Encapsulates the four behaviors both transports must implement
/// identically: settings gate (`diagnosticsEnabled`), document existence,
/// `currentResultId` short-circuit (Unchanged), and full revalidation.
///
/// The disabled, unknown-URI, and "no parse yet" branches all collapse to
/// `.full{ .items = &.{}, .result_id = null }` — pull clients hang on
/// silence, so an empty Full is the safe default. There is intentionally
/// no `.empty` arm: it would conflate "empty full report" (a real LSP
/// shape) with "no response" (a transport policy).
pub fn producePullReport(
    handler: *Handler,
    allocator: std.mem.Allocator,
    uri: []const u8,
    previous_result_id: ?[]const u8,
) !PullReport {
    if (!handler.diagnosticsEnabled()) return .{ .full = .{ .items = &.{}, .result_id = null } };
    if (handler.getDocumentSource(uri) == null) return .{ .full = .{ .items = &.{}, .result_id = null } };

    const current_id: ?[]const u8 = if (handler.currentResultId(uri)) |v|
        try std.fmt.allocPrint(allocator, "{d}", .{v})
    else
        null;
    errdefer if (current_id) |c| allocator.free(c);

    if (current_id) |cur| if (previous_result_id) |prev|
        if (std.mem.eql(u8, prev, cur)) return .{ .unchanged = .{ .result_id = cur } };

    const items = try validateDocumentFull(handler, uri);
    return .{ .full = .{ .items = items, .result_id = current_id } };
}

const ValidateOptions = struct {
    include_minify_lints: bool,
};

fn validateDocumentInner(handler: *Handler, uri: []const u8, options: ValidateOptions) ![]LspDiagnostic {
    const analysis = try handler.analyzeDocument(uri);
    const source: []const u8 = if (analysis.module) |m| m.source else handler.getDocumentSource(uri) orelse "";

    const entries = analysis.diagnostics.diagnostics.items;
    var diags: std.ArrayList(LspDiagnostic) = .empty;
    errdefer {
        for (diags.items) |d| freeSingleDiagnostic(handler.gpa, d);
        diags.deinit(handler.gpa);
    }

    try diags.ensureTotalCapacity(handler.gpa, entries.len + 8);
    for (entries) |entry| {
        try diags.append(handler.gpa, convertDiagnostic(handler.gpa, source, &entry));
    }

    // Append unused symbol warnings, dead code warnings, and unused binding warnings
    Handler.appendUnusedWarnings(handler.gpa, analysis, &diags);
    Handler.appendDeadCodeWarnings(handler.gpa, analysis, &diags);
    Handler.appendUnusedBindingWarnings(handler.gpa, analysis, &diags);

    // Phase 5a — when the document's effective minifier-mode escalates to
    // strict (workspace setting or per-document magic comment), surface the
    // `@wgslender/minify` lint pack alongside the validator's diagnostics.
    // The Linter owns its own arena; `convertDiagnostic` dupes every
    // borrowed slice into the handler's allocator, so the arena teardown
    // immediately after the loop is safe.
    const eff_minify = handler.effectiveMinifyFor(uri);
    if (options.include_minify_lints and eff_minify.lintsActive()) {
        var minify_arena = std.heap.ArenaAllocator.init(handler.gpa);
        defer minify_arena.deinit();
        const overrides = try buildMinifyRuleOverrides(
            handler,
            minify_arena.allocator(),
            eff_minify,
            handler.mangleExternalBindings(),
        );

        // Phase 7 cache hand-off: warm the per-document estimator cache
        // once and let M-rules read the same pointer. `getMinifyEstimate`
        // returns null on parse-failure paths; in that case the rule
        // falls back to its own estimate (matching CLI lint behaviour).
        const cached_estimate: ?*const MinifyEstimator.EstimateResult =
            handler.getMinifyEstimate(uri, handler.estimatorOptionsFor(uri)) catch null;

        var lint_result = try wgslender.Linter.run(handler.gpa, analysis, .{
            .extends = &.{"@wgslender/minify"},
            .rules = overrides,
            .cached_minify_estimate = cached_estimate,
        });
        defer lint_result.deinit(handler.gpa);
        for (lint_result.diagnostics.items()) |entry| {
            try diags.append(handler.gpa, convertDiagnostic(handler.gpa, source, &entry));
        }
    }

    return try diags.toOwnedSlice(handler.gpa);
}

/// Build per-rule overrides synthesising fields from the resolved
/// `MinifySettings.Effective`, the standalone `mangleExternalBindings`
/// knob, and the merged `rules` overrides from every Config layer into
/// the Linter's `Options.rules` slice.
///
/// Two contributions, merged per rule id:
///   1. `rules` (id → severity) — escalates or silences any registered
///      rule by id. Both project (`wgslender.json`) and workspace
///      (LSP `workspace/configuration`) layers contribute; workspace
///      wins on duplicate id (see `Handler.appendLintRuleOverrides`).
///   2. The M0100 mangle gate — when the user has opted into
///      `mangleExternalBindings = true`, attach
///      `{"mangleExternalBindings": true}` to that rule's options so
///      the rule no-ops. Same value the local minifier reads, so editor
///      hint and CLI output never disagree.
///
/// When both apply to M0100, severity is taken from (1) and options are
/// taken from (2). The Linter consumes a flat list, so we accumulate
/// per-rule first and emit the merged entries last.
fn buildMinifyRuleOverrides(
    handler: *const Handler,
    arena: std.mem.Allocator,
    eff: MinifySettings.Effective,
    mangle_external_bindings: bool,
) ![]wgslender.Linter.Options.RuleOverride {
    const Acc = struct {
        id: []const u8,
        severity: ?WgslDiagnostic.Severity = null,
        options: ?std.json.Value = null,
    };
    var by_id: std.StringHashMapUnmanaged(Acc) = .empty;

    // Severities (project + workspace, workspace wins on duplicate id).
    var sev_map: std.StringHashMapUnmanaged(WgslDiagnostic.Severity) = .empty;
    try handler.appendLintRuleOverrides(arena, &sev_map);
    var sev_it = sev_map.iterator();
    while (sev_it.next()) |kv| {
        const gop = try by_id.getOrPut(arena, kv.key_ptr.*);
        if (!gop.found_existing) gop.value_ptr.* = .{ .id = kv.key_ptr.* };
        gop.value_ptr.severity = kv.value_ptr.*;
    }

    // M0100 mangleExternalBindings gate.
    if (mangle_external_bindings) {
        const m0100_id: []const u8 = "minify/external-binding-blocks-rename";
        var obj: std.json.ObjectMap = .empty;
        try obj.put(arena, "mangleExternalBindings", .{ .bool = true });
        const gop = try by_id.getOrPut(arena, m0100_id);
        if (!gop.found_existing) gop.value_ptr.* = .{ .id = m0100_id };
        gop.value_ptr.options = .{ .object = obj };
    }

    // M0500 maxBytes gate. JSON integers are i64, so widen `u32`
    // through that signed path before stamping the option value.
    if (eff.budget_bytes) |budget| {
        const m0500_id: []const u8 = "minify/shader-exceeds-size-budget";
        var obj: std.json.ObjectMap = .empty;
        try obj.put(arena, "maxBytes", .{ .integer = @as(i64, budget) });
        const gop = try by_id.getOrPut(arena, m0500_id);
        if (!gop.found_existing) gop.value_ptr.* = .{ .id = m0500_id };
        gop.value_ptr.options = .{ .object = obj };
    }

    var overrides: std.ArrayList(wgslender.Linter.Options.RuleOverride) = .empty;
    var it = by_id.iterator();
    while (it.next()) |kv| {
        const acc = kv.value_ptr.*;
        // No severity override → preserve the pack's default by
        // restating the rule's `default_severity`. The Linter applies
        // `extends` first and overrides last, so a no-severity merge
        // here would otherwise force a recompute. We pull the default
        // off the registry to avoid hard-coding `.hint`.
        const sev = acc.severity orelse blk: {
            const r = wgslender.Linter.registry.byId(acc.id) orelse break :blk WgslDiagnostic.Severity.hint;
            break :blk r.meta.default_severity;
        };
        try overrides.append(arena, .{
            .id = acc.id,
            .severity = sev,
            .options = acc.options,
        });
    }
    return overrides.toOwnedSlice(arena);
}

fn freeSingleDiagnostic(gpa: std.mem.Allocator, d: LspDiagnostic) void {
    if (d.message.len > 0) gpa.free(d.message);
    if (d.spec_url.len > 0) gpa.free(d.spec_url);
    if (d.related.len > 0) {
        for (d.related) |r| {
            if (r.message.len > 0) gpa.free(r.message);
        }
        gpa.free(d.related);
    }
    freeQuickFixHint(gpa, d.data);
}

fn freeQuickFixHint(gpa: std.mem.Allocator, data: WgslDiagnostic.QuickFixHint) void {
    switch (data) {
        .none, .duplicate_location, .vertex_missing_builtin_position => {},
        .did_you_mean, .unused_symbol, .feature_not_enabled => |s| {
            if (s.len > 0) gpa.free(s);
        },
        .type_mismatch => |tm| {
            if (tm.actual.len > 0) gpa.free(tm.actual);
            if (tm.expected.len > 0) gpa.free(tm.expected);
        },
    }
}

fn dupeQuickFixHint(gpa: std.mem.Allocator, data: WgslDiagnostic.QuickFixHint) WgslDiagnostic.QuickFixHint {
    return switch (data) {
        .none, .duplicate_location, .vertex_missing_builtin_position => data,
        .did_you_mean => |s| .{ .did_you_mean = gpa.dupe(u8, s) catch "" },
        .unused_symbol => |s| .{ .unused_symbol = gpa.dupe(u8, s) catch "" },
        .feature_not_enabled => |s| .{ .feature_not_enabled = gpa.dupe(u8, s) catch "" },
        .type_mismatch => |tm| .{ .type_mismatch = .{
            .actual = gpa.dupe(u8, tm.actual) catch "",
            .expected = gpa.dupe(u8, tm.expected) catch "",
        } },
    };
}

const wgsl_spec_base = "https://www.w3.org/TR/WGSL/#";

/// Convert a wgslender `Diagnostic.Entry` (1-based line/column, byte
/// `offset` field) to an LSP `Diagnostic` (0-based line, UTF-16 code-unit
/// `character`). The `source` argument is the document the diagnostic was
/// produced against — used by `offsetRangeToLspRange` to count UTF-16
/// units across multi-byte UTF-8 sequences. Falls back to a zero-range
/// if either offset doesn't resolve, which preserves graceful degradation
/// for malformed entries (in practice every Validator/Linter site sets a
/// valid `offset`).
pub fn convertDiagnostic(
    gpa: std.mem.Allocator,
    source: []const u8,
    entry: *const WgslDiagnostic.Entry,
) LspDiagnostic {
    const zero_range: Range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } };
    var related: []const LspRelatedInfo = &.{};
    if (entry.related.len > 0) {
        if (gpa.alloc(LspRelatedInfo, entry.related.len)) |rel| {
            for (entry.related, 0..) |r, ri| {
                rel[ri] = .{
                    .range = Handler.offsetRangeToLspRange(source, r.range.start.offset, r.range.end.offset) orelse zero_range,
                    .message = gpa.dupe(u8, r.message) catch "",
                };
            }
            related = rel;
        } else |_| {}
    }
    return .{
        .range = Handler.offsetRangeToLspRange(source, entry.range.start.offset, entry.range.end.offset) orelse zero_range,
        .severity = switch (entry.severity) {
            .@"error" => .@"error",
            .warning => .warning,
            .hint => .hint,
            .note => .information,
            else => .information,
        },
        .message = gpa.dupe(u8, entry.message) catch "",
        .code = entry.code,
        .spec_url = if (entry.code.len > 0 and entry.spec_ref.len > 0) blk: {
            const url = gpa.alloc(u8, wgsl_spec_base.len + entry.spec_ref.len) catch break :blk "";
            @memcpy(url[0..wgsl_spec_base.len], wgsl_spec_base);
            @memcpy(url[wgsl_spec_base.len..], entry.spec_ref);
            break :blk url;
        } else "",
        .related = related,
        .data = dupeQuickFixHint(gpa, entry.data),
    };
}

/// Frees all allocations within a diagnostics slice (messages, related info, the slice itself).
pub fn freeDiagnostics(gpa: std.mem.Allocator, diags: []LspDiagnostic) void {
    for (diags) |d| {
        if (d.related.len > 0) {
            for (d.related) |r| {
                if (r.message.len > 0) gpa.free(r.message);
            }
            gpa.free(d.related);
        }
        if (d.message.len > 0) gpa.free(d.message);
        if (d.spec_url.len > 0) gpa.free(d.spec_url);
        freeQuickFixHint(gpa, d.data);
    }
    gpa.free(diags);
}

test "convertDiagnostic preserves code" {
    const entry = WgslDiagnostic.Entry{ .code = "E0200" };
    const result = convertDiagnostic(std.testing.allocator, "", &entry);
    try std.testing.expectEqualStrings("E0200", result.code);
}

test "convertDiagnostic builds spec_url from spec_ref" {
    const entry = WgslDiagnostic.Entry{ .code = "E0700", .spec_ref = "uniformity" };
    const result = convertDiagnostic(std.testing.allocator, "", &entry);
    defer std.testing.allocator.free(result.spec_url);
    try std.testing.expectEqualStrings("https://www.w3.org/TR/WGSL/#uniformity", result.spec_url);
}

test "convertDiagnostic omits code and spec_url when empty" {
    const entry = WgslDiagnostic.Entry{};
    const result = convertDiagnostic(std.testing.allocator, "", &entry);
    try std.testing.expectEqual(@as(usize, 0), result.code.len);
    try std.testing.expectEqual(@as(usize, 0), result.spec_url.len);
}

test "convertDiagnostic omits spec_url when code empty" {
    const entry = WgslDiagnostic.Entry{ .spec_ref = "uniformity" };
    const result = convertDiagnostic(std.testing.allocator, "", &entry);
    try std.testing.expectEqual(@as(usize, 0), result.spec_url.len);
}

test "code round-trips through validateDocument" {
    // A type mismatch triggers a diagnostic with code "E0200".
    const source =
        \\const x: i32 = 1.5;
    ;
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = try validateDocument(&handler, source);
    defer freeDiagnostics(std.testing.allocator, diags);

    // Find a diagnostic with a code
    for (diags) |d| {
        if (d.code.len > 0) {
            try std.testing.expect(std.mem.startsWith(u8, d.code, "E"));
            return;
        }
    }
    std.debug.print("\nExpected a diagnostic with a code, got {d} diagnostics:\n", .{diags.len});
    for (diags) |d| {
        std.debug.print("  [{s}] {s}\n", .{ d.code, d.message });
    }
    return error.TestUnexpectedResult;
}

test "spec_url round-trips through validateDocument" {
    // workgroupBarrier inside a branch on a non-uniform builtin triggers
    // a uniformity error with code (E0701) and spec_ref ("uniformity").
    const source =
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) global_invocation_id: vec3<u32>) {
        \\  if (global_invocation_id.x > 0) {
        \\    workgroupBarrier();
        \\  }
        \\}
    ;
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = try validateDocument(&handler, source);
    defer freeDiagnostics(std.testing.allocator, diags);

    for (diags) |d| {
        if (d.spec_url.len > 0) {
            try std.testing.expectEqualStrings("https://www.w3.org/TR/WGSL/#uniformity", d.spec_url);
            try std.testing.expect(d.code.len > 0);
            return;
        }
    }
    std.debug.print("\nExpected a diagnostic with spec_url, got {d} diagnostics:\n", .{diags.len});
    for (diags) |d| {
        std.debug.print("  [{s}] {s}\n", .{ d.code, d.message });
    }
    return error.TestUnexpectedResult;
}

// =========================================================================
// producePullReport — drive the pull-mode decision tree directly.
// =========================================================================

const test_pull_uri = "test://pull.wgsl";

fn freeReportForTest(gpa: std.mem.Allocator, arena: std.mem.Allocator, report: PullReport) void {
    switch (report) {
        .unchanged => |u| arena.free(u.result_id),
        .full => |f| {
            freeDiagnostics(gpa, @constCast(f.items));
            if (f.result_id) |r| arena.free(r);
        },
    }
}

test "producePullReport: unknown URI yields empty Full with null result_id" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const report = try producePullReport(&handler, std.testing.allocator, "test://never-opened.wgsl", null);
    defer freeReportForTest(std.testing.allocator, std.testing.allocator, report);

    switch (report) {
        .full => |f| {
            try std.testing.expectEqual(@as(usize, 0), f.items.len);
            try std.testing.expect(f.result_id == null);
        },
        .unchanged => return error.TestUnexpectedResult,
    }
}

test "producePullReport: diagnostics disabled yields empty Full with null result_id" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    try handler.openDocument(test_pull_uri, "const x: i32 = 1.5;", 1);
    handler.workspace_config.lsp_diagnostics_enabled = false;

    const report = try producePullReport(&handler, std.testing.allocator, test_pull_uri, null);
    defer freeReportForTest(std.testing.allocator, std.testing.allocator, report);

    switch (report) {
        .full => |f| {
            try std.testing.expectEqual(@as(usize, 0), f.items.len);
            try std.testing.expect(f.result_id == null);
        },
        .unchanged => return error.TestUnexpectedResult,
    }
}

test "producePullReport: clean source yields empty-items Full with result_id" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    try handler.openDocument(
        test_pull_uri,
        "@compute @workgroup_size(1) fn main() {}",
        1,
    );

    const report = try producePullReport(&handler, std.testing.allocator, test_pull_uri, null);
    defer freeReportForTest(std.testing.allocator, std.testing.allocator, report);

    switch (report) {
        .full => |f| {
            try std.testing.expectEqual(@as(usize, 0), f.items.len);
            try std.testing.expect(f.result_id != null);
            try std.testing.expect(f.result_id.?.len > 0);
        },
        .unchanged => return error.TestUnexpectedResult,
    }
}

test "producePullReport: type-mismatch source yields populated Full with result_id" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    try handler.openDocument(test_pull_uri, "const x: i32 = 1.5;", 1);

    const report = try producePullReport(&handler, std.testing.allocator, test_pull_uri, null);
    defer freeReportForTest(std.testing.allocator, std.testing.allocator, report);

    switch (report) {
        .full => |f| {
            try std.testing.expect(f.items.len > 0);
            try std.testing.expect(f.result_id != null);
        },
        .unchanged => return error.TestUnexpectedResult,
    }
}

test "producePullReport: matching previousResultId yields Unchanged" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    try handler.openDocument(test_pull_uri, "const x: i32 = 1.5;", 1);

    const first = try producePullReport(&handler, std.testing.allocator, test_pull_uri, null);
    const first_id = switch (first) {
        .full => |f| try std.testing.allocator.dupe(u8, f.result_id orelse return error.TestUnexpectedResult),
        .unchanged => return error.TestUnexpectedResult,
    };
    freeReportForTest(std.testing.allocator, std.testing.allocator, first);
    defer std.testing.allocator.free(first_id);

    const second = try producePullReport(&handler, std.testing.allocator, test_pull_uri, first_id);
    defer freeReportForTest(std.testing.allocator, std.testing.allocator, second);

    switch (second) {
        .unchanged => |u| try std.testing.expectEqualStrings(first_id, u.result_id),
        .full => return error.TestUnexpectedResult,
    }
}
