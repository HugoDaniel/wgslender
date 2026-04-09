//! Tests that diagnostics report correct source ranges (start AND end columns).
//!
//! Verifies that errors underline the full relevant token or expression,
//! not just a single character.

const std = @import("std");
const wgslender = @import("wgslender");

const Diagnostic = wgslender.Diagnostic;

// =========================================================================
// Helpers
// =========================================================================

fn validateSource(source: [:0]const u8) !wgslender.Validator.Result {
    return wgslender.validateWithOptions(std.testing.allocator, source, .{});
}

/// Find the first error whose message contains `pattern` and verify its range.
fn expectErrorRange(
    result: wgslender.Validator.Result,
    pattern: []const u8,
    expected_start_col: u32,
    expected_end_col: u32,
) !void {
    try std.testing.expect(!result.valid);
    const diags = result.diagnostics.diagnostics.items;
    for (diags) |d| {
        if (d.severity == .@"error" and std.mem.indexOf(u8, d.message, pattern) != null) {
            if (d.range.start.column != expected_start_col) {
                std.debug.print("\nError \"{s}\": expected start col {d}, got {d}\n", .{ pattern, expected_start_col, d.range.start.column });
            }
            try std.testing.expectEqual(expected_start_col, d.range.start.column);
            if (d.range.end.column != expected_end_col) {
                std.debug.print("\nError \"{s}\": expected end col {d}, got {d}\n", .{ pattern, expected_end_col, d.range.end.column });
            }
            try std.testing.expectEqual(expected_end_col, d.range.end.column);
            return;
        }
    }
    std.debug.print("\nNo error containing \"{s}\", got:\n", .{pattern});
    for (diags) |d| {
        std.debug.print("  {d}:{d}-{d}:{d} [{s}] {s}\n", .{ d.range.start.line, d.range.start.column, d.range.end.line, d.range.end.column, d.code, d.message });
    }
    return error.TestUnexpectedResult;
}

/// Find the first error whose message contains `pattern` and verify the range width.
fn expectErrorWidth(
    result: wgslender.Validator.Result,
    pattern: []const u8,
    expected_width: u32,
) !void {
    try std.testing.expect(!result.valid);
    const diags = result.diagnostics.diagnostics.items;
    for (diags) |d| {
        if (d.severity == .@"error" and std.mem.indexOf(u8, d.message, pattern) != null) {
            const width = d.range.end.column - d.range.start.column;
            if (width != expected_width) {
                std.debug.print("\nError \"{s}\": expected width {d}, got {d} (range {d}:{d}-{d}:{d})\n", .{ pattern, expected_width, width, d.range.start.line, d.range.start.column, d.range.end.line, d.range.end.column });
            }
            try std.testing.expectEqual(expected_width, width);
            return;
        }
    }
    std.debug.print("\nNo error containing \"{s}\"\n", .{pattern});
    return error.TestUnexpectedResult;
}

/// Verify that the first related info of the first error matching `pattern` has the given range width.
fn expectRelatedWidth(
    result: wgslender.Validator.Result,
    pattern: []const u8,
    expected_width: u32,
) !void {
    try std.testing.expect(!result.valid);
    const diags = result.diagnostics.diagnostics.items;
    for (diags) |d| {
        if (d.severity == .@"error" and std.mem.indexOf(u8, d.message, pattern) != null) {
            if (d.related.len == 0) {
                std.debug.print("\nError \"{s}\" has no related info\n", .{d.message});
                return error.TestUnexpectedResult;
            }
            const rel = d.related[0];
            const width = rel.range.end.column - rel.range.start.column;
            try std.testing.expectEqual(expected_width, width);
            return;
        }
    }
    std.debug.print("\nNo error containing \"{s}\"\n", .{pattern});
    return error.TestUnexpectedResult;
}

// =========================================================================
// Identifier ranges
// =========================================================================

test "unknown type underlines full type name" {
    const source =
        \\fn dummy() {
        \\  var x: VertexOutput;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // "VertexOutput" is 12 chars
    try expectErrorWidth(result, "unknown type", 12);
}

test "short unknown type underlines 1 char" {
    const source =
        \\fn dummy() {
        \\  var x: T;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // "T" is 1 char
    try expectErrorWidth(result, "unknown type", 1);
}

test "undefined identifier underlines full name" {
    const source =
        \\@fragment
        \\fn main() {
        \\  let x = myVariable;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // "myVariable" is 10 chars
    try expectErrorWidth(result, "undeclared identifier", 10);
}

test "short undefined identifier underlines 1 char" {
    const source =
        \\@fragment
        \\fn main() {
        \\  let x = y;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    try expectErrorWidth(result, "undeclared identifier", 1);
}

// =========================================================================
// Type ranges
// =========================================================================

test "vec shorthand type range" {
    // vec3f is 5 chars
    const source =
        \\fn dummy() {
        \\  var x: vec3f = 1;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    try expectErrorWidth(result, "cannot initialize", 1); // 'x' is the declaration name
}

test "custom struct type range in error" {
    const source =
        \\struct MyStruct { val: f32 }
        \\const x: MyStruct = 1.5;
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    try expectErrorWidth(result, "cannot initialize", 1); // 'x' is 1 char
}

// =========================================================================
// Expression ranges
// =========================================================================

test "binary operator range for +" {
    const source =
        \\@fragment
        \\fn main() {
        \\  let a = true + 1;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // '+' is 1 char
    try expectErrorWidth(result, "requires numeric", 1);
}

test "binary operator range for ==" {
    // Compare a bool and an int — incompatible types
    const source =
        \\@fragment
        \\fn main() {
        \\  let c = true == 1;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // '==' is 2 chars
    try expectErrorWidth(result, "requires compatible", 2);
}

test "binary operator range for <<" {
    const source =
        \\@fragment
        \\fn main() {
        \\  let a = true << 1u;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // '<<' is 2 chars
    try expectErrorWidth(result, "requires integer", 2);
}

test "unary operator range for !" {
    const source =
        \\@fragment
        \\fn main() {
        \\  let a = !42;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // '!' is 1 char
    try expectErrorWidth(result, "requires 'bool'", 1);
}

test "unary operator range for ~" {
    const source =
        \\@fragment
        \\fn main() {
        \\  let a = ~true;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // '~' is 1 char
    try expectErrorWidth(result, "requires integer", 1);
}

// =========================================================================
// Declaration ranges
// =========================================================================

test "const declaration name range" {
    const source =
        \\const myvar: i32 = 1.5;
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // "myvar" is 5 chars
    try expectErrorWidth(result, "cannot initialize", 5);
}

test "var declaration name range" {
    const source =
        \\fn dummy() {}
        \\var<private> myvar: i32 = 1.5;
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    try expectErrorWidth(result, "cannot initialize", 5);
}

test "let declaration name range" {
    const source =
        \\@fragment
        \\fn main() {
        \\  let mylet: i32 = 1.5;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // "mylet" is 5 chars
    try expectErrorWidth(result, "cannot initialize", 5);
}

test "override declaration name range" {
    const source =
        \\struct S { x: f32 }
        \\override o: S = 1;
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // "o" is 1 char
    try expectErrorWidth(result, "must be bool", 1);
}

// =========================================================================
// Statement keyword ranges
// =========================================================================

test "break outside loop underlines keyword" {
    const source =
        \\@fragment
        \\fn main() {
        \\  break;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // "break" is 5 chars
    try expectErrorWidth(result, "break", 5);
}

test "continue outside loop underlines keyword" {
    const source =
        \\@fragment
        \\fn main() {
        \\  continue;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // "continue" is 8 chars
    try expectErrorWidth(result, "continue", 8);
}

test "discard outside fragment underlines keyword" {
    const source =
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\  discard;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // "discard" is 7 chars
    try expectErrorWidth(result, "discard", 7);
}

test "return missing value underlines keyword" {
    const source =
        \\fn foo() -> f32 {
        \\  return;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // "return" is 6 chars
    try expectErrorWidth(result, "return must provide", 6);
}

// =========================================================================
// Member access ranges
// =========================================================================

test "member access error underlines dot+member" {
    const source =
        \\struct S { x: f32 }
        \\@fragment
        \\fn main() {
        \\  let s: S = S();
        \\  let v = s.nonexistent;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // ".nonexistent" is 1 (dot) + 11 (name) = 12 chars
    try expectErrorWidth(result, "no member", 12);
}

test "short member access error" {
    const source =
        \\struct S { x: f32 }
        \\@fragment
        \\fn main() {
        \\  let s: S = S();
        \\  let v = s.z;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // ".z" is 2 chars
    try expectErrorWidth(result, "no member", 2);
}

// =========================================================================
// Call expression ranges
// =========================================================================

test "unknown function call underlines function name" {
    const source =
        \\@fragment
        \\fn main() {
        \\  nonexistent(1.0);
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // "nonexistent" is 11 chars — error message varies (could be "undeclared" or "not callable")
    try expectErrorWidth(result, "nonexistent", 11);
}

// =========================================================================
// Related info ranges
// =========================================================================

test "related info for duplicate member spans full name" {
    const source =
        \\struct Foo {
        \\  myfield: f32,
        \\  myfield: i32,
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // Primary error: "myfield" is 7 chars
    try expectErrorWidth(result, "duplicate member", 7);
    // Related: "first declared here" also spans "myfield" = 7 chars
    try expectRelatedWidth(result, "duplicate member", 7);
}

test "related info for type annotation spans type name" {
    const source =
        \\const x: i32 = 1.5;
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // Related: "type 'i32' declared here" spans "i32" = 3 chars
    try expectRelatedWidth(result, "cannot initialize", 3);
}

// =========================================================================
// Return expression ranges
// =========================================================================

test "return type mismatch underlines return expression" {
    const source =
        \\fn foo() -> i32 {
        \\  return 1.5;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // "1.5" is 3 chars
    try expectErrorWidth(result, "cannot return", 3);
}

test "assignment type mismatch underlines RHS expression" {
    const source =
        \\@fragment
        \\fn main() {
        \\  var x: i32 = 0;
        \\  x = 1.5;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // "1.5" is 3 chars
    try expectErrorWidth(result, "cannot assign", 3);
}

// =========================================================================
// Recursive struct / function ranges
// =========================================================================

test "recursive struct underlines struct name" {
    const source =
        \\struct Node {
        \\  child: Node,
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // "Node" is 4 chars
    try expectErrorWidth(result, "contains itself recursively", 4);
}

// =========================================================================
// Edge cases
// =========================================================================

test "end-of-source error does not crash" {
    // This source ends abruptly — parser should handle gracefully
    const source =
        \\fn foo() {
        \\  let x: i32 =
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // Just verify no crash — may or may not have errors
    _ = result.diagnostics.count();
}

test "single-char identifier range" {
    const source =
        \\@fragment
        \\fn main() {
        \\  let a = x;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // "x" is 1 char
    try expectErrorWidth(result, "undeclared identifier", 1);
}

// =========================================================================
// Deduplication
// =========================================================================

test "unknown type in function signature is not duplicated" {
    // This used to produce 3x "unknown type 'BadType'" because resolveType
    // was called in phase 3.5 (registerFunctionSignatures) and again in
    // phase 4 (validateFunction) for parameters and return types.
    const source =
        \\@fragment
        \\fn main(input: BadType) {}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // Count how many times "unknown type 'BadType'" appears
    var count: u32 = 0;
    for (result.diagnostics.diagnostics.items) |d| {
        if (d.severity == .@"error" and std.mem.indexOf(u8, d.message, "unknown type 'BadType'") != null) {
            count += 1;
        }
    }
    try std.testing.expectEqual(@as(u32, 1), count);
}

test "unknown return type is not duplicated" {
    const source =
        \\@vertex
        \\fn main() -> BadOutput {
        \\  return vec4f(0.0);
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    var count: u32 = 0;
    for (result.diagnostics.diagnostics.items) |d| {
        if (d.severity == .@"error" and std.mem.indexOf(u8, d.message, "unknown type 'BadOutput'") != null) {
            count += 1;
        }
    }
    try std.testing.expectEqual(@as(u32, 1), count);
}

test "multiple unknown types each appear exactly once" {
    const source =
        \\@vertex
        \\fn main(a: TypeA, b: TypeB) -> TypeC {
        \\  return vec4f(0.0);
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    var count_a: u32 = 0;
    var count_b: u32 = 0;
    var count_c: u32 = 0;
    for (result.diagnostics.diagnostics.items) |d| {
        if (d.severity != .@"error") continue;
        if (std.mem.indexOf(u8, d.message, "'TypeA'") != null) count_a += 1;
        if (std.mem.indexOf(u8, d.message, "'TypeB'") != null) count_b += 1;
        if (std.mem.indexOf(u8, d.message, "'TypeC'") != null) count_c += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), count_a);
    try std.testing.expectEqual(@as(u32, 1), count_b);
    try std.testing.expectEqual(@as(u32, 1), count_c);
}
