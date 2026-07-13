//! Spec-faithful load rule — WGSL §8.3 (The Load Rule) and §10
//! (Memory views / reference types).
//!
//! When a reference appears in a value context (argument, RHS of `=`,
//! arithmetic operand, comparison operand, return expression, constructor
//! arg, index, swizzle, ...), it is automatically loaded to its store
//! type. In lvalue contexts (LHS of `=`, operand of `&`, ptr parameter)
//! the reference is preserved.
//!
//! This file pins the semantics currently observable through the
//! validator: every case below either lowers to a concrete value type
//! we can assert on or produces a specific diagnostic. Any future
//! refactor of the load rule must keep these assertions green.

const std = @import("std");
const wgslender = @import("wgslender");

fn analyze(src: [:0]const u8) !wgslender.Validator.AnalysisResult {
    return wgslender.analyzeWithOptions(std.testing.allocator, src, .{});
}

fn validate(src: [:0]const u8) !wgslender.Validator.Result {
    return wgslender.validateWithOptions(std.testing.allocator, src, .{});
}

fn anyError(r: wgslender.Validator.Result) bool {
    for (r.diagnostics.items()) |d| {
        if (d.severity == .@"error") return true;
    }
    return false;
}

fn hasErrorCode(r: wgslender.Validator.Result, code: []const u8) bool {
    for (r.diagnostics.items()) |d| {
        if (d.severity != .@"error") continue;
        if (std.mem.eql(u8, d.code, code)) return true;
    }
    return false;
}

fn dump(label: []const u8, r: wgslender.Validator.Result) void {
    std.debug.print("\n{s}:\n", .{label});
    for (r.diagnostics.items()) |d| {
        std.debug.print("  [{s}] {s}: {s}\n", .{ d.code, d.severity.string(), d.message });
    }
}

fn letType(r: *const wgslender.Validator.AnalysisResult, name: []const u8) ?wgslender.Types.Type {
    const mod = r.module orelse return null;
    for (mod.symbols.items, 0..) |sym, idx| {
        if (sym.kind != .let) continue;
        if (!std.mem.eql(u8, sym.original_name, name)) continue;
        return r.symbol_types.get(@intCast(idx));
    }
    return null;
}

fn expectLet(r: *const wgslender.Validator.AnalysisResult, name: []const u8, expected: []const u8) !void {
    const t = letType(r, name) orelse {
        std.debug.print("let '{s}' missing; diagnostics:\n", .{name});
        for (r.diagnostics.items()) |d| std.debug.print("  [{s}] {s}: {s}\n", .{ d.code, d.severity.string(), d.message });
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqualStrings(expected, t.string());
}

// =========================================================================
// Value-context loads: arithmetic, comparison, return, argument
// =========================================================================

test "§8.3: var read in arithmetic loads to value type" {
    var r = try analyze(
        \\fn f() {
        \\  var x: i32 = 5;
        \\  let y = x + 1;
        \\}
    );
    defer r.deinit();
    try expectLet(&r, "y", "i32");
}

test "§8.3: var read in RHS of let loads" {
    var r = try analyze(
        \\fn f() {
        \\  var x: f32 = 1.0;
        \\  let y = x;
        \\}
    );
    defer r.deinit();
    try expectLet(&r, "y", "f32");
}

test "§8.3: var read in comparison loads" {
    var r = try analyze(
        \\fn f() {
        \\  var a: i32 = 5;
        \\  var b: i32 = 6;
        \\  let c = a < b;
        \\}
    );
    defer r.deinit();
    try expectLet(&r, "c", "bool");
}

test "§8.3: var read in unary loads" {
    var r = try analyze(
        \\fn f() {
        \\  var x: i32 = 5;
        \\  let y = -x;
        \\}
    );
    defer r.deinit();
    try expectLet(&r, "y", "i32");
}

test "§8.3: var read in binary-&& loads (bool)" {
    var r = try analyze(
        \\fn f() {
        \\  var a: bool = true;
        \\  var b: bool = false;
        \\  let c = a && b;
        \\}
    );
    defer r.deinit();
    try expectLet(&r, "c", "bool");
}

test "§8.3: var read in return loads" {
    var r = try validate(
        \\fn f() -> i32 {
        \\  var x: i32 = 5;
        \\  return x;
        \\}
    );
    defer r.deinit();
    try std.testing.expect(!anyError(r));
}

test "§8.3: var read as function arg loads" {
    var r = try analyze(
        \\fn g(x: f32) -> f32 { return x; }
        \\fn f() {
        \\  var v: f32 = 1.0;
        \\  let y = g(v);
        \\}
    );
    defer r.deinit();
    try expectLet(&r, "y", "f32");
}

test "§8.3: var read as builtin arg loads" {
    var r = try analyze(
        \\fn f() {
        \\  var v: f32 = 1.0;
        \\  let y = sin(v);
        \\}
    );
    defer r.deinit();
    try expectLet(&r, "y", "f32");
}

// =========================================================================
// Composite load: member / index / swizzle of a ref expression
// =========================================================================

test "§8.3: struct field read loads" {
    var r = try analyze(
        \\struct S { a: i32, b: f32 };
        \\fn f() {
        \\  var s: S;
        \\  let a = s.a;
        \\  let b = s.b;
        \\}
    );
    defer r.deinit();
    try expectLet(&r, "a", "i32");
    try expectLet(&r, "b", "f32");
}

test "§8.3: nested struct field read loads" {
    var r = try analyze(
        \\struct Inner { x: f32 };
        \\struct Outer { inner: Inner };
        \\fn f() {
        \\  var o: Outer;
        \\  let x = o.inner.x;
        \\}
    );
    defer r.deinit();
    try expectLet(&r, "x", "f32");
}

test "§8.3: array index read loads" {
    var r = try analyze(
        \\fn f() {
        \\  var a: array<i32, 4>;
        \\  let x = a[0];
        \\}
    );
    defer r.deinit();
    try expectLet(&r, "x", "i32");
}

test "§8.3: vector swizzle read loads" {
    var r = try analyze(
        \\fn f() {
        \\  var v: vec3<f32>;
        \\  let a = v.x;
        \\  let b = v.xy;
        \\  let c = v.xyz;
        \\}
    );
    defer r.deinit();
    try expectLet(&r, "a", "f32");
    try expectLet(&r, "b", "vec2<f32>");
    try expectLet(&r, "c", "vec3<f32>");
}

test "§8.3: matrix column read loads" {
    var r = try analyze(
        \\fn f() {
        \\  var m: mat3x3<f32>;
        \\  let col = m[0];
        \\}
    );
    defer r.deinit();
    try expectLet(&r, "col", "vec3<f32>");
}

test "§8.3: matrix element read loads" {
    var r = try analyze(
        \\fn f() {
        \\  var m: mat3x3<f32>;
        \\  let e = m[0][1];
        \\}
    );
    defer r.deinit();
    try expectLet(&r, "e", "f32");
}

// =========================================================================
// Pointer deref: `*p` yields value type
// =========================================================================

test "§8.5: *p yields value type" {
    var r = try analyze(
        \\fn g(p: ptr<function, i32>) {
        \\  let y = *p;
        \\}
    );
    defer r.deinit();
    try expectLet(&r, "y", "i32");
}

test "§8.5: (*p).field loads field" {
    var r = try analyze(
        \\struct S { a: i32, b: f32 };
        \\fn g(p: ptr<function, S>) {
        \\  let a = (*p).a;
        \\  let b = (*p).b;
        \\}
    );
    defer r.deinit();
    try expectLet(&r, "a", "i32");
    try expectLet(&r, "b", "f32");
}

test "§8.5: (*p)[i] loads element" {
    var r = try analyze(
        \\fn g(p: ptr<function, array<i32, 4>>) {
        \\  let x = (*p)[0];
        \\}
    );
    defer r.deinit();
    try expectLet(&r, "x", "i32");
}

test "§8.5: p[i] (pointer indexing) loads element" {
    var r = try analyze(
        \\fn g(p: ptr<function, array<i32, 4>>) {
        \\  let x = p[0];
        \\}
    );
    defer r.deinit();
    try expectLet(&r, "x", "i32");
}

// =========================================================================
// Lvalue contexts preserve the reference (no load)
// =========================================================================

test "§8.3: var on LHS of assign does not load (compound-assign parses)" {
    var r = try validate(
        \\fn f() {
        \\  var x: i32 = 5;
        \\  x = 10;
        \\  x += 1;
        \\}
    );
    defer r.deinit();
    try std.testing.expect(!anyError(r));
}

test "§8.5: &x on a var yields a pointer" {
    var r = try validate(
        \\fn f() {
        \\  var x: i32 = 5;
        \\  let p = &x;
        \\}
    );
    defer r.deinit();
    try std.testing.expect(!anyError(r));
}

test "§8.5: &s.field on a var yields a pointer" {
    var r = try validate(
        \\struct S { a: i32 };
        \\fn f() {
        \\  var s: S;
        \\  let p = &s.a;
        \\}
    );
    defer r.deinit();
    try std.testing.expect(!anyError(r));
}

test "§8.5: &arr[i] on a var yields a pointer" {
    var r = try validate(
        \\fn f() {
        \\  var a: array<i32, 4>;
        \\  let p = &a[0];
        \\}
    );
    defer r.deinit();
    try std.testing.expect(!anyError(r));
}

// =========================================================================
// Load-rule forbidden cases: `&` cannot address a loaded value
// =========================================================================

test "§8.5: &literal rejected (no reference)" {
    var r = try validate(
        \\fn f() { let p = &1i; }
    );
    defer r.deinit();
    try std.testing.expect(hasErrorCode(r, "E0215"));
}

test "§8.5: &(a+b) rejected (arithmetic produces value)" {
    var r = try validate(
        \\fn f() {
        \\  var a: i32 = 1;
        \\  var b: i32 = 2;
        \\  let p = &(a + b);
        \\}
    );
    defer r.deinit();
    try std.testing.expect(hasErrorCode(r, "E0215"));
}

test "§8.5: &f() rejected (call result has no address)" {
    var r = try validate(
        \\fn g() -> i32 { return 0; }
        \\fn f() {
        \\  let p = &g();
        \\}
    );
    defer r.deinit();
    try std.testing.expect(hasErrorCode(r, "E0215"));
}

test "§8.5: &v.x rejected (vector component is not a reference)" {
    var r = try validate(
        \\fn f() {
        \\  var v: vec3<f32>;
        \\  let p = &v.x;
        \\}
    );
    defer r.deinit();
    try std.testing.expect(hasErrorCode(r, "E0216"));
}

test "§8.5: &texture_var rejected (handle has no reference)" {
    var r = try validate(
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\fn f() {
        \\  let p = &tex;
        \\}
    );
    defer r.deinit();
    try std.testing.expect(hasErrorCode(r, "E0217"));
}

// =========================================================================
// Address spaces preserved on pointer formation
// =========================================================================

test "§8.5: &private_var carries private AS" {
    var r = try analyze(
        \\var<private> g: i32 = 0;
        \\fn f() {
        \\  let p = &g;
        \\}
    );
    defer r.deinit();
    const t = letType(&r, "p") orelse return error.TestUnexpectedResult;
    try std.testing.expect(t == .pointer);
    try std.testing.expect(t.pointer.address_space == .private);
}

test "§8.5: &workgroup_var carries workgroup AS" {
    var r = try analyze(
        \\var<workgroup> w: i32;
        \\fn f() {
        \\  let p = &w;
        \\}
    );
    defer r.deinit();
    const t = letType(&r, "p") orelse return error.TestUnexpectedResult;
    try std.testing.expect(t == .pointer);
    try std.testing.expect(t.pointer.address_space == .workgroup);
}

test "§8.5: &storage_var carries storage AS + read AM" {
    var r = try analyze(
        \\struct S { x: i32 };
        \\@group(0) @binding(0) var<storage, read> s: S;
        \\fn f() {
        \\  let p = &s;
        \\}
    );
    defer r.deinit();
    const t = letType(&r, "p") orelse return error.TestUnexpectedResult;
    try std.testing.expect(t == .pointer);
    try std.testing.expect(t.pointer.address_space == .storage);
    try std.testing.expect(t.pointer.access_mode == .read);
}

test "§8.5: &storage_rw_var carries storage AS + read_write AM" {
    var r = try analyze(
        \\struct S { x: i32 };
        \\@group(0) @binding(0) var<storage, read_write> s: S;
        \\fn f() {
        \\  let p = &s;
        \\}
    );
    defer r.deinit();
    const t = letType(&r, "p") orelse return error.TestUnexpectedResult;
    try std.testing.expect(t == .pointer);
    try std.testing.expect(t.pointer.address_space == .storage);
    try std.testing.expect(t.pointer.access_mode == .read_write);
}

test "§8.5: &function_var carries function AS" {
    var r = try analyze(
        \\fn f() {
        \\  var x: i32 = 0;
        \\  let p = &x;
        \\}
    );
    defer r.deinit();
    const t = letType(&r, "p") orelse return error.TestUnexpectedResult;
    try std.testing.expect(t == .pointer);
    try std.testing.expect(t.pointer.address_space == .function);
}

// =========================================================================
// Load rule in composite expressions — mixing refs and values
// =========================================================================

test "§8.3: ref + concrete loads ref first" {
    var r = try analyze(
        \\fn f() {
        \\  var v: f32 = 1.0;
        \\  let y = v + 2.0;
        \\}
    );
    defer r.deinit();
    try expectLet(&r, "y", "f32");
}

test "§8.3: ref + ref loads both" {
    var r = try analyze(
        \\fn f() {
        \\  var a: f32 = 1.0;
        \\  var b: f32 = 2.0;
        \\  let c = a + b;
        \\}
    );
    defer r.deinit();
    try expectLet(&r, "c", "f32");
}

test "§8.3: ref of vec used as swizzle source loads element" {
    var r = try analyze(
        \\fn f() {
        \\  var v: vec4<f32>;
        \\  let x = v.r;
        \\  let yz = v.gb;
        \\}
    );
    defer r.deinit();
    try expectLet(&r, "x", "f32");
    try expectLet(&r, "yz", "vec2<f32>");
}

test "§8.3: ref used in constructor is loaded" {
    var r = try analyze(
        \\fn f() {
        \\  var a: f32 = 1.0;
        \\  var b: f32 = 2.0;
        \\  let v = vec2<f32>(a, b);
        \\}
    );
    defer r.deinit();
    try expectLet(&r, "v", "vec2<f32>");
}

test "§8.3: ref used as index loads index" {
    var r = try analyze(
        \\fn f() {
        \\  var a: array<i32, 4>;
        \\  var i: i32 = 0;
        \\  let x = a[i];
        \\}
    );
    defer r.deinit();
    try expectLet(&r, "x", "i32");
}

// =========================================================================
// Interaction with let (let = value) vs var (var = ref-able storage)
// =========================================================================

test "§8.3: let x = y; chain preserves value type" {
    var r = try analyze(
        \\fn f() {
        \\  let a = 1i;
        \\  let b = a;
        \\  let c = b;
        \\}
    );
    defer r.deinit();
    try expectLet(&r, "a", "i32");
    try expectLet(&r, "b", "i32");
    try expectLet(&r, "c", "i32");
}

test "§8.3: const referenced from fn scope loads" {
    var r = try analyze(
        \\const K: i32 = 42;
        \\fn f() {
        \\  let x = K;
        \\  let y = K + 1;
        \\}
    );
    defer r.deinit();
    try expectLet(&r, "x", "i32");
    try expectLet(&r, "y", "i32");
}
