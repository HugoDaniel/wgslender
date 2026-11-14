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

const shared_program_source =
    \\(wgsl :name shared :file "shared.wgsl")
    \\(wgsl :name alpha :file "a.wgsl")
    \\(shader-module :name rootA :file "root_a.wgsl" :imports [shared alpha])
    \\(shader-module :name rootB :file "root_b.wgsl" :imports [shared])
    \\(shader-module :name rootC :file "root_c.wgsl" :imports [alpha])
;

const directive_program_source =
    \\(wgsl :name first :file "first.wgsl")
    \\(wgsl :name second :file "second.wgsl")
    \\(shader-module :name root :file "root.wgsl" :imports [first second])
;

fn addSharedProgram(fake: *FakeProvider) !void {
    try fake.addFile("/ws/program.sjon", shared_program_source);
    try fake.addFile("/ws/shared.wgsl", "fn shared_disk() {}");
    try fake.addFile("/ws/a.wgsl", disk_alpha);
    try fake.addFile("/ws/root_a.wgsl", disk_root_a);
    try fake.addFile("/ws/root_b.wgsl", disk_root_b);
    try fake.addFile("/ws/root_c.wgsl", "fn root_c() {}");
}

fn addDirectiveProgram(fake: *FakeProvider) !void {
    try fake.addFile("/ws/program.sjon", directive_program_source);
    try fake.addFile("/ws/first.wgsl", "enable f16;\nfn first() {}");
    try fake.addFile("/ws/second.wgsl", "enable f16;\nfn second() {}");
    try fake.addFile("/ws/root.wgsl", "fn root() {}");
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

/// The root that contains `path`. For a root's own file this is the root
/// part itself; for a fragment it is the first containing root.
fn rootFor(store: *Store, path: []const u8) !Types.PartId {
    return (try firstMembership(store, path)).root;
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

// =========================================================================
// Assembly cache (pngine-shaders phase 02, Task 4)
// =========================================================================

test "A28 an unsaved current root part assembles from the buffer, not disk" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addProgram(&fake);
    var store = try makeStore(&fake);
    defer store.deinit();

    const root_b = try rootFor(&store, "/ws/root_b.wgsl");
    var buffer: [128]u8 = undefined;
    const uri = try fileUri(&buffer, "/ws/root_b.wgsl");
    try store.upsertBuffer(uri, "fn root_b_open() {}", .open_buffer);

    const unit = try store.assembleRoot(root_b);
    try testing.expectEqualStrings("fn gamma_disk() {}\nfn root_b_open() {}\n", unit.text);
    try testing.expect(std.mem.indexOf(u8, unit.text, "root_b()") == null);

    // The cache hit is the same unit, not a byte-equal rebuild.
    try testing.expect(unit == try store.assembleRoot(root_b));
}

test "A29 an unsaved shared sibling appears in containing roots and no other" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addSharedProgram(&fake);
    var store = try makeStore(&fake);
    defer store.deinit();

    const root_a = try rootFor(&store, "/ws/root_a.wgsl");
    const root_b = try rootFor(&store, "/ws/root_b.wgsl");
    const root_c = try rootFor(&store, "/ws/root_c.wgsl");

    const a_before = try store.assembleRoot(root_a);
    const b_before = try store.assembleRoot(root_b);
    const c_before = try store.assembleRoot(root_c);
    try testing.expectEqualStrings(
        "fn shared_disk() {}\nfn alpha_disk() {}\nfn root_a() {}\n",
        a_before.text,
    );
    try testing.expectEqualStrings("fn shared_disk() {}\nfn root_b() {}\n", b_before.text);
    const c_revision = store.rootRevision(root_c);

    var buffer: [128]u8 = undefined;
    const uri = try fileUri(&buffer, "/ws/shared.wgsl");
    try store.upsertBuffer(uri, "fn shared_open() {}", .open_buffer);

    const a_after = try store.assembleRoot(root_a);
    const b_after = try store.assembleRoot(root_b);
    const c_after = try store.assembleRoot(root_c);

    try testing.expect(a_after != a_before);
    try testing.expect(b_after != b_before);
    try testing.expectEqualStrings(
        "fn shared_open() {}\nfn alpha_disk() {}\nfn root_a() {}\n",
        a_after.text,
    );
    try testing.expectEqualStrings("fn shared_open() {}\nfn root_b() {}\n", b_after.text);
    try testing.expect(c_after == c_before);
    try testing.expectEqual(c_revision, store.rootRevision(root_c));
    try testing.expect(std.mem.indexOf(u8, c_after.text, "shared_open()") == null);
}

test "A30 a missing closed sibling reports MissingSource and recovers" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addProgram(&fake);
    var store = try makeStore(&fake);
    defer store.deinit();

    const root_a = try rootFor(&store, "/ws/root_a.wgsl");
    const first = try store.assembleRoot(root_a);
    try testing.expectEqualStrings("fn alpha_disk() {}\nfn root_a() {}\n", first.text);

    fake.removeFile("/ws/a.wgsl");
    store.invalidatePath("/ws/a.wgsl");
    try testing.expectError(error.MissingSource, store.assembleRoot(root_a));
    // No empty substitution: the last good unit is still a real module.
    try testing.expectEqualStrings("fn alpha_disk() {}\nfn root_a() {}\n", first.text);

    try fake.addFile("/ws/a.wgsl", "fn alpha_restored() {}");
    store.invalidatePath("/ws/a.wgsl");
    const recovered = try store.assembleRoot(root_a);
    try testing.expectEqualStrings("fn alpha_restored() {}\nfn root_a() {}\n", recovered.text);
}

test "a provider read failure reports MissingSource and recovers to the cached unit" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addProgram(&fake);
    var store = try makeStore(&fake);
    defer store.deinit();

    const root_a = try rootFor(&store, "/ws/root_a.wgsl");
    const first = try store.assembleRoot(root_a);

    try fake.failReads("/ws/a.wgsl");
    store.invalidatePath("/ws/a.wgsl");
    try testing.expectError(error.MissingSource, store.assembleRoot(root_a));

    fake.allowReads("/ws/a.wgsl");
    store.invalidatePath("/ws/a.wgsl");
    const recovered = try store.assembleRoot(root_a);
    // Same disk bytes: the content key matches the unit built before the
    // failure, so the cache returns that unit rather than rebuilding it.
    try testing.expect(recovered == first);
    try testing.expectEqualStrings("fn alpha_disk() {}\nfn root_a() {}\n", recovered.text);
}

test "editing one root's part preserves the other root's cached unit" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addProgram(&fake);
    var store = try makeStore(&fake);
    defer store.deinit();

    const root_a = try rootFor(&store, "/ws/root_a.wgsl");
    const root_b = try rootFor(&store, "/ws/root_b.wgsl");
    const a_before = try store.assembleRoot(root_a);
    const b_before = try store.assembleRoot(root_b);
    const b_revision = store.rootRevision(root_b);

    var buffer: [128]u8 = undefined;
    const uri = try fileUri(&buffer, "/ws/root_a.wgsl");
    try store.upsertBuffer(uri, "fn root_a_open() {}", .open_buffer);

    const a_after = try store.assembleRoot(root_a);
    const b_after = try store.assembleRoot(root_b);

    try testing.expect(a_after != a_before);
    try testing.expectEqualStrings("fn alpha_disk() {}\nfn root_a_open() {}\n", a_after.text);
    try testing.expect(b_after == b_before);
    try testing.expectEqual(b_revision, store.rootRevision(root_b));
    try testing.expectEqualStrings("fn gamma_disk() {}\nfn root_b() {}\n", b_after.text);
}

test "a repeated assembly performs no provider reads and no allocations" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addProgram(&fake);
    var store = try makeStore(&fake);
    defer store.deinit();

    const root_a = try rootFor(&store, "/ws/root_a.wgsl");
    const first = try store.assembleRoot(root_a);
    const reads = fake.read_calls;
    const generation = store.contentGeneration();

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const real_gpa = store.gpa;
    var second: *const pngine.Assembled = undefined;
    {
        store.gpa = failing.allocator();
        defer store.gpa = real_gpa;
        second = try store.assembleRoot(root_a);
    }

    try testing.expect(second == first);
    try testing.expectEqual(reads, fake.read_calls);
    try testing.expectEqual(generation, store.contentGeneration());
    try testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "a graph generation change rebuilds even when the assembled bytes match" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addProgram(&fake);
    var store = try makeStore(&fake);
    defer store.deinit();

    const root_a = try rootFor(&store, "/ws/root_a.wgsl");
    const first = try store.assembleRoot(root_a);
    const first_address = @intFromPtr(first);

    // Re-saving the same document replaces the Program. The cached unit's
    // rows borrow that Program's names, so the graph generation must not
    // serve it again.
    try fake.addFile("/ws/program.sjon", program_source);
    store.invalidatePath("/ws/program.sjon");
    const after_refresh = try rootFor(&store, "/ws/root_a.wgsl");
    const second = try store.assembleRoot(after_refresh);

    try testing.expect(@intFromPtr(second) != first_address);
    try testing.expectEqualStrings("fn alpha_disk() {}\nfn root_a() {}\n", second.text);
}

test "a changed import closure rebuilds the root from the new graph" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addProgram(&fake);
    var store = try makeStore(&fake);
    defer store.deinit();

    _ = try store.assembleRoot(try rootFor(&store, "/ws/root_a.wgsl"));

    try fake.addFile("/ws/beta.wgsl", "fn beta() {}");
    try fake.addFile("/ws/program.sjon",
        \\(wgsl :name alpha :file "a.wgsl")
        \\(wgsl :name gamma :file "c.wgsl")
        \\(wgsl :name beta :file "beta.wgsl")
        \\(shader-module :name rootA :file "root_a.wgsl" :imports [alpha beta])
        \\(shader-module :name rootB :file "root_b.wgsl" :imports [gamma])
    );
    store.invalidatePath("/ws/program.sjon");
    const generation = store.contentGeneration();

    const root_a = try rootFor(&store, "/ws/root_a.wgsl");
    const unit = try store.assembleRoot(root_a);
    try testing.expectEqualStrings(
        "fn alpha_disk() {}\nfn beta() {}\nfn root_a() {}\n",
        unit.text,
    );
    // The document refresh already bumped the store generation; populating
    // a fresh cache entry adds no second bump.
    try testing.expectEqual(generation, store.contentGeneration());
}

test "a content-key change that keeps the assembled bytes reuses the cached unit" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addDirectiveProgram(&fake);
    var store = try makeStore(&fake);
    defer store.deinit();

    const root = try rootFor(&store, "/ws/root.wgsl");
    const first = try store.assembleRoot(root);
    const generation = store.contentGeneration();

    // Same length, same blanked bytes, same hoisted copy: only the source
    // hash changes (space -> tab inside the duplicate directive).
    var buffer: [128]u8 = undefined;
    const uri = try fileUri(&buffer, "/ws/second.wgsl");
    try store.upsertBuffer(uri, "enable\tf16;\nfn second() {}", .open_buffer);
    const after_edit = store.contentGeneration();
    try testing.expect(after_edit > generation);

    const second_part = (try firstMembership(&store, "/ws/second.wgsl")).part;
    var source = try store.textForPart(second_part);
    defer source.deinit(testing.allocator);
    try testing.expectEqualStrings("enable\tf16;\nfn second() {}", source.text);

    const second = try store.assembleRoot(root);
    try testing.expect(second == first);
    try testing.expectEqual(after_edit, store.contentGeneration());
}

test "A42 allocation failures during a rebuild leave no leak or half-cached unit" {
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var fake = FakeProvider.init(testing.allocator);
        defer fake.deinit();
        try addProgram(&fake);
        var store = try makeStore(&fake);
        defer store.deinit();

        const root_a = try rootFor(&store, "/ws/root_a.wgsl");
        const first = try store.assembleRoot(root_a);
        try testing.expectEqualStrings("fn alpha_disk() {}\nfn root_a() {}\n", first.text);

        try fake.addFile("/ws/a.wgsl", "fn alpha_sweep() {}");
        store.invalidatePath("/ws/a.wgsl");

        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const real_gpa = store.gpa;
        store.gpa = failing.allocator();
        const result = store.assembleRoot(root_a);
        store.gpa = real_gpa;

        if (result) |unit| {
            try testing.expectEqualStrings("fn alpha_sweep() {}\nfn root_a() {}\n", unit.text);
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            // The old entry was neither freed nor half-replaced.
            try testing.expectEqualStrings("fn alpha_disk() {}\nfn root_a() {}\n", first.text);
            const rebuilt = try store.assembleRoot(root_a);
            try testing.expectEqualStrings("fn alpha_sweep() {}\nfn root_a() {}\n", rebuilt.text);
        }

        if (!failing.has_induced_failure) break;
    }
}

test "a missing unreachable part does not fail another root's assembly" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addProgram(&fake);
    var store = try makeStore(&fake);
    defer store.deinit();

    // gamma belongs only to rootB; rootA's closure never reads it.
    fake.removeFile("/ws/c.wgsl");
    store.invalidatePath("/ws/c.wgsl");

    const root_a = try rootFor(&store, "/ws/root_a.wgsl");
    const unit = try store.assembleRoot(root_a);
    try testing.expectEqualStrings("fn alpha_disk() {}\nfn root_a() {}\n", unit.text);
}

test "A42 the first assembly leaves no leak or half-cached unit on allocation failure" {
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var fake = FakeProvider.init(testing.allocator);
        defer fake.deinit();
        try addProgram(&fake);
        var store = try makeStore(&fake);
        defer store.deinit();

        const root_a = try rootFor(&store, "/ws/root_a.wgsl");
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const real_gpa = store.gpa;
        store.gpa = failing.allocator();
        const result = store.assembleRoot(root_a);
        store.gpa = real_gpa;

        if (result) |unit| {
            try testing.expectEqualStrings("fn alpha_disk() {}\nfn root_a() {}\n", unit.text);
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            const rebuilt = try store.assembleRoot(root_a);
            try testing.expectEqualStrings("fn alpha_disk() {}\nfn root_a() {}\n", rebuilt.text);
        }

        if (!failing.has_induced_failure) break;
    }
}
