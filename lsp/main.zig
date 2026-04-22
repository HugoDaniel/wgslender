//! WGSL Language Server — native entry point.
//!
//! Runs the LSP server over stdio using lsp-kit's basic_server framework.
//! All WGSL-specific logic lives in Handler.zig (shared with WASM entry).

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");
const bridge = @import("bridge");

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
    /// True iff the client advertised `workspace.configuration` support in
    /// InitializeParams. Gates outgoing `workspace/configuration` requests
    /// — without it the client would reject the pull with method_not_found.
    client_supports_configuration: bool = false,
    next_request_id: i64 = 1,
    /// ID of the in-flight `workspace/configuration` request, if any.
    pending_config_id: ?i64 = null,

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

    /// Handles the LSP initialize request; returns server capabilities.
    pub fn initialize(
        self: *NativeServer,
        _: std.mem.Allocator,
        params: lsp.types.InitializeParams,
    ) lsp.types.InitializeResult {
        if (params.capabilities.workspace) |ws| {
            if (ws.configuration orelse false) self.client_supports_configuration = true;
        }
        if (params.initializationOptions) |opts| {
            self.handler.applyClientSettings(opts);
        }
        return .{
            .serverInfo = .{ .name = "wgslender-lsp", .version = "1.0.0" },
            .capabilities = .{
                .positionEncoding = .@"utf-16",
                .textDocumentSync = .{
                    .text_document_sync_options = .{
                        .openClose = true,
                        .change = .Incremental,
                        .save = .{ .save_options = .{ .includeText = false } },
                    },
                },
                .codeActionProvider = .{
                    .code_action_options = .{
                        .codeActionKinds = &.{.quickfix},
                    },
                },
                .hoverProvider = .{ .bool = true },
                .definitionProvider = .{ .bool = true },
                .referencesProvider = .{ .bool = true },
                .renameProvider = .{
                    .rename_options = .{ .prepareProvider = true },
                },
                .completionProvider = .{
                    .triggerCharacters = &.{ ".", "@" },
                },
                .signatureHelpProvider = .{
                    .triggerCharacters = &.{ "(", "," },
                },
                .documentSymbolProvider = .{ .bool = true },
                .foldingRangeProvider = .{ .bool = true },
                .typeDefinitionProvider = .{ .bool = true },
                .inlayHintProvider = .{ .bool = true },
                .codeLensProvider = .{},
                .documentFormattingProvider = .{ .bool = true },
                .callHierarchyProvider = .{ .bool = true },
                .selectionRangeProvider = .{ .bool = true },
                .semanticTokensProvider = .{
                    .semantic_tokens_options = .{
                        .full = .{ .bool = true },
                        .legend = .{
                            .tokenTypes = &[_][]const u8{
                                "keyword", "function", "struct",  "parameter", "variable",
                                "number",  "type",     "comment", "decorator",
                            },
                            .tokenModifiers = &[_][]const u8{
                                "declaration", "readonly", "defaultLibrary",
                            },
                        },
                    },
                },
            },
        };
    }

    /// No-op acknowledgement of the initialized notification.
    pub fn initialized(_: *NativeServer, _: std.mem.Allocator, _: lsp.types.InitializedParams) void {}
    /// Handles LSP shutdown; returns null (no pending work).
    pub fn shutdown(_: *NativeServer, _: std.mem.Allocator, _: void) ?void {
        return null;
    }
    /// No-op exit notification handler.
    pub fn exit(_: *NativeServer, _: std.mem.Allocator, _: void) void {}

    /// Routes client responses to any in-flight server-initiated request.
    /// Currently only `workspace/configuration` triggers an outgoing request;
    /// unrelated / unknown response IDs are ignored.
    pub fn onResponse(
        self: *NativeServer,
        _: std.mem.Allocator,
        response: lsp.JsonRPCMessage.Response,
    ) void {
        const resp_id = response.id orelse return;
        const id_number = switch (resp_id) {
            .number => |n| n,
            .string => return,
        };
        if (self.pending_config_id == null or self.pending_config_id.? != id_number) return;
        self.pending_config_id = null;

        const result = switch (response.result_or_error) {
            .result => |r| r orelse return,
            .@"error" => return,
        };
        // workspace/configuration returns one LSPAny per requested item.
        const arr = switch (result) { .array => |a| a, else => return };
        if (arr.items.len == 0) return;
        self.handler.applyClientSettings(arr.items[0]);
        self.republishAllDocuments();
    }

    // ----- Document sync -----

    /// Registers an opened document and publishes initial diagnostics.
    pub fn @"textDocument/didOpen"(
        self: *NativeServer,
        _: std.mem.Allocator,
        notification: lsp.types.TextDocument.DidOpenParams,
    ) !void {
        const uri = notification.textDocument.uri;
        try self.handler.openDocument(uri, notification.textDocument.text, notification.textDocument.version);
        self.publishDiagnostics(uri);
    }

    /// Updates document source on change and re-publishes diagnostics.
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
                .text_document_content_change_partial => |partial| {
                    try self.handler.changeDocumentIncremental(uri, .{
                        .start = .{ .line = partial.range.start.line, .character = partial.range.start.character },
                        .end = .{ .line = partial.range.end.line, .character = partial.range.end.character },
                    }, partial.text);
                },
            }
        }
        self.publishDiagnostics(uri);
    }

    /// Removes a closed document and clears its published diagnostics.
    pub fn @"textDocument/didClose"(
        self: *NativeServer,
        _: std.mem.Allocator,
        notification: lsp.types.TextDocument.DidCloseParams,
    ) !void {
        const uri = notification.textDocument.uri;
        self.handler.closeDocument(uri);
        self.transport.writeNotification(
            self.io,
            self.handler.gpa,
            "textDocument/publishDiagnostics",
            lsp.types.publish_diagnostics.Params,
            .{ .uri = uri, .diagnostics = &.{} },
            .{ .emit_null_optional_fields = false },
        ) catch {};
    }

    /// Handles `textDocument/didSave`. We don't trust the optional `text`
    /// field (we advertise `includeText: false`), so this just re-publishes
    /// diagnostics. Useful hook for future save-only flows.
    pub fn @"textDocument/didSave"(
        self: *NativeServer,
        _: std.mem.Allocator,
        notification: lsp.types.TextDocument.DidSaveParams,
    ) void {
        const uri = notification.textDocument.uri;
        self.handler.handleDidSave(uri);
        self.publishDiagnostics(uri);
    }

    /// Handles `workspace/didChangeConfiguration`. Per LSP issue #676 the
    /// parameters are unreliable; instead we pull the current settings back
    /// from the client via `workspace/configuration`. Only meaningful when
    /// the client advertised `workspace.configuration` support.
    pub fn @"workspace/didChangeConfiguration"(
        self: *NativeServer,
        _: std.mem.Allocator,
        _: lsp.types.workspace.configuration.did_change.Params,
    ) void {
        if (!self.client_supports_configuration) return;
        self.sendConfigurationRequest();
    }

    // ----- Code Actions -----

    /// Returns quick-fix code actions for the requested diagnostic range.
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

    // ----- Hover -----

    pub fn @"textDocument/hover"(
        self: *NativeServer,
        _: std.mem.Allocator,
        params: lsp.types.Hover.Params,
    ) ?lsp.types.Hover {
        const result = self.handler.computeHover(
            params.textDocument.uri,
            .{ .line = params.position.line, .character = params.position.character },
        ) catch return null;
        const r = result orelse return null;
        return .{
            .contents = .{ .markup_content = .{ .kind = .markdown, .value = r.contents } },
            .range = .{
                .start = .{ .line = r.range.start.line, .character = r.range.start.character },
                .end = .{ .line = r.range.end.line, .character = r.range.end.character },
            },
        };
    }

    // ----- Go-to-Definition -----

    pub fn @"textDocument/definition"(
        self: *NativeServer,
        _: std.mem.Allocator,
        params: lsp.types.Definition.Params,
    ) ?lsp.types.Definition.Result {
        const range = self.handler.computeDefinition(
            params.textDocument.uri,
            .{ .line = params.position.line, .character = params.position.character },
        ) catch return null;
        const r = range orelse return null;
        return .{
            .definition = .{
                .location = .{
                    .uri = params.textDocument.uri,
                    .range = .{
                        .start = .{ .line = r.start.line, .character = r.start.character },
                        .end = .{ .line = r.end.line, .character = r.end.character },
                    },
                },
            },
        };
    }

    // ----- Find References -----

    pub fn @"textDocument/references"(
        self: *NativeServer,
        arena: std.mem.Allocator,
        params: lsp.types.reference.Params,
    ) ?[]const lsp.types.Location {
        const refs = self.handler.computeReferences(
            params.textDocument.uri,
            .{ .line = params.position.line, .character = params.position.character },
            params.context.includeDeclaration,
        ) catch return null;
        const handler_refs = refs orelse return null;
        defer self.handler.gpa.free(handler_refs);
        const locations = arena.alloc(lsp.types.Location, handler_refs.len) catch return null;
        for (handler_refs, 0..) |ref, i| {
            locations[i] = .{
                .uri = params.textDocument.uri,
                .range = .{
                    .start = .{ .line = ref.start.line, .character = ref.start.character },
                    .end = .{ .line = ref.end.line, .character = ref.end.character },
                },
            };
        }
        return locations;
    }

    // ----- Document Highlight -----

    pub fn @"textDocument/documentHighlight"(
        self: *NativeServer,
        arena: std.mem.Allocator,
        params: lsp.types.DocumentHighlight.Params,
    ) ?[]const lsp.types.DocumentHighlight {
        const highlights = self.handler.computeDocumentHighlight(
            params.textDocument.uri,
            .{ .line = params.position.line, .character = params.position.character },
        ) catch return null;
        const handler_highlights = highlights orelse return null;
        defer self.handler.gpa.free(handler_highlights);
        const result = arena.alloc(lsp.types.DocumentHighlight, handler_highlights.len) catch return null;
        for (handler_highlights, 0..) |h, i| {
            result[i] = .{
                .range = .{
                    .start = .{ .line = h.range.start.line, .character = h.range.start.character },
                    .end = .{ .line = h.range.end.line, .character = h.range.end.character },
                },
                .kind = switch (h.kind) {
                    .text => .Text,
                    .read => .Read,
                    .write => .Write,
                },
            };
        }
        return result;
    }

    // ----- Rename -----

    pub fn @"textDocument/rename"(
        self: *NativeServer,
        arena: std.mem.Allocator,
        params: lsp.types.rename.Params,
    ) ?lsp.types.WorkspaceEdit {
        const edits = self.handler.computeRename(
            params.textDocument.uri,
            .{ .line = params.position.line, .character = params.position.character },
            params.newName,
        ) catch return null;
        const handler_edits = edits orelse return null;
        defer self.handler.gpa.free(handler_edits);
        const text_edits = arena.alloc(lsp.types.TextEdit, handler_edits.len) catch return null;
        for (handler_edits, 0..) |edit, i| {
            text_edits[i] = .{
                .range = .{
                    .start = .{ .line = edit.range.start.line, .character = edit.range.start.character },
                    .end = .{ .line = edit.range.end.line, .character = edit.range.end.character },
                },
                .newText = edit.new_text,
            };
        }
        var changes = std.json.ArrayHashMap([]const lsp.types.TextEdit){};
        changes.map.put(arena, params.textDocument.uri, text_edits) catch return null;
        return .{ .changes = changes };
    }

    pub fn @"textDocument/prepareRename"(
        self: *NativeServer,
        _: std.mem.Allocator,
        params: lsp.types.prepare_rename.Params,
    ) ?lsp.types.prepare_rename.Result {
        const range = self.handler.prepareRename(
            params.textDocument.uri,
            .{ .line = params.position.line, .character = params.position.character },
        ) catch return null;
        const r = range orelse return null;
        return .{
            .prepare_rename_placeholder = .{
                .range = .{
                    .start = .{ .line = r.start.line, .character = r.start.character },
                    .end = .{ .line = r.end.line, .character = r.end.character },
                },
                .placeholder = "",
            },
        };
    }

    // ----- Completion -----

    pub fn @"textDocument/completion"(
        self: *NativeServer,
        arena: std.mem.Allocator,
        params: lsp.types.completion.Params,
    ) ?lsp.types.completion.Result {
        const items = self.handler.computeCompletion(
            params.textDocument.uri,
            .{ .line = params.position.line, .character = params.position.character },
        ) catch return null;
        defer self.handler.gpa.free(items);
        if (items.len == 0) return null;
        const lsp_items = arena.alloc(lsp.types.completion.Item, items.len) catch return null;
        for (items, 0..) |item, i| {
            lsp_items[i] = .{
                .label = item.label,
                .kind = switch (item.kind) {
                    .variable => .Variable,
                    .function => .Function,
                    .struct_type => .Struct,
                    .field => .Field,
                    .keyword => .Keyword,
                    .builtin => .Function,
                    .type_name => .Class,
                    .attribute => .Property,
                },
                .detail = if (item.detail.len > 0) item.detail else null,
            };
        }
        return .{ .completion_items = lsp_items };
    }

    // ----- Signature Help -----

    pub fn @"textDocument/signatureHelp"(
        self: *NativeServer,
        arena: std.mem.Allocator,
        params: lsp.types.SignatureHelp.Params,
    ) ?lsp.types.SignatureHelp {
        const result = self.handler.computeSignatureHelp(
            params.textDocument.uri,
            .{ .line = params.position.line, .character = params.position.character },
        ) catch return null;
        const r = result orelse return null;

        const lsp_params = if (r.parameters.len > 0) blk: {
            const ps = arena.alloc(lsp.types.SignatureHelp.Signature.Parameter, r.parameters.len) catch break :blk null;
            for (r.parameters, 0..) |p, i| {
                ps[i] = .{ .label = .{ .string = p } };
            }
            break :blk ps;
        } else null;

        const sig = arena.alloc(lsp.types.SignatureHelp.Signature, 1) catch return null;
        sig[0] = .{
            .label = r.label,
            .parameters = lsp_params,
            .activeParameter = r.active_parameter,
        };

        return .{
            .signatures = sig,
            .activeSignature = 0,
            .activeParameter = r.active_parameter,
        };
    }

    // ----- Document Symbols -----

    pub fn @"textDocument/documentSymbol"(
        self: *NativeServer,
        arena: std.mem.Allocator,
        params: lsp.types.DocumentSymbol.Params,
    ) ?lsp.types.DocumentSymbol.Result {
        const symbols = self.handler.computeDocumentSymbols(params.textDocument.uri) catch return null;
        defer self.handler.gpa.free(symbols);
        if (symbols.len == 0) return null;
        const lsp_symbols = arena.alloc(lsp.types.DocumentSymbol, symbols.len) catch return null;
        for (symbols, 0..) |sym, i| {
            lsp_symbols[i] = convertDocSymbol(arena, sym);
        }
        return .{ .document_symbols = lsp_symbols };
    }

    fn convertDocSymbol(arena: std.mem.Allocator, sym: Handler.DocumentSymbolInfo) lsp.types.DocumentSymbol {
        var children: ?[]const lsp.types.DocumentSymbol = null;
        if (sym.children.len > 0) {
            const ch = arena.alloc(lsp.types.DocumentSymbol, sym.children.len) catch null;
            if (ch) |c| {
                for (sym.children, 0..) |child, ci| {
                    c[ci] = convertDocSymbol(arena, child);
                }
                children = c;
            }
        }
        return .{
            .name = sym.name,
            .kind = switch (sym.kind) {
                .function => .Function,
                .struct_type => .Struct,
                .variable => .Variable,
                .constant => .Constant,
                .field => .Field,
                .type_alias => .Class,
                .override => .Constant,
            },
            .range = .{
                .start = .{ .line = sym.range.start.line, .character = sym.range.start.character },
                .end = .{ .line = sym.range.end.line, .character = sym.range.end.character },
            },
            .selectionRange = .{
                .start = .{ .line = sym.selection_range.start.line, .character = sym.selection_range.start.character },
                .end = .{ .line = sym.selection_range.end.line, .character = sym.selection_range.end.character },
            },
            .children = children,
        };
    }

    // ----- Folding Ranges -----

    pub fn @"textDocument/foldingRange"(
        self: *NativeServer,
        arena: std.mem.Allocator,
        params: lsp.types.FoldingRange.Params,
    ) ?[]const lsp.types.FoldingRange {
        const ranges = self.handler.computeFoldingRanges(params.textDocument.uri) catch return null;
        defer self.handler.gpa.free(ranges);
        if (ranges.len == 0) return null;
        const lsp_ranges = arena.alloc(lsp.types.FoldingRange, ranges.len) catch return null;
        for (ranges, 0..) |r, i| {
            lsp_ranges[i] = .{
                .startLine = r.start_line,
                .endLine = r.end_line,
                .kind = switch (r.kind) {
                    .comment => .comment,
                    .region => .region,
                },
            };
        }
        return lsp_ranges;
    }

    // ----- Go-to-Type-Definition -----

    pub fn @"textDocument/typeDefinition"(
        self: *NativeServer,
        _: std.mem.Allocator,
        params: lsp.types.type_definition.Params,
    ) ?lsp.types.Definition.Result {
        const range = self.handler.computeTypeDefinition(
            params.textDocument.uri,
            .{ .line = params.position.line, .character = params.position.character },
        ) catch return null;
        const r = range orelse return null;
        return .{
            .definition = .{
                .location = .{
                    .uri = params.textDocument.uri,
                    .range = .{
                        .start = .{ .line = r.start.line, .character = r.start.character },
                        .end = .{ .line = r.end.line, .character = r.end.character },
                    },
                },
            },
        };
    }

    // ----- Inlay Hints -----

    pub fn @"textDocument/inlayHint"(
        self: *NativeServer,
        arena: std.mem.Allocator,
        params: lsp.types.InlayHint.Params,
    ) ?[]const lsp.types.InlayHint {
        const hints = self.handler.computeInlayHints(
            params.textDocument.uri,
            .{
                .start = .{ .line = params.range.start.line, .character = params.range.start.character },
                .end = .{ .line = params.range.end.line, .character = params.range.end.character },
            },
        ) catch return null;
        defer self.handler.gpa.free(hints);
        if (hints.len == 0) return null;
        const lsp_hints = arena.alloc(lsp.types.InlayHint, hints.len) catch return null;
        for (hints, 0..) |h, i| {
            const label: lsp.types.InlayHint.Label = if (h.def_range) |dr| blk: {
                const parts = arena.alloc(lsp.types.InlayHint.LabelPart, 1) catch return null;
                parts[0] = .{
                    .value = h.label,
                    .location = .{
                        .uri = params.textDocument.uri,
                        .range = .{
                            .start = .{ .line = dr.start.line, .character = dr.start.character },
                            .end = .{ .line = dr.end.line, .character = dr.end.character },
                        },
                    },
                };
                break :blk .{ .inlay_hint_label_parts = parts };
            } else .{ .string = h.label };
            lsp_hints[i] = .{
                .position = .{ .line = h.position.line, .character = h.position.character },
                .label = label,
                .kind = switch (h.kind) {
                    .type_hint, .const_value_hint => .Type,
                    .parameter_hint => .Parameter,
                },
            };
        }
        return lsp_hints;
    }

    // ----- Code Lens -----

    pub fn @"textDocument/codeLens"(
        self: *NativeServer,
        arena: std.mem.Allocator,
        params: lsp.types.code_lens.Params,
    ) ?[]const lsp.types.code_lens.Response {
        const lenses = self.handler.computeCodeLens(params.textDocument.uri) catch return null;
        defer {
            for (lenses) |l| self.handler.gpa.free(l.title);
            self.handler.gpa.free(lenses);
        }
        if (lenses.len == 0) return null;
        const lsp_lenses = arena.alloc(lsp.types.code_lens.Response, lenses.len) catch return null;
        for (lenses, 0..) |l, i| {
            lsp_lenses[i] = .{
                .range = .{
                    .start = .{ .line = l.range.start.line, .character = l.range.start.character },
                    .end = .{ .line = l.range.end.line, .character = l.range.end.character },
                },
                .command = .{
                    .title = arena.dupe(u8, l.title) catch "",
                    .command = "",
                },
            };
        }
        return lsp_lenses;
    }

    // ----- Call Hierarchy -----

    pub fn @"textDocument/prepareCallHierarchy"(
        self: *NativeServer,
        arena: std.mem.Allocator,
        params: lsp.types.call_hierarchy.PrepareParams,
    ) ?[]const lsp.types.call_hierarchy.Item {
        const item = self.handler.prepareCallHierarchy(
            params.textDocument.uri,
            .{ .line = params.position.line, .character = params.position.character },
        ) catch return null;
        const i = item orelse return null;
        const result = arena.alloc(lsp.types.call_hierarchy.Item, 1) catch return null;
        result[0] = .{
            .name = i.name,
            .kind = .Function,
            .uri = params.textDocument.uri,
            .range = .{
                .start = .{ .line = i.range.start.line, .character = i.range.start.character },
                .end = .{ .line = i.range.end.line, .character = i.range.end.character },
            },
            .selectionRange = .{
                .start = .{ .line = i.selection_range.start.line, .character = i.selection_range.start.character },
                .end = .{ .line = i.selection_range.end.line, .character = i.selection_range.end.character },
            },
        };
        return result;
    }

    pub fn @"callHierarchy/incomingCalls"(
        self: *NativeServer,
        arena: std.mem.Allocator,
        params: lsp.types.call_hierarchy.IncomingCallsParams,
    ) ?[]const lsp.types.call_hierarchy.IncomingCall {
        const uri = params.item.uri;
        const calls = self.handler.computeIncomingCalls(uri, params.item.name) catch return null;
        defer {
            for (calls) |c| self.handler.gpa.free(c.from_ranges);
            self.handler.gpa.free(calls);
        }
        if (calls.len == 0) return null;
        const result = arena.alloc(lsp.types.call_hierarchy.IncomingCall, calls.len) catch return null;
        for (calls, 0..) |call, ci| {
            const from_ranges = arena.alloc(lsp.types.Range, call.from_ranges.len) catch continue;
            for (call.from_ranges, 0..) |fr, fi| {
                from_ranges[fi] = .{
                    .start = .{ .line = fr.start.line, .character = fr.start.character },
                    .end = .{ .line = fr.end.line, .character = fr.end.character },
                };
            }
            result[ci] = .{
                .from = .{
                    .name = call.from.name,
                    .kind = .Function,
                    .uri = uri,
                    .range = .{
                        .start = .{ .line = call.from.range.start.line, .character = call.from.range.start.character },
                        .end = .{ .line = call.from.range.end.line, .character = call.from.range.end.character },
                    },
                    .selectionRange = .{
                        .start = .{ .line = call.from.selection_range.start.line, .character = call.from.selection_range.start.character },
                        .end = .{ .line = call.from.selection_range.end.line, .character = call.from.selection_range.end.character },
                    },
                },
                .fromRanges = from_ranges,
            };
        }
        return result;
    }

    pub fn @"callHierarchy/outgoingCalls"(
        self: *NativeServer,
        arena: std.mem.Allocator,
        params: lsp.types.call_hierarchy.OutgoingCallsParams,
    ) ?[]const lsp.types.call_hierarchy.OutgoingCall {
        const uri = params.item.uri;
        const calls = self.handler.computeOutgoingCalls(uri, params.item.name) catch return null;
        defer {
            for (calls) |c| self.handler.gpa.free(c.from_ranges);
            self.handler.gpa.free(calls);
        }
        if (calls.len == 0) return null;
        const result = arena.alloc(lsp.types.call_hierarchy.OutgoingCall, calls.len) catch return null;
        for (calls, 0..) |call, ci| {
            const from_ranges = arena.alloc(lsp.types.Range, call.from_ranges.len) catch continue;
            for (call.from_ranges, 0..) |fr, fi| {
                from_ranges[fi] = .{
                    .start = .{ .line = fr.start.line, .character = fr.start.character },
                    .end = .{ .line = fr.end.line, .character = fr.end.character },
                };
            }
            result[ci] = .{
                .to = .{
                    .name = call.to.name,
                    .kind = .Function,
                    .uri = uri,
                    .range = .{
                        .start = .{ .line = call.to.range.start.line, .character = call.to.range.start.character },
                        .end = .{ .line = call.to.range.end.line, .character = call.to.range.end.character },
                    },
                    .selectionRange = .{
                        .start = .{ .line = call.to.selection_range.start.line, .character = call.to.selection_range.start.character },
                        .end = .{ .line = call.to.selection_range.end.line, .character = call.to.selection_range.end.character },
                    },
                },
                .fromRanges = from_ranges,
            };
        }
        return result;
    }

    // ----- Selection Range -----

    pub fn @"textDocument/selectionRange"(
        self: *NativeServer,
        arena: std.mem.Allocator,
        params: lsp.types.SelectionRange.Params,
    ) ?[]const lsp.types.SelectionRange {
        if (params.positions.len == 0) return null;
        const results = arena.alloc(lsp.types.SelectionRange, params.positions.len) catch return null;
        for (params.positions, 0..) |pos, i| {
            const sel = self.handler.computeSelectionRange(
                params.textDocument.uri,
                .{ .line = pos.line, .character = pos.character },
            ) catch return null;
            if (sel) |s| {
                results[i] = convertSelectionRange(arena, s);
            } else {
                results[i] = .{ .range = .{
                    .start = .{ .line = pos.line, .character = pos.character },
                    .end = .{ .line = pos.line, .character = pos.character },
                } };
            }
        }
        return results;
    }

    fn convertSelectionRange(arena: std.mem.Allocator, sel: *const Handler.SelectionRangeInfo) lsp.types.SelectionRange {
        var parent: ?*const lsp.types.SelectionRange = null;
        if (sel.parent) |p| {
            const lsp_parent = arena.create(lsp.types.SelectionRange) catch return .{
                .range = .{ .start = .{ .line = sel.range.start.line, .character = sel.range.start.character }, .end = .{ .line = sel.range.end.line, .character = sel.range.end.character } },
            };
            lsp_parent.* = convertSelectionRange(arena, p);
            parent = lsp_parent;
        }
        return .{
            .range = .{
                .start = .{ .line = sel.range.start.line, .character = sel.range.start.character },
                .end = .{ .line = sel.range.end.line, .character = sel.range.end.character },
            },
            .parent = parent,
        };
    }

    // ----- Semantic Tokens -----

    pub fn @"textDocument/semanticTokens/full"(
        self: *NativeServer,
        arena: std.mem.Allocator,
        params: lsp.types.semantic_tokens.Params,
    ) ?lsp.types.semantic_tokens.Result {
        const data = self.handler.computeSemanticTokens(params.textDocument.uri) catch return null;
        defer self.handler.gpa.free(data);
        if (data.len == 0) return null;
        return .{ .data = arena.dupe(u32, data) catch return null };
    }

    // ----- Formatting -----

    pub fn @"textDocument/formatting"(
        self: *NativeServer,
        arena: std.mem.Allocator,
        params: lsp.types.document_formatting.Params,
    ) ?[]const lsp.types.TextEdit {
        const edit = self.handler.computeFormatting(params.textDocument.uri) catch return null;
        const e = edit orelse return null;
        defer self.handler.gpa.free(e.new_text);
        const result = arena.alloc(lsp.types.TextEdit, 1) catch return null;
        result[0] = .{
            .range = .{
                .start = .{ .line = e.range.start.line, .character = e.range.start.character },
                .end = .{ .line = e.range.end.line, .character = e.range.end.character },
            },
            .newText = arena.dupe(u8, e.new_text) catch return null,
        };
        return result;
    }

    // ----- Helpers -----

    fn publishDiagnostics(self: *NativeServer, uri: []const u8) void {
        if (!self.handler.settings.diagnostics_enabled) return;
        const diags = self.handler.validateDocumentFull(uri) catch return;
        defer Handler.freeDiagnostics(self.handler.gpa, diags);

        var bridged = bridge.toLspKitDiagnostics(self.handler.gpa, diags, uri) catch return;
        defer bridged.deinit();

        self.transport.writeNotification(
            self.io,
            self.handler.gpa,
            "textDocument/publishDiagnostics",
            lsp.types.publish_diagnostics.Params,
            .{ .uri = uri, .diagnostics = bridged.diagnostics },
            .{ .emit_null_optional_fields = false },
        ) catch {};
    }

    /// Send a `workspace/configuration` request for the `"wgslender"` section.
    /// The response is handled in `onResponse`.
    fn sendConfigurationRequest(self: *NativeServer) void {
        const id = self.next_request_id;
        self.next_request_id +%= 1;
        const items = [_]lsp.types.workspace.configuration.Item{.{ .section = "wgslender" }};
        self.transport.writeRequest(
            self.io,
            self.handler.gpa,
            .{ .number = id },
            "workspace/configuration",
            lsp.types.workspace.configuration.Params,
            .{ .items = &items },
            .{ .emit_null_optional_fields = false },
        ) catch return;
        self.pending_config_id = id;
    }

    /// Re-publish diagnostics for every open document. Called after client
    /// settings change, since toggling `diagnostics.enabled` must take effect
    /// without requiring the client to re-open each file.
    fn republishAllDocuments(self: *NativeServer) void {
        var it = self.handler.documents.iterator();
        while (it.next()) |entry| {
            if (self.handler.settings.diagnostics_enabled) {
                self.publishDiagnostics(entry.key_ptr.*);
            } else {
                self.transport.writeNotification(
                    self.io,
                    self.handler.gpa,
                    "textDocument/publishDiagnostics",
                    lsp.types.publish_diagnostics.Params,
                    .{ .uri = entry.key_ptr.*, .diagnostics = &.{} },
                    .{ .emit_null_optional_fields = false },
                ) catch {};
            }
        }
    }
};
