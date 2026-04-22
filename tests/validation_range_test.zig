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

test "validation range: unknown type underlines full type name" {
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

test "validation range: short unknown type underlines 1 char" {
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

test "validation range: undefined identifier underlines full name" {
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

test "validation range: short undefined identifier underlines 1 char" {
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

test "validation range: vec shorthand type range" {
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

test "validation range: custom struct type range in error" {
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

test "validation range: binary operator range for +" {
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

test "validation range: binary operator range for ==" {
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

test "validation range: binary operator range for <<" {
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

test "validation range: unary operator range for !" {
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

test "validation range: unary operator range for ~" {
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

test "validation range: const declaration name range" {
    const source =
        \\const myvar: i32 = 1.5;
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // "myvar" is 5 chars
    try expectErrorWidth(result, "cannot initialize", 5);
}

test "validation range: var declaration name range" {
    const source =
        \\fn dummy() {}
        \\var<private> myvar: i32 = 1.5;
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    try expectErrorWidth(result, "cannot initialize", 5);
}

test "validation range: let declaration name range" {
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

test "validation range: override declaration name range" {
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

test "validation range: break outside loop underlines keyword" {
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

test "validation range: continue outside loop underlines keyword" {
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

test "validation range: discard outside fragment underlines keyword" {
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

test "validation range: return missing value underlines keyword" {
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

test "validation range: member access error underlines dot+member" {
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

test "validation range: short member access error" {
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

test "validation range: unknown function call underlines function name" {
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

test "validation range: related info for duplicate member spans full name" {
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

test "validation range: related info for type annotation spans type name" {
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

test "validation range: return type mismatch underlines return expression" {
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

test "validation range: assignment type mismatch underlines RHS expression" {
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

test "validation range: recursive struct underlines struct name" {
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

test "validation range: end-of-source error does not crash" {
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

test "validation range: single-char identifier range" {
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

test "validation range: unknown type in function signature is not duplicated" {
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

test "validation range: unknown return type is not duplicated" {
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

// =========================================================================
// Swizzle / vector member ranges
// =========================================================================

test "validation range: invalid swizzle underlines dot+swizzle" {
    const source =
        \\@fragment
        \\fn main() {
        \\  let v = vec3f(1.0, 2.0, 3.0);
        \\  let s = v.wxyz;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // ".wxyz" is 1 (dot) + 4 (swizzle) = 5 chars
    try expectErrorWidth(result, "swizzle", 5);
}

test "validation range: out-of-bounds swizzle component on vec2" {
    const source =
        \\@fragment
        \\fn main() {
        \\  let v = vec2f(1.0, 2.0);
        \\  let s = v.z;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // ".z" is 2 chars
    try expectErrorWidth(result, "out of bounds", 2);
}

test "validation range: mixed swizzle groups xyzw and rgba" {
    const source =
        \\@fragment
        \\fn main() {
        \\  let v = vec3f(1.0, 2.0, 3.0);
        \\  let s = v.xr;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // ".xr" is 3 chars
    try expectErrorWidth(result, "mixes xyzw and rgba", 3);
}

// =========================================================================
// Index expression ranges
// =========================================================================

test "validation range: not-indexable error underlines bracket" {
    const source =
        \\@fragment
        \\fn main() {
        \\  let x: f32 = 1.0;
        \\  let y = x[0];
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // '[' is 1 char
    try expectErrorWidth(result, "not indexable", 1);
}

test "validation range: array index type error underlines the index expression" {
    const source =
        \\@fragment
        \\fn main() {
        \\  var a: array<f32, 4>;
        \\  let v = a[1.5];
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // The `.integer_scalar` expectation reports E0200 at the offending
    // sub-expression (the `1.5` literal, 3 chars wide) rather than at the
    // opening `[` — a more useful range for editors.
    try expectErrorWidth(result, "expected integer scalar", 3);
}

test "validation range: array index inner binary underlines the whole expression" {
    const source =
        \\@fragment
        \\fn main() {
        \\  var a: array<f32, 4>;
        \\  let v = a[1.0 + 2.0];
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // `1.0 + 2.0` is 9 chars — exprSpan covers leftmost to rightmost.
    try expectErrorWidth(result, "expected integer scalar", 9);
}

test "validation range: shift RHS float underlines the literal" {
    const source =
        \\@fragment
        \\fn main() {
        \\  let v = 1u << 1.5;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // `1.5` is 3 chars — the shift RHS `.integer_scalar` points here.
    try expectErrorWidth(result, "expected integer scalar", 3);
}

test "validation range: shift RHS bool underlines the literal" {
    const source =
        \\@fragment
        \\fn main() {
        \\  let v = 1u << true;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // `true` is 4 chars.
    try expectErrorWidth(result, "expected integer scalar", 4);
}

// =========================================================================
// More unary operator ranges
// =========================================================================

test "validation range: unary negation of bool underlines -" {
    const source =
        \\@fragment
        \\fn main() {
        \\  let a = -true;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // '-' is 1 char
    try expectErrorWidth(result, "requires numeric", 1);
}

test "validation range: deref non-pointer underlines *" {
    const source =
        \\@fragment
        \\fn main() {
        \\  let x: f32 = 1.0;
        \\  let y = *x;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // '*' is 1 char
    try expectErrorWidth(result, "unary '*' requires a pointer", 1);
}

// =========================================================================
// Function call argument ranges
// =========================================================================

test "validation range: wrong argument count underlines function name" {
    const source =
        \\fn foo(a: f32, b: f32) -> f32 { return a + b; }
        \\@fragment
        \\fn main() {
        \\  let x = foo(1.0);
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // "foo" is 3 chars
    try expectErrorWidth(result, "expects 2 arguments", 3);
}

test "validation range: wrong argument type underlines function name" {
    const source =
        \\fn foo(a: i32) -> i32 { return a; }
        \\@fragment
        \\fn main() {
        \\  let x = foo(1.5);
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // "foo" is 3 chars
    try expectErrorWidth(result, "argument 1", 3);
}

test "validation range: builtin arg count error underlines function name" {
    const source =
        \\@fragment
        \\fn main() {
        \\  let x = sin();
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // "sin" is 3 chars
    try expectErrorWidth(result, "expects", 3);
}

// =========================================================================
// If / while / for condition ranges
// =========================================================================

test "validation range: if condition type error underlines condition expression" {
    const source =
        \\@fragment
        \\fn main() {
        \\  if (42) {}
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // "42" is 2 chars
    try expectErrorWidth(result, "if condition must be 'bool'", 2);
}

test "validation range: while condition type error underlines condition" {
    const source =
        \\@fragment
        \\fn main() {
        \\  while (123) {}
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // "123" is 3 chars
    try expectErrorWidth(result, "while condition must be 'bool'", 3);
}

test "validation range: for condition type error underlines condition" {
    const source =
        \\@fragment
        \\fn main() {
        \\  for (var i = 0; 99; i++) {}
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // "99" is 2 chars
    try expectErrorWidth(result, "for condition must be 'bool'", 2);
}

// =========================================================================
// Compound assignment / increment
// =========================================================================

test "validation range: compound assignment operator error underlines operator" {
    const source =
        \\@fragment
        \\fn main() {
        \\  var x: i32 = 0;
        \\  x += 1.5;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // "+=" is 2 chars
    try expectErrorWidth(result, "invalid operands", 2);
}

test "validation range: incr/decr on float underlines operand expression" {
    const source =
        \\@fragment
        \\fn main() {
        \\  var x: f32 = 0.0;
        \\  x++;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // "x" is 1 char
    try expectErrorWidth(result, "increment/decrement", 1);
}

// =========================================================================
// Empty struct range
// =========================================================================

test "validation range: empty struct error underlines struct name" {
    const source =
        \\struct Empty {}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // "Empty" is 5 chars
    try expectErrorWidth(result, "must have at least one member", 5);
}

// =========================================================================
// Missing function return range
// =========================================================================

test "validation range: missing return underlines function name" {
    const source =
        \\fn compute() -> f32 {
        \\  let x = 1.0;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // "compute" is 7 chars
    try expectErrorWidth(result, "must return a value", 7);
}

// =========================================================================
// Exact column position tests
// =========================================================================

test "validation range: error at exact column with indentation" {
    const source =
        \\@fragment
        \\fn main() {
        \\    let myvar = unknownIdent;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // "unknownIdent" starts at col 17, ends at col 29
    try expectErrorRange(result, "undeclared identifier", 17, 29);
}

test "validation range: error at column 1 for top-level declaration" {
    const source =
        \\struct E {}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // "E" is at col 8, ends at col 9
    try expectErrorRange(result, "must have at least one member", 8, 9);
}

// =========================================================================
// Deduplication
// =========================================================================

test "validation range: multiple unknown types each appear exactly once" {
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
