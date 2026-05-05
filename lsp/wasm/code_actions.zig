//! WASM `textDocument/codeAction` adapter. Hand-builds JSON to keep
//! lsp-kit out of the WASM binary; reads `params.context.diagnostics`
//! through the shared `wire.diagnostics.parseDiagnosticItems` codec, and
//! emits each action's embedded diagnostic via the same encoder used by
//! `publishDiagnostics` so a `data` payload survives the round-trip.

const std = @import("std");
const Handler = @import("Handler");
const wgslender = @import("wgslender");
const wire = @import("wire");
const json = wire.primitives;
const wire_diag = wire.diagnostics;

const Diagnostic = wgslender.Diagnostic;

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    handler: *Handler,
    sendResult: *const fn (id: ?std.json.Value, result_json: []const u8) void,
};

pub fn handle(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const params = root.getPtr("params") orelse return;
    const td = json.objGet(params, "textDocument") orelse return;
    const uri = json.strVal(json.objGet(td, "uri")) orelse return;

    const context = json.objGet(params, "context") orelse return;
    const diag_array = switch ((json.objGet(context, "diagnostics") orelse return).*) {
        .array => |a| a.items,
        else => return,
    };

    const handler_diags = wire_diag.parseDiagnosticItems(ctx.gpa, diag_array) orelse return;
    defer ctx.gpa.free(handler_diags);

    const actions = ctx.handler.computeCodeActions(handler_diags) catch return;
    defer Handler.freeCodeActions(ctx.gpa, actions);

    buildJsonResponse(ctx, id, uri, actions);
}

fn buildJsonResponse(
    ctx: Ctx,
    id: ?std.json.Value,
    uri: []const u8,
    actions: []const Handler.LspCodeAction,
) void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    json.appendStr(&buf, ctx.gpa, "[");

    for (actions, 0..) |action, ai| {
        if (ai > 0) buf.append(ctx.gpa, ',') catch {};
        json.appendStr(&buf, ctx.gpa, "{\"title\":\"");
        Diagnostic.appendJsonEscaped(&buf, ctx.gpa, action.title) catch return;
        json.appendStr(&buf, ctx.gpa, "\",\"kind\":\"quickfix\"");
        if (action.is_preferred) {
            json.appendStr(&buf, ctx.gpa, ",\"isPreferred\":true");
        }

        json.appendStr(&buf, ctx.gpa, ",\"diagnostics\":[");
        wire_diag.appendDiagnosticItem(&buf, ctx.gpa, uri, action.diagnostic);
        json.appendStr(&buf, ctx.gpa, "]");

        json.appendStr(&buf, ctx.gpa, ",\"edit\":{\"changes\":{\"");
        Diagnostic.appendJsonEscaped(&buf, ctx.gpa, uri) catch return;
        json.appendStr(&buf, ctx.gpa, "\":[");
        for (action.edits, 0..) |edit, ei| {
            if (ei > 0) buf.append(ctx.gpa, ',') catch {};
            json.appendStr(&buf, ctx.gpa, "{\"range\":{\"start\":{\"line\":");
            json.appendUint(&buf, ctx.gpa, edit.range.start.line);
            json.appendStr(&buf, ctx.gpa, ",\"character\":");
            json.appendUint(&buf, ctx.gpa, edit.range.start.character);
            json.appendStr(&buf, ctx.gpa, "},\"end\":{\"line\":");
            json.appendUint(&buf, ctx.gpa, edit.range.end.line);
            json.appendStr(&buf, ctx.gpa, ",\"character\":");
            json.appendUint(&buf, ctx.gpa, edit.range.end.character);
            json.appendStr(&buf, ctx.gpa, "}},\"newText\":\"");
            Diagnostic.appendJsonEscaped(&buf, ctx.gpa, edit.new_text) catch return;
            json.appendStr(&buf, ctx.gpa, "\"}");
        }
        json.appendStr(&buf, ctx.gpa, "]}}}");
    }

    json.appendStr(&buf, ctx.gpa, "]");
    const body = buf.toOwnedSlice(ctx.gpa) catch return;
    defer ctx.gpa.free(body);
    ctx.sendResult(id, body);
}
