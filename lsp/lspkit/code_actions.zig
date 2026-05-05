//! Bridge: `Handler.LspCodeAction[]` ↔ `lsp.types.CodeAction.Result[]`
//! and inbound `params.context.diagnostics[]` → `Handler.LspDiagnostic[]`.
//!
//! Reached as `lspkit.code_actions.*` via `lsp/lspkit_root.zig`. Native
//! adapters drive both directions from `textDocument/codeAction`
//! (`native/code_actions.zig`).
//!
//! Composes `lspkit/edits.zig` (the `WorkspaceEdit.changes` payload) and
//! `lspkit/diagnostics.zig` (the embedded single-diagnostic synopsis the
//! client round-trips). Strings are borrowed from `actions[]` and `uri`;
//! the caller must keep them alive until the response is written.

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");
const primitives = @import("primitives.zig");
const diag_codec = @import("diagnostics.zig");
const edits_codec = @import("edits.zig");

/// Convert `params.context.diagnostics` (the diagnostic synopsis the
/// client just round-tripped) back into `Handler.LspDiagnostic[]` so
/// `Handler.computeCodeActions` can dispatch on a tagged union instead
/// of re-parsing `message`. Strings are borrowed from the parsed lsp-kit
/// tree (matching how the WASM transport handles the same shape).
pub fn fromLspKitClientDiagnostics(
    arena: std.mem.Allocator,
    diagnostics: []const lsp.types.Diagnostic,
) ![]Handler.LspDiagnostic {
    const out = try arena.alloc(Handler.LspDiagnostic, diagnostics.len);
    for (diagnostics, 0..) |d, i| {
        out[i] = .{
            .range = primitives.fromLspKitRange(d.range),
            .severity = primitives.fromLspKitSeverity(d.severity),
            .message = d.message,
            .code = if (d.code) |c| switch (c) {
                .string => |s| s,
                .number => "",
            } else "",
            .data = diag_codec.quickFixHintFromLspKit(d.data),
        };
    }
    return out;
}

/// Convert `Handler.LspCodeAction[]` to lsp-kit's `CodeAction.Result[]`
/// (the `code_action` arm of the union). Each action's embedded
/// diagnostic carries a `data` payload populated from `QuickFixHint` so
/// native LSP clients see the same quick-fix routing the wasm transport
/// already provides.
pub fn toLspKitCodeActions(
    arena: std.mem.Allocator,
    uri: []const u8,
    actions: []const Handler.LspCodeAction,
) ![]const lsp.types.CodeAction.Result {
    const out = try arena.alloc(lsp.types.CodeAction.Result, actions.len);
    for (actions, 0..) |action, i| {
        const we = try edits_codec.toLspKitWorkspaceEdit(arena, uri, action.edits);
        const diag_slice = try arena.alloc(lsp.types.Diagnostic, 1);
        diag_slice[0] = .{
            .range = primitives.toLspKitRange(action.diagnostic.range),
            .severity = primitives.toLspKitSeverity(action.diagnostic.severity),
            .code = if (action.diagnostic.code.len > 0) .{ .string = action.diagnostic.code } else null,
            .source = "wgslender",
            .message = action.diagnostic.message,
            .data = diag_codec.quickFixHintToLspKitBorrowed(arena, action.diagnostic.data),
        };
        out[i] = .{
            .code_action = .{
                .title = action.title,
                .kind = .quickfix,
                // Only set when true so the field is omitted on the wire
                // for default-false actions, matching `wire/code_actions.zig`.
                .isPreferred = if (action.is_preferred) true else null,
                .diagnostics = diag_slice,
                .edit = we,
            },
        };
    }
    return out;
}

// =========================================================================
// Tests
// =========================================================================

const testing = std.testing;

const sample_range: Handler.Range = .{
    .start = .{ .line = 1, .character = 2 },
    .end = .{ .line = 1, .character = 7 },
};

test "toLspKitCodeActions: title, kind, embedded diagnostic, edit.changes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const edits = [_]Handler.LspTextEdit{
        .{ .range = sample_range, .new_text = "x" },
    };
    const actions = [_]Handler.LspCodeAction{.{
        .title = "Rename to x",
        .kind = "quickfix",
        .is_preferred = true,
        .diagnostic = .{
            .range = sample_range,
            .severity = .@"error",
            .message = "bad",
            .code = "E0001",
            .data = .{ .did_you_mean = "x" },
        },
        .edits = &edits,
    }};

    const out = try toLspKitCodeActions(aa, "test://a.wgsl", &actions);
    try testing.expectEqual(@as(usize, 1), out.len);
    const ca = out[0].code_action;
    try testing.expectEqualStrings("Rename to x", ca.title);
    try testing.expectEqual(true, ca.isPreferred.?);
    const diags = ca.diagnostics.?;
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqualStrings("bad", diags[0].message);
    try testing.expect(diags[0].data != null);
    const changes = ca.edit.?.changes.?.map;
    try testing.expectEqual(@as(usize, 1), changes.count());
    try testing.expectEqualStrings("x", changes.get("test://a.wgsl").?[0].newText);
}

test "fromLspKitClientDiagnostics: maps fields and decodes data payload" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const data = diag_codec.quickFixHintToLspKitBorrowed(aa, .{ .did_you_mean = "position" }).?;
    const in = [_]lsp.types.Diagnostic{.{
        .range = primitives.toLspKitRange(sample_range),
        .severity = .Warning,
        .code = .{ .string = "W0001" },
        .source = "wgslender",
        .message = "m",
        .data = data,
    }};
    const out = try fromLspKitClientDiagnostics(aa, &in);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("m", out[0].message);
    try testing.expectEqualStrings("W0001", out[0].code);
    try testing.expectEqual(Handler.DiagnosticSeverity.warning, out[0].severity);
    switch (out[0].data) {
        .did_you_mean => |s| try testing.expectEqualStrings("position", s),
        else => return error.TestUnexpectedResult,
    }
}
