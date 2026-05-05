//! Regression test for `publishDiagnostics` returning garbage bytes in
//! `message` and `codeDescription.href` after a `codeLens` or
//! `documentHighlight` request has been dispatched between `didOpen` and
//! a validator-error-producing `didChange`.
//!
//! Drives the Handler directly and renders diagnostics through the same
//! `lsp/diagnostic_json.zig` path the WASM transport uses, so the
//! assertions see exactly the bytes a real editor would receive on the
//! wire. Lives under `lsp/` (not `tests/`) because the test needs sibling
//! file-path imports to Handler.zig and diagnostic_json.zig — a `tests/`
//! file can't `@import("../lsp/...")` (Zig forbids file imports outside
//! the module's root path).
//!
//! Assertions are byte-strict: every byte of `message` and `href` must be
//! printable ASCII (no NULs, no bytes outside 0x20..0x7e), and the message
//! content must contain the CLI validator's exact text
//! (`'vec3f' requires 3 components`).

const std = @import("std");
const Handler = @import("Handler");
const diagnostic_json = @import("wasm/diagnostics.zig");

const uri = "test://t.wgsl";

// Valid fragment shader that compiles cleanly. The invalid form (produced
// by `editToInvalid` below) appends a fourth argument to the `vec3f(…)`
// constructor, tripping the validator's E0202.
const before: [:0]const u8 = "fn fs() -> vec3<f32> { return vec3f(0.0, 0.0, 0.0); }\n";

fn renderDiagnostics(gpa: std.mem.Allocator, h: *Handler) ![]u8 {
    const diags = try h.validateDocumentFull(uri);
    defer Handler.freeDiagnostics(gpa, diags);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);

    diagnostic_json.appendDiagnosticItems(&buf, gpa, uri, diags);
    return try buf.toOwnedSlice(gpa);
}

fn assertPrintableAscii(label: []const u8, s: []const u8) !void {
    for (s, 0..) |c, i| {
        if (c < 0x20 or c >= 0x7f) {
            std.debug.print("\n{s}: non-printable byte 0x{x:0>2} at index {d} in {d}-byte string: \"", .{ label, c, i, s.len });
            for (s) |b| {
                if (b >= 0x20 and b < 0x7f) {
                    std.debug.print("{c}", .{b});
                } else {
                    std.debug.print("\\x{x:0>2}", .{b});
                }
            }
            std.debug.print("\"\n", .{});
            return error.NonPrintableAsciiInMessage;
        }
    }
}

/// Parses the rendered diagnostics array, finds the E0202 entry, and
/// checks that its `message` is printable ASCII with the expected
/// validator text, and that `codeDescription.href` is a proper WGSL
/// spec URL.
fn assertE0202Clean(body: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{});
    try std.testing.expect(parsed == .array);

    for (parsed.array.items) |d| {
        const code = d.object.get("code") orelse continue;
        if (code != .string) continue;
        if (!std.mem.eql(u8, code.string, "E0202")) continue;

        const msg_v = d.object.get("message") orelse return error.MissingMessage;
        try std.testing.expect(msg_v == .string);
        try assertPrintableAscii("message", msg_v.string);
        try std.testing.expect(std.mem.indexOf(u8, msg_v.string, "requires ") != null);
        try std.testing.expect(std.mem.indexOf(u8, msg_v.string, " components") != null);

        const code_desc = d.object.get("codeDescription") orelse return error.MissingCodeDescription;
        const href_v = code_desc.object.get("href") orelse return error.MissingHref;
        try std.testing.expect(href_v == .string);
        try assertPrintableAscii("codeDescription.href", href_v.string);
        try std.testing.expect(std.mem.startsWith(u8, href_v.string, "https://www.w3.org/TR/WGSL/#"));
        return;
    }
    std.debug.print("\nNo E0202 diagnostic found. Got {d} diagnostic(s). Raw payload:\n{s}\n", .{ parsed.array.items.len, body });
    return error.E0202NotFound;
}

/// Flip the valid `vec3f(0.0, 0.0, 0.0)` into the invalid 4-arg form by
/// inserting `, 0.0` just before the closing `)` of the call.
fn editToInvalid(h: *Handler) !void {
    const needle = "0.0);";
    const close_idx = std.mem.indexOf(u8, before, needle).? + "0.0".len;
    const pos = Handler.offsetToLspPosition(before, @intCast(close_idx)).?;
    try h.changeDocumentIncremental(uri, .{
        .start = pos,
        .end = pos,
    }, ", 0.0");
}

test "no intermediate request: publishDiagnostics after edit has clean message" {
    const gpa = std.testing.allocator;
    var h = Handler.init(gpa);
    defer h.deinit();

    try h.openDocument(uri, before, 1);
    {
        const body = try renderDiagnostics(gpa, &h);
        defer gpa.free(body);
    }

    try editToInvalid(&h);

    const body = try renderDiagnostics(gpa, &h);
    defer gpa.free(body);
    try assertE0202Clean(body);
}

test "after codeLens: publishDiagnostics after edit has clean message" {
    const gpa = std.testing.allocator;
    var h = Handler.init(gpa);
    defer h.deinit();

    try h.openDocument(uri, before, 1);

    const lenses = try h.computeCodeLens(uri);
    defer {
        for (lenses) |l| gpa.free(l.title);
        gpa.free(lenses);
    }

    try editToInvalid(&h);

    const body = try renderDiagnostics(gpa, &h);
    defer gpa.free(body);
    try assertE0202Clean(body);
}

test "after documentHighlight: publishDiagnostics after edit has clean message" {
    const gpa = std.testing.allocator;
    var h = Handler.init(gpa);
    defer h.deinit();

    try h.openDocument(uri, before, 1);

    // Highlight the `fs` identifier. Offset of `f` in "fn fs(" is 3.
    const highlights = try h.computeDocumentHighlight(uri, .{ .line = 0, .character = 3 });
    if (highlights) |hs| gpa.free(hs);

    try editToInvalid(&h);

    const body = try renderDiagnostics(gpa, &h);
    defer gpa.free(body);
    try assertE0202Clean(body);
}

test "after codeLens + didClose + didOpen: publishDiagnostics is still clean" {
    const gpa = std.testing.allocator;
    var h = Handler.init(gpa);
    defer h.deinit();

    try h.openDocument(uri, before, 1);

    const lenses = try h.computeCodeLens(uri);
    defer {
        for (lenses) |l| gpa.free(l.title);
        gpa.free(lenses);
    }

    h.closeDocument(uri);
    try h.openDocument(uri, before, 2);

    try editToInvalid(&h);

    const body = try renderDiagnostics(gpa, &h);
    defer gpa.free(body);
    try assertE0202Clean(body);
}

// Full-text didChange path (the WASM handler's non-incremental branch).
test "after codeLens + full-text didChange: publishDiagnostics is clean" {
    const gpa = std.testing.allocator;
    var h = Handler.init(gpa);
    defer h.deinit();

    try h.openDocument(uri, before, 1);

    const lenses = try h.computeCodeLens(uri);
    defer {
        for (lenses) |l| gpa.free(l.title);
        gpa.free(lenses);
    }

    const after: []const u8 = "fn fs() -> vec3<f32> { return vec3f(0.0, 0.0, 0.0, 0.0); }\n";
    try h.changeDocument(uri, after);

    const body = try renderDiagnostics(gpa, &h);
    defer gpa.free(body);
    try assertE0202Clean(body);
}

// Shader with @group/@binding + an entry point so computeCodeLens exercises
// the `collectBindingSummary` branch, which dupe-shares one buffer across
// multiple CodeLensInfo entries when multiple entry points are present.
const with_bindings_before: [:0]const u8 =
    \\@group(0) @binding(0) var<uniform> u: vec4<f32>;
    \\@group(0) @binding(1) var<storage, read> s: array<f32>;
    \\@fragment fn fs() -> @location(0) vec4<f32> {
    \\    return vec4f(u.x, 0.0, 0.0, 1.0);
    \\}
    \\@fragment fn fs2() -> @location(0) vec4<f32> {
    \\    return vec4f(u.y, 0.0, 0.0, 1.0);
    \\}
    \\
;

test "after codeLens on binding+multi-entry-point shader: publishDiagnostics is clean" {
    const gpa = std.testing.allocator;
    var h = Handler.init(gpa);
    defer h.deinit();

    try h.openDocument(uri, with_bindings_before, 1);

    const lenses = try h.computeCodeLens(uri);
    defer {
        for (lenses) |l| gpa.free(l.title);
        gpa.free(lenses);
    }

    // Flip `vec4f(u.x, ...)` into an invalid 5-arg form to trip E0202.
    const close_idx = std.mem.indexOf(u8, with_bindings_before, "1.0);").? + "1.0".len;
    const pos = Handler.offsetToLspPosition(with_bindings_before, @intCast(close_idx)).?;
    try h.changeDocumentIncremental(uri, .{
        .start = pos,
        .end = pos,
    }, ", 0.0");

    const body = try renderDiagnostics(gpa, &h);
    defer gpa.free(body);
    try assertE0202Clean(body);
}

// Single-entry-point + bindings — matches the original repro shader shape
// (prelude with @group/@binding declarations plus one fragment shader).
const with_bindings_single: [:0]const u8 =
    \\@group(0) @binding(0) var<uniform> u: vec4<f32>;
    \\@fragment fn fs() -> @location(0) vec4<f32> {
    \\    return vec3f(u.x, 0.0, 0.0);
    \\}
    \\
;

test "after codeLens on binding+single-entry-point shader: publishDiagnostics is clean" {
    const gpa = std.testing.allocator;
    var h = Handler.init(gpa);
    defer h.deinit();

    try h.openDocument(uri, with_bindings_single, 1);

    const lenses = try h.computeCodeLens(uri);
    defer {
        for (lenses) |l| gpa.free(l.title);
        gpa.free(lenses);
    }

    // Flip `vec3f(u.x, 0.0, 0.0)` to 4 args → E0202.
    const close_idx = std.mem.indexOf(u8, with_bindings_single, "0.0);").? + "0.0".len;
    const pos = Handler.offsetToLspPosition(with_bindings_single, @intCast(close_idx)).?;
    try h.changeDocumentIncremental(uri, .{
        .start = pos,
        .end = pos,
    }, ", 0.0");

    const body = try renderDiagnostics(gpa, &h);
    defer gpa.free(body);
    try assertE0202Clean(body);
}

// didOpen called twice on the same URI without an intervening close is the
// handler path with a missing `invalidateAnalysisAt` — potential leaked
// arena + stale pointers.
test "after codeLens + didOpen same-uri (no close) + edit: publishDiagnostics is clean" {
    const gpa = std.testing.allocator;
    var h = Handler.init(gpa);
    defer h.deinit();

    try h.openDocument(uri, before, 1);

    const lenses = try h.computeCodeLens(uri);
    defer {
        for (lenses) |l| gpa.free(l.title);
        gpa.free(lenses);
    }

    // Same URI, no close — openDocument takes the `found_existing` branch.
    try h.openDocument(uri, before, 2);

    try editToInvalid(&h);

    const body = try renderDiagnostics(gpa, &h);
    defer gpa.free(body);
    try assertE0202Clean(body);
}
