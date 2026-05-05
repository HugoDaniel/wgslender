//! Native editing adapters: completion, signatureHelp, formatting,
//! foldingRange, inlayHint, codeLens, selectionRange, semanticTokens/full.

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");
const codec = @import("codec");

pub fn handleCompletion(
    h: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.completion.Params,
) ?lsp.types.completion.Result {
    const items = h.computeCompletion(
        params.textDocument.uri,
        codec.fromLspKitPosition(params.position),
    ) catch return null;
    defer h.gpa.free(items);
    if (items.len == 0) return null;
    const lsp_items = arena.alloc(lsp.types.completion.Item, items.len) catch return null;
    for (items, 0..) |item, i| {
        lsp_items[i] = .{
            .label = item.label,
            .kind = switch (item.kind) {
                .variable => .Variable,
                .function => .Function,
                .struct_type => .Struct,
                .field => .Field,
                .keyword => .Keyword,
                .builtin => .Function,
                .type_name => .Class,
                .attribute => .Property,
            },
            .detail = if (item.detail.len > 0) item.detail else null,
        };
    }
    return .{ .completion_items = lsp_items };
}

pub fn handleSignatureHelp(
    h: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.SignatureHelp.Params,
) ?lsp.types.SignatureHelp {
    const result = h.computeSignatureHelp(
        params.textDocument.uri,
        codec.fromLspKitPosition(params.position),
    ) catch return null;
    const r = result orelse return null;

    const lsp_params = if (r.parameters.len > 0) blk: {
        const ps = arena.alloc(lsp.types.SignatureHelp.Signature.Parameter, r.parameters.len) catch break :blk null;
        for (r.parameters, 0..) |p, i| {
            ps[i] = .{ .label = .{ .string = p } };
        }
        break :blk ps;
    } else null;

    const sig = arena.alloc(lsp.types.SignatureHelp.Signature, 1) catch return null;
    sig[0] = .{
        .label = r.label,
        .parameters = lsp_params,
        .activeParameter = r.active_parameter,
    };

    return .{
        .signatures = sig,
        .activeSignature = 0,
        .activeParameter = r.active_parameter,
    };
}

pub fn handleFoldingRange(
    h: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.FoldingRange.Params,
) ?[]const lsp.types.FoldingRange {
    const ranges = h.computeFoldingRanges(params.textDocument.uri) catch return null;
    defer h.gpa.free(ranges);
    if (ranges.len == 0) return null;
    const lsp_ranges = arena.alloc(lsp.types.FoldingRange, ranges.len) catch return null;
    for (ranges, 0..) |r, i| {
        lsp_ranges[i] = .{
            .startLine = r.start_line,
            .endLine = r.end_line,
            .kind = switch (r.kind) {
                .comment => .comment,
                .region => .region,
            },
        };
    }
    return lsp_ranges;
}

pub fn handleInlayHint(
    h: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.InlayHint.Params,
) ?[]const lsp.types.InlayHint {
    const hints = h.computeInlayHints(
        params.textDocument.uri,
        codec.fromLspKitRange(params.range),
    ) catch return null;
    defer h.gpa.free(hints);
    if (hints.len == 0) return null;
    const lsp_hints = arena.alloc(lsp.types.InlayHint, hints.len) catch return null;
    for (hints, 0..) |hint, i| {
        const label: lsp.types.InlayHint.Label = if (hint.def_range) |dr| blk: {
            const parts = arena.alloc(lsp.types.InlayHint.LabelPart, 1) catch return null;
            parts[0] = .{
                .value = hint.label,
                .location = .{
                    .uri = params.textDocument.uri,
                    .range = codec.toLspKitRange(dr),
                },
            };
            break :blk .{ .inlay_hint_label_parts = parts };
        } else .{ .string = hint.label };
        lsp_hints[i] = .{
            .position = codec.toLspKitPosition(hint.position),
            .label = label,
            .kind = switch (hint.kind) {
                .type_hint, .const_value_hint, .minify_size => .Type,
                .parameter_hint => .Parameter,
            },
            .tooltip = if (hint.tooltip) |t| .{ .string = t } else null,
        };
    }
    return lsp_hints;
}

pub fn handleCodeLens(
    h: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.code_lens.Params,
) ?[]const lsp.types.code_lens.Response {
    const lenses = h.computeCodeLens(params.textDocument.uri) catch return null;
    defer Handler.freeCodeLens(h.gpa, lenses);
    if (lenses.len == 0) return null;
    const lsp_lenses = arena.alloc(lsp.types.code_lens.Response, lenses.len) catch return null;
    for (lenses, 0..) |l, i| {
        const cmd_name: []const u8 = if (l.command) |c| arena.dupe(u8, c) catch "" else "";
        // Re-encode the JSON args slice into the arena so the LSP
        // serializer can read it after the Handler-owned buffer is
        // freed by the defer above.
        const args: ?[]std.json.Value = if (l.arguments) |src| blk: {
            const dst = arena.alloc(std.json.Value, src.len) catch break :blk null;
            for (src, 0..) |arg, j| dst[j] = switch (arg) {
                .string => |s| .{ .string = arena.dupe(u8, s) catch "" },
                else => arg,
            };
            break :blk dst;
        } else null;
        lsp_lenses[i] = .{
            .range = codec.toLspKitRange(l.range),
            .command = .{
                .title = arena.dupe(u8, l.title) catch "",
                .command = cmd_name,
                .arguments = args,
            },
        };
    }
    return lsp_lenses;
}

pub fn handleSelectionRange(
    h: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.SelectionRange.Params,
) ?[]const lsp.types.SelectionRange {
    if (params.positions.len == 0) return null;
    const results = arena.alloc(lsp.types.SelectionRange, params.positions.len) catch return null;
    for (params.positions, 0..) |pos, i| {
        const sel = h.computeSelectionRange(
            params.textDocument.uri,
            codec.fromLspKitPosition(pos),
        ) catch return null;
        if (sel) |s| {
            results[i] = convertSelectionRange(arena, s);
        } else {
            results[i] = .{ .range = .{
                .start = .{ .line = pos.line, .character = pos.character },
                .end = .{ .line = pos.line, .character = pos.character },
            } };
        }
    }
    return results;
}

fn convertSelectionRange(arena: std.mem.Allocator, sel: *const Handler.SelectionRangeInfo) lsp.types.SelectionRange {
    var parent: ?*const lsp.types.SelectionRange = null;
    if (sel.parent) |p| {
        const lsp_parent = arena.create(lsp.types.SelectionRange) catch return .{
            .range = codec.toLspKitRange(sel.range),
        };
        lsp_parent.* = convertSelectionRange(arena, p);
        parent = lsp_parent;
    }
    return .{
        .range = codec.toLspKitRange(sel.range),
        .parent = parent,
    };
}

pub fn handleSemanticTokensFull(
    h: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.semantic_tokens.Params,
) ?lsp.types.semantic_tokens.Result {
    const data = h.computeSemanticTokens(params.textDocument.uri) catch return null;
    defer h.gpa.free(data);
    if (data.len == 0) return null;
    return .{ .data = arena.dupe(u32, data) catch return null };
}

pub fn handleFormatting(
    h: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.document_formatting.Params,
) ?[]const lsp.types.TextEdit {
    const edit = h.computeFormatting(params.textDocument.uri) catch return null;
    const e = edit orelse return null;
    defer h.gpa.free(e.new_text);
    const result = arena.alloc(lsp.types.TextEdit, 1) catch return null;
    result[0] = .{
        .range = codec.toLspKitRange(e.range),
        .newText = arena.dupe(u8, e.new_text) catch return null,
    };
    return result;
}
