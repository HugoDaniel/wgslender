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
    arena: std.mem.Allocator,
    params: lsp.types.Definition.Params,
) ?lsp.types.Definition.Result {
    const locations = h.computeDefinition(
        params.textDocument.uri,
        codec.fromLspKitPosition(params.position),
    ) catch return null;
    const list = locations orelse return null;
    defer h.freeDefinitionLocations(list);
    const owned = copyLocations(arena, list) catch return null;
    return nav.toLspKitDefinitionWithUris(arena, owned) catch null;
}

/// WGSL has no forward declarations, so a symbol's declaration IS its
/// definition — `textDocument/declaration` answers exactly what
/// `textDocument/definition` answers.
pub fn handleDeclaration(
    h: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.declaration.Params,
) ?lsp.types.Definition.Result {
    return handleDefinition(h, arena, .{
        .textDocument = params.textDocument,
        .position = params.position,
    });
}

pub fn handleTypeDefinition(
    h: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.type_definition.Params,
) ?lsp.types.Definition.Result {
    const locations = h.computeTypeDefinition(
        params.textDocument.uri,
        codec.fromLspKitPosition(params.position),
    ) catch return null;
    const list = locations orelse return null;
    defer h.freeDefinitionLocations(list);
    const owned = copyLocations(arena, list) catch return null;
    return nav.toLspKitDefinitionWithUris(arena, owned) catch null;
}

/// The lsp-kit definition shape borrows its URI strings, so move them onto
/// the response arena before the Handler-owned result is released.
fn copyLocations(arena: std.mem.Allocator, locations: []const Handler.Location) ![]Handler.Location {
    const owned = try arena.alloc(Handler.Location, locations.len);
    for (locations, 0..) |location, i| {
        owned[i] = .{
            .uri = try arena.dupe(u8, location.uri),
            .range = location.range,
        };
    }
    return owned;
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
    defer h.freeReferences(handler_refs);

    // Inline `:code` origins have no file URI (the virtual document layer
    // is a later task); omit them rather than fabricating a path. Every
    // remaining entry carries its own author document URI, and the URI
    // string moves onto the response arena because the codec borrows it.
    const locations = arena.alloc(Handler.Location, handler_refs.len) catch return null;
    var count: usize = 0;
    for (handler_refs) |ref| {
        const uri = ref.uri orelse continue;
        const owned_uri = arena.dupe(u8, uri) catch return null;
        locations[count] = .{ .uri = owned_uri, .range = ref.range };
        count += 1;
    }
    return nav.toLspKitLocationsWithUris(arena, locations[0..count]) catch null;
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
