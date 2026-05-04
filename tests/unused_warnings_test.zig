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

// =========================================================================
// Edge cases
// =========================================================================

test "unused warnings: unused const" {
    const source: [:0]const u8 = "const UNUSED_CONST: f32 = 3.14;";
    const warnings = try getUnusedWarnings(source);
    defer freeWarnings(warnings);
    try std.testing.expect(hasWarningFor(warnings, "UNUSED_CONST"));
}

test "unused warnings: unused override" {
    const source: [:0]const u8 = "@id(0) override UNUSED_OVR: u32 = 8;";
    const warnings = try getUnusedWarnings(source);
    defer freeWarnings(warnings);
    try std.testing.expect(hasWarningFor(warnings, "UNUSED_OVR"));
}

test "unused warnings: function used by another function no warning" {
    const source: [:0]const u8 = "fn helper() -> f32 { return 1.0; } fn main() -> f32 { return helper(); }";
    const warnings = try getUnusedWarnings(source);
    defer freeWarnings(warnings);
    try std.testing.expect(!hasWarningFor(warnings, "helper"));
}

test "unused warnings: all entry point stages excluded" {
    const source: [:0]const u8 =
        \\@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0.0); }
        \\@fragment fn fs() -> @location(0) vec4f { return vec4f(0.0); }
        \\@compute @workgroup_size(1) fn cs() {}
    ;
    const warnings = try getUnusedWarnings(source);
    defer freeWarnings(warnings);
    try std.testing.expect(!hasWarningFor(warnings, "vs"));
    try std.testing.expect(!hasWarningFor(warnings, "fs"));
    try std.testing.expect(!hasWarningFor(warnings, "cs"));
}

test "unused warnings: multiple unused symbols" {
    const source: [:0]const u8 = "fn a() {} fn b() {} fn c() {} const D: f32 = 1.0;";
    const warnings = try getUnusedWarnings(source);
    defer freeWarnings(warnings);
    try std.testing.expect(hasWarningFor(warnings, "a"));
    try std.testing.expect(hasWarningFor(warnings, "b"));
    try std.testing.expect(hasWarningFor(warnings, "c"));
    try std.testing.expect(hasWarningFor(warnings, "D"));
}

test "unused warnings: empty source no warnings" {
    const source: [:0]const u8 = "";
    const warnings = try getUnusedWarnings(source);
    defer freeWarnings(warnings);
    try std.testing.expectEqual(@as(usize, 0), warnings.len);
}

test "unused warnings: struct not warned" {
    // Structs don't have use_count in the same way
    const source: [:0]const u8 = "struct S { x: f32 }";
    const warnings = try getUnusedWarnings(source);
    defer freeWarnings(warnings);
    // Structs are not warned about (kind is .struct, excluded from check)
    try std.testing.expect(!hasWarningFor(warnings, "S"));
}

test "unused warnings: message format" {
    const source: [:0]const u8 = "fn lonely() {}";
    const warnings = try getUnusedWarnings(source);
    defer freeWarnings(warnings);
    try std.testing.expect(warnings.len > 0);
    // Message should contain the name in quotes
    try std.testing.expect(std.mem.indexOf(u8, warnings[0].message, "'lonely'") != null);
    try std.testing.expect(std.mem.indexOf(u8, warnings[0].message, "declared but never used") != null);
}

test "unused warnings: unused symbol has unnecessary tag" {
    const source: [:0]const u8 = "fn unused_fn() {}";
    const warnings = try getUnusedWarnings(source);
    defer freeWarnings(warnings);
    try std.testing.expect(warnings.len > 0);
    try std.testing.expect(warnings[0].tags.len > 0);
    try std.testing.expectEqual(Handler.DiagnosticTag.unnecessary, warnings[0].tags[0]);
}

// =========================================================================
// Dead code warnings (unreachable from entry points)
// =========================================================================

fn getDeadCodeWarnings(source: [:0]const u8) ![]Handler.LspDiagnostic {
    var result = try wgslender.analyzeWithOptions(std.testing.allocator, source, .{});
    defer result.deinit(std.testing.allocator);

    // Run DCE to compute is_live flags. Stash the Liveness side-table
    // on the analysis so the new `unused_warnings` reads exercise the
    // side-table path alongside the field — matches what the LSP does.
    if (result.module) |module| {
        if (result._arena) |*arena| {
            const aa = arena.allocator();
            if (wgslender.Liveness.init(aa, module.symbols.items.len)) |liveness_init| {
                var liveness = liveness_init;
                _ = wgslender.Dce.mark(aa, module, &liveness) catch {};
                result.liveness = liveness;
            } else |_| {}
        }
    }

    var diags: std.ArrayListUnmanaged(Handler.LspDiagnostic) = .empty;
    Handler.appendDeadCodeWarnings(std.testing.allocator, &result, &diags);
    return diags.toOwnedSlice(std.testing.allocator) catch &.{};
}

test "dead code: function reachable from entry point not flagged" {
    const source: [:0]const u8 = "fn helper() -> f32 { return 1.0; } @vertex fn main() -> @builtin(position) vec4f { return vec4f(helper()); }";
    const warnings = try getDeadCodeWarnings(source);
    defer freeWarnings(warnings);
    try std.testing.expectEqual(@as(usize, 0), warnings.len);
}

test "dead code: function not reachable from entry point flagged" {
    const source: [:0]const u8 = "fn helper() -> f32 { return 1.0; } fn process() -> f32 { return helper(); } @vertex fn main() -> @builtin(position) vec4f { return vec4f(0.0); }";
    const warnings = try getDeadCodeWarnings(source);
    defer freeWarnings(warnings);
    // Both helper and process are used internally but unreachable from main
    try std.testing.expect(warnings.len >= 1);
    try std.testing.expect(warnings[0].tags.len > 0);
    try std.testing.expectEqual(Handler.DiagnosticTag.unnecessary, warnings[0].tags[0]);
}

test "dead code: no entry points means no dead code warnings" {
    // Library mode — no entry points, DCE marks everything live
    const source: [:0]const u8 = "fn helper() -> f32 { return 1.0; } fn process() -> f32 { return helper(); }";
    const warnings = try getDeadCodeWarnings(source);
    defer freeWarnings(warnings);
    try std.testing.expectEqual(@as(usize, 0), warnings.len);
}

test "dead code: entry point itself not flagged" {
    const source: [:0]const u8 = "@vertex fn main() -> @builtin(position) vec4f { return vec4f(0.0); }";
    const warnings = try getDeadCodeWarnings(source);
    defer freeWarnings(warnings);
    try std.testing.expectEqual(@as(usize, 0), warnings.len);
}

// =========================================================================
// Unused binding warnings (W0003)
// =========================================================================

fn getUnusedBindingWarnings(source: [:0]const u8) ![]Handler.LspDiagnostic {
    var result = try wgslender.analyzeWithOptions(std.testing.allocator, source, .{});
    defer result.deinit(std.testing.allocator);

    // Run DCE to compute is_live flags. Stash the Liveness side-table
    // on the analysis so the new `unused_warnings` reads exercise the
    // side-table path alongside the field — matches what the LSP does.
    if (result.module) |module| {
        if (result._arena) |*arena| {
            const aa = arena.allocator();
            if (wgslender.Liveness.init(aa, module.symbols.items.len)) |liveness_init| {
                var liveness = liveness_init;
                _ = wgslender.Dce.mark(aa, module, &liveness) catch {};
                result.liveness = liveness;
            } else |_| {}
        }
    }

    var diags: std.ArrayListUnmanaged(Handler.LspDiagnostic) = .empty;
    Handler.appendUnusedBindingWarnings(std.testing.allocator, &result, &diags);
    return diags.toOwnedSlice(std.testing.allocator) catch &.{};
}

test "unused binding: unused uniform var gets warning" {
    const source: [:0]const u8 =
        \\@group(0) @binding(0) var<uniform> unused_buf: f32;
        \\@compute @workgroup_size(1)
        \\fn main() {}
    ;
    const warnings = try getUnusedBindingWarnings(source);
    defer freeWarnings(warnings);
    try std.testing.expect(hasWarningFor(warnings, "unused_buf"));
}

test "unused binding: used uniform var no warning" {
    const source: [:0]const u8 =
        \\@group(0) @binding(0) var<uniform> used_buf: f32;
        \\@compute @workgroup_size(1)
        \\fn main() { let x = used_buf; }
    ;
    const warnings = try getUnusedBindingWarnings(source);
    defer freeWarnings(warnings);
    try std.testing.expect(!hasWarningFor(warnings, "used_buf"));
}

test "unused binding: unused storage var gets warning" {
    const source: [:0]const u8 =
        \\@group(0) @binding(0) var<storage> data: array<f32>;
        \\@compute @workgroup_size(1)
        \\fn main() {}
    ;
    const warnings = try getUnusedBindingWarnings(source);
    defer freeWarnings(warnings);
    try std.testing.expect(hasWarningFor(warnings, "data"));
}

test "unused binding: severity is warning with code W0003" {
    const source: [:0]const u8 =
        \\@group(0) @binding(0) var<uniform> unused_u: f32;
        \\@compute @workgroup_size(1)
        \\fn main() {}
    ;
    const warnings = try getUnusedBindingWarnings(source);
    defer freeWarnings(warnings);
    try std.testing.expect(warnings.len > 0);
    try std.testing.expect(warnings[0].severity == .warning);
    try std.testing.expectEqualStrings("W0003", warnings[0].code);
}

test "unused binding: has unnecessary tag" {
    const source: [:0]const u8 =
        \\@group(0) @binding(0) var<uniform> unused_u: f32;
        \\@compute @workgroup_size(1)
        \\fn main() {}
    ;
    const warnings = try getUnusedBindingWarnings(source);
    defer freeWarnings(warnings);
    try std.testing.expect(warnings.len > 0);
    try std.testing.expect(warnings[0].tags.len > 0);
    try std.testing.expectEqual(Handler.DiagnosticTag.unnecessary, warnings[0].tags[0]);
}

test "unused binding: message mentions bind group layout" {
    const source: [:0]const u8 =
        \\@group(0) @binding(0) var<uniform> my_buf: f32;
        \\@compute @workgroup_size(1)
        \\fn main() {}
    ;
    const warnings = try getUnusedBindingWarnings(source);
    defer freeWarnings(warnings);
    try std.testing.expect(warnings.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, warnings[0].message, "'my_buf'") != null);
    try std.testing.expect(std.mem.indexOf(u8, warnings[0].message, "bind group layout slot") != null);
}

test "unused binding: multiple unused bindings" {
    const source: [:0]const u8 =
        \\@group(0) @binding(0) var<uniform> a: f32;
        \\@group(0) @binding(1) var<uniform> b: f32;
        \\@group(0) @binding(2) var<storage> c: array<f32>;
        \\@compute @workgroup_size(1)
        \\fn main() {}
    ;
    const warnings = try getUnusedBindingWarnings(source);
    defer freeWarnings(warnings);
    try std.testing.expect(hasWarningFor(warnings, "a"));
    try std.testing.expect(hasWarningFor(warnings, "b"));
    try std.testing.expect(hasWarningFor(warnings, "c"));
}

test "unused binding: mix of used and unused" {
    const source: [:0]const u8 =
        \\@group(0) @binding(0) var<uniform> active_buf: f32;
        \\@group(0) @binding(1) var<uniform> idle_buf: f32;
        \\@compute @workgroup_size(1)
        \\fn main() { let x = active_buf; }
    ;
    const warnings = try getUnusedBindingWarnings(source);
    defer freeWarnings(warnings);
    try std.testing.expect(!hasWarningFor(warnings, "active_buf"));
    try std.testing.expect(hasWarningFor(warnings, "idle_buf"));
}

test "unused binding: no bindings means no warnings" {
    const source: [:0]const u8 =
        \\@compute @workgroup_size(1)
        \\fn main() {}
    ;
    const warnings = try getUnusedBindingWarnings(source);
    defer freeWarnings(warnings);
    try std.testing.expectEqual(@as(usize, 0), warnings.len);
}

test "unused binding: private var not treated as binding" {
    const source: [:0]const u8 =
        \\var<private> x: f32 = 0.0;
    ;
    const warnings = try getUnusedBindingWarnings(source);
    defer freeWarnings(warnings);
    // Private vars are not bindings, should not appear here
    try std.testing.expectEqual(@as(usize, 0), warnings.len);
}
