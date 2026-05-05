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
        .range = primitives.toLspKitRange(result.range),
    };
}

/// Build a single-Location `Definition.Result`. Used by both
/// `textDocument/definition` and `textDocument/typeDefinition` since
/// they share the same response type.
pub fn toLspKitDefinitionLocation(uri: []const u8, range: Handler.Range) lsp.types.Definition.Result {
    return .{
        .definition = .{
            .location = .{
                .uri = uri,
                .range = primitives.toLspKitRange(range),
            },
        },
    };
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
