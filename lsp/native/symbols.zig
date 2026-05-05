//! Native symbol adapters: rename, prepareRename, documentSymbol.

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");
const codec = @import("codec");

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
    const text_edits = arena.alloc(lsp.types.TextEdit, handler_edits.len) catch return null;
    for (handler_edits, 0..) |edit, i| {
        text_edits[i] = .{
            .range = codec.toLspKitRange(edit.range),
            .newText = edit.new_text,
        };
    }
    var changes = std.json.ArrayHashMap([]const lsp.types.TextEdit){};
    changes.map.put(arena, params.textDocument.uri, text_edits) catch return null;
    return .{ .changes = changes };
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
    const lsp_symbols = arena.alloc(lsp.types.DocumentSymbol, symbols.len) catch return null;
    for (symbols, 0..) |sym, i| {
        lsp_symbols[i] = convertDocSymbol(arena, sym);
    }
    return .{ .document_symbols = lsp_symbols };
}

fn convertDocSymbol(arena: std.mem.Allocator, sym: Handler.DocumentSymbolInfo) lsp.types.DocumentSymbol {
    var children: ?[]const lsp.types.DocumentSymbol = null;
    if (sym.children.len > 0) {
        const ch = arena.alloc(lsp.types.DocumentSymbol, sym.children.len) catch null;
        if (ch) |c| {
            for (sym.children, 0..) |child, ci| {
                c[ci] = convertDocSymbol(arena, child);
            }
            children = c;
        }
    }
    return .{
        .name = sym.name,
        .kind = switch (sym.kind) {
            .function => .Function,
            .struct_type => .Struct,
            .variable => .Variable,
            .constant => .Constant,
            .field => .Field,
            .type_alias => .Class,
            .override => .Constant,
        },
        .range = codec.toLspKitRange(sym.range),
        .selectionRange = codec.toLspKitRange(sym.selection_range),
        .children = children,
    };
}
