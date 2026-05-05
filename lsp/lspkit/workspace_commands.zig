//! Bridges `Handler.MinifyCommandResult` and
//! `Handler.ReflectCommandResult` into the `std.json.Value` shape the
//! lsp-kit serializer emits for `workspace/executeCommand` results.
//!
//! Reached as `lspkit.workspace_commands.*` via `lsp/lspkit_root.zig`.
//! Native adapters drive both helpers from
//! `native/workspace_commands.zig`. Strings inside the result are
//! borrowed from the arena that ran the underlying command — the same
//! arena is passed in here, so the returned `std.json.Value` is safe to
//! hand straight to `lsp.writeResponse`.

const std = @import("std");
const Handler = @import("Handler");

/// Build the `std.json.Value` body for `wgslender.showMinifiedOutput`.
/// Mirrors the shape emitted by `wire/workspace_commands.zig`.
pub fn toLspKitShowMinifiedOutput(
    arena: std.mem.Allocator,
    result: Handler.MinifyCommandResult,
) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "uri", .{ .string = result.uri });
    try obj.put(arena, "minified_text", .{ .string = result.minified_text });
    try obj.put(arena, "byte_count", .{ .integer = @as(i64, result.byte_count) });
    try obj.put(arena, "gz_count", .{ .integer = @as(i64, result.gz_count) });
    return .{ .object = obj };
}

/// Build the `std.json.Value` body for `wgslender/reflect`. The Handler
/// returns `result.json` as a pre-rendered JSON string; we parse it
/// once here so the lsp-kit serializer can re-emit it as a structured
/// value (the wasm transport embeds the same raw text verbatim — both
/// paths produce byte-equivalent output once the JSON is canonicalized).
pub fn toLspKitReflectResult(
    arena: std.mem.Allocator,
    result: Handler.ReflectCommandResult,
) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "uri", .{ .string = result.uri });
    try obj.put(arena, "version", .{ .integer = switch (result.version) {
        .v1 => 1,
        .v2 => 2,
    } });
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, result.json, .{
        .max_value_len = null,
    });
    try obj.put(arena, "json", parsed);
    return .{ .object = obj };
}

// =========================================================================
// Tests
// =========================================================================

const testing = std.testing;

test "toLspKitShowMinifiedOutput: every field appears" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const v = try toLspKitShowMinifiedOutput(aa, .{
        .uri = "test://a.wgsl",
        .minified_text = "fn main(){}",
        .byte_count = 11,
        .gz_count = 33,
    });
    try testing.expectEqualStrings("test://a.wgsl", v.object.get("uri").?.string);
    try testing.expectEqualStrings("fn main(){}", v.object.get("minified_text").?.string);
    try testing.expectEqual(@as(i64, 11), v.object.get("byte_count").?.integer);
}

test "toLspKitReflectResult: embedded json is parsed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const v = try toLspKitReflectResult(aa, .{
        .uri = "test://a.wgsl",
        .json = "{\"entries\":[]}",
        .version = .v2,
    });
    try testing.expectEqual(@as(i64, 2), v.object.get("version").?.integer);
    try testing.expect(v.object.get("json").?.object.get("entries").? == .array);
}
