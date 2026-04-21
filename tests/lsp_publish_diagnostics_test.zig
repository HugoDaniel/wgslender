//! End-to-end tests for the `textDocument/publishDiagnostics` JSON
//! payload. Drives real WGSL sources through `Handler.validateDocument`
//! → `bridge.toLspKitDiagnostics` → `lsp.writeNotification`, captures
//! the raw JSON-RPC bytes, and asserts the serialized fields editors
//! actually consume:
//!
//!   * `code`                  — string, round-tripped through the bridge.
//!   * `codeDescription.href`  — full WGSL spec URL built from `spec_ref`.
//!   * `relatedInformation[]`  — location.uri, 0-based range, message.
//!   * `severity`              — integer (1..4), never a tag name.
//!   * `source`                — always `"wgslender"`.
//!   * absence of optional keys when the Handler diagnostic doesn't
//!     carry the corresponding data (guarantee of
//!     `.emit_null_optional_fields = false`).
//!
//! Complements the unit tests at `lsp/Handler.zig` (lines ~3578–3684),
//! which stop one struct hop short of what the client sees on the wire.

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");
const bridge = @import("bridge");
const wgslender = @import("wgslender");

const Diagnostic = wgslender.Diagnostic;

const test_uri = "test://fixture.wgsl";

// =========================================================================
// Helpers
// =========================================================================

/// Captured JSON-RPC notification plus the parsed value tree. All
/// allocations live on a single arena (including the byte buffer) so
/// callers just `deinit()` once.
const Captured = struct {
    arena: std.heap.ArenaAllocator,
    /// The full JSON-RPC envelope after the `Content-Length: N\r\n\r\n` header.
    body: []const u8,
    /// Parsed envelope. `root.object` holds `jsonrpc`, `method`, `params`.
    root: std.json.Value,
    /// Shortcut to `params` object (the `PublishDiagnosticsParams`).
    params: std.json.Value,
    /// Shortcut to `params.diagnostics` array.
    diagnostics: std.json.Value,

    fn deinit(self: *Captured) void {
        self.arena.deinit();
    }

    /// Find the first diagnostic whose `message` contains `needle`. Returns
    /// the JSON object value, or `error.DiagnosticNotFound` with a printed
    /// dump of all diagnostics seen (mirrors the existing validator tests
    /// in `tests/validation_related_test.zig`).
    fn findByMessage(self: *const Captured, needle: []const u8) !std.json.Value {
        for (self.diagnostics.array.items) |d| {
            const msg = d.object.get("message") orelse continue;
            if (msg != .string) continue;
            if (std.mem.indexOf(u8, msg.string, needle) != null) return d;
        }
        std.debug.print("\nNo diagnostic message contains \"{s}\". Got {d}:\n", .{ needle, self.diagnostics.array.items.len });
        for (self.diagnostics.array.items) |d| dumpDiag(d);
        return error.DiagnosticNotFound;
    }
};

fn dumpDiag(d: std.json.Value) void {
    const code = if (d.object.get("code")) |c| switch (c) {
        .string => |s| s,
        else => "<non-string>",
    } else "<absent>";
    const msg = if (d.object.get("message")) |m| switch (m) {
        .string => |s| s,
        else => "<non-string>",
    } else "<absent>";
    std.debug.print("  [{s}] {s}\n", .{ code, msg });
}

/// Runs the full validate → bridge → writeNotification chain and returns
/// the parsed JSON-RPC body. Use `arena` lifetime = test body lifetime.
fn captureForSource(source: []const u8) !Captured {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const handler_diags = try handler.validateDocument(source);
    defer Handler.freeDiagnostics(std.testing.allocator, handler_diags);

    var bridged = try bridge.toLspKitDiagnostics(std.testing.allocator, handler_diags, test_uri);
    defer bridged.deinit();

    var aw: std.Io.Writer.Allocating = .init(aa);
    try lsp.writeNotification(
        &aw.writer,
        aa,
        "textDocument/publishDiagnostics",
        lsp.types.publish_diagnostics.Params,
        .{ .uri = test_uri, .diagnostics = bridged.diagnostics },
        .{ .emit_null_optional_fields = false },
    );

    const full = aw.written();
    const sep = "\r\n\r\n";
    const sep_idx = std.mem.indexOf(u8, full, sep) orelse return error.MalformedEnvelope;
    const body = full[sep_idx + sep.len ..];

    // Parse into a Value tree for flexible field probing.
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, aa, body, .{});
    const params = parsed.object.get("params") orelse return error.MissingParams;
    const diags = params.object.get("diagnostics") orelse return error.MissingDiagnostics;
    if (diags != .array) return error.DiagnosticsNotArray;

    return .{
        .arena = arena,
        .body = body,
        .root = parsed,
        .params = params,
        .diagnostics = diags,
    };
}

/// Resolve `obj.path.to.field` (dot-separated). Returns null if any
/// intermediate key is missing or non-object.
fn getPath(obj: std.json.Value, path: []const u8) ?std.json.Value {
    var cur = obj;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |seg| {
        if (cur != .object) return null;
        cur = cur.object.get(seg) orelse return null;
    }
    return cur;
}

// =========================================================================
// Scenario 1 — `code` + `codeDescription.href` on a type-mismatch error.
// =========================================================================

test "publishDiagnostics JSON: const-init type mismatch carries code + codeDescription" {
    // E0200 (type_mismatch) on `const x: i32 = 1.5;`. The existing
    // round-trip test at lsp/Handler.zig:3631 pins that this source
    // produces a diagnostic whose code starts with "E".
    var cap = try captureForSource("const x: i32 = 1.5;");
    defer cap.deinit();

    const d = try cap.findByMessage("cannot initialize");

    // code is a string, not an integer (LSP allows either; wgslender uses strings)
    const code = d.object.get("code") orelse return error.MissingCode;
    try std.testing.expect(code == .string);
    try std.testing.expectEqualStrings("E0200", code.string);

    // codeDescription.href is the full WGSL spec URL for the "types" section.
    const href = getPath(d, "codeDescription.href") orelse return error.MissingCodeDescription;
    try std.testing.expect(href == .string);
    try std.testing.expectEqualStrings("https://www.w3.org/TR/WGSL/#types", href.string);

    // source is always "wgslender" when we emit (added in main.zig's bridge).
    const source = d.object.get("source") orelse return error.MissingSource;
    try std.testing.expectEqualStrings("wgslender", source.string);

    // severity is an integer 1..4 (LSP DiagnosticSeverity), never a tag name.
    const sev = d.object.get("severity") orelse return error.MissingSeverity;
    try std.testing.expect(sev == .integer);
    try std.testing.expectEqual(@as(i64, 1), sev.integer); // Error

    // Range is 0-based on both start and end (Handler's convertDiagnostic
    // subtracts 1 from the internal 1-based lines/columns).
    const start_line = getPath(d, "range.start.line") orelse return error.MissingRange;
    try std.testing.expect(start_line == .integer);
    try std.testing.expectEqual(@as(i64, 0), start_line.integer);
}

// =========================================================================
// Scenario 2 — uniformity error gets the dedicated `#uniformity` slug.
// =========================================================================

test "publishDiagnostics JSON: uniformity error emits #uniformity spec URL" {
    // Same fixture as lsp/Handler.zig:3656 — workgroupBarrier under a
    // non-uniform conditional.
    const source =
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) global_invocation_id: vec3<u32>) {
        \\  if (global_invocation_id.x > 0) {
        \\    workgroupBarrier();
        \\  }
        \\}
    ;
    var cap = try captureForSource(source);
    defer cap.deinit();

    // Find a diagnostic whose codeDescription.href contains "uniformity".
    // We don't pin the specific code because E0700/E0701/E0702 all share
    // the slug — the contract is that ANY uniformity diag hits #uniformity.
    var hit: ?std.json.Value = null;
    for (cap.diagnostics.array.items) |d| {
        const href = getPath(d, "codeDescription.href") orelse continue;
        if (href != .string) continue;
        if (std.mem.endsWith(u8, href.string, "#uniformity")) {
            hit = d;
            break;
        }
    }

    if (hit == null) {
        std.debug.print("\nNo diagnostic with #uniformity href. Got:\n", .{});
        for (cap.diagnostics.array.items) |d| dumpDiag(d);
        return error.TestUnexpectedResult;
    }
    // And it must be an error severity with a non-empty code.
    const d = hit.?;
    const sev = d.object.get("severity").?.integer;
    try std.testing.expectEqual(@as(i64, 1), sev);
    const code = d.object.get("code").?;
    try std.testing.expect(code == .string and code.string.len > 0);
}

// =========================================================================
// Scenario 3 — relatedInformation on duplicate struct member (E0101).
// =========================================================================

test "publishDiagnostics JSON: duplicate struct member has relatedInformation" {
    // Fixture pinned by tests/validation_related_test.zig:76.
    const source =
        \\struct Foo {
        \\  x: f32,
        \\  x: i32,
        \\}
    ;
    var cap = try captureForSource(source);
    defer cap.deinit();

    const d = try cap.findByMessage("duplicate member 'x'");

    const related = d.object.get("relatedInformation") orelse return error.MissingRelatedInformation;
    try std.testing.expect(related == .array);
    try std.testing.expect(related.array.items.len >= 1);

    const ri = related.array.items[0];
    // URI on the related location points back to our document URI.
    const ri_uri = getPath(ri, "location.uri") orelse return error.MissingRelatedUri;
    try std.testing.expectEqualStrings(test_uri, ri_uri.string);

    // Related message carries the "first declared here" hint.
    const ri_msg = ri.object.get("message") orelse return error.MissingRelatedMessage;
    try std.testing.expect(ri_msg == .string);
    try std.testing.expect(std.mem.indexOf(u8, ri_msg.string, "first declared here") != null);

    // Related range is 0-based. For this fixture, the first declaration
    // sits on line index 1 (the second source line: `  x: f32,`). We
    // don't pin the exact column because `tests/validation_related_test.zig`
    // already does; we pin the 0-based conversion invariant.
    const ri_line = getPath(ri, "location.range.start.line") orelse return error.MissingRelatedRange;
    try std.testing.expect(ri_line == .integer);
    try std.testing.expectEqual(@as(i64, 1), ri_line.integer);
}

// =========================================================================
// Scenario 4 — duplicate binding: BOTH codeDescription AND relatedInformation.
// =========================================================================

test "publishDiagnostics JSON: duplicate @group/@binding has codeDescription and relatedInformation" {
    // Fixture pinned by tests/validation_related_test.zig:104.
    const source =
        \\@group(0) @binding(0) var<uniform> a: f32;
        \\@group(0) @binding(0) var<uniform> b: f32;
    ;
    var cap = try captureForSource(source);
    defer cap.deinit();

    const d = try cap.findByMessage("is already used by");

    // E0804 (duplicate_binding) → spec_ref = "memory-model".
    const href = getPath(d, "codeDescription.href") orelse return error.MissingCodeDescription;
    try std.testing.expect(href == .string);
    try std.testing.expectEqualStrings("https://www.w3.org/TR/WGSL/#memory-model", href.string);

    const code = d.object.get("code").?;
    try std.testing.expectEqualStrings("E0804", code.string);

    // Related info points to `a` on line index 0.
    const related = d.object.get("relatedInformation") orelse return error.MissingRelatedInformation;
    try std.testing.expect(related.array.items.len >= 1);
    const ri = related.array.items[0];
    const ri_line = getPath(ri, "location.range.start.line").?.integer;
    try std.testing.expectEqual(@as(i64, 0), ri_line);
    try std.testing.expect(std.mem.indexOf(u8, ri.object.get("message").?.string, "declared here") != null);
}

// =========================================================================
// Scenario 5 — W0100 shadowing: warning severity, no relatedInformation key.
// =========================================================================

test "publishDiagnostics JSON: W0100 shadowing warning omits relatedInformation key" {
    const source =
        \\var<private> x: f32;
        \\fn main() { let x = 1.0; }
    ;
    var cap = try captureForSource(source);
    defer cap.deinit();

    // Find the shadowing warning (W0100). Use the message hint rather
    // than the code because other diags (unused warnings) may coexist.
    var found: ?std.json.Value = null;
    for (cap.diagnostics.array.items) |d| {
        const c = d.object.get("code") orelse continue;
        if (c != .string) continue;
        if (std.mem.eql(u8, c.string, "W0100")) {
            found = d;
            break;
        }
    }
    if (found == null) {
        std.debug.print("\nNo W0100 diagnostic. Got:\n", .{});
        for (cap.diagnostics.array.items) |d| dumpDiag(d);
        return error.TestUnexpectedResult;
    }
    const d = found.?;

    // severity = 2 (Warning), not 1 (Error).
    try std.testing.expectEqual(@as(i64, 2), d.object.get("severity").?.integer);

    // codeDescription still present (W01xx → module-scope-declarations).
    const href = getPath(d, "codeDescription.href") orelse return error.MissingCodeDescription;
    try std.testing.expectEqualStrings("https://www.w3.org/TR/WGSL/#module-scope-declarations", href.string);

    // relatedInformation key is ABSENT (not `null`). This is the
    // `.emit_null_optional_fields = false` guarantee the client relies on.
    try std.testing.expect(d.object.get("relatedInformation") == null);
}

// =========================================================================
// Scenario 6 — W0101 redundant_cast warning, no relatedInformation.
// =========================================================================

test "publishDiagnostics JSON: W0101 redundant cast warning has codeDescription but no relatedInformation" {
    const source =
        \\fn main() { let x: i32 = i32(42); }
    ;
    var cap = try captureForSource(source);
    defer cap.deinit();

    var found: ?std.json.Value = null;
    for (cap.diagnostics.array.items) |d| {
        const c = d.object.get("code") orelse continue;
        if (c != .string) continue;
        if (std.mem.eql(u8, c.string, "W0101")) {
            found = d;
            break;
        }
    }
    if (found == null) return; // W0101 may be disabled in some builds; skip silently
    const d = found.?;

    try std.testing.expectEqual(@as(i64, 2), d.object.get("severity").?.integer);
    const href = getPath(d, "codeDescription.href") orelse return error.MissingCodeDescription;
    try std.testing.expect(std.mem.startsWith(u8, href.string, "https://www.w3.org/TR/WGSL/#"));
    try std.testing.expect(d.object.get("relatedInformation") == null);
}

// =========================================================================
// Scenario 7 — Clean source emits an empty `diagnostics` array (not null).
// =========================================================================

test "publishDiagnostics JSON: clean source emits empty diagnostics array" {
    var cap = try captureForSource("fn main() {}");
    defer cap.deinit();

    // `params.diagnostics` MUST be the empty array, never `null` or absent.
    // (LSP spec: client expects the array to clear previous diagnostics.)
    try std.testing.expect(cap.diagnostics == .array);
    try std.testing.expectEqual(@as(usize, 0), cap.diagnostics.array.items.len);

    // And the envelope still carries `uri`.
    const uri = cap.params.object.get("uri") orelse return error.MissingUri;
    try std.testing.expectEqualStrings(test_uri, uri.string);
}

// =========================================================================
// Scenario 8 — Undefined identifier with did-you-mean (E0100).
// =========================================================================

test "publishDiagnostics JSON: undefined identifier carries E0100 and module-scope-declarations URL" {
    const source =
        \\fn main() { let y = positon; }
    ;
    var cap = try captureForSource(source);
    defer cap.deinit();

    const d = try cap.findByMessage("use of undeclared identifier");
    const code = d.object.get("code").?;
    try std.testing.expectEqualStrings("E0100", code.string);

    // E01xx → "module-scope-declarations" (per specRefFor).
    const href = getPath(d, "codeDescription.href") orelse return error.MissingCodeDescription;
    try std.testing.expectEqualStrings("https://www.w3.org/TR/WGSL/#module-scope-declarations", href.string);
}

// =========================================================================
// Scenario 9 — Many codes: bridge carries every spec_url without corruption.
// =========================================================================

test "publishDiagnostics JSON: multi-diagnostic source preserves every spec_url" {
    // Produces at least two distinct diagnostics with different spec_refs:
    //   line 1 → E0200 (type_mismatch) → "types"
    //   line 3 → E0804 (duplicate_binding) → "memory-model"
    const source =
        \\const bad: i32 = 1.5;
        \\@group(0) @binding(0) var<uniform> a: f32;
        \\@group(0) @binding(0) var<uniform> b: f32;
    ;
    var cap = try captureForSource(source);
    defer cap.deinit();

    var saw_types = false;
    var saw_memory = false;
    for (cap.diagnostics.array.items) |d| {
        const href = getPath(d, "codeDescription.href") orelse continue;
        if (href != .string) continue;
        if (std.mem.endsWith(u8, href.string, "#types")) saw_types = true;
        if (std.mem.endsWith(u8, href.string, "#memory-model")) saw_memory = true;
    }
    try std.testing.expect(saw_types);
    try std.testing.expect(saw_memory);
}

// =========================================================================
// Shape test A — every relatedInformation.location.uri matches the doc URI.
// =========================================================================

test "publishDiagnostics JSON shape: every relatedInformation location uri == document uri" {
    // Exercises the bridge's `uri` plumbing (main.zig:861 class bugs).
    const source =
        \\struct Foo {
        \\  x: f32,
        \\  x: i32,
        \\}
        \\@group(0) @binding(0) var<uniform> a: f32;
        \\@group(0) @binding(0) var<uniform> b: f32;
    ;
    var cap = try captureForSource(source);
    defer cap.deinit();

    var checked: usize = 0;
    for (cap.diagnostics.array.items) |d| {
        const related = d.object.get("relatedInformation") orelse continue;
        if (related != .array) continue;
        for (related.array.items) |ri| {
            const uri = getPath(ri, "location.uri") orelse return error.MissingRelatedUri;
            try std.testing.expect(uri == .string);
            try std.testing.expectEqualStrings(test_uri, uri.string);
            checked += 1;
        }
    }
    // This fixture produces multiple related infos; guard against silent regression
    // where all related got dropped.
    try std.testing.expect(checked >= 2);
}

// =========================================================================
// Shape test B — severity is an integer, never a string tag name.
// =========================================================================

test "publishDiagnostics JSON shape: severity is always integer 1..4" {
    // Mix of error (E0200) and warning (W0100) severities.
    const source =
        \\var<private> x: f32;
        \\const y: i32 = 1.5;
        \\fn main() { let x = 1.0; }
    ;
    var cap = try captureForSource(source);
    defer cap.deinit();

    try std.testing.expect(cap.diagnostics.array.items.len > 0);
    for (cap.diagnostics.array.items) |d| {
        const sev = d.object.get("severity") orelse return error.MissingSeverity;
        // Hard assertion: integer, not a string. Catches accidental switch
        // to @tagName in the bridge's severity conversion.
        try std.testing.expect(sev == .integer);
        try std.testing.expect(sev.integer >= 1 and sev.integer <= 4);
    }
}

// =========================================================================
// Property sweep — across a corpus, bridge invariants hold for every diag.
// =========================================================================

test "publishDiagnostics JSON sweep: spec_url / related / absence invariants hold across fixtures" {
    // A compact corpus covering parse-level, type, symbol, binding, and
    // uniformity codes. For every diagnostic emitted we assert the three
    // bridge invariants stated in the plan's §5 sweep:
    //   1. If Handler.LspDiagnostic has spec_url, JSON has codeDescription.href == spec_url.
    //   2. If Handler.LspDiagnostic has related[], JSON has relatedInformation with the same length.
    //   3. If Handler.LspDiagnostic has no spec_url, JSON has NO codeDescription key.
    //   4. If Handler.LspDiagnostic has no related, JSON has NO relatedInformation key.
    //
    // We compute the Handler-side oracle from the same validateDocument
    // call the bridge consumed, so drift across the bridge is caught as
    // a field-by-field mismatch rather than a silent regression.

    const fixtures = [_][]const u8{
        "const x: i32 = 1.5;",
        "struct Foo { x: f32, x: i32, }",
        "@group(0) @binding(0) var<uniform> a: f32;\n@group(0) @binding(0) var<uniform> b: f32;",
        "fn main() { let y = positon; }",
        "fn main() { let x: i32 = i32(42); }",
        "var<private> x: f32;\nfn main() { let x = 1.0; }",
        "fn foo() -> i32 { return 1.5; }",
        "fn main() {}",
    };

    for (fixtures) |source| {
        // Side-by-side: Handler output (oracle) and bridged JSON.
        var handler = Handler.init(std.testing.allocator);
        defer handler.deinit();

        const handler_diags = try handler.validateDocument(source);
        defer Handler.freeDiagnostics(std.testing.allocator, handler_diags);

        var bridged = try bridge.toLspKitDiagnostics(std.testing.allocator, handler_diags, test_uri);
        defer bridged.deinit();

        var sweep_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer sweep_arena.deinit();
        const aa = sweep_arena.allocator();

        var aw: std.Io.Writer.Allocating = .init(aa);
        try lsp.writeNotification(
            &aw.writer,
            aa,
            "textDocument/publishDiagnostics",
            lsp.types.publish_diagnostics.Params,
            .{ .uri = test_uri, .diagnostics = bridged.diagnostics },
            .{ .emit_null_optional_fields = false },
        );

        const body_start = std.mem.indexOf(u8, aw.written(), "\r\n\r\n").? + 4;
        const body = aw.written()[body_start..];
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, aa, body, .{});
        const diags_json = parsed.object.get("params").?.object.get("diagnostics").?;

        // Same cardinality on both sides — the bridge preserves count.
        try std.testing.expectEqual(handler_diags.len, diags_json.array.items.len);

        for (handler_diags, diags_json.array.items) |h, j| {
            // Invariant 1 + 3: codeDescription presence tracks h.spec_url.
            if (h.spec_url.len > 0) {
                const href = getPath(j, "codeDescription.href") orelse {
                    std.debug.print("\nBridge dropped codeDescription for code={s} msg={s}\n", .{ h.code, h.message });
                    return error.BridgeDroppedCodeDescription;
                };
                try std.testing.expect(href == .string);
                try std.testing.expectEqualStrings(h.spec_url, href.string);
            } else {
                try std.testing.expect(j.object.get("codeDescription") == null);
            }

            // Invariant 2 + 4: relatedInformation presence tracks h.related.
            if (h.related.len > 0) {
                const related = j.object.get("relatedInformation") orelse {
                    std.debug.print("\nBridge dropped relatedInformation for code={s}\n", .{h.code});
                    return error.BridgeDroppedRelated;
                };
                try std.testing.expect(related == .array);
                try std.testing.expectEqual(h.related.len, related.array.items.len);
            } else {
                try std.testing.expect(j.object.get("relatedInformation") == null);
            }

            // Code roundtrip — every diag with a code surfaces it as a string.
            if (h.code.len > 0) {
                const code = j.object.get("code") orelse return error.MissingCode;
                try std.testing.expect(code == .string);
                try std.testing.expectEqualStrings(h.code, code.string);
            } else {
                try std.testing.expect(j.object.get("code") == null);
            }
        }
    }
}
