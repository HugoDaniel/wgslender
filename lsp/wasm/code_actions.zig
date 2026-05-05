//! WASM `textDocument/codeAction` adapter. Thin dispatch shim — parses
//! `params.context.diagnostics` via the shared `wire/diagnostics.zig`
//! codec, calls `Handler.computeCodeActions`, encodes the result via
//! `wire/code_actions.zig`. lsp-kit-free.

const std = @import("std");
const Handler = @import("Handler");
const wire = @import("wire");
const json = wire.primitives;
const wire_diag = wire.diagnostics;
const wire_actions = wire.code_actions;

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

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire_actions.appendCodeActionItems(&buf, ctx.gpa, uri, actions);
    const body = buf.toOwnedSlice(ctx.gpa) catch return;
    defer ctx.gpa.free(body);
    ctx.sendResult(id, body);
}
