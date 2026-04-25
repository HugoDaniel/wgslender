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
    h.applyClientSettings(parsed.value);
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
    try applySettings(h, "{\"minifyMode\":\"insights\"}");

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
    try applySettings(h, "{\"minifyMode\":\"strict\"}");

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
    try applySettings(h, "{\"minifyMode\":\"strict\"}");

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
    try applySettings(h, "{\"minifyMode\":\"insights\"}");

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
    try applySettings(h, "{\"minifyMode\":\"strict\"}");

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
    try applySettings(h, "{\"minifyMode\":\"strict\"}");

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
    try applySettings(h, "{\"minifyMode\":\"strict\"}");

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
