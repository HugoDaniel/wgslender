//! WASM call-hierarchy adapters.

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

pub fn handlePrepare(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const p = json.extractUriAndPosition(root) orelse return ctx.sendResult(id, "null");
    const item = ctx.handler.prepareCallHierarchy(p.uri, .{ .line = p.line, .character = p.char }) catch return ctx.sendResult(id, "null");
    const i = item orelse return ctx.sendResult(id, "null");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    json.appendStr(&buf, ctx.gpa, "[{\"name\":\"");
    Diagnostic.appendJsonEscaped(&buf, ctx.gpa, i.name) catch return;
    json.appendStr(&buf, ctx.gpa, "\",\"kind\":12,\"uri\":\"");
    Diagnostic.appendJsonEscaped(&buf, ctx.gpa, p.uri) catch return;
    json.appendStr(&buf, ctx.gpa, "\",\"range\":");
    json.formatRange(&buf, ctx.gpa, i.range);
    json.appendStr(&buf, ctx.gpa, ",\"selectionRange\":");
    json.formatRange(&buf, ctx.gpa, i.selection_range);
    json.appendStr(&buf, ctx.gpa, "}]");
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}

pub fn handleIncomingCalls(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const params = root.getPtr("params") orelse return ctx.sendResult(id, "null");
    const item_val = json.objGet(params, "item") orelse return ctx.sendResult(id, "null");
    const name = json.strVal(json.objGet(item_val, "name")) orelse return ctx.sendResult(id, "null");
    const uri_val = json.objGet(item_val, "uri");
    const uri = if (uri_val) |u| json.strVal(u) orelse return ctx.sendResult(id, "null") else return ctx.sendResult(id, "null");
    const calls = ctx.handler.computeIncomingCalls(uri, name) catch return ctx.sendResult(id, "null");
    defer {
        for (calls) |c| ctx.handler.gpa.free(c.from_ranges);
        ctx.handler.gpa.free(calls);
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    json.appendStr(&buf, ctx.gpa, "[");
    for (calls, 0..) |call, ci| {
        if (ci > 0) json.appendStr(&buf, ctx.gpa, ",");
        json.appendStr(&buf, ctx.gpa, "{\"from\":{\"name\":\"");
        Diagnostic.appendJsonEscaped(&buf, ctx.gpa, call.from.name) catch return;
        json.appendStr(&buf, ctx.gpa, "\",\"kind\":12,\"uri\":\"");
        Diagnostic.appendJsonEscaped(&buf, ctx.gpa, uri) catch return;
        json.appendStr(&buf, ctx.gpa, "\",\"range\":");
        json.formatRange(&buf, ctx.gpa, call.from.range);
        json.appendStr(&buf, ctx.gpa, ",\"selectionRange\":");
        json.formatRange(&buf, ctx.gpa, call.from.selection_range);
        json.appendStr(&buf, ctx.gpa, "},\"fromRanges\":[");
        for (call.from_ranges, 0..) |fr, fi| {
            if (fi > 0) json.appendStr(&buf, ctx.gpa, ",");
            json.formatRange(&buf, ctx.gpa, fr);
        }
        json.appendStr(&buf, ctx.gpa, "]}");
    }
    json.appendStr(&buf, ctx.gpa, "]");
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}

pub fn handleOutgoingCalls(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const params = root.getPtr("params") orelse return ctx.sendResult(id, "null");
    const item_val = json.objGet(params, "item") orelse return ctx.sendResult(id, "null");
    const name = json.strVal(json.objGet(item_val, "name")) orelse return ctx.sendResult(id, "null");
    const uri_val = json.objGet(item_val, "uri");
    const uri = if (uri_val) |u| json.strVal(u) orelse return ctx.sendResult(id, "null") else return ctx.sendResult(id, "null");
    const calls = ctx.handler.computeOutgoingCalls(uri, name) catch return ctx.sendResult(id, "null");
    defer {
        for (calls) |c| ctx.handler.gpa.free(c.from_ranges);
        ctx.handler.gpa.free(calls);
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    json.appendStr(&buf, ctx.gpa, "[");
    for (calls, 0..) |call, ci| {
        if (ci > 0) json.appendStr(&buf, ctx.gpa, ",");
        json.appendStr(&buf, ctx.gpa, "{\"to\":{\"name\":\"");
        Diagnostic.appendJsonEscaped(&buf, ctx.gpa, call.to.name) catch return;
        json.appendStr(&buf, ctx.gpa, "\",\"kind\":12,\"uri\":\"");
        Diagnostic.appendJsonEscaped(&buf, ctx.gpa, uri) catch return;
        json.appendStr(&buf, ctx.gpa, "\",\"range\":");
        json.formatRange(&buf, ctx.gpa, call.to.range);
        json.appendStr(&buf, ctx.gpa, ",\"selectionRange\":");
        json.formatRange(&buf, ctx.gpa, call.to.selection_range);
        json.appendStr(&buf, ctx.gpa, "},\"fromRanges\":[");
        for (call.from_ranges, 0..) |fr, fi| {
            if (fi > 0) json.appendStr(&buf, ctx.gpa, ",");
            json.formatRange(&buf, ctx.gpa, fr);
        }
        json.appendStr(&buf, ctx.gpa, "]}");
    }
    json.appendStr(&buf, ctx.gpa, "]");
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}
