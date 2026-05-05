//! WASM editing adapters: completion, signatureHelp, formatting,
//! foldingRange, inlayHint, codeLens, selectionRange, semanticTokens/full.
//!
//! Each handler is a thin shim — pull params via `wire.primitives`, call
//! Handler, encode the result via `wire.editing` (manual JSON, lsp-kit-free).

const std = @import("std");
const Handler = @import("Handler");
const wire = @import("wire");
const json = wire.primitives;
const wire_editing = wire.editing;

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    handler: *Handler,
    sendResult: *const fn (id: ?std.json.Value, result_json: []const u8) void,
};

pub fn handleCompletion(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const p = json.extractUriAndPosition(root) orelse return ctx.sendResult(id, "null");
    const items = ctx.handler.computeCompletion(p.uri, .{ .line = p.line, .character = p.char }) catch return ctx.sendResult(id, "null");
    defer ctx.handler.gpa.free(items);
    if (items.len == 0) return ctx.sendResult(id, "null");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire_editing.appendCompletionItems(&buf, ctx.gpa, items);
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}

pub fn handleSignatureHelp(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const p = json.extractUriAndPosition(root) orelse return ctx.sendResult(id, "null");
    const result = ctx.handler.computeSignatureHelp(p.uri, .{ .line = p.line, .character = p.char }) catch return ctx.sendResult(id, "null");
    const r = result orelse return ctx.sendResult(id, "null");
    defer ctx.handler.gpa.free(r.label);
    if (r.parameters.len > 0) ctx.handler.gpa.free(r.parameters);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire_editing.appendSignatureHelp(&buf, ctx.gpa, r);
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}

pub fn handleFoldingRange(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const uri = json.extractUri(root) orelse return ctx.sendResult(id, "null");
    const ranges = ctx.handler.computeFoldingRanges(uri) catch return ctx.sendResult(id, "null");
    defer ctx.handler.gpa.free(ranges);
    if (ranges.len == 0) return ctx.sendResult(id, "null");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire_editing.appendFoldingRanges(&buf, ctx.gpa, ranges);
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}

pub fn handleInlayHint(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const params = root.getPtr("params") orelse return ctx.sendResult(id, "null");
    const td = json.objGet(params, "textDocument") orelse return ctx.sendResult(id, "null");
    const uri = json.strVal(json.objGet(td, "uri")) orelse return ctx.sendResult(id, "null");
    const range_obj = json.objGet(params, "range") orelse return ctx.sendResult(id, "null");
    const start_obj = json.objGet(range_obj, "start") orelse return ctx.sendResult(id, "null");
    const end_obj = json.objGet(range_obj, "end") orelse return ctx.sendResult(id, "null");
    const start_line: u32 = if (json.intVal(json.objGet(start_obj, "line"))) |v| @intCast(v) else 0;
    const start_char: u32 = if (json.intVal(json.objGet(start_obj, "character"))) |v| @intCast(v) else 0;
    const end_line: u32 = if (json.intVal(json.objGet(end_obj, "line"))) |v| @intCast(v) else 0;
    const end_char: u32 = if (json.intVal(json.objGet(end_obj, "character"))) |v| @intCast(v) else 0;

    const hints = ctx.handler.computeInlayHints(uri, .{
        .start = .{ .line = start_line, .character = start_char },
        .end = .{ .line = end_line, .character = end_char },
    }) catch return ctx.sendResult(id, "null");
    defer ctx.handler.gpa.free(hints);
    if (hints.len == 0) return ctx.sendResult(id, "null");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire_editing.appendInlayHints(&buf, ctx.gpa, uri, hints);
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}

pub fn handleCodeLens(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const uri = json.extractUri(root) orelse return ctx.sendResult(id, "null");
    const lenses = ctx.handler.computeCodeLens(uri) catch return ctx.sendResult(id, "null");
    defer Handler.freeCodeLens(ctx.handler.gpa, lenses);
    if (lenses.len == 0) return ctx.sendResult(id, "null");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire_editing.appendCodeLenses(&buf, ctx.gpa, lenses);
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}

pub fn handleFormatting(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const uri = json.extractUri(root) orelse return ctx.sendResult(id, "null");
    const edit = ctx.handler.computeFormatting(uri) catch return ctx.sendResult(id, "null");
    const e = edit orelse return ctx.sendResult(id, "null");
    defer ctx.handler.gpa.free(e.new_text);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire_editing.appendFormattingEdit(&buf, ctx.gpa, e);
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}

pub fn handleSemanticTokens(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const uri = json.extractUri(root) orelse return ctx.sendResult(id, "null");
    const data = ctx.handler.computeSemanticTokens(uri) catch return ctx.sendResult(id, "null");
    defer ctx.handler.gpa.free(data);
    if (data.len == 0) return ctx.sendResult(id, "null");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire_editing.appendSemanticTokens(&buf, ctx.gpa, data);
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}

pub fn handleSelectionRange(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const params = root.getPtr("params") orelse return ctx.sendResult(id, "null");
    const td = json.objGet(params, "textDocument") orelse return ctx.sendResult(id, "null");
    const uri = json.strVal(json.objGet(td, "uri")) orelse return ctx.sendResult(id, "null");
    const positions = switch ((json.objGet(params, "positions") orelse return ctx.sendResult(id, "null")).*) {
        .array => |a| a.items,
        else => return ctx.sendResult(id, "null"),
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    json.appendStr(&buf, ctx.gpa, "[");
    for (positions, 0..) |*pos_val, pi| {
        if (pi > 0) json.appendStr(&buf, ctx.gpa, ",");
        const line: u32 = if (json.intVal(json.objGet(pos_val, "line"))) |v| @intCast(v) else 0;
        const char: u32 = if (json.intVal(json.objGet(pos_val, "character"))) |v| @intCast(v) else 0;
        const sel = ctx.handler.computeSelectionRange(uri, .{ .line = line, .character = char }) catch null;
        if (sel) |s| {
            wire_editing.appendSelectionRange(&buf, ctx.gpa, s);
        } else {
            wire_editing.appendNullSelectionRange(&buf, ctx.gpa);
        }
    }
    json.appendStr(&buf, ctx.gpa, "]");
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}
