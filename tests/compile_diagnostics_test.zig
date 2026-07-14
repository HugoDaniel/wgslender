//! Block 3.1 — the `compile` artifact must surface real diagnostics.
//!
//! Before this block, `Compiler.compile` reported syntax errors as
//! `error.OutOfMemory` and the JSON surface (`api_json.compileToResult`)
//! collapsed every failure to `[{"message":"compile failed"}]`. A first-class
//! artifact deserves a real diagnostic story: parse errors carry positions and
//! flow through the same entry serializer as validate.

const std = @import("std");
const wgslender = @import("wgslender");

const Compiler = wgslender.Compiler;
const api_json = wgslender.api_json;

test "compile: syntax error surfaces diagnostics and emits no wasm" {
    const a = std.testing.allocator;
    var result = try Compiler.compile(a, "fn broken(", .{});
    defer result.deinit(a);

    try std.testing.expect(result.errors.len > 0);
    try std.testing.expectEqual(@as(usize, 0), result.wasm.len);
}

test "compile: valid shader compiles with no errors and wasm magic" {
    const a = std.testing.allocator;
    var result = try Compiler.compile(a, "@compute @workgroup_size(1) fn main() {}", .{});
    defer result.deinit(a);

    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
    try std.testing.expect(result.wasm.len >= 8);
    try std.testing.expectEqualSlices(u8, "\x00asm", result.wasm[0..4]);
}

test "compileToResult: syntax error JSON carries a positioned diagnostic" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src = try api_json.makeSentinelSource(alloc, "fn broken(");
    const result = try api_json.compileToResult(alloc, src, "{}");

    try std.testing.expectEqual(@as(usize, 0), result.wasm.len);
    try std.testing.expect(std.mem.indexOf(u8, result.errors_json, "\"line\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.errors_json, "\"message\":") != null);
    // No longer the collapsed sentinel.
    try std.testing.expect(std.mem.indexOf(u8, result.errors_json, "compile failed") == null);
}

test "compileToResult: valid shader yields empty error array and wasm" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src = try api_json.makeSentinelSource(alloc, "@compute @workgroup_size(1) fn main() {}");
    const result = try api_json.compileToResult(alloc, src, "{}");

    try std.testing.expectEqualStrings("[]", result.errors_json);
    try std.testing.expect(result.wasm.len >= 8);
}
