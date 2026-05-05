//! Native call-hierarchy adapters: prepareCallHierarchy,
//! callHierarchy/incomingCalls, callHierarchy/outgoingCalls.

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");
const codec = @import("codec");

pub fn handlePrepare(
    h: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.call_hierarchy.PrepareParams,
) ?[]const lsp.types.call_hierarchy.Item {
    const item = h.prepareCallHierarchy(
        params.textDocument.uri,
        codec.fromLspKitPosition(params.position),
    ) catch return null;
    const i = item orelse return null;
    const result = arena.alloc(lsp.types.call_hierarchy.Item, 1) catch return null;
    result[0] = .{
        .name = i.name,
        .kind = .Function,
        .uri = params.textDocument.uri,
        .range = codec.toLspKitRange(i.range),
        .selectionRange = codec.toLspKitRange(i.selection_range),
    };
    return result;
}

pub fn handleIncomingCalls(
    h: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.call_hierarchy.IncomingCallsParams,
) ?[]const lsp.types.call_hierarchy.IncomingCall {
    const uri = params.item.uri;
    const calls = h.computeIncomingCalls(uri, params.item.name) catch return null;
    defer {
        for (calls) |c| h.gpa.free(c.from_ranges);
        h.gpa.free(calls);
    }
    if (calls.len == 0) return null;
    const result = arena.alloc(lsp.types.call_hierarchy.IncomingCall, calls.len) catch return null;
    for (calls, 0..) |call, ci| {
        const from_ranges = arena.alloc(lsp.types.Range, call.from_ranges.len) catch continue;
        for (call.from_ranges, 0..) |fr, fi| from_ranges[fi] = codec.toLspKitRange(fr);
        result[ci] = .{
            .from = .{
                .name = call.from.name,
                .kind = .Function,
                .uri = uri,
                .range = codec.toLspKitRange(call.from.range),
                .selectionRange = codec.toLspKitRange(call.from.selection_range),
            },
            .fromRanges = from_ranges,
        };
    }
    return result;
}

pub fn handleOutgoingCalls(
    h: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.call_hierarchy.OutgoingCallsParams,
) ?[]const lsp.types.call_hierarchy.OutgoingCall {
    const uri = params.item.uri;
    const calls = h.computeOutgoingCalls(uri, params.item.name) catch return null;
    defer {
        for (calls) |c| h.gpa.free(c.from_ranges);
        h.gpa.free(calls);
    }
    if (calls.len == 0) return null;
    const result = arena.alloc(lsp.types.call_hierarchy.OutgoingCall, calls.len) catch return null;
    for (calls, 0..) |call, ci| {
        const from_ranges = arena.alloc(lsp.types.Range, call.from_ranges.len) catch continue;
        for (call.from_ranges, 0..) |fr, fi| from_ranges[fi] = codec.toLspKitRange(fr);
        result[ci] = .{
            .to = .{
                .name = call.to.name,
                .kind = .Function,
                .uri = uri,
                .range = codec.toLspKitRange(call.to.range),
                .selectionRange = codec.toLspKitRange(call.to.selection_range),
            },
            .fromRanges = from_ranges,
        };
    }
    return result;
}
