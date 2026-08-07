//! JSON encoders for the data-returning workspace commands:
//! `wgslender.server.showMinifiedOutput` and `wgslender/reflect`.
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

/// Emit the success body for `wgslender.server.showMinifiedOutput`:
/// `{"uri":"…","minified_text":"…","byte_count":N,"gz_count":N}`.
pub fn appendShowMinifiedOutput(
    buf: *std.ArrayList(u8),
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
    buf: *std.ArrayList(u8),
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

/// Emit the success body for `wgslender/constInventory`:
/// `{"uri":"…","consts":[{"name":"…","typ":"f32","value":"0.55",
/// "liftable":true,"span":{"start":N,"end":N}},…]}`.
///
/// Rendered directly from the `ConstInfo` slice — unlike reflect, there is
/// no pre-rendered JSON to embed. The schema lives here (and is mirrored by
/// the studio's Phase-1 client).
pub fn appendConstInventoryResult(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    result: Handler.ConstInventoryCommandResult,
) void {
    primitives.appendStr(buf, gpa, "{\"uri\":\"");
    Diagnostic.appendJsonEscaped(buf, gpa, result.uri) catch {};
    primitives.appendStr(buf, gpa, "\",\"consts\":[");
    for (result.consts, 0..) |c, i| {
        if (i > 0) buf.append(gpa, ',') catch {};
        primitives.appendStr(buf, gpa, "{\"name\":\"");
        Diagnostic.appendJsonEscaped(buf, gpa, c.name) catch {};
        primitives.appendStr(buf, gpa, "\",\"typ\":\"");
        Diagnostic.appendJsonEscaped(buf, gpa, c.typ) catch {};
        primitives.appendStr(buf, gpa, "\",\"value\":\"");
        Diagnostic.appendJsonEscaped(buf, gpa, c.value) catch {};
        primitives.appendStr(buf, gpa, "\",\"liftable\":");
        primitives.appendStr(buf, gpa, if (c.liftable) "true" else "false");
        primitives.appendStr(buf, gpa, ",\"span\":{\"start\":");
        primitives.appendUint(buf, gpa, c.decl_span.start);
        primitives.appendStr(buf, gpa, ",\"end\":");
        primitives.appendUint(buf, gpa, c.decl_span.end);
        primitives.appendStr(buf, gpa, "}}");
    }
    primitives.appendStr(buf, gpa, "]}");
}

// =========================================================================
// Tests
// =========================================================================

const testing = std.testing;

test "appendShowMinifiedOutput: shape + escapes uri/minified_text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var buf: std.ArrayList(u8) = .empty;
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

    var buf: std.ArrayList(u8) = .empty;
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

test "appendConstInventoryResult: shape + liftable flag + span" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var buf: std.ArrayList(u8) = .empty;
    appendConstInventoryResult(&buf, aa, .{
        .uri = "test://a.wgsl",
        .consts = &.{
            .{ .name = "TUN_SPEED", .typ = "f32", .value = "0.55", .liftable = true, .decl_span = .{ .start = 0, .end = 28 } },
            .{ .name = "GRID_N", .typ = "u32", .value = "4u", .liftable = false, .decl_span = .{ .start = 29, .end = 51 } },
        },
    });

    const v = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});
    try testing.expectEqualStrings("test://a.wgsl", v.object.get("uri").?.string);
    const consts = v.object.get("consts").?.array;
    try testing.expectEqual(@as(usize, 2), consts.items.len);

    const speed = consts.items[0].object;
    try testing.expectEqualStrings("TUN_SPEED", speed.get("name").?.string);
    try testing.expectEqualStrings("f32", speed.get("typ").?.string);
    try testing.expectEqualStrings("0.55", speed.get("value").?.string);
    try testing.expectEqual(true, speed.get("liftable").?.bool);
    try testing.expectEqual(@as(i64, 0), speed.get("span").?.object.get("start").?.integer);
    try testing.expectEqual(@as(i64, 28), speed.get("span").?.object.get("end").?.integer);

    try testing.expectEqual(false, consts.items[1].object.get("liftable").?.bool);
}
