//! Native navigation adapters: hover, definition, typeDefinition,
//! references, documentHighlight. Handler call + ownership lives here;
//! shape conversion is delegated to `lspkit/navigation.zig`. Lock /
//! unlock stays in NativeServer.

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");
const lspkit = @import("lspkit");
const codec = lspkit.primitives;
const nav = lspkit.navigation;

pub fn handleHover(
    h: *Handler,
    params: lsp.types.Hover.Params,
) ?lsp.types.Hover {
    const result = h.computeHover(
        params.textDocument.uri,
        codec.fromLspKitPosition(params.position),
    ) catch return null;
    const r = result orelse return null;
    return nav.toLspKitHover(r);
}

pub fn handleDefinition(
    h: *Handler,
    params: lsp.types.Definition.Params,
) ?lsp.types.Definition.Result {
    const range = h.computeDefinition(
        params.textDocument.uri,
        codec.fromLspKitPosition(params.position),
    ) catch return null;
    const r = range orelse return null;
    return nav.toLspKitDefinitionLocation(params.textDocument.uri, r);
}

/// WGSL has no forward declarations, so a symbol's declaration IS its
/// definition — `textDocument/declaration` answers exactly what
/// `textDocument/definition` answers.
pub fn handleDeclaration(
    h: *Handler,
    params: lsp.types.declaration.Params,
) ?lsp.types.Definition.Result {
    return handleDefinition(h, .{
        .textDocument = params.textDocument,
        .position = params.position,
    });
}

pub fn handleTypeDefinition(
    h: *Handler,
    params: lsp.types.type_definition.Params,
) ?lsp.types.Definition.Result {
    const range = h.computeTypeDefinition(
        params.textDocument.uri,
        codec.fromLspKitPosition(params.position),
    ) catch return null;
    const r = range orelse return null;
    return nav.toLspKitDefinitionLocation(params.textDocument.uri, r);
}

pub fn handleReferences(
    h: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.reference.Params,
) ?[]const lsp.types.Location {
    const refs = h.computeReferences(
        params.textDocument.uri,
        codec.fromLspKitPosition(params.position),
        params.context.includeDeclaration,
    ) catch return null;
    const handler_refs = refs orelse return null;
    defer h.gpa.free(handler_refs);
    return nav.toLspKitLocations(arena, params.textDocument.uri, handler_refs) catch null;
}

pub fn handleDocumentHighlight(
    h: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.DocumentHighlight.Params,
) ?[]const lsp.types.DocumentHighlight {
    const highlights = h.computeDocumentHighlight(
        params.textDocument.uri,
        codec.fromLspKitPosition(params.position),
    ) catch return null;
    const handler_highlights = highlights orelse return null;
    defer h.gpa.free(handler_highlights);
    return nav.toLspKitDocumentHighlights(arena, handler_highlights) catch null;
}
