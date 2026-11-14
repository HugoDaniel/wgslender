//! References, Document Highlight, and Rename: resolve the cursor to a
//! declaration identity and project every bound reference back to its
//! author document. The collection itself lives in `pngine_symbols.zig`;
//! these wrappers are the Handler's public, graph-independent names.

const std = @import("std");
const wgslender = @import("wgslender");

const Handler = @import("../Handler.zig");
const PngineSymbols = @import("pngine_symbols.zig");

const Position = Handler.Position;
const Range = Handler.Range;
const DocumentHighlight = Handler.DocumentHighlight;
const WorkspaceChanges = Handler.WorkspaceChanges;
const Edits = wgslender.Edits;

pub const ReferenceLocation = PngineSymbols.ReferenceLocation;

pub const isValidWgslIdentifier = Edits.isValidWgslIdentifier;

/// Every reference bound to the declaration selected at `position`, in
/// every containing root, each with its own author URI and range. Inline
/// `:code` references carry `uri == null`; the adapters filter them.
pub fn computeReferences(
    handler: *Handler,
    uri: []const u8,
    position: Position,
    include_declaration: bool,
) !?[]ReferenceLocation {
    return PngineSymbols.references(handler, uri, position, include_declaration);
}

/// Release a slice returned by `computeReferences`.
pub fn freeReferences(handler: *Handler, refs: []ReferenceLocation) void {
    PngineSymbols.freeReferences(handler, refs);
}

/// The reference set filtered to the requested author document, keeping
/// the declaration/assignment read/write classification.
pub fn computeDocumentHighlight(
    handler: *Handler,
    uri: []const u8,
    position: Position,
) !?[]DocumentHighlight {
    return PngineSymbols.highlights(handler, uri, position);
}

/// The token range in the requested document when the rename is safe: one
/// declared identity across roots and no edit that would write inline text.
pub fn prepareRename(handler: *Handler, uri: []const u8, position: Position) !?Range {
    return PngineSymbols.prepareRename(handler, uri, position);
}

/// A multi-file `WorkspaceEdit.changes` payload. A standalone document
/// still yields exactly one document; an ambiguous or inline-crossing
/// rename returns `null` with no partial edits.
pub fn computeRename(
    handler: *Handler,
    uri: []const u8,
    position: Position,
    new_name: []const u8,
) !?WorkspaceChanges {
    return PngineSymbols.rename(handler, uri, position, new_name);
}

/// Release a value returned by `computeRename`.
pub fn freeWorkspaceChanges(handler: *Handler, changes: WorkspaceChanges) void {
    PngineSymbols.freeWorkspaceChanges(handler, changes);
}
