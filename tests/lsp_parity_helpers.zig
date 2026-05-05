//! Shared utilities for the LSP transport parity harness. Every
//! `tests/lsp_*_parity_test.zig` file imports these to assert that the
//! native (lsp-kit-driven) and WASM (manual-JSON) encoders emit
//! byte-equivalent JSON for the same logical payload.
//!
//! Two responsibilities:
//!   1. Result-payload parity (`writeAndParseResult` + `jsonEql`):
//!      drive `lsp.writeResponse` once, parse the resulting envelope's
//!      `result` field, then deep-compare against the wire-side parsed
//!      JSON. Used by the four pre-existing parity tests.
//!   2. Error-envelope parity (`writeAndParseErrorEnvelope` +
//!      `buildAndParseWasmErrorEnvelope` + `expectEqualErrorCode`):
//!      reproduce both transports' JSON-RPC error shapes so the
//!      executeCommand-error parity test can assert numeric code
//!      parity while still locking each side's `message` independently.

const std = @import("std");
const lsp = @import("lsp");
const wire = @import("wire");

// =========================================================================
// Result-payload helpers (used by the 4 happy-path parity tests)
// =========================================================================

pub fn expectEqualJson(want: std.json.Value, got: std.json.Value) !void {
    if (!jsonEql(want, got)) {
        std.debug.print("\nJSON mismatch.\n", .{});
        return error.JsonMismatch;
    }
}

pub fn jsonEql(a: std.json.Value, b: std.json.Value) bool {
    if (@as(std.meta.Tag(std.json.Value), a) != @as(std.meta.Tag(std.json.Value), b)) return false;
    return switch (a) {
        .null => true,
        .bool => |x| x == b.bool,
        .integer => |x| x == b.integer,
        .float => |x| x == b.float,
        .number_string => |x| std.mem.eql(u8, x, b.number_string),
        .string => |x| std.mem.eql(u8, x, b.string),
        .array => |arr| blk: {
            if (arr.items.len != b.array.items.len) break :blk false;
            for (arr.items, b.array.items) |x, y| if (!jsonEql(x, y)) break :blk false;
            break :blk true;
        },
        .object => |obj| blk: {
            if (obj.count() != b.object.count()) break :blk false;
            var it = obj.iterator();
            while (it.next()) |entry| {
                const other = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!jsonEql(entry.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}

/// Drive `lsp.writeResponse` for `result`, strip the JSON-RPC envelope,
/// and return the parsed `result` field on `arena`.
pub fn writeAndParseResult(
    arena: std.mem.Allocator,
    comptime Result: type,
    result: Result,
) !std.json.Value {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try lsp.writeResponse(
        &aw.writer,
        arena,
        .{ .number = 0 },
        Result,
        result,
        .{ .emit_null_optional_fields = false },
    );

    const full = aw.written();
    const sep = "\r\n\r\n";
    const sep_idx = std.mem.indexOf(u8, full, sep) orelse return error.MalformedEnvelope;
    const body = full[sep_idx + sep.len ..];

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    return parsed.object.get("result") orelse return error.MissingResult;
}

// =========================================================================
// Error-envelope helpers (used by lsp_workspace_error_parity_test)
// =========================================================================

/// Drive `lsp.writeErrorResponse` for `(code, message)`, strip the
/// JSON-RPC envelope, and return the parsed `error` field on `arena`.
/// Mirrors basic_server's call site (`emit_null_optional_fields = false`)
/// so the optional `data` field is omitted, matching the WASM transport.
pub fn writeAndParseErrorEnvelope(
    arena: std.mem.Allocator,
    code: lsp.JsonRPCMessage.Response.Error.Code,
    message: []const u8,
) !std.json.Value {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try lsp.writeErrorResponse(
        &aw.writer,
        arena,
        .{ .number = 0 },
        .{ .code = code, .message = message },
        .{ .emit_null_optional_fields = false },
    );

    const full = aw.written();
    const sep = "\r\n\r\n";
    const sep_idx = std.mem.indexOf(u8, full, sep) orelse return error.MalformedEnvelope;
    const body = full[sep_idx + sep.len ..];

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    return parsed.object.get("error") orelse return error.MissingError;
}

/// Reproduce `lsp/wasm.zig::sendErrorCode`'s emission via the same
/// `wire.primitives` helpers, then parse and return the `error` field
/// on `arena`. Capturing the real `sendErrorCode` would require pulling
/// in `wasm_allocator` and stubbing `enqueue`; reproducing the format
/// is cleaner and tests the JSON shape the WASM transport will write.
pub fn buildAndParseWasmErrorEnvelope(
    arena: std.mem.Allocator,
    code: i32,
    message: []const u8,
) !std.json.Value {
    const json = wire.primitives;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    json.appendStr(&buf, arena, "{\"jsonrpc\":\"2.0\",\"id\":");
    json.appendId(&buf, arena, .{ .integer = 0 });
    json.appendStr(&buf, arena, ",\"error\":{\"code\":");
    var num_buf: [12]u8 = undefined;
    const s = try std.fmt.bufPrint(&num_buf, "{d}", .{code});
    try buf.appendSlice(arena, s);
    json.appendStr(&buf, arena, ",\"message\":\"");
    for (message) |c| {
        if (c == '"' or c == '\\') try buf.append(arena, '\\');
        try buf.append(arena, c);
    }
    json.appendStr(&buf, arena, "\"}}");

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, buf.items, .{});
    return parsed.object.get("error") orelse return error.MissingError;
}

/// Assert that two parsed `error` objects share the same numeric `code`.
/// Messages are documented to differ between transports (native uses
/// `@errorName(err)`, wasm uses hardcoded English) so are NOT compared
/// here — each side's message is locked separately by the caller.
pub fn expectEqualErrorCode(want: std.json.Value, got: std.json.Value) !void {
    const want_code = want.object.get("code") orelse return error.MissingCode;
    const got_code = got.object.get("code") orelse return error.MissingCode;
    try std.testing.expectEqual(want_code.integer, got_code.integer);
}

// Internal smoke tests live in `tests/lsp_parity_helpers_test.zig` so
// they don't run inside every parity-test binary that imports this file.
