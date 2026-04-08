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
