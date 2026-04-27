//! Phase 5a — Minify-mode lint rules.
//!
//! Three anchor rules that exercise the existing `src/lint/` framework
//! against minification-relevant symbol-table state:
//!
//!   - `M0100` `minify/external-binding-blocks-rename` — fires on every
//!     `@group/@binding` symbol; the long original name will leak through
//!     unless `--mangle-external-bindings` is set.
//!   - `M0201` `minify/unused-const` — fires on `.const` decls with
//!     `use_count == 0`; the const will be dropped by DCE so its bytes
//!     are wasted on disk.
//!   - `M0202` `minify/unused-override` — same shape on `.override`
//!     decls.
//!
//! Each rule's default severity is `.hint`. The shared `@wgslender/minify`
//! pack lists all three at default severity so a single `extends` entry
//! is enough to opt in.

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

fn firstWithCode(result: wgslender.LintResult, code: []const u8) ?wgslender.Diagnostic.Entry {
    for (result.lint.diagnostics.items()) |d| {
        if (std.mem.eql(u8, d.code, code)) return d;
    }
    return null;
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

const minify_opts = wgslender.Linter.Options{
    .extends = &.{"@wgslender/minify"},
};

// =========================================================================
// minify/unused-const (M0201)
// =========================================================================

test "minify/unused-const: positive — never-referenced const fires" {
    var r = try runLint("const UNUSED_K: f32 = 3.14;", minify_opts);
    defer r.deinit(std.testing.allocator);
    if (!hasCodeContaining(r, "M0201", "UNUSED_K")) {
        dump("expected M0201 on UNUSED_K", r);
        return error.TestUnexpectedResult;
    }
}

test "minify/unused-const: negative — referenced const is silent" {
    const src: [:0]const u8 =
        \\const KEPT: f32 = 3.14;
        \\@compute @workgroup_size(1) fn main() { let _v = KEPT; }
    ;
    var r = try runLint(src, minify_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(!hasCode(r, "M0201"));
}

test "minify/unused-const: negative — unused override does not fire M0201" {
    var r = try runLint("@id(0) override UNUSED_OVR: u32 = 8;", minify_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(!hasCode(r, "M0201"));
}

test "minify/unused-const: range covers the decl name span" {
    var r = try runLint("const FOO: f32 = 3.14;", minify_opts);
    defer r.deinit(std.testing.allocator);
    const d = firstWithCode(r, "M0201") orelse {
        dump("no M0201 emitted", r);
        return error.TestUnexpectedResult;
    };
    // Source: `const FOO: f32 = 3.14;` — name starts at col 7, ends at col 10.
    try std.testing.expectEqual(@as(u32, 1), d.range.start.line);
    try std.testing.expectEqual(@as(u32, 7), d.range.start.column);
    try std.testing.expectEqual(@as(u32, 10), d.range.end.column);
}

test "minify/unused-const: default severity is hint" {
    var r = try runLint("const UNUSED_K: f32 = 3.14;", minify_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasSeverity(r, "M0201", .hint));
}

test "minify/unused-const: per-rule override escalates to warning" {
    var r = try runLint("const UNUSED_K: f32 = 3.14;", .{
        .extends = &.{"@wgslender/minify"},
        .rules = &.{
            .{ .id = "minify/unused-const", .severity = .warning },
        },
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasSeverity(r, "M0201", .warning));
}

test "minify/unused-const: spec_ref points at minify slug" {
    var r = try runLint("const UNUSED_K: f32 = 3.14;", minify_opts);
    defer r.deinit(std.testing.allocator);
    const d = firstWithCode(r, "M0201") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("minify", d.spec_ref);
}

// =========================================================================
// minify/unused-override (M0202)
// =========================================================================

test "minify/unused-override: positive — never-referenced override fires" {
    var r = try runLint("@id(0) override UNUSED_OVR: u32 = 8;", minify_opts);
    defer r.deinit(std.testing.allocator);
    if (!hasCodeContaining(r, "M0202", "UNUSED_OVR")) {
        dump("expected M0202 on UNUSED_OVR", r);
        return error.TestUnexpectedResult;
    }
}

test "minify/unused-override: negative — referenced override is silent" {
    // Attribute arguments don't bind references in our AstVisit pass,
    // so the override has to be read from inside a function body for
    // `use_count` to climb above zero.
    const src: [:0]const u8 =
        \\@id(0) override KEPT_OVR: u32 = 8;
        \\@compute @workgroup_size(1) fn main() { let _v = KEPT_OVR; }
    ;
    var r = try runLint(src, minify_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(!hasCode(r, "M0202"));
}

test "minify/unused-override: negative — unused const does not fire M0202" {
    var r = try runLint("const UNUSED_K: f32 = 3.14;", minify_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(!hasCode(r, "M0202"));
}

test "minify/unused-override: range covers the decl name span" {
    var r = try runLint("override BAR: u32 = 8;", minify_opts);
    defer r.deinit(std.testing.allocator);
    const d = firstWithCode(r, "M0202") orelse {
        dump("no M0202 emitted", r);
        return error.TestUnexpectedResult;
    };
    // Source: `override BAR: u32 = 8;` — name starts at col 10, ends at col 13.
    try std.testing.expectEqual(@as(u32, 1), d.range.start.line);
    try std.testing.expectEqual(@as(u32, 10), d.range.start.column);
    try std.testing.expectEqual(@as(u32, 13), d.range.end.column);
}

test "minify/unused-override: default severity is hint" {
    var r = try runLint("@id(0) override UNUSED_OVR: u32 = 8;", minify_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasSeverity(r, "M0202", .hint));
}

test "minify/unused-override: per-rule override escalates to warning" {
    var r = try runLint("@id(0) override UNUSED_OVR: u32 = 8;", .{
        .extends = &.{"@wgslender/minify"},
        .rules = &.{
            .{ .id = "minify/unused-override", .severity = .warning },
        },
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasSeverity(r, "M0202", .warning));
}

test "minify/unused-override: spec_ref points at minify slug" {
    var r = try runLint("@id(0) override UNUSED_OVR: u32 = 8;", minify_opts);
    defer r.deinit(std.testing.allocator);
    const d = firstWithCode(r, "M0202") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("minify", d.spec_ref);
}

// =========================================================================
// minify/external-binding-blocks-rename (M0100)
// =========================================================================

test "minify/external-binding-blocks-rename: positive — used binding fires" {
    const src: [:0]const u8 =
        \\@group(0) @binding(0) var<uniform> uniforms: f32;
        \\@compute @workgroup_size(1) fn main() { let _v = uniforms; }
    ;
    var r = try runLint(src, minify_opts);
    defer r.deinit(std.testing.allocator);
    if (!hasCodeContaining(r, "M0100", "uniforms")) {
        dump("expected M0100 on uniforms", r);
        return error.TestUnexpectedResult;
    }
}

test "minify/external-binding-blocks-rename: positive — unused binding still fires" {
    // The rule is about the binding *blocking* the renamer, not whether
    // it's referenced. Even an unused binding leaks its long name unless
    // the user runs --mangle-external-bindings.
    const src: [:0]const u8 = "@group(0) @binding(0) var<uniform> uniforms: f32;";
    var r = try runLint(src, minify_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCode(r, "M0100"));
}

test "minify/external-binding-blocks-rename: negative — non-binding decl is silent" {
    const src: [:0]const u8 =
        \\const PI: f32 = 3.14;
        \\@compute @workgroup_size(1) fn main() { let _v = PI; }
    ;
    var r = try runLint(src, minify_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(!hasCode(r, "M0100"));
}

test "minify/external-binding-blocks-rename: range covers the binding name span" {
    const src: [:0]const u8 = "@group(0) @binding(0) var<uniform> uniforms: f32;";
    var r = try runLint(src, minify_opts);
    defer r.deinit(std.testing.allocator);
    const d = firstWithCode(r, "M0100") orelse {
        dump("no M0100 emitted", r);
        return error.TestUnexpectedResult;
    };
    // `@group(0) @binding(0) var<uniform> uniforms: f32;` —
    // `uniforms` starts at col 36 (1-based), length 8 → end col 44.
    try std.testing.expectEqual(@as(u32, 1), d.range.start.line);
    try std.testing.expectEqual(@as(u32, 36), d.range.start.column);
    try std.testing.expectEqual(@as(u32, 44), d.range.end.column);
}

test "minify/external-binding-blocks-rename: default severity is hint" {
    const src: [:0]const u8 = "@group(0) @binding(0) var<uniform> uniforms: f32;";
    var r = try runLint(src, minify_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasSeverity(r, "M0100", .hint));
}

test "minify/external-binding-blocks-rename: per-rule override escalates to warning" {
    const src: [:0]const u8 = "@group(0) @binding(0) var<uniform> uniforms: f32;";
    var r = try runLint(src, .{
        .extends = &.{"@wgslender/minify"},
        .rules = &.{
            .{ .id = "minify/external-binding-blocks-rename", .severity = .warning },
        },
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasSeverity(r, "M0100", .warning));
}

test "minify/external-binding-blocks-rename: spec_ref points at minify slug" {
    const src: [:0]const u8 = "@group(0) @binding(0) var<uniform> uniforms: f32;";
    var r = try runLint(src, minify_opts);
    defer r.deinit(std.testing.allocator);
    const d = firstWithCode(r, "M0100") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("minify", d.spec_ref);
}

// =========================================================================
// Pack-level integration
// =========================================================================

test "@wgslender/minify pack enables all three anchor rules" {
    const src: [:0]const u8 =
        \\const UNUSED_K: f32 = 3.14;
        \\@id(0) override UNUSED_OVR: u32 = 8;
        \\@group(0) @binding(0) var<uniform> uniforms: f32;
    ;
    var r = try runLint(src, minify_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCode(r, "M0100"));
    try std.testing.expect(hasCode(r, "M0201"));
    try std.testing.expect(hasCode(r, "M0202"));
}

test "@wgslender/minify pack does not fire when source is clean" {
    const src: [:0]const u8 =
        \\const KEPT: f32 = 3.14;
        \\@compute @workgroup_size(1) fn main() { let _v = KEPT; }
    ;
    var r = try runLint(src, minify_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(!hasCode(r, "M0100"));
    try std.testing.expect(!hasCode(r, "M0201"));
    try std.testing.expect(!hasCode(r, "M0202"));
}

test "@wgslender/minify rules carry source = wgslender-lint" {
    var r = try runLint("const UNUSED_K: f32 = 3.14;", minify_opts);
    defer r.deinit(std.testing.allocator);
    const d = firstWithCode(r, "M0201") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("wgslender-lint", d.source);
}

// =========================================================================
// wgslender-disable directive interaction (free via Linter framework)
// =========================================================================

test "wgslender-disable-next-line minify/unused-const silences M0201" {
    const src: [:0]const u8 =
        \\// wgslender-disable-next-line minify/unused-const
        \\const UNUSED_K: f32 = 3.14;
    ;
    var r = try runLint(src, minify_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(!hasCode(r, "M0201"));
}

test "wgslender-disable-file minify/external-binding-blocks-rename silences M0100" {
    const src: [:0]const u8 =
        \\// wgslender-disable minify/external-binding-blocks-rename
        \\@group(0) @binding(0) var<uniform> uniforms: f32;
    ;
    var r = try runLint(src, minify_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(!hasCode(r, "M0100"));
}

// =========================================================================
// minify/dead-code-kept (M0200) — Phase 5b
// =========================================================================
//
// Mirrors `no-dead-code` (W0002) shape but at hint severity inside the
// minify pack. Fires on symbols with `is_live = false` after DCE that are
// still referenced (`use_count > 0`) — i.e., reachable from another decl
// that's also dead. Library mode (no entry points) silences the rule
// because DCE conservatively marks every symbol live.

test "minify/dead-code-kept: positive — referenced-only-from-dead fires" {
    // `orphan` is called by `sibling`, but `sibling` is never called from
    // the entry point — so both end up `is_live = false`, but `orphan`'s
    // `use_count > 0` distinguishes it from a never-referenced decl.
    const src: [:0]const u8 =
        \\fn orphan() -> f32 { return 1.0; }
        \\fn sibling() -> f32 { return orphan(); }
        \\@vertex fn main() -> @builtin(position) vec4f { return vec4f(0.0); }
    ;
    var r = try runLint(src, minify_opts);
    defer r.deinit(std.testing.allocator);
    if (!hasCodeContaining(r, "M0200", "orphan")) {
        dump("expected M0200 on orphan", r);
        return error.TestUnexpectedResult;
    }
}

test "minify/dead-code-kept: negative — reachable helper is silent" {
    const src: [:0]const u8 =
        \\fn helper() -> f32 { return 1.0; }
        \\@vertex fn main() -> @builtin(position) vec4f { return vec4f(helper()); }
    ;
    var r = try runLint(src, minify_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(!hasCode(r, "M0200"));
}

test "minify/dead-code-kept: negative — never-referenced decl is silent (W0001 territory)" {
    // `use_count == 0` belongs to `no-unused-vars` / `minify/unused-const`;
    // M0200 only flags decls that other dead code keeps alive.
    const src: [:0]const u8 =
        \\fn totally_unused() {}
        \\@vertex fn main() -> @builtin(position) vec4f { return vec4f(0.0); }
    ;
    var r = try runLint(src, minify_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(!hasCode(r, "M0200"));
}

test "minify/dead-code-kept: negative — library mode silences" {
    // No entry points → DCE marks everything live conservatively, so
    // there's no "dead" set against which to flag.
    const src: [:0]const u8 =
        \\fn helper() -> f32 { return 1.0; }
        \\fn process() -> f32 { return helper(); }
    ;
    var r = try runLint(src, minify_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(!hasCode(r, "M0200"));
}

test "minify/dead-code-kept: negative — entry point itself is never flagged" {
    const src: [:0]const u8 =
        \\@vertex fn main() -> @builtin(position) vec4f { return vec4f(0.0); }
    ;
    var r = try runLint(src, minify_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(!hasCode(r, "M0200"));
}

test "minify/dead-code-kept: range covers the decl name span" {
    const src: [:0]const u8 =
        \\fn orphan() -> f32 { return 1.0; }
        \\fn sibling() -> f32 { return orphan(); }
        \\@vertex fn main() -> @builtin(position) vec4f { return vec4f(0.0); }
    ;
    var r = try runLint(src, minify_opts);
    defer r.deinit(std.testing.allocator);
    const d = firstWithCode(r, "M0200") orelse {
        dump("no M0200 emitted", r);
        return error.TestUnexpectedResult;
    };
    // `fn orphan() ...` — `orphan` starts at col 4, length 6 → ends at col 10.
    try std.testing.expectEqual(@as(u32, 1), d.range.start.line);
    try std.testing.expectEqual(@as(u32, 4), d.range.start.column);
    try std.testing.expectEqual(@as(u32, 10), d.range.end.column);
}

test "minify/dead-code-kept: default severity is hint" {
    const src: [:0]const u8 =
        \\fn orphan() -> f32 { return 1.0; }
        \\fn sibling() -> f32 { return orphan(); }
        \\@vertex fn main() -> @builtin(position) vec4f { return vec4f(0.0); }
    ;
    var r = try runLint(src, minify_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasSeverity(r, "M0200", .hint));
}

test "minify/dead-code-kept: per-rule override escalates to warning" {
    const src: [:0]const u8 =
        \\fn orphan() -> f32 { return 1.0; }
        \\fn sibling() -> f32 { return orphan(); }
        \\@vertex fn main() -> @builtin(position) vec4f { return vec4f(0.0); }
    ;
    var r = try runLint(src, .{
        .extends = &.{"@wgslender/minify"},
        .rules = &.{
            .{ .id = "minify/dead-code-kept", .severity = .warning },
        },
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasSeverity(r, "M0200", .warning));
}

test "minify/dead-code-kept: spec_ref points at minify slug" {
    const src: [:0]const u8 =
        \\fn orphan() -> f32 { return 1.0; }
        \\fn sibling() -> f32 { return orphan(); }
        \\@vertex fn main() -> @builtin(position) vec4f { return vec4f(0.0); }
    ;
    var r = try runLint(src, minify_opts);
    defer r.deinit(std.testing.allocator);
    const d = firstWithCode(r, "M0200") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("minify", d.spec_ref);
}

test "@wgslender/minify pack enables M0200" {
    const src: [:0]const u8 =
        \\fn orphan() -> f32 { return 1.0; }
        \\fn sibling() -> f32 { return orphan(); }
        \\@vertex fn main() -> @builtin(position) vec4f { return vec4f(0.0); }
    ;
    var r = try runLint(src, minify_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCode(r, "M0200"));
}

// =========================================================================
// minify/long-entry-point-name (M0101) — Phase 5b
// =========================================================================
//
// Entry-point function names ship verbatim to the host (the JS / wgpu API
// looks them up by name), so any character above the configured threshold
// is shipping bytes the renamer can't recover. Default threshold is 8 —
// `main`, `frag`, `vertex` all pass; `computePassMain` does not.
//
// Configurable via the standard `Linter.RuleOverride.options` shape:
// `["warn", { "max": 4 }]` flips the threshold to 4 chars.

test "minify/long-entry-point-name: positive — long entry name fires" {
    const src: [:0]const u8 =
        \\@compute @workgroup_size(1) fn computeKernelMain() {}
    ;
    var r = try runLint(src, minify_opts);
    defer r.deinit(std.testing.allocator);
    if (!hasCodeContaining(r, "M0101", "computeKernelMain")) {
        dump("expected M0101 on computeKernelMain", r);
        return error.TestUnexpectedResult;
    }
}

test "minify/long-entry-point-name: negative — short entry name is silent" {
    const src: [:0]const u8 =
        \\@compute @workgroup_size(1) fn main() {}
    ;
    var r = try runLint(src, minify_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(!hasCode(r, "M0101"));
}

test "minify/long-entry-point-name: negative — exact-threshold name is silent" {
    // Default max = 8. "fragMain" is exactly 8 chars; threshold check is
    // strictly greater-than, so 8 is OK.
    const src: [:0]const u8 =
        \\@fragment fn fragMain() -> @location(0) vec4f { return vec4f(0.0); }
    ;
    var r = try runLint(src, minify_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(!hasCode(r, "M0101"));
}

test "minify/long-entry-point-name: negative — long non-entry helper is silent" {
    // The rule is entry-point-only; long internal helper names are still
    // renamable so they're not in scope.
    const src: [:0]const u8 =
        \\fn longHelperFunctionName() -> f32 { return 1.0; }
        \\@compute @workgroup_size(1) fn main() { let _v = longHelperFunctionName(); }
    ;
    var r = try runLint(src, minify_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(!hasCode(r, "M0101"));
}

test "minify/long-entry-point-name: range covers the decl name span" {
    const src: [:0]const u8 =
        \\@compute @workgroup_size(1) fn computeKernelMain() {}
    ;
    var r = try runLint(src, minify_opts);
    defer r.deinit(std.testing.allocator);
    const d = firstWithCode(r, "M0101") orelse {
        dump("no M0101 emitted", r);
        return error.TestUnexpectedResult;
    };
    // `@compute @workgroup_size(1) fn computeKernelMain() {}` —
    // `computeKernelMain` starts at col 32 (1-based), length 17 → end col 49.
    try std.testing.expectEqual(@as(u32, 1), d.range.start.line);
    try std.testing.expectEqual(@as(u32, 32), d.range.start.column);
    try std.testing.expectEqual(@as(u32, 49), d.range.end.column);
}

test "minify/long-entry-point-name: default severity is hint" {
    const src: [:0]const u8 =
        \\@compute @workgroup_size(1) fn computeKernelMain() {}
    ;
    var r = try runLint(src, minify_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasSeverity(r, "M0101", .hint));
}

test "minify/long-entry-point-name: per-rule override escalates to warning" {
    const src: [:0]const u8 =
        \\@compute @workgroup_size(1) fn computeKernelMain() {}
    ;
    var r = try runLint(src, .{
        .extends = &.{"@wgslender/minify"},
        .rules = &.{
            .{ .id = "minify/long-entry-point-name", .severity = .warning },
        },
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasSeverity(r, "M0101", .warning));
}

test "minify/long-entry-point-name: options.max=3 makes 'main' fire" {
    // Default threshold (8) leaves `main` (4 chars) silent; a per-rule
    // option flip to max=3 should escalate it.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const opts_json = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        "{\"max\":3}",
        .{},
    );
    const src: [:0]const u8 =
        \\@compute @workgroup_size(1) fn main() {}
    ;
    var r = try runLint(src, .{
        .extends = &.{"@wgslender/minify"},
        .rules = &.{
            .{
                .id = "minify/long-entry-point-name",
                .severity = .hint,
                .options = opts_json,
            },
        },
    });
    defer r.deinit(std.testing.allocator);
    if (!hasCodeContaining(r, "M0101", "main")) {
        dump("expected M0101 on main with max=3", r);
        return error.TestUnexpectedResult;
    }
}

test "minify/long-entry-point-name: options.max=20 silences 'computeKernelMain'" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const opts_json = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        "{\"max\":20}",
        .{},
    );
    const src: [:0]const u8 =
        \\@compute @workgroup_size(1) fn computeKernelMain() {}
    ;
    var r = try runLint(src, .{
        .extends = &.{"@wgslender/minify"},
        .rules = &.{
            .{
                .id = "minify/long-entry-point-name",
                .severity = .hint,
                .options = opts_json,
            },
        },
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(!hasCode(r, "M0101"));
}

test "minify/long-entry-point-name: spec_ref points at minify slug" {
    const src: [:0]const u8 =
        \\@compute @workgroup_size(1) fn computeKernelMain() {}
    ;
    var r = try runLint(src, minify_opts);
    defer r.deinit(std.testing.allocator);
    const d = firstWithCode(r, "M0101") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("minify", d.spec_ref);
}

test "@wgslender/minify pack enables M0101" {
    const src: [:0]const u8 =
        \\@compute @workgroup_size(1) fn computeKernelMain() {}
    ;
    var r = try runLint(src, minify_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCode(r, "M0101"));
}

// =========================================================================
// minify/shader-exceeds-size-budget (M0500) — Phase 5c
// =========================================================================
//
// Module-level advisory that fires when the estimated minified byte size
// exceeds a user-supplied `maxBytes` threshold. No-ops without `maxBytes`
// — there's no defensible default budget so the rule is opt-in via the
// standard `Linter.RuleOverride.options` shape (`["warn", {"maxBytes": N}]`).
//
// The diagnostic anchors at the first declaration's name span so editors
// have a stable place to surface the squiggle; if the module has no
// declarations it falls back to (0..0).

fn parseOptionsLeaky(arena: std.mem.Allocator, json: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
}

const m0500_large_src: [:0]const u8 =
    \\fn helper_one() -> f32 { return 1.0; }
    \\fn helper_two() -> f32 { return 2.0; }
    \\fn helper_three() -> f32 { return 3.0; }
    \\@compute @workgroup_size(1) fn main() {
    \\    let _v = helper_one() + helper_two() + helper_three();
    \\}
;

test "minify/shader-exceeds-size-budget: positive — over-budget source fires" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const opts = try parseOptionsLeaky(arena.allocator(), "{\"maxBytes\":10}");

    var r = try runLint(m0500_large_src, .{
        .extends = &.{"@wgslender/minify"},
        .rules = &.{
            .{
                .id = "minify/shader-exceeds-size-budget",
                .severity = .hint,
                .options = opts,
            },
        },
    });
    defer r.deinit(std.testing.allocator);
    if (!hasCode(r, "M0500")) {
        dump("expected M0500 to fire on over-budget source", r);
        return error.TestUnexpectedResult;
    }
}

test "minify/shader-exceeds-size-budget: positive — message reports both numbers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const opts = try parseOptionsLeaky(arena.allocator(), "{\"maxBytes\":10}");

    var r = try runLint(m0500_large_src, .{
        .extends = &.{"@wgslender/minify"},
        .rules = &.{
            .{
                .id = "minify/shader-exceeds-size-budget",
                .severity = .hint,
                .options = opts,
            },
        },
    });
    defer r.deinit(std.testing.allocator);
    const d = firstWithCode(r, "M0500") orelse {
        dump("no M0500 emitted", r);
        return error.TestUnexpectedResult;
    };
    // Message must mention both the (estimated) actual size and the budget
    // — without that, the user has no idea by how much they're over.
    try std.testing.expect(std.mem.indexOf(u8, d.message, "10") != null);
    try std.testing.expect(std.mem.indexOf(u8, d.message, "bytes") != null);
}

test "minify/shader-exceeds-size-budget: negative — no maxBytes is silent regardless of size" {
    // Even a giant source file is silent without an explicit budget. The
    // pack-default (no options) must never fire on its own.
    var r = try runLint(m0500_large_src, minify_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(!hasCode(r, "M0500"));
}

test "minify/shader-exceeds-size-budget: negative — under-budget source is silent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // 100 KB is comfortably above any minified shader the test fixtures
    // produce, so even with the budget knob set the rule must stay quiet.
    const opts = try parseOptionsLeaky(arena.allocator(), "{\"maxBytes\":100000}");

    var r = try runLint(m0500_large_src, .{
        .extends = &.{"@wgslender/minify"},
        .rules = &.{
            .{
                .id = "minify/shader-exceeds-size-budget",
                .severity = .hint,
                .options = opts,
            },
        },
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(!hasCode(r, "M0500"));
}

test "minify/shader-exceeds-size-budget: negative — empty module is silent even with maxBytes=0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const opts = try parseOptionsLeaky(arena.allocator(), "{\"maxBytes\":0}");

    var r = try runLint("", .{
        .extends = &.{"@wgslender/minify"},
        .rules = &.{
            .{
                .id = "minify/shader-exceeds-size-budget",
                .severity = .hint,
                .options = opts,
            },
        },
    });
    defer r.deinit(std.testing.allocator);
    // Empty source minifies to 0 bytes — strictly-greater check means a
    // 0-byte budget on a 0-byte module stays silent.
    try std.testing.expect(!hasCode(r, "M0500"));
}

test "minify/shader-exceeds-size-budget: range covers the first decl name span" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const opts = try parseOptionsLeaky(arena.allocator(), "{\"maxBytes\":1}");

    // First decl is `const FIRST: f32 = 3.14;` — name `FIRST` starts at
    // col 7 (1-based), length 5 → end col 12.
    const src: [:0]const u8 =
        \\const FIRST: f32 = 3.14;
        \\const SECOND: f32 = 2.71;
        \\@compute @workgroup_size(1) fn main() { let _v = FIRST + SECOND; }
    ;
    var r = try runLint(src, .{
        .extends = &.{"@wgslender/minify"},
        .rules = &.{
            .{
                .id = "minify/shader-exceeds-size-budget",
                .severity = .hint,
                .options = opts,
            },
        },
    });
    defer r.deinit(std.testing.allocator);
    const d = firstWithCode(r, "M0500") orelse {
        dump("no M0500 emitted", r);
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqual(@as(u32, 1), d.range.start.line);
    try std.testing.expectEqual(@as(u32, 7), d.range.start.column);
    try std.testing.expectEqual(@as(u32, 12), d.range.end.column);
}

test "minify/shader-exceeds-size-budget: default severity is hint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const opts = try parseOptionsLeaky(arena.allocator(), "{\"maxBytes\":10}");

    var r = try runLint(m0500_large_src, .{
        .extends = &.{"@wgslender/minify"},
        .rules = &.{
            .{
                .id = "minify/shader-exceeds-size-budget",
                .severity = .hint,
                .options = opts,
            },
        },
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasSeverity(r, "M0500", .hint));
}

test "minify/shader-exceeds-size-budget: per-rule override escalates to warning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const opts = try parseOptionsLeaky(arena.allocator(), "{\"maxBytes\":10}");

    var r = try runLint(m0500_large_src, .{
        .extends = &.{"@wgslender/minify"},
        .rules = &.{
            .{
                .id = "minify/shader-exceeds-size-budget",
                .severity = .warning,
                .options = opts,
            },
        },
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasSeverity(r, "M0500", .warning));
}

test "minify/shader-exceeds-size-budget: spec_ref points at minify slug" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const opts = try parseOptionsLeaky(arena.allocator(), "{\"maxBytes\":10}");

    var r = try runLint(m0500_large_src, .{
        .extends = &.{"@wgslender/minify"},
        .rules = &.{
            .{
                .id = "minify/shader-exceeds-size-budget",
                .severity = .hint,
                .options = opts,
            },
        },
    });
    defer r.deinit(std.testing.allocator);
    const d = firstWithCode(r, "M0500") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("minify", d.spec_ref);
}

test "@wgslender/minify pack lists M0500 (silent without maxBytes)" {
    // The pack opts the rule in at default severity but the rule is a
    // no-op until `maxBytes` is supplied — confirm the pack alone doesn't
    // fire it on a fixture that would otherwise blow past any reasonable
    // budget.
    var r = try runLint(m0500_large_src, minify_opts);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(!hasCode(r, "M0500"));
}

