//! Native lifecycle constants shared with the NativeServer `initialize`
//! body. The state-mutating bodies (mutex, pending_config_id, debouncer
//! arming) stay in NativeServer.

const lsp = @import("lsp");

pub const server_info: lsp.types.ServerInfo = .{
    .name = "wgslender-lsp",
    .version = "1.0.0",
};

pub const server_capabilities: lsp.types.ServerCapabilities = .{
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
    .diagnosticProvider = .{
        .diagnostic_options = .{
            .interFileDependencies = false,
            .workspaceDiagnostics = false,
        },
    },
    .executeCommandProvider = .{
        .commands = &.{
            "wgslender.setMinifyMode",
            "wgslender.toggleMinifyMode",
            "wgslender.showMinifiedOutput",
            "wgslender.recomputeMinifyInsights",
            "wgslender.reflect",
        },
    },
};
