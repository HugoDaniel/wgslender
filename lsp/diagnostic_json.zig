//! JSON serialization for `Handler.LspDiagnostic[]`.
//!
//! Shared between the WASM push path (`publishDiagnostics` notification)
//! and the WASM pull path (`textDocument/diagnostic` Full report). Both
//! need the same `items[]` byte-for-byte; only the envelope differs.
//!
//! The native transport does not need this helper — lsp-kit's type-driven
//! writer handles serialization from `lsp.types.Diagnostic`.

const std = @import("std");
const Handler = @import("Handler.zig");
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
    buf.append(allocator, '}') catch return;
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
