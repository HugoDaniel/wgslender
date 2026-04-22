//! JSON serialization for `Handler.LspDiagnostic[]`.
//!
//! Shared between the WASM push path (`publishDiagnostics` notification)
//! and the WASM pull path (`textDocument/diagnostic` Full report). Both
//! need the same `items[]` byte-for-byte; only the envelope differs.
//!
//! The native transport does not need this helper — lsp-kit's type-driven
//! writer handles serialization from `lsp.types.Diagnostic`.

const std = @import("std");
const Handler = @import("Handler.zig");
const wgslender = @import("wgslender");

const Diagnostic = wgslender.Diagnostic;

/// Append the `[{…}, …]` diagnostic array to `buf`. Writes the enclosing
/// brackets. `uri` is attached as `relatedInformation[].location.uri`
/// (WGSL diagnostics are always intra-document).
///
/// OOM during sub-field allocation (escape scratch buffers) is swallowed
/// per-field — the rest of the diagnostic still reaches the client. The
/// only surfaceable error is OOM on the outer buf writes, which callers
/// already ignore in the WASM transport.
pub fn appendDiagnosticItems(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    uri: []const u8,
    diags: []const Handler.LspDiagnostic,
) void {
    buf.append(allocator, '[') catch return;
    for (diags, 0..) |diag, i| {
        if (i > 0) buf.append(allocator, ',') catch {};
        appendOne(buf, allocator, uri, diag);
    }
    buf.append(allocator, ']') catch return;
}

fn appendOne(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    uri: []const u8,
    diag: Handler.LspDiagnostic,
) void {
    appendStr(buf, allocator, "{\"range\":{\"start\":{\"line\":");
    appendUint(buf, allocator, diag.range.start.line);
    appendStr(buf, allocator, ",\"character\":");
    appendUint(buf, allocator, diag.range.start.character);
    appendStr(buf, allocator, "},\"end\":{\"line\":");
    appendUint(buf, allocator, diag.range.end.line);
    appendStr(buf, allocator, ",\"character\":");
    appendUint(buf, allocator, diag.range.end.character);
    appendStr(buf, allocator, "}},\"severity\":");
    appendUint(buf, allocator, @intFromEnum(diag.severity));
    appendStr(buf, allocator, ",\"source\":\"wgslender\",\"message\":\"");
    Diagnostic.appendJsonEscaped(buf, allocator, diag.message) catch {};
    appendStr(buf, allocator, "\"");
    if (diag.code.len > 0) {
        appendStr(buf, allocator, ",\"code\":\"");
        Diagnostic.appendJsonEscaped(buf, allocator, diag.code) catch {};
        appendStr(buf, allocator, "\"");
    }
    if (diag.spec_url.len > 0) {
        appendStr(buf, allocator, ",\"codeDescription\":{\"href\":\"");
        Diagnostic.appendJsonEscaped(buf, allocator, diag.spec_url) catch {};
        appendStr(buf, allocator, "\"}");
    }
    if (diag.related.len > 0) {
        appendStr(buf, allocator, ",\"relatedInformation\":[");
        for (diag.related, 0..) |rel, ri| {
            if (ri > 0) buf.append(allocator, ',') catch {};
            appendStr(buf, allocator, "{\"location\":{\"uri\":\"");
            Diagnostic.appendJsonEscaped(buf, allocator, uri) catch {};
            appendStr(buf, allocator, "\",\"range\":{\"start\":{\"line\":");
            appendUint(buf, allocator, rel.range.start.line);
            appendStr(buf, allocator, ",\"character\":");
            appendUint(buf, allocator, rel.range.start.character);
            appendStr(buf, allocator, "},\"end\":{\"line\":");
            appendUint(buf, allocator, rel.range.end.line);
            appendStr(buf, allocator, ",\"character\":");
            appendUint(buf, allocator, rel.range.end.character);
            appendStr(buf, allocator, "}}},\"message\":\"");
            Diagnostic.appendJsonEscaped(buf, allocator, rel.message) catch {};
            appendStr(buf, allocator, "\"}");
        }
        appendStr(buf, allocator, "]");
    }
    if (diag.tags.len > 0) {
        appendStr(buf, allocator, ",\"tags\":[");
        for (diag.tags, 0..) |tag, ti| {
            if (ti > 0) buf.append(allocator, ',') catch {};
            appendUint(buf, allocator, @intFromEnum(tag));
        }
        appendStr(buf, allocator, "]");
    }
    buf.append(allocator, '}') catch return;
}

inline fn appendStr(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, s: []const u8) void {
    buf.appendSlice(allocator, s) catch {};
}

inline fn appendUint(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, val: u32) void {
    var num_buf: [10]u8 = undefined;
    const s = std.fmt.bufPrint(&num_buf, "{d}", .{val}) catch return;
    buf.appendSlice(allocator, s) catch {};
}
