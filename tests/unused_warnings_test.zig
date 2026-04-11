const std = @import("std");
const Handler = @import("Handler");
const wgslender = @import("wgslender");

fn getUnusedWarnings(source: [:0]const u8) ![]Handler.LspDiagnostic {
    var result = try wgslender.analyzeWithOptions(std.testing.allocator, source, .{});
    defer result.deinit(std.testing.allocator);

    var diags: std.ArrayListUnmanaged(Handler.LspDiagnostic) = .empty;
    Handler.appendUnusedWarnings(std.testing.allocator, &result, &diags);
    return diags.toOwnedSlice(std.testing.allocator) catch &.{};
}

fn freeWarnings(warnings: []Handler.LspDiagnostic) void {
    for (warnings) |w| {
        std.testing.allocator.free(w.message);
    }
    std.testing.allocator.free(warnings);
}

fn hasWarningFor(warnings: []const Handler.LspDiagnostic, name: []const u8) bool {
    for (warnings) |w| {
        if (std.mem.indexOf(u8, w.message, name) != null) return true;
    }
    return false;
}

test "unused warnings: unused let" {
    const source: [:0]const u8 = "fn f() { let unused_var: f32 = 1.0; }";
    const warnings = try getUnusedWarnings(source);
    defer freeWarnings(warnings);
    try std.testing.expect(hasWarningFor(warnings, "unused_var"));
}

test "unused warnings: unused function" {
    const source: [:0]const u8 = "fn unused_fn() {}";
    const warnings = try getUnusedWarnings(source);
    defer freeWarnings(warnings);
    try std.testing.expect(hasWarningFor(warnings, "unused_fn"));
}

test "unused warnings: used variable no warning" {
    const source: [:0]const u8 = "const x: f32 = 1.0; fn f() -> f32 { return x; }";
    const warnings = try getUnusedWarnings(source);
    defer freeWarnings(warnings);
    try std.testing.expect(!hasWarningFor(warnings, "x"));
}

test "unused warnings: entry point no warning" {
    const source: [:0]const u8 = "@compute @workgroup_size(1) fn main() {}";
    const warnings = try getUnusedWarnings(source);
    defer freeWarnings(warnings);
    try std.testing.expect(!hasWarningFor(warnings, "main"));
}

test "unused warnings: binding variable no warning" {
    const source: [:0]const u8 = "@group(0) @binding(0) var<uniform> u: f32;";
    const warnings = try getUnusedWarnings(source);
    defer freeWarnings(warnings);
    try std.testing.expect(!hasWarningFor(warnings, "u"));
}

test "unused warnings: severity is warning" {
    const source: [:0]const u8 = "fn unused() {}";
    const warnings = try getUnusedWarnings(source);
    defer freeWarnings(warnings);
    try std.testing.expect(warnings.len > 0);
    try std.testing.expect(warnings[0].severity == .warning);
    try std.testing.expectEqualStrings("W0001", warnings[0].code);
}
