//! Literal range validation — WGSL §16.1 / §4.4.2.
//!
//! `checkLiteral` rejects integer / float literals whose magnitude doesn't
//! fit the destination type. The `i` and `abstract` paths admit `2^31` /
//! `2^63` exactly so `-2147483648i` and `-9223372036854775808` remain valid
//! when negated via unary `-`.

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

fn dump(label: []const u8, r: wgslender.Validator.Result) void {
    std.debug.print("\n{s}:\n", .{label});
    for (r.diagnostics.items()) |d| {
        std.debug.print("  [{s}] {s}: {s}\n", .{ d.code, d.severity.string(), d.message });
    }
}

// ---------- integer magnitude (unsuffixed = abstract-int) ----------

test "9223372036854775807 accepts (i64 max)" {
    var r = try validate("const X = 9223372036854775807;");
    defer r.deinit();
    try std.testing.expect(!anyError(r));
}

test "0x10000000000000000 rejects (2^64, doesn't fit in u64)" {
    var r = try validate("const X = 0x10000000000000000;");
    defer r.deinit();
    try std.testing.expect(hasErrorWithCode(r, "E0317"));
}

test "0xFFFFFFFFFFFFFFFF rejects (u64 max > i64-min carve-out)" {
    // Parses as u64 max; exceeds the 2^63 abstract-int ceiling.
    var r = try validate("const X = 0xFFFFFFFFFFFFFFFF;");
    defer r.deinit();
    try std.testing.expect(hasErrorWithCode(r, "E0317"));
}

// ---------- u suffix ----------

test "4294967295u accepts (u32 max)" {
    var r = try validate("const X = 4294967295u;");
    defer r.deinit();
    try std.testing.expect(!anyError(r));
}

test "4294967296u rejects (u32 max + 1)" {
    var r = try validate("const X = 4294967296u;");
    defer r.deinit();
    try std.testing.expect(hasErrorWithCode(r, "E0317"));
}

// ---------- i suffix ----------

test "2147483647i accepts (i32 max)" {
    var r = try validate("const X = 2147483647i;");
    defer r.deinit();
    try std.testing.expect(!anyError(r));
}

test "-2147483648i accepts (i32 min via unary -)" {
    var r = try validate("const X = -2147483648i;");
    defer r.deinit();
    try std.testing.expect(!anyError(r));
}

test "2147483649i rejects (beyond the i32-min carve-out)" {
    var r = try validate("const X = 2147483649i;");
    defer r.deinit();
    try std.testing.expect(hasErrorWithCode(r, "E0317"));
}

// ---------- float literals ----------

test "1e400 (unsuffixed) rejects as infinity" {
    var r = try validate("const X = 1e400;");
    defer r.deinit();
    try std.testing.expect(hasErrorWithCode(r, "E0314"));
}

test "1e40f rejects (finite in f64, out of f32 range)" {
    var r = try validate("const X = 1e40f;");
    defer r.deinit();
    try std.testing.expect(hasErrorWithCode(r, "E0314"));
}

test "1.0f accepts" {
    var r = try validate("const X = 1.0f;");
    defer r.deinit();
    try std.testing.expect(!anyError(r));
}
