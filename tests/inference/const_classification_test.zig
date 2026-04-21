//! WGSL expression stage — spec §6.7–6.9 (const / override / runtime).
//!
//! These tests pin observable behavior, not the internal enum — they
//! assert that diagnostics fire where the spec requires a const- or
//! override-expression and do not fire where such expressions are
//! valid. This protects the classifier (`classifyExprStage` in
//! `src/Validator.zig`) as downstream refactors move toward the
//! unified inference engine.

const std = @import("std");
const wgslender = @import("wgslender");

fn validate(source: [:0]const u8) !wgslender.Validator.Result {
    return wgslender.validateWithOptions(std.testing.allocator, source, .{});
}

fn hasErrorWithCode(r: wgslender.Validator.Result, code: []const u8) bool {
    for (r.diagnostics.items()) |d| {
        if (d.severity == .@"error" and std.mem.eql(u8, d.code, code)) return true;
    }
    return false;
}

fn dump(label: []const u8, r: wgslender.Validator.Result) void {
    std.debug.print("\n{s}:\n", .{label});
    for (r.diagnostics.items()) |d| {
        std.debug.print(
            "  {d}:{d} [{s}] {s}: {s}\n",
            .{ d.range.start.line, d.range.start.column, d.code, d.severity.string(), d.message },
        );
    }
}

// ---------------------------------------------------------------------
// const-decl initializers (§6.7)
// ---------------------------------------------------------------------

test "§6.7: const initializer must be const-expression" {
    var r = try validate(
        \\override run_time: i32;
        \\const bad: i32 = run_time + 1;
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorWithCode(r, "E0302")) {
        dump("expected E0302 on const ref-to-override", r);
        return error.TestUnexpectedResult;
    }
}

test "§6.7: const with literal + literal is valid" {
    var r = try validate(
        \\const ok: i32 = 1 + 2;
    );
    defer r.deinit(std.testing.allocator);
    if (hasErrorWithCode(r, "E0302") or hasErrorWithCode(r, "E0315")) {
        dump("spurious const-expression error", r);
        return error.TestUnexpectedResult;
    }
}

test "§6.7: const with ref to other const is valid" {
    var r = try validate(
        \\const a: i32 = 1;
        \\const b: i32 = a + 2;
    );
    defer r.deinit(std.testing.allocator);
    if (hasErrorWithCode(r, "E0302") or hasErrorWithCode(r, "E0315")) {
        dump("const ref-to-const should be valid", r);
        return error.TestUnexpectedResult;
    }
}

// ---------------------------------------------------------------------
// override-decl initializers (§6.8)
// ---------------------------------------------------------------------

test "§6.8: override initializer can be const-expression" {
    var r = try validate(
        \\const base: i32 = 10;
        \\override x: i32 = base + 5;
    );
    defer r.deinit(std.testing.allocator);
    if (hasErrorWithCode(r, "E0315")) {
        dump("override(const-expr) should be valid", r);
        return error.TestUnexpectedResult;
    }
}

test "§6.8: override initializer can be override-expression" {
    var r = try validate(
        \\override base: i32 = 1;
        \\override x: i32 = base + 5;
    );
    defer r.deinit(std.testing.allocator);
    if (hasErrorWithCode(r, "E0315")) {
        dump("override(override-expr) should be valid", r);
        return error.TestUnexpectedResult;
    }
}

test "§6.8: override initializer rejects var-private (runtime)" {
    var r = try validate(
        \\var<private> rv: i32 = 0;
        \\override x: i32 = rv;
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorWithCode(r, "E0315")) {
        dump("expected E0315 on override init with var ref", r);
        return error.TestUnexpectedResult;
    }
}

// ---------------------------------------------------------------------
// array element count (§11.3)
// ---------------------------------------------------------------------

test "§11.3: array size must be const or override (reject let)" {
    var r = try validate(
        \\fn f() {
        \\  let n = 4;
        \\  var a: array<f32, n>;
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorWithCode(r, "E0315")) {
        dump("expected E0315 on array size from let", r);
        return error.TestUnexpectedResult;
    }
}

test "§11.3: array size with const is valid" {
    var r = try validate(
        \\const N: i32 = 4;
        \\fn f() { var a: array<f32, N>; }
    );
    defer r.deinit(std.testing.allocator);
    if (hasErrorWithCode(r, "E0315") or hasErrorWithCode(r, "E0313")) {
        dump("array size from const should be valid", r);
        return error.TestUnexpectedResult;
    }
}

test "§11.3: array size with override is valid at function scope" {
    var r = try validate(
        \\override N: i32 = 4;
        \\fn f() { var a: array<f32, N>; }
    );
    defer r.deinit(std.testing.allocator);
    if (hasErrorWithCode(r, "E0315")) {
        dump("array size from override should be valid", r);
        return error.TestUnexpectedResult;
    }
}

test "§11.3 struct member array count: must be const (reject override)" {
    var r = try validate(
        \\override N: i32 = 4;
        \\struct S { xs: array<f32, N> }
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorWithCode(r, "E0313")) {
        dump("expected E0313 on struct member array<_, override>", r);
        return error.TestUnexpectedResult;
    }
}

// ---------------------------------------------------------------------
// const_assert (§11.9)
// ---------------------------------------------------------------------

test "§11.9: const_assert with literal bool is valid" {
    var r = try validate(
        \\const_assert 1 < 2;
    );
    defer r.deinit(std.testing.allocator);
    if (hasErrorWithCode(r, "E0302")) {
        dump("const_assert literal should be valid", r);
        return error.TestUnexpectedResult;
    }
}

test "§11.9: const_assert rejects override-expression" {
    var r = try validate(
        \\override N: i32 = 4;
        \\const_assert N > 0;
    );
    defer r.deinit(std.testing.allocator);
    // We expect some const-expression diagnostic; E0302 or E0315 are the
    // two codes the validator currently uses here.
    if (!hasErrorWithCode(r, "E0302") and !hasErrorWithCode(r, "E0315")) {
        dump("expected E0302/E0315 on const_assert with override", r);
        return error.TestUnexpectedResult;
    }
}

// ---------------------------------------------------------------------
// @id / @align / @size (§9.x)
// ---------------------------------------------------------------------

test "§9.x: @id requires const-expression" {
    var r = try validate(
        \\override other = 5;
        \\@id(other) override x: i32 = 0;
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorWithCode(r, "E0315")) {
        dump("expected E0315 on @id(override)", r);
        return error.TestUnexpectedResult;
    }
}

test "§9.x: @id with integer literal is valid" {
    var r = try validate(
        \\@id(42) override x: i32 = 0;
    );
    defer r.deinit(std.testing.allocator);
    if (hasErrorWithCode(r, "E0315")) {
        dump("spurious E0315 on literal @id", r);
        return error.TestUnexpectedResult;
    }
}

test "§9.x: @align requires const-expression (reject override)" {
    var r = try validate(
        \\override A: i32 = 16;
        \\struct S { @align(A) x: i32 }
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorWithCode(r, "E0315")) {
        dump("expected E0315 on @align(override)", r);
        return error.TestUnexpectedResult;
    }
}

// ---------------------------------------------------------------------
// @workgroup_size (§10.x)
// ---------------------------------------------------------------------

test "§10.x: @workgroup_size accepts const-expression" {
    var r = try validate(
        \\const WG: i32 = 64;
        \\@compute @workgroup_size(WG) fn main() {}
    );
    defer r.deinit(std.testing.allocator);
    if (hasErrorWithCode(r, "E0315")) {
        dump("spurious E0315 on @workgroup_size(const)", r);
        return error.TestUnexpectedResult;
    }
}

test "§10.x: @workgroup_size accepts override-expression" {
    var r = try validate(
        \\override WG: i32 = 64;
        \\@compute @workgroup_size(WG) fn main() {}
    );
    defer r.deinit(std.testing.allocator);
    if (hasErrorWithCode(r, "E0315")) {
        dump("spurious E0315 on @workgroup_size(override)", r);
        return error.TestUnexpectedResult;
    }
}

test "§10.x: @workgroup_size rejects runtime ref" {
    // A var<workgroup> ref inside @workgroup_size is clearly runtime.
    var r = try validate(
        \\var<private> w: i32 = 1;
        \\@compute @workgroup_size(w) fn main() {}
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorWithCode(r, "E0315")) {
        dump("expected E0315 on @workgroup_size(var)", r);
        return error.TestUnexpectedResult;
    }
}

// ---------------------------------------------------------------------
// Switch case selectors (§8.x)
// ---------------------------------------------------------------------

test "§8.x: switch case selector must be const-expression (reject let)" {
    var r = try validate(
        \\fn f(x: i32) {
        \\  let n = 1;
        \\  switch (x) {
        \\    case n: {}
        \\    default: {}
        \\  }
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorWithCode(r, "E0315")) {
        dump("expected E0315 on switch case with let", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.x: switch case selector accepts const" {
    var r = try validate(
        \\const N: i32 = 1;
        \\fn f(x: i32) {
        \\  switch (x) {
        \\    case N: {}
        \\    default: {}
        \\  }
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (hasErrorWithCode(r, "E0315")) {
        dump("spurious E0315 on switch case with const", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.x: switch case selector rejects override-expression" {
    var r = try validate(
        \\override N: i32 = 1;
        \\fn f(x: i32) {
        \\  switch (x) {
        \\    case N: {}
        \\    default: {}
        \\  }
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorWithCode(r, "E0315")) {
        dump("expected E0315 on switch case with override", r);
        return error.TestUnexpectedResult;
    }
}

// ---------------------------------------------------------------------
// Classification propagation through operators
// ---------------------------------------------------------------------

test "classify: binop lifts to max of operands (const + override → override)" {
    // `override N + const M` in a const-expr context (array size via const)
    // must error because the right-hand classification is override, not const.
    var r = try validate(
        \\const M: i32 = 2;
        \\override N: i32 = 3;
        \\struct S { xs: array<f32, N + M> }
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorWithCode(r, "E0313")) {
        dump("expected E0313 — binop propagates override classification", r);
        return error.TestUnexpectedResult;
    }
}

test "classify: paren does not change classification" {
    var r = try validate(
        \\override N: i32 = 3;
        \\struct S { xs: array<f32, (N)> }
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorWithCode(r, "E0313")) {
        dump("expected E0313 — paren preserves override classification", r);
        return error.TestUnexpectedResult;
    }
}

test "classify: unary negation does not change classification" {
    var r = try validate(
        \\override N: i32 = -3;
        \\struct S { xs: array<f32, -N> }
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorWithCode(r, "E0313")) {
        dump("expected E0313 — unary preserves override classification", r);
        return error.TestUnexpectedResult;
    }
}
