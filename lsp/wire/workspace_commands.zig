//! JSON encoders for the data-returning workspace commands:
//! `wgslender.showMinifiedOutput` and `wgslender/reflect`.
//!
//! Reached as `wire.workspace_commands.*` via `lsp/wire_root.zig`. The
//! WASM transport drives both helpers from `wasm/workspace_commands.zig`;
//! native parity tests reuse them to assert byte-equivalence against the
//! lsp-kit `std.json.Value` builder in `lspkit/workspace_commands.zig`.

const std = @import("std");
const Handler = @import("Handler");
const wgslender = @import("wgslender");
const primitives = @import("primitives.zig");

const Diagnostic = wgslender.Diagnostic;

/// Emit the success body for `wgslender.showMinifiedOutput`:
/// `{"uri":"…","minified_text":"…","byte_count":N,"gz_count":N}`.
pub fn appendShowMinifiedOutput(
    buf: *std.ArrayListUnmanaged(u8),
    gpa: std.mem.Allocator,
    result: Handler.MinifyCommandResult,
) void {
    primitives.appendStr(buf, gpa, "{\"uri\":\"");
    Diagnostic.appendJsonEscaped(buf, gpa, result.uri) catch {};
    primitives.appendStr(buf, gpa, "\",\"minified_text\":\"");
    Diagnostic.appendJsonEscaped(buf, gpa, result.minified_text) catch {};
    primitives.appendStr(buf, gpa, "\",\"byte_count\":");
    primitives.appendUint(buf, gpa, result.byte_count);
    primitives.appendStr(buf, gpa, ",\"gz_count\":");
    primitives.appendUint(buf, gpa, result.gz_count);
    buf.append(gpa, '}') catch {};
}

/// Emit the success body for `wgslender/reflect`:
/// `{"uri":"…","version":1|2,"json":<result.json>}`.
///
/// `result.json` is already-rendered JSON produced by `Reflect`; we
/// embed it verbatim so the wasm transport doesn't pay to re-parse it.
pub fn appendReflectResult(
    buf: *std.ArrayListUnmanaged(u8),
    gpa: std.mem.Allocator,
    result: Handler.ReflectCommandResult,
) void {
    primitives.appendStr(buf, gpa, "{\"uri\":\"");
    Diagnostic.appendJsonEscaped(buf, gpa, result.uri) catch {};
    primitives.appendStr(buf, gpa, "\",\"version\":");
    primitives.appendStr(buf, gpa, switch (result.version) {
        .v1 => "1",
        .v2 => "2",
    });
    primitives.appendStr(buf, gpa, ",\"json\":");
    buf.appendSlice(gpa, result.json) catch {};
    buf.append(gpa, '}') catch {};
}

// =========================================================================
// Tests
// =========================================================================

const testing = std.testing;

test "appendShowMinifiedOutput: shape + escapes uri/minified_text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendShowMinifiedOutput(&buf, aa, .{
        .uri = "test://a.wgsl",
        .minified_text = "fn main(){}",
        .byte_count = 11,
        .gz_count = 33,
    });

    const v = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});
    try testing.expectEqualStrings("test://a.wgsl", v.object.get("uri").?.string);
    try testing.expectEqualStrings("fn main(){}", v.object.get("minified_text").?.string);
    try testing.expectEqual(@as(i64, 11), v.object.get("byte_count").?.integer);
    try testing.expectEqual(@as(i64, 33), v.object.get("gz_count").?.integer);
}

test "appendReflectResult: embeds pre-rendered json verbatim" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendReflectResult(&buf, aa, .{
        .uri = "test://a.wgsl",
        .json = "{\"entries\":[]}",
        .version = .v2,
    });

    const v = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});
    try testing.expectEqualStrings("test://a.wgsl", v.object.get("uri").?.string);
    try testing.expectEqual(@as(i64, 2), v.object.get("version").?.integer);
    try testing.expectEqual(@as(usize, 0), v.object.get("json").?.object.get("entries").?.array.items.len);
}
