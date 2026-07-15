//! Tests that diagnostics populate related information correctly.
//!
//! Verifies that errors about duplicates, type mismatches, and
//! struct/function references include related locations pointing
//! to "the other place" (first declaration, type annotation, etc.).

const std = @import("std");
const wgslender = @import("wgslender");

const Diagnostic = wgslender.Diagnostic;

// =========================================================================
// Helpers
// =========================================================================

fn validateSource(source: [:0]const u8) !wgslender.Validator.Result {
    return wgslender.validateWithOptions(std.testing.allocator, source, .{});
}

/// Find the first error whose message contains `pattern` and verify it has
/// related info at the expected line/column.
fn expectRelatedAt(
    result: wgslender.Validator.Result,
    pattern: []const u8,
    related_line: u32,
    related_col: u32,
) !void {
    try std.testing.expect(!result.valid);
    const diags = result.diagnostics.diagnostics.items;
    for (diags) |d| {
        if (d.severity == .@"error" and std.mem.indexOf(u8, d.message, pattern) != null) {
            if (d.related.len == 0) {
                std.debug.print("\nError \"{s}\" has no related info\n", .{d.message});
                return error.TestUnexpectedResult;
            }
            try std.testing.expectEqual(related_line, d.related[0].range.start.line);
            try std.testing.expectEqual(related_col, d.related[0].range.start.column);
            return;
        }
    }
    std.debug.print("\nNo error containing \"{s}\", got:\n", .{pattern});
    for (diags) |d| {
        std.debug.print("  {d}:{d} [{s}] {s}\n", .{ d.range.start.line, d.range.start.column, d.code, d.message });
    }
    return error.TestUnexpectedResult;
}

/// Verify that an error containing `pattern` has related info whose message
/// contains `related_pattern`.
fn expectRelatedMessage(
    result: wgslender.Validator.Result,
    pattern: []const u8,
    related_pattern: []const u8,
) !void {
    try std.testing.expect(!result.valid);
    const diags = result.diagnostics.diagnostics.items;
    for (diags) |d| {
        if (d.severity == .@"error" and std.mem.indexOf(u8, d.message, pattern) != null) {
            if (d.related.len == 0) {
                std.debug.print("\nError \"{s}\" has no related info\n", .{d.message});
                return error.TestUnexpectedResult;
            }
            if (std.mem.indexOf(u8, d.related[0].message, related_pattern) != null) return;
            std.debug.print("\nRelated message \"{s}\" does not contain \"{s}\"\n", .{ d.related[0].message, related_pattern });
            return error.TestUnexpectedResult;
        }
    }
    std.debug.print("\nNo error containing \"{s}\"\n", .{pattern});
    return error.TestUnexpectedResult;
}

// =========================================================================
// Duplicate Detection
// =========================================================================

test "validation related: duplicate struct member has related info pointing to first member" {
    const source =
        \\struct Foo {
        \\  x: f32,
        \\  x: i32,
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit();

    // Error on second 'x' (line 3), related should point to first 'x' (line 2)
    try expectRelatedAt(result, "duplicate member 'x'", 2, 3);
    try expectRelatedMessage(result, "duplicate member 'x'", "first declared here");
}

test "validation related: duplicate @id has related info pointing to first override" {
    const source =
        \\@id(1) override a: f32;
        \\@id(1) override b: f32;
    ;
    var result = try validateSource(source);
    defer result.deinit();

    // Error on second @id(1), related should point to first @id(1) (line 1)
    try expectRelatedAt(result, "@id(1) is already used", 1, 1);
    try expectRelatedMessage(result, "@id(1) is already used", "first used here");
}

test "validation related: duplicate @group/@binding has related info pointing to first binding" {
    const source =
        \\@group(0) @binding(0) var<uniform> a: f32;
        \\@group(0) @binding(0) var<uniform> b: f32;
    ;
    var result = try validateSource(source);
    defer result.deinit();

    // Error on second binding, related should point to first var 'a' (line 1, col 36)
    try expectRelatedAt(result, "is already used by", 1, 36);
    try expectRelatedMessage(result, "is already used by", "declared here");
}

// =========================================================================
// Type Mismatches
// =========================================================================

test "validation related: const init type mismatch has related info pointing to type annotation" {
    const source =
        \\const x: i32 = 1.5;
    ;
    var result = try validateSource(source);
    defer result.deinit();

    // Related should point to 'i32' type annotation (line 1, col 10)
    try expectRelatedAt(result, "cannot initialize", 1, 10);
    try expectRelatedMessage(result, "cannot initialize", "type");
}

test "validation related: var init type mismatch has related info pointing to type annotation" {
    const source =
        \\fn foo() {
        \\  var x: i32 = 1.5;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit();

    try expectRelatedAt(result, "cannot initialize", 2, 10);
    try expectRelatedMessage(result, "cannot initialize", "type");
}

test "validation related: return type mismatch has related info pointing to return type" {
    const source =
        \\fn foo() -> i32 {
        \\  return 1.5;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit();

    // Related should point to 'i32' return type (line 1, col 13)
    try expectRelatedAt(result, "cannot return", 1, 13);
    try expectRelatedMessage(result, "cannot return", "return type");
}

test "validation related: assignment type mismatch has related info pointing to LHS" {
    const source =
        \\fn foo() {
        \\  var x: i32 = 1;
        \\  x = 1.5;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit();

    // Related should point to 'x' on LHS
    try expectRelatedMessage(result, "cannot assign", "left-hand side");
}

// =========================================================================
// Struct/Function References
// =========================================================================

test "validation related: struct has no member has related info pointing to struct definition" {
    const source =
        \\struct Foo {
        \\  x: f32,
        \\}
        \\fn bar() -> f32 {
        \\  var s: Foo;
        \\  return s.y;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit();

    // Related should point to 'Foo' struct definition (line 1)
    try expectRelatedAt(result, "has no member 'y'", 1, 8);
    try expectRelatedMessage(result, "has no member 'y'", "defined here");
}

test "validation related: function arg count mismatch has related info pointing to function" {
    const source =
        \\fn add(a: i32, b: i32) -> i32 {
        \\  return a + b;
        \\}
        \\fn bar() -> i32 {
        \\  return add(1);
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit();

    // Related should point to 'add' function declaration (line 1)
    try expectRelatedAt(result, "expects 2 arguments", 1, 4);
    try expectRelatedMessage(result, "expects 2 arguments", "declared here");
}

test "validation related: function arg type mismatch has related info pointing to function" {
    const source =
        \\fn add(a: i32, b: i32) -> i32 {
        \\  return a + b;
        \\}
        \\fn bar() -> i32 {
        \\  return add(1, 1.5);
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit();

    // Related should point to 'add' function declaration (line 1)
    try expectRelatedAt(result, "argument 2", 1, 4);
    try expectRelatedMessage(result, "argument 2", "declared here");
}

// =========================================================================
// Uniformity taint chains (E07xx)
// =========================================================================

test "validation related: barrier in non-uniform control flow points at the taint source" {
    const source =
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
        \\  if (gid.x > 0u) {
        \\    workgroupBarrier();
        \\  }
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit();

    // The E0701 barrier violation carries a `related` entry pointing back at
    // the non-uniform builtin input that made control flow non-uniform.
    try expectRelatedMessage(result, "barrier function", "non-uniform");
    try expectRelatedMessage(result, "barrier function", "global_invocation_id");
}

test "validation related: barrier gated on a storage load points at the buffer read" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data : array<u32>;
        \\@compute @workgroup_size(64)
        \\fn main() {
        \\  if (data[0] > 0u) {
        \\    workgroupBarrier();
        \\  }
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit();

    // The taint chain names the read_write storage buffer, not a builtin.
    try expectRelatedMessage(result, "barrier function", "storage buffer 'data'");
}

// =========================================================================
// JSON Serialization
// =========================================================================

test "validation related: related info is serialized in JSON output" {
    const source =
        \\struct Foo {
        \\  x: f32,
        \\  x: i32,
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit();

    // Find the duplicate member error and check JSON serialization
    const diags = result.diagnostics.diagnostics.items;
    for (diags) |d| {
        if (d.severity == .@"error" and std.mem.indexOf(u8, d.message, "duplicate member") != null) {
            try std.testing.expect(d.related.len > 0);

            // Serialize to JSON and verify related field is present
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            try Diagnostic.entryToJson(&buf, std.testing.allocator, &d);
            defer buf.deinit(std.testing.allocator);

            const json = buf.items;
            try std.testing.expect(std.mem.indexOf(u8, json, "\"related\":[") != null);
            try std.testing.expect(std.mem.indexOf(u8, json, "first declared here") != null);
            return;
        }
    }
    return error.TestUnexpectedResult;
}
