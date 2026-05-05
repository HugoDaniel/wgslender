//! Native document-sync adapters. Each `handle*` does the lsp-kit-
//! notification ↔ Handler-call conversion only — the NativeServer
//! wrapper owns lock/unlock and publish/debouncer side-effects.

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");

pub fn handleDidOpen(
    h: *Handler,
    notification: lsp.types.TextDocument.DidOpenParams,
) !void {
    try h.openDocument(
        notification.textDocument.uri,
        notification.textDocument.text,
        notification.textDocument.version,
    );
}

pub fn handleDidChange(
    h: *Handler,
    notification: lsp.types.TextDocument.DidChangeParams,
) !void {
    const uri = notification.textDocument.uri;
    for (notification.contentChanges) |change| {
        switch (change) {
            .text_document_content_change_whole_document => |full| {
                try h.changeDocument(uri, full.text);
            },
            .text_document_content_change_partial => |partial| {
                try h.changeDocumentIncremental(uri, .{
                    .start = .{ .line = partial.range.start.line, .character = partial.range.start.character },
                    .end = .{ .line = partial.range.end.line, .character = partial.range.end.character },
                }, partial.text);
            },
        }
    }
}

pub fn handleDidSave(
    h: *Handler,
    notification: lsp.types.TextDocument.DidSaveParams,
) void {
    h.handleDidSave(notification.textDocument.uri);
}

pub fn handleDidClose(
    h: *Handler,
    notification: lsp.types.TextDocument.DidCloseParams,
) void {
    h.closeDocument(notification.textDocument.uri);
}
