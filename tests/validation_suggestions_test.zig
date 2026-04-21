//! "Did you mean?" suggestions for the last-mile diagnostic sites that the
//! Levenshtein engine didn't previously cover: swizzle components, address
//! space, access mode, and enable-feature names (DIAGNOSTICS_ROADMAP.md
//! item 2, Phase B).

const std = @import("std");
const wgslender = @import("wgslender");

fn expectErrorContains(source: [:0]const u8, needle: []const u8) !void {
    var r = try wgslender.validateWithOptions(std.testing.allocator, source, .{});
    defer r.deinit(std.testing.allocator);

    for (r.diagnostics.items()) |d| {
        if (d.severity == .@"error" and std.mem.indexOf(u8, d.message, needle) != null) {
            return;
        }
    }
    std.debug.print("\nExpected error containing \"{s}\" but got:\n", .{needle});
    for (r.diagnostics.items()) |d| {
        std.debug.print(
            "  {d}:{d} [{s}] {s}: {s}\n",
            .{ d.range.start.line, d.range.start.column, d.code, d.severity.string(), d.message },
        );
    }
    return error.TestUnexpectedResult;
}

// -------------------------------------------------------------------------
// Swizzle
// -------------------------------------------------------------------------

test "suggest swizzle: invalid char on vec4 suggests xyzw-group replacement" {
    // 'q' is invalid. A single-edit fix within xyzw keeps first three chars.
    try expectErrorContains(
        \\fn main() { var v: vec4<f32> = vec4<f32>(0.0); let a = v.xywq; }
    , "did you mean '.");
}

test "suggest swizzle: invalid char on vec3 still suggests" {
    try expectErrorContains(
        \\fn main() { var v: vec3<f32> = vec3<f32>(0.0); let a = v.xyq; }
    , "did you mean '.");
}

test "suggest swizzle: mixed xyzw and rgba groups suggests single group" {
    try expectErrorContains(
        \\fn main() { var v: vec4<f32> = vec4<f32>(0.0); let a = v.xyrg; }
    , "did you mean '.");
}

// -------------------------------------------------------------------------
// Address space
// -------------------------------------------------------------------------

test "suggest address space: 'worrkgroup' suggests 'workgroup'" {
    try expectErrorContains(
        \\var<worrkgroup> x: f32;
    , "did you mean 'workgroup'");
}

test "suggest address space: 'privat' suggests 'private'" {
    try expectErrorContains(
        \\var<privat> x: f32;
    , "did you mean 'private'");
}

// -------------------------------------------------------------------------
// Access mode
// -------------------------------------------------------------------------

test "suggest access mode: 'read_wrte' suggests 'read_write'" {
    try expectErrorContains(
        \\@group(0) @binding(0) var<storage, read_wrte> x: f32;
    , "did you mean 'read_write'");
}

test "suggest access mode: 'reed' suggests 'read'" {
    try expectErrorContains(
        \\@group(0) @binding(0) var<storage, reed> x: f32;
    , "did you mean 'read'");
}

// -------------------------------------------------------------------------
// Enable feature
// -------------------------------------------------------------------------

test "suggest enable feature: 'f64' suggests 'f16'" {
    try expectErrorContains(
        \\enable f64;
    , "did you mean 'f16'");
}

test "suggest enable feature: 'subgroop' suggests 'subgroups'" {
    try expectErrorContains(
        \\enable subgroop;
    , "did you mean 'subgroups'");
}
