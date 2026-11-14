//! Composed push/pull diagnostics over the native LSP transport
//! (pngine-shaders phase 03, Task 5).
//!
//! The red-first contract:
//!   * editing a shared sibling republishes every open document that
//!     contains it, and arms each for the existing debounced full pass;
//!   * pull diagnostics on a project fragment return the composed set, and
//!     a sibling content change changes the result id and forces a Full
//!     result;
//!   * a standalone WGSL file keeps the legacy single-document diagnostic
//!     set and the legacy decimal result id;
//!   * the native server advertises `interFileDependencies=true` while the
//!     wasm capability JSON keeps advertising no project support;
//!   * a watched project change sends `workspace/diagnostic/refresh` only
//!     when the client advertised refresh support.
//!
//! Every test drives the real `NativeServer` bodies with the in-memory
//! provider from `pngine_test_provider.zig`; no test reads project text from
//! the host filesystem.

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");
const NativeServer = @import("NativeServer");
const provider_mod = @import("pngine_test_provider.zig");

const FakeProvider = provider_mod.FakeProvider;

const testing = std.testing;

const program_source =
    \\(wgsl :name shared :file "shared.wgsl")
    \\(wgsl :name alpha :file "alpha.wgsl" :imports [shared])
    \\(shader-module :name rootA :file "root_a.wgsl" :imports [alpha])
    \\(shader-module :name rootB :file "root_b.wgsl" :imports [shared])
;

const shared_source =
    \\struct Transform2D { x: f32 }
    \\const TAU: f32 = 6.28;
;
const alpha_source = "fn lit(t: Transform2D) -> f32 { return t.x * TAU; }";
const root_a_source =
    \\@fragment
    \\fn fs_main() -> @location(0) vec4<f32> {
    \\  return vec4<f32>(lit(Transform2D(1.0)) + TAU);
    \\}
;
const root_b_source =
    \\@fragment
    \\fn fs_main() -> @location(0) vec4<f32> {
    \\  return vec4<f32>(TAU);
    \\}
;

fn addProgram(fake: *FakeProvider) !void {
    try fake.addFile("/ws/program.sjon", program_source);
    try fake.addFile("/ws/shared.wgsl", shared_source);
    try fake.addFile("/ws/alpha.wgsl", alpha_source);
    try fake.addFile("/ws/root_a.wgsl", root_a_source);
    try fake.addFile("/ws/root_b.wgsl", root_b_source);
}

/// Capture every JSON message the server writes so tests can inspect
/// publishDiagnostics payloads and server-initiated requests.
const RecordingTransport = struct {
    transport: lsp.Transport,
    arena: std.heap.ArenaAllocator,
    messages: std.ArrayListUnmanaged([]const u8) = .empty,

    fn init(backing: std.mem.Allocator) RecordingTransport {
        return .{
            .transport = .{
                .vtable = &.{
                    .readJsonMessage = readJsonMessage,
                    .writeJsonMessage = writeJsonMessage,
                },
            },
            .arena = std.heap.ArenaAllocator.init(backing),
        };
    }

    fn deinit(self: *RecordingTransport) void {
        self.arena.deinit();
    }

    fn clear(self: *RecordingTransport) void {
        self.messages.clearRetainingCapacity();
    }

    fn countOf(self: *RecordingTransport, method: []const u8) usize {
        var count: usize = 0;
        for (self.messages.items) |message| {
            const root = std.json.parseFromSliceLeaky(std.json.Value, self.arena.allocator(), message, .{}) catch continue;
            if (root != .object) continue;
            const got = root.object.get("method") orelse continue;
            if (got != .string) continue;
            if (std.mem.eql(u8, got.string, method)) count += 1;
        }
        return count;
    }

    /// Latest `textDocument/publishDiagnostics` diagnostics array for
    /// `uri`, or null when no publish was emitted for it.
    fn diagnosticsFor(
        self: *RecordingTransport,
        uri: []const u8,
    ) ?std.json.Value {
        var found: ?std.json.Value = null;
        for (self.messages.items) |message| {
            const root = std.json.parseFromSliceLeaky(std.json.Value, self.arena.allocator(), message, .{}) catch continue;
            if (root != .object) continue;
            const method = root.object.get("method") orelse continue;
            if (method != .string or !std.mem.eql(u8, method.string, "textDocument/publishDiagnostics")) continue;
            const params = root.object.get("params") orelse continue;
            if (params != .object) continue;
            const got_uri = params.object.get("uri") orelse continue;
            if (got_uri != .string or !std.mem.eql(u8, got_uri.string, uri)) continue;
            found = params.object.get("diagnostics") orelse continue;
        }
        return found;
    }

    fn readJsonMessage(_: *lsp.Transport, _: std.Io, _: std.mem.Allocator) lsp.Transport.ReadError![]u8 {
        return error.EndOfStream;
    }

    fn writeJsonMessage(transport: *lsp.Transport, _: std.Io, json_message: []const u8) lsp.Transport.WriteError!void {
        const self: *RecordingTransport = @fieldParentPtr("transport", transport);
        const allocator = self.arena.allocator();
        const owned = allocator.dupe(u8, json_message) catch return error.SystemResources;
        self.messages.append(allocator, owned) catch return error.SystemResources;
    }
};

fn setupServer(fake: *FakeProvider, recorder: *RecordingTransport) !*NativeServer {
    const server = try testing.allocator.create(NativeServer);
    errdefer testing.allocator.destroy(server);
    server.* = NativeServer.init(testing.allocator, &recorder.transport, std.testing.io);
    server.pngine_provider_override = fake.sourceProvider();
    return server;
}

fn teardownServer(server: *NativeServer) void {
    server.deinit();
    testing.allocator.destroy(server);
}

fn initialize(
    server: *NativeServer,
    arena: std.mem.Allocator,
    refresh_support: bool,
) lsp.types.InitializeResult {
    const folders = [_]lsp.types.workspace.Folder{.{ .uri = "file:///ws", .name = "ws" }};
    return server.initialize(arena, .{
        .capabilities = .{
            .workspace = .{
                .didChangeWatchedFiles = .{ .dynamicRegistration = true },
                .diagnostics = if (refresh_support) .{ .refreshSupport = true } else null,
            },
        },
        .workspaceFolders = &folders,
    });
}

fn fileUri(buffer: []u8, path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "file://{s}", .{path});
}

fn didOpen(server: *NativeServer, arena: std.mem.Allocator, uri: []const u8, text: []const u8) !void {
    try server.@"textDocument/didOpen"(arena, .{
        .textDocument = .{
            .uri = uri,
            .languageId = .{ .custom_value = "wgsl" },
            .version = 1,
            .text = text,
        },
    });
}

fn didChange(server: *NativeServer, arena: std.mem.Allocator, uri: []const u8, text: []const u8) !void {
    try server.@"textDocument/didChange"(arena, .{
        .textDocument = .{ .uri = uri, .version = 2 },
        .contentChanges = &.{
            .{ .text_document_content_change_whole_document = .{ .text = text } },
        },
    });
}

fn watched(
    server: *NativeServer,
    arena: std.mem.Allocator,
    uri: []const u8,
    kind: lsp.types.workspace.FileSystemWatcher.ChangeType,
) void {
    const changes = [_]lsp.types.workspace.FileSystemWatcher.Event{.{ .uri = uri, .type = kind }};
    server.@"workspace/didChangeWatchedFiles"(arena, .{ .changes = &changes });
}

fn pull(
    server: *NativeServer,
    arena: std.mem.Allocator,
    uri: []const u8,
    previous_id: ?[]const u8,
) !lsp.types.document_diagnostic.Report {
    return server.@"textDocument/diagnostic"(arena, .{
        .textDocument = .{ .uri = uri },
        .previousResultId = previous_id,
    });
}

fn hasCode(items: []const lsp.types.Diagnostic, code: []const u8) bool {
    for (items) |item| {
        const value = item.code orelse continue;
        switch (value) {
            .string => |s| if (std.mem.eql(u8, s, code)) return true,
            .number => {},
        }
    }
    return false;
}

fn anyMessageContains(items: []const lsp.types.Diagnostic, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.indexOf(u8, item.message, needle) != null) return true;
    }
    return false;
}

fn publishedHasMessage(
    recorder: *RecordingTransport,
    uri: []const u8,
    needle: []const u8,
) bool {
    const diagnostics = recorder.diagnosticsFor(uri) orelse return false;
    if (diagnostics != .array) return false;
    for (diagnostics.array.items) |diag| {
        if (diag != .object) continue;
        const message = diag.object.get("message") orelse continue;
        if (message != .string) continue;
        if (std.mem.indexOf(u8, message.string, needle) != null) return true;
    }
    return false;
}

fn publishedHasCode(recorder: *RecordingTransport, uri: []const u8, code: []const u8) bool {
    const diagnostics = recorder.diagnosticsFor(uri) orelse return false;
    if (diagnostics != .array) return false;
    for (diagnostics.array.items) |diag| {
        if (diag != .object) continue;
        const got = diag.object.get("code") orelse continue;
        if (got != .string) continue;
        if (std.mem.eql(u8, got.string, code)) return true;
    }
    return false;
}

// =========================================================================
// 1. An edit to a shared sibling republishes every open container.
// =========================================================================

test "didChange on a shared sibling republishes every affected open document and arms each" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addProgram(&fake);

    var recorder = RecordingTransport.init(testing.allocator);
    defer recorder.deinit();
    const server = try setupServer(&fake, &recorder);
    defer teardownServer(server);
    _ = initialize(server, arena, false);

    var shared_buffer: [128]u8 = undefined;
    var alpha_buffer: [128]u8 = undefined;
    var root_a_buffer: [128]u8 = undefined;
    var root_b_buffer: [128]u8 = undefined;
    const shared_uri = try fileUri(&shared_buffer, "/ws/shared.wgsl");
    const alpha_uri = try fileUri(&alpha_buffer, "/ws/alpha.wgsl");
    const root_a_uri = try fileUri(&root_a_buffer, "/ws/root_a.wgsl");
    const root_b_uri = try fileUri(&root_b_buffer, "/ws/root_b.wgsl");

    try didOpen(server, arena, shared_uri, shared_source);
    try didOpen(server, arena, alpha_uri, alpha_source);
    try didOpen(server, arena, root_a_uri, root_a_source);
    try didOpen(server, arena, root_b_uri, root_b_source);
    recorder.clear();

    const renamed_shared =
        \\struct Transform2D { x: f32 }
        \\const TAUX: f32 = 6.28;
    ;
    try didChange(server, arena, shared_uri, renamed_shared);

    // Every open document that contains the edited sibling receives a
    // publish notification, not just the edited URI.
    try testing.expect(recorder.diagnosticsFor(shared_uri) != null);
    try testing.expect(recorder.diagnosticsFor(alpha_uri) != null);
    try testing.expect(recorder.diagnosticsFor(root_a_uri) != null);
    try testing.expect(recorder.diagnosticsFor(root_b_uri) != null);

    // The composed wording names the controlling module on each fragment.
    try testing.expect(publishedHasMessage(&recorder, alpha_uri, "declared nowhere in pngine module 'rootA'"));
    try testing.expect(publishedHasMessage(&recorder, root_a_uri, "declared nowhere in pngine module 'rootA'"));
    try testing.expect(publishedHasMessage(&recorder, root_b_uri, "declared nowhere in pngine module 'rootB'"));
    try testing.expect(publishedHasCode(&recorder, alpha_uri, "E0100"));

    // Each affected document is armed for the existing debounced full pass;
    // no second timer and no synchronous full pass from the notification.
    try testing.expect(server.debouncer.deadlines.contains(alpha_uri));
    try testing.expect(server.debouncer.deadlines.contains(root_a_uri));
    try testing.expect(server.debouncer.deadlines.contains(root_b_uri));
}

// =========================================================================
// 2. Pull on a project fragment returns the composed set.
// =========================================================================

test "pull on a project fragment returns the composed set, not standalone semantics" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addProgram(&fake);

    var recorder = RecordingTransport.init(testing.allocator);
    defer recorder.deinit();
    const server = try setupServer(&fake, &recorder);
    defer teardownServer(server);
    _ = initialize(server, arena, true);

    var alpha_buffer: [128]u8 = undefined;
    const alpha_uri = try fileUri(&alpha_buffer, "/ws/alpha.wgsl");
    try didOpen(server, arena, alpha_uri, alpha_source);

    const report = try pull(server, arena, alpha_uri, null);
    const items = switch (report) {
        .related_full_document_diagnostic_report => |full| full.items,
        .related_unchanged_document_diagnostic_report => return error.TestUnexpectedResult,
    };
    // `Transform2D` and `shade` are declared in the sibling `shared.wgsl`;
    // standalone analysis would have reported E0200/E0100 here.
    try testing.expect(!hasCode(items, "E0200"));
    try testing.expect(!hasCode(items, "E0100"));
    try testing.expect(!hasCode(items, "P0001"));
}

// =========================================================================
// 3. A sibling content change changes the pull result id and returns Full.
// =========================================================================

test "pull result id changes when a sibling's content changes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addProgram(&fake);

    var recorder = RecordingTransport.init(testing.allocator);
    defer recorder.deinit();
    const server = try setupServer(&fake, &recorder);
    defer teardownServer(server);
    _ = initialize(server, arena, true);

    var alpha_buffer: [128]u8 = undefined;
    const alpha_uri = try fileUri(&alpha_buffer, "/ws/alpha.wgsl");
    try didOpen(server, arena, alpha_uri, alpha_source);

    const first = try pull(server, arena, alpha_uri, null);
    const first_id = switch (first) {
        .related_full_document_diagnostic_report => |full| full.resultId orelse return error.TestExpectedResultId,
        .related_unchanged_document_diagnostic_report => return error.TestUnexpectedResult,
    };
    // The composed id carries parse/config/project components.
    try testing.expect(std.mem.indexOf(u8, first_id, ":p") != null);
    try testing.expect(std.mem.indexOf(u8, first_id, ":g") != null);

    // The sibling is closed; a watched disk change must still invalidate the
    // id and the next pull must return a fresh Full.
    try fake.addFile("/ws/shared.wgsl",
        \\struct Transform2D { x: f32 }
        \\const TAUX: f32 = 6.28;
    );
    watched(server, arena, "file:///ws/shared.wgsl", .Changed);

    const second = try pull(server, arena, alpha_uri, first_id);
    switch (second) {
        .related_full_document_diagnostic_report => |full| {
            const second_id = full.resultId orelse return error.TestExpectedResultId;
            try testing.expect(!std.mem.eql(u8, first_id, second_id));
            try testing.expect(hasCode(full.items, "E0100"));
            try testing.expect(anyMessageContains(full.items, "declared nowhere in pngine module 'rootA'"));

            // A repeat pull with nothing changed is Unchanged.
            const third = try pull(server, arena, alpha_uri, second_id);
            switch (third) {
                .related_unchanged_document_diagnostic_report => |unchanged| {
                    try testing.expectEqualStrings(second_id, unchanged.resultId);
                },
                .related_full_document_diagnostic_report => return error.TestUnexpectedFull,
            }
        },
        .related_unchanged_document_diagnostic_report => return error.TestUnexpectedUnchanged,
    }
}

// =========================================================================
// 4. Standalone files keep the legacy single-document result.
// =========================================================================

test "standalone WGSL keeps the single-document diagnostic set and decimal result id" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addProgram(&fake);

    var recorder = RecordingTransport.init(testing.allocator);
    defer recorder.deinit();
    const server = try setupServer(&fake, &recorder);
    defer teardownServer(server);
    _ = initialize(server, arena, false);

    const solo_source = "const x: i32 = 1.5;";
    var solo_buffer: [128]u8 = undefined;
    const solo_uri = try fileUri(&solo_buffer, "/ws/solo.wgsl");
    try didOpen(server, arena, solo_uri, solo_source);

    // The push path is byte-for-byte the legacy standalone path: compare the
    // published item set against a handler with no project store bound, so
    // the comparison exercises today's single-document full pipeline.
    var baseline_handler = Handler.init(testing.allocator);
    defer baseline_handler.deinit();
    try baseline_handler.openDocument(solo_uri, solo_source, 1);
    const standalone = try baseline_handler.validateDocumentFull(solo_uri);
    defer Handler.freeDiagnostics(testing.allocator, standalone);

    const published = recorder.diagnosticsFor(solo_uri) orelse return error.TestExpectedPublish;
    try testing.expect(published == .array);
    try testing.expectEqual(standalone.len, published.array.items.len);
    for (standalone, published.array.items) |expected, actual| {
        try testing.expect(actual == .object);
        try testing.expectEqualStrings(expected.message, actual.object.get("message").?.string);
        try testing.expectEqualStrings(expected.code, actual.object.get("code").?.string);
        try testing.expectEqual(
            @as(i64, @intCast(expected.range.start.line)),
            actual.object.get("range").?.object.get("start").?.object.get("line").?.integer,
        );
    }
    try testing.expect(!publishedHasCode(&recorder, solo_uri, "P0001"));

    const report = try pull(server, arena, solo_uri, null);
    switch (report) {
        .related_full_document_diagnostic_report => |full| {
            const id = full.resultId orelse return error.TestExpectedResultId;
            // Legacy single-document ids stay decimal; the project-shaped
            // `d…:c…:p…:g…` form is reserved for project members.
            _ = try std.fmt.parseInt(u32, id, 10);
            try testing.expectEqual(standalone.len, full.items.len);
            try testing.expect(hasCode(full.items, "E0200"));
            try testing.expect(!hasCode(full.items, "P0001"));
        },
        .related_unchanged_document_diagnostic_report => return error.TestUnexpectedResult,
    }
}

// =========================================================================
// 5. Capability advertisement.
// =========================================================================

test "native advertises inter-file diagnostic dependencies while wasm advertises nothing new" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addProgram(&fake);

    var recorder = RecordingTransport.init(testing.allocator);
    defer recorder.deinit();
    const server = try setupServer(&fake, &recorder);
    defer teardownServer(server);

    const result = initialize(server, arena, false);
    const provider = result.capabilities.diagnosticProvider orelse return error.TestExpectedDiagnosticProvider;
    switch (provider) {
        .diagnostic_options => |options| {
            try testing.expect(options.interFileDependencies);
            try testing.expect(!options.workspaceDiagnostics);
        },
        else => return error.TestUnexpectedDiagnosticProvider,
    }

    // The wasm LSP reuses Handler.capabilities_json; it must keep
    // advertising no project capability.
    const wasm = try std.json.parseFromSliceLeaky(std.json.Value, arena, Handler.capabilities_json, .{});
    const wasm_provider = wasm.object.get("diagnosticProvider").?.object;
    try testing.expectEqual(false, wasm_provider.get("interFileDependencies").?.bool);
    try testing.expectEqual(false, wasm_provider.get("workspaceDiagnostics").?.bool);
}

// =========================================================================
// 6. Watched changes request a diagnostic refresh only when supported.
// =========================================================================

test "watched project change requests diagnostic refresh only when the client advertised it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addProgram(&fake);

    var alpha_buffer: [128]u8 = undefined;
    const alpha_uri = try fileUri(&alpha_buffer, "/ws/alpha.wgsl");

    {
        var recorder = RecordingTransport.init(testing.allocator);
        defer recorder.deinit();
        const server = try setupServer(&fake, &recorder);
        defer teardownServer(server);
        _ = initialize(server, arena, true);
        try didOpen(server, arena, alpha_uri, alpha_source);
        recorder.clear();

        try fake.addFile("/ws/shared.wgsl",
            \\struct Transform2D { x: f32 }
            \\const TAUX: f32 = 6.28;
        );
        watched(server, arena, "file:///ws/shared.wgsl", .Changed);
        try testing.expectEqual(@as(usize, 1), recorder.countOf("workspace/diagnostic/refresh"));
        // The notification itself publishes nothing; the debounce pass does.
        try testing.expectEqual(@as(usize, 0), recorder.countOf("textDocument/publishDiagnostics"));
    }

    {
        var recorder = RecordingTransport.init(testing.allocator);
        defer recorder.deinit();
        const server = try setupServer(&fake, &recorder);
        defer teardownServer(server);
        _ = initialize(server, arena, false);
        try didOpen(server, arena, alpha_uri, alpha_source);
        recorder.clear();

        try fake.addFile("/ws/shared.wgsl",
            \\struct Transform2D { x: f32 }
            \\const TAUY: f32 = 6.28;
        );
        watched(server, arena, "file:///ws/shared.wgsl", .Changed);
        try testing.expectEqual(@as(usize, 0), recorder.countOf("workspace/diagnostic/refresh"));
        try testing.expectEqual(@as(usize, 0), recorder.countOf("textDocument/publishDiagnostics"));

        // Correctness of a later pull does not depend on refresh support.
        const report = try pull(server, arena, alpha_uri, null);
        switch (report) {
            .related_full_document_diagnostic_report => |full| {
                try testing.expect(hasCode(full.items, "E0100"));
            },
            .related_unchanged_document_diagnostic_report => return error.TestUnexpectedResult,
        }
    }
}
