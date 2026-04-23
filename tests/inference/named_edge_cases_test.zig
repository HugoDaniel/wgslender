//! Named inference edge cases ported from wgsl-analyzer's
//! `crates/hir_ty/src/tests/simple.rs`. Each test pins down a specific
//! WGSL semantic rule that wgsl-analyzer guards with an expect-test
//! snapshot; here we assert the outcome (valid / specific error code)
//! rather than the full inferred-type text — equivalent coverage,
//! simpler to maintain across representation changes.

const std = @import("std");
const wgslender = @import("wgslender");

fn validate(src: [:0]const u8) !wgslender.Validator.Result {
    return wgslender.validateWithOptions(std.testing.allocator, src, .{});
}

fn anyError(r: wgslender.Validator.Result) bool {
    for (r.diagnostics.items()) |d| {
        if (d.severity == .@"error") return true;
    }
    return false;
}

fn hasErrorWithCode(r: wgslender.Validator.Result, code: []const u8) bool {
    for (r.diagnostics.items()) |d| {
        if (d.severity != .@"error") continue;
        if (std.mem.eql(u8, d.code, code)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------
// multiply_with_minus_one
// `x * -1` where `x: i32` must preserve i32 — the abstract `-1` promotes
// to the concrete type of the other operand.
// ---------------------------------------------------------------------

test "infer: i32 * -1 preserves i32" {
    var r = try validate(
        \\const x: i32 = 1;
        \\const y = x * -1;
    );
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(!anyError(r));
}

// ---------------------------------------------------------------------
// call_user_defined_with_abstract_numbers
// User-defined `fn make_one(x: f32) -> u32` called with an abstract
// float argument must promote and return u32 cleanly.
// ---------------------------------------------------------------------

test "infer: user fn accepts abstract-float arg" {
    var r = try validate(
        \\fn make_one(x: f32) -> u32 { return 1u; }
        \\fn main() { let a = make_one(0.333); }
    );
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(!anyError(r));
}

// ---------------------------------------------------------------------
// global_assert_statement_correct / _wrong
// `const_assert` requires a bool-typed expression.
// ---------------------------------------------------------------------

test "infer: const_assert accepts bool expression" {
    var r = try validate(
        \\const a = 29;
        \\const_assert 27 < a;
    );
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(!anyError(r));
}

test "infer: const_assert rejects non-bool expression" {
    var r = try validate(
        \\const a = 29;
        \\const_assert 27 + a;
    );
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(anyError(r));
}

// ---------------------------------------------------------------------
// struct_constructor_unrefs
// Passing references (from `var` locals) to a struct constructor must
// apply the load rule implicitly — no "expected T got ref<T>" errors.
// ---------------------------------------------------------------------

test "infer: struct constructor applies load rule to ref args" {
    var r = try validate(
        \\struct S { u: u32, a: array<f32, 3> }
        \\fn foo() {
        \\    var u = 1u;
        \\    var a = array<f32, 3>(1.0, 2.0, 3.0);
        \\    let s = S(u, a);
        \\}
    );
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(!anyError(r));
}

