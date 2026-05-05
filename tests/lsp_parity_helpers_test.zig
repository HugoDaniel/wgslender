//! Smoke tests for the shared parity helpers. Lives in its own file so
//! the inline tests don't fire inside every test binary that imports
//! `lsp_parity_helpers.zig` as a sibling module.

const std = @import("std");
const helpers = @import("lsp_parity_helpers.zig");

test "jsonEql: scalar equality" {
    try std.testing.expect(helpers.jsonEql(.null, .null));
    try std.testing.expect(helpers.jsonEql(.{ .bool = true }, .{ .bool = true }));
    try std.testing.expect(!helpers.jsonEql(.{ .bool = true }, .{ .bool = false }));
    try std.testing.expect(helpers.jsonEql(.{ .integer = 7 }, .{ .integer = 7 }));
    try std.testing.expect(!helpers.jsonEql(.{ .integer = 7 }, .{ .integer = 8 }));
    try std.testing.expect(helpers.jsonEql(.{ .string = "x" }, .{ .string = "x" }));
    try std.testing.expect(!helpers.jsonEql(.{ .string = "x" }, .{ .string = "y" }));
}

test "expectEqualErrorCode: matching codes pass" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const native = try helpers.writeAndParseErrorEnvelope(aa, .invalid_params, "InvalidParams");
    const wasm = try helpers.buildAndParseWasmErrorEnvelope(aa, -32602, "missing uri");
    try helpers.expectEqualErrorCode(native, wasm);
}

test "writeAndParseErrorEnvelope: emits {code, message}, omits data" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const env = try helpers.writeAndParseErrorEnvelope(aa, .method_not_found, "UnknownCommand");
    try std.testing.expectEqual(@as(i64, -32601), env.object.get("code").?.integer);
    try std.testing.expectEqualStrings("UnknownCommand", env.object.get("message").?.string);
    try std.testing.expect(env.object.get("data") == null);
}

test "buildAndParseWasmErrorEnvelope: escapes quotes and backslashes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const env = try helpers.buildAndParseWasmErrorEnvelope(aa, -32602, "say \"hi\\bye\"");
    try std.testing.expectEqual(@as(i64, -32602), env.object.get("code").?.integer);
    try std.testing.expectEqualStrings("say \"hi\\bye\"", env.object.get("message").?.string);
}
