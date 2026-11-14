//! Native symbol adapters: rename, prepareRename, documentSymbol. Thin
//! dispatch shims — call Handler, delegate shape conversion to
//! `lspkit/edits.zig` + `lspkit/symbols.zig`.

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");
const lspkit = @import("lspkit");
const codec = lspkit.primitives;
const edits_codec = lspkit.edits;
const sym_codec = lspkit.symbols;

pub fn handleRename(
    h: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.rename.Params,
) ?lsp.types.WorkspaceEdit {
    const changes = h.computeRename(
        params.textDocument.uri,
        codec.fromLspKitPosition(params.position),
        params.newName,
    ) catch return null;
    const workspace_changes = changes orelse return null;
    defer h.freeWorkspaceChanges(workspace_changes);

    // The codec borrows each document URI and each `newText` string. The
    // new name belongs to `params`, but the Handler-owned URIs must move
    // onto the response arena before the changes are released.
    const documents = arena.alloc(Handler.DocumentEdits, workspace_changes.documents.len) catch return null;
    for (workspace_changes.documents, 0..) |document, index| {
        documents[index] = .{
            .uri = arena.dupe(u8, document.uri) catch return null,
            .edits = document.edits,
        };
    }
    return edits_codec.toLspKitWorkspaceChanges(arena, .{ .documents = documents }) catch null;
}

pub fn handlePrepareRename(
    h: *Handler,
    params: lsp.types.prepare_rename.Params,
) ?lsp.types.prepare_rename.Result {
    const range = h.prepareRename(
        params.textDocument.uri,
        codec.fromLspKitPosition(params.position),
    ) catch return null;
    const r = range orelse return null;
    return .{
        .prepare_rename_placeholder = .{
            .range = codec.toLspKitRange(r),
            .placeholder = "",
        },
    };
}

pub fn handleWorkspaceSymbol(
    h: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.workspace.Symbol.Params,
) ?lsp.types.workspace.Symbol.Result {
    const symbols = h.computeWorkspaceSymbols(params.query) catch return null;
    defer h.gpa.free(symbols);
    if (symbols.len == 0) return null;
    const lsp_symbols = sym_codec.toLspKitWorkspaceSymbols(arena, symbols) catch return null;
    return .{ .workspace_symbols = lsp_symbols };
}

pub fn handleDocumentSymbol(
    h: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.DocumentSymbol.Params,
) ?lsp.types.DocumentSymbol.Result {
    const symbols = h.computeDocumentSymbols(params.textDocument.uri) catch return null;
    defer h.gpa.free(symbols);
    if (symbols.len == 0) return null;
    const lsp_symbols = sym_codec.toLspKitDocumentSymbols(arena, symbols) catch return null;
    return .{ .document_symbols = lsp_symbols };
}
