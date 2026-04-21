//! Operator typing — WGSL §8.7 (shifts) and §8.8 (comparisons/bitwise).
//!
//! Pins the spec rules for operand typing. Shifts in particular have a
//! strict RHS-must-be-u32 rule (or convertible via automatic conversion,
//! which means AbstractInt is fine but i32 is not). The in-source
//! AbstractInt has width 0 bytes but concretizes to a 32-bit type, so
//! `1 << 2` is valid (today: it is; before the fix, this spuriously
//! errored because `Scalar.size()` was used as the bit-width ceiling).

const std = @import("std");
const wgslender = @import("wgslender");

fn validate(src: [:0]const u8) !wgslender.Validator.Result {
    return wgslender.validateWithOptions(std.testing.allocator, src, .{});
}

fn countErrorsWithCode(r: wgslender.Validator.Result, code: []const u8) usize {
    var n: usize = 0;
    for (r.diagnostics.items()) |d| {
        if (d.severity == .@"error" and std.mem.eql(u8, d.code, code)) n += 1;
    }
    return n;
}

fn hasErrorContaining(r: wgslender.Validator.Result, needle: []const u8) bool {
    for (r.diagnostics.items()) |d| {
        if (d.severity != .@"error") continue;
        if (std.mem.indexOf(u8, d.message, needle) != null) return true;
    }
    return false;
}

fn anyError(r: wgslender.Validator.Result) bool {
    for (r.diagnostics.items()) |d| {
        if (d.severity == .@"error") return true;
    }
    return false;
}

fn dump(label: []const u8, r: wgslender.Validator.Result) void {
    std.debug.print("\n{s}:\n", .{label});
    for (r.diagnostics.items()) |d| {
        std.debug.print(
            "  [{s}] {s}: {s}\n",
            .{ d.code, d.severity.string(), d.message },
        );
    }
}

// --- Shift LHS / RHS type rules (§8.7) ---

test "§8.7: 1 << 2 (both abstract-int) is valid — shader-creation time" {
    var r = try validate("fn f() { let x = 1 << 2; }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("expected no errors on abstract-int shift", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.7: 1u << 2u is valid" {
    var r = try validate("fn f() { let x = 1u << 2u; }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("1u<<2u should be valid", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.7: 1u << 2 (concrete LHS, abstract RHS) is valid" {
    var r = try validate("fn f() { let x = 1u << 2; }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("1u<<2 should be valid", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.7: shift amount i32 rejected" {
    var r = try validate("fn f() { let x = 1u << 2i; }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "shift amount must be 'u32'")) {
        dump("expected shift-amount error on i32 RHS", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.7: shift amount via a let-bound i32 rejected" {
    var r = try validate(
        \\fn f() {
        \\  let shift = 2i;
        \\  let x = 1u << shift;
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "shift amount must be 'u32'")) {
        dump("expected shift-amount error on i32 RHS (runtime)", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.7: float LHS rejected" {
    var r = try validate("fn f() { let x = 1.0 << 2u; }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "integer left operand")) {
        dump("expected integer-LHS error on float shift", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.7: shift by 32 rejected (at bit width of 32-bit int)" {
    var r = try validate("fn f() { let x = 1u << 32u; }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "exceeds bit width")) {
        dump("expected overshift error", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.7: abstract 1 << 31 is valid (within 32-bit ceiling)" {
    var r = try validate("fn f() { let x = 1 << 31; }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("expected no error on 1 << 31 (32-bit ceiling)", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.7: abstract 1 << 32 rejected (overshift)" {
    var r = try validate("fn f() { let x = 1 << 32; }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "exceeds bit width")) {
        dump("expected overshift error on 1 << 32", r);
        return error.TestUnexpectedResult;
    }
}

// --- Bitwise operators (§8.8) ---

test "§8.8: bitwise & / | / ^ on bools is valid" {
    // Parens mandatory — WGSL requires explicit grouping when mixing these
    // bitwise operators (per our E0213 rule); the point here is that each
    // bitwise op by itself accepts bool operands.
    var r = try validate("fn f() { let x = (true & false) | (true ^ false); }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("bool bitwise should be valid", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.8: bitwise on mixed int/bool rejected" {
    var r = try validate("fn f() { let x = 1u & true; }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "integer or bool")) {
        dump("expected int-or-bool error on mixed bitwise", r);
        return error.TestUnexpectedResult;
    }
}

// --- Comparison result types ---

test "§8.8: scalar comparison returns bool" {
    var r = try validate(
        \\fn f() -> bool { return 1 < 2; }
    );
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("scalar comparison should return bool", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.8: vector comparison returns vecN<bool>" {
    var r = try validate(
        \\fn f() -> vec3<bool> { return vec3f(1.0) < vec3f(2.0); }
    );
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("vector comparison should return vec3<bool>", r);
        return error.TestUnexpectedResult;
    }
}

// --- Mixed-signedness comparison: §17.1 requires common type ---

test "§17.1: 1i < 2u rejected (no common type)" {
    var r = try validate("fn f() { let x = 1i < 2u; }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "compatible types")) {
        dump("expected mixed-sign rejection on i32 < u32", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.1: 1u > 2i rejected (no common type)" {
    var r = try validate("fn f() { let x = 1u > 2i; }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "compatible types")) {
        dump("expected mixed-sign rejection on u32 > i32", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.1: 1i <= 2u rejected" {
    var r = try validate("fn f() { let x = 1i <= 2u; }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "compatible types")) {
        dump("expected mixed-sign rejection on <=", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.1: 1u >= 2i rejected" {
    var r = try validate("fn f() { let x = 1u >= 2i; }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "compatible types")) {
        dump("expected mixed-sign rejection on >=", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.1: i32 < i32 still valid" {
    var r = try validate("fn f() { let x = 1i < 2i; }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("i32 < i32 must stay valid", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.1: i32 < abstract-int valid (abstract widens to i32)" {
    var r = try validate("fn f() { let x = 1i < 2; }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("i32 < abstract must stay valid", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.1: u32 < abstract-int valid" {
    var r = try validate("fn f() { let x = 1u < 2; }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("u32 < abstract must stay valid", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.1: f32 < abstract-float valid" {
    var r = try validate("fn f() { let x = 1.0f < 2.0; }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("f32 < abstract-float must stay valid", r);
        return error.TestUnexpectedResult;
    }
}

test "§17.1: vec3<i32> < vec3<u32> rejected" {
    var r = try validate(
        \\fn f() { let x = vec3<i32>(1) < vec3<u32>(2u); }
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "compatible types")) {
        dump("expected rejection on mixed-sign vector comparison", r);
        return error.TestUnexpectedResult;
    }
}

// --- Negation / boolean NOT ---

test "§8.7: unary - on abstract-int is valid" {
    var r = try validate("fn f() { let x = -5; }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("unary-neg on abstract-int should be valid", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.7: unary ! on bool is valid" {
    var r = try validate("fn f() { let x = !true; }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("unary-! on bool should be valid", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.7: unary ! on i32 rejected" {
    var r = try validate("fn f() { let x = !1i; }");
    defer r.deinit(std.testing.allocator);
    if (!anyError(r)) {
        dump("expected error on !i32", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.7: unary ~ on int is valid" {
    var r = try validate("fn f() { let x = ~1u; }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("unary-~ on u32 should be valid", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.7: unary ~ on float rejected" {
    var r = try validate("fn f() { let x = ~1.0f; }");
    defer r.deinit(std.testing.allocator);
    if (!anyError(r)) {
        dump("expected error on ~f32", r);
        return error.TestUnexpectedResult;
    }
}
