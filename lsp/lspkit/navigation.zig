//! Bridge: `Handler.HoverResult` / `Range` (Location) /
//! `DocumentHighlight` ↔ `lsp.types.Hover` / `lsp.types.Location` /
//! `lsp.types.DocumentHighlight`.
//!
//! Reached as `lspkit.navigation.*` via `lsp/lspkit_root.zig`.

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");
const primitives = @import("primitives.zig");

/// Build the lsp-kit `Hover` payload returned by `textDocument/hover`.
/// `result.contents` is borrowed — the caller (`native/navigation.zig`)
/// frees it after the response writes.
pub fn toLspKitHover(result: Handler.HoverResult) lsp.types.Hover {
    return .{
        .contents = .{ .markup_content = .{ .kind = .markdown, .value = result.contents } },
        .range = if (result.range) |range| primitives.toLspKitRange(range) else null,
    };
}

/// Build a single-Location `Definition.Result`. Used by both
/// `textDocument/definition` and `textDocument/typeDefinition` since
/// they share the same response type.
pub fn toLspKitDefinitionLocation(uri: []const u8, range: Handler.Range) lsp.types.Definition.Result {
    return toLspKitDefinitionAt(.{ .uri = uri, .range = range });
}

/// Build a single-Location `Definition.Result` from an origin-aware
/// `Handler.Location`. This is the phase-04 shape: the URI travels with the
/// range instead of being taken from the request document.
pub fn toLspKitDefinitionAt(location: Handler.Location) lsp.types.Definition.Result {
    return .{
        .definition = .{
            .location = .{
                .uri = location.uri,
                .range = primitives.toLspKitRange(location.range),
            },
        },
    };
}

/// Build a `Definition.Result` from origin-aware locations. One location
/// keeps the legacy single-object shape; two or more become the LSP
/// `Location[]` form, each carrying its own URI.
pub fn toLspKitDefinitionWithUris(
    arena: std.mem.Allocator,
    locations: []const Handler.Location,
) !lsp.types.Definition.Result {
    if (locations.len == 1) return toLspKitDefinitionAt(locations[0]);
    return .{ .definition = .{ .locations = try toLspKitLocationsWithUris(arena, locations) } };
}

/// Allocate `[]lsp.types.Location` on `arena` from a Handler reference
/// list. Borrows `uri` (the caller keeps `params.textDocument.uri`
/// alive for the duration of the response).
pub fn toLspKitLocations(
    arena: std.mem.Allocator,
    uri: []const u8,
    refs: []const Handler.Range,
) ![]lsp.types.Location {
    const locations = try arena.alloc(lsp.types.Location, refs.len);
    for (refs, 0..) |ref, i| {
        locations[i] = .{
            .uri = uri,
            .range = primitives.toLspKitRange(ref),
        };
    }
    return locations;
}

/// Allocate `[]lsp.types.Location` on `arena` from origin-aware Handler
/// locations. Every entry keeps its own URI; strings are borrowed from the
/// input.
pub fn toLspKitLocationsWithUris(
    arena: std.mem.Allocator,
    locations: []const Handler.Location,
) ![]lsp.types.Location {
    const out = try arena.alloc(lsp.types.Location, locations.len);
    for (locations, 0..) |location, i| {
        out[i] = .{
            .uri = location.uri,
            .range = primitives.toLspKitRange(location.range),
        };
    }
    return out;
}

/// Allocate `[]lsp.types.DocumentHighlight` on `arena`.
pub fn toLspKitDocumentHighlights(
    arena: std.mem.Allocator,
    highlights: []const Handler.DocumentHighlight,
) ![]lsp.types.DocumentHighlight {
    const result = try arena.alloc(lsp.types.DocumentHighlight, highlights.len);
    for (highlights, 0..) |hl, i| {
        result[i] = .{
            .range = primitives.toLspKitRange(hl.range),
            .kind = switch (hl.kind) {
                .text => .Text,
                .read => .Read,
                .write => .Write,
            },
        };
    }
    return result;
}
