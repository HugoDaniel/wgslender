//! JSON serialization for `Handler.LspTextEdit[]` and the LSP
//! `WorkspaceEdit.changes` shape (`{"<uri>":[<edits>]}`).
//!
//! Pure encoders. The WASM transport drives `appendWorkspaceEdit` from
//! `wasm/symbols.zig::handleRename` and the per-action edit list from
//! `wasm/code_actions.zig`; native parity tests reuse them to assert
//! byte-equivalence with the lsp-kit serializer driven by
//! `lspkit/edits.zig`.
//!
//! Reached as `wire.edits.*` via `lsp/wire_root.zig`.

const std = @import("std");
const Handler = @import("Handler");
const wgslender = @import("wgslender");
const primitives = @import("primitives.zig");

const Diagnostic = wgslender.Diagnostic;

/// Append `{"range":{…},"newText":"…"}`.
pub fn appendTextEdit(
    buf: *std.ArrayListUnmanaged(u8),
    gpa: std.mem.Allocator,
    edit: Handler.LspTextEdit,
) void {
    primitives.appendStr(buf, gpa, "{\"range\":");
    primitives.formatRange(buf, gpa, edit.range);
    primitives.appendStr(buf, gpa, ",\"newText\":\"");
    Diagnostic.appendJsonEscaped(buf, gpa, edit.new_text) catch {};
    primitives.appendStr(buf, gpa, "\"}");
}

/// Append `[{<edit>}, …]`. Writes the enclosing brackets.
pub fn appendTextEdits(
    buf: *std.ArrayListUnmanaged(u8),
    gpa: std.mem.Allocator,
    edits: []const Handler.LspTextEdit,
) void {
    buf.append(gpa, '[') catch return;
    for (edits, 0..) |edit, i| {
        if (i > 0) buf.append(gpa, ',') catch {};
        appendTextEdit(buf, gpa, edit);
    }
    buf.append(gpa, ']') catch {};
}

/// Append a full `WorkspaceEdit` body: `{"changes":{"<uri>":[<edits>]}}`.
/// WGSL edits are always intra-document, so the `changes` map only ever
/// has a single key.
pub fn appendWorkspaceEdit(
    buf: *std.ArrayListUnmanaged(u8),
    gpa: std.mem.Allocator,
    uri: []const u8,
    edits: []const Handler.LspTextEdit,
) void {
    primitives.appendStr(buf, gpa, "{\"changes\":{\"");
    Diagnostic.appendJsonEscaped(buf, gpa, uri) catch {};
    primitives.appendStr(buf, gpa, "\":");
    appendTextEdits(buf, gpa, edits);
    primitives.appendStr(buf, gpa, "}}");
}

// =========================================================================
// Tests
// =========================================================================

const testing = std.testing;

const sample_range: Handler.Range = .{
    .start = .{ .line = 1, .character = 2 },
    .end = .{ .line = 1, .character = 7 },
};

test "appendTextEdit: shape + escapes newText" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendTextEdit(&buf, aa, .{ .range = sample_range, .new_text = "foo \"bar\"" });

    const v = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});
    try testing.expectEqualStrings("foo \"bar\"", v.object.get("newText").?.string);
    try testing.expectEqual(@as(i64, 1), v.object.get("range").?.object.get("start").?.object.get("line").?.integer);
}

test "appendTextEdits: empty slice emits []" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendTextEdits(&buf, aa, &.{});

    const v = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});
    try testing.expect(v == .array);
    try testing.expectEqual(@as(usize, 0), v.array.items.len);
}

test "appendWorkspaceEdit: changes map keyed by uri, single entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const edits = [_]Handler.LspTextEdit{
        .{ .range = sample_range, .new_text = "x" },
        .{ .range = sample_range, .new_text = "y" },
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendWorkspaceEdit(&buf, aa, "test://a.wgsl", &edits);

    const v = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});
    const changes = v.object.get("changes").?.object;
    try testing.expectEqual(@as(usize, 1), changes.count());
    const arr = changes.get("test://a.wgsl").?.array.items;
    try testing.expectEqual(@as(usize, 2), arr.len);
    try testing.expectEqualStrings("x", arr[0].object.get("newText").?.string);
    try testing.expectEqualStrings("y", arr[1].object.get("newText").?.string);
}

test "appendWorkspaceEdit: escapes uri" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendWorkspaceEdit(&buf, aa, "test://a\"b.wgsl", &.{});

    const v = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});
    const changes = v.object.get("changes").?.object;
    try testing.expect(changes.get("test://a\"b.wgsl") != null);
}
