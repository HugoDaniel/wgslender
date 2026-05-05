//! Native (lsp-kit) `textDocument/codeAction` adapter. Pure conversion
//! between lsp-kit types and the Handler's transport-agnostic
//! computeCodeActions output. The NativeServer wrapper handles locking
//! and forwards here.

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");
const codec = @import("codec");

pub fn handle(
    h: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.CodeAction.Params,
) ?[]const lsp.types.CodeAction.Result {
    const handler_diags = convertClientDiagnostics(arena, params.context.diagnostics) orelse return null;
    const actions = h.computeCodeActions(handler_diags) catch return null;
    if (actions.len == 0) return null;
    return convertToLspCodeActions(arena, params.textDocument.uri, actions);
}

fn convertClientDiagnostics(
    arena: std.mem.Allocator,
    diagnostics: []const lsp.types.Diagnostic,
) ?[]Handler.LspDiagnostic {
    const handler_diags = arena.alloc(Handler.LspDiagnostic, diagnostics.len) catch return null;
    for (diagnostics, 0..) |d, i| {
        handler_diags[i] = .{
            .range = codec.fromLspKitRange(d.range),
            .severity = codec.fromLspKitSeverity(d.severity),
            .message = d.message,
            .code = if (d.code) |c| switch (c) {
                .string => |s| s,
                .number => "",
            } else "",
        };
    }
    return handler_diags;
}

fn convertToLspCodeActions(
    arena: std.mem.Allocator,
    uri: []const u8,
    actions: []const Handler.LspCodeAction,
) ?[]const lsp.types.CodeAction.Result {
    const results = arena.alloc(lsp.types.CodeAction.Result, actions.len) catch return null;
    for (actions, 0..) |action, i| {
        const text_edits = arena.alloc(lsp.types.TextEdit, action.edits.len) catch continue;
        for (action.edits, 0..) |edit, ei| {
            text_edits[ei] = .{
                .range = codec.toLspKitRange(edit.range),
                .newText = edit.new_text,
            };
        }

        const lsp_diag = lsp.types.Diagnostic{
            .range = codec.toLspKitRange(action.diagnostic.range),
            .severity = codec.toLspKitSeverity(action.diagnostic.severity),
            .code = if (action.diagnostic.code.len > 0) .{ .string = action.diagnostic.code } else null,
            .source = "wgslender",
            .message = action.diagnostic.message,
        };
        const diag_slice = arena.alloc(lsp.types.Diagnostic, 1) catch continue;
        diag_slice[0] = lsp_diag;

        var changes = std.json.ArrayHashMap([]const lsp.types.TextEdit){};
        changes.map.put(arena, uri, text_edits) catch continue;

        results[i] = .{
            .code_action = .{
                .title = action.title,
                .kind = .quickfix,
                .isPreferred = action.is_preferred,
                .diagnostics = diag_slice,
                .edit = .{ .changes = changes },
            },
        };
    }
    return results;
}
