//! Parity harness: `lspkit/diagnostics.zig` (native, lsp-kit-driven JSON
//! serializer) and `wire/diagnostics.zig` (manual JSON encoder used by
//! the WASM transport) must produce byte-equivalent diagnostic JSON for
//! every `QuickFixHint` variant. Without this guard the two transports
//! could silently diverge on the `data` field shape — VS Code tolerates
//! unknown `data`, but third-party clients may not.

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");
const lspkit = @import("lspkit");
const wire = @import("wire");
const wgslender = @import("wgslender");
const helpers = @import("lsp_parity_helpers.zig");

const Diagnostic = wgslender.Diagnostic;

const expectEqualJson = helpers.expectEqualJson;

const test_uri = "test://parity.wgsl";

/// Encode `diags` via `lsp.writeNotification` + `lspkit/diagnostics.zig`.
/// Returns the parsed `params.diagnostics` array on `arena`.
fn encodeViaLspKit(arena: std.mem.Allocator, diags: []const Handler.LspDiagnostic) !std.json.Value {
    const bridged = try lspkit.diagnostics.toLspKitDiagnosticsBorrowed(arena, diags, test_uri);
    var aw: std.Io.Writer.Allocating = .init(arena);
    try lsp.writeNotification(
        &aw.writer,
        arena,
        "textDocument/publishDiagnostics",
        lsp.types.publish_diagnostics.Params,
        .{ .uri = test_uri, .diagnostics = bridged.diagnostics },
        .{ .emit_null_optional_fields = false },
    );

    const full = aw.written();
    const sep = "\r\n\r\n";
    const sep_idx = std.mem.indexOf(u8, full, sep) orelse return error.MalformedEnvelope;
    const body = full[sep_idx + sep.len ..];

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    const params = parsed.object.get("params") orelse return error.MissingParams;
    return params.object.get("diagnostics") orelse return error.MissingDiagnostics;
}

/// Encode `diags` via `wire/diagnostics.zig`. Returns the parsed array.
fn encodeViaWire(arena: std.mem.Allocator, diags: []const Handler.LspDiagnostic) !std.json.Value {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire.diagnostics.appendDiagnosticItems(&buf, arena, test_uri, diags);
    return std.json.parseFromSliceLeaky(std.json.Value, arena, buf.items, .{});
}

fn assertParity(diag: Handler.LspDiagnostic) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const diags = [_]Handler.LspDiagnostic{diag};
    const a = try encodeViaLspKit(aa, &diags);
    const b = try encodeViaWire(aa, &diags);
    try expectEqualJson(a, b);
}

const base_range: Handler.Range = .{
    .start = .{ .line = 0, .character = 0 },
    .end = .{ .line = 0, .character = 1 },
};

test "parity: minimal diagnostic (no data)" {
    try assertParity(.{
        .range = base_range,
        .severity = .@"error",
        .message = "x",
    });
}

test "parity: did_you_mean" {
    try assertParity(.{
        .range = base_range,
        .severity = .@"error",
        .message = "x",
        .data = .{ .did_you_mean = "position" },
    });
}

test "parity: type_mismatch" {
    try assertParity(.{
        .range = base_range,
        .severity = .@"error",
        .message = "x",
        .data = .{ .type_mismatch = .{ .actual = "i32", .expected = "f32" } },
    });
}

test "parity: duplicate_location" {
    try assertParity(.{
        .range = base_range,
        .severity = .@"error",
        .message = "x",
        .data = .{ .duplicate_location = 7 },
    });
}

test "parity: unused_symbol" {
    try assertParity(.{
        .range = base_range,
        .severity = .warning,
        .message = "x",
        .data = .{ .unused_symbol = "old_name" },
    });
}

test "parity: feature_not_enabled" {
    try assertParity(.{
        .range = base_range,
        .severity = .@"error",
        .message = "x",
        .data = .{ .feature_not_enabled = "f16" },
    });
}

test "parity: vertex_missing_builtin_position" {
    try assertParity(.{
        .range = base_range,
        .severity = .@"error",
        .message = "x",
        .data = .vertex_missing_builtin_position,
    });
}

test "parity: code + spec_url + tags + related" {
    const related = [_]Handler.LspRelatedInfo{.{
        .range = .{ .start = .{ .line = 3, .character = 4 }, .end = .{ .line = 3, .character = 5 } },
        .message = "first declared here",
    }};
    const tags = [_]Handler.DiagnosticTag{ .unnecessary, .deprecated };
    try assertParity(.{
        .range = base_range,
        .severity = .hint,
        .message = "dead",
        .code = "W0001",
        .spec_url = "https://www.w3.org/TR/WGSL/#types",
        .related = &related,
        .tags = &tags,
    });
}
