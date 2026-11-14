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
const build_options = @import("build_options");
const wgslender = @import("wgslender");
const Handler = @import("Handler");
const bridge = @import("bridge");
const native_code_actions = @import("native_code_actions");
const native_document_sync = @import("native_document_sync");
const native_lifecycle = @import("native_lifecycle");
const native_navigation = @import("native_navigation");
const native_symbols = @import("native_symbols");
const native_editing = @import("native_editing");
const native_call_hierarchy = @import("native_call_hierarchy");
const native_workspace_commands = @import("native_workspace_commands");
const Debouncer = @import("Debouncer.zig");
const uri_module = @import("uri.zig");

const pngine_support = build_options.pngine_support;
const PngineStore = if (pngine_support) wgslender.Pngine.Store else void;
const PngineTypes = if (pngine_support) wgslender.Pngine.Types else void;
const native_source_provider = if (pngine_support) @import("native/source_provider.zig") else struct {};

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

/// True iff the client advertised
/// `workspace.didChangeWatchedFiles.dynamicRegistration`. Gates the single
/// `client/registerCapability` request `initialized` sends; nothing is
/// registered when the client does not advertise it.
client_watcher_dynamic_registration: bool = false,

/// True iff the client advertised `workspace.diagnostics.refreshSupport`.
/// Gates the `workspace/diagnostic/refresh` request sent after a watched
/// project change. Pull correctness never depends on it: the result id
/// changes independently, so an unsupporting client still gets a fresh
/// Full on its next pull.
client_supports_diagnostic_refresh: bool = false,

/// Pngine project store (pngine-shaders phase 01). Allocated by
/// `initialize`, owned by this server, destroyed at shutdown/deinit. The
/// native graph is the only graph that reaches these fields.
pngine_store: if (pngine_support) ?*PngineStore else void = if (pngine_support) null else {},
/// Provider injection seam. `null` selects the native filesystem provider;
/// tests (and a future host that supplies text itself) bind an in-memory
/// provider here before `initialize`.
pngine_provider_override: if (pngine_support) ?PngineTypes.SourceProvider else void = if (pngine_support) null else {},
/// The one native filesystem binding of `Types.SourceProvider`. No other
/// LSP module opens a project path for reading.
fs_provider: if (pngine_support) native_source_provider.FileProvider else void = if (pngine_support) native_source_provider.FileProvider{} else {},

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
    var server: NativeServer = .{
        .handler = .init(allocator),
        .transport = transport,
        .io = io,
        .debouncer = Debouncer.init(allocator),
    };
    if (comptime pngine_support) server.fs_provider = .{ .io = io };
    return server;
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
    self.teardownPngineStoreLocked();
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
    arena: std.mem.Allocator,
    params: lsp.types.InitializeParams,
) lsp.types.InitializeResult {
    self.lock();
    defer self.unlock();
    self.client_watcher_dynamic_registration = false;
    self.client_supports_diagnostic_refresh = false;
    if (params.capabilities.workspace) |ws| {
        if (ws.configuration orelse false) self.client_supports_configuration = true;
        if (ws.didChangeWatchedFiles) |watched| {
            self.client_watcher_dynamic_registration = watched.dynamicRegistration orelse false;
        }
        if (ws.diagnostics) |diagnostics| {
            self.client_supports_diagnostic_refresh = diagnostics.refreshSupport orelse false;
        }
    }
    // Workspace-root precedence chain — see `pickWorkspaceRoot` doc.
    // The path string lives on the per-call arena and dies with the function.
    // This first folder stays the config-discovery root only; the project
    // store below receives every workspace folder.
    const start_dir: ?[]const u8 = pickWorkspaceRoot(arena, params);
    self.handler.discoverProjectConfig(self.io, start_dir);
    if (params.initializationOptions) |opts| {
        self.handler.applyClientConfig(opts);
    }
    self.bindPngineStore(arena, params);
    return .{
        .serverInfo = native_lifecycle.server_info,
        .capabilities = native_lifecycle.server_capabilities,
    };
}

/// Handles `workspace/executeCommand`. Dispatches by command name to the
/// matching `Handler.run*` entry point. Void-mode commands (the modes
/// toggle / set / recompute-insights families) republish diagnostics on
/// success; the data-returning commands (showMinifiedOutput, reflect)
/// don't — they are pure reads.
pub fn @"workspace/executeCommand"(
    self: *NativeServer,
    arena: std.mem.Allocator,
    params: lsp.types.workspace.execute_command.Params,
) !?std.json.Value {
    self.lock();
    defer self.unlock();
    const result = try native_workspace_commands.handle(&self.handler, arena, params);
    if (result == null) self.republishAllDocumentsLocked();
    return result;
}

/// Params and result of the native-only `wgslender/pnginePart` request.
/// The custom method cannot ride lsp-kit's typed request union, so
/// `lsp/main.zig` intercepts it before `basic_server` and calls this body.
pub const PnginePartParams = struct {
    uri: []const u8,
};

pub const PnginePartResult = struct {
    text: []u8,
    languageId: []const u8,
};

/// Serve the current author text of one inline `:code` part. Missing and
/// stale parts are distinct errors; neither path invents content.
pub fn pnginePart(
    self: *NativeServer,
    allocator: std.mem.Allocator,
    params: PnginePartParams,
) !PnginePartResult {
    if (comptime pngine_support) {
        self.lock();
        defer self.unlock();
        const document = try Handler.pnginePart(&self.handler, allocator, params.uri);
        return .{ .text = document.text, .languageId = document.language_id };
    } else {
        std.mem.doNotOptimizeAway(params);
        return error.PngineUnsupported;
    }
}

fn pickWorkspaceRoot(
    arena: std.mem.Allocator,
    params: lsp.types.InitializeParams,
) ?[]const u8 {
    if (params.workspaceFolders) |folders| {
        if (folders.len > 0) {
            if (uri_module.fileUriToPath(arena, folders[0].uri) catch null) |p| {
                return p;
            }
        }
    }
    if (params.rootUri) |uri| {
        if (uri_module.fileUriToPath(arena, uri) catch null) |p| {
            return p;
        }
    }
    if (params.rootPath) |p| return p;
    return null;
}

/// Every workspace folder is a project root, not just the first. The
/// `pickWorkspaceRoot` result remains the single config-discovery root.
fn collectWorkspaceRoots(
    arena: std.mem.Allocator,
    params: lsp.types.InitializeParams,
) ![]const []const u8 {
    var roots: std.ArrayList([]const u8) = .empty;
    if (params.workspaceFolders) |folders| {
        for (folders) |folder| {
            if (uri_module.fileUriToPath(arena, folder.uri) catch null) |path| {
                try roots.append(arena, path);
            }
        }
        if (roots.items.len > 0) return roots.toOwnedSlice(arena);
    }
    if (params.rootUri) |uri| {
        if (uri_module.fileUriToPath(arena, uri) catch null) |path| {
            try roots.append(arena, path);
            return roots.toOwnedSlice(arena);
        }
    }
    if (params.rootPath) |path| try roots.append(arena, path);
    return roots.toOwnedSlice(arena);
}

/// Build the project store from the injected provider (native: the
/// filesystem), point it at every workspace root, and hand it to the handler.
/// Discovery failures leave the store bound with whatever roots were
/// accepted; a failed initialize must never take the language server down.
fn bindPngineStore(
    self: *NativeServer,
    arena: std.mem.Allocator,
    params: lsp.types.InitializeParams,
) void {
    if (comptime pngine_support) {
        self.teardownPngineStoreLocked();

        const provider = self.pngine_provider_override orelse self.fs_provider.sourceProvider();
        const store = self.handler.gpa.create(PngineStore) catch return;
        store.* = PngineStore.init(self.handler.gpa, provider);
        self.pngine_store = store;
        // The resolved `lsp.pngine.enabled` rides the handler; discovery is
        // still populated so a later workspace-config opt-in has roots.
        self.handler.setPngineStore(store);

        const roots = collectWorkspaceRoots(arena, params) catch return;
        store.setWorkspaceRoots(roots) catch |err| {
            std.log.warn("pngine workspace discovery failed: {s}", .{@errorName(err)});
        };
    } else {
        // The native graph always resolves pngine support in a steady
        // state; this branch only exists for the first lazy-dependency
        // pass / `-Dlsp=false` compile check.
    }
}

/// Release the project store. Called from `shutdown` and from `deinit`
/// (idempotent; the second call is a no-op).
fn teardownPngineStoreLocked(self: *NativeServer) void {
    if (comptime pngine_support) {
        if (self.pngine_store) |store| {
            self.handler.setPngineStore(null);
            store.deinit();
            self.handler.gpa.destroy(store);
            self.pngine_store = null;
        }
    }
}

/// Ask the client to watch every `.sjon` and `.wgsl` file when it advertised
/// dynamic registration. The payload follows SJON's LSP precedent
/// (`zig-pkg/sjon-1.7.0-*/src/lsp/main.zig:1948`); the response is ignored by
/// `onResponse`, which only tracks `workspace/configuration` ids.
pub fn initialized(self: *NativeServer, arena: std.mem.Allocator, _: lsp.types.InitializedParams) void {
    self.lock();
    defer self.unlock();
    if (!self.client_watcher_dynamic_registration) return;
    if (comptime !pngine_support) return;

    const id = self.next_request_id;
    self.next_request_id +%= 1;
    const json = std.fmt.allocPrint(arena,
        \\{{"jsonrpc":"2.0","id":{d},"method":"client/registerCapability","params":{{"registrations":[{{"id":"wgslender-pngine-watch","method":"workspace/didChangeWatchedFiles","registerOptions":{{"watchers":[{{"globPattern":"**/*.sjon"}},{{"globPattern":"**/*.wgsl"}}]}}}}]}}}}
    , .{id}) catch return;
    self.transport.writeJsonMessage(self.io, json) catch {};
}

/// Route `workspace/didChangeWatchedFiles` into the provider-backed store
/// under the handler mutex, then arm every open document for the existing
/// debounced diagnostics refresh. Nothing is published synchronously.
pub fn @"workspace/didChangeWatchedFiles"(
    self: *NativeServer,
    arena: std.mem.Allocator,
    params: lsp.types.workspace.did_change_watched_files.Params,
) void {
    self.lock();
    defer self.unlock();
    if (comptime pngine_support) {
        const store = self.pngine_store orelse return;
        var arm_all = false;
        var affected: std.ArrayList([]const u8) = .empty;
        defer affected.deinit(self.handler.gpa);

        for (params.changes) |event| {
            const decoded = uri_module.fileUriToPath(arena, event.uri) catch continue;
            const path = decoded orelse continue;
            store.invalidatePath(path);

            // A project document/change can reshape discovery for every open
            // document; a WGSL change only affects open members of roots
            // that contain it.
            if (isProjectDocumentPath(path)) {
                arm_all = true;
                continue;
            }
            const docs = self.handler.affectedOpenDocuments(path) catch continue;
            defer self.handler.gpa.free(docs);
            for (docs) |doc_uri| {
                if (!containsUri(affected.items, doc_uri)) {
                    affected.append(self.handler.gpa, doc_uri) catch {};
                }
            }
        }

        // Reuse the Phase 7 debouncer + timer thread. No second timer, no
        // synchronous publish from this notification.
        if (arm_all) {
            const deadline = self.nowMs() + self.debounce_ms;
            var it = self.handler.documents.iterator();
            while (it.next()) |entry| self.debouncer.arm(entry.key_ptr.*, deadline) catch {};
        } else {
            for (affected.items) |doc_uri| self.armLocked(doc_uri);
        }

        // Tell pull-model clients to re-pull, but only when they advertised
        // refresh support. The result id changes independently, so later
        // pulls stay correct either way.
        if (arm_all or affected.items.len > 0) self.sendWatchedDiagnosticRefreshLocked();
    }
}

fn isProjectDocumentPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".sjon");
}

fn containsUri(uris: []const []const u8, uri: []const u8) bool {
    for (uris) |item| {
        if (std.mem.eql(u8, item, uri)) return true;
    }
    return false;
}

/// Handles LSP shutdown; releases the project store before the client exits.
pub fn shutdown(self: *NativeServer, _: std.mem.Allocator, _: void) ?void {
    self.lock();
    defer self.unlock();
    self.teardownPngineStoreLocked();
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
    self.sendPullRefreshRequestsLocked();
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
    try native_document_sync.handleDidOpen(&self.handler, notification);
    // Open is rare and the user expects M-rule diagnostics on first
    // paint. Run the full path immediately, then arm so the next
    // edit's debounce window is in place.
    const uri = notification.textDocument.uri;
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
    try native_document_sync.handleDidChange(&self.handler, notification);
    // Hot path: cheap publish on every keystroke. A project edit can change
    // the diagnostics of every open document sharing one of its roots, so
    // publish/arm the whole affected set. The debounce timer republishes
    // each with the full pass once the burst settles.
    const uri = notification.textDocument.uri;
    self.publishCheapForEditLocked(uri);
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
    native_document_sync.handleDidClose(&self.handler, notification);
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
    native_document_sync.handleDidSave(&self.handler, notification);
    // Save is a punctuation event — user expects up-to-date M-rule
    // diagnostics, so go straight to the full path.
    self.publishFullDiagnosticsLocked(notification.textDocument.uri);
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
    return native_code_actions.handle(&self.handler, arena, params);
}

// =========================================================================
// Navigation (hover, definition, references, documentHighlight)
// =========================================================================

pub fn @"textDocument/hover"(
    self: *NativeServer,
    _: std.mem.Allocator,
    params: lsp.types.Hover.Params,
) ?lsp.types.Hover {
    self.lock();
    defer self.unlock();
    return native_navigation.handleHover(&self.handler, params);
}

pub fn @"textDocument/definition"(
    self: *NativeServer,
    arena: std.mem.Allocator,
    params: lsp.types.Definition.Params,
) ?lsp.types.Definition.Result {
    self.lock();
    defer self.unlock();
    return native_navigation.handleDefinition(&self.handler, arena, params);
}

pub fn @"textDocument/declaration"(
    self: *NativeServer,
    arena: std.mem.Allocator,
    params: lsp.types.declaration.Params,
) ?lsp.types.Definition.Result {
    self.lock();
    defer self.unlock();
    return native_navigation.handleDeclaration(&self.handler, arena, params);
}

pub fn @"textDocument/references"(
    self: *NativeServer,
    arena: std.mem.Allocator,
    params: lsp.types.reference.Params,
) ?[]const lsp.types.Location {
    self.lock();
    defer self.unlock();
    return native_navigation.handleReferences(&self.handler, arena, params);
}

pub fn @"textDocument/documentHighlight"(
    self: *NativeServer,
    arena: std.mem.Allocator,
    params: lsp.types.DocumentHighlight.Params,
) ?[]const lsp.types.DocumentHighlight {
    self.lock();
    defer self.unlock();
    return native_navigation.handleDocumentHighlight(&self.handler, arena, params);
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
    return native_symbols.handleRename(&self.handler, arena, params);
}

pub fn @"textDocument/prepareRename"(
    self: *NativeServer,
    _: std.mem.Allocator,
    params: lsp.types.prepare_rename.Params,
) ?lsp.types.prepare_rename.Result {
    self.lock();
    defer self.unlock();
    return native_symbols.handlePrepareRename(&self.handler, params);
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
    return native_editing.handleCompletion(&self.handler, arena, params);
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
    return native_editing.handleSignatureHelp(&self.handler, arena, params);
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
    return native_symbols.handleDocumentSymbol(&self.handler, arena, params);
}

pub fn @"workspace/symbol"(
    self: *NativeServer,
    arena: std.mem.Allocator,
    params: lsp.types.workspace.Symbol.Params,
) ?lsp.types.workspace.Symbol.Result {
    self.lock();
    defer self.unlock();
    return native_symbols.handleWorkspaceSymbol(&self.handler, arena, params);
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
    return native_editing.handleFoldingRange(&self.handler, arena, params);
}

// =========================================================================
// Go-to-Type-Definition
// =========================================================================

pub fn @"textDocument/typeDefinition"(
    self: *NativeServer,
    arena: std.mem.Allocator,
    params: lsp.types.type_definition.Params,
) ?lsp.types.Definition.Result {
    self.lock();
    defer self.unlock();
    return native_navigation.handleTypeDefinition(&self.handler, arena, params);
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
    return native_editing.handleInlayHint(&self.handler, arena, params);
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
    return native_editing.handleCodeLens(&self.handler, arena, params);
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
    return native_call_hierarchy.handlePrepare(&self.handler, arena, params);
}

pub fn @"callHierarchy/incomingCalls"(
    self: *NativeServer,
    arena: std.mem.Allocator,
    params: lsp.types.call_hierarchy.IncomingCallsParams,
) ?[]const lsp.types.call_hierarchy.IncomingCall {
    self.lock();
    defer self.unlock();
    return native_call_hierarchy.handleIncomingCalls(&self.handler, arena, params);
}

pub fn @"callHierarchy/outgoingCalls"(
    self: *NativeServer,
    arena: std.mem.Allocator,
    params: lsp.types.call_hierarchy.OutgoingCallsParams,
) ?[]const lsp.types.call_hierarchy.OutgoingCall {
    self.lock();
    defer self.unlock();
    return native_call_hierarchy.handleOutgoingCalls(&self.handler, arena, params);
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
    return native_editing.handleSelectionRange(&self.handler, arena, params);
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
    return native_editing.handleSemanticTokensFull(&self.handler, arena, params);
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
    return native_editing.handleFormatting(&self.handler, arena, params);
}

// =========================================================================
// Helpers (assume `handler_mutex` is held by the caller)
// =========================================================================

/// Cheap publish for one edit. Project members fan out to every open
/// document sharing a containing root; each affected member is also armed
/// for the existing debounced full pass (no second timer, no synchronous
/// full pass here). Standalone documents keep the old single-URI path and
/// the old activity-gated arming exactly.
fn publishCheapForEditLocked(self: *NativeServer, uri: []const u8) void {
    if (comptime pngine_support) {
        const affected = self.handler.affectedOpenDocuments(uri) catch {
            self.publishCheapDiagnosticsLocked(uri);
            self.armIfActiveLocked(uri);
            return;
        };
        defer self.handler.gpa.free(affected);

        var published_self = false;
        for (affected) |affected_uri| {
            if (std.mem.eql(u8, affected_uri, uri)) published_self = true;
            self.publishCheapDiagnosticsLocked(affected_uri);
            // A project member's full pass carries the composed set and the
            // future whole-unit lint; arm it regardless of minify mode.
            self.armLocked(affected_uri);
        }
        if (!published_self) {
            self.publishCheapDiagnosticsLocked(uri);
            self.armIfActiveLocked(uri);
        }
    } else {
        self.publishCheapDiagnosticsLocked(uri);
        self.armIfActiveLocked(uri);
    }
}

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
    var bridged = bridge.toLspKitDiagnosticsBorrowed(self.handler.gpa, diags, uri) catch return;
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

/// `workspace/diagnostic/refresh` after a watched project change, gated on
/// the client's `workspace.diagnostics.refreshSupport`. Configuration
/// changes keep their existing unconditional three-method refresh.
fn sendWatchedDiagnosticRefreshLocked(self: *NativeServer) void {
    if (!self.client_supports_diagnostic_refresh) return;
    const id = self.next_request_id;
    self.next_request_id +%= 1;
    self.transport.writeRequest(
        self.io,
        self.handler.gpa,
        .{ .number = id },
        "workspace/diagnostic/refresh",
        ?u8,
        null,
        .{ .emit_null_optional_fields = false },
    ) catch {};
}

/// Ask the client to re-pull everything whose result depends on settings.
/// Mirrors `lsp/wasm/lifecycle.zig::sendPullRefreshRequests`: republishing
/// covers the push model only, and a pull-model client (VS Code) keeps its
/// stale `textDocument/diagnostic` results until the next edit otherwise.
/// Responses to these requests land in `onResponse` and are ignored there
/// as unmatched ids — including error responses from clients without
/// refresh support.
fn sendPullRefreshRequestsLocked(self: *NativeServer) void {
    const methods = [_][]const u8{
        "workspace/diagnostic/refresh",
        "workspace/inlayHint/refresh",
        "workspace/codeLens/refresh",
    };
    for (methods) |method| {
        const id = self.next_request_id;
        self.next_request_id +%= 1;
        self.transport.writeRequest(
            self.io,
            self.handler.gpa,
            .{ .number = id },
            method,
            ?u8,
            null,
            .{ .emit_null_optional_fields = false },
        ) catch return;
    }
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
    self.armLocked(uri);
}

/// Arm `uri` unconditionally for the existing debounce deadline.
fn armLocked(self: *NativeServer, uri: []const u8) void {
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
