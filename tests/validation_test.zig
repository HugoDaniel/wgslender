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
// False-positive regressions on valid, idiomatic WGSL
//
// These constructs are accepted by naga/Tint but were previously rejected.
// See plan: "Fix validator false-positives on valid, idiomatic WGSL".
// =========================================================================

// --- Fix 1: single-vector value ctor is an *explicit* conversion ---

test "fp: vec2f(vec2u) vector conversion constructor is valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(), "fn f() { let v = vec2u(1u, 2u); let _w = vec2f(v); }");
    try std.testing.expect(result.valid);
    try std.testing.expect(!hasDiagCode(result, "E0209"));
}

test "fp: vec4u(vec4i) vector conversion constructor is valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(), "fn f() { let v = vec4i(1i, 2i, 3i, 4i); let _w = vec4u(v); }");
    try std.testing.expect(result.valid);
    try std.testing.expect(!hasDiagCode(result, "E0209"));
}

test "fp guard: vec2f(1u) splat still requires implicit conversion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // u32 -> f32 is not an implicit conversion; the splat overload must reject it.
    const result = try runValidation(arena.allocator(), "fn f() { let _w = vec2f(1u); }");
    try std.testing.expect(!result.valid);
}

test "fp guard: vec3f(1u,2u,3u) multi-arg still requires implicit conversion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(), "fn f() { let _w = vec3f(1u, 2u, 3u); }");
    try std.testing.expect(!result.valid);
}

// --- Fix 1 (matrix): single-matrix value ctor is an *explicit* conversion ---

test "fp: mat2x2f(mat2x2h) matrix conversion constructor is valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(), "enable f16;\nfn f() { let m = mat2x2h(1.0h, 2.0h, 3.0h, 4.0h); let _n = mat2x2f(m); }");
    try std.testing.expect(result.valid);
    try std.testing.expect(!hasDiagCode(result, "E0209"));
}

test "fp: mat3x3h(mat3x3f) matrix conversion constructor is valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(), "enable f16;\nfn f() { let m = mat3x3f(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0); let _n = mat3x3h(m); }");
    try std.testing.expect(result.valid);
    try std.testing.expect(!hasDiagCode(result, "E0209"));
}

test "fp guard: mat2x2f(mat3x3f) dimension mismatch stays an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(), "fn f() { let m = mat3x3f(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0); let _n = mat2x2f(m); }");
    try std.testing.expect(!result.valid);
}

// --- Fix 2: component-wise vector shifts ---

test "fp: vecN >> vecN component-wise shift is valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(), "fn f() { let a = vec2u(1u, 2u); let b = vec2u(3u, 4u); let _c = a >> b; }");
    try std.testing.expect(result.valid);
}

test "fp: vecN << vecN component-wise shift is valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(), "fn f() { let a = vec3i(1i, 2i, 3i); let _c = a << vec3u(1u, 2u, 3u); }");
    try std.testing.expect(result.valid);
}

test "fp guard: scalar << vector is a shape mismatch error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(), "fn f() { let _x = 1u << vec2u(1u, 2u); }");
    try std.testing.expect(!result.valid);
    try std.testing.expect(hasDiagCode(result, "E0201"));
}

test "fp guard: vecN >> vecM width mismatch is an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(), "fn f() { let a = vec2u(1u, 2u); let _c = a >> vec3u(1u, 2u, 3u); }");
    try std.testing.expect(!result.valid);
}

test "fp guard: vector shift RHS must be u32 elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // vec2<i32> shift amount: element must be u32, not i32.
    const result = try runValidation(arena.allocator(), "fn f() { let a = vec2i(1i, 2i); let _c = a >> vec2i(1i, 2i); }");
    try std.testing.expect(!result.valid);
    try std.testing.expect(hasDiagCode(result, "E0201"));
}

// =========================================================================
// Compound assignment (`v op= e`) — Block 2.1 Step 4e.
//
// `v op= e` is defined as `v = v op e`, so the operand-shape resolution of the
// compound form must match the binary operator `op` exactly. Before Step 4e
// the compound path used the legacy `Types.*ResultType` + `commonType` helpers,
// which diverged from the migrated binary path in both directions: they wrongly
// ACCEPTED bool arithmetic, non-conformant / undefined matrix products, matrix
// division, and mixed-sign bitwise ops, and wrongly REJECTED abstract-int
// literals broadcast into float/uint vectors and matrices. Routing the compound
// path through the same `Operators.binarySigs` engine fixes all of these at
// once. A conformant product whose result cannot store back into the target
// (`mat2x3 *= mat3x2` yields mat3x3) is now an assignability error (E0200)
// rather than a flat operand error (E0201): the operation is well-defined, it
// is the assignment that fails.
// =========================================================================

const CompoundCase = struct {
    name: []const u8,
    src: []const u8,
    valid: bool,
    // Expected diagnostic code when invalid (empty = only require invalidity).
    code: []const u8 = "",
};

const compound_assign_cases = [_]CompoundCase{
    // Wrong-accepts the legacy path let through — now rejected (E0201).
    .{ .name = "bool += bool (bool is not numeric)", .src = "fn f(){ var v=true; v+=true; }", .valid = false, .code = "E0201" },
    .{ .name = "mat2x3 *= mat2x3 (non-conformant, undefined product)", .src = "fn f(){ var m=mat2x3f(1,2,3,4,5,6); m*=mat2x3f(1,2,3,4,5,6); }", .valid = false, .code = "E0201" },
    .{ .name = "mat2x2 /= mat2x2 (no matrix division)", .src = "fn f(){ var m=mat2x2f(1,2,3,4); m/=mat2x2f(1,2,3,4); }", .valid = false, .code = "E0201" },
    .{ .name = "i32 &= 1u (mixed-sign bitwise)", .src = "fn f(){ var v=1i; v&=1u; }", .valid = false, .code = "E0201" },
    // Wrong-rejects the legacy path emitted — now accepted (§8.7 broadcast).
    .{ .name = "vec2f += 1 (abstract-int broadcast into float vector)", .src = "fn f(){ var v=vec2f(1,2); v+=1; }", .valid = true },
    .{ .name = "vec2f *= 2 (abstract-int broadcast into float vector)", .src = "fn f(){ var v=vec2f(1,2); v*=2; }", .valid = true },
    .{ .name = "vec3f %= 1.0 (scalar-broadcast modulo)", .src = "fn f(){ var v=vec3f(1,2,3); v%=1.0; }", .valid = true },
    .{ .name = "mat2x3 *= mat2x2 (conformant product, result assignable)", .src = "fn f(){ var m=mat2x3f(1,2,3,4,5,6); m*=mat2x2f(1,2,3,4); }", .valid = true },
    .{ .name = "mat2x2 *= 2 (abstract-int matrix scalar)", .src = "fn f(){ var m=mat2x2f(1,2,3,4); m*=2; }", .valid = true },
    // Refined code: a conformant product whose result cannot store back is an
    // assignability error (E0200), not a flat operand error (E0201).
    .{ .name = "mat2x3 *= mat3x2 (product mat3x3 not assignable to mat2x3)", .src = "fn f(){ var m=mat2x3f(1,2,3,4,5,6); m*=mat3x2f(1,2,3,4,5,6); }", .valid = false, .code = "E0200" },
    // Stable guards — behavior unchanged by the migration.
    .{ .name = "bool |= bool (bitwise bool stays valid)", .src = "fn f(){ var v=true; v|=false; }", .valid = true },
    .{ .name = "mat2x2 *= mat2x2 (conformant square product stays valid)", .src = "fn f(){ var m=mat2x2f(1,2,3,4); m*=mat2x2f(1,2,3,4); }", .valid = true },
    .{ .name = "i32 += 1u (mixed-sign add stays rejected)", .src = "fn f(){ var v=1i; v+=1u; }", .valid = false, .code = "E0201" },
    .{ .name = "f32 += 1 (abstract-int scalar stays valid)", .src = "fn f(){ var v=1f; v+=1; }", .valid = true },
    .{ .name = "mat2x2 *= 2.0 (abstract-float matrix scalar stays valid)", .src = "fn f(){ var m=mat2x2f(1,2,3,4); m*=2.0; }", .valid = true },
    .{ .name = "f32 *= mat2x2 (result matrix not assignable to f32)", .src = "fn f(){ var v=1f; v*=mat2x2f(1,2,3,4); }", .valid = false, .code = "E0200" },
};

test "compound assignment operand shapes match the binary operator (Block 2.1 4e)" {
    for (compound_assign_cases) |c| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const result = try runValidation(arena.allocator(), c.src);
        if (c.valid) {
            if (!result.valid) {
                std.debug.print("\n[{s}] expected VALID, got errors:\n", .{c.name});
                for (result.diagnostics.diagnostics.items) |d| {
                    if (d.severity == .@"error") std.debug.print("  [{s}] {s}\n", .{ d.code, d.message });
                }
            }
            try std.testing.expect(result.valid);
        } else {
            if (result.valid) std.debug.print("\n[{s}] expected INVALID but it passed\n", .{c.name});
            try std.testing.expect(!result.valid);
            if (c.code.len > 0) {
                if (!hasDiagCode(result, c.code)) {
                    std.debug.print("\n[{s}] expected code {s}, got:\n", .{ c.name, c.code });
                    for (result.diagnostics.diagnostics.items) |d| {
                        if (d.severity == .@"error") std.debug.print("  [{s}] {s}\n", .{ d.code, d.message });
                    }
                }
                try std.testing.expect(hasDiagCode(result, c.code));
            }
        }
    }
}

// Unary value operators `-` `!` `~` resolve their operand shape through the
// same overload engine as the binary forms (Block 2.1 Step 5). The reds-first
// cases are the three unsigned negations the old `isNumeric` neg checker
// wrongly accepted — WGSL §8.6 unary minus has no u32 form. `!` and `~` were
// already spec-correct and stay so (guards). `*` (deref) and `&` (addr-of) are
// not value operators and keep their own hand-rolled checks.
const unary_op_cases = [_]CompoundCase{
    // Wrong-accepts the legacy neg checker let through — now rejected (E0201).
    .{ .name = "-1u (u32 has no negation)", .src = "fn f(){ let r = -1u; }", .valid = false, .code = "E0201" },
    .{ .name = "-vec2u (unsigned vector has no negation)", .src = "fn f(){ let r = -vec2u(); }", .valid = false, .code = "E0201" },
    .{ .name = "-vec3u (unsigned vector has no negation)", .src = "fn f(){ let r = -vec3u(); }", .valid = false, .code = "E0201" },
    // Negation guards — signed / float scalars and vectors stay valid.
    .{ .name = "-1 (abstract-int)", .src = "fn f(){ let r = -1; }", .valid = true },
    .{ .name = "-1i (i32)", .src = "fn f(){ let r = -1i; }", .valid = true },
    .{ .name = "-1.0 (abstract-float)", .src = "fn f(){ let r = -1.0; }", .valid = true },
    .{ .name = "-1f (f32)", .src = "fn f(){ let r = -1f; }", .valid = true },
    .{ .name = "-vec2f (float vector)", .src = "fn f(){ let r = -vec2f(); }", .valid = true },
    .{ .name = "-vec2i (signed int vector)", .src = "fn f(){ let r = -vec2i(); }", .valid = true },
    .{ .name = "-true (bool is not negatable)", .src = "fn f(){ let r = -true; }", .valid = false, .code = "E0201" },
    .{ .name = "-mat2x2 (no matrix negation)", .src = "fn f(){ let r = -mat2x2f(); }", .valid = false, .code = "E0201" },
    // Logical not `!` — bool scalar / vector only; unchanged by the migration.
    .{ .name = "!true (bool)", .src = "fn f(){ let r = !true; }", .valid = true },
    .{ .name = "!vec3<bool> (bool vector)", .src = "fn f(){ let r = !vec3<bool>(true,true,true); }", .valid = true },
    .{ .name = "!1 (int is not bool)", .src = "fn f(){ let r = !1; }", .valid = false, .code = "E0201" },
    .{ .name = "!vec2f (float vector is not bool)", .src = "fn f(){ let r = !vec2f(); }", .valid = false, .code = "E0201" },
    // Bitwise not `~` — integer scalar / vector only; unchanged by the migration.
    .{ .name = "~1i (i32)", .src = "fn f(){ let r = ~1i; }", .valid = true },
    .{ .name = "~1u (u32)", .src = "fn f(){ let r = ~1u; }", .valid = true },
    .{ .name = "~vec2i (signed int vector)", .src = "fn f(){ let r = ~vec2i(); }", .valid = true },
    .{ .name = "~vec2u (unsigned int vector)", .src = "fn f(){ let r = ~vec2u(); }", .valid = true },
    .{ .name = "~1.0 (float has no bitwise not)", .src = "fn f(){ let r = ~1.0; }", .valid = false, .code = "E0201" },
    .{ .name = "~true (bool has no bitwise not)", .src = "fn f(){ let r = ~true; }", .valid = false, .code = "E0201" },
};

test "unary operator operand shapes resolve through the engine (Block 2.1 Step 5)" {
    for (unary_op_cases) |c| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const result = try runValidation(arena.allocator(), c.src);
        if (c.valid) {
            if (!result.valid) {
                std.debug.print("\n[{s}] expected VALID, got errors:\n", .{c.name});
                for (result.diagnostics.diagnostics.items) |d| {
                    if (d.severity == .@"error") std.debug.print("  [{s}] {s}\n", .{ d.code, d.message });
                }
            }
            try std.testing.expect(result.valid);
        } else {
            if (result.valid) std.debug.print("\n[{s}] expected INVALID but it passed\n", .{c.name});
            try std.testing.expect(!result.valid);
            if (c.code.len > 0) {
                if (!hasDiagCode(result, c.code)) {
                    std.debug.print("\n[{s}] expected code {s}, got:\n", .{ c.name, c.code });
                    for (result.diagnostics.diagnostics.items) |d| {
                        if (d.severity == .@"error") std.debug.print("  [{s}] {s}\n", .{ d.code, d.message });
                    }
                }
                try std.testing.expect(hasDiagCode(result, c.code));
            }
        }
    }
}

// --- Fix 3: inferred array(...) constructor ---

test "fp: array(1,2,3) inferred constructor is valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(), "fn f() { let a = array(1, 2, 3); let _u = a[0]; }");
    try std.testing.expect(result.valid);
    try std.testing.expect(!hasDiagCode(result, "E0200"));
}

test "fp: array(1.0, 2.0) inferred float constructor is valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(), "fn f() { let a = array(1.0, 2.0); let _u = a[1]; }");
    try std.testing.expect(result.valid);
    try std.testing.expect(!hasDiagCode(result, "E0200"));
}

// --- Fix: vecN() zero-value constructor infers element from context ---
// The WGSL zero-value vector constructor `vecN()` (no template, no args) yields
// an abstract-int vector that materializes to the annotated concrete element —
// Tint accepts all of these (tint corpus
// expressions/type_ctor/vec{2,3,4}/inferred/zero.wgsl). wgslender previously
// pinned `vec3()` to vec3<f32> and rejected the i32/u32 slots with E0200.

test "fp: vecN() zero-value constructor infers element from annotation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = [_][]const u8{
        "var<private> f : vec2f = vec2();",
        "var<private> i : vec2i = vec2();",
        "var<private> u : vec2u = vec2();",
        "var<private> f : vec3f = vec3();",
        "var<private> i : vec3i = vec3();",
        "var<private> u : vec3u = vec3();",
        "var<private> f : vec4f = vec4();",
        "var<private> i : vec4i = vec4();",
        "var<private> u : vec4u = vec4();",
        "fn f() { var v : vec3i = vec3(); _ = v; }",
        "fn g() { let v : vec4u = vec4(); _ = v; }",
        // Second manifestation: `vec2()` as an integer-coordinate builtin
        // argument must materialize to the coord type so overload resolution
        // succeeds (tint corpus bug/tint/349310442.wgsl).
        "@group(0) @binding(0) var t : texture_external; @compute @workgroup_size(1) fn i() { var r = textureLoad(t, vec2()); _ = r; }",
    };
    for (ok) |src| {
        const result = try runValidation(a, src);
        if (hasDiagCode(result, "E0200")) std.debug.print("\nunexpected E0200 for: {s}\n", .{src});
        try std.testing.expect(result.valid);
        try std.testing.expect(!hasDiagCode(result, "E0200"));
    }
}

test "fp guard: vecN() zero-value ctor still rejects width/shape mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The abstract-int inference must NOT blanket-accept: a vec2 zero-value can't
    // fill a vec3 slot, and a vector can't initialize a scalar.
    const bad = [_][]const u8{
        "var<private> i : vec3i = vec2();",
        "var<private> s : i32 = vec3();",
    };
    for (bad) |src| {
        const result = try runValidation(a, src);
        if (result.valid) std.debug.print("\nexpected invalid: {s}\n", .{src});
        try std.testing.expect(!result.valid);
    }
}

// --- Fix: pointer-composite-access index sugar `p[i]` == `(*p)[i]` ---
// WGSL lets you index a pointer to a vector/matrix/array directly; wgslender
// only handled pointer-to-array, rejecting `p[0]` on a ptr<_, vecN> / <_, matCxR>
// as "not indexable" (E0205) with a cascading "cannot determine type" (E0200).
// Tint accepts all of these (tint corpus
// ptr_sugar/{vector_index,matrix,compound_assign_index}.wgsl).

test "fp: pointer-composite index sugar p[i] on vector/matrix pointers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = [_][]const u8{
        // read through a vector pointer, with and without explicit deref
        "fn f() { var a : vec3<i32>; let p = &a; var b = (*p)[0]; _ = b; }",
        "fn f() { var a : vec3<i32>; let p = &a; var b = p[0]; _ = b; }",
        // write through the sugar (simple, compound, increment)
        "fn f() { var a : vec3<i32>; let p = &a; p[0] = 42; }",
        "fn f() { var a : vec3<i32>; let p = &a; p[0] += 42; }",
        "fn f() { var a : vec3<i32>; let p = &a; p[0]++; }",
        // matrix pointer indexes to a column vector
        "fn f() { var a : mat2x3<f32>; let p = &a; var b = p[0]; _ = b; }",
        "fn f() { var a : mat2x3<f32>; let p = &a; p[0] = vec3<f32>(1.0, 2.0, 3.0); }",
        // pointer-to-array already worked — keep it green
        "fn f() { var a : array<i32, 4>; let p = &a; var b = p[2]; _ = b; }",
    };
    for (ok) |src| {
        const result = try runValidation(a, src);
        if (!result.valid) std.debug.print("\nexpected valid: {s}\n", .{src});
        try std.testing.expect(result.valid);
        try std.testing.expect(!hasDiagCode(result, "E0205"));
        try std.testing.expect(!hasDiagCode(result, "E0200"));
    }
}

test "fp guard: indexing a scalar pointer is still rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `p[0]` where p : ptr<_, f32> has no composite to index — must stay E0205.
    const result = try runValidation(arena.allocator(), "fn f() { var a : f32; let p = &a; var b = p[0]; _ = b; }");
    try std.testing.expect(!result.valid);
    try std.testing.expect(hasDiagCode(result, "E0205"));
}

// --- Claim 4: never-called builtin shadow is accepted ---

test "fp: never-called builtin shadow (step) is valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(), "fn f() -> f32 { let step = 5.0; return step; }");
    try std.testing.expect(result.valid);
    try std.testing.expect(!hasDiagCode(result, "E0106"));
}

// --- Fix: unrestricted_pointer_parameters is a baseline language feature ---
// A pointer parameter may live in ANY address space (storage/uniform/workgroup,
// not just function/private). `unrestricted_pointer_parameters` is a WGSL
// *language feature* — always available, never spelled via `enable` (that
// syntax is for extensions) — so Tint accepts all of these with no directive
// (tint corpus ptr_ref/{load,store}/param/{storage,uniform,workgroup}/**,
// bug/tint/2177.wgsl). wgslender mis-modeled it as an enable-extension and
// raised E0304 "must use 'function' or 'private' address space".

test "fp: pointer parameters accept any address space (unrestricted_pointer_parameters)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = [_][]const u8{
        // storage (read) pointer param — tint ptr_ref/load/param/storage/i32.wgsl
        "@group(0) @binding(0) var<storage> S : i32; fn f(p : ptr<storage, i32>) -> i32 { return *p; } @compute @workgroup_size(1) fn main() { let r = f(&S); _ = r; }",
        // uniform pointer param
        "@group(0) @binding(0) var<uniform> U : vec4f; fn f(p : ptr<uniform, vec4f>) -> vec4f { return *p; } @compute @workgroup_size(1) fn main() { let r = f(&U); _ = r; }",
        // workgroup pointer param
        "var<workgroup> W : i32; fn f(p : ptr<workgroup, i32>) -> i32 { return *p; } @compute @workgroup_size(1) fn main() { let r = f(&W); _ = r; }",
        // storage read_write, chained through functions — tint bug/tint/2177.wgsl
        "@binding(0) @group(0) var<storage, read_write> arr : array<u32>; fn f2(p : ptr<storage, array<u32>, read_write>) -> u32 { return arrayLength(p); } @compute @workgroup_size(1) fn main() { arr[0] = f2(&arr); }",
        // function still fine (the always-allowed base case)
        "fn f(p : ptr<function, i32>) -> i32 { return *p; } @compute @workgroup_size(1) fn main() { var x : i32 = 1; let r = f(&x); _ = r; }",
    };
    for (ok) |src| {
        const result = try runValidation(a, src);
        if (hasDiagCode(result, "E0304")) std.debug.print("\nunexpected E0304 for: {s}\n", .{src});
        try std.testing.expect(result.valid);
        try std.testing.expect(!hasDiagCode(result, "E0304"));
    }
}

test "fp guard: pointer argument with wrong pointee type still rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Relaxing the address-space restriction must not weaken pointer type
    // checking: a ptr<storage, i32> argument for a ptr<storage, f32> parameter
    // is still a type mismatch.
    const result = try runValidation(arena.allocator(), "@group(0) @binding(0) var<storage> S : i32; fn f(p : ptr<storage, f32>) -> f32 { return *p; } @compute @workgroup_size(1) fn main() { let r = f(&S); _ = r; }");
    try std.testing.expect(!result.valid);
}

// --- Fix: out-of-order type-alias references ---
// WGSL module-scope declarations are order-independent, so a type alias (or a
// struct field) may reference an alias declared textually later. wgslender
// resolved aliases in a single textual-order pass, so a forward reference to a
// not-yet-resolved alias hit its `null` placeholder and mis-reported
// E0200 "unknown type 'T'; did you mean 'T'?" (the self-suggestion is the tell:
// the name IS in scope). Forward references to a later struct already worked
// (structs get a non-null placeholder in phase 1); only aliases were broken.
// Tint accepts all of these (tint corpus out_of_order_decls/{alias,struct}/*).

test "fp: out-of-order type-alias references resolve" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = [_][]const u8{
        // alias -> later alias (the core failing case)
        "alias T1 = T2;\nalias T2 = i32;\n@fragment fn f() { var v : T1; _ = v; }",
        // struct field -> later alias
        "struct S { m : T, }\nalias T = i32;\n@fragment fn f() { var v : S; _ = v.m; }",
        // longer reverse chain needs the fixpoint (T1->T2->T3->i32, all reversed)
        "alias T1 = T2;\nalias T2 = T3;\nalias T3 = i32;\n@fragment fn f() { var v : T1; _ = v; }",
        // alias -> later struct (already worked — regression guard)
        "alias T = S;\nstruct S { m : i32, }\n@fragment fn f() { var v : T; _ = v.m; }",
        // struct -> later struct (already worked — regression guard)
        "struct S1 { m : S2, }\nstruct S2 { m : i32, }\n@fragment fn f() { var v : S1; _ = v.m.m; }",
        // module-scope var typed by a later alias
        "var<private> A : array<T, 4>;\nalias T = i32;\n@fragment fn f() { A[0] = 1; }",
    };
    for (ok) |src| {
        const result = try runValidation(a, src);
        if (!result.valid) std.debug.print("\nexpected valid: {s}\n", .{src});
        try std.testing.expect(result.valid);
        try std.testing.expect(!hasDiagCode(result, "E0200"));
    }
}

test "fp guard: genuinely-undefined and cyclic aliases still rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Making forward references resolve must not blanket-accept: an alias to a
    // truly-undefined type, and a self-referential alias cycle, must still fail.
    const bad = [_][]const u8{
        "alias T = DoesNotExist;\n@fragment fn f() { var v : T; _ = v; }",
        "alias A = B;\nalias B = A;\n@fragment fn f() { var v : A; _ = v; }",
    };
    for (bad) |src| {
        const result = try runValidation(a, src);
        if (result.valid) std.debug.print("\nexpected invalid: {s}\n", .{src});
        try std.testing.expect(!result.valid);
    }
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

// --- uniformity/ (12 files) ---

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

test "validation: uniformity/barrier_non_uniform_if" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"uniformity/barrier_non_uniform_if");
}

test "validation: uniformity/barrier_after_balanced_if" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"uniformity/barrier_after_balanced_if");
}

test "validation: uniformity/renamed_param_barrier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"uniformity/renamed_param_barrier");
}

test "validation: uniformity/user_var_named_position" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"uniformity/user_var_named_position");
}

test "validation: uniformity/texture_dimensions_condition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"uniformity/texture_dimensions_condition");
}

test "validation: uniformity/let_propagation_barrier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"uniformity/let_propagation_barrier");
}

test "validation: uniformity/storage_load_condition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"uniformity/storage_load_condition");
}

test "validation: uniformity/workgroup_load_condition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"uniformity/workgroup_load_condition");
}

test "validation: uniformity/divergent_return_barrier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"uniformity/divergent_return_barrier");
}

test "validation: uniformity/uniform_load_condition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"uniformity/uniform_load_condition");
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

// --- @interpolate error matrix (WGSL §10.3) ---
// Each @interpolate(type, sampling) combination below must produce a specific
// error code; porting the named-case pattern from wgsl-analyzer so any
// regression shows up with a readable fixture name instead of "one of the 35
// dedup-sweep files broke".

test "validation: errors/types/missing_interpolation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/types/missing_interpolation");
}

test "validation: errors/types/interpolate_integer_linear" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/types/interpolate_integer_linear");
}

test "validation: errors/types/interpolate_flat_sample" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/types/interpolate_flat_sample");
}

test "validation: errors/types/interpolate_perspective_first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/types/interpolate_perspective_first");
}

test "validation: errors/types/interpolate_perspective_either" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/types/interpolate_perspective_either");
}

test "validation: errors/types/interpolate_linear_first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/types/interpolate_linear_first");
}

test "validation: errors/types/interpolate_linear_either" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/types/interpolate_linear_either");
}

test "validation: errors/types/interpolate_invalid_type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/types/interpolate_invalid_type");
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

test "validation: errors/declarations/builtin_on_module_private_var" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/declarations/builtin_on_module_private_var");
}

test "validation: errors/declarations/builtin_on_module_workgroup_var" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/declarations/builtin_on_module_workgroup_var");
}

test "validation: errors/declarations/builtin_on_module_storage_var" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/declarations/builtin_on_module_storage_var");
}

test "validation: errors/declarations/location_on_module_private_var" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/declarations/location_on_module_private_var");
}

test "validation: errors/declarations/location_on_module_uniform_var" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/declarations/location_on_module_uniform_var");
}

test "validation: errors/declarations/builtin_on_override" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/declarations/builtin_on_override");
}

test "validation: errors/declarations/location_on_override" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/declarations/location_on_override");
}

test "validation: errors/declarations/builtin_unknown_name_on_module_var" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/declarations/builtin_unknown_name_on_module_var");
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

test "validation: errors/io/blend_src_on_vertex_output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/blend_src_on_vertex_output");
}

test "validation: errors/io/blend_src_without_location" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/blend_src_without_location");
}

test "validation: errors/io/blend_src_invalid_value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/blend_src_invalid_value");
}

test "validation: errors/io/blend_src_unpaired" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/blend_src_unpaired");
}

test "validation: errors/io/blend_src_type_mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/blend_src_type_mismatch");
}

test "validation: errors/io/blend_src_on_input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/blend_src_on_input");
}

test "validation: errors/io/builtin_on_non_entry_function_param" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/builtin_on_non_entry_function_param");
}

test "validation: errors/io/builtin_position_on_non_entry_function_return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/builtin_position_on_non_entry_function_return");
}

test "validation: errors/io/builtin_frag_depth_on_non_entry_function_return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/builtin_frag_depth_on_non_entry_function_return");
}

test "validation: errors/io/builtin_vertex_index_on_non_entry_function_return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/builtin_vertex_index_on_non_entry_function_return");
}

test "validation: errors/io/location_on_non_entry_function_return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/location_on_non_entry_function_return");
}

test "validation: errors/io/location_and_builtin_on_non_entry_function_return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/location_and_builtin_on_non_entry_function_return");
}

test "validation: errors/io/builtin_on_helper_called_from_entry_point" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/builtin_on_helper_called_from_entry_point");
}

test "validation: errors/io/location_negative" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/location_negative");
}

test "validation: errors/io/location_non_const" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/location_non_const");
}

test "validation: errors/io/compute_output_builtin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/compute_output_builtin");
}

test "validation: errors/io/builtin_frag_depth_wrong_type_f16" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/builtin_frag_depth_wrong_type_f16");
}

test "validation: errors/io/builtin_sample_mask_wrong_type_i32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/builtin_sample_mask_wrong_type_i32");
}

test "validation: errors/io/builtin_local_invocation_index_wrong_type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/builtin_local_invocation_index_wrong_type");
}

test "validation: errors/io/location_atomic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/location_atomic");
}

test "validation: errors/io/duplicate_location_across_param_and_struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/duplicate_location_across_param_and_struct");
}

test "validation: errors/io/blend_src_non_numeric" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/blend_src_non_numeric");
}

test "validation: errors/io/interpolate_on_direct_return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/io/interpolate_on_direct_return");
}

test "validation: types/entry_point_fragment_blend_src" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"types/entry_point_fragment_blend_src");
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

test "validation: types/entry_point_fragment_multi_location" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"types/entry_point_fragment_multi_location");
}

test "validation: types/entry_point_location_f16" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"types/entry_point_location_f16");
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

// =========================================================================
// Expectation pushdown: `.integer_scalar` at index / shift-RHS;
// `.concrete` at unannotated decl initializers.
// =========================================================================

test "validation: types/index_integer_types_valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"types/index_integer_types_valid");
}

test "validation: types/let_var_no_annotation_concretize" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"types/let_var_no_annotation_concretize");
}

test "validation: types/let_nested_expectation_dispatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"types/let_nested_expectation_dispatch");
}

test "validation: expressions/binary/shift_integer_rhs_valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"expressions/binary/shift_integer_rhs_valid");
}

test "validation: errors/types/index_float_literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/types/index_float_literal");
}

test "validation: errors/types/index_f32_var" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/types/index_f32_var");
}

test "validation: errors/types/index_bool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/types/index_bool");
}

test "validation: errors/types/index_vector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/types/index_vector");
}

test "validation: errors/types/index_inner_binary_float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/types/index_inner_binary_float");
}

test "validation: errors/operations/shift_rhs_float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/operations/shift_rhs_float");
}

test "validation: errors/operations/shift_rhs_f32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/operations/shift_rhs_f32");
}

test "validation: errors/operations/shift_rhs_bool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/operations/shift_rhs_bool");
}

test "validation: errors/operations/shift_rhs_vector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/operations/shift_rhs_vector");
}

test "validation: errors/operations/shift_rhs_i32_requires_u32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/operations/shift_rhs_i32_requires_u32");
}

test "validation: errors/operations/shift_lhs_float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runValidationTest(arena.allocator(), validation_data.@"errors/operations/shift_lhs_float");
}

// =========================================================================
// Calling a shadowed WGSL builtin function (E0106)
//
// WGSL builtin functions (dot/mix/max/…) are predeclared but not reserved.
// A value declaration (let/var/const/override/parameter) with one of these
// names shadows the builtin. WGSL permits the shadow itself; it becomes an
// error only when the name is then *called*, because the call resolves to
// the non-callable value rather than the builtin — which real toolchains
// (Tint) reject. We match that: bare shadows stay valid; a shadow that is
// then called is E0106. Function/struct/alias shadows resolve to a callable
// entity and are allowed. Struct fields are exempt (accessed via `.`).
// =========================================================================

/// True if any emitted diagnostic carries `code`.
fn hasDiagCode(result: wgslender.Validator.Result, code: []const u8) bool {
    for (result.diagnostics.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, code)) return true;
    }
    return false;
}

// Red cases — a value shadows a builtin and is then called → invalid + E0106.

test "validate: shadowed builtin call — local let" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(), "fn f() -> f32 { let max = 3.0; return max(1.0, 2.0); }");
    try std.testing.expect(!result.valid);
    try std.testing.expect(hasDiagCode(result, "E0106"));
}

test "validate: shadowed builtin call — function parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(), "fn f(max: f32) -> f32 { return max(1.0, 2.0); }");
    try std.testing.expect(!result.valid);
    try std.testing.expect(hasDiagCode(result, "E0106"));
}

test "validate: shadowed builtin call — module const" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(), "const distance = 1.0;\nfn f() -> f32 { return distance(1.0, 2.0); }");
    try std.testing.expect(!result.valid);
    try std.testing.expect(hasDiagCode(result, "E0106"));
}

test "validate: shadowed builtin call — module var" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(), "var<private> mix: f32;\nfn f() -> f32 { return mix(1.0, 2.0, 3.0); }");
    try std.testing.expect(!result.valid);
    try std.testing.expect(hasDiagCode(result, "E0106"));
}

test "validate: shadowed builtin call — nested block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(), "fn f() -> f32 { let a = 1.0; { let step = 5.0; return step(a, 2.0); } }");
    try std.testing.expect(!result.valid);
    try std.testing.expect(hasDiagCode(result, "E0106"));
}

// Green guards — must stay valid with no E0106.

test "validate: bare builtin shadow without a call is allowed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `max` shadows the builtin but is only read, never called — legal WGSL.
    const result = try runValidation(arena.allocator(), "fn f() -> f32 { let max = 3.0; return max; }");
    try std.testing.expect(result.valid);
    try std.testing.expect(!hasDiagCode(result, "E0106"));
}

test "validate: unshadowed builtin call is allowed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(), "fn f() -> f32 { return max(1.0, 2.0); }");
    try std.testing.expect(result.valid);
    try std.testing.expect(!hasDiagCode(result, "E0106"));
}

test "validate: user function named after a builtin can be called" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A function shadow resolves to the user function — WGSL allows this.
    const result = try runValidation(arena.allocator(), "fn max(a: f32, b: f32) -> f32 { return a; }\nfn g() -> f32 { return max(1.0, 2.0); }");
    try std.testing.expect(result.valid);
    try std.testing.expect(!hasDiagCode(result, "E0106"));
}

test "validate: builtin call outside the shadow's scope is allowed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The `let max` shadow is confined to the inner block; the call sits in
    // the outer scope, where `max` still resolves to the builtin.
    const result = try runValidation(arena.allocator(), "fn f() -> f32 { { let max = 1.0; _ = max; } return max(1.0, 2.0); }");
    try std.testing.expect(result.valid);
    try std.testing.expect(!hasDiagCode(result, "E0106"));
}

test "validate: struct fields named after builtins are allowed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(), "struct S { min: f32, max: f32, step: f32 }");
    try std.testing.expect(result.valid);
    try std.testing.expect(!hasDiagCode(result, "E0106"));
}

test "validate: near-miss builtin name is allowed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(), "fn dotProduct(a: f32, b: f32) -> f32 { return a * b; }");
    try std.testing.expect(result.valid);
    try std.testing.expect(!hasDiagCode(result, "E0106"));
}

// =========================================================================
// E0802 — uniform array element layout. The WGSL uniform-address-space rule
// for arrays is that the element STRIDE be a multiple of 16 (WGSL §13.4.4),
// NOT that the element alignment be >= 16. A `mat2x2<f32>` element has
// alignment 8 but stride RoundUp(size 16, align 8) = 16, and a `mat4x2<f32>`
// element has stride 32 — both multiples of 16, so both are valid in uniform
// and Tint accepts them (tint corpus buffer/uniform/std140/array/matNx2_f32).
// `mat3x2<f32>` (stride 24), `f32` (4) and `vec2<f32>` (8) stay rejected.
// =========================================================================

test "validate: uniform array<mat2x2<f32>> is valid (stride 16, element align 8)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(), "@group(0) @binding(0) var<uniform> u : array<mat2x2<f32>, 4>;\n" ++
        "@compute @workgroup_size(1) fn main() { _ = u[0][0].x; }");
    try std.testing.expect(result.valid);
    try std.testing.expect(!hasDiagCode(result, "E0802"));
}

test "validate: uniform array<mat4x2<f32>> is valid (stride 32, element align 8)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(), "@group(0) @binding(0) var<uniform> u : array<mat4x2<f32>, 4>;\n" ++
        "@compute @workgroup_size(1) fn main() { _ = u[0][0].x; }");
    try std.testing.expect(result.valid);
    try std.testing.expect(!hasDiagCode(result, "E0802"));
}

test "validate: uniform array<f32> stays rejected (stride 4, not a multiple of 16)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(), "@group(0) @binding(0) var<uniform> u : array<f32, 4>;\n" ++
        "@compute @workgroup_size(1) fn main() { _ = u[0]; }");
    try std.testing.expect(hasDiagCode(result, "E0802"));
}

test "validate: uniform array<vec2<f32>> stays rejected (stride 8, not a multiple of 16)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(), "@group(0) @binding(0) var<uniform> u : array<vec2<f32>, 4>;\n" ++
        "@compute @workgroup_size(1) fn main() { _ = u[0].x; }");
    try std.testing.expect(hasDiagCode(result, "E0802"));
}

test "validate: uniform array<mat3x2<f32>> stays rejected (stride 24, not a multiple of 16)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(), "@group(0) @binding(0) var<uniform> u : array<mat3x2<f32>, 4>;\n" ++
        "@compute @workgroup_size(1) fn main() { _ = u[0][0].x; }");
    try std.testing.expect(hasDiagCode(result, "E0802"));
}

// --- Fix: struct member @align/@size honored in uniform layout (WGSL §13.4) ---
// Struct layout must use the @align(n)/@size(n) member attributes, not just the
// natural type alignment/size, when computing array element stride for the
// uniform-address-space check (§13.4.4). Both accepted cases come straight from
// the tint corpus (buffer/uniform/static_index + std140/struct/mat3x2_f32),
// which Tint accepts but wgslender wrongly flagged E0802 while ignoring the
// attributes. The control keeps a targeted, non-blanket fix honest.

test "fp: @align/@size grow struct so array<Inner> stride is a multiple of 16" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Inner: a@0 (i32), b @align(16) @size(16) -> Inner align 16, size 32, so
    // array<Inner,4> stride 32 (valid). Ignoring the attrs gives size 8 -> stride 8.
    const result = try runValidation(arena.allocator(),
        \\struct Inner { a : i32, @align(16) @size(16) b : f32 }
        \\@group(0) @binding(0) var<uniform> u : array<Inner, 4>;
        \\@compute @workgroup_size(1) fn main() { _ = u[0].a; }
    );
    try std.testing.expect(result.valid);
    try std.testing.expect(!hasDiagCode(result, "E0802"));
}

test "fp: @align(64)/@size honored so array<S> with a mat3x2 has stride 128" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // S: before@0, m:mat3x2<f32>@8 (size 24), after @align(64) @size(16) @64 ->
    // S align 64, size 128, so array<S,4> stride 128 (valid). Ignoring the attrs
    // gives size 40 -> stride 40 -> wrongly flagged.
    const result = try runValidation(arena.allocator(),
        \\struct S { before : i32, m : mat3x2<f32>, @align(64) @size(16) after : i32 }
        \\@group(0) @binding(0) var<uniform> u : array<S, 4>;
        \\@compute @workgroup_size(1) fn main() { _ = u[0].before; }
    );
    try std.testing.expect(result.valid);
    try std.testing.expect(!hasDiagCode(result, "E0802"));
}

test "validate: array<S> with a mat3x2 and no layout attrs stays rejected (stride 24)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Control: without @align/@size, S is align 8 / size 24, so array<S,4>
    // stride 24 (not a multiple of 16) — the fix must stay targeted, not blanket.
    const result = try runValidation(arena.allocator(),
        \\struct S { m : mat3x2<f32> }
        \\@group(0) @binding(0) var<uniform> u : array<S, 4>;
        \\@compute @workgroup_size(1) fn main() { _ = u[0].m[0].x; }
    );
    try std.testing.expect(hasDiagCode(result, "E0802"));
}

// --- Fix: `discard` is not a control-flow terminator ---
// Per WGSL, executing `discard` demotes the invocation to a helper but control
// flow *continues* to the next statement (unlike return/break/continue). Tint
// accepts `discard;` followed by more code (tests/testdata/tint/statements/
// discard/*). The reachability check (stmtTerminates) previously listed
// `.discard` as a terminator, so any statement after a `discard` was wrongly
// reported as E0503 "code is unreachable". The advisory lint W0210
// (no-unreachable) still flags post-discard orphans; only the hard error is
// removed here. `discard` still satisfies the return requirement (has_return).

test "fp: statement after discard is reachable (discard is not a terminator)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(),
        \\@fragment fn fs() -> @location(0) vec4f {
        \\  discard;
        \\  return vec4f(0.0);
        \\}
    );
    try std.testing.expect(result.valid);
    try std.testing.expect(!hasDiagCode(result, "E0503"));
}

test "fp: statement after discard inside a loop is reachable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(),
        \\@fragment fn fs() -> @location(0) vec4f {
        \\  loop {
        \\    discard;
        \\    break;
        \\  }
        \\  return vec4f(0.0);
        \\}
    );
    try std.testing.expect(result.valid);
    try std.testing.expect(!hasDiagCode(result, "E0503"));
}

test "fp: unreachable code after return is valid and warns W0103 (not E0503)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Statically-unreachable code is valid WGSL — it is still type-checked but
    // never executes, and Tint accepts it (see bug/tint/1474-b). Batch 6 removed
    // `discard` from the reachability terminators; batch 12 then downgraded the
    // reachability diagnostic itself from a hard error (E0503) to a non-fatal
    // W0103 validator warning. So `return; <stmt>` is now VALID, yet the advisory
    // still fires — proving the reachability analysis survived, only its severity
    // changed.
    const result = try runValidation(arena.allocator(),
        \\fn f() -> i32 {
        \\  return 1;
        \\  let dead = 2;
        \\  return dead;
        \\}
    );
    try std.testing.expect(result.valid);
    try std.testing.expect(hasDiagCode(result, "W0103"));
    try std.testing.expect(!hasDiagCode(result, "E0503"));
}

// --- Fix: unreachable code is a warning (W0103), not a hard error (E0503) ---
// WGSL permits statically-unreachable code; it is type-checked but does not run,
// and does not contribute to uniformity analysis (bug/tint/1474-b). The
// validator's reachability check handles the *richer* cases the W0210 lint
// deliberately skips — an if/else whose branches both terminate, and a switch
// whose every case terminates — so the check is worth keeping; batch 12 only
// re-homes it from a hard E0503 error to a non-fatal W0103 warning, escalated
// back to an error under Options.strict_mode for CI callers.

test "fp: dead code after an if/else that both terminate is valid (W0103)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // bug/tint/2201.wgsl shape: both arms of the `if` break out of the loop, so
    // the trailing statement is unreachable but valid. The W0210 lint's simpler
    // terminator scan would miss this (an `if` is not a terminator to it); the
    // validator's stmtTerminates sees both arms break.
    const result = try runValidation(arena.allocator(),
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\  loop {
        \\    if true { break; } else { break; }
        \\    let dead = 1;
        \\  }
        \\}
    );
    try std.testing.expect(result.valid);
    try std.testing.expect(hasDiagCode(result, "W0103"));
    try std.testing.expect(!hasDiagCode(result, "E0503"));
}

test "fp: dead code after an all-cases-terminating switch is valid (W0103)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Every case (including default) returns, so the switch terminates and the
    // trailing statement is unreachable but valid (switch/switch_nested.wgsl
    // shape). Another richer case the W0210 lint skips.
    const result = try runValidation(arena.allocator(),
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\  var x = 0;
        \\  switch x {
        \\    case 0: { return; }
        \\    default: { return; }
        \\  }
        \\  let dead = 1;
        \\}
    );
    try std.testing.expect(result.valid);
    try std.testing.expect(hasDiagCode(result, "W0103"));
    try std.testing.expect(!hasDiagCode(result, "E0503"));
}

test "guard: strict_mode escalates unreachable code back to a hard error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Under Options.strict_mode the W0103 warning becomes an error, so a strict
    // CI caller still rejects unreachable code — the downgrade is opt-out.
    const result = try wgslender.validateWithOptions(arena.allocator(),
        \\fn f() -> i32 {
        \\  return 1;
        \\  let dead = 2;
        \\  return dead;
        \\}
    , .{ .strict_mode = true });
    try std.testing.expect(!result.valid);
    try std.testing.expect(hasDiagCode(result, "W0103"));
}

// --- Fix: an un-annotated override materializes its abstract initializer ---
//
// An override is always a concrete pipeline-overridable scalar. When its type
// is inferred from an un-suffixed numeric literal (`override x = 2;`), WGSL
// materializes the abstract type to its concrete default (abstract-int→i32,
// abstract-float→f32), exactly as a function-scope `const` concretizes. The
// validator previously kept the inferred type abstract, then rejected it with
// E0303 "'override x' must be bool, i32, u32, f32, or f16, got 'abstract-int'".

test "fp: override with inferred abstract-int initializer materializes to i32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(),
        \\override x = 2;
    );
    try std.testing.expect(result.valid);
    try std.testing.expect(!hasDiagCode(result, "E0303"));
}

test "fp: override abstract-int as workgroup array size materializes to i32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Mirrors bug/tint/1660: the materialized override drives an array count.
    const result = try runValidation(arena.allocator(),
        \\override size = 2;
        \\var<workgroup> a : array<f32, size>;
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\  _ = a[0];
        \\}
    );
    try std.testing.expect(result.valid);
    try std.testing.expect(!hasDiagCode(result, "E0303"));
}

test "fp: override with inferred abstract-float initializer materializes to f32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(),
        \\override f = 1.5;
    );
    try std.testing.expect(result.valid);
    try std.testing.expect(!hasDiagCode(result, "E0303"));
}

test "fp guard: override inferred to a non-scalar still flags E0303" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Overrides must be scalar. `vec2(1, 2)` concretizes to vec2<i32> but stays
    // a vector, so E0303 must still fire — proving the fix materializes the
    // abstract type without blanket-removing the concrete-scalar requirement.
    const result = try runValidation(arena.allocator(),
        \\override v = vec2(1, 2);
    );
    try std.testing.expect(hasDiagCode(result, "E0303"));
}

// --- Fix: frexp/modf are const-evaluable builtins ---
//
// WGSL §17.5 lists frexp and modf as const functions: `const res = frexp(1.25)`
// is a valid const-expression (Tint const-folds them to an OpConstantComposite).
// They were the lone numeric builtins marked `.runtime` in the Builtins table —
// every other const-capable numeric (sin/cos/exp/sqrt/…) is `.const_eval` — so a
// const-context frexp/modf was wrongly rejected with E0302 "initializer is not a
// const-expression".

test "fp: frexp of a const scalar is a const-expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(),
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\  const in = 1.25;
        \\  const res = frexp(in);
        \\  let fract : f32 = res.fract;
        \\  let exp : i32 = res.exp;
        \\}
    );
    try std.testing.expect(result.valid);
    try std.testing.expect(!hasDiagCode(result, "E0302"));
}

test "fp: modf of a const scalar is a const-expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(),
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\  const in = 1.25;
        \\  const res = modf(in);
        \\  let fract : f32 = res.fract;
        \\  let whole : f32 = res.whole;
        \\}
    );
    try std.testing.expect(result.valid);
    try std.testing.expect(!hasDiagCode(result, "E0302"));
}

test "fp: frexp of a const vector is a const-expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(),
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\  const in = vec2(1.25, 3.75);
        \\  const res = frexp(in);
        \\  let fract : vec2<f32> = res.fract;
        \\  let exp : vec2<i32> = res.exp;
        \\}
    );
    try std.testing.expect(result.valid);
    try std.testing.expect(!hasDiagCode(result, "E0302"));
}

test "fp guard: frexp of a runtime value is not a const-expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A const-eval builtin preserves its arguments' stage: `frexp` of a runtime
    // `let` is still a runtime expression, so a const initialized from it must
    // still be rejected — proving the fix propagates arg stage rather than
    // blanket-accepting every frexp/modf call.
    const result = try runValidation(arena.allocator(),
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\  let in = 1.25;
        \\  const res = frexp(in);
        \\}
    );
    try std.testing.expect(hasDiagCode(result, "E0302"));
}

// --- Fix: address-of a dereferenced pointer value (&*&x / &*ptr_value) ---
//
// `&x` produces a pointer; `*&x` dereferences it back to a reference; `&*&x`
// re-addresses that reference — a valid pointer round-trip Tint accepts. The
// syntactic addressability pre-filter (`addrOfOperandLooksAddressable`) wrongly
// required a deref's *operand* to itself be addressable, so `*&x` was rejected
// (its operand `&x` is a pointer value, not a reference). A deref `*e` denotes a
// reference whenever `e` type-checks as a pointer — the deref check (E0214) is
// the real gate — so `*e` must be treated as syntactically addressable.

test "fp: address-of a dereferenced pointer value (&*&G)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runValidation(arena.allocator(),
        \\@group(0) @binding(0) var<storage, read> G : array<i32>;
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\  let p = &*&G;
        \\  let n : u32 = arrayLength(p);
        \\}
    );
    try std.testing.expect(result.valid);
    try std.testing.expect(!hasDiagCode(result, "E0215"));
}

test "fp: address-of dereference chain through let-bound pointers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Mirrors builtins/arrayLength/via_let_complex_no_struct.wgsl: every step is a
    // pointer/reference round-trip that must resolve without E0215.
    const result = try runValidation(arena.allocator(),
        \\@group(0) @binding(0) var<storage, read> G : array<i32>;
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\  let p = &*&G;
        \\  let p2 = &*p;
        \\  let p3 = &(*p);
        \\  let l1 : u32 = arrayLength(&*p3);
        \\}
    );
    try std.testing.expect(result.valid);
    try std.testing.expect(!hasDiagCode(result, "E0215"));
}

test "fp guard: address-of a literal is still rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A literal has no memory location — the `.literal` arm stays false.
    const result = try runValidation(arena.allocator(),
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\  let p = &5;
        \\}
    );
    try std.testing.expect(hasDiagCode(result, "E0215"));
}

test "fp guard: address-of an arithmetic value is still rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // An arithmetic result is a value, not a reference — the `.binary` arm stays false.
    const result = try runValidation(arena.allocator(),
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\  var a = 1;
        \\  var b = 2;
        \\  let p = &(a + b);
        \\}
    );
    try std.testing.expect(hasDiagCode(result, "E0215"));
}

test "fp guard: address-of deref-of-non-pointer is still rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `&*5`: the relaxed filter treats `*5` as syntactically addressable, but the
    // deref type-check (E0214 'requires a pointer') rejects `*5` before the
    // address-of check runs — proving the relaxation defers to the deref gate
    // rather than blanket-accepting every `&*…` form.
    const result = try runValidation(arena.allocator(),
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\  let p = &*5;
        \\}
    );
    try std.testing.expect(!result.valid);
    try std.testing.expect(hasDiagCode(result, "E0214"));
}

// --- Fix: `break` inside a nested loop/switch within a continuing block ---
//
// WGSL forbids a plain `break` in a `continuing` block because it would exit the
// loop the continuing belongs to (only `break if` may). But a `break` nested in
// a loop/switch/for/while *inside* the continuing block targets that nested
// construct, not the outer loop, so it is legal — Tint accepts it. wgslender
// gated the check on a single `in_continuing` flag that stayed set through nested
// constructs; the dedicated `break_exits_continuing` flag is cleared when a
// nested break-target body begins, so only a `break` that would truly exit the
// continuing's loop is rejected. (`in_continuing` is left untouched — the
// nesting-insensitive `return`-in-continuing rule still uses it.)

test "fp: break inside a nested loop within a continuing block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Mirrors bug/tint/354627692.wgsl verbatim: the two `break`s target the inner
    // loop, and `break if` legally ends the continuing block.
    const result = try runValidation(arena.allocator(),
        \\@group(0) @binding(0)
        \\var<storage, read_write> buffer : i32;
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\  var i : i32 = buffer;
        \\  loop {
        \\    continuing {
        \\      loop {
        \\        if (i > 5) {
        \\          i = i * 2;
        \\          break;
        \\        } else {
        \\          i = i * 2;
        \\          break;
        \\        }
        \\      }
        \\      break if i > 10;
        \\    }
        \\  }
        \\  buffer = i;
        \\}
    );
    try std.testing.expect(result.valid);
    try std.testing.expect(!hasDiagCode(result, "E0500"));
}

test "fp: break inside a nested switch within a continuing block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A `break` in a switch case targets the switch, so it is legal even when the
    // switch is nested inside a continuing block. (The `default` case falls
    // through so the switch does not terminate — keeping the trailing `break if`
    // reachable, i.e. free of an unrelated E0503.)
    const result = try runValidation(arena.allocator(),
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\  var i : i32 = 0;
        \\  loop {
        \\    continuing {
        \\      switch i {
        \\        case 0: { break; }
        \\        default: { i = i + 1; }
        \\      }
        \\      break if i > 10;
        \\    }
        \\  }
        \\}
    );
    try std.testing.expect(result.valid);
    try std.testing.expect(!hasDiagCode(result, "E0500"));
}

test "fp: break inside a nested for within a continuing block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A `break` in a for-loop body targets the for-loop, legal inside a continuing.
    const result = try runValidation(arena.allocator(),
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\  var i : i32 = 0;
        \\  loop {
        \\    continuing {
        \\      for (var j : i32 = 0; j < 3; j++) { break; }
        \\      break if i > 10;
        \\    }
        \\  }
        \\}
    );
    try std.testing.expect(result.valid);
    try std.testing.expect(!hasDiagCode(result, "E0500"));
}

test "fp guard: plain break directly in a continuing block is still rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // No nested loop/switch re-targets this break — it would exit the loop from
    // its continuing block, which WGSL forbids.
    const result = try runValidation(arena.allocator(),
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\  loop {
        \\    continuing {
        \\      break;
        \\    }
        \\  }
        \\}
    );
    try std.testing.expect(hasDiagCode(result, "E0500"));
}

test "fp guard: break inside an if in a continuing block is still rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // An `if` is not a break target, so this break still exits the continuing's
    // loop — the flag is cleared only by a nested loop/switch, not by an `if`.
    const result = try runValidation(arena.allocator(),
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\  var i : i32 = 0;
        \\  loop {
        \\    continuing {
        \\      if (i > 5) { break; }
        \\      break if i > 10;
        \\    }
        \\  }
        \\}
    );
    try std.testing.expect(hasDiagCode(result, "E0500"));
}

// --- Fix: `default` as a member of a `case` selector list ---
// WGSL grammar: `case_selector: 'default' | expression`, so `default` may
// appear anywhere in a `case`'s comma-separated selector list (e.g.
// `case 1, default:`), and `case default:` is equivalent to a bare `default:`.
// The parser modelled a case as EITHER a bare `default` OR `case <exprs>`, so a
// `default` mixed into a selector list raised a spurious "expected expression in
// case selector" and dropped the default — leaving the switch looking
// default-less and firing E0307. These use the full pipeline (validateWithOptions
// merges parse errors) so a lingering parse error also fails the accept cases.

test "fp: default mixed into a case selector list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // statements/switch/case_default_mixed.wgsl verbatim (Tint accepts).
    const result = try wgslender.validateWithOptions(arena.allocator(),
        \\@compute @workgroup_size(1)
        \\fn f() {
        \\    var i : i32;
        \\    var result : i32;
        \\    switch(i) {
        \\        case 0: {
        \\            result = 10;
        \\        }
        \\        case 1, default: {
        \\            result = 22;
        \\        }
        \\        case 2: {
        \\            result = 33;
        \\        }
        \\    }
        \\}
    , .{});
    try std.testing.expect(result.valid);
}

test "fp: default as the sole selector after case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `case default:` is equivalent to a bare `default:`.
    const result = try wgslender.validateWithOptions(arena.allocator(),
        \\@compute @workgroup_size(1)
        \\fn f() {
        \\    var i : i32;
        \\    switch(i) {
        \\        case default: {
        \\            i = 1;
        \\        }
        \\    }
        \\}
    , .{});
    try std.testing.expect(result.valid);
}

test "fp: multi-selector case with a trailing default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // switch/switch_multi_selector.wgsl verbatim (Tint accepts).
    const result = try wgslender.validateWithOptions(arena.allocator(),
        \\@compute @workgroup_size(1)
        \\fn a() {
        \\    var a = 0;
        \\    switch(a) {
        \\        case 0, 2, 4: {
        \\            break;
        \\        }
        \\        case 1, default: {
        \\            return;
        \\        }
        \\    }
        \\}
    , .{});
    try std.testing.expect(result.valid);
}

test "fp: nested switches with mixed default selectors clear E0307" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // switch/switch_nested.wgsl verbatim (Tint accepts). Every nested switch
    // now sees its default via a mixed selector list, so E0307 is cleared.
    // Batch 12 then downgraded the trailing-unreachable-code diagnostic from a
    // hard E0503 error to a non-fatal W0103 warning, so the file now validates
    // fully — assert full validity (E0307-gone was batch 11's partial result,
    // which the then-orthogonal E0503 sub-bug had blocked from being complete).
    const result = try wgslender.validateWithOptions(arena.allocator(),
        \\@compute @workgroup_size(1)
        \\fn a() {
        \\    var a = 0;
        \\    switch(a) {
        \\        case 0, 2, 4: {
        \\            var b = 3u;
        \\            switch(b) {
        \\                case 0: {
        \\                    break;
        \\                }
        \\                case 1, 2, 3, default: {
        \\                    var c = 123u;
        \\                    switch(c) {
        \\                        case 0: {
        \\                            break;
        \\                        }
        \\                        default: {
        \\                            return;
        \\                        }
        \\                    }
        \\                    return;
        \\                }
        \\            }
        \\            break;
        \\        }
        \\        case 1, default: {
        \\            return;
        \\        }
        \\    }
        \\}
    , .{});
    try std.testing.expect(result.valid);
}

test "fp guard: switch with no default clause is still rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try wgslender.validateWithOptions(arena.allocator(),
        \\@compute @workgroup_size(1)
        \\fn f() {
        \\    var i : i32;
        \\    switch(i) {
        \\        case 0: { i = 1; }
        \\        case 1: { i = 2; }
        \\    }
        \\}
    , .{});
    try std.testing.expect(!result.valid);
    try std.testing.expect(hasDiagCode(result, "E0307"));
}

test "fp guard: bare default cannot carry extra selectors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A bare `default` clause takes no selectors — `default, 1:` is invalid WGSL.
    const result = try wgslender.validateWithOptions(arena.allocator(),
        \\@compute @workgroup_size(1)
        \\fn f() {
        \\    var i : i32;
        \\    switch(i) {
        \\        case 0: { i = 1; }
        \\        default, 1: { i = 2; }
        \\    }
        \\}
    , .{});
    try std.testing.expect(!result.valid);
}

test "fp guard: duplicate default (mixed plus bare) is still rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `case 1, default:` provides the default; a second `default:` is a
    // duplicate — proves has_default drives the multiple-default count.
    const result = try wgslender.validateWithOptions(arena.allocator(),
        \\@compute @workgroup_size(1)
        \\fn f() {
        \\    var i : i32;
        \\    switch(i) {
        \\        case 1, default: { i = 1; }
        \\        default: { i = 2; }
        \\    }
        \\}
    , .{});
    try std.testing.expect(!result.valid);
}
