//! Phase 5a — LSP integration for minify lint rules.
//!
//! Exercises the publish-diagnostics path (`Handler.validateDocumentFull`)
//! when the document's effective minifier-mode resolves to `strict`. The
//! Linter is wired in at this layer so:
//!
//!   * `mode=insights` and `mode=off` produce no M-diagnostics;
//!   * `mode=strict` (workspace or per-document magic comment) surfaces
//!     `M0100` / `M0201` / `M0202` alongside the validator's own output;
//!   * `wgslender-disable[-next-line|-file]` directives suppress them
//!     (filtering happens inside the Linter via `src/lint/Disable.zig`,
//!     so the LSP gets it for free).

const std = @import("std");
const Handler = @import("Handler");

fn setup() !*Handler {
    const h = try std.testing.allocator.create(Handler);
    h.* = Handler.init(std.testing.allocator);
    return h;
}

fn teardown(h: *Handler) void {
    h.deinit();
    std.testing.allocator.destroy(h);
}

fn parseJson(json: []const u8) !std.json.Parsed(std.json.Value) {
    return try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        json,
        .{ .ignore_unknown_fields = true, .max_value_len = null },
    );
}

fn applySettings(h: *Handler, json: []const u8) !void {
    var parsed = try parseJson(json);
    defer parsed.deinit();
    h.applyClientConfig(parsed.value);
}

fn freeDiags(diags: []Handler.LspDiagnostic) void {
    Handler.freeDiagnostics(std.testing.allocator, diags);
}

fn hasCode(diags: []const Handler.LspDiagnostic, code: []const u8) bool {
    for (diags) |d| {
        if (std.mem.eql(u8, d.code, code)) return true;
    }
    return false;
}

fn dump(label: []const u8, diags: []const Handler.LspDiagnostic) void {
    std.debug.print("\n{s}:\n", .{label});
    for (diags) |d| {
        std.debug.print(
            "  {d}:{d} [{s}] sev={d}: {s}\n",
            .{ d.range.start.line, d.range.start.character, d.code, @intFromEnum(d.severity), d.message },
        );
    }
}

const sample_with_minify_issues: [:0]const u8 =
    \\const UNUSED_K: f32 = 3.14;
    \\@id(0) override UNUSED_OVR: u32 = 8;
    \\@group(0) @binding(0) var<uniform> uniforms: f32;
    \\@compute @workgroup_size(1) fn main() { let _v = uniforms; }
;

// =========================================================================
// mode gating
// =========================================================================

test "lsp minify rules: no M-diagnostics when mode=off (default)" {
    const h = try setup();
    defer teardown(h);

    try h.openDocument("file:///a.wgsl", sample_with_minify_issues, 1);
    const diags = try h.validateDocumentFull("file:///a.wgsl");
    defer freeDiags(diags);

    if (hasCode(diags, "M0100") or hasCode(diags, "M0201") or hasCode(diags, "M0202")) {
        dump("unexpected M-diagnostic at mode=off", diags);
        return error.TestUnexpectedResult;
    }
}

test "lsp minify rules: no M-diagnostics when mode=insights" {
    const h = try setup();
    defer teardown(h);
    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"insights\"}}");

    try h.openDocument("file:///a.wgsl", sample_with_minify_issues, 1);
    const diags = try h.validateDocumentFull("file:///a.wgsl");
    defer freeDiags(diags);

    if (hasCode(diags, "M0100") or hasCode(diags, "M0201") or hasCode(diags, "M0202")) {
        dump("unexpected M-diagnostic at mode=insights", diags);
        return error.TestUnexpectedResult;
    }
}

test "lsp minify rules: M-diagnostics surface when mode=strict" {
    const h = try setup();
    defer teardown(h);
    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"strict\"}}");

    try h.openDocument("file:///a.wgsl", sample_with_minify_issues, 1);
    const diags = try h.validateDocumentFull("file:///a.wgsl");
    defer freeDiags(diags);

    if (!hasCode(diags, "M0201")) {
        dump("expected M0201 at mode=strict", diags);
        return error.TestUnexpectedResult;
    }
    if (!hasCode(diags, "M0202")) {
        dump("expected M0202 at mode=strict", diags);
        return error.TestUnexpectedResult;
    }
    if (!hasCode(diags, "M0100")) {
        dump("expected M0100 at mode=strict", diags);
        return error.TestUnexpectedResult;
    }
}

test "lsp minify rules: M-diagnostic severity converts to LSP hint" {
    const h = try setup();
    defer teardown(h);
    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"strict\"}}");

    try h.openDocument("file:///a.wgsl", "const UNUSED_K: f32 = 3.14;\n", 1);
    const diags = try h.validateDocumentFull("file:///a.wgsl");
    defer freeDiags(diags);

    var saw_hint = false;
    for (diags) |d| {
        if (!std.mem.eql(u8, d.code, "M0201")) continue;
        try std.testing.expectEqual(Handler.DiagnosticSeverity.hint, d.severity);
        saw_hint = true;
    }
    if (!saw_hint) {
        dump("expected M0201 in payload", diags);
        return error.TestUnexpectedResult;
    }
}

// =========================================================================
// magic-comment layer
// =========================================================================

test "lsp minify rules: magic comment minify-strict surfaces M-diagnostics" {
    const h = try setup();
    defer teardown(h);

    const src: [:0]const u8 =
        \\// wgslender-minify-strict
        \\const UNUSED_K: f32 = 3.14;
    ;
    try h.openDocument("file:///a.wgsl", src, 1);
    const diags = try h.validateDocumentFull("file:///a.wgsl");
    defer freeDiags(diags);

    if (!hasCode(diags, "M0201")) {
        dump("expected M0201 from magic-comment-driven strict mode", diags);
        return error.TestUnexpectedResult;
    }
}

test "lsp minify rules: magic comment minify-insights still suppresses M-diagnostics" {
    const h = try setup();
    defer teardown(h);

    const src: [:0]const u8 =
        \\// wgslender-minify-insights
        \\const UNUSED_K: f32 = 3.14;
    ;
    try h.openDocument("file:///a.wgsl", src, 1);
    const diags = try h.validateDocumentFull("file:///a.wgsl");
    defer freeDiags(diags);

    if (hasCode(diags, "M0201")) {
        dump("unexpected M0201 from magic-comment-driven insights mode", diags);
        return error.TestUnexpectedResult;
    }
}

test "lsp minify rules: magic-strict beats workspace=insights" {
    const h = try setup();
    defer teardown(h);
    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"insights\"}}");

    const src: [:0]const u8 =
        \\// wgslender-minify-strict
        \\@group(0) @binding(0) var<uniform> uniforms: f32;
    ;
    try h.openDocument("file:///a.wgsl", src, 1);
    const diags = try h.validateDocumentFull("file:///a.wgsl");
    defer freeDiags(diags);

    if (!hasCode(diags, "M0100")) {
        dump("expected magic-comment override to surface M0100", diags);
        return error.TestUnexpectedResult;
    }
}

// =========================================================================
// disable directives (free via Linter framework)
// =========================================================================

test "lsp minify rules: wgslender-disable-next-line silences M0201" {
    const h = try setup();
    defer teardown(h);
    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"strict\"}}");

    const src: [:0]const u8 =
        \\// wgslender-disable-next-line minify/unused-const
        \\const UNUSED_K: f32 = 3.14;
    ;
    try h.openDocument("file:///a.wgsl", src, 1);
    const diags = try h.validateDocumentFull("file:///a.wgsl");
    defer freeDiags(diags);

    if (hasCode(diags, "M0201")) {
        dump("expected disable-next-line to silence M0201", diags);
        return error.TestUnexpectedResult;
    }
}

test "lsp minify rules: wgslender-disable file-scope silences M0100" {
    const h = try setup();
    defer teardown(h);
    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"strict\"}}");

    const src: [:0]const u8 =
        \\// wgslender-disable minify/external-binding-blocks-rename
        \\@group(0) @binding(0) var<uniform> uniforms: f32;
    ;
    try h.openDocument("file:///a.wgsl", src, 1);
    const diags = try h.validateDocumentFull("file:///a.wgsl");
    defer freeDiags(diags);

    if (hasCode(diags, "M0100")) {
        dump("expected file-scope disable to silence M0100", diags);
        return error.TestUnexpectedResult;
    }
}

// =========================================================================
// non-interference with validator output
// =========================================================================

test "lsp minify rules: validator errors still flow through alongside M-diagnostics" {
    const h = try setup();
    defer teardown(h);
    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"strict\"}}");

    // Real validator error (undefined identifier) plus an unused const.
    const src: [:0]const u8 =
        \\const UNUSED_K: f32 = 3.14;
        \\@compute @workgroup_size(1) fn main() { let _v = does_not_exist; }
    ;
    try h.openDocument("file:///a.wgsl", src, 1);
    const diags = try h.validateDocumentFull("file:///a.wgsl");
    defer freeDiags(diags);

    var saw_error = false;
    var saw_minify = false;
    for (diags) |d| {
        if (d.severity == .@"error") saw_error = true;
        if (std.mem.eql(u8, d.code, "M0201")) saw_minify = true;
    }
    try std.testing.expect(saw_error);
    try std.testing.expect(saw_minify);
}

// =========================================================================
// mangleExternalBindings gate on M0100
// =========================================================================
//
// The hint exists to nudge the user to enable `--mangle-external-bindings`.
// Once they have, surfacing the hint is just noise — gate it out via the
// top-level `mangleExternalBindings` knob (single source of truth shared
// with the CLI minifier; consumed by `Handler.mangleExternalBindings()`).

test "lsp minify rules: mangleExternalBindings=true silences M0100 in strict" {
    const h = try setup();
    defer teardown(h);
    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"strict\"},\"mangleExternalBindings\":true}");

    const src: [:0]const u8 =
        \\@group(0) @binding(0) var<uniform> uniforms: f32;
        \\@compute @workgroup_size(1) fn main() { let _v = uniforms; }
    ;
    try h.openDocument("file:///a.wgsl", src, 1);
    const diags = try h.validateDocumentFull("file:///a.wgsl");
    defer freeDiags(diags);

    if (hasCode(diags, "M0100")) {
        dump("expected mangleExternalBindings=true to silence M0100", diags);
        return error.TestUnexpectedResult;
    }
}

test "lsp minify rules: mangleExternalBindings=false (default) keeps M0100 firing" {
    const h = try setup();
    defer teardown(h);
    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"strict\"}}");

    const src: [:0]const u8 =
        \\@group(0) @binding(0) var<uniform> uniforms: f32;
        \\@compute @workgroup_size(1) fn main() { let _v = uniforms; }
    ;
    try h.openDocument("file:///a.wgsl", src, 1);
    const diags = try h.validateDocumentFull("file:///a.wgsl");
    defer freeDiags(diags);

    if (!hasCode(diags, "M0100")) {
        dump("expected M0100 to still fire when mangleExternalBindings is unset", diags);
        return error.TestUnexpectedResult;
    }
}

// =========================================================================
// Phase 5b — minifyLints.severities map → Linter.Options.RuleOverride[]
// =========================================================================

test "lsp minify rules: severities map flips M0201 to warning" {
    const h = try setup();
    defer teardown(h);
    try applySettings(h,
        \\{"lsp":{"minifyMode":"strict"},"rules":{"minify/unused-const":"warning"}}
    );

    try h.openDocument("file:///a.wgsl", "const UNUSED_K: f32 = 3.14;\n", 1);
    const diags = try h.validateDocumentFull("file:///a.wgsl");
    defer freeDiags(diags);

    var saw_warning = false;
    for (diags) |d| {
        if (!std.mem.eql(u8, d.code, "M0201")) continue;
        try std.testing.expectEqual(Handler.DiagnosticSeverity.warning, d.severity);
        saw_warning = true;
    }
    if (!saw_warning) {
        dump("expected M0201 stamped at warning", diags);
        return error.TestUnexpectedResult;
    }
}

test "lsp minify rules: severities map M0100=error escalates" {
    const h = try setup();
    defer teardown(h);
    try applySettings(h,
        \\{"lsp":{"minifyMode":"strict"},"rules":{"minify/external-binding-blocks-rename":"error"}}
    );

    const src: [:0]const u8 =
        \\@group(0) @binding(0) var<uniform> uniforms: f32;
        \\@compute @workgroup_size(1) fn main() { let _v = uniforms; }
    ;
    try h.openDocument("file:///a.wgsl", src, 1);
    const diags = try h.validateDocumentFull("file:///a.wgsl");
    defer freeDiags(diags);

    var saw_error = false;
    for (diags) |d| {
        if (!std.mem.eql(u8, d.code, "M0100")) continue;
        try std.testing.expectEqual(Handler.DiagnosticSeverity.@"error", d.severity);
        saw_error = true;
    }
    if (!saw_error) {
        dump("expected M0100 stamped at error", diags);
        return error.TestUnexpectedResult;
    }
}

test "lsp minify rules: severities map M0201=off silences" {
    const h = try setup();
    defer teardown(h);
    try applySettings(h,
        \\{"lsp":{"minifyMode":"strict"},"rules":{"minify/unused-const":"off"}}
    );

    try h.openDocument("file:///a.wgsl", "const UNUSED_K: f32 = 3.14;\n", 1);
    const diags = try h.validateDocumentFull("file:///a.wgsl");
    defer freeDiags(diags);

    if (hasCode(diags, "M0201")) {
        dump("expected severities=off to silence M0201", diags);
        return error.TestUnexpectedResult;
    }
}

test "lsp minify rules: unknown severities key silently ignored" {
    const h = try setup();
    defer teardown(h);
    try applySettings(h,
        \\{"lsp":{"minifyMode":"strict"},"rules":{"minify/does-not-exist":"warning","minify/unused-const":"warning"}}
    );

    try h.openDocument("file:///a.wgsl", "const UNUSED_K: f32 = 3.14;\n", 1);
    const diags = try h.validateDocumentFull("file:///a.wgsl");
    defer freeDiags(diags);

    var saw_warning = false;
    for (diags) |d| {
        if (!std.mem.eql(u8, d.code, "M0201")) continue;
        try std.testing.expectEqual(Handler.DiagnosticSeverity.warning, d.severity);
        saw_warning = true;
    }
    try std.testing.expect(saw_warning);
}

test "lsp minify rules: severities + mangleExternalBindings compose (gate beats severity)" {
    // User escalated M0100 to error AND opted into renaming. The gate
    // wins because the rule no-ops before producing any diagnostic.
    const h = try setup();
    defer teardown(h);
    try applySettings(h,
        \\{"lsp":{"minifyMode":"strict"},"mangleExternalBindings":true,"rules":{"minify/external-binding-blocks-rename":"error"}}
    );

    const src: [:0]const u8 =
        \\@group(0) @binding(0) var<uniform> uniforms: f32;
        \\@compute @workgroup_size(1) fn main() { let _v = uniforms; }
    ;
    try h.openDocument("file:///a.wgsl", src, 1);
    const diags = try h.validateDocumentFull("file:///a.wgsl");
    defer freeDiags(diags);

    if (hasCode(diags, "M0100")) {
        dump("expected mangle gate to silence M0100 even with severity=error", diags);
        return error.TestUnexpectedResult;
    }
}

test "lsp minify rules: mangleExternalBindings=true does not silence other M-codes" {
    // The gate is M0100-only — flipping it should leave M0201 / M0202 alone.
    const h = try setup();
    defer teardown(h);
    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"strict\"},\"mangleExternalBindings\":true}");

    const src: [:0]const u8 =
        \\const UNUSED_K: f32 = 3.14;
        \\@id(0) override UNUSED_OVR: u32 = 8;
        \\@group(0) @binding(0) var<uniform> uniforms: f32;
        \\@compute @workgroup_size(1) fn main() { let _v = uniforms; }
    ;
    try h.openDocument("file:///a.wgsl", src, 1);
    const diags = try h.validateDocumentFull("file:///a.wgsl");
    defer freeDiags(diags);

    if (hasCode(diags, "M0100")) {
        dump("expected M0100 silenced by mangleExternalBindings=true", diags);
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(hasCode(diags, "M0201"));
    try std.testing.expect(hasCode(diags, "M0202"));
}

// =========================================================================
// Phase 5c — minify/shader-exceeds-size-budget (M0500) LSP integration
// =========================================================================
//
// M0500 is opt-in via the rule's `options.maxBytes` shape. Phase 5c
// intentionally does NOT ship an LSP-side `minifyLints.budgetBytes`
// knob — that wiring is deferred to Phase 6 alongside the total-size
// code lens (see §18 entry 16). These tests lock the current behaviour
// so a future regression is caught:
//
//   * mode=insights and mode=off never run lint rules, so M0500 is
//     silent regardless of any severity flip.
//   * mode=strict + no LSP-side budget knob → silent (the rule no-ops
//     without `maxBytes`).
//   * the `severities` map can still address M0500 (e.g. set it to off)
//     without crashing — confirms the registry lookup wires the code
//     correctly even though the rule itself stays quiet.

const sample_with_many_decls: [:0]const u8 =
    \\fn helper_one() -> f32 { return 1.0; }
    \\fn helper_two() -> f32 { return 2.0; }
    \\fn helper_three() -> f32 { return 3.0; }
    \\@compute @workgroup_size(1) fn main() {
    \\    let _v = helper_one() + helper_two() + helper_three();
    \\}
;

test "lsp minify rules: mode=insights does not fire M0500" {
    const h = try setup();
    defer teardown(h);
    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"insights\"}}");

    try h.openDocument("file:///a.wgsl", sample_with_many_decls, 1);
    const diags = try h.validateDocumentFull("file:///a.wgsl");
    defer freeDiags(diags);

    if (hasCode(diags, "M0500")) {
        dump("unexpected M0500 at mode=insights", diags);
        return error.TestUnexpectedResult;
    }
}

test "lsp minify rules: mode=strict alone does not fire M0500 (deferred budgetBytes knob)" {
    // Phase 5c §18 entry 16: there is intentionally no LSP-side
    // `minifyLints.budgetBytes` setting yet. The rule must stay silent
    // until that wiring lands (Phase 6) so the LSP doesn't surface a
    // diagnostic the user has no UI to configure.
    const h = try setup();
    defer teardown(h);
    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"strict\"}}");

    try h.openDocument("file:///a.wgsl", sample_with_many_decls, 1);
    const diags = try h.validateDocumentFull("file:///a.wgsl");
    defer freeDiags(diags);

    if (hasCode(diags, "M0500")) {
        dump("unexpected M0500 — strict mode without a budget knob must stay silent", diags);
        return error.TestUnexpectedResult;
    }
}

test "lsp minify rules: severities map can address M0500 without crashing" {
    // The severities map flips severity but cannot supply `maxBytes`,
    // so M0500 stays silent here too. The point of this test is to
    // confirm the registry lookup resolves "M0500" → the rule id and
    // doesn't panic / leak.
    const h = try setup();
    defer teardown(h);
    try applySettings(h,
        \\{"lsp":{"minifyMode":"strict"},"rules":{"minify/shader-exceeds-size-budget":"warning"}}
    );

    try h.openDocument("file:///a.wgsl", sample_with_many_decls, 1);
    const diags = try h.validateDocumentFull("file:///a.wgsl");
    defer freeDiags(diags);

    if (hasCode(diags, "M0500")) {
        dump("unexpected M0500 — severity flip cannot supply maxBytes", diags);
        return error.TestUnexpectedResult;
    }
}

test "lsp minify rules: severities M0500=off is a no-op (already silent)" {
    const h = try setup();
    defer teardown(h);
    try applySettings(h,
        \\{"lsp":{"minifyMode":"strict"},"rules":{"minify/shader-exceeds-size-budget":"off"}}
    );

    try h.openDocument("file:///a.wgsl", sample_with_many_decls, 1);
    const diags = try h.validateDocumentFull("file:///a.wgsl");
    defer freeDiags(diags);

    if (hasCode(diags, "M0500")) {
        dump("unexpected M0500 — severity=off must stay silent", diags);
        return error.TestUnexpectedResult;
    }
}

// =========================================================================
// Phase 6 — minifyLints.budgetBytes knob
// =========================================================================
//
// Phase 6 closes the gap left by Phase 5c: the LSP can now supply
// `maxBytes` to M0500 via `minifyLints.budgetBytes`, so users driving
// the LSP can finally fire the rule. CLI users were already covered
// through the `Linter.RuleOverride.options` shape; this is a pure
// LSP-side wiring exercise.

test "lsp minify rules: minifyLints.budgetBytes fires M0500 when shader exceeds budget" {
    const h = try setup();
    defer teardown(h);
    // Tiny budget guarantees the multi-decl sample blows past it. The
    // estimator's exact byte count for `sample_with_many_decls` is
    // implementation-detail; comparing against `1` keeps the test
    // robust to estimator tweaks while still pinning "fires when over".
    try applySettings(h,
        \\{"lsp":{"minifyMode":"strict","minifyLints":{"budgetBytes":1}}}
    );

    try h.openDocument("file:///a.wgsl", sample_with_many_decls, 1);
    const diags = try h.validateDocumentFull("file:///a.wgsl");
    defer freeDiags(diags);

    if (!hasCode(diags, "M0500")) {
        dump("expected M0500 with budgetBytes=1 (any non-empty shader exceeds it)", diags);
        return error.TestUnexpectedResult;
    }
}

test "lsp minify rules: minifyLints.budgetBytes silent when under budget" {
    const h = try setup();
    defer teardown(h);
    // 1 MiB ceiling — no realistic test fixture will brush against it.
    try applySettings(h,
        \\{"lsp":{"minifyMode":"strict","minifyLints":{"budgetBytes":1048576}}}
    );

    try h.openDocument("file:///a.wgsl", sample_with_many_decls, 1);
    const diags = try h.validateDocumentFull("file:///a.wgsl");
    defer freeDiags(diags);

    if (hasCode(diags, "M0500")) {
        dump("unexpected M0500 — shader is well under 1 MiB budget", diags);
        return error.TestUnexpectedResult;
    }
}

test "lsp minify rules: minifyLints.budgetBytes still silent at mode=insights" {
    // Lints aren't active at mode=insights regardless of budget value;
    // this guards against a regression where the budget knob accidentally
    // gates `lintsActive()` instead of being a per-rule input.
    const h = try setup();
    defer teardown(h);
    try applySettings(h,
        \\{"lsp":{"minifyMode":"insights","minifyLints":{"budgetBytes":1}}}
    );

    try h.openDocument("file:///a.wgsl", sample_with_many_decls, 1);
    const diags = try h.validateDocumentFull("file:///a.wgsl");
    defer freeDiags(diags);

    if (hasCode(diags, "M0500")) {
        dump("unexpected M0500 at mode=insights even with budgetBytes set", diags);
        return error.TestUnexpectedResult;
    }
}

test "lsp minify rules: minifyLints.budgetBytes negative value silently ignored" {
    const h = try setup();
    defer teardown(h);
    try applySettings(h,
        \\{"lsp":{"minifyMode":"strict","minifyLints":{"budgetBytes":-1}}}
    );

    try h.openDocument("file:///a.wgsl", sample_with_many_decls, 1);
    const diags = try h.validateDocumentFull("file:///a.wgsl");
    defer freeDiags(diags);

    if (hasCode(diags, "M0500")) {
        dump("unexpected M0500 — negative budget must be treated as unset", diags);
        return error.TestUnexpectedResult;
    }
}

test "lsp minify rules: minifyLints.budgetBytes wrong type silently ignored" {
    const h = try setup();
    defer teardown(h);
    try applySettings(h,
        \\{"lsp":{"minifyMode":"strict","minifyLints":{"budgetBytes":"1024"}}}
    );

    try h.openDocument("file:///a.wgsl", sample_with_many_decls, 1);
    const diags = try h.validateDocumentFull("file:///a.wgsl");
    defer freeDiags(diags);

    if (hasCode(diags, "M0500")) {
        dump("unexpected M0500 — string budget must be treated as unset", diags);
        return error.TestUnexpectedResult;
    }
}

test "lsp minify rules: minifyLints.budgetBytes composes with severities map" {
    // Severity=warning + budget=1 should both apply: M0500 fires
    // (because of the budget) and is stamped at warning (because of the
    // severities map), confirming the override accumulator merges the
    // two paths into a single RuleOverride entry.
    const h = try setup();
    defer teardown(h);
    try applySettings(h,
        \\{"lsp":{"minifyMode":"strict","minifyLints":{"budgetBytes":1}},"rules":{"minify/shader-exceeds-size-budget":"warning"}}
    );

    try h.openDocument("file:///a.wgsl", sample_with_many_decls, 1);
    const diags = try h.validateDocumentFull("file:///a.wgsl");
    defer freeDiags(diags);

    var saw_warning = false;
    for (diags) |d| {
        if (!std.mem.eql(u8, d.code, "M0500")) continue;
        try std.testing.expectEqual(Handler.DiagnosticSeverity.warning, d.severity);
        saw_warning = true;
    }
    if (!saw_warning) {
        dump("expected M0500 stamped at warning with budget=1", diags);
        return error.TestUnexpectedResult;
    }
}
