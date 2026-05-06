//! References, Document Highlight, and Rename: all three resolve a
//! cursor to a `SymbolIndex` and walk every reference in the module.
//! References + Highlight return ranges; Rename produces text edits.

const std = @import("std");
const wgslender = @import("wgslender");

const Handler = @import("../Handler.zig");
const NodeAtOffset = @import("node_at_offset.zig");
const Position = Handler.Position;
const Range = Handler.Range;
const DocumentHighlight = Handler.DocumentHighlight;
const LspTextEdit = Handler.LspTextEdit;
const Ast = wgslender.Ast;
const Edits = wgslender.Edits;

pub const isValidWgslIdentifier = Edits.isValidWgslIdentifier;

pub fn computeReferences(handler: *Handler, uri: []const u8, position: Position, include_declaration: bool) !?[]Range {
    const doc = handler.documents.getPtr(uri) orelse return null;
    const source = doc.source;
    const offset: u32 = @intCast(Handler.lspPositionToOffset(source, position) orelse return null);
    const analysis = try handler.analyzeDocument(uri);
    const module = analysis.module orelse return null;

    const node = NodeAtOffset.find(module, offset);
    const target: Ast.SymbolIndex = switch (node) {
        .ident => |id| id.ref,
        .decl_name => |dn| dn.sym_idx,
        .type_ref => |tr| tr.ref,
        else => return null,
    };
    if (!target.isValid()) return null;

    const refs = try Edits.findReferences(handler.gpa, module, target, include_declaration);
    defer handler.gpa.free(refs);

    var ranges: std.ArrayList(Range) = .empty;
    defer ranges.deinit(handler.gpa);
    try ranges.ensureTotalCapacity(handler.gpa, refs.len);
    for (refs) |r| {
        if (Handler.offsetRangeToLspRange(source, r.start, r.end)) |range| {
            ranges.appendAssumeCapacity(range);
        }
    }
    return try handler.gpa.dupe(Range, ranges.items);
}

pub fn computeDocumentHighlight(handler: *Handler, uri: []const u8, position: Position) !?[]DocumentHighlight {
    const doc = handler.documents.getPtr(uri) orelse return null;
    const source = doc.source;
    const offset: u32 = @intCast(Handler.lspPositionToOffset(source, position) orelse return null);
    const analysis = try handler.analyzeDocument(uri);
    const module = analysis.module orelse return null;

    const node = NodeAtOffset.find(module, offset);
    const target: Ast.SymbolIndex = switch (node) {
        .ident => |id| id.ref,
        .decl_name => |dn| dn.sym_idx,
        .type_ref => |tr| tr.ref,
        else => return null,
    };
    if (!target.isValid()) return null;

    const refs = try Edits.findReferences(handler.gpa, module, target, true);
    defer handler.gpa.free(refs);

    var highlights: std.ArrayList(DocumentHighlight) = .empty;
    defer highlights.deinit(handler.gpa);
    try highlights.ensureTotalCapacity(handler.gpa, refs.len);
    for (refs) |r| {
        if (Handler.offsetRangeToLspRange(source, r.start, r.end)) |range| {
            highlights.appendAssumeCapacity(.{
                .range = range,
                .kind = if (r.is_write) .write else .read,
            });
        }
    }
    return try handler.gpa.dupe(DocumentHighlight, highlights.items);
}

pub fn prepareRename(handler: *Handler, uri: []const u8, position: Position) !?Range {
    const doc = handler.documents.getPtr(uri) orelse return null;
    const source = doc.source;
    const offset: u32 = @intCast(Handler.lspPositionToOffset(source, position) orelse return null);
    const analysis = try handler.analyzeDocument(uri);
    const module = analysis.module orelse return null;

    const node = NodeAtOffset.find(module, offset);
    switch (node) {
        .ident => |id| {
            if (!id.ref.isValid()) return null;
            const sym = module.symbols.items[id.ref.index()];
            if (sym.flags.is_builtin) return null;
            return Handler.offsetRangeToLspRange(source, id.loc, id.loc + @as(u32, @intCast(id.name.len)));
        },
        .decl_name => |dn| {
            if (!dn.sym_idx.isValid()) return null;
            const sym = module.symbols.items[dn.sym_idx.index()];
            if (sym.flags.is_builtin) return null;
            return Handler.offsetRangeToLspRange(source, dn.loc, dn.loc + @as(u32, @intCast(sym.original_name.len)));
        },
        .type_ref => |tr| {
            if (!tr.ref.isValid()) return null;
            const sym = module.symbols.items[tr.ref.index()];
            if (sym.flags.is_builtin) return null;
            return Handler.offsetRangeToLspRange(source, tr.loc, tr.loc + @as(u32, @intCast(tr.name.len)));
        },
        else => return null,
    }
}

pub fn computeRename(handler: *Handler, uri: []const u8, position: Position, new_name: []const u8) !?[]LspTextEdit {
    if (!isValidWgslIdentifier(new_name)) return null;

    const refs = (try computeReferences(handler, uri, position, true)) orelse return null;
    defer handler.gpa.free(refs);

    if (refs.len == 0) return null;

    const edits = try handler.gpa.alloc(LspTextEdit, refs.len);
    for (refs, 0..) |ref_range, i| {
        edits[i] = .{
            .range = ref_range,
            .new_text = new_name,
        };
    }
    return edits;
}
