//! pngine store overlays, content hashes, invalidation and opt-out
//! (pngine-shaders phase 01, Task 5).
//!
//! Inventory rows D37–D41 plus provider read failure, deletion, program
//! staleness, and the Handler lifecycle hooks. The provider is the same
//! in-memory one used by the discovery suite; no test touches the host
//! filesystem.

const std = @import("std");
const wgslender = @import("wgslender");
const Handler = @import("Handler");
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

fn makeStore(fake: *FakeProvider) !Store {
    var store = Store.init(testing.allocator, fake.sourceProvider());
    errdefer store.deinit();
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);
    return store;
}

const MembershipInfo = struct {
    program: Types.ProgramId,
    part: Types.PartId,
    root: Types.PartId,
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
        .root = .{
            .program = membership.program,
            .index = membership.containing_roots[0],
        },
    };
}

test "D37 an open buffer wins over disk text and carries its own hash" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addProgram(&fake);
    var store = try makeStore(&fake);
    defer store.deinit();

    const membership = try firstMembership(&store, "/ws/a.wgsl");
    var disk = try store.textForPart(membership.part);
    defer disk.deinit(testing.allocator);
    try testing.expectEqual(Types.SourceOrigin.disk, disk.origin);
    try testing.expectEqualStrings(disk_alpha, disk.text);
    try testing.expectEqual(Types.contentHash(disk_alpha), disk.content_hash);

    var buffer: [128]u8 = undefined;
    const uri = try fileUri(&buffer, "/ws/a.wgsl");
    try store.upsertBuffer(uri, "fn alpha_open() {}", .open_buffer);

    var open = try store.textForPart(membership.part);
    defer open.deinit(testing.allocator);
    try testing.expectEqual(Types.SourceOrigin.open_buffer, open.origin);
    try testing.expectEqualStrings("fn alpha_open() {}", open.text);
    try testing.expectEqual(Types.contentHash("fn alpha_open() {}"), open.content_hash);
    try testing.expect(!std.mem.eql(u8, &disk.content_hash, &open.content_hash));
}

test "D38 an open sibling overlay does not replace another part's disk text" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addProgram(&fake);
    var store = try makeStore(&fake);
    defer store.deinit();

    const alpha = try firstMembership(&store, "/ws/a.wgsl");
    const gamma = try firstMembership(&store, "/ws/c.wgsl");

    var buffer: [128]u8 = undefined;
    try store.upsertBuffer(try fileUri(&buffer, "/ws/c.wgsl"), "fn gamma_open() {}", .open_buffer);

    var alpha_text = try store.textForPart(alpha.part);
    defer alpha_text.deinit(testing.allocator);
    try testing.expectEqualStrings(disk_alpha, alpha_text.text);
    try testing.expectEqual(Types.SourceOrigin.disk, alpha_text.origin);

    var gamma_text = try store.textForPart(gamma.part);
    defer gamma_text.deinit(testing.allocator);
    try testing.expectEqualStrings("fn gamma_open() {}", gamma_text.text);
    try testing.expectEqual(Types.SourceOrigin.open_buffer, gamma_text.origin);
}

test "D39 a closed file change is detected by content hash, not mtime" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addProgram(&fake);
    var store = try makeStore(&fake);
    defer store.deinit();

    const membership = try firstMembership(&store, "/ws/a.wgsl");
    const old_hash = store.sourceHash("/ws/a.wgsl") orelse return error.TestExpectedSourceHash;
    const old_revision = store.rootRevision(membership.root);

    // The fake has no mtime at all: a provider refresh that returns
    // different bytes must invalidate the dependent root.
    try fake.addFile("/ws/a.wgsl", "fn alpha_changed() {}");
    store.invalidatePath("/ws/a.wgsl");

    const new_hash = store.sourceHash("/ws/a.wgsl") orelse return error.TestExpectedSourceHash;
    try testing.expect(!std.mem.eql(u8, &old_hash, &new_hash));
    try testing.expect(store.rootRevision(membership.root) > old_revision);

    var text = try store.textForPart(membership.part);
    defer text.deinit(testing.allocator);
    try testing.expectEqualStrings("fn alpha_changed() {}", text.text);
}

test "D40 a WGSL edit invalidates only roots that contain the part" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addProgram(&fake);
    var store = try makeStore(&fake);
    defer store.deinit();

    const alpha = try firstMembership(&store, "/ws/a.wgsl");
    const gamma = try firstMembership(&store, "/ws/c.wgsl");
    const alpha_root = alpha.root;
    const gamma_root = gamma.root;
    const alpha_before = store.rootRevision(alpha_root);
    const gamma_before = store.rootRevision(gamma_root);

    var buffer: [128]u8 = undefined;
    const uri = try fileUri(&buffer, "/ws/a.wgsl");
    try store.upsertBuffer(uri, "fn alpha_edited() {}", .open_buffer);
    try testing.expect(store.rootRevision(alpha_root) > alpha_before);
    try testing.expectEqual(gamma_before, store.rootRevision(gamma_root));

    const alpha_after_open = store.rootRevision(alpha_root);
    store.removeBuffer(uri);
    try testing.expect(store.rootRevision(alpha_root) > alpha_after_open);
    try testing.expectEqual(gamma_before, store.rootRevision(gamma_root));
}

test "D41 pngine.enabled=false parses through the spec table and empties memberships" {
    var config = try wgslender.Config.parseJson(testing.allocator,
        \\{ "lsp": { "pngine": { "enabled": false } } }
    );
    defer config.deinit(testing.allocator);
    try testing.expectEqual(false, config.lsp_pngine_enabled.?);

    var default_config = wgslender.Config{};
    defer default_config.deinit(testing.allocator);
    try testing.expectEqual(@as(?bool, null), default_config.lsp_pngine_enabled);

    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addProgram(&fake);
    var store = try makeStore(&fake);
    defer store.deinit();

    var before = try firstMembership(&store, "/ws/a.wgsl");
    _ = &before;
    store.setEnabled(false);
    var buffer: [512]u8 = undefined;
    var set = try store.membershipsFor(try fileUri(&buffer, "/ws/a.wgsl"));
    defer set.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), set.items.len);

    var handler = Handler.init(testing.allocator);
    defer handler.deinit();
    try testing.expect(handler.pngineEnabled());
    handler.workspace_config.lsp_pngine_enabled = false;
    try testing.expect(!handler.pngineEnabled());
    try handler.openDocument("test://legacy.wgsl", "fn legacy() {}", 1);
    try testing.expectEqualStrings("fn legacy() {}", handler.getDocumentSource("test://legacy.wgsl").?);
}

test "provider read failure keeps the membership and reports an unreadable source" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addProgram(&fake);
    var store = try makeStore(&fake);
    defer store.deinit();

    const membership = try firstMembership(&store, "/ws/a.wgsl");
    try fake.failReads("/ws/a.wgsl");
    store.invalidatePath("/ws/a.wgsl");

    try testing.expectError(error.SourceUnavailable, store.textForPart(membership.part));
    var buffer: [512]u8 = undefined;
    var set = try store.membershipsFor(try fileUri(&buffer, "/ws/a.wgsl"));
    defer set.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), set.items.len);
    try testing.expectEqual(Types.SourceStatus.unreadable, set.items[0].source_status);
}

test "deleting a referenced WGSL keeps membership but deleting its SJON removes it" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addProgram(&fake);
    var store = try makeStore(&fake);
    defer store.deinit();

    const membership = try firstMembership(&store, "/ws/a.wgsl");
    fake.removeFile("/ws/a.wgsl");
    store.invalidatePath("/ws/a.wgsl");
    try testing.expectError(error.SourceUnavailable, store.textForPart(membership.part));
    var buffer: [512]u8 = undefined;
    var wgsl_set = try store.membershipsFor(try fileUri(&buffer, "/ws/a.wgsl"));
    defer wgsl_set.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), wgsl_set.items.len);

    const program_id = membership.program;
    fake.removeFile("/ws/program.sjon");
    store.invalidatePath("/ws/program.sjon");
    try testing.expect(store.program(program_id) == null);
    var program_set = try store.membershipsFor(try fileUri(&buffer, "/ws/a.wgsl"));
    defer program_set.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), program_set.items.len);
}

test "a syntax-invalid refresh keeps the last known good program stale" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addProgram(&fake);
    var store = try makeStore(&fake);
    defer store.deinit();

    const membership = try firstMembership(&store, "/ws/a.wgsl");
    const generation_before = store.contentGeneration();
    try fake.addFile("/ws/program.sjon", "(wgsl :name alpha :file \"a.wgsl\"");
    store.invalidatePath("/ws/program.sjon");

    const retained = store.program(membership.program) orelse return error.TestExpectedRetainedProgram;
    try testing.expect(retained.stale);
    try testing.expectEqual(Types.DiscoveryState.incomplete, store.discoveryState());
    try testing.expect(store.contentGeneration() > generation_before);
}

test "a recovered SJON document replaces the stale graph and clears incomplete" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addProgram(&fake);
    var store = try makeStore(&fake);
    defer store.deinit();

    const membership = try firstMembership(&store, "/ws/a.wgsl");
    try fake.addFile("/ws/program.sjon", "(wgsl :name alpha :file \"a.wgsl\"");
    store.invalidatePath("/ws/program.sjon");
    try testing.expect(store.program(membership.program).?.stale);

    try fake.addFile("/ws/program.sjon", program_source);
    store.invalidatePath("/ws/program.sjon");

    const recovered = store.program(membership.program) orelse return error.TestExpectedProgram;
    try testing.expect(!recovered.stale);
    try testing.expectEqual(Types.DiscoveryState.complete, store.discoveryState());
    var text = try store.textForPart(membership.part);
    defer text.deinit(testing.allocator);
    try testing.expectEqualStrings(disk_alpha, text.text);
}

test "Handler open/change/incremental/close drive the store overlays" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addProgram(&fake);
    var store = try makeStore(&fake);
    defer store.deinit();

    var handler = Handler.init(testing.allocator);
    defer handler.deinit();
    handler.setPngineStore(&store);

    var buffer: [128]u8 = undefined;
    const uri = try fileUri(&buffer, "/ws/a.wgsl");
    const membership = try firstMembership(&store, "/ws/a.wgsl");

    try handler.openDocument(uri, "fn opened() {}", 1);
    try testing.expect(store.hasOverlay(uri));
    var opened = try store.textForPart(membership.part);
    defer opened.deinit(testing.allocator);
    try testing.expectEqualStrings("fn opened() {}", opened.text);

    try handler.changeDocument(uri, "fn changed() {}");
    var changed = try store.textForPart(membership.part);
    defer changed.deinit(testing.allocator);
    try testing.expectEqualStrings("fn changed() {}", changed.text);

    try handler.changeDocumentIncremental(uri, .{
        .start = .{ .line = 0, .character = 12 },
        .end = .{ .line = 0, .character = 12 },
    }, "!");
    var incremental = try store.textForPart(membership.part);
    defer incremental.deinit(testing.allocator);
    try testing.expectEqualStrings("fn changed()! {}", incremental.text);

    handler.closeDocument(uri);
    try testing.expect(!store.hasOverlay(uri));
    var closed = try store.textForPart(membership.part);
    defer closed.deinit(testing.allocator);
    try testing.expectEqualStrings(disk_alpha, closed.text);
    try testing.expectEqual(Types.SourceOrigin.disk, closed.origin);
}
