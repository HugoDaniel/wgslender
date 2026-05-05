//! Manual-JSON helpers shared by every WASM per-feature adapter.
//!
//! The WASM transport hand-builds JSON-RPC frames to keep the binary small
//! (no lsp-kit dependency). These helpers fall into three groups:
//!
//!   1. Read helpers — pure, allocator-free: `objGet`, `strVal`, `intVal`,
//!      `boolVal`, `extractUri`, `extractUriAndPosition`.
//!
//!   2. Write helpers — append onto a caller-supplied buffer with a
//!      caller-supplied allocator: `appendStr`, `appendUint`, `appendI64`,
//!      `appendId`, `formatRange`.
//!
//!   3. Outbox helpers — `enqueue`, `sendResult`, `sendErrorCode` sit on
//!      `Server.zig` since they need access to the per-instance outbox.

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
    const line: u32 = if (intVal(objGet(pos, "line"))) |v| @intCast(v) else return null;
    const char: u32 = if (intVal(objGet(pos, "character"))) |v| @intCast(v) else return null;
    return .{ .uri = uri, .line = line, .char = char };
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
