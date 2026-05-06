//! WASM symbol adapters: rename, prepareRename, documentSymbol. Thin
//! dispatch shims — parse JSON via `wire.primitives`, call Handler,
//! encode via `wire.edits` / `wire.symbols`.

const std = @import("std");
const Handler = @import("Handler");
const wgslender = @import("wgslender");
const wire = @import("wire");
const json = wire.primitives;
const wire_edits = wire.edits;
const wire_symbols = wire.symbols;

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

    var buf: std.ArrayList(u8) = .empty;
    wire_edits.appendWorkspaceEdit(&buf, ctx.gpa, p.uri, handler_edits);
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}

pub fn handlePrepareRename(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const p = json.extractUriAndPosition(root) orelse return ctx.sendResult(id, "null");
    const range = ctx.handler.prepareRename(p.uri, .{ .line = p.line, .character = p.char }) catch return ctx.sendResult(id, "null");
    const r = range orelse return ctx.sendResult(id, "null");

    var buf: std.ArrayList(u8) = .empty;
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

    var buf: std.ArrayList(u8) = .empty;
    wire_symbols.appendDocSymbols(&buf, ctx.gpa, symbols);
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}
