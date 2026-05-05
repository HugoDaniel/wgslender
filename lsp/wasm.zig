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
const Handler = @import("Handler");
const wasm_diagnostics = @import("wasm/diagnostics.zig");
const json = @import("wasm/json.zig");

const Diagnostic = wgslender.Diagnostic;
const ffi = wgslender.ffi;
const wasm_allocator = std.heap.wasm_allocator;

// =========================================================================
// Global state
// =========================================================================

var handler: Handler = .init(wasm_allocator);
var outbox: std.ArrayListUnmanaged([]u8) = .empty;
/// True iff the client advertised `workspace.configuration` in InitializeParams.
var client_supports_configuration: bool = false;
var next_request_id: i64 = 1;
/// ID of the in-flight `workspace/configuration` request, if any.
var pending_config_id: ?i64 = null;

// =========================================================================
// Exported WASM functions
// =========================================================================

export fn wgslender_lsp_alloc(len: u32) callconv(.c) ?[*]u8 {
    return ffi.allocBuf(len);
}

export fn wgslender_lsp_dealloc(ptr: [*]u8, len: u32) callconv(.c) void {
    ffi.freeBuf(ptr, len);
}

/// Send a JSON-RPC message to the server. Responses/notifications
/// are queued and retrieved via wgslender_lsp_recv().
export fn wgslender_lsp_send(msg_ptr: [*]const u8, msg_len: u32) callconv(.c) void {
    handleMessage(msg_ptr[0..msg_len]);
}

/// Get the next outgoing message, or null if empty.
/// Returns pointer to [u32 len][u8... json].
/// Caller frees with wgslender_lsp_dealloc(ptr, len + 4).
export fn wgslender_lsp_recv() callconv(.c) ?[*]u8 {
    if (outbox.items.len == 0) return null;
    const msg = outbox.orderedRemove(0);
    const out = wasm_allocator.alloc(u8, 4 + msg.len) catch {
        wasm_allocator.free(msg);
        return null;
    };
    // Copy message BEFORE writing the length header: the allocator may
    // return `out` at the same address as `msg`, so writeInt would corrupt
    // the first 4 bytes of msg. Use copyBackwards to handle the overlap
    // (dest is 4 bytes ahead of source).
    std.mem.copyBackwards(u8, out[4..][0..msg.len], msg);
    std.mem.writeInt(u32, out[0..4], @intCast(msg.len), .little);
    wasm_allocator.free(msg);
    return out.ptr;
}

// =========================================================================
// JSON-RPC dispatch
// =========================================================================

const HandlerFn = *const fn (std.json.ObjectMap, ?std.json.Value) void;

const dispatch_table = [_]struct { method: []const u8, handler: HandlerFn }{
    .{ .method = "initialize", .handler = handleInitialize },
    .{ .method = "initialized", .handler = handleNoop },
    .{ .method = "exit", .handler = handleNoop },
    .{ .method = "shutdown", .handler = handleShutdown },
    .{ .method = "textDocument/didOpen", .handler = handleDidOpen },
    .{ .method = "textDocument/didChange", .handler = handleDidChange },
    .{ .method = "textDocument/didClose", .handler = handleDidClose },
    .{ .method = "textDocument/didSave", .handler = handleDidSave },
    .{ .method = "workspace/didChangeConfiguration", .handler = handleDidChangeConfiguration },
    .{ .method = "wgslender/recomputeMinifyInsights", .handler = handleRecomputeMinifyInsights },
    .{ .method = "wgslender/reflect", .handler = handleReflect },
    .{ .method = "textDocument/codeAction", .handler = handleCodeAction },
    .{ .method = "textDocument/hover", .handler = handleHover },
    .{ .method = "textDocument/definition", .handler = handleDefinition },
    .{ .method = "textDocument/references", .handler = handleReferences },
    .{ .method = "textDocument/documentHighlight", .handler = handleDocumentHighlight },
    .{ .method = "textDocument/rename", .handler = handleRename },
    .{ .method = "textDocument/prepareRename", .handler = handlePrepareRename },
    .{ .method = "textDocument/completion", .handler = handleCompletion },
    .{ .method = "textDocument/signatureHelp", .handler = handleSignatureHelp },
    .{ .method = "textDocument/documentSymbol", .handler = handleDocumentSymbol },
    .{ .method = "textDocument/foldingRange", .handler = handleFoldingRange },
    .{ .method = "textDocument/typeDefinition", .handler = handleTypeDefinition },
    .{ .method = "textDocument/inlayHint", .handler = handleInlayHint },
    .{ .method = "textDocument/codeLens", .handler = handleCodeLens },
    .{ .method = "textDocument/formatting", .handler = handleFormatting },
    .{ .method = "textDocument/semanticTokens/full", .handler = handleSemanticTokens },
    .{ .method = "textDocument/selectionRange", .handler = handleSelectionRange },
    .{ .method = "textDocument/prepareCallHierarchy", .handler = handlePrepareCallHierarchy },
    .{ .method = "callHierarchy/incomingCalls", .handler = handleIncomingCalls },
    .{ .method = "callHierarchy/outgoingCalls", .handler = handleOutgoingCalls },
    .{ .method = "textDocument/diagnostic", .handler = handlePullDiagnostic },
    .{ .method = "workspace/executeCommand", .handler = handleExecuteCommand },
};

fn handleMessage(msg_json: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, wasm_allocator, msg_json, .{
        .ignore_unknown_fields = true,
        .max_value_len = null,
    }) catch return;
    defer parsed.deinit();

    const root = parsed.value.object;
    const method_val = root.get("method") orelse {
        // No `method` field — this is a response to a server-initiated request.
        handleResponse(root);
        return;
    };
    const method = switch (method_val) {
        .string => |s| s,
        else => return,
    };
    const id = root.get("id");

    for (&dispatch_table) |entry| {
        if (std.mem.eql(u8, method, entry.method)) {
            entry.handler(root, id);
            return;
        }
    }
    if (id != null) sendResult(id, "null");
}

fn handleNoop(_: std.json.ObjectMap, _: ?std.json.Value) void {}

fn handleShutdown(_: std.json.ObjectMap, id: ?std.json.Value) void {
    sendResult(id, "null");
}

// =========================================================================
// Document handlers (delegate to shared Handler)
// =========================================================================

fn handleDidOpen(root: std.json.ObjectMap, _: ?std.json.Value) void {
    const params = root.getPtr("params") orelse return;
    const td = objGet(params, "textDocument") orelse return;
    const uri = strVal(objGet(td, "uri")) orelse return;
    const text = strVal(objGet(td, "text")) orelse return;
    const version: i32 = if (intVal(objGet(td, "version"))) |v| @intCast(v) else 0;
    handler.openDocument(uri, text, version) catch return;
    emitDiagnostics(uri);
}

fn handleDidChange(root: std.json.ObjectMap, _: ?std.json.Value) void {
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
    // Phase 7: cheap-path on the hot edit channel. The JS client is
    // responsible for sending `wgslender/recomputeMinifyInsights` after
    // typing settles to surface M-rule diagnostics.
    emitDiagnosticsCheap(uri);
}

fn handleDidClose(root: std.json.ObjectMap, _: ?std.json.Value) void {
    const uri = extractUri(root) orelse return;
    handler.closeDocument(uri);

    // Clear diagnostics.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(&buf, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"");
    Diagnostic.appendJsonEscaped(&buf, wasm_allocator, uri) catch return;
    appendStr(&buf, "\",\"diagnostics\":[]}}");
    enqueue(buf.toOwnedSlice(wasm_allocator) catch return);
}

fn handleDidSave(root: std.json.ObjectMap, _: ?std.json.Value) void {
    const uri = extractUri(root) orelse return;
    handler.handleDidSave(uri);
    emitDiagnostics(uri);
}

fn handleDidChangeConfiguration(_: std.json.ObjectMap, _: ?std.json.Value) void {
    if (!client_supports_configuration) return;
    sendConfigurationRequest();
}

/// Phase 7 — `wgslender/recomputeMinifyInsights` notification. The WASM
/// transport doesn't have a native idle timer, so the JS client owns the
/// debounce window: it batches `didChange` notifications, waits for the
/// idle gap, then sends this notification to ask the server to warm the
/// per-document estimator cache and re-emit diagnostics. The notification
/// shape matches LSP convention — `params.textDocument.uri` carries the
/// target. Unknown URIs / inactive minify modes turn into no-ops inside
/// the handler.
fn handleRecomputeMinifyInsights(root: std.json.ObjectMap, _: ?std.json.Value) void {
    const uri = extractUri(root) orelse return;
    handler.refreshMinifyInsights(uri);
    emitDiagnostics(uri);
}

/// `wgslender/reflect` — custom request that reflects the named document
/// and returns the JSON payload (compact or pretty-printed) at the
/// requested schema version. Params:
///   `textDocument.uri`   document to reflect (must be opened)
///   `format`             "v1" | "v2", default "v2"
///   `pretty`             bool, default false
fn handleReflect(root: std.json.ObjectMap, id: ?std.json.Value) void {
    if (id == null) return; // request, must have an id
    const params = root.getPtr("params") orelse return sendErrorCode(id, -32602, "missing params");
    const td = objGet(params, "textDocument") orelse return sendErrorCode(id, -32602, "missing textDocument.uri");
    const uri = strVal(objGet(td, "uri")) orelse return sendErrorCode(id, -32602, "missing textDocument.uri");

    var version: wgslender.Reflect.JsonVersion = .v2;
    if (objGet(params, "format")) |fmt_val| switch (fmt_val.*) {
        .string => |s| {
            if (std.mem.eql(u8, s, "v1")) {
                version = .v1;
            } else if (std.mem.eql(u8, s, "v2")) {
                version = .v2;
            } else return sendErrorCode(id, -32602, "format must be 'v1' or 'v2'");
        },
        else => return sendErrorCode(id, -32602, "format must be a string"),
    };

    var pretty = false;
    if (objGet(params, "pretty")) |p| switch (p.*) {
        .bool => |b| pretty = b,
        else => {},
    };

    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const result = handler.runReflect(arena.allocator(), uri, version, pretty) catch |err| {
        switch (err) {
            error.UnknownCommand => sendErrorCode(id, -32601, "unknown command"),
            error.InvalidParams => sendErrorCode(id, -32602, "invalid params"),
            error.DocumentNotFound => sendErrorCode(id, -32602, "document not found"),
            error.MinifyFailed => sendErrorCode(id, -32603, "reflect failed"),
            error.ReflectFailed => sendErrorCode(id, -32603, "reflect failed"),
            error.OutOfMemory => sendErrorCode(id, -32603, "out of memory"),
        }
        return;
    };

    // Wrap the (already-serialised) JSON payload under {"uri", "version", "json"}.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(&buf, "{\"uri\":\"");
    Diagnostic.appendJsonEscaped(&buf, wasm_allocator, result.uri) catch return;
    appendStr(&buf, "\",\"version\":");
    appendStr(&buf, switch (result.version) {
        .v1 => "1",
        .v2 => "2",
    });
    appendStr(&buf, ",\"json\":");
    buf.appendSlice(wasm_allocator, result.json) catch return;
    appendStr(&buf, "}");
    sendResult(id, buf.toOwnedSlice(wasm_allocator) catch return);
}

fn handleExecuteCommand(root: std.json.ObjectMap, id: ?std.json.Value) void {
    const params = root.getPtr("params") orelse {
        if (id != null) sendErrorCode(id, -32602, "missing params");
        return;
    };
    const command = strVal(objGet(params, "command")) orelse {
        if (id != null) sendErrorCode(id, -32602, "missing command");
        return;
    };
    // `arguments` may be omitted, null, or an array of LSPAny. Extract the
    // slice (null/missing → null).
    var args_slice: ?[]const std.json.Value = null;
    if (objGet(params, "arguments")) |a| switch (a.*) {
        .array => |arr| args_slice = arr.items,
        .null => {},
        else => {
            if (id != null) sendErrorCode(id, -32602, "arguments must be an array");
            return;
        },
    };
    if (std.mem.eql(u8, command, "wgslender.showMinifiedOutput")) {
        if (id == null) return;
        const items = args_slice orelse return sendErrorCode(id, -32602, "missing uri");
        if (items.len < 1) return sendErrorCode(id, -32602, "missing uri");
        const uri = switch (items[0]) {
            .string => |s| s,
            else => return sendErrorCode(id, -32602, "uri must be a string"),
        };
        var arena = std.heap.ArenaAllocator.init(wasm_allocator);
        defer arena.deinit();
        const result = handler.runShowMinifiedOutput(arena.allocator(), uri) catch |err| {
            switch (err) {
                error.UnknownCommand => sendErrorCode(id, -32601, "unknown command"),
                error.InvalidParams => sendErrorCode(id, -32602, "invalid command arguments"),
                error.DocumentNotFound => sendErrorCode(id, -32602, "document not found"),
                error.MinifyFailed => sendErrorCode(id, -32603, "minify failed"),
                error.ReflectFailed => sendErrorCode(id, -32603, "reflect failed"),
                error.OutOfMemory => sendErrorCode(id, -32603, "out of memory"),
            }
            return;
        };
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        appendStr(&buf, "{\"uri\":\"");
        Diagnostic.appendJsonEscaped(&buf, wasm_allocator, result.uri) catch return;
        appendStr(&buf, "\",\"minified_text\":\"");
        Diagnostic.appendJsonEscaped(&buf, wasm_allocator, result.minified_text) catch return;
        appendStr(&buf, "\",\"byte_count\":");
        appendUint(&buf, result.byte_count);
        appendStr(&buf, ",\"gz_count\":");
        appendUint(&buf, result.gz_count);
        appendStr(&buf, "}");
        sendResult(id, buf.toOwnedSlice(wasm_allocator) catch return);
        return;
    }
    handler.executeCommand(command, args_slice) catch |err| {
        if (id == null) return;
        switch (err) {
            error.UnknownCommand => sendErrorCode(id, -32601, "unknown command"),
            error.InvalidParams => sendErrorCode(id, -32602, "invalid command arguments"),
            error.DocumentNotFound => sendErrorCode(id, -32602, "document not found"),
            error.MinifyFailed => sendErrorCode(id, -32603, "minify failed"),
            error.ReflectFailed => sendErrorCode(id, -32603, "reflect failed"),
            error.OutOfMemory => sendErrorCode(id, -32603, "out of memory"),
        }
        return;
    };
    // Re-publish diagnostics for every open document so any minify-mode
    // change takes effect immediately.
    republishAllDocuments();
    if (id != null) sendResult(id, "null");
}

fn handleInitialize(root: std.json.ObjectMap, id: ?std.json.Value) void {
    if (root.getPtr("params")) |params| {
        if (objGet(params, "capabilities")) |cap|
            if (objGet(cap, "workspace")) |ws|
                if (objGet(ws, "configuration")) |c| switch (c.*) {
                    .bool => |b| client_supports_configuration = b,
                    else => {},
                };
        if (objGet(params, "initializationOptions")) |opts|
            handler.applyClientConfig(opts.*);
    }
    sendResult(id, "{\"capabilities\":" ++ Handler.capabilities_json ++ ",\"serverInfo\":{\"name\":\"wgslender-lsp\",\"version\":\"1.0.0\"}}");
}

fn handleResponse(root: std.json.ObjectMap) void {
    const id_val = root.get("id") orelse return;
    const id: i64 = switch (id_val) {
        .integer => |n| n,
        else => return,
    };
    if (pending_config_id == null or pending_config_id.? != id) return;
    pending_config_id = null;

    const result_val = root.get("result") orelse return;
    const arr = switch (result_val) {
        .array => |a| a,
        else => return,
    };
    if (arr.items.len == 0) return;
    handler.applyClientConfig(arr.items[0]);
    republishAllDocuments();
}

fn sendConfigurationRequest() void {
    const id = next_request_id;
    next_request_id +%= 1;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(&buf, "{\"jsonrpc\":\"2.0\",\"id\":");
    appendI64(&buf, id);
    appendStr(&buf, ",\"method\":\"workspace/configuration\",\"params\":{\"items\":[{\"section\":\"wgslender\"}]}}");
    const msg = buf.toOwnedSlice(wasm_allocator) catch return;
    enqueue(msg);
    pending_config_id = id;
}

fn republishAllDocuments() void {
    var it = handler.documents.iterator();
    while (it.next()) |entry| {
        const uri = entry.key_ptr.*;
        if (handler.diagnosticsEnabled()) {
            emitDiagnostics(uri);
        } else {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            appendStr(&buf, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"");
            Diagnostic.appendJsonEscaped(&buf, wasm_allocator, uri) catch return;
            appendStr(&buf, "\",\"diagnostics\":[]}}");
            enqueue(buf.toOwnedSlice(wasm_allocator) catch return);
        }
    }
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

    const handler_diags = wasm_diagnostics.parseDiagnosticItems(wasm_allocator, diag_array) orelse return;
    defer wasm_allocator.free(handler_diags);

    const actions = handler.computeCodeActions(handler_diags) catch return;
    defer Handler.freeCodeActions(wasm_allocator, actions);

    buildCodeActionJsonResponse(id, uri, actions);
}

fn buildCodeActionJsonResponse(id: ?std.json.Value, uri: []const u8, actions: []const Handler.LspCodeAction) void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(&buf, "[");

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

    appendStr(&buf, "]");
    const body = buf.toOwnedSlice(wasm_allocator) catch return;
    defer wasm_allocator.free(body);
    sendResult(id, body);
}

// =========================================================================
// Hover, Definition, References, Rename (WASM handlers)
// =========================================================================

fn extractUri(root: std.json.ObjectMap) ?[]const u8 {
    return json.extractUri(root);
}

fn extractUriAndPosition(root: std.json.ObjectMap) ?json.UriPosition {
    return json.extractUriAndPosition(root);
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
    json.formatRange(buf, wasm_allocator, range);
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
    const uri = extractUri(root) orelse return sendResult(id, "null");
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
    const uri = extractUri(root) orelse return sendResult(id, "null");
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
        appendStr(&buf, "},\"label\":");
        if (h.def_range) |dr| {
            // Label parts with location for navigation/hover
            appendStr(&buf, "[{\"value\":\"");
            Diagnostic.appendJsonEscaped(&buf, wasm_allocator, h.label) catch return;
            appendStr(&buf, "\",\"location\":{\"uri\":\"");
            Diagnostic.appendJsonEscaped(&buf, wasm_allocator, uri) catch return;
            appendStr(&buf, "\",\"range\":");
            formatRange(&buf, dr);
            appendStr(&buf, "}}]");
        } else {
            appendStr(&buf, "\"");
            Diagnostic.appendJsonEscaped(&buf, wasm_allocator, h.label) catch return;
            appendStr(&buf, "\"");
        }
        appendStr(&buf, ",\"kind\":");
        appendUint(&buf, if (h.kind == .parameter_hint) @as(u32, 2) else @as(u32, 1));
        if (h.tooltip) |t| {
            appendStr(&buf, ",\"tooltip\":\"");
            Diagnostic.appendJsonEscaped(&buf, wasm_allocator, t) catch return;
            appendStr(&buf, "\"");
        }
        appendStr(&buf, "}");
    }
    appendStr(&buf, "]");
    sendResult(id, buf.toOwnedSlice(wasm_allocator) catch return);
}

fn handleCodeLens(root: std.json.ObjectMap, id: ?std.json.Value) void {
    const uri = extractUri(root) orelse return sendResult(id, "null");
    const lenses = handler.computeCodeLens(uri) catch return sendResult(id, "null");
    defer Handler.freeCodeLens(handler.gpa, lenses);
    if (lenses.len == 0) return sendResult(id, "null");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(&buf, "[");
    for (lenses, 0..) |l, i| {
        if (i > 0) appendStr(&buf, ",");
        appendStr(&buf, "{\"range\":");
        formatRange(&buf, l.range);
        appendStr(&buf, ",\"command\":{\"title\":\"");
        Diagnostic.appendJsonEscaped(&buf, wasm_allocator, l.title) catch return;
        appendStr(&buf, "\",\"command\":\"");
        if (l.command) |c| {
            Diagnostic.appendJsonEscaped(&buf, wasm_allocator, c) catch return;
        }
        appendStr(&buf, "\"");
        if (l.arguments) |args| {
            appendStr(&buf, ",\"arguments\":[");
            for (args, 0..) |arg, j| {
                if (j > 0) appendStr(&buf, ",");
                switch (arg) {
                    .string => |s| {
                        appendStr(&buf, "\"");
                        Diagnostic.appendJsonEscaped(&buf, wasm_allocator, s) catch return;
                        appendStr(&buf, "\"");
                    },
                    else => appendStr(&buf, "null"),
                }
            }
            appendStr(&buf, "]");
        }
        appendStr(&buf, "}}");
    }
    appendStr(&buf, "]");
    sendResult(id, buf.toOwnedSlice(wasm_allocator) catch return);
}

fn handleFormatting(root: std.json.ObjectMap, id: ?std.json.Value) void {
    const uri = extractUri(root) orelse return sendResult(id, "null");
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
    const uri = extractUri(root) orelse return sendResult(id, "null");
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

fn diagCtx() wasm_diagnostics.Ctx {
    return .{ .gpa = wasm_allocator, .handler = &handler, .outbox = &outbox };
}

fn emitDiagnostics(uri: []const u8) void {
    wasm_diagnostics.emitDiagnostics(diagCtx(), uri);
}

fn emitDiagnosticsCheap(uri: []const u8) void {
    wasm_diagnostics.emitDiagnosticsCheap(diagCtx(), uri);
}

fn handlePullDiagnostic(root: std.json.ObjectMap, id: ?std.json.Value) void {
    wasm_diagnostics.handlePullDiagnostic(diagCtx(), sendResult, root, id);
}

// =========================================================================
// JSON-RPC helpers — thin forwarders to wasm/json.zig.
//
// Per-feature WASM adapters (lsp/wasm/<feature>.zig) call the json.*
// functions directly. The forwarders below preserve the existing
// in-file call sites until each feature group is migrated.
// =========================================================================

fn sendResult(id: ?std.json.Value, result_json: []const u8) void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(&buf, "{\"jsonrpc\":\"2.0\",\"id\":");
    appendId(&buf, id);
    appendStr(&buf, ",\"result\":");
    buf.appendSlice(wasm_allocator, result_json) catch return;
    buf.append(wasm_allocator, '}') catch return;
    enqueue(buf.toOwnedSlice(wasm_allocator) catch return);
}

fn enqueue(msg: []u8) void {
    outbox.append(wasm_allocator, msg) catch wasm_allocator.free(msg);
}

fn appendId(buf: *std.ArrayListUnmanaged(u8), id: ?std.json.Value) void {
    json.appendId(buf, wasm_allocator, id);
}

fn sendErrorCode(id: ?std.json.Value, code: i32, message: []const u8) void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(&buf, "{\"jsonrpc\":\"2.0\",\"id\":");
    appendId(&buf, id);
    appendStr(&buf, ",\"error\":{\"code\":");
    var num_buf: [12]u8 = undefined;
    const s = std.fmt.bufPrint(&num_buf, "{d}", .{code}) catch return;
    buf.appendSlice(wasm_allocator, s) catch return;
    appendStr(&buf, ",\"message\":\"");
    for (message) |c| {
        if (c == '"' or c == '\\') buf.append(wasm_allocator, '\\') catch return;
        buf.append(wasm_allocator, c) catch return;
    }
    appendStr(&buf, "\"}}");
    enqueue(buf.toOwnedSlice(wasm_allocator) catch return);
}

// =========================================================================
// Tiny JSON read helpers — thin forwarders.
// =========================================================================

fn objGet(val: ?*const std.json.Value, key: []const u8) ?*const std.json.Value {
    return json.objGet(val, key);
}

fn strVal(val: ?*const std.json.Value) ?[]const u8 {
    return json.strVal(val);
}

fn intVal(val: ?*const std.json.Value) ?i64 {
    return json.intVal(val);
}

fn appendStr(buf: *std.ArrayListUnmanaged(u8), s: []const u8) void {
    json.appendStr(buf, wasm_allocator, s);
}

fn appendUint(buf: *std.ArrayListUnmanaged(u8), val: u32) void {
    json.appendUint(buf, wasm_allocator, val);
}

fn appendI64(buf: *std.ArrayListUnmanaged(u8), val: i64) void {
    json.appendI64(buf, wasm_allocator, val);
}
