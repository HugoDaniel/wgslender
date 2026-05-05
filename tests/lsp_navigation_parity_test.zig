//! Parity harness for navigation + call_hierarchy: `lspkit/<feature>.zig`
//! (driven by `lsp.writeResponse`) and `wire/<feature>.zig` must produce
//! byte-equivalent JSON for every result shape.
//!
//! Like `lsp_diagnostic_parity_test.zig`, this guards against the two
//! transports drifting on field ordering, kind constants, or escape
//! conventions — VS Code tolerates many shapes, but third-party clients
//! may not.

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");
const lspkit = @import("lspkit");
const wire = @import("wire");
const helpers = @import("lsp_parity_helpers.zig");

const expectEqualJson = helpers.expectEqualJson;
const writeAndParse = helpers.writeAndParseResult;

const test_uri = "test://parity.wgsl";

const sample_range: Handler.Range = .{
    .start = .{ .line = 1, .character = 2 },
    .end = .{ .line = 1, .character = 7 },
};
const sample_sel: Handler.Range = .{
    .start = .{ .line = 1, .character = 3 },
    .end = .{ .line = 1, .character = 5 },
};

// =========================================================================
// Hover
// =========================================================================

test "parity: hover with markdown content" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const handler_hover: Handler.HoverResult = .{
        .contents = "**fn** `f`(\"a\\b\") -> `i32`",
        .range = sample_range,
    };

    const a = try writeAndParse(aa, lsp.types.Hover, lspkit.navigation.toLspKitHover(handler_hover));

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire.navigation.appendHover(&buf, aa, handler_hover);
    const b = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});

    try expectEqualJson(a, b);
}

// =========================================================================
// Definition / TypeDefinition (single Location)
// =========================================================================

test "parity: single location (definition)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const a = try writeAndParse(
        aa,
        lsp.types.Definition.Result,
        lspkit.navigation.toLspKitDefinitionLocation(test_uri, sample_range),
    );

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire.navigation.appendLocation(&buf, aa, test_uri, sample_range);
    const b = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});

    try expectEqualJson(a, b);
}

// =========================================================================
// References (array of Locations)
// =========================================================================

test "parity: references — multiple locations" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const refs = [_]Handler.Range{
        .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 1 } },
        .{ .start = .{ .line = 5, .character = 6 }, .end = .{ .line = 5, .character = 9 } },
        sample_range,
    };

    const locations = try lspkit.navigation.toLspKitLocations(aa, test_uri, &refs);
    const a = try writeAndParse(aa, []const lsp.types.Location, locations);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.append(aa, '[') catch unreachable;
    for (refs, 0..) |r, i| {
        if (i > 0) buf.append(aa, ',') catch unreachable;
        wire.navigation.appendLocation(&buf, aa, test_uri, r);
    }
    buf.append(aa, ']') catch unreachable;
    const b = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});

    try expectEqualJson(a, b);
}

// =========================================================================
// DocumentHighlight
// =========================================================================

test "parity: documentHighlight — text/read/write kinds" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const highlights = [_]Handler.DocumentHighlight{
        .{ .range = sample_range, .kind = .text },
        .{ .range = sample_range, .kind = .read },
        .{ .range = sample_range, .kind = .write },
    };

    const result = try lspkit.navigation.toLspKitDocumentHighlights(aa, &highlights);
    const a = try writeAndParse(aa, []const lsp.types.DocumentHighlight, result);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.append(aa, '[') catch unreachable;
    for (highlights, 0..) |h, i| {
        if (i > 0) buf.append(aa, ',') catch unreachable;
        wire.navigation.appendDocumentHighlight(&buf, aa, h);
    }
    buf.append(aa, ']') catch unreachable;
    const b = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});

    try expectEqualJson(a, b);
}

// =========================================================================
// Call hierarchy: prepare (one item)
// =========================================================================

test "parity: call_hierarchy prepare — single item" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const item: Handler.CallHierarchyItem = .{
        .name = "main",
        .kind = .function,
        .range = sample_range,
        .selection_range = sample_sel,
    };

    const result = try lspkit.call_hierarchy.toLspKitPrepareResult(aa, test_uri, item);
    const a = try writeAndParse(aa, []const lsp.types.call_hierarchy.Item, result);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.append(aa, '[') catch unreachable;
    wire.call_hierarchy.appendItem(&buf, aa, test_uri, item);
    buf.append(aa, ']') catch unreachable;
    const b = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});

    try expectEqualJson(a, b);
}

// =========================================================================
// Call hierarchy: incoming
// =========================================================================

test "parity: call_hierarchy incoming — fromRanges len > 0" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const ranges = [_]Handler.Range{
        .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 1 } },
        .{ .start = .{ .line = 4, .character = 4 }, .end = .{ .line = 4, .character = 9 } },
    };
    const calls = [_]Handler.IncomingCall{.{
        .from = .{ .name = "caller", .kind = .function, .range = sample_range, .selection_range = sample_sel },
        .from_ranges = &ranges,
    }};

    const result = try lspkit.call_hierarchy.toLspKitIncomingCalls(aa, test_uri, &calls);
    const a = try writeAndParse(aa, []const lsp.types.call_hierarchy.IncomingCall, result);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.append(aa, '[') catch unreachable;
    for (calls, 0..) |c, i| {
        if (i > 0) buf.append(aa, ',') catch unreachable;
        wire.call_hierarchy.appendIncomingCall(&buf, aa, test_uri, c);
    }
    buf.append(aa, ']') catch unreachable;
    const b = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});

    try expectEqualJson(a, b);
}

// =========================================================================
// Call hierarchy: outgoing
// =========================================================================

test "parity: call_hierarchy outgoing — empty fromRanges" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const calls = [_]Handler.OutgoingCall{.{
        .to = .{ .name = "callee", .kind = .function, .range = sample_range, .selection_range = sample_sel },
        .from_ranges = &.{},
    }};

    const result = try lspkit.call_hierarchy.toLspKitOutgoingCalls(aa, test_uri, &calls);
    const a = try writeAndParse(aa, []const lsp.types.call_hierarchy.OutgoingCall, result);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.append(aa, '[') catch unreachable;
    for (calls, 0..) |c, i| {
        if (i > 0) buf.append(aa, ',') catch unreachable;
        wire.call_hierarchy.appendOutgoingCall(&buf, aa, test_uri, c);
    }
    buf.append(aa, ']') catch unreachable;
    const b = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});

    try expectEqualJson(a, b);
}
