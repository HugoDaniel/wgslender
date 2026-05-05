//! JSON serialization for `Handler.LspDiagnostic[]`.
//!
//! Shared between the WASM push path (`publishDiagnostics` notification)
//! and the WASM pull path (`textDocument/diagnostic` Full report). Both
//! need the same `items[]` byte-for-byte; only the envelope differs.
//!
//! The native transport does not need this helper — lsp-kit's type-driven
//! writer handles serialization from `lsp.types.Diagnostic`.

const std = @import("std");
const Handler = @import("Handler");
const wgslender = @import("wgslender");

const Diagnostic = wgslender.Diagnostic;

/// Append the `[{…}, …]` diagnostic array to `buf`. Writes the enclosing
/// brackets. `uri` is attached as `relatedInformation[].location.uri`
/// (WGSL diagnostics are always intra-document).
///
/// OOM during sub-field allocation (escape scratch buffers) is swallowed
/// per-field — the rest of the diagnostic still reaches the client. The
/// only surfaceable error is OOM on the outer buf writes, which callers
/// already ignore in the WASM transport.
pub fn appendDiagnosticItems(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    uri: []const u8,
    diags: []const Handler.LspDiagnostic,
) void {
    buf.append(allocator, '[') catch return;
    for (diags, 0..) |diag, i| {
        if (i > 0) buf.append(allocator, ',') catch {};
        appendOne(buf, allocator, uri, diag);
    }
    buf.append(allocator, ']') catch return;
}

/// Inverse of `appendDiagnosticItems`: parse an array of LSP diagnostic
/// JSON objects into `Handler.LspDiagnostic`s. Used by the WASM transport's
/// code-action path, which receives diagnostics from the client in
/// `params.context.diagnostics`. String fields are borrowed from the parsed
/// JSON — the caller must keep the parse result alive while the returned
/// slice is in use.
///
/// Returns `null` only on top-level OOM. Missing fields fall back to safe
/// zero defaults so a malformed entry can't poison neighbouring slots.
pub fn parseDiagnosticItems(
    allocator: std.mem.Allocator,
    diag_array: []std.json.Value,
) ?[]Handler.LspDiagnostic {
    const handler_diags = allocator.alloc(Handler.LspDiagnostic, diag_array.len) catch return null;
    for (diag_array, 0..) |*diag_val, i| {
        const range_val = objGet(diag_val, "range");
        const start_obj = if (range_val) |r| objGet(r, "start") else null;
        const end_obj = if (range_val) |r| objGet(r, "end") else null;

        const start_line: u32 = if (intVal(if (start_obj) |s| objGet(s, "line") else null)) |v| @intCast(v) else 0;
        const start_char: u32 = if (intVal(if (start_obj) |s| objGet(s, "character") else null)) |v| @intCast(v) else 0;
        const end_line: u32 = if (intVal(if (end_obj) |e| objGet(e, "line") else null)) |v| @intCast(v) else 0;
        const end_char: u32 = if (intVal(if (end_obj) |e| objGet(e, "character") else null)) |v| @intCast(v) else 0;

        const sev_int: i64 = intVal(objGet(diag_val, "severity")) orelse 1;
        handler_diags[i] = .{
            .range = .{
                .start = .{ .line = start_line, .character = start_char },
                .end = .{ .line = end_line, .character = end_char },
            },
            .severity = switch (sev_int) {
                1 => .@"error",
                2 => .warning,
                3 => .information,
                4 => .hint,
                else => .information,
            },
            .message = strVal(objGet(diag_val, "message")) orelse "",
            .code = strVal(objGet(diag_val, "code")) orelse "",
            .data = parseData(objGet(diag_val, "data")),
        };
    }
    return handler_diags;
}

// =========================================================================
// Push-mode emit + pull-mode handler
// =========================================================================

/// Mutable handles a WASM-feature module needs to publish a notification
/// or send a response back through the outbox.
pub const Ctx = struct {
    gpa: std.mem.Allocator,
    handler: *Handler,
    outbox: *std.ArrayListUnmanaged([]u8),

    fn enqueue(self: Ctx, msg: []u8) void {
        self.outbox.append(self.gpa, msg) catch self.gpa.free(msg);
    }
};

/// Full-path emit: validator + minify lint pack. Used by didOpen, didSave,
/// and `wgslender/recomputeMinifyInsights` — every path where the user
/// expects M-rule diagnostics on the next paint.
pub fn emitDiagnostics(ctx: Ctx, uri: []const u8) void {
    emitDiagnosticsImpl(ctx, uri, true);
}

/// Cheap-path emit: validator + unused-symbol warnings only. Used by the
/// `didChange` hot loop so a 100-keystroke burst doesn't run the estimator
/// every frame. JS clients schedule a `recomputeMinifyInsights`
/// notification on idle (~300 ms) to surface M-rule diagnostics.
pub fn emitDiagnosticsCheap(ctx: Ctx, uri: []const u8) void {
    emitDiagnosticsImpl(ctx, uri, false);
}

fn emitDiagnosticsImpl(ctx: Ctx, uri: []const u8, include_minify_lints: bool) void {
    if (!ctx.handler.diagnosticsEnabled()) return;
    const diags = if (include_minify_lints)
        ctx.handler.validateDocumentFull(uri) catch return
    else
        ctx.handler.validateDocumentCheap(uri) catch return;
    defer Handler.freeDiagnostics(ctx.handler.gpa, diags);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(&buf, ctx.gpa, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"");
    Diagnostic.appendJsonEscaped(&buf, ctx.gpa, uri) catch return;
    appendStr(&buf, ctx.gpa, "\",\"diagnostics\":");
    appendDiagnosticItems(&buf, ctx.gpa, uri, diags);
    appendStr(&buf, ctx.gpa, "}}");
    ctx.enqueue(buf.toOwnedSlice(ctx.gpa) catch return);
}

/// Pull-model diagnostics (LSP 3.17 `textDocument/diagnostic`). Returns a
/// Full report (or Unchanged when `previousResultId` matches the current
/// revision key). Unknown URIs and `diagnostics.enabled=false` both answer
/// with an empty Full report — pull clients wait for a response, so
/// silence would hang the UI.
///
/// The settings/document/short-circuit decision tree lives in
/// `Handler.producePullReport`; this function only handles transport-level
/// param parsing, the empty-Full fallback on internal errors, and JSON
/// framing of the result envelope.
pub fn handlePullDiagnostic(
    ctx: Ctx,
    sendResult: *const fn (id: ?std.json.Value, result_json: []const u8) void,
    root: std.json.ObjectMap,
    id: ?std.json.Value,
) void {
    if (id == null) return;
    const empty_full = "{\"kind\":\"full\",\"items\":[]}";
    const params = root.getPtr("params") orelse return sendResult(id, empty_full);
    const td = objGet(params, "textDocument") orelse return sendResult(id, empty_full);
    const uri = strVal(objGet(td, "uri")) orelse return sendResult(id, empty_full);
    const prev = strVal(objGet(params, "previousResultId"));

    const report = Handler.producePullReport(ctx.handler, ctx.gpa, uri, prev) catch
        return sendResult(id, empty_full);
    defer switch (report) {
        .unchanged => |u| ctx.gpa.free(u.result_id),
        .full => |f| {
            Handler.freeDiagnostics(ctx.handler.gpa, @constCast(f.items));
            if (f.result_id) |r| ctx.gpa.free(r);
        },
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    switch (report) {
        .unchanged => |u| {
            appendStr(&buf, ctx.gpa, "{\"kind\":\"unchanged\",\"resultId\":\"");
            appendStr(&buf, ctx.gpa, u.result_id);
            appendStr(&buf, ctx.gpa, "\"}");
        },
        .full => |f| {
            appendStr(&buf, ctx.gpa, "{\"kind\":\"full\"");
            if (f.result_id) |cur| {
                appendStr(&buf, ctx.gpa, ",\"resultId\":\"");
                appendStr(&buf, ctx.gpa, cur);
                appendStr(&buf, ctx.gpa, "\"");
            }
            appendStr(&buf, ctx.gpa, ",\"items\":");
            appendDiagnosticItems(&buf, ctx.gpa, uri, f.items);
            appendStr(&buf, ctx.gpa, "}");
        },
    }
    const body = buf.toOwnedSlice(ctx.gpa) catch return;
    defer ctx.gpa.free(body);
    sendResult(id, body);
}

/// Parse the `data` payload back into a `QuickFixHint`. Strings are
/// borrowed from the parsed JSON tree (matching how `parseDiagnosticItems`
/// handles `message` / `code`), so the caller must keep the parsed tree
/// alive while the returned hint is in use. Unknown / malformed shapes
/// degrade to `.none` rather than failing the whole code-action request.
fn parseData(val: ?*const std.json.Value) Diagnostic.QuickFixHint {
    const v = val orelse return .none;
    const obj = switch (v.*) {
        .object => |o| o,
        else => return .none,
    };
    const kind_val = obj.getPtr("kind") orelse return .none;
    const kind = switch (kind_val.*) {
        .string => |s| s,
        else => return .none,
    };
    if (std.mem.eql(u8, kind, "didYouMean")) {
        const s = strVal(obj.getPtr("suggestion")) orelse return .none;
        return .{ .did_you_mean = s };
    }
    if (std.mem.eql(u8, kind, "typeMismatch")) {
        const a = strVal(obj.getPtr("actual")) orelse return .none;
        const e = strVal(obj.getPtr("expected")) orelse return .none;
        return .{ .type_mismatch = .{ .actual = a, .expected = e } };
    }
    if (std.mem.eql(u8, kind, "duplicateLocation")) {
        const n = intVal(obj.getPtr("value")) orelse return .none;
        const u: u32 = std.math.cast(u32, n) orelse return .none;
        return .{ .duplicate_location = u };
    }
    if (std.mem.eql(u8, kind, "unusedSymbol")) {
        const s = strVal(obj.getPtr("name")) orelse return .none;
        return .{ .unused_symbol = s };
    }
    if (std.mem.eql(u8, kind, "featureNotEnabled")) {
        const s = strVal(obj.getPtr("feature")) orelse return .none;
        return .{ .feature_not_enabled = s };
    }
    if (std.mem.eql(u8, kind, "vertexMissingBuiltinPosition")) {
        return .vertex_missing_builtin_position;
    }
    return .none;
}

fn objGet(val: ?*const std.json.Value, key: []const u8) ?*const std.json.Value {
    const v = val orelse return null;
    return switch (v.*) {
        .object => |obj| obj.getPtr(key),
        else => null,
    };
}

fn strVal(val: ?*const std.json.Value) ?[]const u8 {
    const v = val orelse return null;
    return switch (v.*) {
        .string => |s| s,
        else => null,
    };
}

fn intVal(val: ?*const std.json.Value) ?i64 {
    const v = val orelse return null;
    return switch (v.*) {
        .integer => |n| n,
        else => null,
    };
}

fn appendOne(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    uri: []const u8,
    diag: Handler.LspDiagnostic,
) void {
    appendStr(buf, allocator, "{\"range\":{\"start\":{\"line\":");
    appendUint(buf, allocator, diag.range.start.line);
    appendStr(buf, allocator, ",\"character\":");
    appendUint(buf, allocator, diag.range.start.character);
    appendStr(buf, allocator, "},\"end\":{\"line\":");
    appendUint(buf, allocator, diag.range.end.line);
    appendStr(buf, allocator, ",\"character\":");
    appendUint(buf, allocator, diag.range.end.character);
    appendStr(buf, allocator, "}},\"severity\":");
    appendUint(buf, allocator, @intFromEnum(diag.severity));
    appendStr(buf, allocator, ",\"source\":\"wgslender\",\"message\":\"");
    Diagnostic.appendJsonEscaped(buf, allocator, diag.message) catch {};
    appendStr(buf, allocator, "\"");
    if (diag.code.len > 0) {
        appendStr(buf, allocator, ",\"code\":\"");
        Diagnostic.appendJsonEscaped(buf, allocator, diag.code) catch {};
        appendStr(buf, allocator, "\"");
    }
    if (diag.spec_url.len > 0) {
        appendStr(buf, allocator, ",\"codeDescription\":{\"href\":\"");
        Diagnostic.appendJsonEscaped(buf, allocator, diag.spec_url) catch {};
        appendStr(buf, allocator, "\"}");
    }
    if (diag.related.len > 0) {
        appendStr(buf, allocator, ",\"relatedInformation\":[");
        for (diag.related, 0..) |rel, ri| {
            if (ri > 0) buf.append(allocator, ',') catch {};
            appendStr(buf, allocator, "{\"location\":{\"uri\":\"");
            Diagnostic.appendJsonEscaped(buf, allocator, uri) catch {};
            appendStr(buf, allocator, "\",\"range\":{\"start\":{\"line\":");
            appendUint(buf, allocator, rel.range.start.line);
            appendStr(buf, allocator, ",\"character\":");
            appendUint(buf, allocator, rel.range.start.character);
            appendStr(buf, allocator, "},\"end\":{\"line\":");
            appendUint(buf, allocator, rel.range.end.line);
            appendStr(buf, allocator, ",\"character\":");
            appendUint(buf, allocator, rel.range.end.character);
            appendStr(buf, allocator, "}}},\"message\":\"");
            Diagnostic.appendJsonEscaped(buf, allocator, rel.message) catch {};
            appendStr(buf, allocator, "\"}");
        }
        appendStr(buf, allocator, "]");
    }
    if (diag.tags.len > 0) {
        appendStr(buf, allocator, ",\"tags\":[");
        for (diag.tags, 0..) |tag, ti| {
            if (ti > 0) buf.append(allocator, ',') catch {};
            appendUint(buf, allocator, @intFromEnum(tag));
        }
        appendStr(buf, allocator, "]");
    }
    appendData(buf, allocator, diag.data);
    buf.append(allocator, '}') catch return;
}

/// Emit `,"data":{...}` for the variants the LSP knows how to consume,
/// or nothing at all for `.none`. The shape is opaque LSP `data` —
/// clients round-trip it back on `textDocument/codeAction`.
fn appendData(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, data: Diagnostic.QuickFixHint) void {
    switch (data) {
        .none => return,
        .did_you_mean => |s| {
            appendStr(buf, allocator, ",\"data\":{\"kind\":\"didYouMean\",\"suggestion\":\"");
            Diagnostic.appendJsonEscaped(buf, allocator, s) catch {};
            appendStr(buf, allocator, "\"}");
        },
        .type_mismatch => |tm| {
            appendStr(buf, allocator, ",\"data\":{\"kind\":\"typeMismatch\",\"actual\":\"");
            Diagnostic.appendJsonEscaped(buf, allocator, tm.actual) catch {};
            appendStr(buf, allocator, "\",\"expected\":\"");
            Diagnostic.appendJsonEscaped(buf, allocator, tm.expected) catch {};
            appendStr(buf, allocator, "\"}");
        },
        .duplicate_location => |n| {
            appendStr(buf, allocator, ",\"data\":{\"kind\":\"duplicateLocation\",\"value\":");
            appendUint(buf, allocator, n);
            appendStr(buf, allocator, "}");
        },
        .unused_symbol => |s| {
            appendStr(buf, allocator, ",\"data\":{\"kind\":\"unusedSymbol\",\"name\":\"");
            Diagnostic.appendJsonEscaped(buf, allocator, s) catch {};
            appendStr(buf, allocator, "\"}");
        },
        .feature_not_enabled => |s| {
            appendStr(buf, allocator, ",\"data\":{\"kind\":\"featureNotEnabled\",\"feature\":\"");
            Diagnostic.appendJsonEscaped(buf, allocator, s) catch {};
            appendStr(buf, allocator, "\"}");
        },
        .vertex_missing_builtin_position => {
            appendStr(buf, allocator, ",\"data\":{\"kind\":\"vertexMissingBuiltinPosition\"}");
        },
    }
}

inline fn appendStr(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, s: []const u8) void {
    buf.appendSlice(allocator, s) catch {};
}

inline fn appendUint(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, val: u32) void {
    var num_buf: [10]u8 = undefined;
    const s = std.fmt.bufPrint(&num_buf, "{d}", .{val}) catch return;
    buf.appendSlice(allocator, s) catch {};
}

// ==========================================================================
// Tests
// ==========================================================================

const testing = std.testing;

fn renderAndParse(
    arena: *std.heap.ArenaAllocator,
    uri: []const u8,
    diags: []const Handler.LspDiagnostic,
) !std.json.Value {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendDiagnosticItems(&buf, testing.allocator, uri, diags);
    defer buf.deinit(testing.allocator);
    return std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), buf.items, .{});
}

test "appendDiagnosticItems: empty slice emits empty array" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const parsed = try renderAndParse(&arena, "test://a.wgsl", &.{});
    try testing.expect(parsed == .array);
    try testing.expectEqual(@as(usize, 0), parsed.array.items.len);
}

test "appendDiagnosticItems: required fields present, optional fields omitted when empty" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const diags = [_]Handler.LspDiagnostic{
        .{
            .range = .{ .start = .{ .line = 1, .character = 2 }, .end = .{ .line = 1, .character = 4 } },
            .severity = .warning,
            .message = "w",
        },
    };
    const parsed = try renderAndParse(&arena, "test://a.wgsl", &diags);

    try testing.expectEqual(@as(usize, 1), parsed.array.items.len);
    const d = parsed.array.items[0];
    try testing.expectEqualStrings("wgslender", d.object.get("source").?.string);
    try testing.expectEqual(@as(i64, 2), d.object.get("severity").?.integer);
    try testing.expectEqualStrings("w", d.object.get("message").?.string);
    try testing.expectEqual(@as(i64, 1), d.object.get("range").?.object.get("start").?.object.get("line").?.integer);

    // No source data for these → keys must be absent (pulled-diagnostic
    // clients check for presence, not null).
    try testing.expect(d.object.get("code") == null);
    try testing.expect(d.object.get("codeDescription") == null);
    try testing.expect(d.object.get("relatedInformation") == null);
    try testing.expect(d.object.get("tags") == null);
}

test "appendDiagnosticItems: code + codeDescription round-trip" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const diags = [_]Handler.LspDiagnostic{
        .{
            .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 1 } },
            .severity = .@"error",
            .message = "nope",
            .code = "E0200",
            .spec_url = "https://www.w3.org/TR/WGSL/#types",
        },
    };
    const parsed = try renderAndParse(&arena, "test://a.wgsl", &diags);
    const d = parsed.array.items[0];

    try testing.expectEqualStrings("E0200", d.object.get("code").?.string);
    try testing.expectEqualStrings(
        "https://www.w3.org/TR/WGSL/#types",
        d.object.get("codeDescription").?.object.get("href").?.string,
    );
}

test "appendDiagnosticItems: relatedInformation attaches the provided URI" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const related = [_]Handler.LspRelatedInfo{
        .{
            .range = .{ .start = .{ .line = 3, .character = 4 }, .end = .{ .line = 3, .character = 5 } },
            .message = "first declared here",
        },
    };
    const diags = [_]Handler.LspDiagnostic{
        .{
            .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 1 } },
            .severity = .@"error",
            .message = "dup",
            .related = &related,
        },
    };
    const parsed = try renderAndParse(&arena, "test://related.wgsl", &diags);
    const ri = parsed.array.items[0].object.get("relatedInformation").?.array.items[0];
    try testing.expectEqualStrings("test://related.wgsl", ri.object.get("location").?.object.get("uri").?.string);
    try testing.expectEqualStrings("first declared here", ri.object.get("message").?.string);
    try testing.expectEqual(
        @as(i64, 3),
        ri.object.get("location").?.object.get("range").?.object.get("start").?.object.get("line").?.integer,
    );
}

test "appendDiagnosticItems: tags are serialized as integers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const tags = [_]Handler.DiagnosticTag{ .unnecessary, .deprecated };
    const diags = [_]Handler.LspDiagnostic{
        .{
            .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 1 } },
            .severity = .hint,
            .message = "dead",
            .tags = &tags,
        },
    };
    const parsed = try renderAndParse(&arena, "test://tags.wgsl", &diags);
    const arr = parsed.array.items[0].object.get("tags").?.array.items;
    try testing.expectEqual(@as(usize, 2), arr.len);
    try testing.expectEqual(@as(i64, 1), arr[0].integer);
    try testing.expectEqual(@as(i64, 2), arr[1].integer);
}

test "appendDiagnosticItems: message escapes JSON specials" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const diags = [_]Handler.LspDiagnostic{
        .{
            .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 1 } },
            .severity = .@"error",
            .message = "quotes \"x\" and a\\slash and a\nnewline",
        },
    };
    const parsed = try renderAndParse(&arena, "test://a.wgsl", &diags);
    // The parsed string must round-trip to the original unescaped bytes.
    try testing.expectEqualStrings(
        "quotes \"x\" and a\\slash and a\nnewline",
        parsed.array.items[0].object.get("message").?.string,
    );
}

test "data round-trip: did_you_mean" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const diags = [_]Handler.LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 1 } },
        .severity = .@"error",
        .message = "x",
        .data = .{ .did_you_mean = "position" },
    }};

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendDiagnosticItems(&buf, testing.allocator, "test://a.wgsl", &diags);
    defer buf.deinit(testing.allocator);

    const tree = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), buf.items, .{});
    const parsed = parseDiagnosticItems(arena.allocator(), tree.array.items) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), parsed.len);
    switch (parsed[0].data) {
        .did_you_mean => |s| try testing.expectEqualStrings("position", s),
        else => return error.TestUnexpectedResult,
    }
}

test "data round-trip: type_mismatch" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const diags = [_]Handler.LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 1 } },
        .severity = .@"error",
        .message = "x",
        .data = .{ .type_mismatch = .{ .actual = "i32", .expected = "f32" } },
    }};

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendDiagnosticItems(&buf, testing.allocator, "test://a.wgsl", &diags);
    defer buf.deinit(testing.allocator);

    const tree = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), buf.items, .{});
    const parsed = parseDiagnosticItems(arena.allocator(), tree.array.items) orelse return error.TestUnexpectedResult;
    switch (parsed[0].data) {
        .type_mismatch => |tm| {
            try testing.expectEqualStrings("i32", tm.actual);
            try testing.expectEqualStrings("f32", tm.expected);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "data round-trip: duplicate_location" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const diags = [_]Handler.LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 1 } },
        .severity = .@"error",
        .message = "x",
        .data = .{ .duplicate_location = 7 },
    }};

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendDiagnosticItems(&buf, testing.allocator, "test://a.wgsl", &diags);
    defer buf.deinit(testing.allocator);

    const tree = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), buf.items, .{});
    const parsed = parseDiagnosticItems(arena.allocator(), tree.array.items) orelse return error.TestUnexpectedResult;
    switch (parsed[0].data) {
        .duplicate_location => |n| try testing.expectEqual(@as(u32, 7), n),
        else => return error.TestUnexpectedResult,
    }
}

test "data round-trip: vertex_missing_builtin_position (payloadless)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const diags = [_]Handler.LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 1 } },
        .severity = .@"error",
        .message = "x",
        .data = .vertex_missing_builtin_position,
    }};

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendDiagnosticItems(&buf, testing.allocator, "test://a.wgsl", &diags);
    defer buf.deinit(testing.allocator);

    const tree = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), buf.items, .{});
    const parsed = parseDiagnosticItems(arena.allocator(), tree.array.items) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Diagnostic.QuickFixHint.vertex_missing_builtin_position, parsed[0].data);
}

test "data round-trip: .none omits the field entirely" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const diags = [_]Handler.LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 1 } },
        .severity = .@"error",
        .message = "x",
    }};

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendDiagnosticItems(&buf, testing.allocator, "test://a.wgsl", &diags);
    defer buf.deinit(testing.allocator);

    const tree = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), buf.items, .{});
    try testing.expect(tree.array.items[0].object.get("data") == null);

    const parsed = parseDiagnosticItems(arena.allocator(), tree.array.items) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Diagnostic.QuickFixHint.none, parsed[0].data);
}
