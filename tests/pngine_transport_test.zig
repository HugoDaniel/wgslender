//! Native LSP transport for pngine project sources (pngine-shaders phase 01,
//! Task 6): watcher registration, `workspace/didChangeWatchedFiles` routing,
//! provider source supply, and the D45 no-watcher boundaries.
//!
//! Every test drives the real native server bodies (`initialize`,
//! `initialized`, the watched-files notification, `didOpen`, `didSave`) with
//! the in-memory `SourceProvider` from `pngine_test_provider.zig`; no test
//! reads project text from the host filesystem. The only seam added for the
//! suite is `NativeServer.pngine_provider_override`, which `initialize` uses
//! in place of the filesystem provider exactly as a future host would inject
//! its own provider.

const std = @import("std");
const lsp = @import("lsp");
const wgslender = @import("wgslender");
const NativeServer = @import("NativeServer");
const provider_mod = @import("pngine_test_provider.zig");

const pngine = wgslender.Pngine;
const Types = pngine.Types;
const Store = pngine.Store;
const FakeProvider = provider_mod.FakeProvider;

const testing = std.testing;

const program_source =
    \\(wgsl :name alpha :file "a.wgsl")
    \\(wgsl :name gamma :file "c.wgsl")
    \\(shader-module :name rootA :file "root_a.wgsl" :imports [alpha])
    \\(shader-module :name rootB :file "root_b.wgsl" :imports [gamma])
;

const disk_alpha = "fn alpha_disk() {}";
const disk_gamma = "fn gamma_disk() {}";
const disk_root_a = "fn root_a() {}";
const disk_root_b = "fn root_b() {}";

/// Captures every JSON message the server writes so tests can inspect the
/// `client/registerCapability` payload and prove diagnostics are deferred
/// until the debounce timer drains.
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
            var parsed = std.json.parseFromSlice(std.json.Value, self.arena.allocator(), message, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const got = parsed.value.object.get("method") orelse continue;
            if (got != .string) continue;
            if (std.mem.eql(u8, got.string, method)) count += 1;
        }
        return count;
    }

    fn last(self: *const RecordingTransport) ?[]const u8 {
        if (self.messages.items.len == 0) return null;
        return self.messages.items[self.messages.items.len - 1];
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

fn fileUri(buffer: []u8, path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "file://{s}", .{path});
}

fn addProgram(fake: *FakeProvider) !void {
    try fake.addFile("/ws/program.sjon", program_source);
    try fake.addFile("/ws/a.wgsl", disk_alpha);
    try fake.addFile("/ws/c.wgsl", disk_gamma);
    try fake.addFile("/ws/root_a.wgsl", disk_root_a);
    try fake.addFile("/ws/root_b.wgsl", disk_root_b);
}

fn bindWorkspace(
    server: *NativeServer,
    arena: std.mem.Allocator,
    folders: []const lsp.types.workspace.Folder,
) void {
    _ = server.initialize(arena, .{
        .capabilities = .{},
        .workspaceFolders = folders,
    });
}

fn pngineStore(server: *NativeServer) *Store {
    return server.pngine_store orelse unreachable;
}

const MembershipInfo = struct {
    program: Types.ProgramId,
    part: Types.PartId,
    root: Types.PartId,
    source_status: Types.SourceStatus,
};

fn firstMembership(store: *Store, path: []const u8) !MembershipInfo {
    var buffer: [512]u8 = undefined;
    var set = try store.membershipsFor(try fileUri(&buffer, path));
    defer set.deinit(testing.allocator);
    if (set.items.len == 0) return error.TestExpectedMembership;
    const membership = set.items[0];
    if (membership.containing_roots.len == 0) return error.TestExpectedRoot;
    return .{
        .program = membership.program,
        .part = membership.part,
        .root = .{ .program = membership.program, .index = membership.containing_roots[0] },
        .source_status = membership.source_status,
    };
}

fn expectNoMembership(store: *Store, path: []const u8) !void {
    var buffer: [512]u8 = undefined;
    var set = try store.membershipsFor(try fileUri(&buffer, path));
    defer set.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), set.items.len);
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

fn didSave(server: *NativeServer, arena: std.mem.Allocator, uri: []const u8) void {
    server.@"textDocument/didSave"(arena, .{ .textDocument = .{ .uri = uri } });
}

fn watched(server: *NativeServer, arena: std.mem.Allocator, uri: []const u8, kind: lsp.types.workspace.FileSystemWatcher.ChangeType) void {
    const changes = [_]lsp.types.workspace.FileSystemWatcher.Event{.{ .uri = uri, .type = kind }};
    server.@"workspace/didChangeWatchedFiles"(arena, .{ .changes = &changes });
}

test "initialize binds a provider-backed store over every workspace folder" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addProgram(&fake);
    try fake.addFile("/ws2/program.sjon",
        \\(wgsl :name omega :file "o.wgsl")
        \\(shader-module :name rootO :file "root_o.wgsl" :imports [omega])
    );
    try fake.addFile("/ws2/o.wgsl", "fn omega() {}");
    try fake.addFile("/ws2/root_o.wgsl", "fn root_o() {}");

    var recorder = RecordingTransport.init(testing.allocator);
    defer recorder.deinit();
    const server = try setupServer(&fake, &recorder);
    defer teardownServer(server);

    const folders = [_]lsp.types.workspace.Folder{
        .{ .uri = "file:///ws", .name = "ws" },
        .{ .uri = "file:///ws2", .name = "ws2" },
    };
    bindWorkspace(server, arena, &folders);

    const store = pngineStore(server);
    var set = try store.membershipsFor("file:///ws2/o.wgsl");
    defer set.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), set.items.len);
    try testing.expectEqual(Types.SourceStatus.readable, set.items[0].source_status);

    // Shutdown is the host teardown boundary; the store must not survive it.
    _ = server.shutdown(arena, {});
    try testing.expect(server.pngine_store == null);
}

test "initialized registers .sjon and .wgsl watchers only when the client advertises dynamic registration" {
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

    const folders = [_]lsp.types.workspace.Folder{.{ .uri = "file:///ws", .name = "ws" }};
    _ = server.initialize(arena, .{
        .capabilities = .{
            .workspace = .{
                .didChangeWatchedFiles = .{ .dynamicRegistration = true },
            },
        },
        .workspaceFolders = &folders,
    });
    recorder.clear();
    server.initialized(arena, .{});

    const message = recorder.last() orelse return error.TestExpectedRegistration;
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, message, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try testing.expectEqualStrings("2.0", object.get("jsonrpc").?.string);
    try testing.expectEqualStrings("client/registerCapability", object.get("method").?.string);

    const registrations = object.get("params").?.object.get("registrations").?.array;
    try testing.expectEqual(@as(usize, 1), registrations.items.len);
    const registration = registrations.items[0].object;
    try testing.expectEqualStrings("workspace/didChangeWatchedFiles", registration.get("method").?.string);

    const watchers = registration.get("registerOptions").?.object.get("watchers").?.array;
    try testing.expectEqual(@as(usize, 2), watchers.items.len);
    var saw_sjon = false;
    var saw_wgsl = false;
    for (watchers.items) |watcher| {
        const pattern = watcher.object.get("globPattern").?.string;
        if (std.mem.eql(u8, pattern, "**/*.sjon")) saw_sjon = true;
        if (std.mem.eql(u8, pattern, "**/*.wgsl")) saw_wgsl = true;
    }
    try testing.expect(saw_sjon and saw_wgsl);

    // A client that does not advertise dynamic registration gets nothing.
    _ = server.initialize(arena, .{
        .capabilities = .{},
        .workspaceFolders = &folders,
    });
    recorder.clear();
    server.initialized(arena, .{});
    try testing.expectEqual(@as(usize, 0), recorder.messages.items.len);
}

test "watched SJON change refreshes membership and defers open-document diagnostics" {
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

    const folders = [_]lsp.types.workspace.Folder{.{ .uri = "file:///ws", .name = "ws" }};
    bindWorkspace(server, arena, &folders);

    var uri_buffer: [128]u8 = undefined;
    try didOpen(server, arena, try fileUri(&uri_buffer, "/ws/a.wgsl"), "fn alpha_open() {}");
    recorder.clear();

    try fake.addFile("/ws/b.wgsl", "fn beta() {}");
    try fake.addFile("/ws/program.sjon",
        \\(wgsl :name alpha :file "a.wgsl")
        \\(wgsl :name beta :file "b.wgsl")
        \\(shader-module :name rootA :file "root_a.wgsl" :imports [alpha])
    );
    watched(server, arena, "file:///ws/program.sjon", .Changed);

    const store = pngineStore(server);
    var set = try store.membershipsFor("file:///ws/b.wgsl");
    defer set.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), set.items.len);

    // The notification itself must not publish diagnostics; the existing
    // debounce path does that later.
    try testing.expectEqual(@as(usize, 0), recorder.countOf("textDocument/publishDiagnostics"));
    const deadline = server.debouncer.nextDeadline() orelse return error.TestExpectedDebounce;
    server.tick(deadline);
    try testing.expectEqual(@as(usize, 1), recorder.countOf("textDocument/publishDiagnostics"));
}

test "watched WGSL change keeps an open buffer authoritative and does not bump its root" {
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

    const folders = [_]lsp.types.workspace.Folder{.{ .uri = "file:///ws", .name = "ws" }};
    bindWorkspace(server, arena, &folders);

    var uri_buffer: [128]u8 = undefined;
    const uri = try fileUri(&uri_buffer, "/ws/a.wgsl");
    try didOpen(server, arena, uri, "fn alpha_open() {}");

    const store = pngineStore(server);
    const membership = try firstMembership(store, "/ws/a.wgsl");
    const upper_root = membership.root;
    const revision_before = store.rootRevision(upper_root);

    try fake.addFile("/ws/a.wgsl", "fn alpha_disk_changed() {}");
    recorder.clear();
    watched(server, arena, uri, .Changed);

    const disk_hash = store.sourceHash("/ws/a.wgsl") orelse return error.TestExpectedSourceHash;
    try testing.expectEqual(Types.contentHash("fn alpha_disk_changed() {}"), disk_hash);
    try testing.expectEqual(revision_before, store.rootRevision(upper_root));

    var text = try store.textForPart(membership.part);
    defer text.deinit(testing.allocator);
    try testing.expectEqualStrings("fn alpha_open() {}", text.text);
    try testing.expectEqual(Types.SourceOrigin.open_buffer, text.origin);
    try testing.expectEqual(@as(usize, 0), recorder.countOf("textDocument/publishDiagnostics"));
}

test "watched create and delete of project documents add and remove memberships" {
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

    const folders = [_]lsp.types.workspace.Folder{.{ .uri = "file:///ws", .name = "ws" }};
    bindWorkspace(server, arena, &folders);
    const store = pngineStore(server);

    try fake.addFile("/ws/new.sjon",
        \\(wgsl :name delta :file "d.wgsl")
        \\(shader-module :name rootD :file "root_d.wgsl" :imports [delta])
    );
    try fake.addFile("/ws/d.wgsl", "fn delta() {}");
    try fake.addFile("/ws/root_d.wgsl", "fn root_d() {}");
    watched(server, arena, "file:///ws/new.sjon", .Created);

    const created = try firstMembership(store, "/ws/d.wgsl");
    try testing.expectEqual(Types.SourceStatus.readable, created.source_status);

    fake.removeFile("/ws/new.sjon");
    watched(server, arena, "file:///ws/new.sjon", .Deleted);

    try testing.expect(store.program(created.program) == null);
    try expectNoMembership(store, "/ws/d.wgsl");
}

test "provider read failure and deletion keep the membership with an unreadable source" {
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

    const folders = [_]lsp.types.workspace.Folder{.{ .uri = "file:///ws", .name = "ws" }};
    bindWorkspace(server, arena, &folders);

    const store = pngineStore(server);
    const membership = try firstMembership(store, "/ws/a.wgsl");

    // A provider failure is the store's missing-source state, never empty
    // WGSL and never a dropped membership.
    try fake.failReads("/ws/a.wgsl");
    watched(server, arena, "file:///ws/a.wgsl", .Changed);
    try testing.expectError(error.SourceUnavailable, store.textForPart(membership.part));
    var failed = try store.membershipsFor("file:///ws/a.wgsl");
    defer failed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), failed.items.len);
    try testing.expectEqual(Types.SourceStatus.unreadable, failed.items[0].source_status);

    // Deleting the referenced WGSL keeps the reference (D25).
    fake.removeFile("/ws/a.wgsl");
    fake.allowReads("/ws/a.wgsl");
    watched(server, arena, "file:///ws/a.wgsl", .Deleted);
    try testing.expectError(error.SourceUnavailable, store.textForPart(membership.part));
    var deleted = try store.membershipsFor("file:///ws/a.wgsl");
    defer deleted.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), deleted.items.len);
    try testing.expectEqual(Types.SourceStatus.unreadable, deleted.items[0].source_status);

    // Deleting the program document removes its memberships.
    fake.removeFile("/ws/program.sjon");
    watched(server, arena, "file:///ws/program.sjon", .Deleted);
    try testing.expect(store.program(membership.program) == null);
    try expectNoMembership(store, "/ws/a.wgsl");
}

test "D45 didOpen and didSave content-check siblings without any watcher notification" {
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

    const folders = [_]lsp.types.workspace.Folder{.{ .uri = "file:///ws", .name = "ws" }};
    bindWorkspace(server, arena, &folders);
    const store = pngineStore(server);

    // didOpen is a content-checked boundary: a sibling that changed on disk
    // before the open is re-read even though no notification arrives.
    try fake.addFile("/ws/c.wgsl", "fn gamma_first_change() {}");
    var uri_buffer: [128]u8 = undefined;
    const uri = try fileUri(&uri_buffer, "/ws/a.wgsl");
    try didOpen(server, arena, uri, "fn alpha_open() {}");
    try testing.expectEqual(Types.contentHash("fn gamma_first_change() {}"), store.sourceHash("/ws/c.wgsl").?);

    const gamma_membership = try firstMembership(store, "/ws/c.wgsl");
    const gamma_root = gamma_membership.root;
    const revision_before = store.rootRevision(gamma_root);

    // The next sibling edit is picked up at didSave, the second boundary a
    // no-watcher client still provides.
    try fake.addFile("/ws/c.wgsl", "fn gamma_second_change() {}");
    didSave(server, arena, uri);

    try testing.expectEqual(Types.contentHash("fn gamma_second_change() {}"), store.sourceHash("/ws/c.wgsl").?);
    try testing.expect(store.rootRevision(gamma_root) > revision_before);
    var current = try store.membershipsFor("file:///ws/c.wgsl");
    defer current.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), current.items.len);
    try testing.expectEqual(Types.SourceStatus.readable, current.items[0].source_status);
}

test "D45 first membershipsFor walks ancestors and explicit project selection rescans" {
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

    const folders = [_]lsp.types.workspace.Folder{.{ .uri = "file:///ws", .name = "ws" }};
    bindWorkspace(server, arena, &folders);
    const store = pngineStore(server);

    // Outside every workspace root: the bounded ancestor walk finds the
    // program on the first query for an unknown file.
    try fake.addFile("/outside/program.sjon",
        \\(wgsl :name outside :file "x.wgsl")
        \\(shader-module :name rootX :file "root_x.wgsl" :imports [outside])
    );
    try fake.addFile("/outside/x.wgsl", "fn outside() {}");
    try fake.addFile("/outside/root_x.wgsl", "fn root_x() {}");
    var external = try store.membershipsFor("file:///outside/x.wgsl");
    defer external.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), external.items.len);

    // Explicit project selection replaces the root set and rescans.
    try fake.addFile("/other/program.sjon",
        \\(wgsl :name other :file "y.wgsl")
        \\(shader-module :name rootY :file "root_y.wgsl" :imports [other])
    );
    try fake.addFile("/other/y.wgsl", "fn other() {}");
    try fake.addFile("/other/root_y.wgsl", "fn root_y() {}");
    const roots = [_][]const u8{ "/ws", "/other" };
    try store.setWorkspaceRoots(&roots);

    var selected = try store.membershipsFor("file:///other/y.wgsl");
    defer selected.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), selected.items.len);
}
