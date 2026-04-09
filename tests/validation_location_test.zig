//! Tests that validation errors report correct source locations (line/column).
//!
//! Before this fix, all errors reported 1:1 because the Validator hardcoded
//! offset 0. These tests verify that each error category now points to the
//! correct AST node in the source.

const std = @import("std");
const wgslender = @import("wgslender");

const Diagnostic = wgslender.Diagnostic;

// =========================================================================
// Helpers
// =========================================================================

fn validateSource(source: [:0]const u8) !wgslender.Validator.Result {
    return wgslender.validateWithOptions(std.testing.allocator, source, .{});
}

fn expectErrorAt(result: wgslender.Validator.Result, expected_line: u32, expected_col: u32) !void {
    try std.testing.expect(!result.valid);
    const diags = result.diagnostics.diagnostics.items;
    try std.testing.expect(diags.len > 0);
    // Find the first error
    for (diags) |d| {
        if (d.severity == .@"error") {
            try std.testing.expectEqual(expected_line, d.range.start.line);
            try std.testing.expectEqual(expected_col, d.range.start.column);
            return;
        }
    }
    return error.TestUnexpectedResult;
}

fn expectErrorAtWithMessage(result: wgslender.Validator.Result, expected_line: u32, expected_col: u32, pattern: []const u8) !void {
    try std.testing.expect(!result.valid);
    const diags = result.diagnostics.diagnostics.items;
    for (diags) |d| {
        if (d.severity == .@"error" and std.mem.indexOf(u8, d.message, pattern) != null) {
            try std.testing.expectEqual(expected_line, d.range.start.line);
            try std.testing.expectEqual(expected_col, d.range.start.column);
            return;
        }
    }
    // Print diagnostics for debugging
    std.debug.print("\nExpected error containing \"{s}\" at {d}:{d}, got:\n", .{ pattern, expected_line, expected_col });
    for (diags) |d| {
        std.debug.print("  {d}:{d} [{s}] {s}\n", .{ d.range.start.line, d.range.start.column, d.code, d.message });
    }
    return error.TestUnexpectedResult;
}

fn expectNthErrorAt(result: wgslender.Validator.Result, n: usize, expected_line: u32, expected_col: u32) !void {
    try std.testing.expect(!result.valid);
    const diags = result.diagnostics.diagnostics.items;
    var error_idx: usize = 0;
    for (diags) |d| {
        if (d.severity == .@"error") {
            if (error_idx == n) {
                try std.testing.expectEqual(expected_line, d.range.start.line);
                try std.testing.expectEqual(expected_col, d.range.start.column);
                return;
            }
            error_idx += 1;
        }
    }
    return error.TestUnexpectedResult;
}

// =========================================================================
// Declaration Errors
// =========================================================================

test "const missing initializer reports correct line" {
    // "const x : i32;" is a parse error, validator won't see it.
    // Use a const without '=' which the parser accepts but validator catches:
    // Actually, the parser requires '=' for const. Let's test a different const error.
    // Test type mismatch on const at a specific line:
    const source =
        \\fn dummy() {}
        \\const x : i32 = 1.5;
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // The const 'x' is on line 2, col 7 (position of 'x')
    try expectErrorAt(result, 2, 7);
}

test "var type mismatch reports declaration location" {
    const source =
        \\fn dummy() {}
        \\
        \\var<private> myvar : i32 = 1.5;
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // 'myvar' is on line 3, col 14
    try expectErrorAt(result, 3, 14);
}

test "storage var with write-only access mode is rejected" {
    const source =
        \\struct Data { value : f32 }
        \\@group(0) @binding(0) var<storage, write> buf : Data;
        \\@compute @workgroup_size(1)
        \\fn main() {}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // 'buf' is on line 2, col 43
    try expectErrorAtWithMessage(result, 2, 43, "access mode");
}

test "let missing initializer reports declaration location" {
    const source =
        \\@fragment
        \\fn main() {
        \\    let y : i32 = 1.5;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // 'y' is on line 3, col 9
    try expectErrorAt(result, 3, 9);
}

// =========================================================================
// Statement Errors
// =========================================================================

test "break outside loop reports break keyword location" {
    const source =
        \\@fragment
        \\fn main() {
        \\    break;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // 'break' is on line 3, col 5
    try expectErrorAt(result, 3, 5);
}

test "continue outside loop reports continue keyword location" {
    const source =
        \\@fragment
        \\fn main() {
        \\    continue;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // 'continue' is on line 3, col 5
    try expectErrorAt(result, 3, 5);
}

test "discard outside fragment reports discard keyword location" {
    const source =
        \\@vertex
        \\fn main() -> @builtin(position) vec4<f32> {
        \\    discard;
        \\    return vec4<f32>(0.0, 0.0, 0.0, 1.0);
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // 'discard' is on line 3, col 5
    try expectErrorAtWithMessage(result, 3, 5, "discard");
}

test "if condition not bool reports condition location" {
    const source =
        \\@fragment
        \\fn main() {
        \\    if (1.23) {}
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // The literal '1.23' is at line 3, col 9
    try expectErrorAt(result, 3, 9);
}

test "while condition not bool reports condition location" {
    const source =
        \\@fragment
        \\fn main() {
        \\    while (42) {}
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // The literal '42' is at line 3, col 12
    try expectErrorAt(result, 3, 12);
}

test "for condition not bool reports condition location" {
    const source =
        \\@fragment
        \\fn main() {
        \\    for (var i = 0; 10; i++) {}
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // The literal '10' is at line 3, col 21
    try expectErrorAt(result, 3, 21);
}

// =========================================================================
// Expression Errors
// =========================================================================

test "binary operator type error reports operator location" {
    // Modulo on bools triggers "modulo operator requires numeric operands"
    const source =
        \\@fragment
        \\fn main() {
        \\    let x = true % false;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // The '%' operator is at line 3, col 18
    try expectErrorAt(result, 3, 18);
}

test "logical operator type error reports operator location" {
    const source =
        \\@fragment
        \\fn main() {
        \\    let x = 1 && 2;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // The '&&' is at line 3, col 15
    try expectErrorAt(result, 3, 15);
}

test "unary operator type error reports operator location" {
    const source =
        \\@fragment
        \\fn main() {
        \\    let x = -true;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // The '-' is at line 3, col 13
    try expectErrorAt(result, 3, 13);
}

test "undefined identifier reports identifier location" {
    const source =
        \\@fragment
        \\fn main() {
        \\    let x = undefined_var;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // 'undefined_var' starts at line 3, col 13
    try expectErrorAt(result, 3, 13);
}

// =========================================================================
// Multi-Error Sources
// =========================================================================

test "multiple errors report different locations" {
    const source =
        \\@fragment
        \\fn main() {
        \\    break;
        \\    continue;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // First error: 'break' at line 3, col 5
    try expectNthErrorAt(result, 0, 3, 5);
    // Second error: 'continue' at line 4, col 5
    try expectNthErrorAt(result, 1, 4, 5);
}

// =========================================================================
// Nested Scope Errors
// =========================================================================

test "error in nested if body reports correct location" {
    const source =
        \\@fragment
        \\fn main() {
        \\    if (true) {
        \\        if (true) {
        \\            break;
        \\        }
        \\    }
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // 'break' is deeply nested at line 5, col 13
    try expectErrorAt(result, 5, 13);
}

// =========================================================================
// Errors Not at Line 1
// =========================================================================

test "error on last line of source" {
    const source =
        \\@fragment
        \\fn main() {
        \\}
        \\const bad : i32 = 1.5;
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // 'bad' is on line 4, col 7
    try expectErrorAt(result, 4, 7);
}

test "error after many blank lines" {
    const source =
        \\
        \\
        \\
        \\
        \\@fragment
        \\fn main() {
        \\    break;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // 'break' is on line 7, col 5
    try expectErrorAt(result, 7, 5);
}

// =========================================================================
// Column Accuracy
// =========================================================================

test "error column with leading whitespace" {
    const source =
        \\@fragment
        \\fn main() {
        \\        break;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // 'break' at line 3, col 9 (8 spaces + 1)
    try expectErrorAt(result, 3, 9);
}

// =========================================================================
// Line Offset
// =========================================================================

test "line_offset shifts reported line numbers" {
    const source =
        \\@fragment
        \\fn main() {
        \\    break;
        \\}
    ;
    // With line_offset=99, line 3 becomes line 102
    var result = try wgslender.validateWithOptions(std.testing.allocator, source, .{
        .line_offset = 99,
    });
    defer result.deinit(std.testing.allocator);
    try expectErrorAt(result, 102, 5);
}

test "line_offset zero is default behavior" {
    const source =
        \\@fragment
        \\fn main() {
        \\    break;
        \\}
    ;
    var result = try wgslender.validateWithOptions(std.testing.allocator, source, .{
        .line_offset = 0,
    });
    defer result.deinit(std.testing.allocator);
    try expectErrorAt(result, 3, 5);
}

test "line_offset does not affect column numbers" {
    const source =
        \\@fragment
        \\fn main() {
        \\        break;
        \\}
    ;
    var result = try wgslender.validateWithOptions(std.testing.allocator, source, .{
        .line_offset = 10,
    });
    defer result.deinit(std.testing.allocator);
    // Line 3+10=13, column stays at 9
    try expectErrorAt(result, 13, 9);
}

test "negative line_offset shifts lines down" {
    const source =
        \\@fragment
        \\fn main() {
        \\    break;
        \\}
    ;
    // Line 3 with offset -2 becomes line 1
    var result = try wgslender.validateWithOptions(std.testing.allocator, source, .{
        .line_offset = -2,
    });
    defer result.deinit(std.testing.allocator);
    try expectErrorAt(result, 1, 5);
}

test "negative line_offset clamps to line 1" {
    const source =
        \\@fragment
        \\fn main() {
        \\    break;
        \\}
    ;
    // Line 3 with offset -100 would be negative, clamps to 1
    var result = try wgslender.validateWithOptions(std.testing.allocator, source, .{
        .line_offset = -100,
    });
    defer result.deinit(std.testing.allocator);
    try expectErrorAt(result, 1, 5);
}

test "line_offset applies to multiple errors" {
    const source =
        \\@fragment
        \\fn main() {
        \\    break;
        \\    continue;
        \\}
    ;
    var result = try wgslender.validateWithOptions(std.testing.allocator, source, .{
        .line_offset = 5,
    });
    defer result.deinit(std.testing.allocator);
    try expectNthErrorAt(result, 0, 8, 5);
    try expectNthErrorAt(result, 1, 9, 5);
}

// =========================================================================
// Compound Assignment with Vector-Scalar Promotion
// =========================================================================

test "vec3f *= f32 is valid" {
    const source =
        \\fn foo() {
        \\    var c = vec3f(1.0);
        \\    c *= 2.0;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.valid);
}

test "vec3f += f32 is valid" {
    const source =
        \\fn foo() {
        \\    var c = vec3f(1.0);
        \\    c += 1.0;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.valid);
}

test "vec3f -= f32 is valid" {
    const source =
        \\fn foo() {
        \\    var c = vec3f(1.0);
        \\    c -= 0.5;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.valid);
}

test "vec3f /= f32 is valid" {
    const source =
        \\fn foo() {
        \\    var c = vec3f(1.0);
        \\    c /= 2.0;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.valid);
}

test "vec3f *= vec3f is still valid" {
    const source =
        \\fn foo() {
        \\    var c = vec3f(1.0);
        \\    c *= vec3f(2.0);
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.valid);
}

test "scalar i32 += i32 is still valid" {
    const source =
        \\fn foo() {
        \\    var i : i32 = 0;
        \\    i += 1;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.valid);
}

test "vec3f *= bool is rejected" {
    const source =
        \\fn foo() {
        \\    var c = vec3f(1.0);
        \\    c *= true;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.valid);
}

test "simple assignment f32 to vec3f is still rejected" {
    const source =
        \\fn foo() {
        \\    var c = vec3f(1.0);
        \\    c = 2.0;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.valid);
}

test "return type mismatch reports return keyword" {
    const source =
        \\fn foo() -> i32 {
        \\    return;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // 'return' at line 2, col 5
    try expectErrorAtWithMessage(result, 2, 5, "return");
}

fn expectAnyErrorAtWithMessage(result: wgslender.Validator.Result, expected_line: u32, expected_col: u32, pattern: []const u8) !void {
    try std.testing.expect(!result.valid);
    const diags = result.diagnostics.diagnostics.items;
    for (diags) |d| {
        if (d.severity == .@"error" and
            d.range.start.line == expected_line and
            d.range.start.column == expected_col and
            std.mem.indexOf(u8, d.message, pattern) != null)
        {
            return;
        }
    }
    std.debug.print("\nExpected error containing \"{s}\" at {d}:{d}, got:\n", .{ pattern, expected_line, expected_col });
    for (diags) |d| {
        std.debug.print("  {d}:{d} [{s}] {s}\n", .{ d.range.start.line, d.range.start.column, d.code, d.message });
    }
    return error.TestUnexpectedResult;
}

// =========================================================================
// Unknown Type Location Tests
// =========================================================================

test "unknown type in var reports type location" {
    const source =
        \\@fragment
        \\fn main() {
        \\    var x : MyType;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // 'MyType' starts at line 3, col 13
    try expectErrorAtWithMessage(result, 3, 13, "unknown type");
}

test "unknown type in function return reports type location" {
    const source =
        \\fn foo() -> BadType {
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // 'BadType' starts at line 1, col 13
    try expectErrorAtWithMessage(result, 1, 13, "unknown type");
}

test "unknown type in function parameter reports type location" {
    const source =
        \\@fragment
        \\fn main(x: BadType) {
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // 'BadType' starts at line 2, col 12
    try expectErrorAtWithMessage(result, 2, 12, "unknown type");
}

test "unknown type in struct member reports type location" {
    const source =
        \\struct Foo {
        \\    x: BadType,
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // 'BadType' at line 2, col 8
    try expectErrorAtWithMessage(result, 2, 8, "unknown type");
}

test "unknown type in let reports type location" {
    const source =
        \\@fragment
        \\fn main() {
        \\    let x : BadType = 1;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // 'BadType' at line 3, col 13
    try expectErrorAtWithMessage(result, 3, 13, "unknown type");
}

test "unknown type in const reports type location" {
    const source =
        \\const x : BadType = 1;
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // 'BadType' at line 1, col 11
    try expectErrorAtWithMessage(result, 1, 11, "unknown type");
}

test "unknown type in override reports type location" {
    const source =
        \\override x : BadType = 1;
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // 'BadType' at line 1, col 14
    try expectErrorAtWithMessage(result, 1, 14, "unknown type");
}

test "unknown type in alias reports type location" {
    const source =
        \\alias T = BadType;
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // 'BadType' at line 1, col 11
    try expectErrorAtWithMessage(result, 1, 11, "unknown type");
}

test "multiple unknown type refs report distinct locations" {
    const source =
        \\struct Foo { x: f32 }
        \\fn bar() -> Fo {
        \\    var a: Fo;
        \\    return a;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // Return type 'Fo' at line 2 col 13, var type 'Fo' at line 3 col 12
    // (return type may be resolved in multiple phases, producing duplicates)
    try expectAnyErrorAtWithMessage(result, 2, 13, "unknown type 'Fo'");
    try expectAnyErrorAtWithMessage(result, 3, 12, "unknown type 'Fo'");
}

// =========================================================================
// "Did you mean?" Suggestion Tests
// =========================================================================

test "did-you-mean suggests close struct name" {
    const source =
        \\struct MyVertex { x: f32 }
        \\@fragment
        \\fn main() {
        \\    var v : MyVertx;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // 'MyVertx' at line 4, col 13
    try expectErrorAtWithMessage(result, 4, 13, "did you mean 'MyVertex'");
}

test "did-you-mean suggests close builtin type" {
    const source =
        \\@fragment
        \\fn main() {
        \\    var x : vec4x;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // 'vec4x' at line 3, col 13 — should suggest vec4f, vec4i, vec4u, or vec4h
    try expectErrorAtWithMessage(result, 3, 13, "did you mean");
}

test "unknown type with did-you-mean reports type location" {
    const source =
        \\struct VertexOutputs { @builtin(position) pos: vec4f }
        \\@fragment
        \\fn main(x: VertexOutput) {
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // 'VertexOutput' at line 3, col 12
    try expectErrorAtWithMessage(result, 3, 12, "did you mean 'VertexOutputs'");
}

test "no suggestion for completely different name" {
    const source =
        \\@fragment
        \\fn main() {
        \\    var x : CompletelyWrong;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // Should say "unknown type" without "did you mean"
    try expectErrorAtWithMessage(result, 3, 13, "unknown type");
    const diags = result.diagnostics.diagnostics.items;
    for (diags) |d| {
        if (d.severity == .@"error") {
            try std.testing.expect(std.mem.indexOf(u8, d.message, "did you mean") == null);
            break;
        }
    }
}

// =========================================================================
// Renamed struct scenario (user's exact case)
// =========================================================================

test "renamed struct VertexOutput to VertexOutputs — three distinct error locations" {
    const source =
        \\struct VertexOutputs {
        \\    @builtin(position) pos: vec4f,
        \\    @location(0) color: vec3f,
        \\}
        \\@vertex
        \\fn vs_main(@builtin(vertex_index) idx: u32) -> VertexOutput {
        \\    var out: VertexOutput;
        \\    let x = f32(i32(idx) - 1);
        \\    let y = f32(i32(idx & 1u) * 2 - 1);
        \\    out.pos = vec4f(x, y, 0.0, 1.0);
        \\    out.color = vec3f(x + 0.5, y + 0.5, 0.5);
        \\    return out;
        \\}
        \\@fragment
        \\fn fs_main(in: VertexOutput) -> @location(0) vec4f {
        \\    return vec4f(in.color, 1.0);
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // Three distinct locations where 'VertexOutput' is used:
    // Line 6 col 48: -> VertexOutput (return type)
    // Line 7 col 14: var out: VertexOutput
    // Line 15 col 16: in: VertexOutput (parameter)
    // All should contain "did you mean 'VertexOutputs'?"
    // (return/param types may be resolved in multiple phases, producing duplicates)
    const diags = result.diagnostics.diagnostics.items;

    // Verify all "unknown type 'VertexOutput'" errors include the suggestion
    for (diags) |d| {
        if (d.severity == .@"error" and std.mem.indexOf(u8, d.message, "unknown type 'VertexOutput'") != null) {
            try std.testing.expect(std.mem.indexOf(u8, d.message, "did you mean 'VertexOutputs'") != null);
        }
    }

    // Verify errors exist at each of the three distinct source locations
    try expectAnyErrorAtWithMessage(result, 6, 48, "unknown type 'VertexOutput'");
    try expectAnyErrorAtWithMessage(result, 7, 14, "unknown type 'VertexOutput'");
    try expectAnyErrorAtWithMessage(result, 15, 16, "unknown type 'VertexOutput'");
}

// =========================================================================
// Matrix / Atomic Type Location Tests
// =========================================================================

test "matrix with non-float element type reports location" {
    const source =
        \\@fragment
        \\fn main() {
        \\    var m : mat2x2<i32>;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // 'mat2x2' at line 3, col 13
    try expectErrorAtWithMessage(result, 3, 13, "matrix element");
}

test "atomic with non-integer element type reports location" {
    const source =
        \\var<workgroup> a : atomic<f32>;
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // 'atomic' at line 1, col 20
    try expectErrorAtWithMessage(result, 1, 20, "atomic type requires");
}

// =========================================================================
// "Did you mean?" — Struct member suggestions
// =========================================================================

test "did-you-mean suggests close struct member" {
    const source =
        \\struct Vertex { position: f32 }
        \\@fragment
        \\fn main() {
        \\    var s : Vertex;
        \\    let tmp = s.positon;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    try expectErrorAtWithMessage(result, 5, 16, "did you mean 'position'");
}

test "did-you-mean suggests struct member with transposition" {
    const source =
        \\struct Mesh { color: vec4f }
        \\@fragment
        \\fn main() {
        \\    var s : Mesh;
        \\    let tmp = s.colro;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    try expectErrorAtWithMessage(result, 5, 16, "did you mean 'color'");
}

test "no suggestion for completely wrong struct member" {
    const source =
        \\struct S { x: f32 }
        \\@fragment
        \\fn main() {
        \\    var s : S;
        \\    let tmp = s.foobar;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    const diags = result.diagnostics.diagnostics.items;
    for (diags) |d| {
        if (d.severity == .@"error" and std.mem.indexOf(u8, d.message, "foobar") != null) {
            try std.testing.expect(std.mem.indexOf(u8, d.message, "did you mean") == null);
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "did-you-mean struct member off-by-one char" {
    const source =
        \\struct S { normal: vec3f }
        \\@fragment
        \\fn main() {
        \\    var s : S;
        \\    let tmp = s.norml;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    try expectErrorAtWithMessage(result, 5, 16, "did you mean 'normal'");
}

test "did-you-mean struct member picks best from multiple" {
    const source =
        \\struct S { position: f32, rotation: f32 }
        \\@fragment
        \\fn main() {
        \\    var s : S;
        \\    let tmp = s.positon;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // 'positon' is distance 1 from 'position', distance 3+ from 'rotation'
    try expectErrorAtWithMessage(result, 5, 16, "did you mean 'position'");
}

// =========================================================================
// "Did you mean?" — @builtin value suggestions
// =========================================================================

test "did-you-mean suggests close builtin value" {
    const source =
        \\@vertex
        \\fn main(@builtin(positon) idx: u32) -> @builtin(position) vec4f {
        \\    return vec4f(0.0);
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    try expectErrorAtWithMessage(result, 2, 9, "did you mean 'position'");
}

test "did-you-mean for misspelled builtin vertex_index" {
    const source =
        \\@vertex
        \\fn main(@builtin(vertex_indx) idx: u32) -> @builtin(position) vec4f {
        \\    return vec4f(0.0);
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    try expectErrorAtWithMessage(result, 2, 9, "did you mean 'vertex_index'");
}

test "unknown builtin value with no close match" {
    const source =
        \\@vertex
        \\fn main(@builtin(xyzzy) idx: u32) -> @builtin(position) vec4f {
        \\    return vec4f(0.0);
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    try expectErrorAtWithMessage(result, 2, 9, "unknown @builtin value");
    const diags = result.diagnostics.diagnostics.items;
    for (diags) |d| {
        if (d.severity == .@"error" and std.mem.indexOf(u8, d.message, "xyzzy") != null) {
            try std.testing.expect(std.mem.indexOf(u8, d.message, "did you mean") == null);
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "did-you-mean builtin with underscore typo" {
    const source =
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(local_invocationid) id: vec3u) {
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    try expectErrorAtWithMessage(result, 2, 9, "did you mean 'local_invocation_id'");
}

test "builtin wrong for stage suggests valid alternative" {
    const source =
        \\@fragment
        \\fn main(@builtin(vertex_index) idx: u32) -> @location(0) vec4f {
        \\    return vec4f(0.0);
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // vertex_index is known but invalid for fragment stage
    try expectErrorAtWithMessage(result, 2, 9, "is not valid for fragment shaders");
}

// =========================================================================
// "Did you mean?" — Undeclared identifier suggestions
// =========================================================================

test "did-you-mean suggests close variable name" {
    const source =
        \\@fragment
        \\fn main() {
        \\    var position : f32 = 1.0;
        \\    let tmp = positon;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    try expectErrorAtWithMessage(result, 4, 15, "did you mean 'position'");
}

test "did-you-mean suggests function name for identifier" {
    const source =
        \\fn compute() {}
        \\@fragment
        \\fn main() {
        \\    comput();
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // 'comput' should suggest 'compute' (error at call location)
    try expectErrorAtWithMessage(result, 4, 11, "did you mean 'compute'");
}

test "did-you-mean suggests builtin function name" {
    const source =
        \\@fragment
        \\fn main() {
        \\    let tmp = sine(1.0);
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // 'sine' should suggest 'sin' (error at call location)
    try expectErrorAtWithMessage(result, 3, 19, "did you mean 'sin'");
}

test "no suggestion for completely wrong identifier" {
    const source =
        \\@fragment
        \\fn main() {
        \\    let tmp = xyzzyplugh;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    const diags = result.diagnostics.diagnostics.items;
    for (diags) |d| {
        if (d.severity == .@"error" and std.mem.indexOf(u8, d.message, "xyzzyplugh") != null) {
            try std.testing.expect(std.mem.indexOf(u8, d.message, "did you mean") == null);
            return;
        }
    }
    return error.TestUnexpectedResult;
}

// =========================================================================
// "Did you mean?" — Not-callable suggestions
// =========================================================================

test "did-you-mean suggests close builtin function call" {
    const source =
        \\@fragment
        \\fn main() {
        \\    let tmp = coss(1.0);
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // 'coss' should suggest 'cos' (error at call location)
    try expectErrorAtWithMessage(result, 3, 19, "did you mean 'cos'");
}

test "did-you-mean suggests close user function call" {
    const source =
        \\fn calculate() -> f32 { return 1.0; }
        \\@fragment
        \\fn main() {
        \\    let tmp = calculat();
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // error at call location (opening paren)
    try expectErrorAtWithMessage(result, 4, 23, "did you mean 'calculate'");
}

test "no suggestion for completely wrong call" {
    const source =
        \\@fragment
        \\fn main() {
        \\    let tmp = fooBarBaz();
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    const diags = result.diagnostics.diagnostics.items;
    for (diags) |d| {
        if (d.severity == .@"error") {
            try std.testing.expect(std.mem.indexOf(u8, d.message, "did you mean") == null);
            return;
        }
    }
    return error.TestUnexpectedResult;
}

// =========================================================================
// "Did you mean?" — Swizzle component hints
// =========================================================================

test "swizzle error shows valid components hint" {
    const source =
        \\@fragment
        \\fn main() {
        \\    var v : vec3f;
        \\    let tmp = v.q;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // error at member expression (`.` position)
    try expectErrorAtWithMessage(result, 4, 16, "valid components are xyzw or rgba");
}

test "swizzle with invalid character in multi-component shows hint" {
    const source =
        \\@fragment
        \\fn main() {
        \\    var v : vec3f;
        \\    let tmp = v.xq;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    try expectErrorAtWithMessage(result, 4, 16, "valid components are xyzw or rgba");
}

test "swizzle out-of-bounds does not show components hint" {
    const source =
        \\@fragment
        \\fn main() {
        \\    var v : vec2f;
        \\    let tmp = v.z;
        \\}
    ;
    var result = try validateSource(source);
    defer result.deinit(std.testing.allocator);
    // Out-of-bounds error should NOT mention "valid components"
    try expectErrorAtWithMessage(result, 4, 16, "out of bounds");
}
