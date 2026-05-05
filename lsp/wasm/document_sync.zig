//! WASM document-sync adapters. Manual JSON parsing of the four
//! `textDocument/did*` notifications, then delegates to the shared
//! Handler. Diagnostic emission is routed through `wasm_diagnostics`.

const std = @import("std");
const Handler = @import("Handler");
const wgslender = @import("wgslender");
const json = @import("json.zig");
const wasm_diagnostics = @import("diagnostics.zig");

const Diagnostic = wgslender.Diagnostic;

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    handler: *Handler,
    outbox: *std.ArrayListUnmanaged([]u8),

    fn diagCtx(self: Ctx) wasm_diagnostics.Ctx {
        return .{ .gpa = self.gpa, .handler = self.handler, .outbox = self.outbox };
    }

    fn enqueue(self: Ctx, msg: []u8) void {
        self.outbox.append(self.gpa, msg) catch self.gpa.free(msg);
    }
};

pub fn handleDidOpen(ctx: Ctx, root: std.json.ObjectMap) void {
    const params = root.getPtr("params") orelse return;
    const td = json.objGet(params, "textDocument") orelse return;
    const uri = json.strVal(json.objGet(td, "uri")) orelse return;
    const text = json.strVal(json.objGet(td, "text")) orelse return;
    const version: i32 = if (json.intVal(json.objGet(td, "version"))) |v| @intCast(v) else 0;
    ctx.handler.openDocument(uri, text, version) catch return;
    wasm_diagnostics.emitDiagnostics(ctx.diagCtx(), uri);
}

pub fn handleDidChange(ctx: Ctx, root: std.json.ObjectMap) void {
    const params = root.getPtr("params") orelse return;
    const td = json.objGet(params, "textDocument") orelse return;
    const uri = json.strVal(json.objGet(td, "uri")) orelse return;
    const changes = switch ((json.objGet(params, "contentChanges") orelse return).*) {
        .array => |a| a.items,
        else => return,
    };
    if (changes.len == 0) return;

    for (changes) |*change_val| {
        const change = json.objGet(change_val, "text") orelse continue;
        const text = json.strVal(change) orelse continue;
        const range_val = json.objGet(change_val, "range");
        if (range_val) |rv| {
            const start_obj = json.objGet(rv, "start");
            const end_obj = json.objGet(rv, "end");
            const start_line: u32 = if (json.intVal(if (start_obj) |s| json.objGet(s, "line") else null)) |v| @intCast(v) else continue;
            const start_char: u32 = if (json.intVal(if (start_obj) |s| json.objGet(s, "character") else null)) |v| @intCast(v) else continue;
            const end_line: u32 = if (json.intVal(if (end_obj) |e| json.objGet(e, "line") else null)) |v| @intCast(v) else continue;
            const end_char: u32 = if (json.intVal(if (end_obj) |e| json.objGet(e, "character") else null)) |v| @intCast(v) else continue;
            ctx.handler.changeDocumentIncremental(uri, .{
                .start = .{ .line = start_line, .character = start_char },
                .end = .{ .line = end_line, .character = end_char },
            }, text) catch continue;
        } else {
            ctx.handler.changeDocument(uri, text) catch continue;
        }
    }
    // Phase 7: cheap-path on the hot edit channel. The JS client schedules
    // `wgslender/recomputeMinifyInsights` after typing settles to surface
    // M-rule diagnostics.
    wasm_diagnostics.emitDiagnosticsCheap(ctx.diagCtx(), uri);
}

pub fn handleDidClose(ctx: Ctx, root: std.json.ObjectMap) void {
    const uri = json.extractUri(root) orelse return;
    ctx.handler.closeDocument(uri);

    // Clear diagnostics.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    json.appendStr(&buf, ctx.gpa, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"");
    Diagnostic.appendJsonEscaped(&buf, ctx.gpa, uri) catch return;
    json.appendStr(&buf, ctx.gpa, "\",\"diagnostics\":[]}}");
    ctx.enqueue(buf.toOwnedSlice(ctx.gpa) catch return);
}

pub fn handleDidSave(ctx: Ctx, root: std.json.ObjectMap) void {
    const uri = json.extractUri(root) orelse return;
    ctx.handler.handleDidSave(uri);
    wasm_diagnostics.emitDiagnostics(ctx.diagCtx(), uri);
}
