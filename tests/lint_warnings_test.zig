//! Lint-style warnings beyond the unused-symbol family:
//!
//!   - W0100 shadowing: any inner scope (function body / nested block)
//!     that re-uses a name visible from an outer scope.
//!   - W0101 redundant cast: a type constructor call whose single
//!     argument is already of the target concrete type.
//!   - E0105 reserved identifier: `_` alone, or any `__`-prefixed name.
//!
//! DIAGNOSTICS_ROADMAP.md item 10, Phase C.

const std = @import("std");
const wgslender = @import("wgslender");

fn validateSource(source: [:0]const u8) !wgslender.Validator.Result {
    return wgslender.validateWithOptions(std.testing.allocator, source, .{});
}

fn hasWarningWithCode(r: wgslender.Validator.Result, code: []const u8) bool {
    for (r.diagnostics.items()) |d| {
        if (d.severity == .warning and std.mem.eql(u8, d.code, code)) return true;
    }
    return false;
}

fn hasWarningContaining(r: wgslender.Validator.Result, code: []const u8, needle: []const u8) bool {
    for (r.diagnostics.items()) |d| {
        if (d.severity != .warning) continue;
        if (!std.mem.eql(u8, d.code, code)) continue;
        if (std.mem.indexOf(u8, d.message, needle) != null) return true;
    }
    return false;
}

fn hasErrorWithCode(r: wgslender.Validator.Result, code: []const u8) bool {
    for (r.diagnostics.items()) |d| {
        if (d.severity == .@"error" and std.mem.eql(u8, d.code, code)) return true;
    }
    return false;
}

fn countErrorsWithCode(r: wgslender.Validator.Result, code: []const u8) usize {
    var n: usize = 0;
    for (r.diagnostics.items()) |d| {
        if (d.severity == .@"error" and std.mem.eql(u8, d.code, code)) n += 1;
    }
    return n;
}

fn hasErrorContaining(r: wgslender.Validator.Result, code: []const u8, needle: []const u8) bool {
    for (r.diagnostics.items()) |d| {
        if (d.severity != .@"error") continue;
        if (!std.mem.eql(u8, d.code, code)) continue;
        if (std.mem.indexOf(u8, d.message, needle) != null) return true;
    }
    return false;
}

fn dumpDiags(label: []const u8, r: wgslender.Validator.Result) void {
    std.debug.print("\n{s}:\n", .{label});
    for (r.diagnostics.items()) |d| {
        std.debug.print(
            "  {d}:{d} [{s}] {s}: {s}\n",
            .{ d.range.start.line, d.range.start.column, d.code, d.severity.string(), d.message },
        );
    }
}

// -------------------------------------------------------------------------
// W0100 shadowing
// -------------------------------------------------------------------------

test "W0100: module-scope shadow retains code" {
    var r = try validateSource(
        \\var<private> x: f32 = 0.0;
        \\fn main() -> f32 { let x: f32 = 1.0; return x; }
    );
    defer r.deinit();
    if (!hasWarningWithCode(r, "W0100")) {
        dumpDiags("no W0100 module-scope shadow", r);
        return error.TestUnexpectedResult;
    }
}

test "W0100: nested block shadow inside function body" {
    var r = try validateSource(
        \\fn main() -> f32 {
        \\  let x: f32 = 1.0;
        \\  {
        \\    let x: f32 = 2.0;
        \\    return x;
        \\  }
        \\}
    );
    defer r.deinit();
    if (!hasWarningContaining(r, "W0100", "shadows")) {
        dumpDiags("no W0100 nested shadow", r);
        return error.TestUnexpectedResult;
    }
}

test "W0100: parameter shadowing module-scope const" {
    var r = try validateSource(
        \\const x: i32 = 1;
        \\fn main() -> i32 { return x; }
        \\fn other(x: f32) -> f32 { return x; }
    );
    defer r.deinit();
    if (!hasWarningWithCode(r, "W0100")) {
        dumpDiags("no W0100 param-shadow", r);
        return error.TestUnexpectedResult;
    }
}

test "W0100: no shadow when names are different" {
    var r = try validateSource(
        \\fn main() -> f32 {
        \\  let a: f32 = 0.0;
        \\  { let b: f32 = a; return b; }
        \\}
    );
    defer r.deinit();
    for (r.diagnostics.items()) |d| {
        if (d.severity == .warning and std.mem.eql(u8, d.code, "W0100")) {
            dumpDiags("unexpected W0100", r);
            return error.TestUnexpectedResult;
        }
    }
}

// -------------------------------------------------------------------------
// W0101 redundant cast
// -------------------------------------------------------------------------

test "W0101: f32(f32) is redundant" {
    var r = try validateSource(
        \\fn main() -> f32 {
        \\  let a: f32 = 1.0f;
        \\  return f32(a);
        \\}
    );
    defer r.deinit();
    if (!hasWarningWithCode(r, "W0101")) {
        dumpDiags("no W0101 redundant cast", r);
        return error.TestUnexpectedResult;
    }
}

test "W0101: i32(i32) is redundant" {
    var r = try validateSource(
        \\fn main() -> i32 {
        \\  let a: i32 = 1i;
        \\  return i32(a);
        \\}
    );
    defer r.deinit();
    if (!hasWarningWithCode(r, "W0101")) {
        dumpDiags("no W0101 redundant i32 cast", r);
        return error.TestUnexpectedResult;
    }
}

test "W0101: f32(i32) is NOT a redundant cast" {
    var r = try validateSource(
        \\fn main() -> f32 {
        \\  let a: i32 = 1i;
        \\  return f32(a);
        \\}
    );
    defer r.deinit();
    for (r.diagnostics.items()) |d| {
        if (d.severity == .warning and std.mem.eql(u8, d.code, "W0101")) {
            dumpDiags("unexpected W0101 on f32(i32)", r);
            return error.TestUnexpectedResult;
        }
    }
}

test "W0101: u32(u32) is redundant" {
    var r = try validateSource(
        \\fn main() -> u32 {
        \\  let a: u32 = 1u;
        \\  return u32(a);
        \\}
    );
    defer r.deinit();
    if (!hasWarningWithCode(r, "W0101")) {
        dumpDiags("no W0101 redundant u32 cast", r);
        return error.TestUnexpectedResult;
    }
}

// -------------------------------------------------------------------------
// E0105 reserved identifier
// -------------------------------------------------------------------------

test "E0105: let __tmp is reserved" {
    var r = try validateSource(
        \\fn main() -> f32 {
        \\  let __tmp: f32 = 1.0;
        \\  return __tmp;
        \\}
    );
    defer r.deinit();
    if (!hasErrorWithCode(r, "E0105")) {
        dumpDiags("no E0105 for let __tmp", r);
        return error.TestUnexpectedResult;
    }
}

test "E0105: fn __main is reserved" {
    var r = try validateSource(
        \\fn __main() -> f32 { return 0.0; }
    );
    defer r.deinit();
    if (!hasErrorWithCode(r, "E0105")) {
        dumpDiags("no E0105 for fn __main", r);
        return error.TestUnexpectedResult;
    }
}

test "E0105: struct __S is reserved" {
    var r = try validateSource(
        \\struct __S { x: f32 }
        \\fn main() -> f32 {
        \\  let s: __S = __S(1.0);
        \\  return s.x;
        \\}
    );
    defer r.deinit();
    if (!hasErrorWithCode(r, "E0105")) {
        dumpDiags("no E0105 for struct __S", r);
        return error.TestUnexpectedResult;
    }
}

test "E0105: parameter __p is reserved" {
    var r = try validateSource(
        \\fn helper(__p: f32) -> f32 { return __p; }
    );
    defer r.deinit();
    if (!hasErrorWithCode(r, "E0105")) {
        dumpDiags("no E0105 for parameter __p", r);
        return error.TestUnexpectedResult;
    }
}

test "E0105: struct member __x is reserved" {
    var r = try validateSource(
        \\struct S { __x: f32 }
        \\fn main() -> f32 {
        \\  let s: S = S(1.0);
        \\  return s.__x;
        \\}
    );
    defer r.deinit();
    if (!hasErrorWithCode(r, "E0105")) {
        dumpDiags("no E0105 for struct member __x", r);
        return error.TestUnexpectedResult;
    }
}

test "E0105: single-underscore leading name is OK" {
    // `_x` (single leading underscore followed by chars) is a valid WGSL identifier.
    var r = try validateSource(
        \\fn main() -> f32 {
        \\  let _x: f32 = 1.0;
        \\  return _x;
        \\}
    );
    defer r.deinit();
    for (r.diagnostics.items()) |d| {
        if (d.severity == .@"error" and std.mem.eql(u8, d.code, "E0105")) {
            dumpDiags("unexpected E0105 on '_x'", r);
            return error.TestUnexpectedResult;
        }
    }
}

test "E0105: x__y (internal double underscore) is OK" {
    // Only a leading `__` prefix is reserved.
    var r = try validateSource(
        \\fn main() -> f32 {
        \\  let x__y: f32 = 1.0;
        \\  return x__y;
        \\}
    );
    defer r.deinit();
    for (r.diagnostics.items()) |d| {
        if (d.severity == .@"error" and std.mem.eql(u8, d.code, "E0105")) {
            dumpDiags("unexpected E0105 on 'x__y'", r);
            return error.TestUnexpectedResult;
        }
    }
}

// -------------------------------------------------------------------------
// E0213 ambiguous operator precedence
// -------------------------------------------------------------------------

test "E0213: shift nested in comparison without parens" {
    var r = try validateSource(
        \\fn main() -> bool {
        \\  let a: u32 = 1u;
        \\  let b: u32 = 2u;
        \\  let c: u32 = 3u;
        \\  return a < b << c;
        \\}
    );
    defer r.deinit();
    if (!hasErrorWithCode(r, "E0213")) {
        dumpDiags("no E0213 for 'a < b << c'", r);
        return error.TestUnexpectedResult;
    }
}

test "E0213: && and || mixed without parens" {
    var r = try validateSource(
        \\fn main() -> bool {
        \\  let a: bool = true;
        \\  let b: bool = false;
        \\  let c: bool = true;
        \\  return a && b || c;
        \\}
    );
    defer r.deinit();
    if (!hasErrorWithCode(r, "E0213")) {
        dumpDiags("no E0213 for '&& ||'", r);
        return error.TestUnexpectedResult;
    }
}

test "E0213: bitwise & and | mixed without parens" {
    var r = try validateSource(
        \\fn main() -> u32 {
        \\  let a: u32 = 1u;
        \\  let b: u32 = 2u;
        \\  let c: u32 = 3u;
        \\  return a & b | c;
        \\}
    );
    defer r.deinit();
    if (!hasErrorWithCode(r, "E0213")) {
        dumpDiags("no E0213 for '& |'", r);
        return error.TestUnexpectedResult;
    }
}

test "E0213: shift nested in arithmetic without parens" {
    var r = try validateSource(
        \\fn main() -> u32 {
        \\  let a: u32 = 1u;
        \\  let b: u32 = 2u;
        \\  let c: u32 = 3u;
        \\  return a + b << c;
        \\}
    );
    defer r.deinit();
    if (!hasErrorWithCode(r, "E0213")) {
        dumpDiags("no E0213 for '+ <<'", r);
        return error.TestUnexpectedResult;
    }
}

test "E0213: parentheses silence the check" {
    var r = try validateSource(
        \\fn main() -> bool {
        \\  let a: bool = true;
        \\  let b: bool = false;
        \\  let c: bool = true;
        \\  return (a && b) || c;
        \\}
    );
    defer r.deinit();
    for (r.diagnostics.items()) |d| {
        if (d.severity == .@"error" and std.mem.eql(u8, d.code, "E0213")) {
            dumpDiags("unexpected E0213 inside parens", r);
            return error.TestUnexpectedResult;
        }
    }
}

test "E0213: associative same-op chains are OK" {
    // `a & b & c` is unambiguous — all operands are bitwise-and.
    var r = try validateSource(
        \\fn main() -> u32 {
        \\  let a: u32 = 1u;
        \\  let b: u32 = 2u;
        \\  let c: u32 = 3u;
        \\  return a & b & c;
        \\}
    );
    defer r.deinit();
    for (r.diagnostics.items()) |d| {
        if (d.severity == .@"error" and std.mem.eql(u8, d.code, "E0213")) {
            dumpDiags("unexpected E0213 on associative chain", r);
            return error.TestUnexpectedResult;
        }
    }
}

test "E0213: arithmetic within arithmetic is OK" {
    var r = try validateSource(
        \\fn main() -> u32 {
        \\  let a: u32 = 1u;
        \\  let b: u32 = 2u;
        \\  let c: u32 = 3u;
        \\  return a + b * c;
        \\}
    );
    defer r.deinit();
    for (r.diagnostics.items()) |d| {
        if (d.severity == .@"error" and std.mem.eql(u8, d.code, "E0213")) {
            dumpDiags("unexpected E0213 on arithmetic", r);
            return error.TestUnexpectedResult;
        }
    }
}

// -------------------------------------------------------------------------
// E0214 deref requires pointer / E0215 address-of requires reference
// -------------------------------------------------------------------------

test "E0214: *f32 on non-pointer fires" {
    var r = try validateSource(
        \\fn main() -> f32 {
        \\  let x: f32 = 1.0;
        \\  return *x;
        \\}
    );
    defer r.deinit();
    if (!hasErrorWithCode(r, "E0214")) {
        dumpDiags("no E0214 for '*x' where x is f32", r);
        return error.TestUnexpectedResult;
    }
}

test "E0214: dereferencing a pointer is OK" {
    var r = try validateSource(
        \\fn main() -> f32 {
        \\  var x: f32 = 1.0;
        \\  let p = &x;
        \\  return *p;
        \\}
    );
    defer r.deinit();
    for (r.diagnostics.items()) |d| {
        if (d.severity == .@"error" and std.mem.eql(u8, d.code, "E0214")) {
            dumpDiags("unexpected E0214 on valid pointer deref", r);
            return error.TestUnexpectedResult;
        }
    }
}

test "E0215: &literal has no address" {
    var r = try validateSource(
        \\fn main() -> f32 {
        \\  var x: f32 = 1.0;
        \\  let p = &1.0;
        \\  return x;
        \\}
    );
    defer r.deinit();
    if (!hasErrorWithCode(r, "E0215")) {
        dumpDiags("no E0215 for '&1.0'", r);
        return error.TestUnexpectedResult;
    }
}

test "E0215: &(a + b) has no address" {
    var r = try validateSource(
        \\fn main() -> f32 {
        \\  var a: f32 = 1.0;
        \\  var b: f32 = 2.0;
        \\  let p = &(a + b);
        \\  return a;
        \\}
    );
    defer r.deinit();
    if (!hasErrorWithCode(r, "E0215")) {
        dumpDiags("no E0215 for '&(a + b)'", r);
        return error.TestUnexpectedResult;
    }
}

test "E0215: &x on a variable is OK" {
    var r = try validateSource(
        \\fn main() -> f32 {
        \\  var x: f32 = 1.0;
        \\  let p = &x;
        \\  return *p;
        \\}
    );
    defer r.deinit();
    for (r.diagnostics.items()) |d| {
        if (d.severity == .@"error" and std.mem.eql(u8, d.code, "E0215")) {
            dumpDiags("unexpected E0215 on valid addr-of", r);
            return error.TestUnexpectedResult;
        }
    }
}

// -------------------------------------------------------------------------
// E0215: non-`var` ident roots — the address-of operator requires a
// reference, and only `var` declarations produce references in WGSL. The
// validator must emit a kind-specific message for each other declaration
// kind instead of silently fabricating a `ptr<function, T, read_write>`
// that would cascade misleading errors downstream.
// -------------------------------------------------------------------------

test "E0215: &module_const fires with kind-specific message" {
    var r = try validateSource(
        \\const C: i32 = 1;
        \\fn main() { let p = &C; _ = p; }
    );
    defer r.deinit();
    if (!hasErrorContaining(r, "E0215", "'const' declarations")) {
        dumpDiags("no kind-specific E0215 for '&C' (const)", r);
        return error.TestUnexpectedResult;
    }
}

test "E0215: &local_const fires" {
    var r = try validateSource(
        \\fn main() {
        \\  const c: i32 = 1;
        \\  let p = &c;
        \\  _ = p;
        \\}
    );
    defer r.deinit();
    if (!hasErrorContaining(r, "E0215", "'const' declarations")) {
        dumpDiags("no E0215 for '&c' (local const)", r);
        return error.TestUnexpectedResult;
    }
}

test "E0215: &override fires" {
    var r = try validateSource(
        \\override OV: i32 = 1;
        \\fn main() { let p = &OV; _ = p; }
    );
    defer r.deinit();
    if (!hasErrorContaining(r, "E0215", "'override' declarations")) {
        dumpDiags("no E0215 for '&OV' (override)", r);
        return error.TestUnexpectedResult;
    }
}

test "E0215: &let_binding fires" {
    var r = try validateSource(
        \\fn main() {
        \\  let x: i32 = 1;
        \\  let p = &x;
        \\  _ = p;
        \\}
    );
    defer r.deinit();
    if (!hasErrorContaining(r, "E0215", "'let' bindings are not references")) {
        dumpDiags("no E0215 for '&x' (let)", r);
        return error.TestUnexpectedResult;
    }
}

test "E0215: &value_parameter fires" {
    var r = try validateSource(
        \\fn f(p: i32) -> i32 {
        \\  let q = &p;
        \\  return *q;
        \\}
    );
    defer r.deinit();
    if (!hasErrorContaining(r, "E0215", "parameters are not references")) {
        dumpDiags("no E0215 for '&p' (value parameter)", r);
        return error.TestUnexpectedResult;
    }
}

test "E0215: &struct_name fires" {
    var r = try validateSource(
        \\struct S { a: i32 }
        \\fn main() { let p = &S; _ = p; }
    );
    defer r.deinit();
    if (!hasErrorContaining(r, "E0215", "type name")) {
        dumpDiags("no E0215 for '&S' (struct name)", r);
        return error.TestUnexpectedResult;
    }
}

test "E0215: &alias_name fires" {
    var r = try validateSource(
        \\alias A = i32;
        \\fn main() { let p = &A; _ = p; }
    );
    defer r.deinit();
    if (!hasErrorContaining(r, "E0215", "type name")) {
        dumpDiags("no E0215 for '&A' (alias)", r);
        return error.TestUnexpectedResult;
    }
}

test "E0215: &user_function fires" {
    var r = try validateSource(
        \\fn foo() {}
        \\fn main() { let p = &foo; _ = p; }
    );
    defer r.deinit();
    if (!hasErrorContaining(r, "E0215", "function")) {
        dumpDiags("no E0215 for '&foo' (function)", r);
        return error.TestUnexpectedResult;
    }
}

test "E0215: &builtin_function fires" {
    var r = try validateSource(
        \\fn main() { let p = &max; _ = p; }
    );
    defer r.deinit();
    // Accept either E0215 (our preferred diagnostic) or any upstream error
    // that catches the builtin reference before it reaches the `&` handler.
    // What we refuse is: silent acceptance producing a phantom pointer.
    var had_any_error = false;
    for (r.diagnostics.items()) |d| if (d.severity == .@"error") {
        had_any_error = true;
    };
    if (!had_any_error) {
        dumpDiags("'&max' silently accepted — no error emitted", r);
        return error.TestUnexpectedResult;
    }
}

// -------------------------------------------------------------------------
// E0215: tightened syntactic gate — `&foo().x`, `&(a+b).x`, `&foo()[0]`
// used to slip past the old gate (which accepted `.member` / `.index`
// unconditionally), then fell into the AS/AM resolver's silent default.
// The gate now recurses into the projection base.
// -------------------------------------------------------------------------

test "E0215: &call().field is rejected (call base under member)" {
    var r = try validateSource(
        \\fn make() -> vec2<i32> { return vec2<i32>(1, 2); }
        \\fn main() {
        \\  let p = &make().x;
        \\  _ = p;
        \\}
    );
    defer r.deinit();
    // Note: vec component errors (E0216) are specific to vector component
    // addressing; for `&make().x` on a value vector, E0215 fires at the
    // syntactic gate before the vector check runs.
    if (!hasErrorWithCode(r, "E0215")) {
        dumpDiags("no E0215 for '&make().x' (call base)", r);
        return error.TestUnexpectedResult;
    }
}

test "E0215: &call()[0] is rejected (call base under index)" {
    var r = try validateSource(
        \\fn make() -> array<i32, 4> { return array<i32, 4>(1, 2, 3, 4); }
        \\fn main() {
        \\  let p = &make()[0];
        \\  _ = p;
        \\}
    );
    defer r.deinit();
    if (!hasErrorWithCode(r, "E0215")) {
        dumpDiags("no E0215 for '&make()[0]' (call base)", r);
        return error.TestUnexpectedResult;
    }
}

test "E0215: &(a+b).x is rejected (binary base under member)" {
    var r = try validateSource(
        \\fn main() {
        \\  let a = vec2<i32>(1, 2);
        \\  let b = vec2<i32>(3, 4);
        \\  let p = &(a + b).x;
        \\  _ = p;
        \\}
    );
    defer r.deinit();
    if (!hasErrorWithCode(r, "E0215")) {
        dumpDiags("no E0215 for '&(a+b).x' (binary base)", r);
        return error.TestUnexpectedResult;
    }
}

test "E0215: &paren-wrapped call base is still rejected" {
    var r = try validateSource(
        \\fn make() -> i32 { return 0; }
        \\fn main() {
        \\  let p = &(make());
        \\  _ = p;
        \\}
    );
    defer r.deinit();
    if (!hasErrorWithCode(r, "E0215")) {
        dumpDiags("no E0215 for '&(make())'", r);
        return error.TestUnexpectedResult;
    }
}

// -------------------------------------------------------------------------
// E0216 / E0217 regression guards: the tightened gate and kind-based root
// classifier must not swallow the specific vector-component / handle
// diagnostics. They fire ahead of AS/AM resolution and must keep winning.
// -------------------------------------------------------------------------

test "E0216: &vector_var.x still fires specifically" {
    var r = try validateSource(
        \\fn main() {
        \\  var v: vec3<f32> = vec3<f32>(1.0, 2.0, 3.0);
        \\  let p = &v.x;
        \\  _ = p;
        \\}
    );
    defer r.deinit();
    if (!hasErrorWithCode(r, "E0216")) {
        dumpDiags("no E0216 for '&v.x'", r);
        return error.TestUnexpectedResult;
    }
}

test "E0216: &vector_var[0] still fires specifically" {
    var r = try validateSource(
        \\fn main() {
        \\  var v: vec3<f32> = vec3<f32>(1.0, 2.0, 3.0);
        \\  let p = &v[0];
        \\  _ = p;
        \\}
    );
    defer r.deinit();
    if (!hasErrorWithCode(r, "E0216")) {
        dumpDiags("no E0216 for '&v[0]'", r);
        return error.TestUnexpectedResult;
    }
}

test "E0217: &texture_var still fires specifically" {
    var r = try validateSource(
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\fn main() { let p = &tex; _ = p; }
    );
    defer r.deinit();
    if (!hasErrorWithCode(r, "E0217")) {
        dumpDiags("no E0217 for '&tex' (texture)", r);
        return error.TestUnexpectedResult;
    }
}

test "E0217: &sampler_var still fires specifically" {
    var r = try validateSource(
        \\@group(0) @binding(0) var samp: sampler;
        \\fn main() { let p = &samp; _ = p; }
    );
    defer r.deinit();
    if (!hasErrorWithCode(r, "E0217")) {
        dumpDiags("no E0217 for '&samp' (sampler)", r);
        return error.TestUnexpectedResult;
    }
}

// -------------------------------------------------------------------------
// Valid addressable chains must still resolve cleanly. Each case below
// passes the `&expr` result to a pointer parameter of exactly the AS/AM
// we expect, so any regression where the old defaults creep back in
// (e.g. storage/read_write collapsing to function/read_write) would fire
// a type-mismatch error. Here we assert no E0214/E0215/E0216/E0217 fires.
// -------------------------------------------------------------------------

fn assertNoAddressOfErrors(r: wgslender.Validator.Result, label: []const u8) !void {
    for (r.diagnostics.items()) |d| {
        if (d.severity != .@"error") continue;
        const c = d.code;
        if (std.mem.eql(u8, c, "E0214") or std.mem.eql(u8, c, "E0215") or
            std.mem.eql(u8, c, "E0216") or std.mem.eql(u8, c, "E0217"))
        {
            dumpDiags(label, r);
            return error.TestUnexpectedResult;
        }
    }
}

test "valid: &function_var → ptr<function, T, read_write>" {
    var r = try validateSource(
        \\fn takes(p: ptr<function, i32, read_write>) { *p = 1; }
        \\fn main() {
        \\  var x: i32 = 0;
        \\  takes(&x);
        \\}
    );
    defer r.deinit();
    try assertNoAddressOfErrors(r, "&function_var regressed");
}

test "valid: &private_var → ptr<private, T, read_write>" {
    var r = try validateSource(
        \\var<private> pv: i32 = 0;
        \\fn takes(p: ptr<private, i32, read_write>) { *p = 1; }
        \\fn main() { takes(&pv); }
    );
    defer r.deinit();
    try assertNoAddressOfErrors(r, "&private_var regressed");
}

test "valid: &workgroup_var → ptr<workgroup, T, read_write>" {
    var r = try validateSource(
        \\var<workgroup> wg: i32;
        \\fn takes(p: ptr<workgroup, i32, read_write>) { *p = 1; }
        \\@compute @workgroup_size(1)
        \\fn main() { takes(&wg); }
    );
    defer r.deinit();
    try assertNoAddressOfErrors(r, "&workgroup_var regressed");
}

test "valid: &storage_var_rw → ptr<storage, T, read_write>" {
    var r = try validateSource(
        \\@group(0) @binding(0) var<storage, read_write> buf: i32;
        \\fn takes(p: ptr<storage, i32, read_write>) { *p = 1; }
        \\@compute @workgroup_size(1)
        \\fn main() { takes(&buf); }
    );
    defer r.deinit();
    try assertNoAddressOfErrors(r, "&storage_var_rw regressed");
}

test "valid: &storage_var_default → ptr<storage, T, read>" {
    var r = try validateSource(
        \\@group(0) @binding(0) var<storage> buf: i32;
        \\fn takes(p: ptr<storage, i32, read>) -> i32 { return *p; }
        \\@compute @workgroup_size(1)
        \\fn main() { _ = takes(&buf); }
    );
    defer r.deinit();
    try assertNoAddressOfErrors(r, "&storage_var_default regressed");
}

test "valid: &uniform_var → ptr<uniform, T, read>" {
    var r = try validateSource(
        \\struct U { v: vec4<f32> }
        \\@group(0) @binding(0) var<uniform> uni: U;
        \\fn takes(p: ptr<uniform, U, read>) -> vec4<f32> { return (*p).v; }
        \\@compute @workgroup_size(1)
        \\fn main() { _ = takes(&uni); }
    );
    defer r.deinit();
    try assertNoAddressOfErrors(r, "&uniform_var regressed");
}

test "valid: &struct_var.field carries var AS/AM" {
    var r = try validateSource(
        \\struct S { a: i32, b: i32 }
        \\@group(0) @binding(0) var<storage, read_write> s: S;
        \\fn takes(p: ptr<storage, i32, read_write>) { *p = 1; }
        \\@compute @workgroup_size(1)
        \\fn main() { takes(&s.a); }
    );
    defer r.deinit();
    try assertNoAddressOfErrors(r, "&s.field regressed");
}

test "valid: &array_var[i] carries var AS/AM" {
    var r = try validateSource(
        \\var<private> arr: array<i32, 4>;
        \\fn takes(p: ptr<private, i32, read_write>) { *p = 1; }
        \\fn main() { takes(&arr[0]); }
    );
    defer r.deinit();
    try assertNoAddressOfErrors(r, "&arr[i] regressed");
}

test "valid: &(*ptr_param).field projects parameter AS/AM" {
    var r = try validateSource(
        \\struct S { a: i32 }
        \\fn inner(p: ptr<storage, i32, read_write>) { *p = 1; }
        \\fn outer(p: ptr<storage, S, read_write>) { inner(&(*p).a); }
    );
    defer r.deinit();
    try assertNoAddressOfErrors(r, "&(*p).field regressed");
}

test "valid: &(*ptr_param)[i] projects parameter AS/AM" {
    var r = try validateSource(
        \\fn inner(p: ptr<workgroup, i32, read_write>) { *p = 1; }
        \\fn outer(p: ptr<workgroup, array<i32, 4>, read_write>) { inner(&(*p)[0]); }
    );
    defer r.deinit();
    try assertNoAddressOfErrors(r, "&(*p)[i] regressed");
}

test "valid: deep member chain on storage var" {
    var r = try validateSource(
        \\struct Inner { deep: i32 }
        \\struct S { inner: Inner }
        \\@group(0) @binding(0) var<storage, read_write> s: S;
        \\fn takes(p: ptr<storage, i32, read_write>) { *p = 1; }
        \\@compute @workgroup_size(1)
        \\fn main() { takes(&s.inner.deep); }
    );
    defer r.deinit();
    try assertNoAddressOfErrors(r, "deep member chain regressed");
}

// -------------------------------------------------------------------------
// Cascade-suppression: when a sub-expression already fails, the `&`
// wrapper must not fabricate a bogus pointer type that would then cascade
// into a second (misleading) E0215 / type-mismatch. At most one E0215
// should be attributable to the `&` form — usually zero, with the single
// error being the upstream cause.
// -------------------------------------------------------------------------

test "cascade: &undefined_ident reports undefined without extra E0215" {
    var r = try validateSource(
        \\fn main() { let p = &unknown_ident; _ = p; }
    );
    defer r.deinit();
    // Undefined-symbol must fire (E0100 or equivalent).
    if (!hasErrorWithCode(r, "E0100")) {
        dumpDiags("expected E0100 for '&unknown_ident'", r);
        return error.TestUnexpectedResult;
    }
    // Zero E0215 cascade is ideal; allow at most 0 here since the operand
    // check fails first and the `&` handler early-exits.
    if (countErrorsWithCode(r, "E0215") > 0) {
        dumpDiags("unexpected E0215 cascade on '&unknown_ident'", r);
        return error.TestUnexpectedResult;
    }
}

test "cascade: &(*unknown).field reports only upstream error" {
    var r = try validateSource(
        \\fn main() { let p = &(*unknown).field; _ = p; }
    );
    defer r.deinit();
    if (!hasErrorWithCode(r, "E0100")) {
        dumpDiags("expected E0100 upstream of '&(*unknown).field'", r);
        return error.TestUnexpectedResult;
    }
    if (countErrorsWithCode(r, "E0215") > 0) {
        dumpDiags("unexpected E0215 cascade from '&(*unknown).field'", r);
        return error.TestUnexpectedResult;
    }
}

test "cascade: &s.missing_field reports no-such-member without extra E0215" {
    var r = try validateSource(
        \\struct S { a: i32 }
        \\@group(0) @binding(0) var<storage, read_write> s: S;
        \\@compute @workgroup_size(1)
        \\fn main() { let p = &s.missing; _ = p; }
    );
    defer r.deinit();
    if (!hasErrorWithCode(r, "E0206")) {
        dumpDiags("expected E0206 for '&s.missing'", r);
        return error.TestUnexpectedResult;
    }
    if (countErrorsWithCode(r, "E0215") > 0) {
        dumpDiags("unexpected E0215 cascade from '&s.missing'", r);
        return error.TestUnexpectedResult;
    }
}

test "cascade: &arr[undefined] reports undefined without extra E0215" {
    var r = try validateSource(
        \\var<private> arr: array<i32, 4>;
        \\fn main() { let p = &arr[unknown]; _ = p; }
    );
    defer r.deinit();
    if (!hasErrorWithCode(r, "E0100")) {
        dumpDiags("expected E0100 for '&arr[unknown]'", r);
        return error.TestUnexpectedResult;
    }
    if (countErrorsWithCode(r, "E0215") > 0) {
        dumpDiags("unexpected E0215 cascade from '&arr[unknown]'", r);
        return error.TestUnexpectedResult;
    }
}
