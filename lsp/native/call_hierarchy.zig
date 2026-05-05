//! Native call-hierarchy adapters: prepareCallHierarchy,
//! callHierarchy/incomingCalls, callHierarchy/outgoingCalls. Handler
//! call + ownership lives here; shape conversion is delegated to
//! `lspkit/call_hierarchy.zig`.

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");
const lspkit = @import("lspkit");
const codec = lspkit.primitives;
const ch = lspkit.call_hierarchy;

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
    return ch.toLspKitPrepareResult(arena, params.textDocument.uri, i) catch null;
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
    return ch.toLspKitIncomingCalls(arena, uri, calls) catch null;
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
    return ch.toLspKitOutgoingCalls(arena, uri, calls) catch null;
}
