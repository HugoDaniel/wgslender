//! Parity harness for symbols + edits + code_actions: `lspkit/<feature>.zig`
//! (driven by `lsp.writeResponse`) and `wire/<feature>.zig` must produce
//! byte-equivalent JSON for every result shape.
//!
//! Like `lsp_diagnostic_parity_test.zig` and
//! `lsp_navigation_parity_test.zig`, this guards the two transports
//! against drifting on field ordering, kind constants, and the
//! `WorkspaceEdit.changes` map keying.

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");
const lspkit = @import("lspkit");
const wire = @import("wire");
const helpers = @import("lsp_parity_helpers.zig");

const expectEqualJson = helpers.expectEqualJson;
const writeAndParse = helpers.writeAndParseResult;

const test_uri = "test://parity.wgsl";

const sample_range: Handler.Range = .{
    .start = .{ .line = 1, .character = 2 },
    .end = .{ .line = 1, .character = 7 },
};
const sample_sel: Handler.Range = .{
    .start = .{ .line = 1, .character = 3 },
    .end = .{ .line = 1, .character = 5 },
};

// =========================================================================
// WorkspaceEdit (rename)
// =========================================================================

test "parity: WorkspaceEdit — single-URI changes map" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const edits = [_]Handler.LspTextEdit{
        .{ .range = sample_range, .new_text = "newName" },
        .{ .range = sample_range, .new_text = "newName" },
    };

    const we = try lspkit.edits.toLspKitWorkspaceEdit(aa, test_uri, &edits);
    const a = try writeAndParse(aa, lsp.types.WorkspaceEdit, we);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire.edits.appendWorkspaceEdit(&buf, aa, test_uri, &edits);
    const b = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});

    try expectEqualJson(a, b);
}

// =========================================================================
// DocumentSymbol (recursive)
// =========================================================================

test "parity: DocumentSymbol — leaf function" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const syms = [_]Handler.DocumentSymbolInfo{
        .{
            .name = "main",
            .kind = .function,
            .range = sample_range,
            .selection_range = sample_sel,
            .children = &.{},
        },
    };

    const lsp_syms = try lspkit.symbols.toLspKitDocumentSymbols(aa, &syms);
    const a = try writeAndParse(aa, []const lsp.types.DocumentSymbol, lsp_syms);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire.symbols.appendDocSymbols(&buf, aa, &syms);
    const b = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});

    try expectEqualJson(a, b);
}

test "parity: DocumentSymbol — struct with field children (recursive)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const fields = [_]Handler.DocumentSymbolInfo{
        .{ .name = "a", .kind = .field, .range = sample_range, .selection_range = sample_sel, .children = &.{} },
        .{ .name = "b", .kind = .field, .range = sample_range, .selection_range = sample_sel, .children = &.{} },
    };
    const syms = [_]Handler.DocumentSymbolInfo{
        .{
            .name = "S",
            .kind = .struct_type,
            .range = sample_range,
            .selection_range = sample_sel,
            .children = &fields,
        },
    };

    const lsp_syms = try lspkit.symbols.toLspKitDocumentSymbols(aa, &syms);
    const a = try writeAndParse(aa, []const lsp.types.DocumentSymbol, lsp_syms);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire.symbols.appendDocSymbols(&buf, aa, &syms);
    const b = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});

    try expectEqualJson(a, b);
}

test "parity: DocumentSymbol — every SymbolKind variant" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const kinds = [_]Handler.SymbolKind{
        .function, .struct_type, .variable, .constant, .field, .type_alias, .override,
    };
    var syms: [kinds.len]Handler.DocumentSymbolInfo = undefined;
    for (kinds, 0..) |k, i| syms[i] = .{
        .name = "n",
        .kind = k,
        .range = sample_range,
        .selection_range = sample_sel,
        .children = &.{},
    };

    const lsp_syms = try lspkit.symbols.toLspKitDocumentSymbols(aa, &syms);
    const a = try writeAndParse(aa, []const lsp.types.DocumentSymbol, lsp_syms);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire.symbols.appendDocSymbols(&buf, aa, &syms);
    const b = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});

    try expectEqualJson(a, b);
}

// =========================================================================
// CodeAction (composes edits + diagnostics)
// =========================================================================

test "parity: CodeAction — quickfix with embedded diagnostic + workspace edit" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const edits = [_]Handler.LspTextEdit{
        .{ .range = sample_range, .new_text = "x" },
    };
    const actions = [_]Handler.LspCodeAction{.{
        .title = "Rename to x",
        .kind = "quickfix",
        .is_preferred = true,
        .diagnostic = .{
            .range = sample_range,
            .severity = .@"error",
            .message = "bad",
            .code = "E0001",
            .data = .{ .did_you_mean = "x" },
        },
        .edits = &edits,
    }};

    const lsp_actions = try lspkit.code_actions.toLspKitCodeActions(aa, test_uri, &actions);
    const a = try writeAndParse(aa, []const lsp.types.CodeAction.Result, lsp_actions);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire.code_actions.appendCodeActionItems(&buf, aa, test_uri, &actions);
    const b = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});

    try expectEqualJson(a, b);
}

test "parity: CodeAction — isPreferred=false omits the field on both transports" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const actions = [_]Handler.LspCodeAction{.{
        .title = "t",
        .kind = "quickfix",
        .is_preferred = false,
        .diagnostic = .{ .range = sample_range, .severity = .hint, .message = "m" },
        .edits = &.{},
    }};

    const lsp_actions = try lspkit.code_actions.toLspKitCodeActions(aa, test_uri, &actions);
    const a = try writeAndParse(aa, []const lsp.types.CodeAction.Result, lsp_actions);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire.code_actions.appendCodeActionItems(&buf, aa, test_uri, &actions);
    const b = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});

    try expectEqualJson(a, b);
}

// =========================================================================
// WorkspaceSymbol (workspace/symbol)
// =========================================================================

test "parity: WorkspaceSymbol — module symbol without container" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const syms = [_]Handler.WorkspaceSymbolInfo{
        .{
            .name = "integrate",
            .kind = .function,
            .uri = test_uri,
            .range = sample_sel,
            .container_name = "",
        },
        .{
            .name = "particles",
            .kind = .variable,
            .uri = "test://other.wgsl",
            .range = sample_range,
            .container_name = "",
        },
    };

    const lsp_syms = try lspkit.symbols.toLspKitWorkspaceSymbols(aa, &syms);
    const a = try writeAndParse(aa, []const lsp.types.workspace.Symbol, lsp_syms);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire.symbols.appendWorkspaceSymbols(&buf, aa, &syms);
    const b = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});

    try expectEqualJson(a, b);
}

test "parity: WorkspaceSymbol — field carries containerName, empty omits it on both" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const syms = [_]Handler.WorkspaceSymbolInfo{
        .{
            .name = "pos",
            .kind = .field,
            .uri = test_uri,
            .range = sample_sel,
            .container_name = "Particle",
        },
    };

    const lsp_syms = try lspkit.symbols.toLspKitWorkspaceSymbols(aa, &syms);
    const a = try writeAndParse(aa, []const lsp.types.workspace.Symbol, lsp_syms);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire.symbols.appendWorkspaceSymbols(&buf, aa, &syms);
    const b = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});

    try expectEqualJson(a, b);
}
