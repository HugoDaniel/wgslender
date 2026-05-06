//! JSON serialization for `Handler.CallHierarchyItem` /
//! `IncomingCall` / `OutgoingCall`.
//!
//! Pure encoders. The WASM transport drives these from
//! `wasm/call_hierarchy.zig`; native parity tests reuse them to assert
//! byte-equivalence with the lsp-kit serializer driven by
//! `lspkit/call_hierarchy.zig`.
//!
//! Reached as `wire.call_hierarchy.*` via `lsp/wire_root.zig`.
//!
//! The `kind` field of every `CallHierarchyItem` is hard-wired to `12`
//! (LSP `SymbolKind.Function`) — WGSL only models functions in this
//! tree.

const std = @import("std");
const Handler = @import("Handler");
const wgslender = @import("wgslender");
const primitives = @import("primitives.zig");

const Diagnostic = wgslender.Diagnostic;

/// Append `{"name":"…","kind":12,"uri":"…","range":{…},"selectionRange":{…}}`.
/// Used standalone for `prepareCallHierarchy` and as the inner `from` /
/// `to` object inside an `IncomingCall` / `OutgoingCall`.
pub fn appendItem(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    uri: []const u8,
    item: Handler.CallHierarchyItem,
) void {
    primitives.appendStr(buf, gpa, "{\"name\":\"");
    Diagnostic.appendJsonEscaped(buf, gpa, item.name) catch return;
    primitives.appendStr(buf, gpa, "\",\"kind\":12,\"uri\":\"");
    Diagnostic.appendJsonEscaped(buf, gpa, uri) catch return;
    primitives.appendStr(buf, gpa, "\",\"range\":");
    primitives.formatRange(buf, gpa, item.range);
    primitives.appendStr(buf, gpa, ",\"selectionRange\":");
    primitives.formatRange(buf, gpa, item.selection_range);
    buf.append(gpa, '}') catch {};
}

fn appendFromRanges(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    ranges: []const Handler.Range,
) void {
    primitives.appendStr(buf, gpa, ",\"fromRanges\":[");
    for (ranges, 0..) |fr, fi| {
        if (fi > 0) buf.append(gpa, ',') catch {};
        primitives.formatRange(buf, gpa, fr);
    }
    buf.append(gpa, ']') catch {};
}

/// Append `{"from":{<item>},"fromRanges":[…]}`.
pub fn appendIncomingCall(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    uri: []const u8,
    call: Handler.IncomingCall,
) void {
    primitives.appendStr(buf, gpa, "{\"from\":");
    appendItem(buf, gpa, uri, call.from);
    appendFromRanges(buf, gpa, call.from_ranges);
    buf.append(gpa, '}') catch {};
}

/// Append `{"to":{<item>},"fromRanges":[…]}`.
pub fn appendOutgoingCall(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    uri: []const u8,
    call: Handler.OutgoingCall,
) void {
    primitives.appendStr(buf, gpa, "{\"to\":");
    appendItem(buf, gpa, uri, call.to);
    appendFromRanges(buf, gpa, call.from_ranges);
    buf.append(gpa, '}') catch {};
}

// =========================================================================
// Tests
// =========================================================================

const testing = std.testing;

const sample_range: Handler.Range = .{
    .start = .{ .line = 1, .character = 2 },
    .end = .{ .line = 1, .character = 7 },
};
const sample_sel: Handler.Range = .{
    .start = .{ .line = 1, .character = 3 },
    .end = .{ .line = 1, .character = 5 },
};

test "appendItem: shape, kind=12, range fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var buf: std.ArrayList(u8) = .empty;
    appendItem(&buf, aa, "test://x.wgsl", .{
        .name = "main",
        .kind = .function,
        .range = sample_range,
        .selection_range = sample_sel,
    });

    const v = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});
    try testing.expectEqualStrings("main", v.object.get("name").?.string);
    try testing.expectEqual(@as(i64, 12), v.object.get("kind").?.integer);
    try testing.expectEqualStrings("test://x.wgsl", v.object.get("uri").?.string);
    try testing.expect(v.object.get("range") != null);
    try testing.expect(v.object.get("selectionRange") != null);
}

test "appendIncomingCall: empty fromRanges array stays empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var buf: std.ArrayList(u8) = .empty;
    appendIncomingCall(&buf, aa, "test://x.wgsl", .{
        .from = .{ .name = "caller", .kind = .function, .range = sample_range, .selection_range = sample_sel },
        .from_ranges = &.{},
    });

    const v = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});
    try testing.expectEqualStrings("caller", v.object.get("from").?.object.get("name").?.string);
    try testing.expectEqual(@as(usize, 0), v.object.get("fromRanges").?.array.items.len);
}

test "appendOutgoingCall: from_ranges length preserved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const ranges = [_]Handler.Range{
        .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 1 } },
        .{ .start = .{ .line = 5, .character = 6 }, .end = .{ .line = 5, .character = 9 } },
    };

    var buf: std.ArrayList(u8) = .empty;
    appendOutgoingCall(&buf, aa, "test://x.wgsl", .{
        .to = .{ .name = "callee", .kind = .function, .range = sample_range, .selection_range = sample_sel },
        .from_ranges = &ranges,
    });

    const v = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});
    try testing.expectEqualStrings("callee", v.object.get("to").?.object.get("name").?.string);
    try testing.expectEqual(@as(usize, 2), v.object.get("fromRanges").?.array.items.len);
}
