//! Bridge: `Handler.CallHierarchyItem` / `IncomingCall` /
//! `OutgoingCall` ↔ `lsp.types.call_hierarchy.*`.
//!
//! Reached as `lspkit.call_hierarchy.*` via `lsp/lspkit_root.zig`.
//!
//! Every WGSL call-hierarchy entry is a `Function` — there's no other
//! callable kind. Both transports hard-wire that via `kind = .Function`
//! (lsp-kit) / `"kind":12` (wire), so the parity harness asserts they
//! agree.

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");
const primitives = @import("primitives.zig");

/// Translate one Handler item into the lsp-kit shape. Borrows `name`
/// and `uri` from the caller (typed-arena response model — `name` lives
/// in the analysis arena, `uri` in `params`).
pub fn toLspKitItem(uri: []const u8, item: Handler.CallHierarchyItem) lsp.types.call_hierarchy.Item {
    return .{
        .name = item.name,
        .kind = .Function,
        .uri = uri,
        .range = primitives.toLspKitRange(item.range),
        .selectionRange = primitives.toLspKitRange(item.selection_range),
    };
}

/// Single-item slice for `prepareCallHierarchy` (the LSP shape is an
/// array, even though WGSL only ever resolves to one function at a
/// position).
pub fn toLspKitPrepareResult(
    arena: std.mem.Allocator,
    uri: []const u8,
    item: Handler.CallHierarchyItem,
) ![]const lsp.types.call_hierarchy.Item {
    const result = try arena.alloc(lsp.types.call_hierarchy.Item, 1);
    result[0] = toLspKitItem(uri, item);
    return result;
}

fn dupeRanges(arena: std.mem.Allocator, ranges: []const Handler.Range) ![]lsp.types.Range {
    const out = try arena.alloc(lsp.types.Range, ranges.len);
    for (ranges, 0..) |r, i| out[i] = primitives.toLspKitRange(r);
    return out;
}

pub fn toLspKitIncomingCalls(
    arena: std.mem.Allocator,
    uri: []const u8,
    calls: []const Handler.IncomingCall,
) ![]const lsp.types.call_hierarchy.IncomingCall {
    const result = try arena.alloc(lsp.types.call_hierarchy.IncomingCall, calls.len);
    for (calls, 0..) |call, ci| {
        result[ci] = .{
            .from = toLspKitItem(uri, call.from),
            .fromRanges = try dupeRanges(arena, call.from_ranges),
        };
    }
    return result;
}

pub fn toLspKitOutgoingCalls(
    arena: std.mem.Allocator,
    uri: []const u8,
    calls: []const Handler.OutgoingCall,
) ![]const lsp.types.call_hierarchy.OutgoingCall {
    const result = try arena.alloc(lsp.types.call_hierarchy.OutgoingCall, calls.len);
    for (calls, 0..) |call, ci| {
        result[ci] = .{
            .to = toLspKitItem(uri, call.to),
            .fromRanges = try dupeRanges(arena, call.from_ranges),
        };
    }
    return result;
}
