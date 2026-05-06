//! Manual-JSON primitives shared by every wire codec.
//!
//! Reached as `wire.primitives.*` via `lsp/wire_root.zig`. The WASM
//! transport uses these directly; the native transport reuses them from
//! parity tests in PR3+.
//!
//! These helpers fall into two groups:
//!
//!   1. Read helpers — pure, allocator-free: `objGet`, `strVal`, `intVal`,
//!      `boolVal`, `extractUri`, `extractUriAndPosition`.
//!
//!   2. Write helpers — append onto a caller-supplied buffer with a
//!      caller-supplied allocator: `appendStr`, `appendUint`, `appendI64`,
//!      `appendId`, `formatRange`.
//!
//! Outbox helpers (`enqueue`, `sendResult`, `sendErrorCode`) stay on
//! `lsp/wasm.zig` since they need access to the per-instance outbox.

const std = @import("std");
const Handler = @import("Handler");

// =========================================================================
// Pure read helpers
// =========================================================================

pub fn objGet(val: ?*const std.json.Value, key: []const u8) ?*const std.json.Value {
    const v = val orelse return null;
    return switch (v.*) {
        .object => |obj| obj.getPtr(key),
        else => null,
    };
}

pub fn strVal(val: ?*const std.json.Value) ?[]const u8 {
    const v = val orelse return null;
    return switch (v.*) {
        .string => |s| s,
        else => null,
    };
}

pub fn intVal(val: ?*const std.json.Value) ?i64 {
    const v = val orelse return null;
    return switch (v.*) {
        .integer => |n| n,
        else => null,
    };
}

pub fn boolVal(val: ?*const std.json.Value) ?bool {
    const v = val orelse return null;
    return switch (v.*) {
        .bool => |b| b,
        else => null,
    };
}

pub fn extractUri(root: std.json.ObjectMap) ?[]const u8 {
    const params = root.getPtr("params") orelse return null;
    const td = objGet(params, "textDocument") orelse return null;
    return strVal(objGet(td, "uri"));
}

pub const UriPosition = struct { uri: []const u8, line: u32, char: u32 };

pub fn extractUriAndPosition(root: std.json.ObjectMap) ?UriPosition {
    const params = root.getPtr("params") orelse return null;
    const td = objGet(params, "textDocument") orelse return null;
    const uri = strVal(objGet(td, "uri")) orelse return null;
    const pos = objGet(params, "position") orelse return null;
    const line = posU32(objGet(pos, "line")) orelse return null;
    const char = posU32(objGet(pos, "character")) orelse return null;
    return .{ .uri = uri, .line = line, .char = char };
}

/// Read a JSON integer that the LSP spec defines as `uinteger` (a u32).
/// Returns null for any non-integer, negative, or out-of-range value so
/// callers don't silently wrap on hostile input.
fn posU32(val: ?*const std.json.Value) ?u32 {
    const i = intVal(val) orelse return null;
    return std.math.cast(u32, i);
}

// =========================================================================
// Buffer write helpers (allocator-explicit)
// =========================================================================

pub fn appendStr(buf: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, s: []const u8) void {
    buf.appendSlice(gpa, s) catch {};
}

pub fn appendUint(buf: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, val: u32) void {
    var num_buf: [10]u8 = undefined;
    const s = std.fmt.bufPrint(&num_buf, "{d}", .{val}) catch return;
    buf.appendSlice(gpa, s) catch {};
}

pub fn appendI64(buf: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, val: i64) void {
    var num_buf: [21]u8 = undefined;
    const s = std.fmt.bufPrint(&num_buf, "{d}", .{val}) catch return;
    buf.appendSlice(gpa, s) catch {};
}

pub fn appendId(buf: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, id: ?std.json.Value) void {
    if (id) |id_val| switch (id_val) {
        .integer => |n| appendI64(buf, gpa, n),
        .string => |s| {
            buf.append(gpa, '"') catch return;
            buf.appendSlice(gpa, s) catch return;
            buf.append(gpa, '"') catch return;
        },
        else => appendStr(buf, gpa, "null"),
    } else appendStr(buf, gpa, "null");
}

pub fn formatRange(buf: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, range: Handler.Range) void {
    appendStr(buf, gpa, "{\"start\":{\"line\":");
    appendUint(buf, gpa, range.start.line);
    appendStr(buf, gpa, ",\"character\":");
    appendUint(buf, gpa, range.start.character);
    appendStr(buf, gpa, "},\"end\":{\"line\":");
    appendUint(buf, gpa, range.end.line);
    appendStr(buf, gpa, ",\"character\":");
    appendUint(buf, gpa, range.end.character);
    appendStr(buf, gpa, "}}");
}

// =========================================================================
// Tests
// =========================================================================

test "posU32: in-range integer" {
    const v: std.json.Value = .{ .integer = 42 };
    try std.testing.expectEqual(@as(?u32, 42), posU32(&v));
}

test "posU32: zero" {
    const v: std.json.Value = .{ .integer = 0 };
    try std.testing.expectEqual(@as(?u32, 0), posU32(&v));
}

test "posU32: rejects negative" {
    const v: std.json.Value = .{ .integer = -1 };
    try std.testing.expectEqual(@as(?u32, null), posU32(&v));
}

test "posU32: rejects > maxInt(u32)" {
    const v: std.json.Value = .{ .integer = @as(i64, std.math.maxInt(u32)) + 1 };
    try std.testing.expectEqual(@as(?u32, null), posU32(&v));
}

test "posU32: accepts maxInt(u32)" {
    const v: std.json.Value = .{ .integer = std.math.maxInt(u32) };
    try std.testing.expectEqual(@as(?u32, std.math.maxInt(u32)), posU32(&v));
}

test "posU32: rejects non-integer json value" {
    const v: std.json.Value = .{ .string = "12" };
    try std.testing.expectEqual(@as(?u32, null), posU32(&v));
}
