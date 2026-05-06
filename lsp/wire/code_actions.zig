//! JSON serialization for `Handler.LspCodeAction[]`.
//!
//! Pure encoder. Composes `wire/diagnostics.zig` (the embedded
//! single-diagnostic synopsis the client round-trips on
//! `textDocument/codeAction`) with `wire/edits.zig` (the
//! `WorkspaceEdit.changes` payload). The WASM transport drives this
//! from `wasm/code_actions.zig`; native parity tests reuse it to assert
//! byte-equivalence with the lsp-kit serializer driven by
//! `lspkit/code_actions.zig`.
//!
//! Reached as `wire.code_actions.*` via `lsp/wire_root.zig`.

const std = @import("std");
const Handler = @import("Handler");
const wgslender = @import("wgslender");
const primitives = @import("primitives.zig");
const wire_diag = @import("diagnostics.zig");
const wire_edits = @import("edits.zig");

const Diagnostic = wgslender.Diagnostic;

/// Append `[{<action>}, …]`. Writes the enclosing brackets.
pub fn appendCodeActionItems(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    uri: []const u8,
    actions: []const Handler.LspCodeAction,
) void {
    buf.append(gpa, '[') catch return;
    for (actions, 0..) |action, i| {
        if (i > 0) buf.append(gpa, ',') catch {};
        appendCodeActionItem(buf, gpa, uri, action);
    }
    buf.append(gpa, ']') catch {};
}

/// Append a single `{"title":"…","kind":"quickfix"[,"isPreferred":true],
/// "diagnostics":[<diag>],"edit":{"changes":{"<uri>":[<edits>]}}}`.
pub fn appendCodeActionItem(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    uri: []const u8,
    action: Handler.LspCodeAction,
) void {
    primitives.appendStr(buf, gpa, "{\"title\":\"");
    Diagnostic.appendJsonEscaped(buf, gpa, action.title) catch {};
    primitives.appendStr(buf, gpa, "\",\"kind\":\"quickfix\"");
    if (action.is_preferred) {
        primitives.appendStr(buf, gpa, ",\"isPreferred\":true");
    }
    primitives.appendStr(buf, gpa, ",\"diagnostics\":[");
    wire_diag.appendDiagnosticItem(buf, gpa, uri, action.diagnostic);
    primitives.appendStr(buf, gpa, "],\"edit\":");
    wire_edits.appendWorkspaceEdit(buf, gpa, uri, action.edits);
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

test "appendCodeActionItem: shape — title, kind, diagnostics, edit.changes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const edits = [_]Handler.LspTextEdit{
        .{ .range = sample_range, .new_text = "x" },
    };
    const action: Handler.LspCodeAction = .{
        .title = "Rename to x",
        .kind = "quickfix",
        .is_preferred = false,
        .diagnostic = .{
            .range = sample_range,
            .severity = .@"error",
            .message = "bad",
            .code = "E0001",
        },
        .edits = &edits,
    };

    var buf: std.ArrayList(u8) = .empty;
    appendCodeActionItem(&buf, aa, "test://a.wgsl", action);

    const v = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});
    try testing.expectEqualStrings("Rename to x", v.object.get("title").?.string);
    try testing.expectEqualStrings("quickfix", v.object.get("kind").?.string);
    try testing.expect(v.object.get("isPreferred") == null);
    const diag = v.object.get("diagnostics").?.array.items[0];
    try testing.expectEqualStrings("bad", diag.object.get("message").?.string);
    const changes = v.object.get("edit").?.object.get("changes").?.object;
    try testing.expectEqual(@as(usize, 1), changes.count());
    try testing.expectEqualStrings("x", changes.get("test://a.wgsl").?.array.items[0].object.get("newText").?.string);
}

test "appendCodeActionItem: isPreferred only when true" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const action: Handler.LspCodeAction = .{
        .title = "t",
        .kind = "quickfix",
        .is_preferred = true,
        .diagnostic = .{ .range = sample_range, .severity = .hint, .message = "m" },
        .edits = &.{},
    };

    var buf: std.ArrayList(u8) = .empty;
    appendCodeActionItem(&buf, aa, "test://a.wgsl", action);

    const v = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});
    try testing.expectEqual(true, v.object.get("isPreferred").?.bool);
}

test "appendCodeActionItems: empty slice emits []" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var buf: std.ArrayList(u8) = .empty;
    appendCodeActionItems(&buf, aa, "test://a.wgsl", &.{});

    const v = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});
    try testing.expect(v == .array);
    try testing.expectEqual(@as(usize, 0), v.array.items.len);
}
