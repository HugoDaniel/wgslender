//! Swizzle writability — WGSL §5.3.4 and §9.4.
//!
//! Key spec rules:
//! 1. A single-letter swizzle (`v.x`) yields a reference and can appear
//!    on the LHS of an assignment.
//! 2. A multi-letter swizzle (`v.xy`, `v.xyz`) always yields a value and
//!    cannot appear on the LHS of an assignment — even without duplicate
//!    components. Previously the validator only caught the duplicate case.
//! 3. Swizzle components must be all from {x,y,z,w} or all from {r,g,b,a}.
//! 4. Swizzle components must be in-bounds for the vector's width.

const std = @import("std");
const wgslender = @import("wgslender");

fn validate(src: [:0]const u8) !wgslender.Validator.Result {
    return wgslender.validateWithOptions(std.testing.allocator, src, .{});
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

// --- Valid single-letter writes ---

test "§5.3.4: single-letter swizzle write v.x = 1.0 is valid" {
    var r = try validate("fn f() { var v: vec3f; v.x = 1.0; }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("expected no errors on v.x write", r);
        return error.TestUnexpectedResult;
    }
}

test "§5.3.4: single-letter swizzle v.r (rgba group) write is valid" {
    var r = try validate("fn f() { var v: vec4f; v.r = 1.0; }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("expected no errors on v.r write", r);
        return error.TestUnexpectedResult;
    }
}

// --- Multi-letter swizzle writes are invalid (new check) ---

test "§5.3.4: v.xy = ... is rejected (multi-letter swizzle as LHS)" {
    var r = try validate("fn f() { var v: vec3f; v.xy = vec2f(1.0, 2.0); }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "multi-letter swizzle 'xy'")) {
        dump("expected multi-letter-swizzle error", r);
        return error.TestUnexpectedResult;
    }
}

test "§5.3.4: v.xyz = ... is rejected" {
    var r = try validate("fn f() { var v: vec3f; v.xyz = vec3f(1.0); }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "multi-letter swizzle 'xyz'")) {
        dump("expected multi-letter-swizzle error on xyz", r);
        return error.TestUnexpectedResult;
    }
}

test "§5.3.4: v.rgb = ... is rejected" {
    var r = try validate("fn f() { var v: vec4f; v.rgb = vec3f(1.0); }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "multi-letter swizzle 'rgb'")) {
        dump("expected multi-letter-swizzle error on rgb", r);
        return error.TestUnexpectedResult;
    }
}

// --- Duplicate-component writes (existing check) ---

test "§5.3.4: v.xx is rejected for duplicates" {
    var r = try validate("fn f() { var v: vec3f; v.xx = vec2f(1.0); }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "duplicate components")) {
        dump("expected duplicate-components error on xx", r);
        return error.TestUnexpectedResult;
    }
}

test "§5.3.4: v.xyx is rejected for duplicates" {
    var r = try validate("fn f() { var v: vec3f; v.xyx = vec3f(1.0); }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "duplicate components")) {
        dump("expected duplicate-components error on xyx", r);
        return error.TestUnexpectedResult;
    }
}

// --- Out-of-bounds components (existing check) ---

test "§5.3.4: v.a on vec3 is rejected (a requires vec4)" {
    var r = try validate("fn f() { var v: vec3f; v.a = 1.0; }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "out of bounds")) {
        dump("expected out-of-bounds error", r);
        return error.TestUnexpectedResult;
    }
}

// --- Multi-letter swizzles as r-values (not LHS) are valid ---

test "§5.3.4: let y = v.xy reads multi-letter swizzle — valid" {
    var r = try validate("fn f() { let v = vec3f(1.0, 2.0, 3.0); let y = v.xy; }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("expected no errors on swizzle read", r);
        return error.TestUnexpectedResult;
    }
}

test "§5.3.4: return v.xyz from a vec3<f32> fn is valid" {
    var r = try validate("fn f() -> vec3f { let v = vec4f(1.0, 2.0, 3.0, 4.0); return v.xyz; }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("expected no errors on swizzle return", r);
        return error.TestUnexpectedResult;
    }
}

// --- Compound assignment on single-letter swizzles ---

test "§5.3.4: compound += on v.x is valid" {
    var r = try validate("fn f() { var v: vec3f; v.x += 1.0; }");
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump("expected no errors on v.x +=", r);
        return error.TestUnexpectedResult;
    }
}

test "§5.3.4: compound += on multi-letter swizzle is rejected" {
    var r = try validate("fn f() { var v: vec3f; v.xy += vec2f(1.0, 2.0); }");
    defer r.deinit(std.testing.allocator);
    if (!hasErrorContaining(r, "multi-letter swizzle 'xy'")) {
        dump("expected multi-letter error on v.xy +=", r);
        return error.TestUnexpectedResult;
    }
}
