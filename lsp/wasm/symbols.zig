//! WASM symbol adapters: rename, prepareRename, documentSymbol.

const std = @import("std");
const Handler = @import("Handler");
const wgslender = @import("wgslender");
const json = @import("json.zig");

const Diagnostic = wgslender.Diagnostic;

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    handler: *Handler,
    sendResult: *const fn (id: ?std.json.Value, result_json: []const u8) void,
};

pub fn handleRename(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const p = json.extractUriAndPosition(root) orelse return ctx.sendResult(id, "null");
    const params = root.getPtr("params") orelse return ctx.sendResult(id, "null");
    const new_name = json.strVal(json.objGet(params, "newName")) orelse return ctx.sendResult(id, "null");

    const edits = ctx.handler.computeRename(p.uri, .{ .line = p.line, .character = p.char }, new_name) catch return ctx.sendResult(id, "null");
    const handler_edits = edits orelse return ctx.sendResult(id, "null");
    defer ctx.handler.gpa.free(handler_edits);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    json.appendStr(&buf, ctx.gpa, "{\"changes\":{\"");
    Diagnostic.appendJsonEscaped(&buf, ctx.gpa, p.uri) catch return;
    json.appendStr(&buf, ctx.gpa, "\":[");
    for (handler_edits, 0..) |edit, i| {
        if (i > 0) json.appendStr(&buf, ctx.gpa, ",");
        json.appendStr(&buf, ctx.gpa, "{\"range\":");
        json.formatRange(&buf, ctx.gpa, edit.range);
        json.appendStr(&buf, ctx.gpa, ",\"newText\":\"");
        Diagnostic.appendJsonEscaped(&buf, ctx.gpa, edit.new_text) catch return;
        json.appendStr(&buf, ctx.gpa, "\"}");
    }
    json.appendStr(&buf, ctx.gpa, "]}}");
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}

pub fn handlePrepareRename(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const p = json.extractUriAndPosition(root) orelse return ctx.sendResult(id, "null");
    const range = ctx.handler.prepareRename(p.uri, .{ .line = p.line, .character = p.char }) catch return ctx.sendResult(id, "null");
    const r = range orelse return ctx.sendResult(id, "null");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    json.appendStr(&buf, ctx.gpa, "{\"range\":");
    json.formatRange(&buf, ctx.gpa, r);
    json.appendStr(&buf, ctx.gpa, ",\"placeholder\":\"\"}");
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}

pub fn handleDocumentSymbol(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const uri = json.extractUri(root) orelse return ctx.sendResult(id, "null");
    const symbols = ctx.handler.computeDocumentSymbols(uri) catch return ctx.sendResult(id, "null");
    defer ctx.handler.gpa.free(symbols);
    if (symbols.len == 0) return ctx.sendResult(id, "null");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    json.appendStr(&buf, ctx.gpa, "[");
    for (symbols, 0..) |sym, i| {
        if (i > 0) json.appendStr(&buf, ctx.gpa, ",");
        emitDocSymbol(&buf, ctx.gpa, sym);
    }
    json.appendStr(&buf, ctx.gpa, "]");
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}

fn emitDocSymbol(buf: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, sym: Handler.DocumentSymbolInfo) void {
    json.appendStr(buf, gpa, "{\"name\":\"");
    Diagnostic.appendJsonEscaped(buf, gpa, sym.name) catch return;
    json.appendStr(buf, gpa, "\",\"kind\":");
    const kind_num: u32 = switch (sym.kind) {
        .function => 12,
        .struct_type => 23,
        .variable => 13,
        .constant => 14,
        .field => 8,
        .type_alias => 5,
        .override => 14,
    };
    json.appendUint(buf, gpa, kind_num);
    json.appendStr(buf, gpa, ",\"range\":");
    json.formatRange(buf, gpa, sym.range);
    json.appendStr(buf, gpa, ",\"selectionRange\":");
    json.formatRange(buf, gpa, sym.selection_range);
    if (sym.children.len > 0) {
        json.appendStr(buf, gpa, ",\"children\":[");
        for (sym.children, 0..) |child, ci| {
            if (ci > 0) json.appendStr(buf, gpa, ",");
            emitDocSymbol(buf, gpa, child);
        }
        json.appendStr(buf, gpa, "]");
    }
    json.appendStr(buf, gpa, "}");
}
