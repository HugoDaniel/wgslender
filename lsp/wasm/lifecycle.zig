//! WASM lifecycle handlers: initialize, the `workspace/configuration`
//! request/response pair, and `workspace/didChangeConfiguration`. Pure
//! Handler-call + JSON-build logic; the wasm.zig dispatcher binds the
//! globals into the Ctx.

const std = @import("std");
const Handler = @import("Handler");
const wgslender = @import("wgslender");
const wire = @import("wire");
const json = wire.primitives;
const wasm_diagnostics = @import("diagnostics.zig");

const Diagnostic = wgslender.Diagnostic;

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    handler: *Handler,
    outbox: *std.ArrayList([]u8),
    client_supports_configuration: *bool,
    next_request_id: *i64,
    pending_config_id: *?i64,
    sendResult: *const fn (id: ?std.json.Value, result_json: []const u8) void,

    fn enqueue(self: Ctx, msg: []u8) void {
        self.outbox.append(self.gpa, msg) catch self.gpa.free(msg);
    }

    fn diagCtx(self: Ctx) wasm_diagnostics.Ctx {
        return .{ .gpa = self.gpa, .handler = self.handler, .outbox = self.outbox };
    }
};

pub fn handleInitialize(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    if (root.getPtr("params")) |params| {
        if (json.objGet(params, "capabilities")) |cap|
            if (json.objGet(cap, "workspace")) |ws|
                if (json.objGet(ws, "configuration")) |c| switch (c.*) {
                    .bool => |b| ctx.client_supports_configuration.* = b,
                    else => {},
                };
        if (json.objGet(params, "initializationOptions")) |opts|
            ctx.handler.applyClientConfig(opts.*);
    }
    ctx.sendResult(id, "{\"capabilities\":" ++ Handler.capabilities_json ++ ",\"serverInfo\":{\"name\":\"wgslender-lsp\",\"version\":\"1.1.0\"}}");
}

pub fn handleDidChangeConfiguration(ctx: Ctx) void {
    if (!ctx.client_supports_configuration.*) return;
    sendConfigurationRequest(ctx);
}

/// Send a `workspace/configuration` request for the `wgslender` section.
/// The response is handled by `handleResponse`.
pub fn sendConfigurationRequest(ctx: Ctx) void {
    const id = ctx.next_request_id.*;
    ctx.next_request_id.* +%= 1;

    var buf: std.ArrayList(u8) = .empty;
    json.appendStr(&buf, ctx.gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
    json.appendI64(&buf, ctx.gpa, id);
    json.appendStr(&buf, ctx.gpa, ",\"method\":\"workspace/configuration\",\"params\":{\"items\":[{\"section\":\"wgslender\"}]}}");
    const msg = buf.toOwnedSlice(ctx.gpa) catch return;
    ctx.enqueue(msg);
    ctx.pending_config_id.* = id;
}

/// Routes a `workspace/configuration` response back into Handler config and
/// republishes diagnostics for every open document.
pub fn handleResponse(ctx: Ctx, root: std.json.ObjectMap) void {
    const id_val = root.get("id") orelse return;
    const id: i64 = switch (id_val) {
        .integer => |n| n,
        else => return,
    };
    if (ctx.pending_config_id.* == null or ctx.pending_config_id.*.? != id) return;
    ctx.pending_config_id.* = null;

    const result_val = root.get("result") orelse return;
    const arr = switch (result_val) {
        .array => |a| a,
        else => return,
    };
    if (arr.items.len == 0) return;
    ctx.handler.applyClientConfig(arr.items[0]);
    republishAllDocuments(ctx);
}

/// Re-publish diagnostics (or empty list when disabled) for every open URI.
/// Called from settings-change paths and `workspace/executeCommand`.
pub fn republishAllDocuments(ctx: Ctx) void {
    var it = ctx.handler.documents.iterator();
    while (it.next()) |entry| {
        const uri = entry.key_ptr.*;
        if (ctx.handler.diagnosticsEnabled()) {
            wasm_diagnostics.emitDiagnostics(ctx.diagCtx(), uri);
        } else {
            var buf: std.ArrayList(u8) = .empty;
            json.appendStr(&buf, ctx.gpa, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"");
            Diagnostic.appendJsonEscaped(&buf, ctx.gpa, uri) catch return;
            json.appendStr(&buf, ctx.gpa, "\",\"diagnostics\":[]}}");
            ctx.enqueue(buf.toOwnedSlice(ctx.gpa) catch return);
        }
    }
}
