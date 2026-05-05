//! Native editing adapters: completion, signatureHelp, formatting,
//! foldingRange, inlayHint, codeLens, selectionRange, semanticTokens/full.
//!
//! Each handler is a thin shim — fold lsp.types.* params via
//! `lspkit.primitives`, call Handler, encode the result via
//! `lspkit.editing` and hand the lsp-kit `*.Result` shape to lsp-kit's
//! response writer.

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");
const lspkit = @import("lspkit");
const codec = lspkit.primitives;
const editing_codec = lspkit.editing;

pub fn handleCompletion(
    h: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.completion.Params,
) ?lsp.types.completion.Result {
    const items = h.computeCompletion(
        params.textDocument.uri,
        codec.fromLspKitPosition(params.position),
    ) catch return null;
    defer h.gpa.free(items);
    if (items.len == 0) return null;
    const lsp_items = editing_codec.toLspKitCompletionItems(arena, items) catch return null;
    return .{ .completion_items = lsp_items };
}

pub fn handleSignatureHelp(
    h: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.SignatureHelp.Params,
) ?lsp.types.SignatureHelp {
    const result = h.computeSignatureHelp(
        params.textDocument.uri,
        codec.fromLspKitPosition(params.position),
    ) catch return null;
    const r = result orelse return null;
    return editing_codec.toLspKitSignatureHelp(arena, r) catch null;
}

pub fn handleFoldingRange(
    h: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.FoldingRange.Params,
) ?[]const lsp.types.FoldingRange {
    const ranges = h.computeFoldingRanges(params.textDocument.uri) catch return null;
    defer h.gpa.free(ranges);
    if (ranges.len == 0) return null;
    return editing_codec.toLspKitFoldingRanges(arena, ranges) catch null;
}

pub fn handleInlayHint(
    h: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.InlayHint.Params,
) ?[]const lsp.types.InlayHint {
    const hints = h.computeInlayHints(
        params.textDocument.uri,
        codec.fromLspKitRange(params.range),
    ) catch return null;
    defer h.gpa.free(hints);
    if (hints.len == 0) return null;
    return editing_codec.toLspKitInlayHints(arena, params.textDocument.uri, hints) catch null;
}

pub fn handleCodeLens(
    h: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.code_lens.Params,
) ?[]const lsp.types.code_lens.Response {
    const lenses = h.computeCodeLens(params.textDocument.uri) catch return null;
    defer Handler.freeCodeLens(h.gpa, lenses);
    if (lenses.len == 0) return null;
    return editing_codec.toLspKitCodeLenses(arena, lenses) catch null;
}

pub fn handleSelectionRange(
    h: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.SelectionRange.Params,
) ?[]const lsp.types.SelectionRange {
    if (params.positions.len == 0) return null;
    const results = arena.alloc(lsp.types.SelectionRange, params.positions.len) catch return null;
    for (params.positions, 0..) |pos, i| {
        const sel = h.computeSelectionRange(
            params.textDocument.uri,
            codec.fromLspKitPosition(pos),
        ) catch return null;
        if (sel) |s| {
            results[i] = editing_codec.toLspKitSelectionRange(arena, s) catch return null;
        } else {
            results[i] = editing_codec.lspKitNullSelectionRange();
        }
    }
    return results;
}

pub fn handleSemanticTokensFull(
    h: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.semantic_tokens.Params,
) ?lsp.types.semantic_tokens.Result {
    const data = h.computeSemanticTokens(params.textDocument.uri) catch return null;
    defer h.gpa.free(data);
    if (data.len == 0) return null;
    return editing_codec.toLspKitSemanticTokens(arena, data) catch null;
}

pub fn handleFormatting(
    h: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.document_formatting.Params,
) ?[]const lsp.types.TextEdit {
    const edit = h.computeFormatting(params.textDocument.uri) catch return null;
    const e = edit orelse return null;
    defer h.gpa.free(e.new_text);
    return editing_codec.toLspKitFormattingEdit(arena, e) catch null;
}
