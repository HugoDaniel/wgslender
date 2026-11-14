//! Go-to-Definition + Go-to-Type-Definition: resolve a cursor position to
//! the declaration's own document URI and range, in every root that contains
//! the requested file.
//!
//! The request position is author-local; `NodeAtOffset` is always queried at
//! the assembled offset `contextsAt` mapped it to. A declaration is projected
//! back through the same root's `Assembled`, so an inline `:code` target
//! lands on its stable virtual document URI and never on an assembled range.
//! Reaching one declaration through several roots yields one `(URI, range)`
//! entry; genuinely distinct root resolutions yield all of them.

const std = @import("std");
const wgslender = @import("wgslender");

const Handler = @import("../Handler.zig");
const PngineContext = @import("pngine_context.zig");
const NodeAtOffset = @import("node_at_offset.zig");
const NodeAtPosition = NodeAtOffset.NodeAtPosition;
const Position = Handler.Position;
const Location = Handler.Location;
const Ast = wgslender.Ast;

/// One document-and-range result per distinct declaration. `null` means the
/// request has no symbol declaration to navigate to. The caller owns the
/// slice and its URIs; release them with `freeLocations`.
pub fn computeDefinition(handler: *Handler, uri: []const u8, position: Position) !?[]Location {
    const contexts = try Handler.contextsAt(handler, uri, position);
    defer Handler.freeContexts(handler, contexts);
    return locationsForContexts(handler, contexts, .definition);
}

/// Type definition follows the same context and location path as
/// definition. It resolves the cursor symbol's validator type, then finds
/// the struct declaration in whichever part holds it.
pub fn computeTypeDefinition(handler: *Handler, uri: []const u8, position: Position) !?[]Location {
    const contexts = try Handler.contextsAt(handler, uri, position);
    defer Handler.freeContexts(handler, contexts);
    return locationsForContexts(handler, contexts, .type_definition);
}

/// Release a slice returned by `computeDefinition` or
/// `computeTypeDefinition`, including every URI it owns.
pub fn freeLocations(handler: *Handler, locations: []Location) void {
    for (locations) |location| handler.gpa.free(location.uri);
    handler.gpa.free(locations);
}

const RequestedKind = enum {
    definition,
    type_definition,
};

fn locationsForContexts(
    handler: *Handler,
    contexts: []Handler.RequestContext,
    kind: RequestedKind,
) !?[]Location {
    var out: std.ArrayList(Location) = .empty;
    errdefer {
        for (out.items) |location| handler.gpa.free(location.uri);
        out.deinit(handler.gpa);
    }

    for (contexts) |*context| {
        const analysis = PngineContext.analysisFor(handler, context) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        const module = analysis.module orelse continue;
        const node = NodeAtOffset.find(module, context.assembled_offset);

        switch (kind) {
            .definition => {
                const sym_idx = nodeSymbolIndex(node) orelse continue;
                if (!sym_idx.isValid()) continue;
                if (try locationForSymbol(handler, context, module, sym_idx)) |location| {
                    try appendUnique(handler, &out, location);
                }
            },
            .type_definition => {
                const sym_idx: Ast.SymbolIndex = switch (node) {
                    .ident => |id| id.ref,
                    .decl_name => |dn| dn.sym_idx,
                    else => continue,
                };
                if (!sym_idx.isValid()) continue;

                const typ = analysis.symbol_types.get(sym_idx.index()) orelse continue;
                switch (typ) {
                    .@"struct" => |st| {
                        for (module.declarations.items) |decl| {
                            switch (decl) {
                                .@"struct" => |sd| {
                                    if (!sd.name.isValid()) continue;
                                    const sym = module.symbols.items[sd.name.index()];
                                    if (!std.mem.eql(u8, sym.original_name, st.name)) continue;
                                    if (try locationForSymbol(handler, context, module, sd.name)) |location| {
                                        try appendUnique(handler, &out, location);
                                    }
                                    break;
                                },
                                else => {},
                            }
                        }
                    },
                    else => {},
                }
            },
        }
    }

    if (out.items.len == 0) {
        out.deinit(handler.gpa);
        return null;
    }
    return try out.toOwnedSlice(handler.gpa);
}

/// The declaration location of `sym_idx` in `context`'s root. Standalone
/// documents stay on their own text; a composed symbol is mapped through
/// `declarationKey`, and each target gets its own URI — a sibling file's
/// canonical spelling or an inline part's virtual document.
fn locationForSymbol(
    handler: *Handler,
    context: *const Handler.RequestContext,
    module: *const Ast.Module,
    sym_idx: Ast.SymbolIndex,
) !?Location {
    if (!sym_idx.isValid()) return null;
    const sym = module.symbols.items[sym_idx.index()];
    if (sym.flags.is_retired) return null;
    const name_len: u32 = @intCast(sym.original_name.len);

    if (!context.isComposed()) {
        const request_uri = context.request_uri orelse return null;
        const uri = try handler.gpa.dupe(u8, request_uri);
        errdefer handler.gpa.free(uri);

        var text = try PngineContext.authorText(handler, context);
        defer text.deinit(handler.gpa);
        const range = Handler.offsetRangeToLspRange(text.text, sym.loc, sym.loc + name_len) orelse
            return null;
        return .{ .uri = uri, .range = range };
    }

    const key = Handler.declarationKey(context, sym_idx) orelse return null;
    const uri = (try uriForOrigin(handler, context, key.origin)) orelse return null;
    errdefer handler.gpa.free(uri);

    var text = try PngineContext.originText(handler, key.origin);
    defer text.deinit(handler.gpa);
    const range = Handler.offsetRangeToLspRange(
        text.text,
        key.declaration_range.start,
        key.declaration_range.end,
    ) orelse return null;
    return .{ .uri = uri, .range = range };
}

/// A result in the request's own document keeps the client's URI spelling;
/// a sibling target uses the part's canonical file URI.
fn uriForOrigin(
    handler: *Handler,
    context: *const Handler.RequestContext,
    origin: Handler.PngineContext.OriginKey,
) !?[]u8 {
    if (context.request_uri) |request_uri| {
        if (context.origin) |request_origin| {
            if (request_origin.program == origin.program and request_origin.index == origin.index) {
                return try handler.gpa.dupe(u8, request_uri);
            }
        }
    }
    return try Handler.originUri(handler, handler.gpa, origin);
}

fn appendUnique(handler: *Handler, out: *std.ArrayList(Location), location: Location) !void {
    for (out.items) |existing| {
        if (!std.mem.eql(u8, existing.uri, location.uri)) continue;
        if (!std.meta.eql(existing.range, location.range)) continue;
        handler.gpa.free(location.uri);
        return;
    }
    errdefer handler.gpa.free(location.uri);
    try out.append(handler.gpa, location);
}

fn nodeSymbolIndex(node: NodeAtPosition) ?Ast.SymbolIndex {
    return switch (node) {
        .ident => |id| id.ref,
        .type_ref => |tr| tr.ref,
        .decl_name => |dn| dn.sym_idx,
        .member_access => |ma| ma.ref,
        .binary_expr, .none => null,
    };
}
