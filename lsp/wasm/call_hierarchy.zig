//! WASM call-hierarchy adapters. Param parsing lives here; JSON
//! emission for each shape is delegated to `wire/call_hierarchy.zig`.

const std = @import("std");
const Handler = @import("Handler");
const wire = @import("wire");
const json = wire.primitives;
const wire_ch = wire.call_hierarchy;

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
    buf.append(ctx.gpa, '[') catch return;
    wire_ch.appendItem(&buf, ctx.gpa, p.uri, i);
    buf.append(ctx.gpa, ']') catch return;
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}

const ItemRef = struct { uri: []const u8, name: []const u8 };

fn extractItemRef(root: std.json.ObjectMap) ?ItemRef {
    const params = root.getPtr("params") orelse return null;
    const item_val = json.objGet(params, "item") orelse return null;
    const name = json.strVal(json.objGet(item_val, "name")) orelse return null;
    const uri = json.strVal(json.objGet(item_val, "uri")) orelse return null;
    return .{ .uri = uri, .name = name };
}

pub fn handleIncomingCalls(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const ref = extractItemRef(root) orelse return ctx.sendResult(id, "null");
    const calls = ctx.handler.computeIncomingCalls(ref.uri, ref.name) catch return ctx.sendResult(id, "null");
    defer {
        for (calls) |c| ctx.handler.gpa.free(c.from_ranges);
        ctx.handler.gpa.free(calls);
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.append(ctx.gpa, '[') catch return;
    for (calls, 0..) |call, ci| {
        if (ci > 0) buf.append(ctx.gpa, ',') catch {};
        wire_ch.appendIncomingCall(&buf, ctx.gpa, ref.uri, call);
    }
    buf.append(ctx.gpa, ']') catch return;
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}

pub fn handleOutgoingCalls(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const ref = extractItemRef(root) orelse return ctx.sendResult(id, "null");
    const calls = ctx.handler.computeOutgoingCalls(ref.uri, ref.name) catch return ctx.sendResult(id, "null");
    defer {
        for (calls) |c| ctx.handler.gpa.free(c.from_ranges);
        ctx.handler.gpa.free(calls);
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.append(ctx.gpa, '[') catch return;
    for (calls, 0..) |call, ci| {
        if (ci > 0) buf.append(ctx.gpa, ',') catch {};
        wire_ch.appendOutgoingCall(&buf, ctx.gpa, ref.uri, call);
    }
    buf.append(ctx.gpa, ']') catch return;
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}
