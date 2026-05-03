//! WGSL Language Server — native (stdio) callback dispatcher.
//!
//! This is the thin lsp-kit-shaped wrapper that forwards every request /
//! notification into the transport-agnostic `Handler` and does the
//! Handler-type → lsp-kit-type conversion in both directions.
//!
//! Phase 7 added two cross-cutting concerns on top of the original
//! per-method dispatch:
//!
//!   1. A `handler_mutex` (`std.Io.Mutex`, the only blocking mutex
//!      shipped by Zig 0.16). Every public method body starts with
//!      `self.lock(); defer self.unlock();` because Phase 7 introduces
//!      a second thread (the idle-debounce
//!      timer) that calls into `self.handler` and writes through
//!      `self.transport`. The basic_server callback thread and the timer
//!      thread are otherwise free to race; the mutex serialises both so
//!      Handler stays effectively single-threaded.
//!
//!   2. A debouncer + a dedicated timer thread. `didOpen` / `didChange` /
//!      `didSave` cheap-publish immediately and `arm` the document for a
//!      ~300 ms refresh. After the burst settles, the timer thread drains
//!      the debouncer, warms the per-document `MinifyEstimator` cache,
//!      and republishes with the full minify-lint diagnostics included.
//!      Settings changes re-arm every open doc so any pending refresh is
//!      pushed into a fresh debounce window — see master plan §10.1
//!      acceptance "settings change resets debounce timer".
//!
//! The transport is wrapped in `lsp.ThreadSafeTransport` by the caller
//! (see `lsp/main.zig`) so concurrent `writeNotification` from the timer
//! thread doesn't garble output; the mutex above guards Handler state
//! only, not the wire.

const std = @import("std");
const lsp = @import("lsp");
const wgslender = @import("wgslender");
const Handler = @import("Handler");
const bridge = @import("bridge");
const Debouncer = @import("Debouncer.zig");

const NativeServer = @This();

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

/// Serialises every access to `self.handler` and every transport write
/// across {basic_server callback thread, timer thread}. Held for the
/// entire body of every public dispatch method. Phase 7 uses
/// `std.Io.Mutex` (the only blocking mutex shipped in Zig 0.16) so
/// every lock/unlock takes the server's `io` — that's why the helper
/// `lock()` / `unlock()` methods exist below.
handler_mutex: std.Io.Mutex = .init,

/// Idle-debounce bookkeeping. Armed by every push-on-edit path; drained
/// by the timer thread once the deadline elapses.
debouncer: Debouncer,

/// Set by `deinit` to make the timer thread drop out of its loop.
should_stop: std.atomic.Value(bool) = .init(false),

/// `null` until `start()` runs — tests construct a server without
/// spawning the thread and drive `tick` synchronously instead.
timer_thread: ?std.Thread = null,

/// How long after the last edit the debouncer fires. Tweakable from
/// tests so they don't need real wall-clock waits.
debounce_ms: i64 = 300,

/// Upper bound on the timer-thread sleep when no deadline is pending.
/// Keeps `should_stop` reactive without busy-spinning. Picked small
/// enough that an editor close + server shutdown returns inside a few
/// frames at 60 Hz.
idle_tick_ns: u64 = 50 * std.time.ns_per_ms,

pub fn init(allocator: std.mem.Allocator, transport: *lsp.Transport, io: std.Io) NativeServer {
    return .{
        .handler = .init(allocator),
        .transport = transport,
        .io = io,
        .debouncer = Debouncer.init(allocator),
    };
}

/// Spawn the idle-debounce timer thread. Skipped by tests, which drive
/// `tick(now_ms)` directly.
pub fn start(self: *NativeServer) !void {
    std.debug.assert(self.timer_thread == null);
    self.timer_thread = try std.Thread.spawn(.{}, timerLoop, .{self});
}

pub fn deinit(self: *NativeServer) void {
    self.should_stop.store(true, .release);
    if (self.timer_thread) |t| t.join();
    self.timer_thread = null;
    // Both threads have stopped by here; the mutex is uncontended.
    self.debouncer.deinit();
    self.handler.deinit();
}

/// Take the dispatch lock. Wraps `std.Io.Mutex.lockUncancelable` so
/// every method body can write `self.lock(); defer self.unlock();`
/// without repeating the io argument and the cancellation choice.
fn lock(self: *NativeServer) void {
    self.handler_mutex.lockUncancelable(self.io);
}

fn unlock(self: *NativeServer) void {
    self.handler_mutex.unlock(self.io);
}

/// Wall-clock-equivalent monotonic time in milliseconds. The
/// debouncer keys on whatever scalar this returns, so as long as
/// `arm` and `popDue` see the same source they agree on ordering.
/// `Clock.awake` skips suspend time, which matches "elapsed editor
/// idle" better than `real` (system clock can jump backwards).
fn nowMs(self: *const NativeServer) i64 {
    return std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
}

// =========================================================================
// Timer loop
// =========================================================================

/// Background loop owned by `timer_thread`. Sleeps until either a
/// pending deadline or the idle-tick cap, then drains the debouncer
/// under the mutex. The sleep upper bound is `idle_tick_ns` so a
/// `should_stop` flip is observed inside ~50 ms even when the
/// debouncer is empty.
fn timerLoop(self: *NativeServer) void {
    while (!self.should_stop.load(.acquire)) {
        const sleep_ns: u64 = blk: {
            self.lock();
            defer self.unlock();
            const now = self.nowMs();
            if (self.debouncer.nextDeadline()) |d| {
                const delta_ms = d - now;
                if (delta_ms <= 0) break :blk std.time.ns_per_ms;
                const delta_ns = @as(u64, @intCast(delta_ms)) * std.time.ns_per_ms;
                break :blk @min(self.idle_tick_ns, delta_ns);
            }
            break :blk self.idle_tick_ns;
        };
        self.io.sleep(.fromNanoseconds(@intCast(sleep_ns)), .awake) catch return;
        self.tick(self.nowMs());
    }
}

/// Drain every URI whose deadline is `<= now_ms`. For each one warms
/// the cache via `refreshMinifyInsights` and re-publishes diagnostics
/// using the full path so the M-rules become visible. Called from the
/// timer thread on every loop iteration; tests call it directly.
pub fn tick(self: *NativeServer, now_ms: i64) void {
    self.lock();
    defer self.unlock();
    while (self.debouncer.popDue(now_ms)) |uri_owned| {
        defer self.handler.gpa.free(uri_owned);
        self.handler.refreshMinifyInsights(uri_owned);
        self.publishFullDiagnosticsLocked(uri_owned);
    }
}

/// Test-only entry point that exercises the same re-arm path
/// `onResponse` runs after a `workspace/configuration` response.
/// Lets tests assert "settings change resets debounce timer" without
/// stubbing the JSON-RPC response wire format.
pub fn rearmAllOpenDocsForTest(self: *NativeServer) void {
    self.lock();
    defer self.unlock();
    self.rearmAllOpenDocsLocked();
}

// =========================================================================
// LSP lifecycle
// =========================================================================

/// Handles the LSP initialize request; returns server capabilities.
pub fn initialize(
    self: *NativeServer,
    _: std.mem.Allocator,
    params: lsp.types.InitializeParams,
) lsp.types.InitializeResult {
    self.lock();
    defer self.unlock();
    if (params.capabilities.workspace) |ws| {
        if (ws.configuration orelse false) self.client_supports_configuration = true;
    }
    // Walk parents from cwd for `wgslender.json` and seed the project
    // minify layer. cwd is the editor-spawned working directory, which is
    // the workspace root for VS Code / nvim / Helix in the common case;
    // honoring `params.rootUri` / `workspaceFolders` is a clean follow-up
    // (needs a `file://` percent-decoder).
    self.handler.discoverProjectConfig(self.io, null);
    if (params.initializationOptions) |opts| {
        self.handler.applyClientConfig(opts);
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
        },
    };
}

/// Handles `workspace/executeCommand`. Dispatches to `Handler.executeCommand`
/// for the void-returning mode commands, or `runShowMinifiedOutput` for
/// the data-returning minified-text command. Mode commands re-publish
/// diagnostics on success; the show-minified command does not (it's a
/// pure read).
pub fn @"workspace/executeCommand"(
    self: *NativeServer,
    arena: std.mem.Allocator,
    params: lsp.types.workspace.execute_command.Params,
) !?std.json.Value {
    self.lock();
    defer self.unlock();
    if (std.mem.eql(u8, params.command, "wgslender.showMinifiedOutput")) {
        const items = params.arguments orelse return error.InvalidParams;
        if (items.len < 1) return error.InvalidParams;
        const uri = switch (items[0]) {
            .string => |s| s,
            else => return error.InvalidParams,
        };
        const result = self.handler.runShowMinifiedOutput(arena, uri) catch |err| switch (err) {
            error.UnknownCommand => return error.MethodNotFound,
            error.InvalidParams => return error.InvalidParams,
            error.DocumentNotFound => return error.InvalidParams,
            error.MinifyFailed, error.ReflectFailed => return error.InternalError,
            error.OutOfMemory => return error.OutOfMemory,
        };
        var obj: std.json.ObjectMap = .empty;
        try obj.put(arena, "uri", .{ .string = result.uri });
        try obj.put(arena, "minified_text", .{ .string = result.minified_text });
        try obj.put(arena, "byte_count", .{ .integer = @as(i64, result.byte_count) });
        try obj.put(arena, "gz_count", .{ .integer = @as(i64, result.gz_count) });
        return .{ .object = obj };
    }
    if (std.mem.eql(u8, params.command, "wgslender.reflect")) {
        const items = params.arguments orelse return error.InvalidParams;
        if (items.len < 1) return error.InvalidParams;
        const uri = switch (items[0]) {
            .string => |s| s,
            else => return error.InvalidParams,
        };
        var version: wgslender.Reflect.JsonVersion = .v2;
        if (items.len >= 2) {
            const fmt_str = switch (items[1]) {
                .string => |s| s,
                .null => "v2",
                else => return error.InvalidParams,
            };
            if (std.mem.eql(u8, fmt_str, "v1")) {
                version = .v1;
            } else if (std.mem.eql(u8, fmt_str, "v2")) {
                version = .v2;
            } else return error.InvalidParams;
        }
        var pretty = false;
        if (items.len >= 3) switch (items[2]) {
            .bool => |b| pretty = b,
            .null => {},
            else => return error.InvalidParams,
        };
        const result = self.handler.runReflect(arena, uri, version, pretty) catch |err| switch (err) {
            error.UnknownCommand => return error.MethodNotFound,
            error.InvalidParams => return error.InvalidParams,
            error.DocumentNotFound => return error.InvalidParams,
            error.MinifyFailed, error.ReflectFailed => return error.InternalError,
            error.OutOfMemory => return error.OutOfMemory,
        };
        var obj: std.json.ObjectMap = .empty;
        try obj.put(arena, "uri", .{ .string = result.uri });
        try obj.put(arena, "version", .{ .integer = switch (result.version) {
            .v1 => 1,
            .v2 => 2,
        } });
        // Parse the reflect-emitted JSON back into LSPAny so the JSON-RPC
        // response carries it as a structured object rather than a string.
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, result.json, .{
            .max_value_len = null,
        });
        try obj.put(arena, "json", parsed);
        return .{ .object = obj };
    }
    self.handler.executeCommand(params.command, params.arguments) catch |err| switch (err) {
        error.UnknownCommand => return error.MethodNotFound,
        error.InvalidParams => return error.InvalidParams,
        error.DocumentNotFound => return error.InvalidParams,
        error.MinifyFailed, error.ReflectFailed => return error.InternalError,
        error.OutOfMemory => return error.OutOfMemory,
    };
    // Re-publish diagnostics so any minify-mode change takes effect
    // immediately across all open documents.
    self.republishAllDocumentsLocked();
    return null;
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
    self.lock();
    defer self.unlock();
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
    const arr = switch (result) {
        .array => |a| a,
        else => return,
    };
    if (arr.items.len == 0) return;
    self.handler.applyClientConfig(arr.items[0]);
    // Settings change — re-publish (full) and re-arm every open doc so
    // any in-flight debounce window is reset to `now + debounce_ms`
    // (master plan §10.1 "settings change resets debounce timer").
    self.republishAllDocumentsLocked();
    self.rearmAllOpenDocsLocked();
}

// =========================================================================
// Document sync
// =========================================================================

/// Registers an opened document and publishes initial diagnostics.
pub fn @"textDocument/didOpen"(
    self: *NativeServer,
    _: std.mem.Allocator,
    notification: lsp.types.TextDocument.DidOpenParams,
) !void {
    self.lock();
    defer self.unlock();
    const uri = notification.textDocument.uri;
    try self.handler.openDocument(uri, notification.textDocument.text, notification.textDocument.version);
    // Open is rare and the user expects M-rule diagnostics on first
    // paint. Run the full path immediately, then arm so the next
    // edit's debounce window is in place.
    self.publishFullDiagnosticsLocked(uri);
    self.armIfActiveLocked(uri);
}

/// Updates document source on change and re-publishes diagnostics.
pub fn @"textDocument/didChange"(
    self: *NativeServer,
    _: std.mem.Allocator,
    notification: lsp.types.TextDocument.DidChangeParams,
) !void {
    self.lock();
    defer self.unlock();
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
    // Hot path: cheap publish on every keystroke. The debounce timer
    // will republish with M-rule diagnostics once the burst settles.
    self.publishCheapDiagnosticsLocked(uri);
    self.armIfActiveLocked(uri);
}

/// Removes a closed document and clears its published diagnostics.
pub fn @"textDocument/didClose"(
    self: *NativeServer,
    _: std.mem.Allocator,
    notification: lsp.types.TextDocument.DidCloseParams,
) !void {
    self.lock();
    defer self.unlock();
    const uri = notification.textDocument.uri;
    self.debouncer.clear(uri);
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
    self.lock();
    defer self.unlock();
    const uri = notification.textDocument.uri;
    self.handler.handleDidSave(uri);
    // Save is a punctuation event — user expects up-to-date M-rule
    // diagnostics, so go straight to the full path.
    self.publishFullDiagnosticsLocked(uri);
}

/// Pull-model diagnostics (LSP 3.17 `textDocument/diagnostic`).
/// Complements the push model (`publishDiagnostics` on didOpen/didChange/
/// didSave). Clients that advertise diagnostic pull support will send this
/// request on open + on any event the client deems relevant (focus, save);
/// we respond with a Full report built from the same
/// `validateDocumentFull` path the push notification uses. Unknown URIs
/// and `diagnostics.enabled=false` both return an empty Full report —
/// pull clients wait for a response, so silence would hang the UI.
///
/// When `params.previousResultId` matches the current revision key we
/// return an Unchanged report (spec-blessed short-circuit that lets the
/// client reuse its cached items[]).
pub fn @"textDocument/diagnostic"(
    self: *NativeServer,
    arena: std.mem.Allocator,
    params: lsp.types.document_diagnostic.Params,
) !lsp.types.document_diagnostic.Report {
    self.lock();
    defer self.unlock();
    return bridge.buildPullReport(&self.handler, arena, params.textDocument.uri, params.previousResultId);
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
    self.lock();
    defer self.unlock();
    if (!self.client_supports_configuration) return;
    self.sendConfigurationRequestLocked();
}

// =========================================================================
// Code Actions
// =========================================================================

/// Returns quick-fix code actions for the requested diagnostic range.
pub fn @"textDocument/codeAction"(
    self: *NativeServer,
    arena: std.mem.Allocator,
    params: lsp.types.CodeAction.Params,
) ?[]const lsp.types.CodeAction.Result {
    self.lock();
    defer self.unlock();
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

// =========================================================================
// Hover
// =========================================================================

pub fn @"textDocument/hover"(
    self: *NativeServer,
    _: std.mem.Allocator,
    params: lsp.types.Hover.Params,
) ?lsp.types.Hover {
    self.lock();
    defer self.unlock();
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

// =========================================================================
// Go-to-Definition
// =========================================================================

pub fn @"textDocument/definition"(
    self: *NativeServer,
    _: std.mem.Allocator,
    params: lsp.types.Definition.Params,
) ?lsp.types.Definition.Result {
    self.lock();
    defer self.unlock();
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

// =========================================================================
// Find References
// =========================================================================

pub fn @"textDocument/references"(
    self: *NativeServer,
    arena: std.mem.Allocator,
    params: lsp.types.reference.Params,
) ?[]const lsp.types.Location {
    self.lock();
    defer self.unlock();
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

// =========================================================================
// Document Highlight
// =========================================================================

pub fn @"textDocument/documentHighlight"(
    self: *NativeServer,
    arena: std.mem.Allocator,
    params: lsp.types.DocumentHighlight.Params,
) ?[]const lsp.types.DocumentHighlight {
    self.lock();
    defer self.unlock();
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

// =========================================================================
// Rename
// =========================================================================

pub fn @"textDocument/rename"(
    self: *NativeServer,
    arena: std.mem.Allocator,
    params: lsp.types.rename.Params,
) ?lsp.types.WorkspaceEdit {
    self.lock();
    defer self.unlock();
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
    self.lock();
    defer self.unlock();
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

// =========================================================================
// Completion
// =========================================================================

pub fn @"textDocument/completion"(
    self: *NativeServer,
    arena: std.mem.Allocator,
    params: lsp.types.completion.Params,
) ?lsp.types.completion.Result {
    self.lock();
    defer self.unlock();
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

// =========================================================================
// Signature Help
// =========================================================================

pub fn @"textDocument/signatureHelp"(
    self: *NativeServer,
    arena: std.mem.Allocator,
    params: lsp.types.SignatureHelp.Params,
) ?lsp.types.SignatureHelp {
    self.lock();
    defer self.unlock();
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

// =========================================================================
// Document Symbols
// =========================================================================

pub fn @"textDocument/documentSymbol"(
    self: *NativeServer,
    arena: std.mem.Allocator,
    params: lsp.types.DocumentSymbol.Params,
) ?lsp.types.DocumentSymbol.Result {
    self.lock();
    defer self.unlock();
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

// =========================================================================
// Folding Ranges
// =========================================================================

pub fn @"textDocument/foldingRange"(
    self: *NativeServer,
    arena: std.mem.Allocator,
    params: lsp.types.FoldingRange.Params,
) ?[]const lsp.types.FoldingRange {
    self.lock();
    defer self.unlock();
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

// =========================================================================
// Go-to-Type-Definition
// =========================================================================

pub fn @"textDocument/typeDefinition"(
    self: *NativeServer,
    _: std.mem.Allocator,
    params: lsp.types.type_definition.Params,
) ?lsp.types.Definition.Result {
    self.lock();
    defer self.unlock();
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

// =========================================================================
// Inlay Hints
// =========================================================================

pub fn @"textDocument/inlayHint"(
    self: *NativeServer,
    arena: std.mem.Allocator,
    params: lsp.types.InlayHint.Params,
) ?[]const lsp.types.InlayHint {
    self.lock();
    defer self.unlock();
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
                .type_hint, .const_value_hint, .minify_size => .Type,
                .parameter_hint => .Parameter,
            },
            .tooltip = if (h.tooltip) |t| .{ .string = t } else null,
        };
    }
    return lsp_hints;
}

// =========================================================================
// Code Lens
// =========================================================================

pub fn @"textDocument/codeLens"(
    self: *NativeServer,
    arena: std.mem.Allocator,
    params: lsp.types.code_lens.Params,
) ?[]const lsp.types.code_lens.Response {
    self.lock();
    defer self.unlock();
    const lenses = self.handler.computeCodeLens(params.textDocument.uri) catch return null;
    defer Handler.freeCodeLens(self.handler.gpa, lenses);
    if (lenses.len == 0) return null;
    const lsp_lenses = arena.alloc(lsp.types.code_lens.Response, lenses.len) catch return null;
    for (lenses, 0..) |l, i| {
        const cmd_name: []const u8 = if (l.command) |c| arena.dupe(u8, c) catch "" else "";
        // Re-encode the JSON args slice into the arena so the LSP
        // serializer can read it after the Handler-owned buffer is
        // freed by the defer above.
        const args: ?[]std.json.Value = if (l.arguments) |src| blk: {
            const dst = arena.alloc(std.json.Value, src.len) catch break :blk null;
            for (src, 0..) |arg, j| dst[j] = switch (arg) {
                .string => |s| .{ .string = arena.dupe(u8, s) catch "" },
                else => arg,
            };
            break :blk dst;
        } else null;
        lsp_lenses[i] = .{
            .range = .{
                .start = .{ .line = l.range.start.line, .character = l.range.start.character },
                .end = .{ .line = l.range.end.line, .character = l.range.end.character },
            },
            .command = .{
                .title = arena.dupe(u8, l.title) catch "",
                .command = cmd_name,
                .arguments = args,
            },
        };
    }
    return lsp_lenses;
}

// =========================================================================
// Call Hierarchy
// =========================================================================

pub fn @"textDocument/prepareCallHierarchy"(
    self: *NativeServer,
    arena: std.mem.Allocator,
    params: lsp.types.call_hierarchy.PrepareParams,
) ?[]const lsp.types.call_hierarchy.Item {
    self.lock();
    defer self.unlock();
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
    self.lock();
    defer self.unlock();
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
    self.lock();
    defer self.unlock();
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

// =========================================================================
// Selection Range
// =========================================================================

pub fn @"textDocument/selectionRange"(
    self: *NativeServer,
    arena: std.mem.Allocator,
    params: lsp.types.SelectionRange.Params,
) ?[]const lsp.types.SelectionRange {
    self.lock();
    defer self.unlock();
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

// =========================================================================
// Semantic Tokens
// =========================================================================

pub fn @"textDocument/semanticTokens/full"(
    self: *NativeServer,
    arena: std.mem.Allocator,
    params: lsp.types.semantic_tokens.Params,
) ?lsp.types.semantic_tokens.Result {
    self.lock();
    defer self.unlock();
    const data = self.handler.computeSemanticTokens(params.textDocument.uri) catch return null;
    defer self.handler.gpa.free(data);
    if (data.len == 0) return null;
    return .{ .data = arena.dupe(u32, data) catch return null };
}

// =========================================================================
// Formatting
// =========================================================================

pub fn @"textDocument/formatting"(
    self: *NativeServer,
    arena: std.mem.Allocator,
    params: lsp.types.document_formatting.Params,
) ?[]const lsp.types.TextEdit {
    self.lock();
    defer self.unlock();
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

// =========================================================================
// Helpers (assume `handler_mutex` is held by the caller)
// =========================================================================

/// Cheap path: validator + unused/dead-code warnings, no M-rules.
/// Used by every push-on-edit path so a 100-keystroke burst never
/// enters the estimator-heavy minify lint pipeline.
fn publishCheapDiagnosticsLocked(self: *NativeServer, uri: []const u8) void {
    if (!self.handler.diagnosticsEnabled()) return;
    const diags = self.handler.validateDocumentCheap(uri) catch return;
    defer Handler.freeDiagnostics(self.handler.gpa, diags);
    self.writePublishLocked(uri, diags);
}

/// Full path: cheap diagnostics + minify lint rules (M-rules). Fired
/// from the timer drain after the debounce window settles, and from
/// `didOpen` / `didSave` / `republishAllDocumentsLocked` where the user
/// expects up-to-date M-rule output immediately.
fn publishFullDiagnosticsLocked(self: *NativeServer, uri: []const u8) void {
    if (!self.handler.diagnosticsEnabled()) return;
    const diags = self.handler.validateDocumentFull(uri) catch return;
    defer Handler.freeDiagnostics(self.handler.gpa, diags);
    self.writePublishLocked(uri, diags);
}

fn writePublishLocked(self: *NativeServer, uri: []const u8, diags: []const Handler.LspDiagnostic) void {
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
fn sendConfigurationRequestLocked(self: *NativeServer) void {
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
/// without requiring the client to re-open each file. Uses the full
/// path because mode-toggle commands want M-rules visible immediately.
fn republishAllDocumentsLocked(self: *NativeServer) void {
    var it = self.handler.documents.iterator();
    while (it.next()) |entry| {
        if (self.handler.diagnosticsEnabled()) {
            self.publishFullDiagnosticsLocked(entry.key_ptr.*);
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

/// Arm the debouncer for `uri` iff the document's effective minify
/// state would actually do work on a refresh. Skips the arm when
/// `mode = off` etc., so closed documents and inactive workspaces
/// don't keep the timer thread waking up for no reason.
fn armIfActiveLocked(self: *NativeServer, uri: []const u8) void {
    const eff = self.handler.effectiveMinifyFor(uri);
    if (!eff.insightsActive() and !eff.lintsActive()) return;
    const deadline = self.nowMs() + self.debounce_ms;
    self.debouncer.arm(uri, deadline) catch {};
}

/// Re-arm every open document with `now + debounce_ms`. Called after a
/// settings refresh so any pending debounce window from prior typing is
/// pushed forward into a fresh window — the "settings change resets
/// debounce timer" acceptance from master plan §10.1.
fn rearmAllOpenDocsLocked(self: *NativeServer) void {
    const deadline = self.nowMs() + self.debounce_ms;
    var it = self.handler.documents.iterator();
    while (it.next()) |entry| {
        const uri = entry.key_ptr.*;
        const eff = self.handler.effectiveMinifyFor(uri);
        if (!eff.insightsActive() and !eff.lintsActive()) {
            self.debouncer.clear(uri);
            continue;
        }
        self.debouncer.arm(uri, deadline) catch {};
    }
}
