//! WGSL Language Server — WASM entry point.
//!
//! Exports C-ABI functions for JavaScript interop. The JS side sends
//! JSON-RPC messages via wgslender_lsp_send() and polls responses via
//! wgslender_lsp_recv(). All WGSL-specific logic lives in Handler.zig
//! (shared with the native entry point).
//!
//! JS usage:
//!   // Send a JSON-RPC message:
//!   const encoded = encoder.encode(jsonString);
//!   const ptr = wasm.wgslender_lsp_alloc(encoded.length);
//!   new Uint8Array(wasm.memory.buffer, ptr, encoded.length).set(encoded);
//!   wasm.wgslender_lsp_send(ptr, encoded.length);
//!   // Read response(s):
//!   while (true) {
//!     const rptr = wasm.wgslender_lsp_recv();
//!     if (!rptr) break;
//!     const len = new DataView(wasm.memory.buffer).getUint32(rptr, true);
//!     const msg = decoder.decode(new Uint8Array(wasm.memory.buffer, rptr + 4, len));
//!     wasm.wgslender_lsp_dealloc(rptr, len + 4);
//!     // msg is a JSON-RPC response or notification
//!   }

const std = @import("std");
const wgslender = @import("wgslender");
const Handler = @import("Handler.zig");

const Diagnostic = wgslender.Diagnostic;
const wasm_allocator = std.heap.wasm_allocator;

// =========================================================================
// Global state
// =========================================================================

var handler: Handler = .init(wasm_allocator);
var outbox: std.ArrayListUnmanaged([]u8) = .empty;

// =========================================================================
// Exported WASM functions
// =========================================================================

export fn wgslender_lsp_alloc(len: u32) ?[*]u8 {
    const slice = wasm_allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

export fn wgslender_lsp_dealloc(ptr: [*]u8, len: u32) void {
    wasm_allocator.free(ptr[0..len]);
}

/// Send a JSON-RPC message to the server. Responses/notifications
/// are queued and retrieved via wgslender_lsp_recv().
export fn wgslender_lsp_send(msg_ptr: [*]const u8, msg_len: u32) void {
    handleMessage(msg_ptr[0..msg_len]);
}

/// Get the next outgoing message, or null if empty.
/// Returns pointer to [u32 len][u8... json].
/// Caller frees with wgslender_lsp_dealloc(ptr, len + 4).
export fn wgslender_lsp_recv() ?[*]u8 {
    if (outbox.items.len == 0) return null;
    const msg = outbox.orderedRemove(0);
    const out = wasm_allocator.alloc(u8, 4 + msg.len) catch {
        wasm_allocator.free(msg);
        return null;
    };
    std.mem.writeInt(u32, out[0..4], @intCast(msg.len), .little);
    @memcpy(out[4..][0..msg.len], msg);
    wasm_allocator.free(msg);
    return out.ptr;
}

// =========================================================================
// JSON-RPC dispatch
// =========================================================================

fn handleMessage(json: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, wasm_allocator, json, .{
        .ignore_unknown_fields = true,
        .max_value_len = null,
    }) catch return;
    defer parsed.deinit();

    const root = parsed.value.object;
    const method = switch (root.get("method") orelse return) {
        .string => |s| s,
        else => return,
    };
    const id = root.get("id");

    if (eql(method, "initialize")) {
        sendResult(id, "{\"capabilities\":" ++ Handler.capabilities_json ++ ",\"serverInfo\":{\"name\":\"wgslender-lsp\",\"version\":\"0.1.0\"}}");
    } else if (eql(method, "initialized") or eql(method, "exit")) {
        // No-op.
    } else if (eql(method, "shutdown")) {
        sendResult(id, "null");
    } else if (eql(method, "textDocument/didOpen")) {
        handleDidOpen(root);
    } else if (eql(method, "textDocument/didChange")) {
        handleDidChange(root);
    } else if (eql(method, "textDocument/didClose")) {
        handleDidClose(root);
    } else if (eql(method, "textDocument/codeAction")) {
        handleCodeAction(root, id);
    } else if (id != null) {
        sendResult(id, "null");
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// =========================================================================
// Document handlers (delegate to shared Handler)
// =========================================================================

fn handleDidOpen(root: std.json.ObjectMap) void {
    const params = root.getPtr("params") orelse return;
    const td = objGet(params, "textDocument") orelse return;
    const uri = strVal(objGet(td, "uri")) orelse return;
    const text = strVal(objGet(td, "text")) orelse return;
    const version: i32 = if (intVal(objGet(td, "version"))) |v| @intCast(v) else 0;
    handler.openDocument(uri, text, version) catch return;
    emitDiagnostics(uri);
}

fn handleDidChange(root: std.json.ObjectMap) void {
    const params = root.getPtr("params") orelse return;
    const td = objGet(params, "textDocument") orelse return;
    const uri = strVal(objGet(td, "uri")) orelse return;
    const changes = switch ((objGet(params, "contentChanges") orelse return).*) {
        .array => |a| a.items,
        else => return,
    };
    if (changes.len == 0) return;
    const text = strVal(objGet(&changes[changes.len - 1], "text")) orelse return;
    handler.changeDocument(uri, text) catch return;
    emitDiagnostics(uri);
}

fn handleDidClose(root: std.json.ObjectMap) void {
    const params = root.getPtr("params") orelse return;
    const td = objGet(params, "textDocument") orelse return;
    const uri = strVal(objGet(td, "uri")) orelse return;
    handler.closeDocument(uri);

    // Clear diagnostics.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(&buf, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"");
    Diagnostic.appendJsonEscaped(&buf, wasm_allocator, uri);
    appendStr(&buf, "\",\"diagnostics\":[]}}");
    enqueue(buf.toOwnedSlice(wasm_allocator) catch return);
}

// =========================================================================
// Code Actions
// =========================================================================

fn handleCodeAction(root: std.json.ObjectMap, id: ?std.json.Value) void {
    const params = root.getPtr("params") orelse return;
    const td = objGet(params, "textDocument") orelse return;
    const uri = strVal(objGet(td, "uri")) orelse return;

    // Extract diagnostics from context
    const context = objGet(params, "context") orelse return;
    const diag_array = switch ((objGet(context, "diagnostics") orelse return).*) {
        .array => |a| a.items,
        else => return,
    };

    const handler_diags = convertJsonDiagnostics(diag_array) orelse return;
    defer wasm_allocator.free(handler_diags);

    const actions = handler.computeCodeActions(handler_diags) catch return;
    defer Handler.freeCodeActions(wasm_allocator, actions);

    buildCodeActionJsonResponse(id, uri, actions);
}

fn convertJsonDiagnostics(diag_array: []std.json.Value) ?[]Handler.LspDiagnostic {
    const handler_diags = wasm_allocator.alloc(Handler.LspDiagnostic, diag_array.len) catch return null;

    for (diag_array, 0..) |*diag_val, i| {
        const diag_obj = objGet(diag_val, "range") orelse continue;
        const start_obj = objGet(diag_obj, "start");
        const end_obj = objGet(diag_obj, "end");

        const start_line: u32 = if (intVal(if (start_obj) |s| objGet(s, "line") else null)) |v| @intCast(v) else 0;
        const start_char: u32 = if (intVal(if (start_obj) |s| objGet(s, "character") else null)) |v| @intCast(v) else 0;
        const end_line: u32 = if (intVal(if (end_obj) |e| objGet(e, "line") else null)) |v| @intCast(v) else 0;
        const end_char: u32 = if (intVal(if (end_obj) |e| objGet(e, "character") else null)) |v| @intCast(v) else 0;

        const code_val = objGet(diag_val, "code");
        const code: []const u8 = if (code_val) |cv| (strVal(cv) orelse "") else "";

        const sev_int: u32 = if (intVal(objGet(diag_val, "severity"))) |v| @intCast(v) else 1;
        handler_diags[i] = .{
            .range = .{
                .start = .{ .line = start_line, .character = start_char },
                .end = .{ .line = end_line, .character = end_char },
            },
            .severity = switch (sev_int) {
                1 => .@"error",
                2 => .warning,
                3 => .information,
                4 => .hint,
                else => .information,
            },
            .message = strVal(objGet(diag_val, "message")) orelse "",
            .code = code,
        };
    }

    return handler_diags;
}

fn buildCodeActionJsonResponse(id: ?std.json.Value, uri: []const u8, actions: []const Handler.LspCodeAction) void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(&buf, "{\"jsonrpc\":\"2.0\",\"id\":");
    if (id) |id_val| switch (id_val) {
        .integer => |n| {
            var num_buf: [20]u8 = undefined;
            const s = std.fmt.bufPrint(&num_buf, "{d}", .{n}) catch return;
            buf.appendSlice(wasm_allocator, s) catch return;
        },
        .string => |s| {
            buf.append(wasm_allocator, '"') catch return;
            buf.appendSlice(wasm_allocator, s) catch return;
            buf.append(wasm_allocator, '"') catch return;
        },
        else => appendStr(&buf, "null"),
    } else appendStr(&buf, "null");

    appendStr(&buf, ",\"result\":[");

    for (actions, 0..) |action, ai| {
        if (ai > 0) buf.append(wasm_allocator, ',') catch {};
        appendStr(&buf, "{\"title\":\"");
        Diagnostic.appendJsonEscaped(&buf, wasm_allocator, action.title);
        appendStr(&buf, "\",\"kind\":\"quickfix\"");
        if (action.is_preferred) {
            appendStr(&buf, ",\"isPreferred\":true");
        }

        // Diagnostics array
        appendStr(&buf, ",\"diagnostics\":[{\"range\":{\"start\":{\"line\":");
        appendUint(&buf, action.diagnostic.range.start.line);
        appendStr(&buf, ",\"character\":");
        appendUint(&buf, action.diagnostic.range.start.character);
        appendStr(&buf, "},\"end\":{\"line\":");
        appendUint(&buf, action.diagnostic.range.end.line);
        appendStr(&buf, ",\"character\":");
        appendUint(&buf, action.diagnostic.range.end.character);
        appendStr(&buf, "}},\"message\":\"");
        Diagnostic.appendJsonEscaped(&buf, wasm_allocator, action.diagnostic.message);
        appendStr(&buf, "\"");
        if (action.diagnostic.code.len > 0) {
            appendStr(&buf, ",\"code\":\"");
            Diagnostic.appendJsonEscaped(&buf, wasm_allocator, action.diagnostic.code);
            appendStr(&buf, "\"");
        }
        appendStr(&buf, "}]");

        // Edit (WorkspaceEdit with changes)
        appendStr(&buf, ",\"edit\":{\"changes\":{\"");
        Diagnostic.appendJsonEscaped(&buf, wasm_allocator, uri);
        appendStr(&buf, "\":[");
        for (action.edits, 0..) |edit, ei| {
            if (ei > 0) buf.append(wasm_allocator, ',') catch {};
            appendStr(&buf, "{\"range\":{\"start\":{\"line\":");
            appendUint(&buf, edit.range.start.line);
            appendStr(&buf, ",\"character\":");
            appendUint(&buf, edit.range.start.character);
            appendStr(&buf, "},\"end\":{\"line\":");
            appendUint(&buf, edit.range.end.line);
            appendStr(&buf, ",\"character\":");
            appendUint(&buf, edit.range.end.character);
            appendStr(&buf, "}},\"newText\":\"");
            Diagnostic.appendJsonEscaped(&buf, wasm_allocator, edit.new_text);
            appendStr(&buf, "\"}");
        }
        appendStr(&buf, "]}}}");
    }

    appendStr(&buf, "]}");
    enqueue(buf.toOwnedSlice(wasm_allocator) catch return);
}

// =========================================================================
// Diagnostics (reuses Handler.validateDocument + Handler.LspDiagnostic)
// =========================================================================

fn emitDiagnostics(uri: []const u8) void {
    const source = handler.getDocumentSource(uri) orelse return;
    const diags = handler.validateDocument(source) catch return;
    defer Handler.freeDiagnostics(handler.allocator, diags);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(&buf, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"");
    Diagnostic.appendJsonEscaped(&buf, wasm_allocator, uri);
    appendStr(&buf, "\",\"diagnostics\":[");

    for (diags, 0..) |diag, i| {
        if (i > 0) buf.append(wasm_allocator, ',') catch {};
        appendStr(&buf, "{\"range\":{\"start\":{\"line\":");
        appendUint(&buf, diag.range.start.line);
        appendStr(&buf, ",\"character\":");
        appendUint(&buf, diag.range.start.character);
        appendStr(&buf, "},\"end\":{\"line\":");
        appendUint(&buf, diag.range.end.line);
        appendStr(&buf, ",\"character\":");
        appendUint(&buf, diag.range.end.character);
        appendStr(&buf, "}},\"severity\":");
        appendUint(&buf, @intFromEnum(diag.severity));
        appendStr(&buf, ",\"source\":\"wgslender\",\"message\":\"");
        Diagnostic.appendJsonEscaped(&buf, wasm_allocator, diag.message);
        appendStr(&buf, "\"");
        if (diag.code.len > 0) {
            appendStr(&buf, ",\"code\":\"");
            Diagnostic.appendJsonEscaped(&buf, wasm_allocator, diag.code);
            appendStr(&buf, "\"");
        }
        if (diag.spec_url.len > 0) {
            appendStr(&buf, ",\"codeDescription\":{\"href\":\"");
            Diagnostic.appendJsonEscaped(&buf, wasm_allocator, diag.spec_url);
            appendStr(&buf, "\"}");
        }
        if (diag.related.len > 0) {
            appendStr(&buf, ",\"relatedInformation\":[");
            for (diag.related, 0..) |rel, ri| {
                if (ri > 0) buf.append(wasm_allocator, ',') catch {};
                appendStr(&buf, "{\"location\":{\"uri\":\"");
                Diagnostic.appendJsonEscaped(&buf, wasm_allocator, uri);
                appendStr(&buf, "\",\"range\":{\"start\":{\"line\":");
                appendUint(&buf, rel.range.start.line);
                appendStr(&buf, ",\"character\":");
                appendUint(&buf, rel.range.start.character);
                appendStr(&buf, "},\"end\":{\"line\":");
                appendUint(&buf, rel.range.end.line);
                appendStr(&buf, ",\"character\":");
                appendUint(&buf, rel.range.end.character);
                appendStr(&buf, "}}},\"message\":\"");
                Diagnostic.appendJsonEscaped(&buf, wasm_allocator, rel.message);
                appendStr(&buf, "\"}");
            }
            appendStr(&buf, "]");
        }
        appendStr(&buf, "}");
    }

    appendStr(&buf, "]}}");
    enqueue(buf.toOwnedSlice(wasm_allocator) catch return);
}

// =========================================================================
// JSON-RPC helpers
// =========================================================================

fn sendResult(id: ?std.json.Value, result_json: []const u8) void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(&buf, "{\"jsonrpc\":\"2.0\",\"id\":");
    if (id) |id_val| switch (id_val) {
        .integer => |n| {
            var num_buf: [20]u8 = undefined;
            const s = std.fmt.bufPrint(&num_buf, "{d}", .{n}) catch return;
            buf.appendSlice(wasm_allocator, s) catch return;
        },
        .string => |s| {
            buf.append(wasm_allocator, '"') catch return;
            buf.appendSlice(wasm_allocator, s) catch return;
            buf.append(wasm_allocator, '"') catch return;
        },
        else => appendStr(&buf, "null"),
    } else appendStr(&buf, "null");
    appendStr(&buf, ",\"result\":");
    buf.appendSlice(wasm_allocator, result_json) catch return;
    buf.append(wasm_allocator, '}') catch return;
    enqueue(buf.toOwnedSlice(wasm_allocator) catch return);
}

fn enqueue(msg: []u8) void {
    outbox.append(wasm_allocator, msg) catch wasm_allocator.free(msg);
}

// =========================================================================
// Tiny JSON read helpers
// =========================================================================

fn objGet(val: ?*const std.json.Value, key: []const u8) ?*const std.json.Value {
    const v = val orelse return null;
    return switch (v.*) {
        .object => |obj| obj.getPtr(key),
        else => null,
    };
}

fn strVal(val: ?*const std.json.Value) ?[]const u8 {
    const v = val orelse return null;
    return switch (v.*) {
        .string => |s| s,
        else => null,
    };
}

fn intVal(val: ?*const std.json.Value) ?i64 {
    const v = val orelse return null;
    return switch (v.*) {
        .integer => |n| n,
        else => null,
    };
}

fn appendStr(buf: *std.ArrayListUnmanaged(u8), s: []const u8) void {
    buf.appendSlice(wasm_allocator, s) catch {};
}

fn appendUint(buf: *std.ArrayListUnmanaged(u8), val: u32) void {
    var num_buf: [10]u8 = undefined;
    const s = std.fmt.bufPrint(&num_buf, "{d}", .{val}) catch return;
    buf.appendSlice(wasm_allocator, s) catch {};
}
