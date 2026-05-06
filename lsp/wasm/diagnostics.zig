//! WASM transport glue for diagnostics.
//!
//! Encoders/decoders live in `lsp/wire/diagnostics.zig` (shared with the
//! native parity harness); this file owns the per-instance outbox and
//! drives the LSP 3.17 push (`publishDiagnostics`) and pull
//! (`textDocument/diagnostic`) flows.

const std = @import("std");
const Handler = @import("Handler");
const wgslender = @import("wgslender");
const wire = @import("wire");
const json = wire.primitives;

const Diagnostic = wgslender.Diagnostic;

/// Mutable handles a WASM-feature module needs to publish a notification
/// or send a response back through the outbox.
pub const Ctx = struct {
    gpa: std.mem.Allocator,
    handler: *Handler,
    outbox: *std.ArrayList([]u8),

    fn enqueue(self: Ctx, msg: []u8) void {
        self.outbox.append(self.gpa, msg) catch self.gpa.free(msg);
    }
};

/// Full-path emit: validator + minify lint pack. Used by didOpen, didSave,
/// and `wgslender/recomputeMinifyInsights` — every path where the user
/// expects M-rule diagnostics on the next paint.
pub fn emitDiagnostics(ctx: Ctx, uri: []const u8) void {
    emitDiagnosticsImpl(ctx, uri, true);
}

/// Cheap-path emit: validator + unused-symbol warnings only. Used by the
/// `didChange` hot loop so a 100-keystroke burst doesn't run the estimator
/// every frame. JS clients schedule a `recomputeMinifyInsights`
/// notification on idle (~300 ms) to surface M-rule diagnostics.
pub fn emitDiagnosticsCheap(ctx: Ctx, uri: []const u8) void {
    emitDiagnosticsImpl(ctx, uri, false);
}

fn emitDiagnosticsImpl(ctx: Ctx, uri: []const u8, include_minify_lints: bool) void {
    if (!ctx.handler.diagnosticsEnabled()) return;
    const diags = if (include_minify_lints)
        ctx.handler.validateDocumentFull(uri) catch return
    else
        ctx.handler.validateDocumentCheap(uri) catch return;
    defer Handler.freeDiagnostics(ctx.handler.gpa, diags);

    var buf: std.ArrayList(u8) = .empty;
    json.appendStr(&buf, ctx.gpa, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"");
    Diagnostic.appendJsonEscaped(&buf, ctx.gpa, uri) catch return;
    json.appendStr(&buf, ctx.gpa, "\",\"diagnostics\":");
    wire.diagnostics.appendDiagnosticItems(&buf, ctx.gpa, uri, diags);
    json.appendStr(&buf, ctx.gpa, "}}");
    ctx.enqueue(buf.toOwnedSlice(ctx.gpa) catch return);
}

/// Pull-model diagnostics (LSP 3.17 `textDocument/diagnostic`). Returns a
/// Full report (or Unchanged when `previousResultId` matches the current
/// revision key). Unknown URIs and `diagnostics.enabled=false` both answer
/// with an empty Full report — pull clients wait for a response, so
/// silence would hang the UI.
///
/// The settings/document/short-circuit decision tree lives in
/// `Handler.producePullReport`; this function only handles transport-level
/// param parsing, the empty-Full fallback on internal errors, and JSON
/// framing of the result envelope.
pub fn handlePullDiagnostic(
    ctx: Ctx,
    sendResult: *const fn (id: ?std.json.Value, result_json: []const u8) void,
    root: std.json.ObjectMap,
    id: ?std.json.Value,
) void {
    if (id == null) return;
    const empty_full = "{\"kind\":\"full\",\"items\":[]}";
    const params = root.getPtr("params") orelse return sendResult(id, empty_full);
    const td = json.objGet(params, "textDocument") orelse return sendResult(id, empty_full);
    const uri = json.strVal(json.objGet(td, "uri")) orelse return sendResult(id, empty_full);
    const prev = json.strVal(json.objGet(params, "previousResultId"));

    const report = Handler.producePullReport(ctx.handler, ctx.gpa, uri, prev) catch
        return sendResult(id, empty_full);
    defer switch (report) {
        .unchanged => |u| ctx.gpa.free(u.result_id),
        .full => |f| {
            Handler.freeDiagnostics(ctx.handler.gpa, @constCast(f.items));
            if (f.result_id) |r| ctx.gpa.free(r);
        },
    };

    var buf: std.ArrayList(u8) = .empty;
    switch (report) {
        .unchanged => |u| {
            json.appendStr(&buf, ctx.gpa, "{\"kind\":\"unchanged\",\"resultId\":\"");
            json.appendStr(&buf, ctx.gpa, u.result_id);
            json.appendStr(&buf, ctx.gpa, "\"}");
        },
        .full => |f| {
            json.appendStr(&buf, ctx.gpa, "{\"kind\":\"full\"");
            if (f.result_id) |cur| {
                json.appendStr(&buf, ctx.gpa, ",\"resultId\":\"");
                json.appendStr(&buf, ctx.gpa, cur);
                json.appendStr(&buf, ctx.gpa, "\"");
            }
            json.appendStr(&buf, ctx.gpa, ",\"items\":");
            wire.diagnostics.appendDiagnosticItems(&buf, ctx.gpa, uri, f.items);
            json.appendStr(&buf, ctx.gpa, "}");
        },
    }
    const body = buf.toOwnedSlice(ctx.gpa) catch return;
    defer ctx.gpa.free(body);
    sendResult(id, body);
}
