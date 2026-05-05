//! JSON serialization for `Handler.DocumentSymbolInfo[]`.
//!
//! Pure encoder. Recursive — `children` follow the same shape — so a
//! single `appendDocSymbol` covers the whole tree. The WASM transport
//! drives this from `wasm/symbols.zig::handleDocumentSymbol`; native
//! parity tests reuse it to assert byte-equivalence with the lsp-kit
//! serializer driven by `lspkit/symbols.zig`.
//!
//! Reached as `wire.symbols.*` via `lsp/wire_root.zig`.

const std = @import("std");
const Handler = @import("Handler");
const wgslender = @import("wgslender");
const primitives = @import("primitives.zig");

const Diagnostic = wgslender.Diagnostic;

/// Map a `Handler.SymbolKind` onto the LSP `SymbolKind` integer
/// constants. Kept here (and mirrored in `lspkit/symbols.zig`) so the
/// two transports cannot drift on the integer encoding.
pub fn symbolKindCode(kind: Handler.SymbolKind) u32 {
    return switch (kind) {
        .function => 12,
        .struct_type => 23,
        .variable => 13,
        .constant => 14,
        .field => 8,
        .type_alias => 5,
        .override => 14,
    };
}

/// Append `[{<sym>}, …]`. Writes the enclosing brackets.
pub fn appendDocSymbols(
    buf: *std.ArrayListUnmanaged(u8),
    gpa: std.mem.Allocator,
    syms: []const Handler.DocumentSymbolInfo,
) void {
    buf.append(gpa, '[') catch return;
    for (syms, 0..) |sym, i| {
        if (i > 0) buf.append(gpa, ',') catch {};
        appendDocSymbol(buf, gpa, sym);
    }
    buf.append(gpa, ']') catch {};
}

/// Append `{"name":"…","kind":<int>,"range":{…},"selectionRange":{…},
/// "children":[…]?}`. `children` is omitted when empty.
pub fn appendDocSymbol(
    buf: *std.ArrayListUnmanaged(u8),
    gpa: std.mem.Allocator,
    sym: Handler.DocumentSymbolInfo,
) void {
    primitives.appendStr(buf, gpa, "{\"name\":\"");
    Diagnostic.appendJsonEscaped(buf, gpa, sym.name) catch {};
    primitives.appendStr(buf, gpa, "\",\"kind\":");
    primitives.appendUint(buf, gpa, symbolKindCode(sym.kind));
    primitives.appendStr(buf, gpa, ",\"range\":");
    primitives.formatRange(buf, gpa, sym.range);
    primitives.appendStr(buf, gpa, ",\"selectionRange\":");
    primitives.formatRange(buf, gpa, sym.selection_range);
    if (sym.children.len > 0) {
        primitives.appendStr(buf, gpa, ",\"children\":");
        appendDocSymbols(buf, gpa, sym.children);
    }
    buf.append(gpa, '}') catch {};
}

// =========================================================================
// Tests
// =========================================================================

const testing = std.testing;

const sample_range: Handler.Range = .{
    .start = .{ .line = 1, .character = 2 },
    .end = .{ .line = 3, .character = 4 },
};
const sample_sel: Handler.Range = .{
    .start = .{ .line = 1, .character = 3 },
    .end = .{ .line = 1, .character = 5 },
};

test "appendDocSymbol: leaf, kind=function (12), no children field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendDocSymbol(&buf, aa, .{
        .name = "main",
        .kind = .function,
        .range = sample_range,
        .selection_range = sample_sel,
        .children = &.{},
    });

    const v = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});
    try testing.expectEqualStrings("main", v.object.get("name").?.string);
    try testing.expectEqual(@as(i64, 12), v.object.get("kind").?.integer);
    try testing.expect(v.object.get("children") == null);
}

test "appendDocSymbol: struct with field children (recursive)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const fields = [_]Handler.DocumentSymbolInfo{
        .{ .name = "a", .kind = .field, .range = sample_range, .selection_range = sample_sel, .children = &.{} },
        .{ .name = "b", .kind = .field, .range = sample_range, .selection_range = sample_sel, .children = &.{} },
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendDocSymbol(&buf, aa, .{
        .name = "S",
        .kind = .struct_type,
        .range = sample_range,
        .selection_range = sample_sel,
        .children = &fields,
    });

    const v = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});
    try testing.expectEqual(@as(i64, 23), v.object.get("kind").?.integer);
    const children = v.object.get("children").?.array.items;
    try testing.expectEqual(@as(usize, 2), children.len);
    try testing.expectEqual(@as(i64, 8), children[0].object.get("kind").?.integer);
    try testing.expectEqualStrings("a", children[0].object.get("name").?.string);
}

test "appendDocSymbols: empty slice emits []" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendDocSymbols(&buf, aa, &.{});

    const v = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});
    try testing.expect(v == .array);
    try testing.expectEqual(@as(usize, 0), v.array.items.len);
}

test "symbolKindCode: every variant maps to LSP SymbolKind integer" {
    try testing.expectEqual(@as(u32, 12), symbolKindCode(.function));
    try testing.expectEqual(@as(u32, 23), symbolKindCode(.struct_type));
    try testing.expectEqual(@as(u32, 13), symbolKindCode(.variable));
    try testing.expectEqual(@as(u32, 14), symbolKindCode(.constant));
    try testing.expectEqual(@as(u32, 8), symbolKindCode(.field));
    try testing.expectEqual(@as(u32, 5), symbolKindCode(.type_alias));
    try testing.expectEqual(@as(u32, 14), symbolKindCode(.override));
}
