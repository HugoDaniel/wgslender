//! JSON serialization for navigation results: Hover, Location,
//! DocumentHighlight.
//!
//! Pure encoders (no I/O, no Handler lookup). The WASM transport drives
//! these directly from `wasm/navigation.zig`; native parity tests reuse
//! them to assert byte-equivalence with the lsp-kit serializer driven by
//! `lspkit/navigation.zig`.
//!
//! Reached as `wire.navigation.*` via `lsp/wire_root.zig`.
//!
//! Each helper appends a single object — the caller emits enclosing `[`
//! / `,` / `]` for array results (definition/typeDefinition return one
//! Location; references returns an array of Locations).

const std = @import("std");
const Handler = @import("Handler");
const wgslender = @import("wgslender");
const primitives = @import("primitives.zig");

const Diagnostic = wgslender.Diagnostic;

/// Append `{"uri":"…","range":{…}}` — the LSP `Location` shape, used by
/// definition, typeDefinition, and each entry of references.
pub fn appendLocation(
    buf: *std.ArrayListUnmanaged(u8),
    gpa: std.mem.Allocator,
    uri: []const u8,
    range: Handler.Range,
) void {
    primitives.appendStr(buf, gpa, "{\"uri\":\"");
    Diagnostic.appendJsonEscaped(buf, gpa, uri) catch return;
    primitives.appendStr(buf, gpa, "\",\"range\":");
    primitives.formatRange(buf, gpa, range);
    buf.append(gpa, '}') catch {};
}

/// Append `{"range":{…},"kind":N}` — the LSP `DocumentHighlight` shape.
pub fn appendDocumentHighlight(
    buf: *std.ArrayListUnmanaged(u8),
    gpa: std.mem.Allocator,
    h: Handler.DocumentHighlight,
) void {
    primitives.appendStr(buf, gpa, "{\"range\":");
    primitives.formatRange(buf, gpa, h.range);
    primitives.appendStr(buf, gpa, ",\"kind\":");
    primitives.appendUint(buf, gpa, @intFromEnum(h.kind));
    buf.append(gpa, '}') catch {};
}

/// Append `{"contents":{"kind":"markdown","value":"…"},"range":{…}}` —
/// the LSP `Hover` shape. The caller owns `hover.contents`; it is escaped
/// inline.
pub fn appendHover(
    buf: *std.ArrayListUnmanaged(u8),
    gpa: std.mem.Allocator,
    hover: Handler.HoverResult,
) void {
    primitives.appendStr(buf, gpa, "{\"contents\":{\"kind\":\"markdown\",\"value\":\"");
    Diagnostic.appendJsonEscaped(buf, gpa, hover.contents) catch return;
    primitives.appendStr(buf, gpa, "\"},\"range\":");
    primitives.formatRange(buf, gpa, hover.range);
    buf.append(gpa, '}') catch {};
}

// =========================================================================
// Tests
// =========================================================================

const testing = std.testing;

fn parseValue(arena: std.mem.Allocator, body: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
}

fn renderLocation(gpa: std.mem.Allocator, uri: []const u8, range: Handler.Range) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);
    appendLocation(&buf, gpa, uri, range);
    return try buf.toOwnedSlice(gpa);
}

test "appendLocation: shape and uri escape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const body = try renderLocation(aa, "file:///a%20b.wgsl", .{
        .start = .{ .line = 2, .character = 5 },
        .end = .{ .line = 2, .character = 9 },
    });

    const v = try parseValue(aa, body);
    try testing.expect(v == .object);
    try testing.expectEqualStrings("file:///a%20b.wgsl", v.object.get("uri").?.string);
    const r = v.object.get("range").?.object;
    try testing.expectEqual(@as(i64, 2), r.get("start").?.object.get("line").?.integer);
    try testing.expectEqual(@as(i64, 5), r.get("start").?.object.get("character").?.integer);
    try testing.expectEqual(@as(i64, 2), r.get("end").?.object.get("line").?.integer);
    try testing.expectEqual(@as(i64, 9), r.get("end").?.object.get("character").?.integer);
}

test "appendDocumentHighlight: kind = read" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendDocumentHighlight(&buf, aa, .{
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 4 } },
        .kind = .read,
    });

    const v = try parseValue(aa, buf.items);
    try testing.expectEqual(@as(i64, 2), v.object.get("kind").?.integer);
    try testing.expect(v.object.get("range") != null);
}

test "appendHover: markdown shape and value escape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendHover(&buf, aa, .{
        .contents = "**fn** `f`(\"x\\y\") -> `i32`",
        .range = .{ .start = .{ .line = 1, .character = 2 }, .end = .{ .line = 1, .character = 3 } },
    });

    const v = try parseValue(aa, buf.items);
    const c = v.object.get("contents").?.object;
    try testing.expectEqualStrings("markdown", c.get("kind").?.string);
    try testing.expectEqualStrings("**fn** `f`(\"x\\y\") -> `i32`", c.get("value").?.string);
    try testing.expect(v.object.get("range") != null);
}
