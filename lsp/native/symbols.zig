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
    const edits = h.computeRename(
        params.textDocument.uri,
        codec.fromLspKitPosition(params.position),
        params.newName,
    ) catch return null;
    const handler_edits = edits orelse return null;
    defer h.gpa.free(handler_edits);
    return edits_codec.toLspKitWorkspaceEdit(arena, params.textDocument.uri, handler_edits) catch null;
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
