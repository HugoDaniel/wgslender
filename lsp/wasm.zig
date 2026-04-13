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
        sendResult(id, "{\"capabilities\":" ++ Handler.capabilities_json ++ ",\"serverInfo\":{\"name\":\"wgslender-lsp\",\"version\":\"1.0.0\"}}");
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
    } else if (eql(method, "textDocument/hover")) {
        handleHover(root, id);
    } else if (eql(method, "textDocument/definition")) {
        handleDefinition(root, id);
    } else if (eql(method, "textDocument/references")) {
        handleReferences(root, id);
    } else if (eql(method, "textDocument/documentHighlight")) {
        handleDocumentHighlight(root, id);
    } else if (eql(method, "textDocument/rename")) {
        handleRename(root, id);
    } else if (eql(method, "textDocument/prepareRename")) {
        handlePrepareRename(root, id);
    } else if (eql(method, "textDocument/completion")) {
        handleCompletion(root, id);
    } else if (eql(method, "textDocument/signatureHelp")) {
        handleSignatureHelp(root, id);
    } else if (eql(method, "textDocument/documentSymbol")) {
        handleDocumentSymbol(root, id);
    } else if (eql(method, "textDocument/foldingRange")) {
        handleFoldingRange(root, id);
    } else if (eql(method, "textDocument/typeDefinition")) {
        handleTypeDefinition(root, id);
    } else if (eql(method, "textDocument/inlayHint")) {
        handleInlayHint(root, id);
    } else if (eql(method, "textDocument/codeLens")) {
        handleCodeLens(root, id);
    } else if (eql(method, "textDocument/formatting")) {
        handleFormatting(root, id);
    } else if (eql(method, "textDocument/semanticTokens/full")) {
        handleSemanticTokens(root, id);
    } else if (eql(method, "textDocument/selectionRange")) {
        handleSelectionRange(root, id);
    } else if (eql(method, "textDocument/prepareCallHierarchy")) {
        handlePrepareCallHierarchy(root, id);
    } else if (eql(method, "callHierarchy/incomingCalls")) {
        handleIncomingCalls(root, id);
    } else if (eql(method, "callHierarchy/outgoingCalls")) {
        handleOutgoingCalls(root, id);
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

    // Apply each change (may be incremental or full)
    for (changes) |*change_val| {
        const change = objGet(change_val, "text") orelse continue;
        const text = strVal(change) orelse continue;
        const range_val = objGet(change_val, "range");
        if (range_val) |rv| {
            // Incremental change with range
            const start_obj = objGet(rv, "start");
            const end_obj = objGet(rv, "end");
            const start_line: u32 = if (intVal(if (start_obj) |s| objGet(s, "line") else null)) |v| @intCast(v) else continue;
            const start_char: u32 = if (intVal(if (start_obj) |s| objGet(s, "character") else null)) |v| @intCast(v) else continue;
            const end_line: u32 = if (intVal(if (end_obj) |e| objGet(e, "line") else null)) |v| @intCast(v) else continue;
            const end_char: u32 = if (intVal(if (end_obj) |e| objGet(e, "character") else null)) |v| @intCast(v) else continue;
            handler.changeDocumentIncremental(uri, .{
                .start = .{ .line = start_line, .character = start_char },
                .end = .{ .line = end_line, .character = end_char },
            }, text) catch continue;
        } else {
            // Full document replacement
            handler.changeDocument(uri, text) catch continue;
        }
    }
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
    Diagnostic.appendJsonEscaped(&buf, wasm_allocator, uri) catch return;
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
        Diagnostic.appendJsonEscaped(&buf, wasm_allocator, action.title) catch return;
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
        Diagnostic.appendJsonEscaped(&buf, wasm_allocator, action.diagnostic.message) catch return;
        appendStr(&buf, "\"");
        if (action.diagnostic.code.len > 0) {
            appendStr(&buf, ",\"code\":\"");
            Diagnostic.appendJsonEscaped(&buf, wasm_allocator, action.diagnostic.code) catch return;
            appendStr(&buf, "\"");
        }
        appendStr(&buf, "}]");

        // Edit (WorkspaceEdit with changes)
        appendStr(&buf, ",\"edit\":{\"changes\":{\"");
        Diagnostic.appendJsonEscaped(&buf, wasm_allocator, uri) catch return;
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
            Diagnostic.appendJsonEscaped(&buf, wasm_allocator, edit.new_text) catch return;
            appendStr(&buf, "\"}");
        }
        appendStr(&buf, "]}}}");
    }

    appendStr(&buf, "]}");
    enqueue(buf.toOwnedSlice(wasm_allocator) catch return);
}

// =========================================================================
// Hover, Definition, References, Rename (WASM handlers)
// =========================================================================

fn extractUriAndPosition(root: std.json.ObjectMap) ?struct { uri: []const u8, line: u32, char: u32 } {
    const params = root.getPtr("params") orelse return null;
    const td = objGet(params, "textDocument") orelse return null;
    const uri = strVal(objGet(td, "uri")) orelse return null;
    const pos = objGet(params, "position") orelse return null;
    const line: u32 = if (intVal(objGet(pos, "line"))) |v| @intCast(v) else return null;
    const char: u32 = if (intVal(objGet(pos, "character"))) |v| @intCast(v) else return null;
    return .{ .uri = uri, .line = line, .char = char };
}

fn handleHover(root: std.json.ObjectMap, id: ?std.json.Value) void {
    const p = extractUriAndPosition(root) orelse return sendResult(id, "null");
    const result = handler.computeHover(p.uri, .{ .line = p.line, .character = p.char }) catch return sendResult(id, "null");
    const r = result orelse return sendResult(id, "null");
    defer handler.gpa.free(r.contents);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(&buf, "{\"contents\":{\"kind\":\"markdown\",\"value\":\"");
    Diagnostic.appendJsonEscaped(&buf, wasm_allocator, r.contents) catch return;
    appendStr(&buf, "\"},\"range\":{\"start\":{\"line\":");
    appendUint(&buf, r.range.start.line);
    appendStr(&buf, ",\"character\":");
    appendUint(&buf, r.range.start.character);
    appendStr(&buf, "},\"end\":{\"line\":");
    appendUint(&buf, r.range.end.line);
    appendStr(&buf, ",\"character\":");
    appendUint(&buf, r.range.end.character);
    appendStr(&buf, "}}}");
    sendResult(id, buf.toOwnedSlice(wasm_allocator) catch return);
}

fn formatRange(buf: *std.ArrayListUnmanaged(u8), range: Handler.Range) void {
    appendStr(buf, "{\"start\":{\"line\":");
    appendUint(buf, range.start.line);
    appendStr(buf, ",\"character\":");
    appendUint(buf, range.start.character);
    appendStr(buf, "},\"end\":{\"line\":");
    appendUint(buf, range.end.line);
    appendStr(buf, ",\"character\":");
    appendUint(buf, range.end.character);
    appendStr(buf, "}}");
}

fn handleDefinition(root: std.json.ObjectMap, id: ?std.json.Value) void {
    const p = extractUriAndPosition(root) orelse return sendResult(id, "null");
    const range = handler.computeDefinition(p.uri, .{ .line = p.line, .character = p.char }) catch return sendResult(id, "null");
    const r = range orelse return sendResult(id, "null");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(&buf, "{\"uri\":\"");
    Diagnostic.appendJsonEscaped(&buf, wasm_allocator, p.uri) catch return;
    appendStr(&buf, "\",\"range\":");
    formatRange(&buf, r);
    appendStr(&buf, "}");
    sendResult(id, buf.toOwnedSlice(wasm_allocator) catch return);
}

fn handleReferences(root: std.json.ObjectMap, id: ?std.json.Value) void {
    const p = extractUriAndPosition(root) orelse return sendResult(id, "null");
    const params = root.getPtr("params") orelse return sendResult(id, "null");
    const ctx = objGet(params, "context");
    const include_decl = if (ctx) |c| blk: {
        const v = objGet(c, "includeDeclaration");
        if (v) |val| {
            break :blk switch (val.*) {
                .bool => |b| b,
                else => true,
            };
        }
        break :blk true;
    } else true;

    const refs = handler.computeReferences(p.uri, .{ .line = p.line, .character = p.char }, include_decl) catch return sendResult(id, "null");
    const handler_refs = refs orelse return sendResult(id, "null");
    defer handler.gpa.free(handler_refs);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(&buf, "[");
    for (handler_refs, 0..) |ref, i| {
        if (i > 0) appendStr(&buf, ",");
        appendStr(&buf, "{\"uri\":\"");
        Diagnostic.appendJsonEscaped(&buf, wasm_allocator, p.uri) catch return;
        appendStr(&buf, "\",\"range\":");
        formatRange(&buf, ref);
        appendStr(&buf, "}");
    }
    appendStr(&buf, "]");
    sendResult(id, buf.toOwnedSlice(wasm_allocator) catch return);
}

fn handleDocumentHighlight(root: std.json.ObjectMap, id: ?std.json.Value) void {
    const p = extractUriAndPosition(root) orelse return sendResult(id, "null");
    const highlights = handler.computeDocumentHighlight(p.uri, .{ .line = p.line, .character = p.char }) catch return sendResult(id, "null");
    const handler_highlights = highlights orelse return sendResult(id, "null");
    defer handler.gpa.free(handler_highlights);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(&buf, "[");
    for (handler_highlights, 0..) |h, i| {
        if (i > 0) appendStr(&buf, ",");
        appendStr(&buf, "{\"range\":");
        formatRange(&buf, h.range);
        appendStr(&buf, ",\"kind\":");
        appendUint(&buf, @intFromEnum(h.kind));
        appendStr(&buf, "}");
    }
    appendStr(&buf, "]");
    sendResult(id, buf.toOwnedSlice(wasm_allocator) catch return);
}

fn handleRename(root: std.json.ObjectMap, id: ?std.json.Value) void {
    const p = extractUriAndPosition(root) orelse return sendResult(id, "null");
    const params = root.getPtr("params") orelse return sendResult(id, "null");
    const new_name = strVal(objGet(params, "newName")) orelse return sendResult(id, "null");

    const edits = handler.computeRename(p.uri, .{ .line = p.line, .character = p.char }, new_name) catch return sendResult(id, "null");
    const handler_edits = edits orelse return sendResult(id, "null");
    defer handler.gpa.free(handler_edits);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(&buf, "{\"changes\":{\"");
    Diagnostic.appendJsonEscaped(&buf, wasm_allocator, p.uri) catch return;
    appendStr(&buf, "\":[");
    for (handler_edits, 0..) |edit, i| {
        if (i > 0) appendStr(&buf, ",");
        appendStr(&buf, "{\"range\":");
        formatRange(&buf, edit.range);
        appendStr(&buf, ",\"newText\":\"");
        Diagnostic.appendJsonEscaped(&buf, wasm_allocator, edit.new_text) catch return;
        appendStr(&buf, "\"}");
    }
    appendStr(&buf, "]}}");
    sendResult(id, buf.toOwnedSlice(wasm_allocator) catch return);
}

fn handlePrepareRename(root: std.json.ObjectMap, id: ?std.json.Value) void {
    const p = extractUriAndPosition(root) orelse return sendResult(id, "null");
    const range = handler.prepareRename(p.uri, .{ .line = p.line, .character = p.char }) catch return sendResult(id, "null");
    const r = range orelse return sendResult(id, "null");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(&buf, "{\"range\":");
    formatRange(&buf, r);
    appendStr(&buf, ",\"placeholder\":\"\"}");
    sendResult(id, buf.toOwnedSlice(wasm_allocator) catch return);
}

fn handleCompletion(root: std.json.ObjectMap, id: ?std.json.Value) void {
    const p = extractUriAndPosition(root) orelse return sendResult(id, "null");
    const items = handler.computeCompletion(p.uri, .{ .line = p.line, .character = p.char }) catch return sendResult(id, "null");
    defer handler.gpa.free(items);
    if (items.len == 0) return sendResult(id, "null");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(&buf, "[");
    for (items, 0..) |item, i| {
        if (i > 0) appendStr(&buf, ",");
        appendStr(&buf, "{\"label\":\"");
        Diagnostic.appendJsonEscaped(&buf, wasm_allocator, item.label) catch return;
        appendStr(&buf, "\",\"kind\":");
        const kind_num: u32 = switch (item.kind) {
            .variable => 6,
            .function => 3,
            .struct_type => 22,
            .field => 5,
            .keyword => 14,
            .builtin => 3,
            .type_name => 7,
            .attribute => 10,
        };
        appendUint(&buf, kind_num);
        if (item.detail.len > 0) {
            appendStr(&buf, ",\"detail\":\"");
            Diagnostic.appendJsonEscaped(&buf, wasm_allocator, item.detail) catch return;
            appendStr(&buf, "\"");
        }
        appendStr(&buf, "}");
    }
    appendStr(&buf, "]");
    sendResult(id, buf.toOwnedSlice(wasm_allocator) catch return);
}

fn handleSignatureHelp(root: std.json.ObjectMap, id: ?std.json.Value) void {
    const p = extractUriAndPosition(root) orelse return sendResult(id, "null");
    const result = handler.computeSignatureHelp(p.uri, .{ .line = p.line, .character = p.char }) catch return sendResult(id, "null");
    const r = result orelse return sendResult(id, "null");
    defer handler.gpa.free(r.label);
    if (r.parameters.len > 0) handler.gpa.free(r.parameters);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(&buf, "{\"signatures\":[{\"label\":\"");
    Diagnostic.appendJsonEscaped(&buf, wasm_allocator, r.label) catch return;
    appendStr(&buf, "\"");
    if (r.parameters.len > 0) {
        appendStr(&buf, ",\"parameters\":[");
        for (r.parameters, 0..) |param, i| {
            if (i > 0) appendStr(&buf, ",");
            appendStr(&buf, "{\"label\":\"");
            Diagnostic.appendJsonEscaped(&buf, wasm_allocator, param) catch return;
            appendStr(&buf, "\"}");
        }
        appendStr(&buf, "]");
    }
    appendStr(&buf, "}],\"activeSignature\":0,\"activeParameter\":");
    appendUint(&buf, r.active_parameter);
    appendStr(&buf, "}");
    sendResult(id, buf.toOwnedSlice(wasm_allocator) catch return);
}

fn handleDocumentSymbol(root: std.json.ObjectMap, id: ?std.json.Value) void {
    const params = root.getPtr("params") orelse return sendResult(id, "null");
    const td = objGet(params, "textDocument") orelse return sendResult(id, "null");
    const uri = strVal(objGet(td, "uri")) orelse return sendResult(id, "null");
    const symbols = handler.computeDocumentSymbols(uri) catch return sendResult(id, "null");
    defer handler.gpa.free(symbols);
    if (symbols.len == 0) return sendResult(id, "null");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(&buf, "[");
    for (symbols, 0..) |sym, i| {
        if (i > 0) appendStr(&buf, ",");
        emitDocSymbol(&buf, sym);
    }
    appendStr(&buf, "]");
    sendResult(id, buf.toOwnedSlice(wasm_allocator) catch return);
}

fn emitDocSymbol(buf: *std.ArrayListUnmanaged(u8), sym: Handler.DocumentSymbolInfo) void {
    appendStr(buf, "{\"name\":\"");
    Diagnostic.appendJsonEscaped(buf, wasm_allocator, sym.name) catch return;
    appendStr(buf, "\",\"kind\":");
    const kind_num: u32 = switch (sym.kind) {
        .function => 12,
        .struct_type => 23,
        .variable => 13,
        .constant => 14,
        .field => 8,
        .type_alias => 5,
        .override => 14,
    };
    appendUint(buf, kind_num);
    appendStr(buf, ",\"range\":");
    formatRange(buf, sym.range);
    appendStr(buf, ",\"selectionRange\":");
    formatRange(buf, sym.selection_range);
    if (sym.children.len > 0) {
        appendStr(buf, ",\"children\":[");
        for (sym.children, 0..) |child, ci| {
            if (ci > 0) appendStr(buf, ",");
            emitDocSymbol(buf, child);
        }
        appendStr(buf, "]");
    }
    appendStr(buf, "}");
}

fn handleFoldingRange(root: std.json.ObjectMap, id: ?std.json.Value) void {
    const params = root.getPtr("params") orelse return sendResult(id, "null");
    const td = objGet(params, "textDocument") orelse return sendResult(id, "null");
    const uri = strVal(objGet(td, "uri")) orelse return sendResult(id, "null");
    const ranges = handler.computeFoldingRanges(uri) catch return sendResult(id, "null");
    defer handler.gpa.free(ranges);
    if (ranges.len == 0) return sendResult(id, "null");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(&buf, "[");
    for (ranges, 0..) |r, i| {
        if (i > 0) appendStr(&buf, ",");
        appendStr(&buf, "{\"startLine\":");
        appendUint(&buf, r.start_line);
        appendStr(&buf, ",\"endLine\":");
        appendUint(&buf, r.end_line);
        appendStr(&buf, ",\"kind\":\"");
        appendStr(&buf, if (r.kind == .comment) "comment" else "region");
        appendStr(&buf, "\"}");
    }
    appendStr(&buf, "]");
    sendResult(id, buf.toOwnedSlice(wasm_allocator) catch return);
}

fn handleTypeDefinition(root: std.json.ObjectMap, id: ?std.json.Value) void {
    const p = extractUriAndPosition(root) orelse return sendResult(id, "null");
    const range = handler.computeTypeDefinition(p.uri, .{ .line = p.line, .character = p.char }) catch return sendResult(id, "null");
    const r = range orelse return sendResult(id, "null");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(&buf, "{\"uri\":\"");
    Diagnostic.appendJsonEscaped(&buf, wasm_allocator, p.uri) catch return;
    appendStr(&buf, "\",\"range\":");
    formatRange(&buf, r);
    appendStr(&buf, "}");
    sendResult(id, buf.toOwnedSlice(wasm_allocator) catch return);
}

fn handleInlayHint(root: std.json.ObjectMap, id: ?std.json.Value) void {
    const params = root.getPtr("params") orelse return sendResult(id, "null");
    const td = objGet(params, "textDocument") orelse return sendResult(id, "null");
    const uri = strVal(objGet(td, "uri")) orelse return sendResult(id, "null");
    const range_obj = objGet(params, "range") orelse return sendResult(id, "null");
    const start_obj = objGet(range_obj, "start") orelse return sendResult(id, "null");
    const end_obj = objGet(range_obj, "end") orelse return sendResult(id, "null");
    const start_line: u32 = if (intVal(objGet(start_obj, "line"))) |v| @intCast(v) else 0;
    const start_char: u32 = if (intVal(objGet(start_obj, "character"))) |v| @intCast(v) else 0;
    const end_line: u32 = if (intVal(objGet(end_obj, "line"))) |v| @intCast(v) else 0;
    const end_char: u32 = if (intVal(objGet(end_obj, "character"))) |v| @intCast(v) else 0;

    const hints = handler.computeInlayHints(uri, .{
        .start = .{ .line = start_line, .character = start_char },
        .end = .{ .line = end_line, .character = end_char },
    }) catch return sendResult(id, "null");
    defer handler.gpa.free(hints);
    if (hints.len == 0) return sendResult(id, "null");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(&buf, "[");
    for (hints, 0..) |h, i| {
        if (i > 0) appendStr(&buf, ",");
        appendStr(&buf, "{\"position\":{\"line\":");
        appendUint(&buf, h.position.line);
        appendStr(&buf, ",\"character\":");
        appendUint(&buf, h.position.character);
        appendStr(&buf, "},\"label\":\"");
        Diagnostic.appendJsonEscaped(&buf, wasm_allocator, h.label) catch return;
        appendStr(&buf, "\",\"kind\":");
        appendUint(&buf, if (h.kind == .type_hint) @as(u32, 1) else @as(u32, 2));
        appendStr(&buf, "}");
    }
    appendStr(&buf, "]");
    sendResult(id, buf.toOwnedSlice(wasm_allocator) catch return);
}

fn handleCodeLens(root: std.json.ObjectMap, id: ?std.json.Value) void {
    const params = root.getPtr("params") orelse return sendResult(id, "null");
    const td = objGet(params, "textDocument") orelse return sendResult(id, "null");
    const uri = strVal(objGet(td, "uri")) orelse return sendResult(id, "null");
    const lenses = handler.computeCodeLens(uri) catch return sendResult(id, "null");
    defer {
        for (lenses) |l| handler.gpa.free(l.title);
        handler.gpa.free(lenses);
    }
    if (lenses.len == 0) return sendResult(id, "null");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(&buf, "[");
    for (lenses, 0..) |l, i| {
        if (i > 0) appendStr(&buf, ",");
        appendStr(&buf, "{\"range\":");
        formatRange(&buf, l.range);
        appendStr(&buf, ",\"command\":{\"title\":\"");
        Diagnostic.appendJsonEscaped(&buf, wasm_allocator, l.title) catch return;
        appendStr(&buf, "\",\"command\":\"\"}}");
    }
    appendStr(&buf, "]");
    sendResult(id, buf.toOwnedSlice(wasm_allocator) catch return);
}

fn handleFormatting(root: std.json.ObjectMap, id: ?std.json.Value) void {
    const params = root.getPtr("params") orelse return sendResult(id, "null");
    const td = objGet(params, "textDocument") orelse return sendResult(id, "null");
    const uri = strVal(objGet(td, "uri")) orelse return sendResult(id, "null");
    const edit = handler.computeFormatting(uri) catch return sendResult(id, "null");
    const e = edit orelse return sendResult(id, "null");
    defer handler.gpa.free(e.new_text);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(&buf, "[{\"range\":");
    formatRange(&buf, e.range);
    appendStr(&buf, ",\"newText\":\"");
    Diagnostic.appendJsonEscaped(&buf, wasm_allocator, e.new_text) catch return;
    appendStr(&buf, "\"}]");
    sendResult(id, buf.toOwnedSlice(wasm_allocator) catch return);
}

fn handleSemanticTokens(root: std.json.ObjectMap, id: ?std.json.Value) void {
    const params = root.getPtr("params") orelse return sendResult(id, "null");
    const td = objGet(params, "textDocument") orelse return sendResult(id, "null");
    const uri = strVal(objGet(td, "uri")) orelse return sendResult(id, "null");
    const data = handler.computeSemanticTokens(uri) catch return sendResult(id, "null");
    defer handler.gpa.free(data);
    if (data.len == 0) return sendResult(id, "null");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(&buf, "{\"data\":[");
    for (data, 0..) |v, i| {
        if (i > 0) appendStr(&buf, ",");
        appendUint(&buf, v);
    }
    appendStr(&buf, "]}");
    sendResult(id, buf.toOwnedSlice(wasm_allocator) catch return);
}

fn handleSelectionRange(root: std.json.ObjectMap, id: ?std.json.Value) void {
    const params = root.getPtr("params") orelse return sendResult(id, "null");
    const td = objGet(params, "textDocument") orelse return sendResult(id, "null");
    const uri = strVal(objGet(td, "uri")) orelse return sendResult(id, "null");
    const positions = switch ((objGet(params, "positions") orelse return sendResult(id, "null")).*) {
        .array => |a| a.items,
        else => return sendResult(id, "null"),
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(&buf, "[");
    for (positions, 0..) |*pos_val, pi| {
        if (pi > 0) appendStr(&buf, ",");
        const line: u32 = if (intVal(objGet(pos_val, "line"))) |v| @intCast(v) else 0;
        const char: u32 = if (intVal(objGet(pos_val, "character"))) |v| @intCast(v) else 0;
        const sel = handler.computeSelectionRange(uri, .{ .line = line, .character = char }) catch null;
        if (sel) |s| {
            emitSelectionRange(&buf, s);
        } else {
            appendStr(&buf, "{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":0}}}");
        }
    }
    appendStr(&buf, "]");
    sendResult(id, buf.toOwnedSlice(wasm_allocator) catch return);
}

fn emitSelectionRange(buf: *std.ArrayListUnmanaged(u8), sel: *const Handler.SelectionRangeInfo) void {
    appendStr(buf, "{\"range\":");
    formatRange(buf, sel.range);
    if (sel.parent) |p| {
        appendStr(buf, ",\"parent\":");
        emitSelectionRange(buf, p);
    }
    appendStr(buf, "}");
}

fn handlePrepareCallHierarchy(root: std.json.ObjectMap, id: ?std.json.Value) void {
    const p = extractUriAndPosition(root) orelse return sendResult(id, "null");
    const item = handler.prepareCallHierarchy(p.uri, .{ .line = p.line, .character = p.char }) catch return sendResult(id, "null");
    const i = item orelse return sendResult(id, "null");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(&buf, "[{\"name\":\"");
    Diagnostic.appendJsonEscaped(&buf, wasm_allocator, i.name) catch return;
    appendStr(&buf, "\",\"kind\":12,\"uri\":\"");
    Diagnostic.appendJsonEscaped(&buf, wasm_allocator, p.uri) catch return;
    appendStr(&buf, "\",\"range\":");
    formatRange(&buf, i.range);
    appendStr(&buf, ",\"selectionRange\":");
    formatRange(&buf, i.selection_range);
    appendStr(&buf, "}]");
    sendResult(id, buf.toOwnedSlice(wasm_allocator) catch return);
}

fn handleIncomingCalls(root: std.json.ObjectMap, id: ?std.json.Value) void {
    const params = root.getPtr("params") orelse return sendResult(id, "null");
    const item_val = objGet(params, "item") orelse return sendResult(id, "null");
    const name = strVal(objGet(item_val, "name")) orelse return sendResult(id, "null");
    const uri_val = objGet(item_val, "uri");
    const uri = if (uri_val) |u| strVal(u) orelse return sendResult(id, "null") else return sendResult(id, "null");
    const calls = handler.computeIncomingCalls(uri, name) catch return sendResult(id, "null");
    defer {
        for (calls) |c| handler.gpa.free(c.from_ranges);
        handler.gpa.free(calls);
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(&buf, "[");
    for (calls, 0..) |call, ci| {
        if (ci > 0) appendStr(&buf, ",");
        appendStr(&buf, "{\"from\":{\"name\":\"");
        Diagnostic.appendJsonEscaped(&buf, wasm_allocator, call.from.name) catch return;
        appendStr(&buf, "\",\"kind\":12,\"uri\":\"");
        Diagnostic.appendJsonEscaped(&buf, wasm_allocator, uri) catch return;
        appendStr(&buf, "\",\"range\":");
        formatRange(&buf, call.from.range);
        appendStr(&buf, ",\"selectionRange\":");
        formatRange(&buf, call.from.selection_range);
        appendStr(&buf, "},\"fromRanges\":[");
        for (call.from_ranges, 0..) |fr, fi| {
            if (fi > 0) appendStr(&buf, ",");
            formatRange(&buf, fr);
        }
        appendStr(&buf, "]}");
    }
    appendStr(&buf, "]");
    sendResult(id, buf.toOwnedSlice(wasm_allocator) catch return);
}

fn handleOutgoingCalls(root: std.json.ObjectMap, id: ?std.json.Value) void {
    const params = root.getPtr("params") orelse return sendResult(id, "null");
    const item_val = objGet(params, "item") orelse return sendResult(id, "null");
    const name = strVal(objGet(item_val, "name")) orelse return sendResult(id, "null");
    const uri_val = objGet(item_val, "uri");
    const uri = if (uri_val) |u| strVal(u) orelse return sendResult(id, "null") else return sendResult(id, "null");
    const calls = handler.computeOutgoingCalls(uri, name) catch return sendResult(id, "null");
    defer {
        for (calls) |c| handler.gpa.free(c.from_ranges);
        handler.gpa.free(calls);
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(&buf, "[");
    for (calls, 0..) |call, ci| {
        if (ci > 0) appendStr(&buf, ",");
        appendStr(&buf, "{\"to\":{\"name\":\"");
        Diagnostic.appendJsonEscaped(&buf, wasm_allocator, call.to.name) catch return;
        appendStr(&buf, "\",\"kind\":12,\"uri\":\"");
        Diagnostic.appendJsonEscaped(&buf, wasm_allocator, uri) catch return;
        appendStr(&buf, "\",\"range\":");
        formatRange(&buf, call.to.range);
        appendStr(&buf, ",\"selectionRange\":");
        formatRange(&buf, call.to.selection_range);
        appendStr(&buf, "},\"fromRanges\":[");
        for (call.from_ranges, 0..) |fr, fi| {
            if (fi > 0) appendStr(&buf, ",");
            formatRange(&buf, fr);
        }
        appendStr(&buf, "]}");
    }
    appendStr(&buf, "]");
    sendResult(id, buf.toOwnedSlice(wasm_allocator) catch return);
}

// =========================================================================
// Diagnostics (reuses Handler.validateDocument + Handler.LspDiagnostic)
// =========================================================================

fn emitDiagnostics(uri: []const u8) void {
    const diags = handler.validateDocumentFull(uri) catch return;
    defer Handler.freeDiagnostics(handler.gpa, diags);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(&buf, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"");
    Diagnostic.appendJsonEscaped(&buf, wasm_allocator, uri) catch return;
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
        Diagnostic.appendJsonEscaped(&buf, wasm_allocator, diag.message) catch return;
        appendStr(&buf, "\"");
        if (diag.code.len > 0) {
            appendStr(&buf, ",\"code\":\"");
            Diagnostic.appendJsonEscaped(&buf, wasm_allocator, diag.code) catch return;
            appendStr(&buf, "\"");
        }
        if (diag.spec_url.len > 0) {
            appendStr(&buf, ",\"codeDescription\":{\"href\":\"");
            Diagnostic.appendJsonEscaped(&buf, wasm_allocator, diag.spec_url) catch return;
            appendStr(&buf, "\"}");
        }
        if (diag.related.len > 0) {
            appendStr(&buf, ",\"relatedInformation\":[");
            for (diag.related, 0..) |rel, ri| {
                if (ri > 0) buf.append(wasm_allocator, ',') catch {};
                appendStr(&buf, "{\"location\":{\"uri\":\"");
                Diagnostic.appendJsonEscaped(&buf, wasm_allocator, uri) catch return;
                appendStr(&buf, "\",\"range\":{\"start\":{\"line\":");
                appendUint(&buf, rel.range.start.line);
                appendStr(&buf, ",\"character\":");
                appendUint(&buf, rel.range.start.character);
                appendStr(&buf, "},\"end\":{\"line\":");
                appendUint(&buf, rel.range.end.line);
                appendStr(&buf, ",\"character\":");
                appendUint(&buf, rel.range.end.character);
                appendStr(&buf, "}}},\"message\":\"");
                Diagnostic.appendJsonEscaped(&buf, wasm_allocator, rel.message) catch return;
                appendStr(&buf, "\"}");
            }
            appendStr(&buf, "]");
        }
        if (diag.tags.len > 0) {
            appendStr(&buf, ",\"tags\":[");
            for (diag.tags, 0..) |tag, ti| {
                if (ti > 0) buf.append(wasm_allocator, ',') catch {};
                appendUint(&buf, @intFromEnum(tag));
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
