//! WASM navigation adapters: hover, definition, typeDefinition,
//! references, documentHighlight. Param parsing lives here; JSON
//! emission for each result shape is delegated to `wire/navigation.zig`.

const std = @import("std");
const Handler = @import("Handler");
const wire = @import("wire");
const json = wire.primitives;
const wire_nav = wire.navigation;

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

    var buf: std.ArrayList(u8) = .empty;
    wire_nav.appendHover(&buf, ctx.gpa, r);
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}

fn sendSingleLocation(ctx: Ctx, id: ?std.json.Value, uri: []const u8, range: Handler.Range) void {
    var buf: std.ArrayList(u8) = .empty;
    wire_nav.appendLocation(&buf, ctx.gpa, uri, range);
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}

pub fn handleDefinition(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const p = json.extractUriAndPosition(root) orelse return ctx.sendResult(id, "null");
    const range = ctx.handler.computeDefinition(p.uri, .{ .line = p.line, .character = p.char }) catch return ctx.sendResult(id, "null");
    const r = range orelse return ctx.sendResult(id, "null");
    sendSingleLocation(ctx, id, p.uri, r);
}

pub fn handleTypeDefinition(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const p = json.extractUriAndPosition(root) orelse return ctx.sendResult(id, "null");
    const range = ctx.handler.computeTypeDefinition(p.uri, .{ .line = p.line, .character = p.char }) catch return ctx.sendResult(id, "null");
    const r = range orelse return ctx.sendResult(id, "null");
    sendSingleLocation(ctx, id, p.uri, r);
}

pub fn handleReferences(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const p = json.extractUriAndPosition(root) orelse return ctx.sendResult(id, "null");
    const params = root.getPtr("params") orelse return ctx.sendResult(id, "null");
    const c = json.objGet(params, "context");
    const include_decl = if (c) |cv| json.boolVal(json.objGet(cv, "includeDeclaration")) orelse true else true;

    const refs = ctx.handler.computeReferences(p.uri, .{ .line = p.line, .character = p.char }, include_decl) catch return ctx.sendResult(id, "null");
    const handler_refs = refs orelse return ctx.sendResult(id, "null");
    defer ctx.handler.gpa.free(handler_refs);

    var buf: std.ArrayList(u8) = .empty;
    buf.append(ctx.gpa, '[') catch return;
    for (handler_refs, 0..) |ref, i| {
        if (i > 0) buf.append(ctx.gpa, ',') catch {};
        wire_nav.appendLocation(&buf, ctx.gpa, p.uri, ref);
    }
    buf.append(ctx.gpa, ']') catch return;
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}

pub fn handleDocumentHighlight(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const p = json.extractUriAndPosition(root) orelse return ctx.sendResult(id, "null");
    const highlights = ctx.handler.computeDocumentHighlight(p.uri, .{ .line = p.line, .character = p.char }) catch return ctx.sendResult(id, "null");
    const handler_highlights = highlights orelse return ctx.sendResult(id, "null");
    defer ctx.handler.gpa.free(handler_highlights);

    var buf: std.ArrayList(u8) = .empty;
    buf.append(ctx.gpa, '[') catch return;
    for (handler_highlights, 0..) |h, i| {
        if (i > 0) buf.append(ctx.gpa, ',') catch {};
        wire_nav.appendDocumentHighlight(&buf, ctx.gpa, h);
    }
    buf.append(ctx.gpa, ']') catch return;
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}
