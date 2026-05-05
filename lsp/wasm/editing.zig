//! WASM editing adapters: completion, signatureHelp, formatting,
//! foldingRange, inlayHint, codeLens, selectionRange, semanticTokens/full.

const std = @import("std");
const Handler = @import("Handler");
const wgslender = @import("wgslender");
const wire = @import("wire");
const json = wire.primitives;

const Diagnostic = wgslender.Diagnostic;

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
    json.appendStr(&buf, ctx.gpa, "[");
    for (items, 0..) |item, i| {
        if (i > 0) json.appendStr(&buf, ctx.gpa, ",");
        json.appendStr(&buf, ctx.gpa, "{\"label\":\"");
        Diagnostic.appendJsonEscaped(&buf, ctx.gpa, item.label) catch return;
        json.appendStr(&buf, ctx.gpa, "\",\"kind\":");
        const kind_num: u32 = switch (item.kind) {
            .variable => 6,
            .function => 3,
            .struct_type => 22,
            .field => 5,
            .keyword => 14,
            .builtin => 3,
            .type_name => 7,
            .attribute => 10,
        };
        json.appendUint(&buf, ctx.gpa, kind_num);
        if (item.detail.len > 0) {
            json.appendStr(&buf, ctx.gpa, ",\"detail\":\"");
            Diagnostic.appendJsonEscaped(&buf, ctx.gpa, item.detail) catch return;
            json.appendStr(&buf, ctx.gpa, "\"");
        }
        json.appendStr(&buf, ctx.gpa, "}");
    }
    json.appendStr(&buf, ctx.gpa, "]");
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}

pub fn handleSignatureHelp(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const p = json.extractUriAndPosition(root) orelse return ctx.sendResult(id, "null");
    const result = ctx.handler.computeSignatureHelp(p.uri, .{ .line = p.line, .character = p.char }) catch return ctx.sendResult(id, "null");
    const r = result orelse return ctx.sendResult(id, "null");
    defer ctx.handler.gpa.free(r.label);
    if (r.parameters.len > 0) ctx.handler.gpa.free(r.parameters);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    json.appendStr(&buf, ctx.gpa, "{\"signatures\":[{\"label\":\"");
    Diagnostic.appendJsonEscaped(&buf, ctx.gpa, r.label) catch return;
    json.appendStr(&buf, ctx.gpa, "\"");
    if (r.parameters.len > 0) {
        json.appendStr(&buf, ctx.gpa, ",\"parameters\":[");
        for (r.parameters, 0..) |param, i| {
            if (i > 0) json.appendStr(&buf, ctx.gpa, ",");
            json.appendStr(&buf, ctx.gpa, "{\"label\":\"");
            Diagnostic.appendJsonEscaped(&buf, ctx.gpa, param) catch return;
            json.appendStr(&buf, ctx.gpa, "\"}");
        }
        json.appendStr(&buf, ctx.gpa, "]");
    }
    json.appendStr(&buf, ctx.gpa, "}],\"activeSignature\":0,\"activeParameter\":");
    json.appendUint(&buf, ctx.gpa, r.active_parameter);
    json.appendStr(&buf, ctx.gpa, "}");
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}

pub fn handleFoldingRange(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const uri = json.extractUri(root) orelse return ctx.sendResult(id, "null");
    const ranges = ctx.handler.computeFoldingRanges(uri) catch return ctx.sendResult(id, "null");
    defer ctx.handler.gpa.free(ranges);
    if (ranges.len == 0) return ctx.sendResult(id, "null");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    json.appendStr(&buf, ctx.gpa, "[");
    for (ranges, 0..) |r, i| {
        if (i > 0) json.appendStr(&buf, ctx.gpa, ",");
        json.appendStr(&buf, ctx.gpa, "{\"startLine\":");
        json.appendUint(&buf, ctx.gpa, r.start_line);
        json.appendStr(&buf, ctx.gpa, ",\"endLine\":");
        json.appendUint(&buf, ctx.gpa, r.end_line);
        json.appendStr(&buf, ctx.gpa, ",\"kind\":\"");
        json.appendStr(&buf, ctx.gpa, if (r.kind == .comment) "comment" else "region");
        json.appendStr(&buf, ctx.gpa, "\"}");
    }
    json.appendStr(&buf, ctx.gpa, "]");
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
    json.appendStr(&buf, ctx.gpa, "[");
    for (hints, 0..) |h, i| {
        if (i > 0) json.appendStr(&buf, ctx.gpa, ",");
        json.appendStr(&buf, ctx.gpa, "{\"position\":{\"line\":");
        json.appendUint(&buf, ctx.gpa, h.position.line);
        json.appendStr(&buf, ctx.gpa, ",\"character\":");
        json.appendUint(&buf, ctx.gpa, h.position.character);
        json.appendStr(&buf, ctx.gpa, "},\"label\":");
        if (h.def_range) |dr| {
            json.appendStr(&buf, ctx.gpa, "[{\"value\":\"");
            Diagnostic.appendJsonEscaped(&buf, ctx.gpa, h.label) catch return;
            json.appendStr(&buf, ctx.gpa, "\",\"location\":{\"uri\":\"");
            Diagnostic.appendJsonEscaped(&buf, ctx.gpa, uri) catch return;
            json.appendStr(&buf, ctx.gpa, "\",\"range\":");
            json.formatRange(&buf, ctx.gpa, dr);
            json.appendStr(&buf, ctx.gpa, "}}]");
        } else {
            json.appendStr(&buf, ctx.gpa, "\"");
            Diagnostic.appendJsonEscaped(&buf, ctx.gpa, h.label) catch return;
            json.appendStr(&buf, ctx.gpa, "\"");
        }
        json.appendStr(&buf, ctx.gpa, ",\"kind\":");
        json.appendUint(&buf, ctx.gpa, if (h.kind == .parameter_hint) @as(u32, 2) else @as(u32, 1));
        if (h.tooltip) |t| {
            json.appendStr(&buf, ctx.gpa, ",\"tooltip\":\"");
            Diagnostic.appendJsonEscaped(&buf, ctx.gpa, t) catch return;
            json.appendStr(&buf, ctx.gpa, "\"");
        }
        json.appendStr(&buf, ctx.gpa, "}");
    }
    json.appendStr(&buf, ctx.gpa, "]");
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}

pub fn handleCodeLens(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const uri = json.extractUri(root) orelse return ctx.sendResult(id, "null");
    const lenses = ctx.handler.computeCodeLens(uri) catch return ctx.sendResult(id, "null");
    defer Handler.freeCodeLens(ctx.handler.gpa, lenses);
    if (lenses.len == 0) return ctx.sendResult(id, "null");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    json.appendStr(&buf, ctx.gpa, "[");
    for (lenses, 0..) |l, i| {
        if (i > 0) json.appendStr(&buf, ctx.gpa, ",");
        json.appendStr(&buf, ctx.gpa, "{\"range\":");
        json.formatRange(&buf, ctx.gpa, l.range);
        json.appendStr(&buf, ctx.gpa, ",\"command\":{\"title\":\"");
        Diagnostic.appendJsonEscaped(&buf, ctx.gpa, l.title) catch return;
        json.appendStr(&buf, ctx.gpa, "\",\"command\":\"");
        if (l.command) |c| {
            Diagnostic.appendJsonEscaped(&buf, ctx.gpa, c) catch return;
        }
        json.appendStr(&buf, ctx.gpa, "\"");
        if (l.arguments) |args| {
            json.appendStr(&buf, ctx.gpa, ",\"arguments\":[");
            for (args, 0..) |arg, j| {
                if (j > 0) json.appendStr(&buf, ctx.gpa, ",");
                switch (arg) {
                    .string => |s| {
                        json.appendStr(&buf, ctx.gpa, "\"");
                        Diagnostic.appendJsonEscaped(&buf, ctx.gpa, s) catch return;
                        json.appendStr(&buf, ctx.gpa, "\"");
                    },
                    else => json.appendStr(&buf, ctx.gpa, "null"),
                }
            }
            json.appendStr(&buf, ctx.gpa, "]");
        }
        json.appendStr(&buf, ctx.gpa, "}}");
    }
    json.appendStr(&buf, ctx.gpa, "]");
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}

pub fn handleFormatting(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const uri = json.extractUri(root) orelse return ctx.sendResult(id, "null");
    const edit = ctx.handler.computeFormatting(uri) catch return ctx.sendResult(id, "null");
    const e = edit orelse return ctx.sendResult(id, "null");
    defer ctx.handler.gpa.free(e.new_text);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    json.appendStr(&buf, ctx.gpa, "[{\"range\":");
    json.formatRange(&buf, ctx.gpa, e.range);
    json.appendStr(&buf, ctx.gpa, ",\"newText\":\"");
    Diagnostic.appendJsonEscaped(&buf, ctx.gpa, e.new_text) catch return;
    json.appendStr(&buf, ctx.gpa, "\"}]");
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}

pub fn handleSemanticTokens(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const uri = json.extractUri(root) orelse return ctx.sendResult(id, "null");
    const data = ctx.handler.computeSemanticTokens(uri) catch return ctx.sendResult(id, "null");
    defer ctx.handler.gpa.free(data);
    if (data.len == 0) return ctx.sendResult(id, "null");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    json.appendStr(&buf, ctx.gpa, "{\"data\":[");
    for (data, 0..) |v, i| {
        if (i > 0) json.appendStr(&buf, ctx.gpa, ",");
        json.appendUint(&buf, ctx.gpa, v);
    }
    json.appendStr(&buf, ctx.gpa, "]}");
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
            emitSelectionRange(&buf, ctx.gpa, s);
        } else {
            json.appendStr(&buf, ctx.gpa, "{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":0}}}");
        }
    }
    json.appendStr(&buf, ctx.gpa, "]");
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}

fn emitSelectionRange(buf: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, sel: *const Handler.SelectionRangeInfo) void {
    json.appendStr(buf, gpa, "{\"range\":");
    json.formatRange(buf, gpa, sel.range);
    if (sel.parent) |p| {
        json.appendStr(buf, gpa, ",\"parent\":");
        emitSelectionRange(buf, gpa, p);
    }
    json.appendStr(buf, gpa, "}");
}
