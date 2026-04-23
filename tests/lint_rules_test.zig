//! Lint-rule unit tests.
//!
//! Each rule gets:
//!   - positive cases: source that should trigger the rule.
//!   - negative cases: source that should NOT trigger it.
//!   - config interaction: severity override to error and disable.
//!
//! Also covers Linter infrastructure: severity resolution from `extends`,
//! per-rule overrides, disabled flag, unknown-name tolerance.

const std = @import("std");
const wgslender = @import("wgslender");
const Severity = wgslender.Diagnostic.Severity;

fn runLint(
    source: [:0]const u8,
    options: wgslender.Linter.Options,
) !wgslender.LintResult {
    return wgslender.lint(std.testing.allocator, source, options);
}

fn hasCode(result: wgslender.LintResult, code: []const u8) bool {
    for (result.lint.diagnostics.items()) |d| {
        if (std.mem.eql(u8, d.code, code)) return true;
    }
    return false;
}

fn hasCodeContaining(result: wgslender.LintResult, code: []const u8, needle: []const u8) bool {
    for (result.lint.diagnostics.items()) |d| {
        if (!std.mem.eql(u8, d.code, code)) continue;
        if (std.mem.indexOf(u8, d.message, needle) != null) return true;
    }
    return false;
}

fn hasSeverity(result: wgslender.LintResult, code: []const u8, sev: Severity) bool {
    for (result.lint.diagnostics.items()) |d| {
        if (std.mem.eql(u8, d.code, code) and d.severity == sev) return true;
    }
    return false;
}

fn countCode(result: wgslender.LintResult, code: []const u8) usize {
    var n: usize = 0;
    for (result.lint.diagnostics.items()) |d| {
        if (std.mem.eql(u8, d.code, code)) n += 1;
    }
    return n;
}

fn dump(label: []const u8, result: wgslender.LintResult) void {
    std.debug.print("\n{s}:\n", .{label});
    for (result.lint.diagnostics.items()) |d| {
        std.debug.print(
            "  {d}:{d} [{s}] {s}: {s}\n",
            .{ d.range.start.line, d.range.start.column, d.code, d.severity.string(), d.message },
        );
    }
}

const recommended_opts = wgslender.Linter.Options{
    .extends = &.{"@wgslender/recommended"},
};

// =========================================================================
// no-unused-vars (W0001)
// =========================================================================

test "no-unused-vars: unused function" {
    var r = try runLint("fn lonely() {}", recommended_opts);
    defer r.deinit(std.testing.allocator);
    if (!hasCode(r, "W0001")) {
        dump("no-unused-vars: unused function", r);
        return error.TestUnexpectedResult;
    }
}

test "no-unused-vars: unused const" {
    var r = try runLint("const UNUSED: f32 = 3.14;", recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCodeContaining(r, "W0001", "UNUSED"));
}

test "no-unused-vars: unused let inside function" {
    var r = try runLint("fn f() { let inner: f32 = 1.0; }", recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCodeContaining(r, "W0001", "inner"));
}

test "no-unused-vars: unused override" {
    var r = try runLint("@id(0) override UNUSED_OVR: u32 = 8;", recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCodeContaining(r, "W0001", "UNUSED_OVR"));
}

test "no-unused-vars: used function is not flagged" {
    var r = try runLint("fn helper() -> f32 { return 1.0; } fn main() -> f32 { return helper(); }", recommended_opts);
    defer r.deinit(std.testing.allocator);
    // main is flagged (no entry-point attrs here), but helper is not
    for (r.lint.diagnostics.items()) |d| {
        if (std.mem.indexOf(u8, d.message, "'helper'") != null) {
            dump("unexpected flag on used helper", r);
            return error.TestUnexpectedResult;
        }
    }
}

test "no-unused-vars: entry point is excluded" {
    var r = try runLint("@compute @workgroup_size(1) fn main() {}", recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), r.lint.warning_count);
}

test "no-unused-vars: vertex / fragment / compute all excluded" {
    var r = try runLint(
        \\@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0.0); }
        \\@fragment fn fs() -> @location(0) vec4f { return vec4f(0.0); }
        \\@compute @workgroup_size(1) fn cs() {}
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), r.lint.warning_count);
}

test "no-unused-vars: external binding is excluded (caught by unused-binding separately)" {
    // `@group/@binding` vars are filtered out of no-unused-vars — the
    // no-unused-binding rule is the right surface for them.
    var r = try runLint(
        \\@group(0) @binding(0) var<uniform> u: f32;
        \\@compute @workgroup_size(1) fn main() {}
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    for (r.lint.diagnostics.items()) |d| {
        if (std.mem.eql(u8, d.code, "W0001") and std.mem.indexOf(u8, d.message, "'u'") != null) {
            dump("unexpected W0001 flag on external binding", r);
            return error.TestUnexpectedResult;
        }
    }
}

test "no-unused-vars: parameter is not flagged" {
    var r = try runLint("fn f(unused_param: f32) -> f32 { return 1.0; }", recommended_opts);
    defer r.deinit(std.testing.allocator);
    for (r.lint.diagnostics.items()) |d| {
        if (std.mem.indexOf(u8, d.message, "'unused_param'") != null) {
            dump("unexpected flag on parameter", r);
            return error.TestUnexpectedResult;
        }
    }
}

test "no-unused-vars: struct is not flagged" {
    // struct is .@"struct" kind, excluded from the rule's switch.
    var r = try runLint("struct S { x: f32 }", recommended_opts);
    defer r.deinit(std.testing.allocator);
    for (r.lint.diagnostics.items()) |d| {
        if (std.mem.indexOf(u8, d.message, "'S'") != null) {
            dump("unexpected flag on struct", r);
            return error.TestUnexpectedResult;
        }
    }
}

test "no-unused-vars: message contains quoted name" {
    var r = try runLint("fn lonely() {}", recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCodeContaining(r, "W0001", "'lonely'"));
    try std.testing.expect(hasCodeContaining(r, "W0001", "declared but never used"));
}

test "no-unused-vars: default severity is warning" {
    var r = try runLint("fn lonely() {}", recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasSeverity(r, "W0001", .warning));
}

test "no-unused-vars: source field is 'wgslender-lint'" {
    var r = try runLint("fn lonely() {}", recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r.lint.diagnostics.items().len >= 1);
    for (r.lint.diagnostics.items()) |d| {
        try std.testing.expectEqualStrings("wgslender-lint", d.source);
    }
}

test "no-unused-vars: position points at the declaration's name" {
    var r = try runLint("fn lonely() {}", recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r.lint.diagnostics.items().len >= 1);
    const d = r.lint.diagnostics.items()[0];
    try std.testing.expectEqual(@as(u32, 1), d.range.start.line);
    // "fn " is 3 chars → 1-based column 4
    try std.testing.expectEqual(@as(u32, 4), d.range.start.column);
}

test "no-unused-vars: multiple unused symbols each reported once" {
    var r = try runLint("fn a() {} fn b() {} fn c() {} const D: f32 = 1.0;", recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), countCode(r, "W0001"));
}

test "no-unused-vars: empty source has zero diagnostics" {
    var r = try runLint("", recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), r.lint.warning_count);
    try std.testing.expectEqual(@as(u32, 0), r.lint.error_count);
}

test "no-unused-vars: parse error does not crash linter" {
    var r = try runLint("fn { invalid", recommended_opts);
    defer r.deinit(std.testing.allocator);
    // Lint should degrade gracefully; validator reports the parse error.
    try std.testing.expect(r.analysis.diagnostics.errorCount() > 0);
}

// =========================================================================
// no-dead-code (W0002)
// =========================================================================

test "no-dead-code: function unreachable from entry point is flagged" {
    // `orphan` is called by `sibling`, but `sibling` is never called and
    // not an entry point, so the whole chain is dead relative to `main`.
    var r = try runLint(
        \\fn orphan() -> f32 { return 1.0; }
        \\fn sibling() -> f32 { return orphan(); }
        \\@vertex fn main() -> @builtin(position) vec4f { return vec4f(0.0); }
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    if (!hasCodeContaining(r, "W0002", "orphan")) {
        dump("no-dead-code: orphan not flagged", r);
        return error.TestUnexpectedResult;
    }
}

test "no-dead-code: reachable helper is not flagged" {
    var r = try runLint(
        \\fn helper() -> f32 { return 1.0; }
        \\@vertex fn main() -> @builtin(position) vec4f { return vec4f(helper()); }
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0002"));
}

test "no-dead-code: library mode (no entry points) emits nothing" {
    // DCE conservatively marks everything live in library mode.
    var r = try runLint(
        \\fn helper() -> f32 { return 1.0; }
        \\fn process() -> f32 { return helper(); }
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0002"));
}

test "no-dead-code: entry point itself is never flagged" {
    var r = try runLint(
        \\@vertex fn main() -> @builtin(position) vec4f { return vec4f(0.0); }
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0002"));
}

test "no-dead-code: never-referenced declarations belong to no-unused-vars, not this rule" {
    // `use_count == 0` → caught by no-unused-vars; no-dead-code skips them.
    var r = try runLint(
        \\fn totally_unused() {}
        \\@vertex fn main() -> @builtin(position) vec4f { return vec4f(0.0); }
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    // Exactly one W0001 (totally_unused), zero W0002.
    try std.testing.expect(hasCodeContaining(r, "W0001", "totally_unused"));
    for (r.lint.diagnostics.items()) |d| {
        if (std.mem.eql(u8, d.code, "W0002") and std.mem.indexOf(u8, d.message, "totally_unused") != null) {
            dump("unexpected W0002 on never-used symbol", r);
            return error.TestUnexpectedResult;
        }
    }
}

test "no-dead-code: source field stamped" {
    var r = try runLint(
        \\fn orphan() -> f32 { return 1.0; }
        \\fn sibling() -> f32 { return orphan(); }
        \\@vertex fn main() -> @builtin(position) vec4f { return vec4f(0.0); }
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    for (r.lint.diagnostics.items()) |d| {
        if (std.mem.eql(u8, d.code, "W0002")) {
            try std.testing.expectEqualStrings("wgslender-lint", d.source);
        }
    }
}

// =========================================================================
// no-unused-binding (W0003)
// =========================================================================

test "no-unused-binding: unused uniform is flagged" {
    var r = try runLint(
        \\@group(0) @binding(0) var<uniform> unused_buf: f32;
        \\@compute @workgroup_size(1)
        \\fn main() {}
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    if (!hasCodeContaining(r, "W0003", "unused_buf")) {
        dump("no-unused-binding: unused uniform not flagged", r);
        return error.TestUnexpectedResult;
    }
}

test "no-unused-binding: used uniform is not flagged" {
    var r = try runLint(
        \\@group(0) @binding(0) var<uniform> used_buf: f32;
        \\@compute @workgroup_size(1)
        \\fn main() { let x = used_buf; _ = x; }
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0003"));
}

test "no-unused-binding: unused storage is flagged" {
    var r = try runLint(
        \\@group(0) @binding(0) var<storage, read_write> unused_buf: array<f32>;
        \\@compute @workgroup_size(1)
        \\fn main() {}
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCodeContaining(r, "W0003", "unused_buf"));
}

test "no-unused-binding: textures are currently caught by no-unused-vars, not this rule" {
    // Limitation: the parser sets `is_external_binding` only on `var<uniform>`
    // and `var<storage>` declarations (Parser.zig:905), so textures and
    // samplers declared with `@group/@binding` fall through to the
    // no-unused-vars rule instead. Kept as a regression guard so a future
    // fix (detect `@group/@binding` attrs directly) is a visible, tested
    // change rather than a silent behavior drift.
    var r = try runLint(
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@compute @workgroup_size(1)
        \\fn main() {}
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0003"));
    try std.testing.expect(hasCodeContaining(r, "W0001", "tex"));
}

test "no-unused-binding: message mentions bind group layout slot" {
    var r = try runLint(
        \\@group(0) @binding(0) var<uniform> u: f32;
        \\@compute @workgroup_size(1)
        \\fn main() {}
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCodeContaining(r, "W0003", "bind group layout slot"));
}

test "no-unused-binding: does NOT fire on non-binding vars" {
    // `var<private>` is not a bind-group binding, so this rule should
    // ignore it entirely (no-unused-vars handles it if unused).
    var r = try runLint(
        \\var<private> pv: f32;
        \\@compute @workgroup_size(1)
        \\fn main() {}
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0003"));
}

test "no-unused-binding: multiple unused bindings each reported" {
    var r = try runLint(
        \\@group(0) @binding(0) var<uniform> a: f32;
        \\@group(0) @binding(1) var<uniform> b: f32;
        \\@group(0) @binding(2) var<uniform> c: f32;
        \\@compute @workgroup_size(1)
        \\fn main() {}
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), countCode(r, "W0003"));
}

// =========================================================================
// naming-convention (W0200)
// =========================================================================

const naming_opts = wgslender.Linter.Options{
    .rules = &.{.{ .id = "naming-convention", .severity = .warning }},
};

test "naming-convention: snake_case function fires warning" {
    var r = try runLint("fn snake_fn() -> f32 { return 1.0; }", naming_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCodeContaining(r, "W0200", "snake_fn"));
    try std.testing.expect(hasCodeContaining(r, "W0200", "camelCase"));
}

test "naming-convention: camelCase function passes" {
    var r = try runLint("fn goodName() -> f32 { return 1.0; }", naming_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0200"));
}

test "naming-convention: lowercase const fires (wants SCREAMING_SNAKE_CASE)" {
    var r = try runLint("const pi: f32 = 3.14;", naming_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCodeContaining(r, "W0200", "SCREAMING_SNAKE_CASE"));
}

test "naming-convention: SCREAMING_SNAKE const passes" {
    var r = try runLint("const PI: f32 = 3.14;", naming_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0200"));
}

test "naming-convention: lowercase struct fires (wants PascalCase)" {
    var r = try runLint("struct my_struct { x: f32 }", naming_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCodeContaining(r, "W0200", "my_struct"));
    try std.testing.expect(hasCodeContaining(r, "W0200", "PascalCase"));
}

test "naming-convention: PascalCase struct passes" {
    var r = try runLint("struct MyStruct { x: f32 }", naming_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0200"));
}

test "naming-convention: entry point is excluded" {
    var r = try runLint("@compute @workgroup_size(1) fn bad_name() {}", naming_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0200"));
}

test "naming-convention: external binding is excluded (api surface)" {
    var r = try runLint(
        \\@group(0) @binding(0) var<uniform> my_uniform: f32;
        \\@compute @workgroup_size(1) fn main() { let x = my_uniform; _ = x; }
    , naming_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0200"));
}

test "naming-convention: leading underscore opts out" {
    var r = try runLint("fn _helper() -> f32 { return 1.0; } fn main() -> f32 { return _helper(); }", naming_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0200"));
}

// =========================================================================
// require-entry-point-attrs (W0206)
// =========================================================================

const portability_opts = wgslender.Linter.Options{
    .extends = &.{"@wgslender/portability"},
};

test "require-entry-point-attrs: @compute without @workgroup_size is flagged" {
    var r = try runLint("@compute fn bad() {}", portability_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCodeContaining(r, "W0206", "missing @workgroup_size"));
}

test "require-entry-point-attrs: @compute with @workgroup_size passes" {
    var r = try runLint("@compute @workgroup_size(1) fn good() {}", portability_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0206"));
}

test "require-entry-point-attrs: @vertex without workgroup is not flagged" {
    var r = try runLint("@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0.0); }", portability_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0206"));
}

test "require-entry-point-attrs: default severity is error" {
    var r = try runLint("@compute fn bad() {}", portability_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasSeverity(r, "W0206", .@"error"));
}

// =========================================================================
// consistent-binding-annotations (W0208)
// =========================================================================

test "consistent-binding-annotations: uniform var missing @group and @binding" {
    // Parser requires both for a valid var, but let's at least exercise
    // one missing.
    var r = try runLint(
        \\@group(0) var<uniform> partial: f32;
        \\@compute @workgroup_size(1) fn main() { let x = partial; _ = x; }
    , portability_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCodeContaining(r, "W0208", "@binding"));
}

test "consistent-binding-annotations: missing @group" {
    var r = try runLint(
        \\@binding(0) var<uniform> partial: f32;
        \\@compute @workgroup_size(1) fn main() { let x = partial; _ = x; }
    , portability_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCodeContaining(r, "W0208", "@group"));
}

test "consistent-binding-annotations: complete binding passes" {
    var r = try runLint(
        \\@group(0) @binding(0) var<uniform> u: f32;
        \\@compute @workgroup_size(1) fn main() { let x = u; _ = x; }
    , portability_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0208"));
}

test "consistent-binding-annotations: non-resource var ignored" {
    var r = try runLint(
        \\var<private> pv: f32;
        \\@compute @workgroup_size(1) fn main() { pv = 1.0; }
    , portability_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0208"));
}

// =========================================================================
// no-magic-numbers (W0202)
// =========================================================================

const magic_opts = wgslender.Linter.Options{
    .rules = &.{.{ .id = "no-magic-numbers", .severity = .warning }},
};

test "no-magic-numbers: plain literal in expression is flagged" {
    var r = try runLint("fn f() -> f32 { return 3.14; }", magic_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCodeContaining(r, "W0202", "3.14"));
}

test "no-magic-numbers: allowlisted 0/1/2 pass" {
    var r = try runLint("fn f() -> f32 { return 0.0 + 1.0 * 2.0; }", magic_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0202"));
}

test "no-magic-numbers: integer 42 is flagged" {
    var r = try runLint("fn f() -> i32 { return 42; }", magic_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCodeContaining(r, "W0202", "42"));
}

test "no-magic-numbers: u32 literal 255 is flagged" {
    var r = try runLint("fn f() -> u32 { return 255u; }", magic_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCodeContaining(r, "W0202", "255"));
}

test "no-magic-numbers: inside const declaration is skipped" {
    var r = try runLint("const PI: f32 = 3.14159;", magic_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0202"));
}

test "no-magic-numbers: switch selectors exempt (pattern literals)" {
    var r = try runLint(
        \\fn f(x: i32) -> i32 {
        \\  switch x {
        \\    case 42: { return 0; }
        \\    default: { return 1; }
        \\  }
        \\}
    , magic_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0202"));
}

// =========================================================================
// no-large-local-arrays (W0204)
// =========================================================================

const large_array_opts = wgslender.Linter.Options{
    .rules = &.{.{ .id = "no-large-local-arrays", .severity = .warning }},
};

test "no-large-local-arrays: large local array is flagged" {
    var r = try runLint("fn f() { var big: array<f32, 2048>; _ = big[0]; }", large_array_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCodeContaining(r, "W0204", "big"));
    try std.testing.expect(hasCodeContaining(r, "W0204", "2048"));
}

test "no-large-local-arrays: small local array is not flagged" {
    var r = try runLint("fn f() { var small: array<f32, 16>; _ = small[0]; }", large_array_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0204"));
}

test "no-large-local-arrays: threshold boundary (1024 passes)" {
    var r = try runLint("fn f() { var b: array<f32, 1024>; _ = b[0]; }", large_array_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0204"));
}

test "no-large-local-arrays: module-scope arrays are not flagged" {
    var r = try runLint("var<workgroup> shared: array<f32, 65536>;\n@compute @workgroup_size(1) fn main() { shared[0] = 1.0; }", large_array_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0204"));
}

test "no-large-local-arrays: named size (const expr) is not flagged" {
    // Without const-expr evaluation we can't determine the size, so we
    // intentionally skip. Documented behavior.
    var r = try runLint("const N: u32 = 4096;\nfn f() { var a: array<f32, N>; _ = a[0]; }", large_array_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0204"));
}

test "no-large-local-arrays: configurable maxSize option" {
    // Options parse through the rule's own readThreshold. We need to pass
    // a JSON value; build one with std.json.
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"maxSize\":256}", .{});
    defer parsed.deinit();

    var r = try runLint("fn f() { var a: array<f32, 512>; _ = a[0]; }", .{
        .rules = &.{.{
            .id = "no-large-local-arrays",
            .severity = .warning,
            .options = parsed.value,
        }},
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCodeContaining(r, "W0204", "512"));
}

// =========================================================================
// no-unreachable (W0210)
// =========================================================================

test "no-unreachable: statement after return is flagged" {
    var r = try runLint(
        \\fn f() -> i32 {
        \\  return 1;
        \\  let dead = 2;
        \\  return dead;
        \\}
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCode(r, "W0210"));
}

test "no-unreachable: statement after discard is flagged" {
    var r = try runLint(
        \\@fragment fn fs() -> @location(0) vec4f {
        \\  discard;
        \\  return vec4f(0.0);
        \\}
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCode(r, "W0210"));
}

test "no-unreachable: break inside loop flags following stmts" {
    var r = try runLint(
        \\fn f() {
        \\  loop {
        \\    break;
        \\    let x = 1;
        \\  }
        \\}
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCode(r, "W0210"));
}

test "no-unreachable: conditional return is NOT flagged" {
    // The return is inside an `if`, so code after the `if` is reachable
    // via the else-not-taken path.
    var r = try runLint(
        \\fn f(x: i32) -> i32 {
        \\  if (x > 0) { return 1; }
        \\  return 2;
        \\}
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0210"));
}

test "no-unreachable: last return in function is not flagged" {
    var r = try runLint("fn f() -> i32 { return 1; }", recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0210"));
}

// =========================================================================
// no-constant-condition (W0211)
// =========================================================================

test "no-constant-condition: if (true) is flagged" {
    var r = try runLint("fn f() -> i32 { if (true) { return 1; } return 0; }", recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCode(r, "W0211"));
}

test "no-constant-condition: while (false) is flagged" {
    var r = try runLint("fn f() { while (false) { } }", recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCode(r, "W0211"));
}

test "no-constant-condition: variable condition is not flagged" {
    var r = try runLint("fn f(b: bool) -> i32 { if (b) { return 1; } return 0; }", recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0211"));
}

// =========================================================================
// for-direction (W0212)
// =========================================================================

test "for-direction: up comparator with decrement is flagged" {
    var r = try runLint(
        \\fn f() {
        \\  for (var i = 0; i < 10; i--) { }
        \\}
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCode(r, "W0212"));
}

test "for-direction: down comparator with increment is flagged" {
    var r = try runLint(
        \\fn f() {
        \\  for (var i = 10; i > 0; i++) { }
        \\}
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCode(r, "W0212"));
}

test "for-direction: correctly-oriented up-loop is fine" {
    var r = try runLint(
        \\fn f() {
        \\  for (var i = 0; i < 10; i++) { }
        \\}
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0212"));
}

test "for-direction: correctly-oriented down-loop is fine" {
    var r = try runLint(
        \\fn f() {
        \\  for (var i = 10; i >= 0; i--) { }
        \\}
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0212"));
}

// =========================================================================
// no-duplicate-case (W0213)
// =========================================================================

test "no-duplicate-case: duplicate integer selector is flagged" {
    var r = try runLint(
        \\fn f(x: i32) -> i32 {
        \\  switch x {
        \\    case 1: { return 1; }
        \\    case 1: { return 2; }
        \\    default: { return 0; }
        \\  }
        \\}
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCode(r, "W0213"));
}

test "no-duplicate-case: 42 and 42u collide" {
    var r = try runLint(
        \\fn f(x: u32) -> u32 {
        \\  switch x {
        \\    case 42: { return 1u; }
        \\    case 42u: { return 2u; }
        \\    default: { return 0u; }
        \\  }
        \\}
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCode(r, "W0213"));
}

test "no-duplicate-case: distinct selectors are fine" {
    var r = try runLint(
        \\fn f(x: i32) -> i32 {
        \\  switch x {
        \\    case 1: { return 1; }
        \\    case 2: { return 2; }
        \\    default: { return 0; }
        \\  }
        \\}
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0213"));
}

// =========================================================================
// no-self-assign (W0214)
// =========================================================================

test "no-self-assign: x = x is flagged" {
    var r = try runLint(
        \\fn f() {
        \\  var x: i32 = 1;
        \\  x = x;
        \\}
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCode(r, "W0214"));
}

test "no-self-assign: member self-assign is flagged" {
    var r = try runLint(
        \\fn f() {
        \\  var v: vec2f = vec2f(1.0);
        \\  v.x = v.x;
        \\}
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCode(r, "W0214"));
}

test "no-self-assign: compound assign not flagged" {
    var r = try runLint(
        \\fn f() {
        \\  var x: i32 = 1;
        \\  x += x;
        \\}
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0214"));
}

test "no-self-assign: assign different variables is fine" {
    var r = try runLint(
        \\fn f() {
        \\  var x: i32 = 1;
        \\  var y: i32 = 2;
        \\  x = y;
        \\}
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0214"));
}

test "no-self-assign: attaches autofix that deletes the statement" {
    var r = try runLint(
        \\fn f() {
        \\  var x: i32 = 1;
        \\  x = x;
        \\}
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    var found = false;
    for (r.lint.diagnostics.items()) |d| {
        if (std.mem.eql(u8, d.code, "W0214")) {
            try std.testing.expect(d.fix != null);
            found = true;
        }
    }
    try std.testing.expect(found);
}

// =========================================================================
// Config packs
// =========================================================================

test "configs: @wgslender/style includes naming-convention" {
    const cfg = wgslender.Linter.Configs.byName("@wgslender/style").?;
    var found = false;
    for (cfg.rules) |r| {
        if (std.mem.eql(u8, r.id, "naming-convention")) found = true;
    }
    try std.testing.expect(found);
}

test "configs: @wgslender/strict elevates core rules to error" {
    const cfg = wgslender.Linter.Configs.byName("@wgslender/strict").?;
    for (cfg.rules) |r| {
        if (std.mem.eql(u8, r.id, "no-unused-vars")) {
            try std.testing.expectEqual(Severity.@"error", r.severity);
        }
    }
}

// =========================================================================
// wgslender-disable directives
// =========================================================================

test "disable-next-line silences diagnostic on the following line" {
    var r = try runLint(
        \\// wgslender-disable-next-line no-unused-vars
        \\fn unused_fn() {}
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0001"));
}

test "disable-next-line does not silence two lines below" {
    var r = try runLint(
        \\// wgslender-disable-next-line no-unused-vars
        \\
        \\fn unused_fn() {}
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCodeContaining(r, "W0001", "unused_fn"));
}

test "disable-line silences diagnostic on same line (trailing comment)" {
    var r = try runLint(
        \\fn unused_fn() {} // wgslender-disable-line no-unused-vars
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0001"));
}

test "disable-file silences the rule across the whole file" {
    var r = try runLint(
        \\// wgslender-disable-file no-unused-vars
        \\fn a() {}
        \\fn b() {}
        \\fn c() {}
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0001"));
}

test "disable/enable block silences between markers" {
    var r = try runLint(
        \\/* wgslender-disable no-unused-vars */
        \\fn inside1() {}
        \\fn inside2() {}
        \\/* wgslender-enable no-unused-vars */
        \\fn outside() {}
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCodeContaining(r, "W0001", "outside"));
    // inside1 / inside2 both silenced
    for (r.lint.diagnostics.items()) |d| {
        if (std.mem.indexOf(u8, d.message, "inside1") != null or
            std.mem.indexOf(u8, d.message, "inside2") != null)
        {
            dump("unexpected diag inside disable range", r);
            return error.TestUnexpectedResult;
        }
    }
}

test "disable without rule id silences everything" {
    var r = try runLint(
        \\// wgslender-disable-next-line
        \\fn unused_fn() {}
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0001"));
}

test "disable with multiple rules on comma-separated list" {
    var r = try runLint(
        \\// wgslender-disable-next-line no-unused-vars, no-unused-binding
        \\fn unused_fn() {}
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0001"));
}

test "disable does not silence validator diagnostics" {
    // Validator E-codes flow through untouched.
    var r = try runLint(
        \\// wgslender-disable-file no-unused-vars
        \\fn main() { let x = undeclared_symbol; }
    , recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r.analysis.diagnostics.errorCount() > 0);
}

test "report-unused-disable-directives flags dead directives" {
    var r = try runLint(
        \\// wgslender-disable-next-line no-unused-vars
        \\@compute @workgroup_size(1) fn main() {}
    , .{
        .extends = &.{"@wgslender/recommended"},
        .report_unused_disable_directives = true,
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCode(r, "W0209"));
}

test "report-unused-disable-directives does not fire on used directives" {
    var r = try runLint(
        \\// wgslender-disable-next-line no-unused-vars
        \\fn lonely() {}
    , .{
        .extends = &.{"@wgslender/recommended"},
        .report_unused_disable_directives = true,
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0209"));
}

// =========================================================================
// Fixer public API
// =========================================================================

test "Fixer: exposed via wgslender.Linter.Fixer" {
    // Quick smoke — just ensures the module is reachable from the public
    // surface. Full behavior tested in src/lint/Fixer.zig.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const r = try wgslender.Linter.Fixer.apply(arena_state.allocator(), "hello", &.{});
    try std.testing.expectEqualStrings("hello", r.fixed);
}

// =========================================================================
// Cross-rule interactions
// =========================================================================

test "rules: severity override to error for no-dead-code" {
    var r = try runLint(
        \\fn orphan() -> f32 { return 1.0; }
        \\fn sibling() -> f32 { return orphan(); }
        \\@vertex fn main() -> @builtin(position) vec4f { return vec4f(0.0); }
    , .{
        .extends = &.{"@wgslender/recommended"},
        .rules = &.{.{ .id = "no-dead-code", .severity = .@"error" }},
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasSeverity(r, "W0002", .@"error"));
}

test "rules: disable one rule in a pack" {
    // Disable no-dead-code but keep no-unused-vars + no-unused-binding.
    var r = try runLint(
        \\@group(0) @binding(0) var<uniform> unused_buf: f32;
        \\fn unused_fn() {}
        \\@compute @workgroup_size(1) fn main() {}
    , .{
        .extends = &.{"@wgslender/recommended"},
        .rules = &.{.{ .id = "no-dead-code", .severity = .disabled }},
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCode(r, "W0001")); // unused_fn
    try std.testing.expect(hasCode(r, "W0003")); // unused_buf
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0002"));
}

// =========================================================================
// Linter infrastructure
// =========================================================================

test "Linter: default (no extends) produces zero diagnostics" {
    var r = try runLint("fn lonely() {}", .{});
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), r.lint.warning_count);
    try std.testing.expectEqual(@as(u32, 0), r.lint.error_count);
}

test "Linter: severity override to error flips code severity" {
    var r = try runLint("fn lonely() {}", .{
        .rules = &.{.{ .id = "no-unused-vars", .severity = .@"error" }},
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasSeverity(r, "W0001", .@"error"));
    try std.testing.expect(r.lint.error_count >= 1);
    try std.testing.expectEqual(@as(u32, 0), r.lint.warning_count);
}

test "Linter: severity override to off silences extended pack" {
    var r = try runLint("fn lonely() {}", .{
        .extends = &.{"@wgslender/recommended"},
        .rules = &.{.{ .id = "no-unused-vars", .severity = .disabled }},
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countCode(r, "W0001"));
}

test "Linter: disabled flag short-circuits every rule" {
    var r = try runLint("fn lonely() {}", .{
        .extends = &.{"@wgslender/recommended"},
        .disabled = true,
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), r.lint.warning_count);
    try std.testing.expectEqual(@as(u32, 0), r.lint.error_count);
}

test "Linter: unknown extends name is silently ignored" {
    var r = try runLint("fn lonely() {}", .{
        .extends = &.{ "@wgslender/does-not-exist", "@wgslender/recommended" },
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCode(r, "W0001"));
}

test "Linter: unknown rule id is silently ignored" {
    var r = try runLint("fn lonely() {}", .{
        .rules = &.{
            .{ .id = "no-such-rule", .severity = .@"error" },
            .{ .id = "no-unused-vars", .severity = .warning },
        },
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCode(r, "W0001"));
}

test "Linter: later rules override earlier settings" {
    // user rules take precedence over extends; verify that ordering works
    var r = try runLint("fn lonely() {}", .{
        .extends = &.{"@wgslender/recommended"},
        .rules = &.{
            .{ .id = "no-unused-vars", .severity = .@"error" },
        },
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasSeverity(r, "W0001", .@"error"));
    // should not also produce a warning of the same code
    try std.testing.expect(!hasSeverity(r, "W0001", .warning));
}

test "Linter: repeated runs do not accumulate" {
    const src: [:0]const u8 = "fn lonely() {}";
    for (0..5) |_| {
        var r = try runLint(src, recommended_opts);
        r.deinit(std.testing.allocator);
    }
}

test "Linter: OOM propagates" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const result = wgslender.lint(failing.allocator(), "fn lonely() {}", recommended_opts);
    try std.testing.expect(result == error.OutOfMemory);
}

test "Linter: line_offset shifts reported positions" {
    var r = try runLint("fn lonely() {}", .{
        .extends = &.{"@wgslender/recommended"},
        .line_offset = 10,
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r.lint.diagnostics.items().len >= 1);
    const d = r.lint.diagnostics.items()[0];
    try std.testing.expectEqual(@as(u32, 11), d.range.start.line);
}

// =========================================================================
// Registry / configs lookup
// =========================================================================

test "registry: byId finds registered rules" {
    try std.testing.expect(wgslender.Linter.registry.byId("no-unused-vars") != null);
    try std.testing.expect(wgslender.Linter.registry.byId("nope") == null);
}

test "registry: byCode finds rules by their diagnostic code" {
    try std.testing.expect(wgslender.Linter.registry.byCode("W0001") != null);
    try std.testing.expect(wgslender.Linter.registry.byCode("X9999") == null);
}

test "configs: built-in packs resolve by name" {
    try std.testing.expect(wgslender.Linter.Configs.byName("@wgslender/recommended") != null);
    try std.testing.expect(wgslender.Linter.Configs.byName("@wgslender/performance") != null);
    try std.testing.expect(wgslender.Linter.Configs.byName("@wgslender/portability") != null);
    try std.testing.expect(wgslender.Linter.Configs.byName("@nope/nope") == null);
}

// =========================================================================
// Diagnostic.Entry serialization changes
// =========================================================================

test "entryToJson: source field appears in JSON" {
    var r = try runLint("fn lonely() {}", recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r.lint.diagnostics.items().len >= 1);
    const d = r.lint.diagnostics.items()[0];

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try wgslender.Diagnostic.entryToJson(&buf, std.testing.allocator, &d);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"source\":\"wgslender-lint\"") != null);
}

test "entryToJson: fix field appears when set" {
    const Entry = wgslender.Diagnostic.Entry;
    const fix = wgslender.Diagnostic.Fix{
        .range = .{
            .start = .{ .offset = 0, .line = 1, .column = 1 },
            .end = .{ .offset = 5, .line = 1, .column = 6 },
        },
        .text = "repl",
    };
    const entry = Entry{
        .severity = .warning,
        .code = "W9999",
        .message = "test",
        .fix = &fix,
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try wgslender.Diagnostic.entryToJson(&buf, std.testing.allocator, &entry);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"fix\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"text\":\"repl\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"startOffset\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"endOffset\":5") != null);
}

test "entryToJson: fix field absent when unset" {
    const entry = wgslender.Diagnostic.Entry{
        .severity = .warning,
        .code = "W9999",
        .message = "test",
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try wgslender.Diagnostic.entryToJson(&buf, std.testing.allocator, &entry);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"fix\":") == null);
}

// =========================================================================
// End-to-end: wgslender.lint() public API deinit contract
// =========================================================================

test "lint: public API frees all memory on clean run" {
    var r = try wgslender.lint(std.testing.allocator, "fn lonely() {}", recommended_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r.lint.warning_count >= 1);
}

test "lint: public API frees all memory on parse failure" {
    var r = try wgslender.lint(std.testing.allocator, "fn { invalid", recommended_opts);
    defer r.deinit(std.testing.allocator);
    // Parse error is on the analysis side
    try std.testing.expect(r.analysis.diagnostics.errorCount() > 0);
}

test "lint: public API repeated calls no accumulation" {
    for (0..10) |_| {
        var r = try wgslender.lint(std.testing.allocator, "fn lonely() {}", recommended_opts);
        r.deinit(std.testing.allocator);
    }
}
