//! Native navigation adapters: hover, definition, typeDefinition,
//! references, documentHighlight. Lock/unlock stays in NativeServer.

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");
const codec = @import("codec");

pub fn handleHover(
    h: *Handler,
    params: lsp.types.Hover.Params,
) ?lsp.types.Hover {
    const result = h.computeHover(
        params.textDocument.uri,
        codec.fromLspKitPosition(params.position),
    ) catch return null;
    const r = result orelse return null;
    return .{
        .contents = .{ .markup_content = .{ .kind = .markdown, .value = r.contents } },
        .range = codec.toLspKitRange(r.range),
    };
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
    return .{
        .definition = .{
            .location = .{
                .uri = params.textDocument.uri,
                .range = codec.toLspKitRange(r),
            },
        },
    };
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
    return .{
        .definition = .{
            .location = .{
                .uri = params.textDocument.uri,
                .range = codec.toLspKitRange(r),
            },
        },
    };
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
    const locations = arena.alloc(lsp.types.Location, handler_refs.len) catch return null;
    for (handler_refs, 0..) |ref, i| {
        locations[i] = .{
            .uri = params.textDocument.uri,
            .range = codec.toLspKitRange(ref),
        };
    }
    return locations;
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
    const result = arena.alloc(lsp.types.DocumentHighlight, handler_highlights.len) catch return null;
    for (handler_highlights, 0..) |hl, i| {
        result[i] = .{
            .range = codec.toLspKitRange(hl.range),
            .kind = switch (hl.kind) {
                .text => .Text,
                .read => .Read,
                .write => .Write,
            },
        };
    }
    return result;
}
