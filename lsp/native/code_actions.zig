//! Native (lsp-kit) `textDocument/codeAction` adapter. Thin dispatch
//! shim — parses `params.context.diagnostics` via `lspkit.code_actions`,
//! calls `Handler.computeCodeActions`, encodes the result via the same
//! codec. The NativeServer wrapper handles locking and forwards here.

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");
const lspkit = @import("lspkit");
const ca_codec = lspkit.code_actions;

pub fn handle(
    h: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.CodeAction.Params,
) ?[]const lsp.types.CodeAction.Result {
    const handler_diags = ca_codec.fromLspKitClientDiagnostics(arena, params.context.diagnostics) catch return null;
    const actions = h.computeCodeActions(handler_diags) catch return null;
    defer Handler.freeCodeActions(h.gpa, actions);
    if (actions.len == 0) return null;
    return ca_codec.toLspKitCodeActions(arena, params.textDocument.uri, actions) catch null;
}
