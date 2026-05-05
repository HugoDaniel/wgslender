//! Parity harness for the editing batch (completion, signature help,
//! folding ranges, inlay hints, code lens, selection range, semantic
//! tokens, formatting) plus the data-returning workspace commands
//! (`wgslender.showMinifiedOutput`, `wgslender/reflect`).
//!
//! `lspkit/<feature>.zig` (driven by `lsp.writeResponse`) and
//! `wire/<feature>.zig` must emit byte-equivalent JSON for every result
//! shape — guards against the two transports drifting on field
//! ordering, kind constants, and the inlay-hint LabelPart `def_range`
//! null-vs-set divergence the migration plan called out.

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
// Completion
// =========================================================================

test "parity: completion items — every kind + optional detail" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const items = [_]Handler.CompletionItem{
        .{ .label = "v", .kind = .variable, .detail = "u32" },
        .{ .label = "f", .kind = .function },
        .{ .label = "S", .kind = .struct_type },
        .{ .label = "x", .kind = .field },
        .{ .label = "fn", .kind = .keyword },
        .{ .label = "abs", .kind = .builtin },
        .{ .label = "i32", .kind = .type_name },
        .{ .label = "binding", .kind = .attribute },
    };

    const lsp_items = try lspkit.editing.toLspKitCompletionItems(aa, &items);
    const a = try writeAndParse(aa, lsp.types.completion.Result, .{ .completion_items = lsp_items });

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire.editing.appendCompletionItems(&buf, aa, &items);
    const b = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});

    try expectEqualJson(a, b);
}

// =========================================================================
// Signature Help
// =========================================================================

test "parity: signatureHelp — with parameters" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const params = [_][]const u8{ "x", "y" };
    const info: Handler.SignatureInfo = .{
        .label = "f(x: u32, y: u32) -> u32",
        .parameters = &params,
        .active_parameter = 1,
    };

    const lsp_help = try lspkit.editing.toLspKitSignatureHelp(aa, info);
    const a = try writeAndParse(aa, lsp.types.SignatureHelp, lsp_help);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire.editing.appendSignatureHelp(&buf, aa, info);
    const b = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});

    try expectEqualJson(a, b);
}

test "parity: signatureHelp — empty parameters omits the field" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const info: Handler.SignatureInfo = .{
        .label = "g()",
        .parameters = &.{},
        .active_parameter = 0,
    };

    const lsp_help = try lspkit.editing.toLspKitSignatureHelp(aa, info);
    const a = try writeAndParse(aa, lsp.types.SignatureHelp, lsp_help);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire.editing.appendSignatureHelp(&buf, aa, info);
    const b = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});

    try expectEqualJson(a, b);
}

// =========================================================================
// Folding Ranges
// =========================================================================

test "parity: foldingRange — region + comment kinds" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const ranges = [_]Handler.FoldingRangeInfo{
        .{ .start_line = 1, .end_line = 5, .kind = .region },
        .{ .start_line = 7, .end_line = 9, .kind = .comment },
    };

    const lsp_ranges = try lspkit.editing.toLspKitFoldingRanges(aa, &ranges);
    const a = try writeAndParse(aa, []const lsp.types.FoldingRange, lsp_ranges);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire.editing.appendFoldingRanges(&buf, aa, &ranges);
    const b = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});

    try expectEqualJson(a, b);
}

// =========================================================================
// Inlay Hints — the called-out parity case (def_range null vs set)
// =========================================================================

test "parity: inlayHint — def_range = null (label is bare string)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const hints = [_]Handler.InlayHintInfo{.{
        .position = .{ .line = 1, .character = 2 },
        .label = "u32",
        .kind = .type_hint,
    }};

    const lsp_hints = try lspkit.editing.toLspKitInlayHints(aa, test_uri, &hints);
    const a = try writeAndParse(aa, []const lsp.types.InlayHint, lsp_hints);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire.editing.appendInlayHints(&buf, aa, test_uri, &hints);
    const b = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});

    try expectEqualJson(a, b);
}

test "parity: inlayHint — def_range set (label is LabelPart[] with location)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const hints = [_]Handler.InlayHintInfo{.{
        .position = .{ .line = 3, .character = 4 },
        .label = "S",
        .kind = .type_hint,
        .def_range = sample_range,
    }};

    const lsp_hints = try lspkit.editing.toLspKitInlayHints(aa, test_uri, &hints);
    const a = try writeAndParse(aa, []const lsp.types.InlayHint, lsp_hints);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire.editing.appendInlayHints(&buf, aa, test_uri, &hints);
    const b = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});

    try expectEqualJson(a, b);
}

test "parity: inlayHint — every InlayHintKind variant + tooltip" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const hints = [_]Handler.InlayHintInfo{
        .{ .position = .{ .line = 0, .character = 0 }, .label = "T", .kind = .type_hint, .tooltip = "approx" },
        .{ .position = .{ .line = 1, .character = 0 }, .label = "p", .kind = .parameter_hint },
        .{ .position = .{ .line = 2, .character = 0 }, .label = "= 42", .kind = .const_value_hint },
        .{ .position = .{ .line = 3, .character = 0 }, .label = "—12 b", .kind = .minify_size },
    };

    const lsp_hints = try lspkit.editing.toLspKitInlayHints(aa, test_uri, &hints);
    const a = try writeAndParse(aa, []const lsp.types.InlayHint, lsp_hints);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire.editing.appendInlayHints(&buf, aa, test_uri, &hints);
    const b = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});

    try expectEqualJson(a, b);
}

// =========================================================================
// Code Lens
// =========================================================================

test "parity: codeLens — title-only and command-with-arguments" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var args = [_]std.json.Value{.{ .string = "test://parity.wgsl" }};
    const lenses = [_]Handler.CodeLensInfo{
        .{ .range = sample_range, .title = "1 ref" },
        .{
            .range = sample_range,
            .title = "Show minified",
            .command = "wgslender.showMinifiedOutput",
            .arguments = args[0..],
        },
    };

    const lsp_lenses = try lspkit.editing.toLspKitCodeLenses(aa, &lenses);
    const a = try writeAndParse(aa, []const lsp.types.code_lens.Response, lsp_lenses);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire.editing.appendCodeLenses(&buf, aa, &lenses);
    const b = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});

    try expectEqualJson(a, b);
}

// =========================================================================
// Selection Range
// =========================================================================

test "parity: selectionRange — recursive parent chain" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const outer: Handler.SelectionRangeInfo = .{ .range = sample_range, .parent = null };
    const inner: Handler.SelectionRangeInfo = .{ .range = sample_sel, .parent = &outer };

    const lsp_sel = try lspkit.editing.toLspKitSelectionRange(aa, &inner);
    const sel_slice = try aa.alloc(lsp.types.SelectionRange, 1);
    sel_slice[0] = lsp_sel;
    const a = try writeAndParse(aa, []const lsp.types.SelectionRange, sel_slice);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.append(aa, '[') catch unreachable;
    wire.editing.appendSelectionRange(&buf, aa, &inner);
    buf.append(aa, ']') catch unreachable;
    const b = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});

    try expectEqualJson(a, b);
}

// =========================================================================
// Semantic Tokens
// =========================================================================

test "parity: semanticTokens — data array roundtrip" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const data = [_]u32{ 1, 0, 4, 1, 0, 0, 5, 3, 8, 1 };

    const lsp_tokens = try lspkit.editing.toLspKitSemanticTokens(aa, &data);
    const a = try writeAndParse(aa, lsp.types.semantic_tokens.Result, lsp_tokens);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire.editing.appendSemanticTokens(&buf, aa, &data);
    const b = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});

    try expectEqualJson(a, b);
}

// =========================================================================
// Formatting
// =========================================================================

test "parity: formatting — single TextEdit" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const edit: Handler.LspTextEdit = .{ .range = sample_range, .new_text = "fn main(){}" };

    const lsp_edits = try lspkit.editing.toLspKitFormattingEdit(aa, edit);
    const a = try writeAndParse(aa, []const lsp.types.TextEdit, lsp_edits);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire.editing.appendFormattingEdit(&buf, aa, edit);
    const b = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});

    try expectEqualJson(a, b);
}

// =========================================================================
// Workspace commands: showMinifiedOutput + reflect
// =========================================================================

test "parity: showMinifiedOutput — every field shape" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const result: Handler.MinifyCommandResult = .{
        .uri = test_uri,
        .minified_text = "fn main(){}",
        .byte_count = 11,
        .gz_count = 33,
    };

    const value = try lspkit.workspace_commands.toLspKitShowMinifiedOutput(aa, result);
    const a = try writeAndParse(aa, std.json.Value, value);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire.workspace_commands.appendShowMinifiedOutput(&buf, aa, result);
    const b = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});

    try expectEqualJson(a, b);
}

test "parity: reflect — embedded JSON normalizes equivalently" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const result: Handler.ReflectCommandResult = .{
        .uri = test_uri,
        .json = "{\"entries\":[],\"count\":0}",
        .version = .v2,
    };

    const value = try lspkit.workspace_commands.toLspKitReflectResult(aa, result);
    const a = try writeAndParse(aa, std.json.Value, value);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire.workspace_commands.appendReflectResult(&buf, aa, result);
    const b = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});

    try expectEqualJson(a, b);
}
