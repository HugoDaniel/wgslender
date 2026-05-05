//! WASM navigation adapters: hover, definition, typeDefinition,
//! references, documentHighlight. Builds JSON manually.

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

pub fn handleHover(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const p = json.extractUriAndPosition(root) orelse return ctx.sendResult(id, "null");
    const result = ctx.handler.computeHover(p.uri, .{ .line = p.line, .character = p.char }) catch return ctx.sendResult(id, "null");
    const r = result orelse return ctx.sendResult(id, "null");
    defer ctx.handler.gpa.free(r.contents);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    json.appendStr(&buf, ctx.gpa, "{\"contents\":{\"kind\":\"markdown\",\"value\":\"");
    Diagnostic.appendJsonEscaped(&buf, ctx.gpa, r.contents) catch return;
    json.appendStr(&buf, ctx.gpa, "\"},\"range\":");
    json.formatRange(&buf, ctx.gpa, r.range);
    json.appendStr(&buf, ctx.gpa, "}");
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}

pub fn handleDefinition(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const p = json.extractUriAndPosition(root) orelse return ctx.sendResult(id, "null");
    const range = ctx.handler.computeDefinition(p.uri, .{ .line = p.line, .character = p.char }) catch return ctx.sendResult(id, "null");
    const r = range orelse return ctx.sendResult(id, "null");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    json.appendStr(&buf, ctx.gpa, "{\"uri\":\"");
    Diagnostic.appendJsonEscaped(&buf, ctx.gpa, p.uri) catch return;
    json.appendStr(&buf, ctx.gpa, "\",\"range\":");
    json.formatRange(&buf, ctx.gpa, r);
    json.appendStr(&buf, ctx.gpa, "}");
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}

pub fn handleTypeDefinition(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const p = json.extractUriAndPosition(root) orelse return ctx.sendResult(id, "null");
    const range = ctx.handler.computeTypeDefinition(p.uri, .{ .line = p.line, .character = p.char }) catch return ctx.sendResult(id, "null");
    const r = range orelse return ctx.sendResult(id, "null");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    json.appendStr(&buf, ctx.gpa, "{\"uri\":\"");
    Diagnostic.appendJsonEscaped(&buf, ctx.gpa, p.uri) catch return;
    json.appendStr(&buf, ctx.gpa, "\",\"range\":");
    json.formatRange(&buf, ctx.gpa, r);
    json.appendStr(&buf, ctx.gpa, "}");
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}

pub fn handleReferences(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const p = json.extractUriAndPosition(root) orelse return ctx.sendResult(id, "null");
    const params = root.getPtr("params") orelse return ctx.sendResult(id, "null");
    const c = json.objGet(params, "context");
    const include_decl = if (c) |cv| blk: {
        const v = json.objGet(cv, "includeDeclaration");
        if (v) |val| {
            break :blk switch (val.*) {
                .bool => |b| b,
                else => true,
            };
        }
        break :blk true;
    } else true;

    const refs = ctx.handler.computeReferences(p.uri, .{ .line = p.line, .character = p.char }, include_decl) catch return ctx.sendResult(id, "null");
    const handler_refs = refs orelse return ctx.sendResult(id, "null");
    defer ctx.handler.gpa.free(handler_refs);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    json.appendStr(&buf, ctx.gpa, "[");
    for (handler_refs, 0..) |ref, i| {
        if (i > 0) json.appendStr(&buf, ctx.gpa, ",");
        json.appendStr(&buf, ctx.gpa, "{\"uri\":\"");
        Diagnostic.appendJsonEscaped(&buf, ctx.gpa, p.uri) catch return;
        json.appendStr(&buf, ctx.gpa, "\",\"range\":");
        json.formatRange(&buf, ctx.gpa, ref);
        json.appendStr(&buf, ctx.gpa, "}");
    }
    json.appendStr(&buf, ctx.gpa, "]");
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}

pub fn handleDocumentHighlight(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const p = json.extractUriAndPosition(root) orelse return ctx.sendResult(id, "null");
    const highlights = ctx.handler.computeDocumentHighlight(p.uri, .{ .line = p.line, .character = p.char }) catch return ctx.sendResult(id, "null");
    const handler_highlights = highlights orelse return ctx.sendResult(id, "null");
    defer ctx.handler.gpa.free(handler_highlights);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    json.appendStr(&buf, ctx.gpa, "[");
    for (handler_highlights, 0..) |h, i| {
        if (i > 0) json.appendStr(&buf, ctx.gpa, ",");
        json.appendStr(&buf, ctx.gpa, "{\"range\":");
        json.formatRange(&buf, ctx.gpa, h.range);
        json.appendStr(&buf, ctx.gpa, ",\"kind\":");
        json.appendUint(&buf, ctx.gpa, @intFromEnum(h.kind));
        json.appendStr(&buf, ctx.gpa, "}");
    }
    json.appendStr(&buf, ctx.gpa, "]");
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}
