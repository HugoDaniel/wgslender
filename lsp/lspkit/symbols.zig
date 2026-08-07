//! Bridge: `Handler.DocumentSymbolInfo[]` → `lsp.types.DocumentSymbol[]`.
//!
//! Reached as `lspkit.symbols.*` via `lsp/lspkit_root.zig`. Native
//! adapters drive this from `textDocument/documentSymbol`
//! (`native/symbols.zig`). Recursive — `children` follow the same shape.
//! Strings are borrowed from `Handler.DocumentSymbolInfo.name`; the
//! caller must keep that input alive until the response is written.

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");
const primitives = @import("primitives.zig");

/// Map a `Handler.SymbolKind` onto an `lsp.types.SymbolKind`. Mirrors the
/// integer table in `wire/symbols.zig::symbolKindCode` so the two
/// transports cannot drift on the encoding.
pub fn toLspKitSymbolKind(kind: Handler.SymbolKind) lsp.types.SymbolKind {
    return switch (kind) {
        .function => .Function,
        .struct_type => .Struct,
        .variable => .Variable,
        .constant => .Constant,
        .field => .Field,
        .type_alias => .Class,
        .override => .Constant,
    };
}

/// Convert a top-level `DocumentSymbolInfo[]` slice. Each entry, and
/// every descendant via `children`, is allocated on `arena`.
pub fn toLspKitDocumentSymbols(
    arena: std.mem.Allocator,
    syms: []const Handler.DocumentSymbolInfo,
) std.mem.Allocator.Error![]lsp.types.DocumentSymbol {
    const out = try arena.alloc(lsp.types.DocumentSymbol, syms.len);
    for (syms, 0..) |sym, i| out[i] = try toLspKitDocumentSymbol(arena, sym);
    return out;
}

/// Convert a single `DocumentSymbolInfo` (recursing into `children`).
pub fn toLspKitDocumentSymbol(
    arena: std.mem.Allocator,
    sym: Handler.DocumentSymbolInfo,
) std.mem.Allocator.Error!lsp.types.DocumentSymbol {
    var children: ?[]const lsp.types.DocumentSymbol = null;
    if (sym.children.len > 0) {
        children = try toLspKitDocumentSymbols(arena, sym.children);
    }
    return .{
        .name = sym.name,
        .kind = toLspKitSymbolKind(sym.kind),
        .range = primitives.toLspKitRange(sym.range),
        .selectionRange = primitives.toLspKitRange(sym.selection_range),
        .children = children,
    };
}

/// Convert a `Handler.WorkspaceSymbolInfo[]` slice for a
/// `workspace/symbol` response. Allocated on `arena`; strings are
/// borrowed from the input (same contract as document symbols).
pub fn toLspKitWorkspaceSymbols(
    arena: std.mem.Allocator,
    syms: []const Handler.WorkspaceSymbolInfo,
) std.mem.Allocator.Error![]lsp.types.workspace.Symbol {
    const out = try arena.alloc(lsp.types.workspace.Symbol, syms.len);
    for (syms, 0..) |sym, i| {
        out[i] = .{
            .location = .{ .location = .{
                .uri = sym.uri,
                .range = primitives.toLspKitRange(sym.range),
            } },
            .name = sym.name,
            .kind = toLspKitSymbolKind(sym.kind),
            .containerName = if (sym.container_name.len > 0) sym.container_name else null,
        };
    }
    return out;
}

// =========================================================================
// Tests
// =========================================================================

const testing = std.testing;

const sample_range: Handler.Range = .{
    .start = .{ .line = 1, .character = 2 },
    .end = .{ .line = 3, .character = 4 },
};
const sample_sel: Handler.Range = .{
    .start = .{ .line = 1, .character = 3 },
    .end = .{ .line = 1, .character = 5 },
};

test "toLspKitDocumentSymbol: leaf, no children" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const out = try toLspKitDocumentSymbol(aa, .{
        .name = "main",
        .kind = .function,
        .range = sample_range,
        .selection_range = sample_sel,
        .children = &.{},
    });
    try testing.expectEqualStrings("main", out.name);
    try testing.expectEqual(lsp.types.SymbolKind.Function, out.kind);
    try testing.expect(out.children == null);
}

test "toLspKitDocumentSymbol: struct with field children" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const fields = [_]Handler.DocumentSymbolInfo{
        .{ .name = "a", .kind = .field, .range = sample_range, .selection_range = sample_sel, .children = &.{} },
        .{ .name = "b", .kind = .field, .range = sample_range, .selection_range = sample_sel, .children = &.{} },
    };
    const out = try toLspKitDocumentSymbol(aa, .{
        .name = "S",
        .kind = .struct_type,
        .range = sample_range,
        .selection_range = sample_sel,
        .children = &fields,
    });

    try testing.expectEqual(lsp.types.SymbolKind.Struct, out.kind);
    const ch = out.children.?;
    try testing.expectEqual(@as(usize, 2), ch.len);
    try testing.expectEqual(lsp.types.SymbolKind.Field, ch[0].kind);
    try testing.expectEqualStrings("a", ch[0].name);
}

test "toLspKitSymbolKind: every variant is mapped" {
    try testing.expectEqual(lsp.types.SymbolKind.Function, toLspKitSymbolKind(.function));
    try testing.expectEqual(lsp.types.SymbolKind.Struct, toLspKitSymbolKind(.struct_type));
    try testing.expectEqual(lsp.types.SymbolKind.Variable, toLspKitSymbolKind(.variable));
    try testing.expectEqual(lsp.types.SymbolKind.Constant, toLspKitSymbolKind(.constant));
    try testing.expectEqual(lsp.types.SymbolKind.Field, toLspKitSymbolKind(.field));
    try testing.expectEqual(lsp.types.SymbolKind.Class, toLspKitSymbolKind(.type_alias));
    try testing.expectEqual(lsp.types.SymbolKind.Constant, toLspKitSymbolKind(.override));
}
