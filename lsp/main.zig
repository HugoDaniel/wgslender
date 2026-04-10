//! WGSL Language Server — native entry point.
//!
//! Runs the LSP server over stdio using lsp-kit's basic_server framework.
//! All WGSL-specific logic lives in Handler.zig (shared with WASM entry).

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler.zig");

pub fn main(init: std.process.Init) !void {
    var read_buffer: [4096]u8 = undefined;
    var stdio_transport: lsp.Transport.Stdio = .init(&read_buffer, .stdin(), .stdout());
    const transport: *lsp.Transport = &stdio_transport.transport;

    var server: NativeServer = .init(init.gpa, transport, init.io);
    defer server.deinit();

    try lsp.basic_server.run(init.io, init.gpa, transport, &server, std.log.err);
}

/// Thin wrapper that adapts the transport-agnostic Handler to lsp-kit's
/// basic_server callback interface. Converts Handler diagnostics to
/// lsp-kit types and handles notification delivery via transport.
const NativeServer = struct {
    handler: Handler,
    transport: *lsp.Transport,
    io: std.Io,

    fn init(allocator: std.mem.Allocator, transport: *lsp.Transport, io: std.Io) NativeServer {
        return .{
            .handler = .init(allocator),
            .transport = transport,
            .io = io,
        };
    }

    fn deinit(self: *NativeServer) void {
        self.handler.deinit();
    }

    // ----- LSP lifecycle -----

    pub fn initialize(
        _: *NativeServer,
        _: std.mem.Allocator,
        _: lsp.types.InitializeParams,
    ) lsp.types.InitializeResult {
        return .{
            .serverInfo = .{ .name = "wgslender-lsp", .version = "0.1.0" },
            .capabilities = .{
                .positionEncoding = .@"utf-16",
                .textDocumentSync = .{
                    .text_document_sync_options = .{
                        .openClose = true,
                        .change = .Full,
                    },
                },
                .codeActionProvider = .{
                    .code_action_options = .{
                        .codeActionKinds = &.{.quickfix},
                    },
                },
            },
        };
    }

    pub fn initialized(_: *NativeServer, _: std.mem.Allocator, _: lsp.types.InitializedParams) void {}
    pub fn shutdown(_: *NativeServer, _: std.mem.Allocator, _: void) ?void { return null; }
    pub fn exit(_: *NativeServer, _: std.mem.Allocator, _: void) void {}
    pub fn onResponse(_: *NativeServer, _: std.mem.Allocator, _: lsp.JsonRPCMessage.Response) void {}

    // ----- Document sync -----

    pub fn @"textDocument/didOpen"(
        self: *NativeServer,
        _: std.mem.Allocator,
        notification: lsp.types.TextDocument.DidOpenParams,
    ) !void {
        const uri = notification.textDocument.uri;
        try self.handler.openDocument(uri, notification.textDocument.text, notification.textDocument.version);
        self.publishDiagnostics(uri);
    }

    pub fn @"textDocument/didChange"(
        self: *NativeServer,
        _: std.mem.Allocator,
        notification: lsp.types.TextDocument.DidChangeParams,
    ) !void {
        const uri = notification.textDocument.uri;
        for (notification.contentChanges) |change| {
            switch (change) {
                .text_document_content_change_whole_document => |full| {
                    try self.handler.changeDocument(uri, full.text);
                },
                .text_document_content_change_partial => {},
            }
        }
        self.publishDiagnostics(uri);
    }

    pub fn @"textDocument/didClose"(
        self: *NativeServer,
        _: std.mem.Allocator,
        notification: lsp.types.TextDocument.DidCloseParams,
    ) !void {
        const uri = notification.textDocument.uri;
        self.handler.closeDocument(uri);
        self.transport.writeNotification(
            self.io, self.handler.allocator,
            "textDocument/publishDiagnostics",
            lsp.types.publish_diagnostics.Params,
            .{ .uri = uri, .diagnostics = &.{} },
            .{ .emit_null_optional_fields = false },
        ) catch {};
    }

    // ----- Code Actions -----

    pub fn @"textDocument/codeAction"(
        self: *NativeServer,
        arena: std.mem.Allocator,
        params: lsp.types.CodeAction.Params,
    ) ?[]const lsp.types.CodeAction.Result {
        const handler_diags = convertClientDiagnostics(arena, params.context.diagnostics) orelse return null;
        const actions = self.handler.computeCodeActions(handler_diags) catch return null;
        if (actions.len == 0) return null;
        return convertToLspCodeActions(arena, params.textDocument.uri, actions);
    }

    fn convertClientDiagnostics(arena: std.mem.Allocator, diagnostics: []const lsp.types.Diagnostic) ?[]Handler.LspDiagnostic {
        const handler_diags = arena.alloc(Handler.LspDiagnostic, diagnostics.len) catch return null;
        for (diagnostics, 0..) |d, i| {
            handler_diags[i] = .{
                .range = .{
                    .start = .{ .line = d.range.start.line, .character = d.range.start.character },
                    .end = .{ .line = d.range.end.line, .character = d.range.end.character },
                },
                .severity = if (d.severity) |s| switch (s) {
                    .Error => .@"error",
                    .Warning => .warning,
                    .Information => .information,
                    .Hint => .hint,
                    _ => .information,
                } else .information,
                .message = d.message,
                .code = if (d.code) |c| switch (c) {
                    .string => |s| s,
                    .number => "",
                } else "",
            };
        }
        return handler_diags;
    }

    fn convertToLspCodeActions(arena: std.mem.Allocator, uri: []const u8, actions: []const Handler.LspCodeAction) ?[]const lsp.types.CodeAction.Result {
        const results = arena.alloc(lsp.types.CodeAction.Result, actions.len) catch return null;
        for (actions, 0..) |action, i| {
            const text_edits = arena.alloc(lsp.types.TextEdit, action.edits.len) catch continue;
            for (action.edits, 0..) |edit, ei| {
                text_edits[ei] = .{
                    .range = .{
                        .start = .{ .line = edit.range.start.line, .character = edit.range.start.character },
                        .end = .{ .line = edit.range.end.line, .character = edit.range.end.character },
                    },
                    .newText = edit.new_text,
                };
            }

            const lsp_diag = lsp.types.Diagnostic{
                .range = .{
                    .start = .{ .line = action.diagnostic.range.start.line, .character = action.diagnostic.range.start.character },
                    .end = .{ .line = action.diagnostic.range.end.line, .character = action.diagnostic.range.end.character },
                },
                .severity = switch (action.diagnostic.severity) {
                    .@"error" => .Error,
                    .warning => .Warning,
                    .information => .Information,
                    .hint => .Hint,
                },
                .code = if (action.diagnostic.code.len > 0) .{ .string = action.diagnostic.code } else null,
                .source = "wgslender",
                .message = action.diagnostic.message,
            };
            const diag_slice = arena.alloc(lsp.types.Diagnostic, 1) catch continue;
            diag_slice[0] = lsp_diag;

            var changes = std.json.ArrayHashMap([]const lsp.types.TextEdit){};
            changes.map.put(arena, uri, text_edits) catch continue;

            results[i] = .{
                .code_action = .{
                    .title = action.title,
                    .kind = .quickfix,
                    .isPreferred = action.is_preferred,
                    .diagnostics = diag_slice,
                    .edit = .{ .changes = changes },
                },
            };
        }
        return results;
    }

    // ----- Helpers -----

    fn publishDiagnostics(self: *NativeServer, uri: []const u8) void {
        const source = self.handler.getDocumentSource(uri) orelse return;
        const diags = self.handler.validateDocument(source) catch return;
        defer Handler.freeDiagnostics(self.handler.allocator, diags);

        // Convert Handler diagnostics to lsp-kit types.
        const lsp_diags = self.handler.allocator.alloc(lsp.types.Diagnostic, diags.len) catch return;
        defer self.handler.allocator.free(lsp_diags);

        // Track related_info allocations so we can free them after serialization.
        var related_allocs: [256]?[]const lsp.types.Diagnostic.RelatedInformation = undefined;
        var related_count: usize = 0;

        for (diags, 0..) |d, i| {
            var related_info: ?[]const lsp.types.Diagnostic.RelatedInformation = null;
            if (d.related.len > 0) {
                const rel = self.handler.allocator.alloc(lsp.types.Diagnostic.RelatedInformation, d.related.len) catch null;
                if (rel) |r| {
                    for (d.related, 0..) |rel_item, ri| {
                        r[ri] = .{
                            .location = .{
                                .uri = uri,
                                .range = .{
                                    .start = .{ .line = rel_item.range.start.line, .character = rel_item.range.start.character },
                                    .end = .{ .line = rel_item.range.end.line, .character = rel_item.range.end.character },
                                },
                            },
                            .message = rel_item.message,
                        };
                    }
                    related_info = r;
                    if (related_count < related_allocs.len) {
                        related_allocs[related_count] = r;
                        related_count += 1;
                    }
                }
            }
            lsp_diags[i] = .{
                .range = .{
                    .start = .{ .line = d.range.start.line, .character = d.range.start.character },
                    .end = .{ .line = d.range.end.line, .character = d.range.end.character },
                },
                .severity = switch (d.severity) {
                    .@"error" => .Error,
                    .warning => .Warning,
                    .information => .Information,
                    .hint => .Hint,
                },
                .code = if (d.code.len > 0) .{ .string = d.code } else null,
                .codeDescription = if (d.spec_url.len > 0) .{ .href = d.spec_url } else null,
                .source = "wgslender",
                .message = d.message,
                .relatedInformation = related_info,
            };
        }

        self.transport.writeNotification(
            self.io, self.handler.allocator,
            "textDocument/publishDiagnostics",
            lsp.types.publish_diagnostics.Params,
            .{ .uri = uri, .diagnostics = lsp_diags },
            .{ .emit_null_optional_fields = false },
        ) catch {};

        // Free related_info arrays after serialization.
        for (related_allocs[0..related_count]) |ri| {
            if (ri) |r| self.handler.allocator.free(r);
        }
    }
};
