//! End-to-end tests for the pull-mode `textDocument/diagnostic`
//! response (LSP 3.17). Drives sources through
//! `bridge.buildPullReport` — the exact pipeline the native handler
//! calls — and `lsp.writeResponse`, then asserts on the serialized
//! JSON-RPC body the editor actually receives.
//!
//! Complements the push tests at `tests/lsp_publish_diagnostics_test.zig`.
//! Scenarios cover the pull-specific surface: Full vs Unchanged reports,
//! `resultId` monotonicity across edits, empty-report fallbacks for
//! unknown URIs and disabled diagnostics, and push/pull `items[]` parity
//! on the same source.

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");
const bridge = @import("bridge");
const wgslender = @import("wgslender");

const test_uri = "test://fixture.wgsl";

// =========================================================================
// Helpers
// =========================================================================

/// Captured JSON-RPC response body + the parsed result value. Uses a
/// single arena for every allocation so callers `deinit()` once.
const Captured = struct {
    arena: std.heap.ArenaAllocator,
    body: []const u8,
    root: std.json.Value,
    result: std.json.Value,

    fn deinit(self: *Captured) void {
        self.arena.deinit();
    }
};

/// Build the Report for `uri` using the production path and write it
/// via `lsp.writeResponse`. `previous_result_id` threads into the
/// Unchanged short-circuit — pass `null` for the first pull.
fn capturePull(
    handler: *Handler,
    uri: []const u8,
    previous_result_id: ?[]const u8,
) !Captured {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const report = try bridge.buildPullReport(handler, aa, uri, previous_result_id);

    var aw: std.Io.Writer.Allocating = .init(aa);
    try lsp.writeResponse(
        &aw.writer,
        aa,
        .{ .number = 1 },
        lsp.types.document_diagnostic.Report,
        report,
        .{ .emit_null_optional_fields = false },
    );

    const full = aw.written();
    const sep = "\r\n\r\n";
    const sep_idx = std.mem.indexOf(u8, full, sep) orelse return error.MalformedEnvelope;
    const body = full[sep_idx + sep.len ..];

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, aa, body, .{});
    const result = parsed.object.get("result") orelse return error.MissingResult;

    return .{ .arena = arena, .body = body, .root = parsed, .result = result };
}

/// Open `source` at `test_uri` and immediately pull — the common setup
/// for single-shot scenarios.
fn openAndPull(source: []const u8) !Captured {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    try handler.openDocument(test_uri, source, 1);
    return capturePull(&handler, test_uri, null);
}

fn getPath(obj: std.json.Value, path: []const u8) ?std.json.Value {
    var cur = obj;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |seg| {
        if (cur != .object) return null;
        cur = cur.object.get(seg) orelse return null;
    }
    return cur;
}

fn findItemByMessage(items: std.json.Value, needle: []const u8) ?std.json.Value {
    for (items.array.items) |d| {
        const msg = d.object.get("message") orelse continue;
        if (msg != .string) continue;
        if (std.mem.indexOf(u8, msg.string, needle) != null) return d;
    }
    return null;
}

// =========================================================================
// Scenario 1 — Full report happy path: kind, code, href, severity, range.
// =========================================================================

test "pull: const-init type mismatch produces Full report with code + href" {
    var cap = try openAndPull("const x: i32 = 1.5;");
    defer cap.deinit();

    try std.testing.expectEqualStrings("full", cap.result.object.get("kind").?.string);

    const items = cap.result.object.get("items").?;
    try std.testing.expect(items == .array);
    const d = findItemByMessage(items, "cannot initialize") orelse return error.DiagnosticNotFound;

    try std.testing.expectEqualStrings("E0200", d.object.get("code").?.string);
    try std.testing.expectEqualStrings(
        "https://www.w3.org/TR/WGSL/#types",
        getPath(d, "codeDescription.href").?.string,
    );
    try std.testing.expectEqualStrings("wgslender", d.object.get("source").?.string);
    try std.testing.expectEqual(@as(i64, 1), d.object.get("severity").?.integer);
    try std.testing.expectEqual(@as(i64, 0), getPath(d, "range.start.line").?.integer);
}

// =========================================================================
// Scenario 2 — resultId present on Full reports and stable across a no-op pull.
// =========================================================================

test "pull: Full report carries resultId and it is stable across repeat pulls" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    try handler.openDocument(test_uri, "const x: i32 = 1.5;", 1);

    var cap1 = try capturePull(&handler, test_uri, null);
    defer cap1.deinit();
    const id1 = cap1.result.object.get("resultId") orelse return error.MissingResultId;
    try std.testing.expect(id1 == .string);
    try std.testing.expect(id1.string.len > 0);

    // Second pull with no edits between — same revision key.
    var cap2 = try capturePull(&handler, test_uri, null);
    defer cap2.deinit();
    const id2 = cap2.result.object.get("resultId").?;
    try std.testing.expectEqualStrings(id1.string, id2.string);
}

// =========================================================================
// Scenario 3 — previousResultId match → Unchanged report (bandwidth save).
// =========================================================================

test "pull: matching previousResultId returns Unchanged" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    try handler.openDocument(test_uri, "const x: i32 = 1.5;", 1);

    var cap1 = try capturePull(&handler, test_uri, null);
    defer cap1.deinit();
    const id1 = cap1.result.object.get("resultId").?.string;

    // Dupe because cap1's arena dies before cap2 is built.
    const prev_id = try std.testing.allocator.dupe(u8, id1);
    defer std.testing.allocator.free(prev_id);

    var cap2 = try capturePull(&handler, test_uri, prev_id);
    defer cap2.deinit();

    try std.testing.expectEqualStrings("unchanged", cap2.result.object.get("kind").?.string);
    try std.testing.expectEqualStrings(prev_id, cap2.result.object.get("resultId").?.string);
    // Unchanged reports carry no `items` key — the client reuses its cache.
    try std.testing.expect(cap2.result.object.get("items") == null);
}

// =========================================================================
// Scenario 4 — edit invalidates resultId → client gets a fresh Full.
// =========================================================================

test "pull: stale previousResultId after incremental edit yields a new Full" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    try handler.openDocument(test_uri, "const x: i32 = 1.5;", 1);

    var cap1 = try capturePull(&handler, test_uri, null);
    defer cap1.deinit();
    const id1 = try std.testing.allocator.dupe(u8, cap1.result.object.get("resultId").?.string);
    defer std.testing.allocator.free(id1);

    // Semantic edit: flip `i32` → `f32` (the diagnostic disappears).
    try handler.changeDocumentIncremental(test_uri, .{
        .start = .{ .line = 0, .character = 9 },
        .end = .{ .line = 0, .character = 12 },
    }, "f32");

    var cap2 = try capturePull(&handler, test_uri, id1);
    defer cap2.deinit();

    try std.testing.expectEqualStrings("full", cap2.result.object.get("kind").?.string);
    const id2 = cap2.result.object.get("resultId").?.string;
    try std.testing.expect(!std.mem.eql(u8, id1, id2));
    // With the type fixed, the type-mismatch item should be gone.
    const items = cap2.result.object.get("items").?;
    try std.testing.expect(findItemByMessage(items, "cannot initialize") == null);
}

// =========================================================================
// Scenario 4b — a settings change invalidates the resultId.
//
// The result id must cover everything the report depends on, and lint
// output depends on configuration: after `applyClientConfig` a re-pull
// with the old id must yield a fresh Full, or the client keeps showing a
// rule the user just turned off. (This is exactly the VS Code flow:
// config change → workspace/diagnostic/refresh → client re-pulls with
// its cached previousResultId.)
// =========================================================================

test "pull: a settings change invalidates previousResultId" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    try handler.openDocument(
        test_uri,
        "@compute @workgroup_size(1) fn main() { let unused = 1.0; }",
        1,
    );

    var cap1 = try capturePull(&handler, test_uri, null);
    defer cap1.deinit();
    const id1 = try std.testing.allocator.dupe(u8, cap1.result.object.get("resultId").?.string);
    defer std.testing.allocator.free(id1);
    try std.testing.expect(findItemByMessage(cap1.result.object.get("items").?, "never used") != null);

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"rules\":{\"no-unused-vars\":\"off\"}}",
        .{},
    );
    defer parsed.deinit();
    handler.applyClientConfig(parsed.value);

    var cap2 = try capturePull(&handler, test_uri, id1);
    defer cap2.deinit();

    try std.testing.expectEqualStrings("full", cap2.result.object.get("kind").?.string);
    try std.testing.expect(findItemByMessage(cap2.result.object.get("items").?, "never used") == null);
}

// =========================================================================
// Scenario 5 — resultId survives a full-text replace (monotonicity).
// =========================================================================

test "pull: changeDocument full-replace keeps resultId monotonic" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    try handler.openDocument(test_uri, "const x: i32 = 1.5;", 1);

    var cap1 = try capturePull(&handler, test_uri, null);
    defer cap1.deinit();
    const id1 = try std.testing.allocator.dupe(u8, cap1.result.object.get("resultId").?.string);
    defer std.testing.allocator.free(id1);

    // Full-text replace — `rebuildParse` alone would reset module_version
    // to "0"; `changeDocument` must bump past the prior id.
    try handler.changeDocument(test_uri, "const y: i32 = 2.5;");

    var cap2 = try capturePull(&handler, test_uri, null);
    defer cap2.deinit();
    const id2 = cap2.result.object.get("resultId").?.string;
    try std.testing.expect(!std.mem.eql(u8, id1, id2));
}

// =========================================================================
// Scenario 6 — unknown URI returns empty Full (no crash, no hang).
// =========================================================================

test "pull: unknown URI returns empty Full report" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    var cap = try capturePull(&handler, "test://never-opened.wgsl", null);
    defer cap.deinit();

    try std.testing.expectEqualStrings("full", cap.result.object.get("kind").?.string);
    try std.testing.expectEqual(@as(usize, 0), cap.result.object.get("items").?.array.items.len);
    // Unknown URI has no parse → no resultId emitted.
    try std.testing.expect(cap.result.object.get("resultId") == null);
}

// =========================================================================
// Scenario 7 — diagnostics.enabled=false still answers (avoids client hang).
// =========================================================================

test "pull: diagnostics disabled yields empty Full, not silence" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    try handler.openDocument(test_uri, "const x: i32 = 1.5;", 1);
    handler.workspace_config.lsp_diagnostics_enabled = false;

    var cap = try capturePull(&handler, test_uri, null);
    defer cap.deinit();

    try std.testing.expectEqualStrings("full", cap.result.object.get("kind").?.string);
    try std.testing.expectEqual(@as(usize, 0), cap.result.object.get("items").?.array.items.len);
}

// =========================================================================
// Scenario 8 — push/pull parity: items[] match on the same source.
// =========================================================================

test "pull: items[] match publishDiagnostics items[] for the same source" {
    const source =
        \\struct Foo {
        \\  x: f32,
        \\  x: i32,
        \\}
    ;

    // Pull path.
    var pull = try openAndPull(source);
    defer pull.deinit();
    const pull_items = pull.result.object.get("items").?;

    // Push path — call the same validateDocumentFull + bridge and compare.
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    try handler.openDocument(test_uri, source, 1);

    const push_diags = try handler.validateDocumentFull(test_uri);
    defer Handler.freeDiagnostics(std.testing.allocator, push_diags);
    try std.testing.expectEqual(push_diags.len, pull_items.array.items.len);

    // Per-item: compare the fields editors actually key on.
    for (push_diags, 0..) |d, i| {
        const pulled = pull_items.array.items[i];
        try std.testing.expectEqualStrings(d.message, pulled.object.get("message").?.string);
        try std.testing.expectEqualStrings(d.code, pulled.object.get("code").?.string);
        try std.testing.expectEqual(@as(i64, @intFromEnum(d.severity)), pulled.object.get("severity").?.integer);
        try std.testing.expectEqual(
            @as(i64, @intCast(d.range.start.line)),
            getPath(pulled, "range.start.line").?.integer,
        );
    }
}

// =========================================================================
// Scenario 9 — relatedInformation survives the pull bridge.
// =========================================================================

test "pull: duplicate struct member carries relatedInformation in Full report" {
    const source =
        \\struct Foo {
        \\  x: f32,
        \\  x: i32,
        \\}
    ;
    var cap = try openAndPull(source);
    defer cap.deinit();

    const items = cap.result.object.get("items").?;
    const d = findItemByMessage(items, "duplicate member 'x'") orelse return error.DiagnosticNotFound;

    const related = d.object.get("relatedInformation") orelse return error.MissingRelatedInformation;
    try std.testing.expect(related.array.items.len >= 1);
    const ri = related.array.items[0];
    try std.testing.expectEqualStrings(test_uri, getPath(ri, "location.uri").?.string);
    try std.testing.expect(std.mem.indexOf(u8, ri.object.get("message").?.string, "first declared here") != null);
}

// =========================================================================
// Scenario 10 — capability advertisement (Handler.capabilities_json).
// =========================================================================

test "pull: capabilities_json advertises diagnosticProvider with expected shape" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), Handler.capabilities_json, .{});

    const provider = parsed.object.get("diagnosticProvider") orelse return error.MissingDiagnosticProvider;
    try std.testing.expect(provider == .object);

    try std.testing.expectEqual(false, provider.object.get("interFileDependencies").?.bool);
    try std.testing.expectEqual(false, provider.object.get("workspaceDiagnostics").?.bool);
}
