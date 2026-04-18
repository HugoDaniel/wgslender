//! Library-level tests for the `Edits` module.
//!
//! These tests exercise the bidirectional flow without going through the
//! LSP handler: analyze a shader, locate a symbol, produce TextEdits,
//! apply them to the source, and verify the rewritten source re-analyzes
//! cleanly with the expected new name.

const std = @import("std");
const wgslender = @import("wgslender");

fn findOffsetOf(source: []const u8, needle: []const u8) u32 {
    return @intCast(std.mem.indexOf(u8, source, needle) orelse unreachable);
}

test "edits: rename a const across a shader preserves comments" {
    const a = std.testing.allocator;
    const source: [:0]const u8 =
        \\// This is a load-bearing comment.
        \\const PI: f32 = 3.14;
        \\fn circumference(r: f32) -> f32 {
        \\    return 2.0 * PI * r;
        \\}
    ;

    // Analyze to get symbols.
    var analysis = try wgslender.analyze(a, source);
    defer analysis.deinit(a);
    const module = analysis.module orelse return error.TestUnexpectedResult;

    // Locate PI by searching for its declared name.
    const pi_offset = findOffsetOf(source, "PI");
    const target = wgslender.Edits.symbolAtOffset(module, pi_offset);
    try std.testing.expect(target.isValid());

    const edits = try wgslender.Edits.renameEdits(a, module, target, "TAU") orelse
        return error.TestUnexpectedResult;
    defer a.free(edits);

    // Declaration + one usage = 2 edits.
    try std.testing.expectEqual(@as(usize, 2), edits.len);

    const rewritten = try wgslender.Edits.applyEdits(a, source, edits);
    defer a.free(rewritten);

    const expected =
        \\// This is a load-bearing comment.
        \\const TAU: f32 = 3.14;
        \\fn circumference(r: f32) -> f32 {
        \\    return 2.0 * TAU * r;
        \\}
    ;
    try std.testing.expectEqualStrings(expected, rewritten);
}

test "edits: rename a struct updates type references" {
    const a = std.testing.allocator;
    const source: [:0]const u8 =
        \\struct Uniforms { t: f32 }
        \\@group(0) @binding(0) var<uniform> u: Uniforms;
        \\@compute @workgroup_size(1) fn main() { let x = u.t; }
    ;

    var analysis = try wgslender.analyze(a, source);
    defer analysis.deinit(a);
    const module = analysis.module orelse return error.TestUnexpectedResult;

    const decl_offset = findOffsetOf(source, "Uniforms");
    const target = wgslender.Edits.symbolAtOffset(module, decl_offset);
    try std.testing.expect(target.isValid());

    const edits = try wgslender.Edits.renameEdits(a, module, target, "Globals") orelse
        return error.TestUnexpectedResult;
    defer a.free(edits);

    // Declaration + one type reference = 2 edits.
    try std.testing.expectEqual(@as(usize, 2), edits.len);

    const rewritten = try wgslender.Edits.applyEdits(a, source, edits);
    defer a.free(rewritten);

    // The new source must re-analyze without errors.
    const rewritten_z = try a.dupeZ(u8, rewritten);
    defer a.free(rewritten_z);
    var re = try wgslender.analyze(a, rewritten_z);
    defer re.deinit(a);
    try std.testing.expect(re.valid);

    // And the new name must appear where the old one was.
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Globals") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Uniforms") == null);
}

test "edits: renameEdits rejects invalid identifiers" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "const x: f32 = 1.0;";
    var analysis = try wgslender.analyze(a, source);
    defer analysis.deinit(a);
    const module = analysis.module orelse return error.TestUnexpectedResult;

    const target = wgslender.Edits.symbolAtOffset(module, findOffsetOf(source, "x"));
    try std.testing.expect(target.isValid());

    // Keyword → rejected.
    try std.testing.expect((try wgslender.Edits.renameEdits(a, module, target, "fn")) == null);
    // Leading digit → rejected.
    try std.testing.expect((try wgslender.Edits.renameEdits(a, module, target, "1x")) == null);
    // Double underscore prefix → rejected.
    try std.testing.expect((try wgslender.Edits.renameEdits(a, module, target, "__bad")) == null);
}

test "edits: findReferences includes assignment writes" {
    const a = std.testing.allocator;
    const source: [:0]const u8 =
        \\var<private> counter: i32 = 0;
        \\fn bump() { counter = counter + 1; }
    ;
    var analysis = try wgslender.analyze(a, source);
    defer analysis.deinit(a);
    const module = analysis.module orelse return error.TestUnexpectedResult;

    const target = wgslender.Edits.symbolAtOffset(module, findOffsetOf(source, "counter"));
    try std.testing.expect(target.isValid());

    const refs = try wgslender.Edits.findReferences(a, module, target, true);
    defer a.free(refs);

    // Declaration (write) + LHS of assignment (write) + RHS read = 3 refs.
    try std.testing.expectEqual(@as(usize, 3), refs.len);

    var writes: usize = 0;
    for (refs) |r| if (r.is_write) {
        writes += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), writes);
}

test "edits: symbolAtOffset returns none outside any identifier" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "const x: f32 = 1.0;";
    var analysis = try wgslender.analyze(a, source);
    defer analysis.deinit(a);
    const module = analysis.module orelse return error.TestUnexpectedResult;

    // Offset at the space between `const` and `x`.
    const s = wgslender.Edits.symbolAtOffset(module, 5);
    try std.testing.expect(!s.isValid());
}

test "edits: setWorkgroupSize changes attribute args" {
    const a = std.testing.allocator;
    const source: [:0]const u8 =
        \\@compute @workgroup_size(1) fn main() {}
    ;
    var analysis = try wgslender.analyze(a, source);
    defer analysis.deinit(a);
    const module = analysis.module orelse return error.TestUnexpectedResult;

    const edits = try wgslender.Edits.setWorkgroupSize(a, source, module, "main", .{ 8, 8, 1 }) orelse
        return error.TestUnexpectedResult;
    defer wgslender.Edits.freeBuiltEdits(a, edits);
    try std.testing.expectEqual(@as(usize, 1), edits.len);

    const rewritten = try wgslender.Edits.applyEdits(a, source, edits);
    defer a.free(rewritten);
    try std.testing.expectEqualStrings("@compute @workgroup_size(8, 8) fn main() {}", rewritten);

    // New source re-analyzes clean.
    const rewritten_z = try a.dupeZ(u8, rewritten);
    defer a.free(rewritten_z);
    var re = try wgslender.analyze(a, rewritten_z);
    defer re.deinit(a);
    try std.testing.expect(re.valid);
}

test "edits: setWorkgroupSize missing entry point returns null" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "@compute @workgroup_size(1) fn main() {}";
    var analysis = try wgslender.analyze(a, source);
    defer analysis.deinit(a);
    const module = analysis.module orelse return error.TestUnexpectedResult;

    const edits = try wgslender.Edits.setWorkgroupSize(a, source, module, "nonexistent", .{ 4, 1, 1 });
    try std.testing.expect(edits == null);
}

test "edits: setWorkgroupSize missing attribute returns null" {
    const a = std.testing.allocator;
    // `main` has no @workgroup_size.
    const source: [:0]const u8 = "@fragment fn main() -> @location(0) vec4f { return vec4f(0.0); }";
    var analysis = try wgslender.analyze(a, source);
    defer analysis.deinit(a);
    const module = analysis.module orelse return error.TestUnexpectedResult;

    const edits = try wgslender.Edits.setWorkgroupSize(a, source, module, "main", .{ 4, 1, 1 });
    try std.testing.expect(edits == null);
}

test "edits: insertAt appended declaration re-analyzes clean" {
    const a = std.testing.allocator;
    const source: [:0]const u8 =
        \\@group(0) @binding(0) var<uniform> u: f32;
        \\@compute @workgroup_size(1) fn main() {}
    ;
    const append_text = "\n@group(0) @binding(1) var<storage, read> data: array<f32>;";
    const edit = wgslender.Edits.insertAt(@intCast(source.len), append_text);
    const rewritten = try wgslender.Edits.applyEdits(a, source, &.{edit});
    defer a.free(rewritten);

    const rewritten_z = try a.dupeZ(u8, rewritten);
    defer a.free(rewritten_z);
    var re = try wgslender.reflect(a, rewritten_z);
    defer re.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), re.bindings.items.len);
}
