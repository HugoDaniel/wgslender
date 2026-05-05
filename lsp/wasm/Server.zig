//! Per-instance state for the WASM LSP server.
//!
//! `wasm.zig` owns a single static `Server` instance because the C-ABI
//! exports operate on the wasm-allocator-backed module-level state. Per-
//! feature WASM adapters under `lsp/wasm/<feature>.zig` take `*Server` so
//! they don't need to reach into globals.
//!
//! Handler is stored by value (kept where it's always lived); pointer
//! identity is preserved across calls because `Server` is a single global.

const std = @import("std");
const Handler = @import("Handler");
const json = @import("json.zig");

const Server = @This();

handler: Handler,
outbox: std.ArrayListUnmanaged([]u8) = .empty,
gpa: std.mem.Allocator,
/// True iff the client advertised `workspace.configuration` in InitializeParams.
client_supports_configuration: bool = false,
next_request_id: i64 = 1,
/// ID of the in-flight `workspace/configuration` request, if any.
pending_config_id: ?i64 = null,

pub fn init(gpa: std.mem.Allocator) Server {
    return .{
        .handler = Handler.init(gpa),
        .gpa = gpa,
    };
}

/// Take ownership of `msg` and queue it for the next `recv` call. On
/// allocation failure the message is freed (best-effort — the dropped
/// frame is the failure mode).
pub fn enqueue(self: *Server, msg: []u8) void {
    self.outbox.append(self.gpa, msg) catch self.gpa.free(msg);
}

/// Send a JSON-RPC `result` response. `result_json` is the already-
/// serialised value for the `"result"` field — it is not re-quoted.
pub fn sendResult(self: *Server, id: ?std.json.Value, result_json: []const u8) void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    json.appendStr(&buf, self.gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
    json.appendId(&buf, self.gpa, id);
    json.appendStr(&buf, self.gpa, ",\"result\":");
    buf.appendSlice(self.gpa, result_json) catch return;
    buf.append(self.gpa, '}') catch return;
    self.enqueue(buf.toOwnedSlice(self.gpa) catch return);
}

/// Send a JSON-RPC `error` response with the given numeric code and
/// message. The message is JSON-escaped for `"` and `\` only — full
/// escape isn't needed since the codes are server-authored.
pub fn sendErrorCode(self: *Server, id: ?std.json.Value, code: i32, message: []const u8) void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    json.appendStr(&buf, self.gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
    json.appendId(&buf, self.gpa, id);
    json.appendStr(&buf, self.gpa, ",\"error\":{\"code\":");
    var num_buf: [12]u8 = undefined;
    const s = std.fmt.bufPrint(&num_buf, "{d}", .{code}) catch return;
    buf.appendSlice(self.gpa, s) catch return;
    json.appendStr(&buf, self.gpa, ",\"message\":\"");
    for (message) |c| {
        if (c == '"' or c == '\\') buf.append(self.gpa, '\\') catch return;
        buf.append(self.gpa, c) catch return;
    }
    json.appendStr(&buf, self.gpa, "\"}}");
    self.enqueue(buf.toOwnedSlice(self.gpa) catch return);
}
