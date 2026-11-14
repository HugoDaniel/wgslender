//! Bridge: `Handler.LspTextEdit[]` ↔ `lsp.types.TextEdit[]` and the
//! `WorkspaceEdit.changes` map (always single-URI for WGSL).
//!
//! Reached as `lspkit.edits.*` via `lsp/lspkit_root.zig`. Native adapters
//! drive these from `textDocument/rename` (`native/symbols.zig`) and from
//! the per-action edit list inside `textDocument/codeAction`
//! (`native/code_actions.zig`). The bridge **borrows** every `[]const u8`
//! from `handler_edits` (uri, new_text); the caller must keep the input
//! alive until the response is written.

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");
const primitives = @import("primitives.zig");

/// Convert `Handler.LspTextEdit[]` to `lsp.types.TextEdit[]`. Strings are
/// borrowed from the input.
pub fn toLspKitTextEdits(
    arena: std.mem.Allocator,
    edits: []const Handler.LspTextEdit,
) ![]lsp.types.TextEdit {
    const out = try arena.alloc(lsp.types.TextEdit, edits.len);
    for (edits, 0..) |edit, i| {
        out[i] = .{
            .range = primitives.toLspKitRange(edit.range),
            .newText = edit.new_text,
        };
    }
    return out;
}

/// Build a single-URI `lsp.types.WorkspaceEdit` (`{changes: {uri: edits}}`).
/// Strings are borrowed from `uri` and `edits[].new_text`.
pub fn toLspKitWorkspaceEdit(
    arena: std.mem.Allocator,
    uri: []const u8,
    edits: []const Handler.LspTextEdit,
) !lsp.types.WorkspaceEdit {
    return toLspKitWorkspaceChanges(arena, .{ .documents = &.{.{
        .uri = uri,
        .edits = edits,
    }} });
}

/// Build a multi-document `WorkspaceEdit` from origin-aware changes.
///
/// Every result carries its own document URI; entries naming the same URI
/// are merged in input order so a declaration and a reference reported
/// twice cannot produce duplicate `changes` keys. A single document still
/// serializes as the legacy one-key map. Strings are borrowed from
/// `changes`.
pub fn toLspKitWorkspaceChanges(
    arena: std.mem.Allocator,
    changes: Handler.WorkspaceChanges,
) !lsp.types.WorkspaceEdit {
    var map: std.json.ArrayHashMap([]const lsp.types.TextEdit) = .{};
    for (changes.documents) |document| {
        const converted = try toLspKitTextEdits(arena, document.edits);
        const entry = try map.map.getOrPut(arena, document.uri);
        if (!entry.found_existing) {
            entry.value_ptr.* = converted;
            continue;
        }
        const previous = entry.value_ptr.*;
        const merged = try arena.alloc(lsp.types.TextEdit, previous.len + converted.len);
        @memcpy(merged[0..previous.len], previous);
        @memcpy(merged[previous.len..], converted);
        entry.value_ptr.* = merged;
    }
    return .{ .changes = map };
}

// =========================================================================
// Tests
// =========================================================================

const testing = std.testing;

const sample_range: Handler.Range = .{
    .start = .{ .line = 1, .character = 2 },
    .end = .{ .line = 1, .character = 7 },
};

test "toLspKitTextEdits: shape, range, newText borrowed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const edits = [_]Handler.LspTextEdit{
        .{ .range = sample_range, .new_text = "hello" },
    };
    const out = try toLspKitTextEdits(aa, &edits);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("hello", out[0].newText);
    try testing.expectEqual(@as(u32, 1), out[0].range.start.line);
}

test "toLspKitWorkspaceEdit: changes map keyed by uri (single entry)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const edits = [_]Handler.LspTextEdit{
        .{ .range = sample_range, .new_text = "x" },
    };
    const we = try toLspKitWorkspaceEdit(aa, "test://a.wgsl", &edits);
    try testing.expectEqual(@as(usize, 1), we.changes.?.map.count());
    const entry = we.changes.?.map.get("test://a.wgsl").?;
    try testing.expectEqual(@as(usize, 1), entry.len);
    try testing.expectEqualStrings("x", entry[0].newText);
}
