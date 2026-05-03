//! Document Symbols: produce the document outline (functions, structs,
//! globals, with struct fields as children).

const std = @import("std");
const wgslender = @import("wgslender");

const Handler = @import("../Handler.zig");
const Range = Handler.Range;

pub const DocumentSymbolInfo = struct {
    name: []const u8,
    kind: SymbolKind,
    range: Range,
    selection_range: Range,
    children: []const DocumentSymbolInfo,
};

pub const SymbolKind = enum(u8) {
    function,
    struct_type,
    variable,
    constant,
    field,
    type_alias,
    override,
};

pub fn computeDocumentSymbols(handler: *Handler, uri: []const u8) ![]DocumentSymbolInfo {
    const analysis = handler.analyzeDocument(uri) catch return &.{};
    const module = analysis.module orelse return &.{};
    const source = module.source;

    var symbols: std.ArrayListUnmanaged(DocumentSymbolInfo) = .empty;
    defer symbols.deinit(handler.gpa);

    for (module.declarations.items, 0..) |decl, di| {
        const name_ref = decl.nameRef();
        if (!name_ref.isValid()) continue;
        const sym = module.symbols.items[name_ref.index()];

        const kind: SymbolKind = switch (decl) {
            .function => .function,
            .@"struct" => .struct_type,
            .@"var" => .variable,
            .@"const" => .constant,
            .let => .constant,
            .override => .override,
            .alias => .type_alias,
            .const_assert => continue,
        };

        // Selection range = the name identifier
        const sel_range = Handler.offsetRangeToLspRange(source, sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len))) orelse continue;

        // Enclosing range: from this decl's name to next decl's name (or EOF)
        const range_end: u32 = if (di + 1 < module.declarations.items.len) blk: {
            const next_ref = module.declarations.items[di + 1].nameRef();
            if (next_ref.isValid()) break :blk module.symbols.items[next_ref.index()].loc;
            break :blk @as(u32, @intCast(source.len));
        } else @as(u32, @intCast(source.len));
        const range = Handler.offsetRangeToLspRange(source, sym.loc, range_end) orelse continue;

        // Children for structs
        var children: []const DocumentSymbolInfo = &.{};
        if (decl == .@"struct") {
            const st = decl.@"struct";
            var ch: std.ArrayListUnmanaged(DocumentSymbolInfo) = .empty;
            for (st.members.items) |member| {
                if (!member.name.isValid()) continue;
                const m_sym = module.symbols.items[member.name.index()];
                const m_sel = Handler.offsetRangeToLspRange(source, m_sym.loc, m_sym.loc + @as(u32, @intCast(m_sym.original_name.len))) orelse continue;
                ch.append(handler.gpa, .{
                    .name = m_sym.original_name,
                    .kind = .field,
                    .range = m_sel,
                    .selection_range = m_sel,
                    .children = &.{},
                }) catch continue;
            }
            children = ch.toOwnedSlice(handler.gpa) catch &.{};
        }

        try symbols.append(handler.gpa, .{
            .name = sym.original_name,
            .kind = kind,
            .range = range,
            .selection_range = sel_range,
            .children = children,
        });
    }

    return try handler.gpa.dupe(DocumentSymbolInfo, symbols.items);
}
