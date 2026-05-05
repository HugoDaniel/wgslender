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
const wasm_code_actions = @import("wasm/code_actions.zig");
const wasm_document_sync = @import("wasm/document_sync.zig");
const wasm_lifecycle = @import("wasm/lifecycle.zig");
const wasm_navigation = @import("wasm/navigation.zig");
const wasm_symbols = @import("wasm/symbols.zig");
const wasm_editing = @import("wasm/editing.zig");
const wasm_call_hierarchy = @import("wasm/call_hierarchy.zig");
const wasm_workspace_commands = @import("wasm/workspace_commands.zig");
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
// Document handlers (delegate to wasm/document_sync.zig)
// =========================================================================

fn docSyncCtx() wasm_document_sync.Ctx {
    return .{ .gpa = wasm_allocator, .handler = &handler, .outbox = &outbox };
}

fn handleDidOpen(root: std.json.ObjectMap, _: ?std.json.Value) void {
    wasm_document_sync.handleDidOpen(docSyncCtx(), root);
}

fn handleDidChange(root: std.json.ObjectMap, _: ?std.json.Value) void {
    wasm_document_sync.handleDidChange(docSyncCtx(), root);
}

fn handleDidClose(root: std.json.ObjectMap, _: ?std.json.Value) void {
    wasm_document_sync.handleDidClose(docSyncCtx(), root);
}

fn handleDidSave(root: std.json.ObjectMap, _: ?std.json.Value) void {
    wasm_document_sync.handleDidSave(docSyncCtx(), root);
}

fn handleDidChangeConfiguration(_: std.json.ObjectMap, _: ?std.json.Value) void {
    wasm_lifecycle.handleDidChangeConfiguration(lifecycleCtx());
}

/// Phase 7 — `wgslender/recomputeMinifyInsights` notification. The WASM
/// transport doesn't have a native idle timer, so the JS client owns the
/// debounce window: it batches `didChange` notifications, waits for the
/// idle gap, then sends this notification to ask the server to warm the
/// per-document estimator cache and re-emit diagnostics. The notification
/// shape matches LSP convention — `params.textDocument.uri` carries the
/// target. Unknown URIs / inactive minify modes turn into no-ops inside
/// the handler.
fn workspaceCommandsCtx() wasm_workspace_commands.Ctx {
    return .{
        .gpa = wasm_allocator,
        .handler = &handler,
        .outbox = &outbox,
        .sendResult = sendResult,
        .sendErrorCode = sendErrorCode,
        .lifecycleCtx = lifecycleCtx(),
    };
}

fn handleRecomputeMinifyInsights(root: std.json.ObjectMap, _: ?std.json.Value) void {
    wasm_workspace_commands.handleRecomputeMinifyInsights(workspaceCommandsCtx(), root);
}

fn handleReflect(root: std.json.ObjectMap, id: ?std.json.Value) void {
    wasm_workspace_commands.handleReflect(workspaceCommandsCtx(), root, id);
}

fn handleExecuteCommand(root: std.json.ObjectMap, id: ?std.json.Value) void {
    wasm_workspace_commands.handleExecuteCommand(workspaceCommandsCtx(), root, id);
}

fn lifecycleCtx() wasm_lifecycle.Ctx {
    return .{
        .gpa = wasm_allocator,
        .handler = &handler,
        .outbox = &outbox,
        .client_supports_configuration = &client_supports_configuration,
        .next_request_id = &next_request_id,
        .pending_config_id = &pending_config_id,
        .sendResult = sendResult,
    };
}

fn handleInitialize(root: std.json.ObjectMap, id: ?std.json.Value) void {
    wasm_lifecycle.handleInitialize(lifecycleCtx(), root, id);
}

fn handleResponse(root: std.json.ObjectMap) void {
    wasm_lifecycle.handleResponse(lifecycleCtx(), root);
}

fn republishAllDocuments() void {
    wasm_lifecycle.republishAllDocuments(lifecycleCtx());
}

// =========================================================================
// Code Actions
// =========================================================================

fn codeActionCtx() wasm_code_actions.Ctx {
    return .{ .gpa = wasm_allocator, .handler = &handler, .sendResult = sendResult };
}

fn handleCodeAction(root: std.json.ObjectMap, id: ?std.json.Value) void {
    wasm_code_actions.handle(codeActionCtx(), root, id);
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

fn navCtx() wasm_navigation.Ctx {
    return .{ .gpa = wasm_allocator, .handler = &handler, .sendResult = sendResult };
}

fn handleHover(root: std.json.ObjectMap, id: ?std.json.Value) void {
    wasm_navigation.handleHover(navCtx(), root, id);
}

fn formatRange(buf: *std.ArrayListUnmanaged(u8), range: Handler.Range) void {
    json.formatRange(buf, wasm_allocator, range);
}

fn handleDefinition(root: std.json.ObjectMap, id: ?std.json.Value) void {
    wasm_navigation.handleDefinition(navCtx(), root, id);
}

fn handleReferences(root: std.json.ObjectMap, id: ?std.json.Value) void {
    wasm_navigation.handleReferences(navCtx(), root, id);
}

fn handleDocumentHighlight(root: std.json.ObjectMap, id: ?std.json.Value) void {
    wasm_navigation.handleDocumentHighlight(navCtx(), root, id);
}

fn symbolsCtx() wasm_symbols.Ctx {
    return .{ .gpa = wasm_allocator, .handler = &handler, .sendResult = sendResult };
}

fn handleRename(root: std.json.ObjectMap, id: ?std.json.Value) void {
    wasm_symbols.handleRename(symbolsCtx(), root, id);
}

fn handlePrepareRename(root: std.json.ObjectMap, id: ?std.json.Value) void {
    wasm_symbols.handlePrepareRename(symbolsCtx(), root, id);
}

fn editingCtx() wasm_editing.Ctx {
    return .{ .gpa = wasm_allocator, .handler = &handler, .sendResult = sendResult };
}

fn handleCompletion(root: std.json.ObjectMap, id: ?std.json.Value) void {
    wasm_editing.handleCompletion(editingCtx(), root, id);
}

fn handleSignatureHelp(root: std.json.ObjectMap, id: ?std.json.Value) void {
    wasm_editing.handleSignatureHelp(editingCtx(), root, id);
}

fn handleDocumentSymbol(root: std.json.ObjectMap, id: ?std.json.Value) void {
    wasm_symbols.handleDocumentSymbol(symbolsCtx(), root, id);
}

fn handleFoldingRange(root: std.json.ObjectMap, id: ?std.json.Value) void {
    wasm_editing.handleFoldingRange(editingCtx(), root, id);
}

fn handleTypeDefinition(root: std.json.ObjectMap, id: ?std.json.Value) void {
    wasm_navigation.handleTypeDefinition(navCtx(), root, id);
}

fn handleInlayHint(root: std.json.ObjectMap, id: ?std.json.Value) void {
    wasm_editing.handleInlayHint(editingCtx(), root, id);
}

fn handleCodeLens(root: std.json.ObjectMap, id: ?std.json.Value) void {
    wasm_editing.handleCodeLens(editingCtx(), root, id);
}

fn handleFormatting(root: std.json.ObjectMap, id: ?std.json.Value) void {
    wasm_editing.handleFormatting(editingCtx(), root, id);
}

fn handleSemanticTokens(root: std.json.ObjectMap, id: ?std.json.Value) void {
    wasm_editing.handleSemanticTokens(editingCtx(), root, id);
}

fn handleSelectionRange(root: std.json.ObjectMap, id: ?std.json.Value) void {
    wasm_editing.handleSelectionRange(editingCtx(), root, id);
}

fn callHierarchyCtx() wasm_call_hierarchy.Ctx {
    return .{ .gpa = wasm_allocator, .handler = &handler, .sendResult = sendResult };
}

fn handlePrepareCallHierarchy(root: std.json.ObjectMap, id: ?std.json.Value) void {
    wasm_call_hierarchy.handlePrepare(callHierarchyCtx(), root, id);
}

fn handleIncomingCalls(root: std.json.ObjectMap, id: ?std.json.Value) void {
    wasm_call_hierarchy.handleIncomingCalls(callHierarchyCtx(), root, id);
}

fn handleOutgoingCalls(root: std.json.ObjectMap, id: ?std.json.Value) void {
    wasm_call_hierarchy.handleOutgoingCalls(callHierarchyCtx(), root, id);
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
