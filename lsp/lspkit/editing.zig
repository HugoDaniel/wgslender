//! Bridges between the transport-agnostic editing-batch types
//! (`Handler.CompletionItem`, `Handler.SignatureInfo`, …) and the
//! lsp-kit `lsp.types.*` shapes consumed by `lsp.writeResponse`.
//!
//! Reached as `lspkit.editing.*` via `lsp/lspkit_root.zig`. Native
//! adapters (`native/editing.zig`) drive each helper for the matching
//! request handler. Strings inside the input are borrowed; the caller
//! must keep them alive until the response is written.
//!
//! Code-lens command arguments are duped onto the response arena —
//! `Handler.computeCodeLens` returns a slice owned by `handler.gpa` and
//! `freeCodeLens` releases it via `defer` once we've copied what the
//! lsp-kit serializer needs.

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");
const primitives = @import("primitives.zig");

// =========================================================================
// Completion
// =========================================================================

pub fn toLspKitCompletionKind(kind: Handler.CompletionKind) lsp.types.completion.Item.Kind {
    return switch (kind) {
        .variable => .Variable,
        .function => .Function,
        .struct_type => .Struct,
        .field => .Field,
        .keyword => .Keyword,
        .builtin => .Function,
        .type_name => .Class,
        .attribute => .Property,
    };
}

pub fn toLspKitCompletionItems(
    arena: std.mem.Allocator,
    items: []const Handler.CompletionItem,
) ![]lsp.types.completion.Item {
    const out = try arena.alloc(lsp.types.completion.Item, items.len);
    for (items, 0..) |item, i| {
        out[i] = .{
            .label = item.label,
            .kind = toLspKitCompletionKind(item.kind),
            .detail = if (item.detail.len > 0) item.detail else null,
        };
    }
    return out;
}

// =========================================================================
// Signature Help
// =========================================================================

/// Build a single-signature `SignatureHelp` shape. The Handler currently
/// returns at most one `SignatureInfo` per request, so we always emit a
/// one-element `signatures` array with `activeSignature = 0`.
pub fn toLspKitSignatureHelp(
    arena: std.mem.Allocator,
    info: Handler.SignatureInfo,
) !lsp.types.SignatureHelp {
    const params: ?[]const lsp.types.SignatureHelp.Signature.Parameter = if (info.parameters.len > 0) blk: {
        const ps = try arena.alloc(lsp.types.SignatureHelp.Signature.Parameter, info.parameters.len);
        for (info.parameters, 0..) |p, i| ps[i] = .{ .label = .{ .string = p } };
        break :blk ps;
    } else null;
    const sig = try arena.alloc(lsp.types.SignatureHelp.Signature, 1);
    sig[0] = .{
        .label = info.label,
        .parameters = params,
        // Leave the per-signature `activeParameter` null so it's omitted
        // on the wire — the outer `SignatureHelp.activeParameter` already
        // carries the index, and the wire transport does not emit it on
        // the inner `Signature`. Setting both diverges from the wire shape
        // for no functional gain (per LSP spec the inner field overrides
        // the outer when both are present).
    };
    return .{
        .signatures = sig,
        .activeSignature = 0,
        .activeParameter = info.active_parameter,
    };
}

// =========================================================================
// Folding Ranges
// =========================================================================

pub fn toLspKitFoldingRanges(
    arena: std.mem.Allocator,
    ranges: []const Handler.FoldingRangeInfo,
) ![]lsp.types.FoldingRange {
    const out = try arena.alloc(lsp.types.FoldingRange, ranges.len);
    for (ranges, 0..) |r, i| out[i] = .{
        .startLine = r.start_line,
        .endLine = r.end_line,
        .kind = switch (r.kind) {
            .comment => .comment,
            .region => .region,
        },
    };
    return out;
}

// =========================================================================
// Inlay Hints
// =========================================================================

pub fn toLspKitInlayHintKind(kind: @FieldType(Handler.InlayHintInfo, "kind")) lsp.types.InlayHint.Kind {
    return switch (kind) {
        .type_hint, .const_value_hint, .minify_size => .Type,
        .parameter_hint => .Parameter,
    };
}

pub fn toLspKitInlayHints(
    arena: std.mem.Allocator,
    uri: []const u8,
    hints: []const Handler.InlayHintInfo,
) ![]lsp.types.InlayHint {
    const out = try arena.alloc(lsp.types.InlayHint, hints.len);
    for (hints, 0..) |hint, i| {
        const label: lsp.types.InlayHint.Label = if (hint.def_range) |dr| blk: {
            const parts = try arena.alloc(lsp.types.InlayHint.LabelPart, 1);
            parts[0] = .{
                .value = hint.label,
                .location = .{
                    .uri = uri,
                    .range = primitives.toLspKitRange(dr),
                },
            };
            break :blk .{ .inlay_hint_label_parts = parts };
        } else .{ .string = hint.label };
        out[i] = .{
            .position = primitives.toLspKitPosition(hint.position),
            .label = label,
            .kind = toLspKitInlayHintKind(hint.kind),
            .tooltip = if (hint.tooltip) |t| .{ .string = t } else null,
        };
    }
    return out;
}

// =========================================================================
// Code Lens
// =========================================================================

/// Convert `CodeLensInfo[]` to the lsp-kit shape. `command` and
/// `arguments` are duped onto `arena` — Handler-side ownership of the
/// argument strings ends with `freeCodeLens(handler.gpa, lenses)` in
/// the caller, which fires after we return.
pub fn toLspKitCodeLenses(
    arena: std.mem.Allocator,
    lenses: []const Handler.CodeLensInfo,
) ![]lsp.types.code_lens.Response {
    const out = try arena.alloc(lsp.types.code_lens.Response, lenses.len);
    for (lenses, 0..) |l, i| {
        const cmd_name: []const u8 = if (l.command) |c| try arena.dupe(u8, c) else "";
        const args: ?[]std.json.Value = if (l.arguments) |src| blk: {
            const dst = try arena.alloc(std.json.Value, src.len);
            for (src, 0..) |arg, j| dst[j] = switch (arg) {
                .string => |s| .{ .string = try arena.dupe(u8, s) },
                else => arg,
            };
            break :blk dst;
        } else null;
        out[i] = .{
            .range = primitives.toLspKitRange(l.range),
            .command = .{
                .title = try arena.dupe(u8, l.title),
                .command = cmd_name,
                .arguments = args,
            },
        };
    }
    return out;
}

// =========================================================================
// Selection Range (recursive)
// =========================================================================

/// Convert one `SelectionRangeInfo` (and its parent chain) into the
/// lsp-kit shape. The lsp-kit type uses an explicit `?*const SelectionRange`
/// pointer for `parent`, so each node is independently allocated.
pub fn toLspKitSelectionRange(
    arena: std.mem.Allocator,
    sel: *const Handler.SelectionRangeInfo,
) std.mem.Allocator.Error!lsp.types.SelectionRange {
    var parent: ?*const lsp.types.SelectionRange = null;
    if (sel.parent) |p| {
        const lsp_parent = try arena.create(lsp.types.SelectionRange);
        lsp_parent.* = try toLspKitSelectionRange(arena, p);
        parent = lsp_parent;
    }
    return .{
        .range = primitives.toLspKitRange(sel.range),
        .parent = parent,
    };
}

/// Fallback selection-range emitted for a position that has no parent
/// chain (e.g. cursor outside any declaration). Mirrors the wire-side
/// `appendNullSelectionRange`: zero-width range at (0,0), no parent.
pub fn lspKitNullSelectionRange() lsp.types.SelectionRange {
    return .{
        .range = .{
            .start = .{ .line = 0, .character = 0 },
            .end = .{ .line = 0, .character = 0 },
        },
        .parent = null,
    };
}

// =========================================================================
// Semantic Tokens
// =========================================================================

pub fn toLspKitSemanticTokens(
    arena: std.mem.Allocator,
    data: []const u32,
) !lsp.types.semantic_tokens.Result {
    return .{ .data = try arena.dupe(u32, data) };
}

// =========================================================================
// Formatting
// =========================================================================

/// Build a single-edit `TextEdit[]` for `textDocument/formatting`. The
/// `new_text` string is duped onto `arena` because the Handler frees
/// the original buffer after the request returns.
pub fn toLspKitFormattingEdit(
    arena: std.mem.Allocator,
    edit: Handler.LspTextEdit,
) ![]lsp.types.TextEdit {
    const out = try arena.alloc(lsp.types.TextEdit, 1);
    out[0] = .{
        .range = primitives.toLspKitRange(edit.range),
        .newText = try arena.dupe(u8, edit.new_text),
    };
    return out;
}

// =========================================================================
// Tests
// =========================================================================

const testing = std.testing;

const sample_range: Handler.Range = .{
    .start = .{ .line = 1, .character = 2 },
    .end = .{ .line = 1, .character = 7 },
};

test "toLspKitCompletionItems: kind table + optional detail" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const items = [_]Handler.CompletionItem{
        .{ .label = "foo", .kind = .function, .detail = "fn() -> u32" },
        .{ .label = "bar", .kind = .keyword },
    };
    const out = try toLspKitCompletionItems(aa, &items);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqual(lsp.types.completion.Item.Kind.Function, out[0].kind.?);
    try testing.expectEqualStrings("fn() -> u32", out[0].detail.?);
    try testing.expect(out[1].detail == null);
}

test "toLspKitSignatureHelp: parameters present and absent" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const params = [_][]const u8{ "x", "y" };
    const out = try toLspKitSignatureHelp(aa, .{ .label = "f(x,y)", .parameters = &params, .active_parameter = 1 });
    try testing.expectEqualStrings("f(x,y)", out.signatures[0].label);
    try testing.expectEqual(@as(usize, 2), out.signatures[0].parameters.?.len);

    const out2 = try toLspKitSignatureHelp(aa, .{ .label = "g()", .parameters = &.{}, .active_parameter = 0 });
    try testing.expect(out2.signatures[0].parameters == null);
}

test "toLspKitInlayHints: def_range null vs set" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const hints = [_]Handler.InlayHintInfo{
        .{ .position = .{ .line = 1, .character = 2 }, .label = "x", .kind = .type_hint },
        .{ .position = .{ .line = 3, .character = 4 }, .label = "S", .kind = .type_hint, .def_range = sample_range },
    };
    const out = try toLspKitInlayHints(aa, "test://a.wgsl", &hints);
    switch (out[0].label) {
        .string => |s| try testing.expectEqualStrings("x", s),
        else => return error.TestUnexpectedResult,
    }
    switch (out[1].label) {
        .inlay_hint_label_parts => |parts| {
            try testing.expectEqual(@as(usize, 1), parts.len);
            try testing.expectEqualStrings("S", parts[0].value);
            try testing.expectEqualStrings("test://a.wgsl", parts[0].location.?.uri);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "toLspKitSelectionRange: parent chain" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const outer: Handler.SelectionRangeInfo = .{ .range = sample_range, .parent = null };
    const inner: Handler.SelectionRangeInfo = .{
        .range = .{ .start = .{ .line = 1, .character = 3 }, .end = .{ .line = 1, .character = 5 } },
        .parent = &outer,
    };
    const out = try toLspKitSelectionRange(aa, &inner);
    try testing.expect(out.parent != null);
    try testing.expect(out.parent.?.parent == null);
}
