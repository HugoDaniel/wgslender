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
    defer r.deinit(std.testing.allocator);
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
    defer r.deinit(std.testing.allocator);
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
    defer r.deinit(std.testing.allocator);
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
    defer r.deinit(std.testing.allocator);
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
    defer r.deinit(std.testing.allocator);
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
    defer r.deinit(std.testing.allocator);
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
    defer r.deinit(std.testing.allocator);
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
    defer r.deinit(std.testing.allocator);
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
    defer r.deinit(std.testing.allocator);
    if (!hasErrorWithCode(r, "E0105")) {
        dumpDiags("no E0105 for let __tmp", r);
        return error.TestUnexpectedResult;
    }
}

test "E0105: fn __main is reserved" {
    var r = try validateSource(
        \\fn __main() -> f32 { return 0.0; }
    );
    defer r.deinit(std.testing.allocator);
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
    defer r.deinit(std.testing.allocator);
    if (!hasErrorWithCode(r, "E0105")) {
        dumpDiags("no E0105 for struct __S", r);
        return error.TestUnexpectedResult;
    }
}

test "E0105: parameter __p is reserved" {
    var r = try validateSource(
        \\fn helper(__p: f32) -> f32 { return __p; }
    );
    defer r.deinit(std.testing.allocator);
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
    defer r.deinit(std.testing.allocator);
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
    defer r.deinit(std.testing.allocator);
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
    defer r.deinit(std.testing.allocator);
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
    defer r.deinit(std.testing.allocator);
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
    defer r.deinit(std.testing.allocator);
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
    defer r.deinit(std.testing.allocator);
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
    defer r.deinit(std.testing.allocator);
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
    defer r.deinit(std.testing.allocator);
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
    defer r.deinit(std.testing.allocator);
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
    defer r.deinit(std.testing.allocator);
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
    defer r.deinit(std.testing.allocator);
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
    defer r.deinit(std.testing.allocator);
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
    defer r.deinit(std.testing.allocator);
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
    defer r.deinit(std.testing.allocator);
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
    defer r.deinit(std.testing.allocator);
    for (r.diagnostics.items()) |d| {
        if (d.severity == .@"error" and std.mem.eql(u8, d.code, "E0215")) {
            dumpDiags("unexpected E0215 on valid addr-of", r);
            return error.TestUnexpectedResult;
        }
    }
}
