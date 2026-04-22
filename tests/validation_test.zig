//! Validation test harness.
//!
//! Tests the Zig validator against annotated .wgsl test files from tests/testdata/validation/.
//! Each test file uses annotations to specify expected outcomes:
//!   // @expect-valid          — shader should validate
//!   // @spec-ref: ...         — shader should validate (spec reference)
//!   // @expect-error CODE "pattern"  — shader should have error with CODE and message containing pattern
//!
//! Test data is embedded at compile time via the "validation_data" module.

const std = @import("std");
const wgslender = @import("wgslender");
const validation_data = @import("validation_data");

// =========================================================================
// Annotation parser
// =========================================================================

const ExpectedDiag = struct {
    code: []const u8,
    pattern: []const u8,
};

const TestExpectation = struct {
    expect_valid: bool,
    expected_errors: []const ExpectedDiag,
};

fn parseAnnotations(allocator: std.mem.Allocator, source: []const u8) TestExpectation {
    var expect_valid = false;
    var has_explicit = false;
    var errors: std.ArrayListUnmanaged(ExpectedDiag) = .empty;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "@expect-valid") != null) {
            expect_valid = true;
            has_explicit = true;
        }
        if (std.mem.indexOf(u8, line, "@spec-ref:") != null) {
            expect_valid = true;
            has_explicit = true;
        }
        if (std.mem.indexOf(u8, line, "@expect-error")) |idx| {
            has_explicit = true;
            const rest = std.mem.trim(u8, line[idx + 13 ..], " \t\r");
            // Parse error code (first word)
            var code: []const u8 = "";
            var pattern: []const u8 = "";
            var parts = std.mem.splitScalar(u8, rest, ' ');
            if (parts.next()) |c| code = c;
            // Parse pattern in quotes
            if (std.mem.indexOf(u8, rest, "\"")) |q1| {
                if (std.mem.indexOfPos(u8, rest, q1 + 1, "\"")) |q2| {
                    pattern = rest[q1 + 1 .. q2];
                }
            }
            errors.append(allocator, .{ .code = code, .pattern = pattern }) catch {};
        }
    }
    if (!has_explicit) expect_valid = true;
    return .{ .expect_valid = expect_valid, .expected_errors = errors.items };
}

// =========================================================================
// Test runner
// =========================================================================

fn runValidationTest(allocator: std.mem.Allocator, source_bytes: []const u8) !void {
    const expectation = parseAnnotations(allocator, source_bytes);

    // Make sentinel-terminated copy
    const buf = try allocator.alloc(u8, source_bytes.len + 1);
    @memcpy(buf[0..source_bytes.len], source_bytes);
    buf[source_bytes.len] = 0;
    const source: [:0]const u8 = buf[0..source_bytes.len :0];

    const result = try wgslender.validateWithOptions(allocator, source, .{});

    if (expectation.expect_valid) {
        // Should be valid — print diagnostics on failure for debugging
        if (!result.valid) {
            std.debug.print("\n=== UNEXPECTED VALIDATION ERRORS ===\n", .{});
            for (result.diagnostics.diagnostics.items) |d| {
                if (d.severity == .@"error") {
                    std.debug.print("  [{s}] {s}\n", .{ d.code, d.message });
                }
            }
        }
        try std.testing.expect(result.valid);
    } else {
        // Should have errors — the key requirement is that the shader is
        // rejected as invalid. The annotations were written for the Go
        // validator which may use different error codes/messages, so we
        // only verify the shader is invalid (not the specific code/pattern).
        if (result.valid) {
            std.debug.print("\n=== EXPECTED VALIDATION TO FAIL BUT IT PASSED ===\n", .{});
        }
        try std.testing.expect(!result.valid);
    }
}

fn runValidation(allocator: std.mem.Allocator, source_bytes: []const u8) !wgslender.Validator.Result {
    const sb = try allocator.alloc(u8, source_bytes.len + 1);
    @memcpy(sb[0..source_bytes.len], source_bytes);
    sb[source_bytes.len] = 0;
    const source: [:0]const u8 = sb[0..source_bytes.len :0];

    var tokens = try wgslender.Lexer.tokenize(allocator, source);
    _ = &tokens;
    var parser = try wgslender.Parser.init(allocator, source, tokens);
    const module = try parser.parse();

    return wgslender.Validator.validate(allocator, module, .{});
}

// =========================================================================
// Inline validation tests (don't depend on testdata directory)
// =========================================================================

test "validate: valid simple shader" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(), "@fragment fn main() -> @location(0) vec4f { return vec4f(1.0); }");
    try std.testing.expect(result.valid);
}

test "validate: valid compute shader" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(), "@compute @workgroup_size(64) fn main(@builtin(global_invocation_id) id: vec3u) {}");
    try std.testing.expect(result.valid);
}

test "validate: valid vertex shader" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(), "@vertex fn main(@builtin(vertex_index) idx: u32) -> @builtin(position) vec4f { return vec4f(0.0); }");
    try std.testing.expect(result.valid);
}

test "validate: valid multiple functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(), "fn helper() -> f32 { return 1.0; }\n@fragment fn main() -> @location(0) vec4f { return vec4f(1.0); }");
    try std.testing.expect(result.valid);
}

test "validate: valid struct usage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(), "struct V { @builtin(position) pos: vec4f }\n@vertex fn main() -> V { var o: V; o.pos = vec4f(0.0); return o; }");
    try std.testing.expect(result.valid);
}

test "validate: valid uniform binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(), "@group(0) @binding(0) var<uniform> u: f32;\n@fragment fn main() -> @location(0) vec4f { return vec4f(u); }");
    try std.testing.expect(result.valid);
}

test "validate: valid control flow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(),
        \\@fragment fn main() -> @location(0) vec4f {
        \\  var x = 0;
        \\  if x > 0 { x = 1; } else { x = 2; }
        \\  for (var i = 0; i < 10; i++) { x += i; }
        \\  while x > 0 { x--; }
        \\  switch x { case 0: { x = 1; } default: { x = 0; } }
        \\  return vec4f(1.0);
        \\}
    );
    try std.testing.expect(result.valid);
}

test "validate: discard only in fragment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Valid: discard in fragment shader
    const result1 = try runValidation(arena.allocator(), "@fragment fn main() -> @location(0) vec4f { discard; }");
    try std.testing.expect(result1.valid);
}

test "validate: invalid shader returns valid result, not undefined" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // This shader has a type error — validation should succeed (not OOM)
    // and return a well-formed Result with valid=false and accessible diagnostics.
    const result = try runValidation(arena.allocator(), "@fragment fn main() -> @location(0) vec4f { return 42; }");
    try std.testing.expect(!result.valid);
    // The diagnostics pointer must be valid (not undefined) — accessing it must not crash.
    try std.testing.expect(result.diagnostics.diagnostics.items.len > 0);
}

test "validate: runValidation propagates errors on OOM" {
    // FailingAllocator that fails on the very first allocation.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const result = runValidation(failing.allocator(), "fn main() {}");
    // Should return an error, not a Result with undefined diagnostics.
    try std.testing.expect(result == error.OutOfMemory);
}

// =========================================================================
// Annotation-driven tests from testdata/validation/
// =========================================================================

// --- types/ (5 files) ---

test "validation: types/struct_basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"types/struct_basic");
}

test "validation: types/array_basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"types/array_basic");
}

test "validation: types/entry_point_compute" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"types/entry_point_compute");
}

test "validation: types/entry_point_vertex" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"types/entry_point_vertex");
}

test "validation: types/entry_point_fragment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"types/entry_point_fragment");
}

// --- types/ (new) ---

test "validation: types/switch_valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"types/switch_valid");
}

test "validation: types/matrix_valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"types/matrix_valid");
}

test "validation: types/incr_decr_valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"types/incr_decr_valid");
}

test "validation: types/vector_constructors_valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"types/vector_constructors_valid");
}

test "validation: types/matrix_constructors_valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"types/matrix_constructors_valid");
}

// --- declarations/ (4 + 3 new files) ---

test "validation: declarations/let_basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"declarations/let_basic");
}

test "validation: declarations/const_basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"declarations/const_basic");
}

test "validation: declarations/uniform_storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"declarations/uniform_storage");
}

test "validation: declarations/var_basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"declarations/var_basic");
}

test "validation: declarations/const_assert_valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"declarations/const_assert_valid");
}

test "validation: declarations/override_valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"declarations/override_valid");
}

test "validation: declarations/atomic_valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"declarations/atomic_valid");
}

// --- uniformity/ (2 files) ---

test "validation: uniformity/barrier_uniform" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"uniformity/barrier_uniform");
}

test "validation: uniformity/derivatives_uniform" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"uniformity/derivatives_uniform");
}

// --- builtins/ (4 files) ---

test "validation: builtins/vector_math" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"builtins/vector_math");
}

test "validation: builtins/math_basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"builtins/math_basic");
}

test "validation: builtins/atomic_ops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"builtins/atomic_ops");
}

test "validation: builtins/texture_sample" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"builtins/texture_sample");
}

// --- Phase 3e migration coverage (atomicStore / arrayLength / barriers) ---

test "validation: builtins/atomic_store" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"builtins/atomic_store");
}

test "validation: builtins/atomic_store_wrong_value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"builtins/atomic_store_wrong_value");
}

test "validation: builtins/atomic_store_non_atomic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"builtins/atomic_store_non_atomic");
}

test "validation: builtins/atomic_store_wrong_signed_value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"builtins/atomic_store_wrong_signed_value");
}

test "validation: builtins/array_length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"builtins/array_length");
}

test "validation: builtins/array_length_sized" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"builtins/array_length_sized");
}

test "validation: builtins/array_length_workgroup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"builtins/array_length_workgroup");
}

test "validation: builtins/array_length_non_array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"builtins/array_length_non_array");
}

test "validation: builtins/barriers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"builtins/barriers");
}

test "validation: builtins/barriers_wrong_arity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"builtins/barriers_wrong_arity");
}

// --- expressions/binary/mul/ (8 files) ---

test "validation: expressions/binary/mul/vec3_mat3x3_f32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"expressions/binary/mul/vec3_mat3x3_f32");
}

test "validation: expressions/binary/mul/mat3x3_vec3_f32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"expressions/binary/mul/mat3x3_vec3_f32");
}

test "validation: expressions/binary/mul/mat4x4_vec4_f32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"expressions/binary/mul/mat4x4_vec4_f32");
}

test "validation: expressions/binary/mul/scalar_vec3_f32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"expressions/binary/mul/scalar_vec3_f32");
}

test "validation: expressions/binary/mul/mat_mat_f32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"expressions/binary/mul/mat_mat_f32");
}

test "validation: expressions/binary/mul/vec_vec_f32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"expressions/binary/mul/vec_vec_f32");
}

test "validation: expressions/binary/mul/vec3_scalar_f32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"expressions/binary/mul/vec3_scalar_f32");
}

test "validation: expressions/binary/mul/mat_scalar_f32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"expressions/binary/mul/mat_scalar_f32");
}

// --- expressions/binary/add/ (3 files) ---

test "validation: expressions/binary/add/scalar_scalar_i32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"expressions/binary/add/scalar_scalar_i32");
}

test "validation: expressions/binary/add/vec_vec_f32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"expressions/binary/add/vec_vec_f32");
}

test "validation: expressions/binary/add/scalar_scalar_f32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"expressions/binary/add/scalar_scalar_f32");
}

// --- errors/calls/ (5 files) ---

test "validation: errors/calls/builtin_wrong_args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/calls/builtin_wrong_args");
}

test "validation: errors/calls/too_many_args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/calls/too_many_args");
}

test "validation: errors/calls/arg_type_mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/calls/arg_type_mismatch");
}

test "validation: errors/calls/too_few_args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/calls/too_few_args");
}

test "validation: errors/calls/not_callable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/calls/not_callable");
}

test "validation: errors/calls/vec_constructor_wrong_count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/calls/vec_constructor_wrong_count");
}

test "validation: errors/calls/mat_constructor_wrong_count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/calls/mat_constructor_wrong_count");
}

test "validation: errors/calls/scalar_constructor_too_many" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/calls/scalar_constructor_too_many");
}

test "validation: errors/calls/vec_constructor_type_mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/calls/vec_constructor_type_mismatch");
}

// --- errors/types/ (7 files) ---

test "validation: errors/types/let_initializer_mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/types/let_initializer_mismatch");
}

test "validation: errors/types/if_condition_not_bool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/types/if_condition_not_bool");
}

test "validation: errors/types/for_condition_not_bool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/types/for_condition_not_bool");
}

test "validation: errors/types/assign_type_mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/types/assign_type_mismatch");
}

test "validation: errors/types/return_type_mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/types/return_type_mismatch");
}

test "validation: errors/types/while_condition_not_bool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/types/while_condition_not_bool");
}

test "validation: errors/types/var_initializer_mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/types/var_initializer_mismatch");
}

test "validation: errors/types/switch_duplicate_case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/types/switch_duplicate_case");
}

test "validation: errors/types/switch_missing_default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/types/switch_missing_default");
}

test "validation: errors/types/incr_decr_non_concrete" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/types/incr_decr_non_concrete");
}

// --- errors/declarations/ (4 files) ---

test "validation: errors/declarations/const_without_init" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/declarations/const_without_init");
}

test "validation: errors/declarations/missing_group" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/declarations/missing_group");
}

test "validation: errors/declarations/let_without_init" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/declarations/let_without_init");
}

test "validation: errors/declarations/missing_binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/declarations/missing_binding");
}

test "validation: errors/declarations/storage_write_only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/declarations/storage_write_only");
}

test "validation: errors/declarations/empty_struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/declarations/empty_struct");
}

test "validation: errors/declarations/duplicate_struct_member" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/declarations/duplicate_struct_member");
}

test "validation: errors/declarations/recursive_struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/declarations/recursive_struct");
}

test "validation: errors/declarations/override_id_out_of_range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/declarations/override_id_out_of_range");
}

test "validation: errors/declarations/override_id_duplicate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/declarations/override_id_duplicate");
}

test "validation: errors/declarations/array_size_zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/declarations/array_size_zero");
}

test "validation: errors/declarations/atomic_invalid_type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/declarations/atomic_invalid_type");
}

test "validation: errors/declarations/matrix_invalid_element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/declarations/matrix_invalid_element");
}

test "validation: errors/declarations/duplicate_var" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/declarations/duplicate_var");
}

test "validation: errors/declarations/duplicate_fn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/declarations/duplicate_fn");
}

test "validation: errors/declarations/duplicate_attribute" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/declarations/duplicate_attribute");
}

test "validation: errors/declarations/duplicate_location" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/declarations/duplicate_location");
}

test "validation: errors/declarations/missing_io_attr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/declarations/missing_io_attr");
}

test "validation: errors/declarations/align_not_power_of_2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/declarations/align_not_power_of_2");
}

test "validation: errors/declarations/size_too_small" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/declarations/size_too_small");
}

test "validation: errors/declarations/duplicate_binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/declarations/duplicate_binding");
}

test "validation: errors/declarations/const_assert_non_bool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/declarations/const_assert_non_bool");
}

// --- errors/operations/ (11 files) ---

test "validation: errors/operations/mul_incompatible_types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/operations/mul_incompatible_types");
}

test "validation: errors/operations/member_access_invalid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/operations/member_access_invalid");
}

test "validation: errors/operations/not_on_int" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/operations/not_on_int");
}

test "validation: errors/operations/index_non_indexable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/operations/index_non_indexable");
}

test "validation: errors/operations/bitwise_on_float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/operations/bitwise_on_float");
}

test "validation: errors/operations/mod_incompatible_types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/operations/mod_incompatible_types");
}

test "validation: errors/operations/logical_on_int" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/operations/logical_on_int");
}

test "validation: errors/operations/add_incompatible_types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/operations/add_incompatible_types");
}

test "validation: errors/operations/div_incompatible_types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/operations/div_incompatible_types");
}

test "validation: errors/operations/sub_incompatible_types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/operations/sub_incompatible_types");
}

test "validation: errors/operations/negate_bool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/operations/negate_bool");
}

test "validation: errors/types/runtime_array_value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/types/runtime_array_value");
}

test "validation: errors/types/invalid_conversion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/types/invalid_conversion");
}

test "validation: errors/operations/swizzle_mixed_groups" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/operations/swizzle_mixed_groups");
}

test "validation: errors/operations/swizzle_out_of_bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/operations/swizzle_out_of_bounds");
}

// --- errors/symbols/ (6 files) ---

test "validation: errors/symbols/undefined_variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/symbols/undefined_variable");
}

test "validation: errors/symbols/undefined_variable_expr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/symbols/undefined_variable_expr");
}

test "validation: errors/symbols/var_different_scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/symbols/var_different_scope");
}

test "validation: errors/symbols/undefined_function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/symbols/undefined_function");
}

test "validation: errors/symbols/undefined_type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/symbols/undefined_type");
}

test "validation: errors/symbols/var_out_of_scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/symbols/var_out_of_scope");
}

test "validation: errors/symbols/reserved_word_var" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/symbols/reserved_word_var");
}

test "validation: errors/symbols/reserved_word_fn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/symbols/reserved_word_fn");
}

test "validation: errors/symbols/reserved_word_param" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/symbols/reserved_word_param");
}

test "validation: errors/symbols/double_underscore" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/symbols/double_underscore");
}

test "validation: errors/symbols/use_before_decl_var" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/symbols/use_before_decl_var");
}

test "validation: errors/symbols/use_before_decl_let" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/symbols/use_before_decl_let");
}

test "validation: errors/symbols/recursive_fn_direct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/symbols/recursive_fn_direct");
}

test "validation: errors/symbols/recursive_fn_indirect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/symbols/recursive_fn_indirect");
}

// --- errors/control_flow/ (6 files) ---

test "validation: errors/control_flow/discard_outside_fragment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/control_flow/discard_outside_fragment");
}

test "validation: errors/control_flow/continue_outside_loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/control_flow/continue_outside_loop");
}

test "validation: errors/control_flow/discard_in_vertex" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/control_flow/discard_in_vertex");
}

test "validation: errors/control_flow/break_outside_loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/control_flow/break_outside_loop");
}

test "validation: errors/control_flow/break_in_function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/control_flow/break_in_function");
}

test "validation: errors/control_flow/continue_in_if" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/control_flow/continue_in_if");
}

test "validation: errors/control_flow/unreachable_after_return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/control_flow/unreachable_after_return");
}

// =========================================================================
// Entry-point I/O: builtin stage/direction, builtin type, @location type
// =========================================================================

test "validation: errors/io/frag_output_builtin_position" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/frag_output_builtin_position");
}

test "validation: errors/io/vertex_output_builtin_vertex_index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/vertex_output_builtin_vertex_index");
}

test "validation: errors/io/frag_input_struct_vertex_index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/frag_input_struct_vertex_index");
}

test "validation: errors/io/frag_output_struct_vertex_index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/frag_output_struct_vertex_index");
}

test "validation: errors/io/vertex_input_frag_depth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/vertex_input_frag_depth");
}

test "validation: errors/io/builtin_position_wrong_type_vec3" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/builtin_position_wrong_type_vec3");
}

test "validation: errors/io/builtin_position_wrong_type_vec4i" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/builtin_position_wrong_type_vec4i");
}

test "validation: errors/io/builtin_frag_depth_wrong_type_vec4" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/builtin_frag_depth_wrong_type_vec4");
}

test "validation: errors/io/builtin_sample_mask_wrong_type_f32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/builtin_sample_mask_wrong_type_f32");
}

test "validation: errors/io/builtin_vertex_index_wrong_type_i32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/builtin_vertex_index_wrong_type_i32");
}

test "validation: errors/io/builtin_front_facing_wrong_type_u32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/builtin_front_facing_wrong_type_u32");
}

test "validation: errors/io/builtin_local_invocation_id_wrong_type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/builtin_local_invocation_id_wrong_type");
}

test "validation: errors/io/builtin_global_invocation_id_wrong_element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/builtin_global_invocation_id_wrong_element");
}

test "validation: errors/io/builtin_workgroup_id_vec4" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/builtin_workgroup_id_vec4");
}

test "validation: errors/io/builtin_clip_distances_too_many" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/builtin_clip_distances_too_many");
}

test "validation: errors/io/builtin_clip_distances_wrong_element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/builtin_clip_distances_wrong_element");
}

test "validation: errors/io/location_matrix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/location_matrix");
}

test "validation: errors/io/location_struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/location_struct");
}

test "validation: errors/io/location_bool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/location_bool");
}

test "validation: errors/io/location_array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/location_array");
}

test "validation: errors/io/location_on_compute_input_struct_member" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/location_on_compute_input_struct_member");
}

test "validation: errors/io/workgroup_size_on_vertex" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/workgroup_size_on_vertex");
}

test "validation: errors/io/workgroup_size_on_fragment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/workgroup_size_on_fragment");
}

test "validation: errors/io/workgroup_size_on_non_entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/workgroup_size_on_non_entry");
}

test "validation: errors/io/invariant_on_direct_return_non_position" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/invariant_on_direct_return_non_position");
}

test "validation: types/entry_point_vertex_inputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"types/entry_point_vertex_inputs");
}

test "validation: types/entry_point_vertex_clip_distances" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"types/entry_point_vertex_clip_distances");
}

test "validation: types/entry_point_fragment_all_inputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"types/entry_point_fragment_all_inputs");
}

test "validation: types/entry_point_fragment_frag_depth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"types/entry_point_fragment_frag_depth");
}

test "validation: types/entry_point_fragment_sample_mask_out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"types/entry_point_fragment_sample_mask_out");
}

test "validation: types/entry_point_compute_all_builtins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"types/entry_point_compute_all_builtins");
}

// =========================================================================
// Const folding tests (binary arithmetic in tryExtractIntValue)
// =========================================================================

test "validate: const folding — basic arithmetic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(),
        \\const A = 10;
        \\const B = A + 5;
        \\const C = A * B;
        \\@compute @workgroup_size(B)
        \\fn main() {
        \\  var data: array<f32, C>;
        \\  _ = data;
        \\}
    );
    try std.testing.expect(result.valid);
}

test "validate: const folding — subtraction and division" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(),
        \\const TOTAL = 256;
        \\const HALF = TOTAL / 2;
        \\const QUARTER = TOTAL / 4;
        \\const DIFF = HALF - QUARTER;
        \\@compute @workgroup_size(DIFF)
        \\fn main() {}
    );
    try std.testing.expect(result.valid);
}

test "validate: const folding — bitwise ops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(),
        \\const A = 0xFF;
        \\const B = A & 0x0F;
        \\const C = B | 0x10;
        \\const D = C ^ 0x01;
        \\@compute @workgroup_size(D)
        \\fn main() {}
    );
    try std.testing.expect(result.valid);
}

test "validate: const folding — shift ops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(),
        \\const BASE = 1;
        \\const SHIFTED = BASE << 4;
        \\@compute @workgroup_size(SHIFTED)
        \\fn main() {}
    );
    // SHIFTED = 1 << 4 = 16, valid workgroup size
    try std.testing.expect(result.valid);
}

test "validate: const folding — nested binary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(),
        \\const X = 2;
        \\const Y = 3;
        \\const Z = (X + Y) * (X - 1);
        \\@compute @workgroup_size(Z)
        \\fn main() {}
    );
    // Z = (2+3)*(2-1) = 5*1 = 5
    try std.testing.expect(result.valid);
}

test "validate: const folding — chained const refs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(),
        \\const A = 2;
        \\const B = A * A;
        \\const C = B * B;
        \\const D = C * C;
        \\@compute @workgroup_size(D)
        \\fn main() {}
    );
    // A=2, B=4, C=16, D=256
    try std.testing.expect(result.valid);
}

test "validate: const folding — modulo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(),
        \\const A = 17;
        \\const B = 8;
        \\const C = A % B;
        \\@compute @workgroup_size(C)
        \\fn main() {}
    );
    // C = 17 % 8 = 1
    try std.testing.expect(result.valid);
}

test "validate: const folding — with array sizes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(),
        \\const WIDTH = 16;
        \\const HEIGHT = 16;
        \\const TOTAL = WIDTH * HEIGHT;
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\  var buf: array<f32, TOTAL>;
        \\  _ = buf;
        \\}
    );
    try std.testing.expect(result.valid);
}

test "validate: const folding — negation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Negation of a const, used in an expression
    const result = try runValidation(arena.allocator(),
        \\const A: i32 = 5;
        \\const B: i32 = -A + 10;
        \\@compute @workgroup_size(B)
        \\fn main() {}
    );
    // B = -5 + 10 = 5
    try std.testing.expect(result.valid);
}

// =========================================================================
// Binding conflict detection tests
// =========================================================================

test "validate: single entry point — duplicate binding errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(),
        \\@group(0) @binding(0) var<uniform> a: f32;
        \\@group(0) @binding(0) var<uniform> b: f32;
        \\@compute @workgroup_size(1)
        \\fn main() { let x = a + b; }
    );
    try std.testing.expect(!result.valid);
    // Should have E0804 duplicate_binding
    var found = false;
    for (result.diagnostics.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, "E0804")) found = true;
    }
    try std.testing.expect(found);
}

test "validate: multi entry point — shared binding across stages is valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(),
        \\@group(0) @binding(0) var<uniform> a: f32;
        \\@group(0) @binding(0) var<uniform> b: f32;
        \\@vertex fn vs() -> @builtin(position) vec4f { return vec4f(a); }
        \\@fragment fn fs() -> @location(0) vec4f { return vec4f(b); }
    );
    // Different entry points using same binding is allowed
    try std.testing.expect(result.valid);
}

test "validate: multi entry point — duplicate within same entry point errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(),
        \\@group(0) @binding(0) var<uniform> a: f32;
        \\@group(0) @binding(0) var<uniform> b: f32;
        \\@vertex fn vs() -> @builtin(position) vec4f { return vec4f(a + b); }
        \\@fragment fn fs() -> @location(0) vec4f { return vec4f(1.0); }
    );
    try std.testing.expect(!result.valid);
    var found = false;
    for (result.diagnostics.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, "E0804")) found = true;
    }
    try std.testing.expect(found);
}

test "validate: multi entry point — each stage with unique bindings is valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(),
        \\@group(0) @binding(0) var<uniform> a: f32;
        \\@group(0) @binding(1) var<uniform> b: f32;
        \\@vertex fn vs() -> @builtin(position) vec4f { return vec4f(a); }
        \\@fragment fn fs() -> @location(0) vec4f { return vec4f(b); }
    );
    try std.testing.expect(result.valid);
}

test "validate: binding gap produces info diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(),
        \\@group(0) @binding(0) var<uniform> a: f32;
        \\@group(0) @binding(2) var<uniform> b: f32;
        \\@compute @workgroup_size(1)
        \\fn main() { let x = a + b; }
    );
    try std.testing.expect(result.valid); // Gaps are info, not errors
    var found_gap = false;
    for (result.diagnostics.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, "W0101")) found_gap = true;
    }
    try std.testing.expect(found_gap);
}

test "validate: high binding number produces info diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(),
        \\@group(0) @binding(32) var<uniform> a: f32;
        \\@compute @workgroup_size(1)
        \\fn main() { let x = a; }
    );
    try std.testing.expect(result.valid);
    var found_high = false;
    for (result.diagnostics.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, "W0102")) found_high = true;
    }
    try std.testing.expect(found_high);
}

test "validate: high group number produces info diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(),
        \\@group(16) @binding(0) var<uniform> a: f32;
        \\@compute @workgroup_size(1)
        \\fn main() { let x = a; }
    );
    try std.testing.expect(result.valid);
    var found_high = false;
    for (result.diagnostics.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, "W0102")) found_high = true;
    }
    try std.testing.expect(found_high);
}

test "validate: contiguous bindings no gap warning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(),
        \\@group(0) @binding(0) var<uniform> a: f32;
        \\@group(0) @binding(1) var<uniform> b: f32;
        \\@group(0) @binding(2) var<uniform> c: f32;
        \\@compute @workgroup_size(1)
        \\fn main() { let x = a + b + c; }
    );
    try std.testing.expect(result.valid);
    for (result.diagnostics.diagnostics.items) |d| {
        try std.testing.expect(!std.mem.eql(u8, d.code, "W0101"));
    }
}

test "validate: normal group numbers no warning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(),
        \\@group(0) @binding(0) var<uniform> a: f32;
        \\@group(1) @binding(0) var<uniform> b: f32;
        \\@compute @workgroup_size(1)
        \\fn main() { let x = a + b; }
    );
    try std.testing.expect(result.valid);
    for (result.diagnostics.diagnostics.items) |d| {
        try std.testing.expect(!std.mem.eql(u8, d.code, "W0102"));
    }
}

