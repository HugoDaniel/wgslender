//! Bridge: `Handler.LspDiagnostic` ↔ `lsp.types.Diagnostic`.
//!
//! Reached as `lspkit.diagnostics.*` via `lsp/lspkit_root.zig`. The
//! native transport drives the outbound side from `publishDiagnostics` /
//! `textDocument/diagnostic` and the inbound side from
//! `textDocument/codeAction` (parsing `params.context.diagnostics[].data`
//! back into a `QuickFixHint`).
//!
//! Ownership variants are spelled out in their names — `Borrowed` shares
//! string slices with the input slice, `Owned` dupes them onto the caller
//! arena. Boolean flags are deliberately avoided so a typo can't flip
//! lifetime correctness silently.

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");
const wgslender = @import("wgslender");

const Diagnostic = wgslender.Diagnostic;

/// Owns the bridged `lsp.types.Diagnostic` slice plus every sub-slice
/// (relatedInformation, tags, data) allocated while translating from
/// `Handler.LspDiagnostic`. Uses an internal arena so callers free the
/// entire payload with a single `deinit()`.
pub const BridgedDiagnostics = struct {
    diagnostics: []lsp.types.Diagnostic,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *BridgedDiagnostics) void {
        self.arena.deinit();
    }
};

/// Translate Handler's transport-agnostic diagnostics into the lsp-kit
/// JSON-shaped representation. **Borrows** every `[]const u8` from
/// `handler_diags` (message, code, spec_url, related messages, and the
/// `QuickFixHint` payload strings). The caller must keep `handler_diags`
/// alive until the serialized JSON is written.
///
/// `uri` is attached as the `location.uri` of every relatedInformation
/// entry (WGSL diagnostics are always intra-document).
///
/// Fails only if the top-level diagnostics slice can't be allocated.
/// Sub-slice allocations degrade to `null` on OOM so the rest of the
/// diagnostic still reaches the client.
pub fn toLspKitDiagnosticsBorrowed(
    gpa: std.mem.Allocator,
    handler_diags: []const Handler.LspDiagnostic,
    uri: []const u8,
) !BridgedDiagnostics {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const diags = try aa.alloc(lsp.types.Diagnostic, handler_diags.len);

    for (handler_diags, 0..) |d, i| {
        var related_info: ?[]const lsp.types.Diagnostic.RelatedInformation = null;
        if (d.related.len > 0) {
            if (aa.alloc(lsp.types.Diagnostic.RelatedInformation, d.related.len)) |rel| {
                for (d.related, 0..) |rel_item, ri| {
                    rel[ri] = .{
                        .location = .{
                            .uri = uri,
                            .range = .{
                                .start = .{ .line = rel_item.range.start.line, .character = rel_item.range.start.character },
                                .end = .{ .line = rel_item.range.end.line, .character = rel_item.range.end.character },
                            },
                        },
                        .message = rel_item.message,
                    };
                }
                related_info = rel;
            } else |_| {}
        }

        var tags_slice: ?[]const lsp.types.Diagnostic.Tag = null;
        if (d.tags.len > 0) {
            if (aa.alloc(lsp.types.Diagnostic.Tag, d.tags.len)) |t| {
                for (d.tags, 0..) |tag, ti| t[ti] = switch (tag) {
                    .unnecessary => .Unnecessary,
                    .deprecated => .Deprecated,
                };
                tags_slice = t;
            } else |_| {}
        }

        diags[i] = .{
            .range = .{
                .start = .{ .line = d.range.start.line, .character = d.range.start.character },
                .end = .{ .line = d.range.end.line, .character = d.range.end.character },
            },
            .severity = switch (d.severity) {
                .@"error" => .Error,
                .warning => .Warning,
                .information => .Information,
                .hint => .Hint,
            },
            .code = if (d.code.len > 0) .{ .string = d.code } else null,
            .codeDescription = if (d.spec_url.len > 0) .{ .href = d.spec_url } else null,
            .source = "wgslender",
            .message = d.message,
            .tags = tags_slice,
            .relatedInformation = related_info,
            .data = quickFixHintToLspKitBorrowed(aa, d.data),
        };
    }

    return .{ .diagnostics = diags, .arena = arena };
}

/// Bridge variant for the pull-diagnostic handler. Allocates everything
/// (slice + per-item relatedInformation / tags + duplicated strings +
/// `data` payload) on the caller's arena. The pull handler returns the
/// `Diagnostic[]` by value to lsp-kit, which serializes after
/// `handler_diags` has been freed; the caller must keep the arena alive
/// until after the response is written (the per-request arena threaded
/// by `lsp.basic_server` satisfies this).
pub fn toLspKitDiagnosticsOwned(
    arena: std.mem.Allocator,
    handler_diags: []const Handler.LspDiagnostic,
    uri: []const u8,
) ![]lsp.types.Diagnostic {
    const diags = try arena.alloc(lsp.types.Diagnostic, handler_diags.len);
    const uri_dup = try arena.dupe(u8, uri);
    for (handler_diags, 0..) |d, i| {
        var related_info: ?[]const lsp.types.Diagnostic.RelatedInformation = null;
        if (d.related.len > 0) {
            if (arena.alloc(lsp.types.Diagnostic.RelatedInformation, d.related.len)) |rel| {
                for (d.related, 0..) |rel_item, ri| {
                    rel[ri] = .{
                        .location = .{
                            .uri = uri_dup,
                            .range = .{
                                .start = .{ .line = rel_item.range.start.line, .character = rel_item.range.start.character },
                                .end = .{ .line = rel_item.range.end.line, .character = rel_item.range.end.character },
                            },
                        },
                        .message = arena.dupe(u8, rel_item.message) catch "",
                    };
                }
                related_info = rel;
            } else |_| {}
        }

        var tags_slice: ?[]const lsp.types.Diagnostic.Tag = null;
        if (d.tags.len > 0) {
            if (arena.alloc(lsp.types.Diagnostic.Tag, d.tags.len)) |t| {
                for (d.tags, 0..) |tag, ti| t[ti] = switch (tag) {
                    .unnecessary => .Unnecessary,
                    .deprecated => .Deprecated,
                };
                tags_slice = t;
            } else |_| {}
        }

        diags[i] = .{
            .range = .{
                .start = .{ .line = d.range.start.line, .character = d.range.start.character },
                .end = .{ .line = d.range.end.line, .character = d.range.end.character },
            },
            .severity = switch (d.severity) {
                .@"error" => .Error,
                .warning => .Warning,
                .information => .Information,
                .hint => .Hint,
            },
            .code = if (d.code.len > 0) .{ .string = arena.dupe(u8, d.code) catch "" } else null,
            .codeDescription = if (d.spec_url.len > 0) .{ .href = arena.dupe(u8, d.spec_url) catch "" } else null,
            .source = "wgslender",
            .message = arena.dupe(u8, d.message) catch "",
            .tags = tags_slice,
            .relatedInformation = related_info,
            .data = quickFixHintToLspKitOwned(arena, d.data),
        };
    }
    return diags;
}

/// Pure pipeline behind the pull-mode `textDocument/diagnostic` handler.
/// Exposed here so tests drive the exact production path
/// (`producePullReport` → bridge) without spinning up a transport.
/// Allocations land on the caller's arena — shape-compatible with the
/// per-request arena `lsp.basic_server` threads through to the handler.
pub fn buildPullReport(
    h: *Handler,
    arena: std.mem.Allocator,
    uri: []const u8,
    previous_result_id: ?[]const u8,
) !lsp.types.document_diagnostic.Report {
    const report = try Handler.producePullReport(h, arena, uri, previous_result_id);
    switch (report) {
        .unchanged => |u| return .{
            .related_unchanged_document_diagnostic_report = .{
                .resultId = u.result_id,
                .relatedDocuments = null,
            },
        },
        .full => |f| {
            defer Handler.freeDiagnostics(h.gpa, @constCast(f.items));
            const items = try toLspKitDiagnosticsOwned(arena, f.items, uri);
            return .{
                .related_full_document_diagnostic_report = .{
                    .items = items,
                    .resultId = f.result_id,
                    .relatedDocuments = null,
                },
            };
        },
    }
}

// =========================================================================
// QuickFixHint ↔ lsp.types.LSPAny (`Diagnostic.data`)
// =========================================================================

/// Encode a `QuickFixHint` as the `Diagnostic.data` payload, borrowing
/// every string slice from `hint`. The returned `std.json.Value` (and its
/// owned ObjectMap) lives on `arena`. Returns `null` for `.none` so the
/// `data` field is omitted entirely on the wire.
pub fn quickFixHintToLspKitBorrowed(arena: std.mem.Allocator, hint: Diagnostic.QuickFixHint) ?std.json.Value {
    return buildHintValue(arena, hint, .borrow);
}

/// Encode a `QuickFixHint` as `Diagnostic.data`, duplicating every
/// string onto `arena`. Use when the response outlives the input.
pub fn quickFixHintToLspKitOwned(arena: std.mem.Allocator, hint: Diagnostic.QuickFixHint) ?std.json.Value {
    return buildHintValue(arena, hint, .own);
}

/// Inverse: parse the `data` payload back into a `QuickFixHint`. Strings
/// are borrowed from the parsed JSON tree, matching the inbound
/// code-action lifetime (the per-request arena outlives the dispatch).
/// Unknown / malformed shapes degrade to `.none`.
pub fn quickFixHintFromLspKit(val: ?std.json.Value) Diagnostic.QuickFixHint {
    const v = val orelse return .none;
    const obj = switch (v) {
        .object => |o| o,
        else => return .none,
    };
    const kind_val = obj.get("kind") orelse return .none;
    const kind = switch (kind_val) {
        .string => |s| s,
        else => return .none,
    };
    if (std.mem.eql(u8, kind, "didYouMean")) {
        const s = strField(obj, "suggestion") orelse return .none;
        return .{ .did_you_mean = s };
    }
    if (std.mem.eql(u8, kind, "typeMismatch")) {
        const a = strField(obj, "actual") orelse return .none;
        const e = strField(obj, "expected") orelse return .none;
        return .{ .type_mismatch = .{ .actual = a, .expected = e } };
    }
    if (std.mem.eql(u8, kind, "duplicateLocation")) {
        const n = intField(obj, "value") orelse return .none;
        const u: u32 = std.math.cast(u32, n) orelse return .none;
        return .{ .duplicate_location = u };
    }
    if (std.mem.eql(u8, kind, "unusedSymbol")) {
        const s = strField(obj, "name") orelse return .none;
        return .{ .unused_symbol = s };
    }
    if (std.mem.eql(u8, kind, "featureNotEnabled")) {
        const s = strField(obj, "feature") orelse return .none;
        return .{ .feature_not_enabled = s };
    }
    if (std.mem.eql(u8, kind, "vertexMissingBuiltinPosition")) return .vertex_missing_builtin_position;
    return .none;
}

const Ownership = enum { borrow, own };

fn buildHintValue(arena: std.mem.Allocator, hint: Diagnostic.QuickFixHint, ownership: Ownership) ?std.json.Value {
    const dup = struct {
        fn f(a: std.mem.Allocator, s: []const u8, o: Ownership) []const u8 {
            return switch (o) {
                .borrow => s,
                .own => a.dupe(u8, s) catch "",
            };
        }
    }.f;
    return switch (hint) {
        .none => null,
        .did_you_mean => |s| obj2(arena, "didYouMean", "suggestion", .{ .string = dup(arena, s, ownership) }),
        .type_mismatch => |tm| obj3(
            arena,
            "typeMismatch",
            "actual",
            .{ .string = dup(arena, tm.actual, ownership) },
            "expected",
            .{ .string = dup(arena, tm.expected, ownership) },
        ),
        .duplicate_location => |n| obj2(arena, "duplicateLocation", "value", .{ .integer = @intCast(n) }),
        .unused_symbol => |s| obj2(arena, "unusedSymbol", "name", .{ .string = dup(arena, s, ownership) }),
        .feature_not_enabled => |s| obj2(arena, "featureNotEnabled", "feature", .{ .string = dup(arena, s, ownership) }),
        .vertex_missing_builtin_position => obj1(arena, "vertexMissingBuiltinPosition"),
    };
}

fn obj1(arena: std.mem.Allocator, kind: []const u8) ?std.json.Value {
    var map: std.json.ObjectMap = .empty;
    map.put(arena, "kind", .{ .string = kind }) catch return null;
    return .{ .object = map };
}

fn obj2(arena: std.mem.Allocator, kind: []const u8, k1: []const u8, v1: std.json.Value) ?std.json.Value {
    var map: std.json.ObjectMap = .empty;
    map.put(arena, "kind", .{ .string = kind }) catch return null;
    map.put(arena, k1, v1) catch return null;
    return .{ .object = map };
}

fn obj3(
    arena: std.mem.Allocator,
    kind: []const u8,
    k1: []const u8,
    v1: std.json.Value,
    k2: []const u8,
    v2: std.json.Value,
) ?std.json.Value {
    var map: std.json.ObjectMap = .empty;
    map.put(arena, "kind", .{ .string = kind }) catch return null;
    map.put(arena, k1, v1) catch return null;
    map.put(arena, k2, v2) catch return null;
    return .{ .object = map };
}

fn strField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn intField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |n| n,
        else => null,
    };
}

// ==========================================================================
// Tests
// ==========================================================================

const testing = std.testing;

test "Diagnostic.data: did_you_mean round-trips through lsp-kit shape" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const v = quickFixHintToLspKitBorrowed(aa, .{ .did_you_mean = "position" }).?;
    try testing.expectEqualStrings("didYouMean", v.object.get("kind").?.string);
    try testing.expectEqualStrings("position", v.object.get("suggestion").?.string);

    const back = quickFixHintFromLspKit(v);
    switch (back) {
        .did_you_mean => |s| try testing.expectEqualStrings("position", s),
        else => return error.TestUnexpectedResult,
    }
}

test "Diagnostic.data: type_mismatch round-trips" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const v = quickFixHintToLspKitBorrowed(aa, .{ .type_mismatch = .{ .actual = "i32", .expected = "f32" } }).?;
    try testing.expectEqualStrings("typeMismatch", v.object.get("kind").?.string);
    try testing.expectEqualStrings("i32", v.object.get("actual").?.string);
    try testing.expectEqualStrings("f32", v.object.get("expected").?.string);

    const back = quickFixHintFromLspKit(v);
    switch (back) {
        .type_mismatch => |tm| {
            try testing.expectEqualStrings("i32", tm.actual);
            try testing.expectEqualStrings("f32", tm.expected);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "Diagnostic.data: duplicate_location round-trips" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const v = quickFixHintToLspKitBorrowed(aa, .{ .duplicate_location = 7 }).?;
    try testing.expectEqual(@as(i64, 7), v.object.get("value").?.integer);

    const back = quickFixHintFromLspKit(v);
    switch (back) {
        .duplicate_location => |n| try testing.expectEqual(@as(u32, 7), n),
        else => return error.TestUnexpectedResult,
    }
}

test "Diagnostic.data: vertex_missing_builtin_position is payloadless" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const v = quickFixHintToLspKitBorrowed(aa, .vertex_missing_builtin_position).?;
    try testing.expectEqualStrings("vertexMissingBuiltinPosition", v.object.get("kind").?.string);
    try testing.expect(v.object.get("value") == null);

    const back = quickFixHintFromLspKit(v);
    try testing.expectEqual(Diagnostic.QuickFixHint.vertex_missing_builtin_position, back);
}

test "Diagnostic.data: .none is null (field omitted entirely)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    try testing.expect(quickFixHintToLspKitBorrowed(aa, .none) == null);
    try testing.expectEqual(Diagnostic.QuickFixHint.none, quickFixHintFromLspKit(null));
}

test "Diagnostic.data: Owned variant outlives the input" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var msg_buf: [16]u8 = undefined;
    @memcpy(msg_buf[0..4], "len4");
    const v = quickFixHintToLspKitOwned(aa, .{ .did_you_mean = msg_buf[0..4] }).?;
    @memcpy(msg_buf[0..4], "XXXX");
    try testing.expectEqualStrings("len4", v.object.get("suggestion").?.string);
}
