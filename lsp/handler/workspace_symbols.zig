//! Workspace Symbols: the cmd-T "search symbols by name" feature.
//! Collects module-scope declarations (plus struct fields, qualified by
//! their container) from every open document, filtered by the
//! LSP-sanctioned relaxed match — query characters must appear in
//! order, case-insensitively (the spec tells servers NOT to do strict
//! prefix/substring matching; editors apply their own scoring on top).

const std = @import("std");
const wgslender = @import("wgslender");

const Handler = @import("../Handler.zig");
const DocumentSymbols = @import("document_symbols.zig");
const Range = Handler.Range;

pub const WorkspaceSymbolInfo = struct {
    name: []const u8,
    kind: DocumentSymbols.SymbolKind,
    /// Borrowed from the handler's document-store key — valid until the
    /// document closes; serialize before yielding.
    uri: []const u8,
    /// The name identifier's range (not the whole declaration).
    range: Range,
    /// Enclosing struct's name for fields; empty for module-scope decls.
    container_name: []const u8,
};

/// `true` when every character of `query` appears in `name` in order,
/// ignoring ASCII case. The empty query matches everything ("Clients
/// may send an empty string here to request all symbols").
fn matchesQuery(query: []const u8, name: []const u8) bool {
    var qi: usize = 0;
    for (name) |c| {
        if (qi == query.len) break;
        if (std.ascii.toLower(c) == std.ascii.toLower(query[qi])) qi += 1;
    }
    return qi == query.len;
}

fn lessThan(_: void, a: WorkspaceSymbolInfo, b: WorkspaceSymbolInfo) bool {
    switch (std.mem.order(u8, a.uri, b.uri)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    if (a.range.start.line != b.range.start.line)
        return a.range.start.line < b.range.start.line;
    return a.range.start.character < b.range.start.character;
}

/// Collect matching symbols from every open document, sorted by
/// (uri, position) so the response is deterministic across the document
/// store's hash-map iteration order. Caller frees the returned slice
/// with `handler.gpa`; names/uris are borrowed (see `WorkspaceSymbolInfo`).
pub fn computeWorkspaceSymbols(handler: *Handler, query: []const u8) ![]WorkspaceSymbolInfo {
    var symbols: std.ArrayList(WorkspaceSymbolInfo) = .empty;
    defer symbols.deinit(handler.gpa);

    var it = handler.documents.iterator();
    while (it.next()) |entry| {
        try collectFromDocument(handler, entry.key_ptr.*, query, &symbols);
    }

    std.sort.pdq(WorkspaceSymbolInfo, symbols.items, {}, lessThan);
    return try handler.gpa.dupe(WorkspaceSymbolInfo, symbols.items);
}

fn collectFromDocument(
    handler: *Handler,
    uri: []const u8,
    query: []const u8,
    symbols: *std.ArrayList(WorkspaceSymbolInfo),
) !void {
    const analysis = handler.analyzeDocument(uri) catch return;
    const module = analysis.module orelse return;
    const source = module.source;

    // One line index per document: this loop converts one offset per
    // result, and `Handler.offsetRangeToLspRange` scans from byte 0.
    var pm = try Handler.PositionMapper.init(handler.gpa, source);
    defer pm.deinit(handler.gpa);

    for (module.declarations.items) |decl| {
        const name_ref = decl.nameRef();
        if (!name_ref.isValid()) continue;
        const sym = module.symbols.items[name_ref.index()];

        const kind: DocumentSymbols.SymbolKind = switch (decl) {
            .function => .function,
            .@"struct" => .struct_type,
            .@"var" => .variable,
            .@"const" => .constant,
            .let => .constant,
            .override => .override,
            .alias => .type_alias,
            .const_assert => continue,
        };

        if (matchesQuery(query, sym.original_name)) {
            const range = pm.range(sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len))) orelse continue;
            try symbols.append(handler.gpa, .{
                .name = sym.original_name,
                .kind = kind,
                .uri = uri,
                .range = range,
                .container_name = "",
            });
        }

        if (decl == .@"struct") {
            for (decl.@"struct".members.items) |member| {
                if (!member.name.isValid()) continue;
                const m_sym = module.symbols.items[member.name.index()];
                if (!matchesQuery(query, m_sym.original_name)) continue;
                const m_range = pm.range(m_sym.loc, m_sym.loc + @as(u32, @intCast(m_sym.original_name.len))) orelse continue;
                try symbols.append(handler.gpa, .{
                    .name = m_sym.original_name,
                    .kind = .field,
                    .uri = uri,
                    .range = m_range,
                    .container_name = sym.original_name,
                });
            }
        }
    }
}

// =========================================================================
// Tests
// =========================================================================

const testing = std.testing;

test "matchesQuery: empty query matches anything" {
    try testing.expect(matchesQuery("", "anything"));
    try testing.expect(matchesQuery("", ""));
}

test "matchesQuery: in-order subsequence, case-insensitive" {
    try testing.expect(matchesQuery("itg", "integrate"));
    try testing.expect(matchesQuery("ITG", "integrate"));
    try testing.expect(matchesQuery("particle", "Particle"));
    try testing.expect(!matchesQuery("tgi", "integrate"));
    try testing.expect(!matchesQuery("integrated", "integrate"));
    try testing.expect(!matchesQuery("x", ""));
}
