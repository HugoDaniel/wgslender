//! Regression tests for parser recursive-descent depth limits.
//!
//! Property: pathological nesting must produce a `nesting_too_deep`
//! diagnostic, not a stack overflow. We feed the parser inputs whose
//! depth straddles the limit declared in `src/constants.zig`:
//!
//!   - just under the limit  → parses cleanly, no E0504 diagnostic.
//!   - just over the limit   → analysis returns invalid, E0504 surfaces.

const std = @import("std");
const wgslender = @import("wgslender");

const E0504 = "E0504";

fn buildParenExpr(arena: std.mem.Allocator, depth: u32) ![:0]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.appendSlice(arena, "fn f() -> i32 { return ");
    try buf.appendNTimes(arena, '(', depth);
    try buf.appendSlice(arena, "0");
    try buf.appendNTimes(arena, ')', depth);
    try buf.appendSlice(arena, "; }");
    return try arena.dupeZ(u8, buf.items);
}

fn buildNestedBlock(arena: std.mem.Allocator, depth: u32) ![:0]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.appendSlice(arena, "fn f() { ");
    try buf.appendNTimes(arena, '{', depth);
    try buf.appendNTimes(arena, '}', depth);
    try buf.appendSlice(arena, " }");
    return try arena.dupeZ(u8, buf.items);
}

fn buildNestedArrayType(arena: std.mem.Allocator, depth: u32) ![:0]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.appendSlice(arena, "alias T = ");
    try buf.appendNTimes(arena, '@', 0); // no-op; keeps formatting consistent
    var i: u32 = 0;
    while (i < depth) : (i += 1) try buf.appendSlice(arena, "array<");
    try buf.appendSlice(arena, "i32");
    i = 0;
    while (i < depth) : (i += 1) try buf.appendSlice(arena, ">");
    try buf.appendSlice(arena, ";");
    return try arena.dupeZ(u8, buf.items);
}

fn hasCode(result: wgslender.Validator.AnalysisResult, code: []const u8) bool {
    for (result.diagnostics.items()) |d| {
        if (std.mem.eql(u8, d.code, code)) return true;
    }
    return false;
}

test "parser: deeply nested parens just under expr limit parse without E0504" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = try buildParenExpr(arena.allocator(), 200);
    var result = try wgslender.analyze(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!hasCode(result, E0504));
}

test "parser: deeply nested parens past expr limit produce E0504" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = try buildParenExpr(arena.allocator(), 400);
    var result = try wgslender.analyze(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(hasCode(result, E0504));
}

test "parser: deeply nested compound stmts just under stmt limit parse without E0504" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = try buildNestedBlock(arena.allocator(), 100);
    var result = try wgslender.analyze(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!hasCode(result, E0504));
}

test "parser: deeply nested compound stmts past stmt limit produce E0504" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = try buildNestedBlock(arena.allocator(), 200);
    var result = try wgslender.analyze(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(hasCode(result, E0504));
}

test "parser: deeply nested array<...> just under type limit parses without E0504" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = try buildNestedArrayType(arena.allocator(), 50);
    var result = try wgslender.analyze(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!hasCode(result, E0504));
}

test "parser: deeply nested array<...> past type limit produce E0504" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = try buildNestedArrayType(arena.allocator(), 100);
    var result = try wgslender.analyze(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(hasCode(result, E0504));
}
