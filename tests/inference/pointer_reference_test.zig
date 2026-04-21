//! Pointer & reference flow — WGSL §6.5 ("Reference types"), §8.5
//! ("address-of"), §8.5 ("indirection"), §13 ("pointer-typed parameters").
//!
//! These tests pin the behavior of `&` and `*` beyond the previous
//! syntactic check (which only asked "does the operand shape look
//! addressable?"). Now the validator also rejects:
//!   • `&v.x`, `&v.xy`, `&v[i]` where `v` is a vector (vector components
//!     are values, not references — "Address-of / vector component" in
//!     §8.5 "Reference and pointer types"),
//!   • `&texture_var` / `&sampler_var` (handles are not first-class
//!     memory locations),
//! and propagates the root variable's address-space / access-mode onto
//! the resulting pointer type.

const std = @import("std");
const wgslender = @import("wgslender");

fn validate(src: [:0]const u8) !wgslender.Validator.Result {
    return wgslender.validateWithOptions(std.testing.allocator, src, .{});
}

fn hasErrorWithCode(r: wgslender.Validator.Result, code: []const u8) bool {
    for (r.diagnostics.items()) |d| {
        if (d.severity == .@"error" and std.mem.eql(u8, d.code, code)) return true;
    }
    return false;
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

// -------------------------------------------------------------------------
// §8.5 addr-of a variable — always OK.
// -------------------------------------------------------------------------

test "§8.5: &v on a function-scope var is valid" {
    var r = try validate(
        \\fn f() {
        \\  var x: i32 = 1;
        \\  let p = &x;
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("no error expected on &x", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.5: &v on a module-scope private var is valid" {
    var r = try validate(
        \\var<private> g: i32 = 0;
        \\fn f() { let p = &g; }
    );
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("no error expected on &g private", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.5: &v on a workgroup var is valid" {
    var r = try validate(
        \\var<workgroup> w: i32;
        \\fn f() { let p = &w; }
    );
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("no error expected on &w workgroup", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.5: &v on a storage var is valid" {
    var r = try validate(
        \\@group(0) @binding(0) var<storage, read_write> s: array<i32>;
        \\fn f() { let p = &s; }
    );
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("no error expected on &s storage", r);
        return error.TestUnexpectedResult;
    }
}

// -------------------------------------------------------------------------
// §8.5 addr-of a vector component — rejected (E0216).
// -------------------------------------------------------------------------

test "§8.5: &v.x on a vector is rejected (single-letter swizzle)" {
    var r = try validate(
        \\fn f() {
        \\  var v: vec3f;
        \\  let p = &v.x;
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorWithCode(r, "E0216")) {
        dump("expected E0216 on &v.x", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.5: &v.r on a vec4 rgba-form is rejected" {
    var r = try validate(
        \\fn f() {
        \\  var v: vec4f;
        \\  let p = &v.r;
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorWithCode(r, "E0216")) {
        dump("expected E0216 on &v.r", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.5: &v.xy on a vector (multi-letter swizzle) is rejected" {
    var r = try validate(
        \\fn f() {
        \\  var v: vec3f;
        \\  let p = &v.xy;
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorWithCode(r, "E0216")) {
        dump("expected E0216 on &v.xy", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.5: &v[0] on a vector is rejected" {
    var r = try validate(
        \\fn f() {
        \\  var v: vec3f;
        \\  let p = &v[0];
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorWithCode(r, "E0216")) {
        dump("expected E0216 on &v[0]", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.5: &v[i] on a vector (dynamic index) is rejected" {
    var r = try validate(
        \\fn f() {
        \\  var v: vec3f;
        \\  var i: i32 = 0;
        \\  let p = &v[i];
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorWithCode(r, "E0216")) {
        dump("expected E0216 on &v[i]", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.5: &(v).x — paren-wrapped — still rejected" {
    var r = try validate(
        \\fn f() {
        \\  var v: vec3f;
        \\  let p = &(v).x;
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorWithCode(r, "E0216")) {
        dump("expected E0216 on &(v).x", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.5: diagnostic message names the offending swizzle" {
    var r = try validate(
        \\fn f() {
        \\  var v: vec3f;
        \\  let p = &v.y;
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, ".y")) {
        dump("expected the message to mention '.y'", r);
        return error.TestUnexpectedResult;
    }
}

// -------------------------------------------------------------------------
// §8.5 addr-of a struct field (not a vector component) — OK.
// -------------------------------------------------------------------------

test "§8.5: &s.field on a struct is valid" {
    var r = try validate(
        \\struct S { x: i32, y: i32 }
        \\fn f() {
        \\  var s: S;
        \\  let p = &s.x;
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("no error expected on &s.field", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.5: &arr[i] on an array is valid" {
    var r = try validate(
        \\fn f() {
        \\  var arr: array<i32, 4>;
        \\  let p = &arr[0];
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("no error expected on &arr[0]", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.5: &arr[i].field on an array of structs is valid" {
    var r = try validate(
        \\struct S { x: i32, y: f32 }
        \\fn f() {
        \\  var arr: array<S, 4>;
        \\  let p = &arr[0].y;
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("no error expected on &arr[0].y", r);
        return error.TestUnexpectedResult;
    }
}

// -------------------------------------------------------------------------
// §8.5 addr-of a handle (texture / sampler) — rejected (E0217).
// -------------------------------------------------------------------------

test "§8.5: &texture_var is rejected" {
    var r = try validate(
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\fn f() { let p = &tex; }
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorWithCode(r, "E0217")) {
        dump("expected E0217 on &tex", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.5: &sampler_var is rejected" {
    var r = try validate(
        \\@group(0) @binding(0) var samp: sampler;
        \\fn f() { let p = &samp; }
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorWithCode(r, "E0217")) {
        dump("expected E0217 on &samp", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.5: &comparison_sampler_var is rejected" {
    var r = try validate(
        \\@group(0) @binding(0) var samp_cmp: sampler_comparison;
        \\fn f() { let p = &samp_cmp; }
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorWithCode(r, "E0217")) {
        dump("expected E0217 on &samp_cmp", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.5: &storage_texture_var is rejected" {
    var r = try validate(
        \\@group(0) @binding(0) var tex_s: texture_storage_2d<rgba8unorm, write>;
        \\fn f() { let p = &tex_s; }
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorWithCode(r, "E0217")) {
        dump("expected E0217 on &tex_s storage", r);
        return error.TestUnexpectedResult;
    }
}

// -------------------------------------------------------------------------
// §8.5 addr-of a value-producing expression — rejected (E0215).
// -------------------------------------------------------------------------

test "§8.5: &literal is rejected (E0215)" {
    var r = try validate("fn f() { let p = &1.0; }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorWithCode(r, "E0215")) {
        dump("expected E0215 on &1.0", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.5: &(a+b) is rejected (E0215)" {
    var r = try validate(
        \\fn f() {
        \\  let a = 1;
        \\  let b = 2;
        \\  let p = &(a + b);
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorWithCode(r, "E0215")) {
        dump("expected E0215 on &(a+b)", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.5: &f() is rejected (E0215)" {
    var r = try validate(
        \\fn g() -> i32 { return 1; }
        \\fn f() { let p = &g(); }
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorWithCode(r, "E0215")) {
        dump("expected E0215 on &g()", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.5: &!x (unary value) is rejected (E0215)" {
    var r = try validate(
        \\fn f() {
        \\  let b = true;
        \\  let p = &!b;
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorWithCode(r, "E0215")) {
        dump("expected E0215 on &!b", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.5: &-n (unary minus on value) is rejected (E0215)" {
    var r = try validate(
        \\fn f() {
        \\  let n = 1i;
        \\  let p = &-n;
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorWithCode(r, "E0215")) {
        dump("expected E0215 on &-n", r);
        return error.TestUnexpectedResult;
    }
}

// -------------------------------------------------------------------------
// §8.5 indirection `*` — forms.
// -------------------------------------------------------------------------

test "§8.5: *p on a pointer reads through" {
    var r = try validate(
        \\fn f() {
        \\  var x: i32 = 1;
        \\  let p = &x;
        \\  let y = *p;
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("no error expected on *p read", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.5: *p on a non-pointer is rejected (E0214)" {
    var r = try validate("fn f() { let n = 1; let p = *n; }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorWithCode(r, "E0214")) {
        dump("expected E0214 on *n", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.5: **p (double indirection on i32 ptr) is rejected" {
    var r = try validate(
        \\fn f() {
        \\  var x: i32 = 1;
        \\  let p = &x;
        \\  let y = **p;
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorWithCode(r, "E0214")) {
        dump("expected E0214 on **p (inner * yields i32)", r);
        return error.TestUnexpectedResult;
    }
}

// -------------------------------------------------------------------------
// §13 pointer parameters — accept `&v` at call sites.
// -------------------------------------------------------------------------

test "§13: passing &v to a function taking ptr<function,i32,read_write>" {
    var r = try validate(
        \\fn inc(p: ptr<function, i32, read_write>) { *p = *p + 1; }
        \\fn f() {
        \\  var x: i32 = 0;
        \\  inc(&x);
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("no error expected on &x to ptr<function,i32>", r);
        return error.TestUnexpectedResult;
    }
}

test "§13: passing &v to a function taking ptr<function,i32> (no AM specified)" {
    var r = try validate(
        \\fn inc(p: ptr<function, i32>) { *p = *p + 1; }
        \\fn f() {
        \\  var x: i32 = 0;
        \\  inc(&x);
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("no error expected on &x to ptr<function,i32> default-AM", r);
        return error.TestUnexpectedResult;
    }
}

// -------------------------------------------------------------------------
// Chained addressable forms — `&s.field.field` and friends.
// -------------------------------------------------------------------------

test "§8.5: &s.inner.x on nested struct is valid" {
    var r = try validate(
        \\struct Inner { x: i32 }
        \\struct Outer { inner: Inner }
        \\fn f() {
        \\  var o: Outer;
        \\  let p = &o.inner.x;
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("no error expected on &o.inner.x", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.5: &arr[0][0] on array of arrays is valid" {
    var r = try validate(
        \\fn f() {
        \\  var a: array<array<i32, 4>, 4>;
        \\  let p = &a[0][0];
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("no error expected on &a[0][0]", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.5: &matrix[0] (a column) is valid — matrix columns are references" {
    var r = try validate(
        \\fn f() {
        \\  var m: mat2x2f;
        \\  let p = &m[0];
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("no error expected on &m[0] matrix column", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.5: &matrix[0].x — the column is a vector, so .x is a component → rejected" {
    var r = try validate(
        \\fn f() {
        \\  var m: mat2x2f;
        \\  let p = &m[0].x;
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (!hasErrorWithCode(r, "E0216")) {
        dump("expected E0216 on &m[0].x (vector component of matrix col)", r);
        return error.TestUnexpectedResult;
    }
}

// -------------------------------------------------------------------------
// AS / AM propagation onto the pointer type.
// This is an indirect observation: we can't print a pointer type's AS
// directly from these tests, but we can exercise call-site matching.
// -------------------------------------------------------------------------

test "§13: storage pointer matches ptr<storage,…,read_write> (unrestricted)" {
    var r = try validate(
        \\enable unrestricted_pointer_parameters;
        \\@group(0) @binding(0) var<storage, read_write> s: i32;
        \\fn sink(p: ptr<storage, i32, read_write>) { *p = 1; }
        \\fn f() { sink(&s); }
    );
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("no error expected on &s storage → ptr<storage,…>", r);
        return error.TestUnexpectedResult;
    }
}

test "§13: workgroup pointer matches ptr<workgroup,…> (unrestricted)" {
    var r = try validate(
        \\enable unrestricted_pointer_parameters;
        \\var<workgroup> w: i32;
        \\fn sink(p: ptr<workgroup, i32, read_write>) { *p = 1; }
        \\fn f() { sink(&w); }
    );
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("no error expected on &w workgroup → ptr<workgroup,…>", r);
        return error.TestUnexpectedResult;
    }
}

// -------------------------------------------------------------------------
// `&` preserves addressability through `*p` — double star round-trip.
// -------------------------------------------------------------------------

test "§8.5: &*p is valid when p is a pointer" {
    var r = try validate(
        \\fn f() {
        \\  var x: i32 = 1;
        \\  let p = &x;
        \\  let q = &*p;
        \\}
    );
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("no error expected on &*p round-trip", r);
        return error.TestUnexpectedResult;
    }
}
