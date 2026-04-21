//! Lint-style warnings beyond the unused-symbol family:
//!
//!   - W0100 shadowing: any inner scope (function body / nested block)
//!     that re-uses a name visible from an outer scope.
//!   - W0101 redundant cast: a type constructor call whose single
//!     argument is already of the target concrete type.
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
