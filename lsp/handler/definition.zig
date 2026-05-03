//! Go-to-Definition + Go-to-Type-Definition: resolve a cursor position
//! to the source range of either the bound symbol's declaration
//! (`computeDefinition`) or — for symbols whose type is a user struct —
//! the struct declaration (`computeTypeDefinition`).

const std = @import("std");
const wgslender = @import("wgslender");

const Handler = @import("../Handler.zig");
const NodeAtOffset = @import("node_at_offset.zig");
const NodeAtPosition = NodeAtOffset.NodeAtPosition;
const Position = Handler.Position;
const Range = Handler.Range;
const Ast = wgslender.Ast;

pub fn computeDefinition(handler: *Handler, uri: []const u8, position: Position) !?Range {
    const doc = handler.documents.getPtr(uri) orelse return null;
    const source = doc.source;
    const offset: u32 = @intCast(Handler.lspPositionToOffset(source, position) orelse return null);
    const analysis = try handler.analyzeDocument(uri);
    const module = analysis.module orelse return null;

    const node = NodeAtOffset.find(module, offset);
    return symbolToRange(module, source, nodeSymbolIndex(node));
}

pub fn computeTypeDefinition(handler: *Handler, uri: []const u8, position: Position) !?Range {
    const doc = handler.documents.getPtr(uri) orelse return null;
    const source = doc.source;
    const offset: u32 = @intCast(Handler.lspPositionToOffset(source, position) orelse return null);
    const analysis = try handler.analyzeDocument(uri);
    const module = analysis.module orelse return null;

    const node = NodeAtOffset.find(module, offset);
    const sym_idx: Ast.SymbolIndex = switch (node) {
        .ident => |id| id.ref,
        .decl_name => |dn| dn.sym_idx,
        else => return null,
    };
    if (!sym_idx.isValid()) return null;

    // Get the resolved type of this symbol
    const typ = analysis.symbol_types.get(sym_idx.index()) orelse return null;
    switch (typ) {
        .@"struct" => |st| {
            // Find the struct declaration in module
            for (module.declarations.items) |decl| {
                switch (decl) {
                    .@"struct" => |sd| {
                        if (!sd.name.isValid()) continue;
                        const sym = module.symbols.items[sd.name.index()];
                        if (std.mem.eql(u8, sym.original_name, st.name)) {
                            return Handler.offsetRangeToLspRange(source, sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len)));
                        }
                    },
                    else => {},
                }
            }
        },
        else => {},
    }
    return null;
}

fn nodeSymbolIndex(node: NodeAtPosition) Ast.SymbolIndex {
    return switch (node) {
        .ident => |id| id.ref,
        .type_ref => |tr| tr.ref,
        .decl_name => |dn| dn.sym_idx,
        .member_access => |ma| ma.ref,
        .binary_expr, .none => .none,
    };
}

fn symbolToRange(module: *const Ast.Module, source: []const u8, ref: Ast.SymbolIndex) ?Range {
    if (!ref.isValid()) return null;
    const sym = module.symbols.items[ref.index()];
    return Handler.offsetRangeToLspRange(source, sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len)));
}
