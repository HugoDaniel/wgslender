//! pngine project discovery and reverse membership (pngine-shaders phase 01,
//! Task 4).
//!
//! Every test binds the in-memory provider in `pngine_test_provider.zig`; no
//! project module opens a path and the fixture corpus is compiled in. The
//! inventory rows covered here are D01–D14, D25–D31, D36 (the distinct
//! `unsupported` discovery state) and D42 (all three discovery limits).

const std = @import("std");
const wgslender = @import("wgslender");
const provider_mod = @import("pngine_test_provider.zig");

const pngine = wgslender.Pngine;
const Types = pngine.Types;
const Store = pngine.Store;
const FakeProvider = provider_mod.FakeProvider;

const testing = std.testing;

fn fileUri(buffer: []u8, path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "file://{s}", .{path});
}

fn membershipsFor(store: *Store, path: []const u8) !Types.MembershipSet {
    var buffer: [512]u8 = undefined;
    return store.membershipsFor(try fileUri(&buffer, path));
}

fn partName(store: *const Store, id: Types.PartId) []const u8 {
    return store.part(id).?.name;
}

fn programPath(store: *const Store, id: Types.ProgramId) []const u8 {
    return store.program(id).?.document_path;
}

fn expectMembership(
    store: *const Store,
    set: *const Types.MembershipSet,
    path: []const u8,
) !Types.Membership {
    for (set.items) |membership| {
        const program = store.program(membership.program) orelse continue;
        const part = store.part(membership.part) orelse continue;
        switch (part.origin) {
            .file => |file| {
                const document_dir = std.fs.path.dirname(program.document_path) orelse "/";
                var joined_buf: [512]u8 = undefined;
                const joined = try std.fmt.bufPrint(&joined_buf, "{s}/{s}", .{ document_dir, file.path });
                if (std.mem.eql(u8, joined, path)) return membership;
            },
            .inline_code => {},
        }
    }
    std.debug.print("no membership for {s}; got {d}\n", .{ path, set.items.len });
    return error.TestExpectedMembership;
}

fn expectRoots(store: *const Store, membership: Types.Membership, names: []const []const u8) !void {
    try testing.expectEqual(names.len, membership.containing_roots.len);
    for (names, 0..) |expected, index| {
        try testing.expectEqualStrings(expected, partName(store, .{
            .program = membership.program,
            .index = membership.containing_roots[index],
        }));
    }
}

test "D01 clock scene_lib: one fragment with four dependants in sceneCode" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addCorpus();

    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);

    var set = try membershipsFor(&store, "/ws/clock/kernels/scene_lib.wgsl");
    defer set.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), set.items.len);

    const membership = set.items[0];
    try testing.expectEqual(@as(usize, 4), membership.dependants.len);
    try expectRoots(&store, membership, &.{"sceneCode"});
    try testing.expectEqualStrings("sceneLib", partName(&store, membership.part));
    try testing.expectEqualStrings("/ws/clock/program.sjon", programPath(&store, membership.program));

    const expected_dependants = [_][]const u8{ "clockScene", "clockVecScene", "clockFrag", "clockPost" };
    for (expected_dependants, 0..) |expected, index| {
        try testing.expectEqualStrings(expected, partName(&store, .{
            .program = membership.program,
            .index = membership.dependants[index],
        }));
    }
    try testing.expectEqual(Types.SourceStatus.readable, membership.source_status);
}

test "D02 clock_scene: fragment membership names its containing root" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addCorpus();

    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);

    var set = try membershipsFor(&store, "/ws/clock/kernels/clock_scene.wgsl");
    defer set.deinit(testing.allocator);
    const membership = try expectMembership(&store, &set, "/ws/clock/kernels/clock_scene.wgsl");
    try testing.expectEqualStrings("clockScene", partName(&store, membership.part));
    try expectRoots(&store, membership, &.{"sceneCode"});
}

test "D03 scene.wgsl: root membership and its four imports in written order" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addCorpus();

    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);

    var set = try membershipsFor(&store, "/ws/clock/shaders/scene.wgsl");
    defer set.deinit(testing.allocator);
    const membership = try expectMembership(&store, &set, "/ws/clock/shaders/scene.wgsl");
    try expectRoots(&store, membership, &.{"sceneCode"});

    const root = store.part(membership.part).?;
    try testing.expectEqual(Types.PartKind.shader_module, root.kind);
    try testing.expectEqualStrings("sceneCode", root.name);
    const expected_imports = [_][]const u8{ "clockScene", "clockVecScene", "clockFrag", "clockPost" };
    try testing.expectEqual(expected_imports.len, root.imports.len);
    for (expected_imports, 0..) |expected, index| {
        try testing.expectEqualStrings(expected, root.imports[index].name);
    }
}

test "D04 demo palette: one part with four containing roots" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addCorpus();

    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);

    var set = try membershipsFor(&store, "/ws/demo/palette.wgsl");
    defer set.deinit(testing.allocator);
    const membership = try expectMembership(&store, &set, "/ws/demo/palette.wgsl");
    try expectRoots(&store, membership, &.{ "bgCode", "squaresCode", "postCode", "compositeCode" });
}

test "D05 bounce: a no-import root is a member of itself" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addCorpus();

    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);

    var set = try membershipsFor(&store, "/ws/bounce/bouncing-sq.wgsl");
    defer set.deinit(testing.allocator);
    const membership = try expectMembership(&store, &set, "/ws/bounce/bouncing-sq.wgsl");
    try testing.expectEqualStrings("bounceCode", partName(&store, membership.part));
    try expectRoots(&store, membership, &.{"bounceCode"});
}

test "D06 veclock: the second no-import root" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addCorpus();

    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);

    var set = try membershipsFor(&store, "/ws/veclock/clock_vec.wgsl");
    defer set.deinit(testing.allocator);
    const membership = try expectMembership(&store, &set, "/ws/veclock/clock_vec.wgsl");
    try testing.expectEqualStrings("clockVecCode", partName(&store, membership.part));
    try expectRoots(&store, membership, &.{"clockVecCode"});
}

test "D07 unreferenced circle.wgsl is not a member by directory or name" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addCorpus();

    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);

    var set = try membershipsFor(&store, "/ws/veclock/kernels/circle.wgsl");
    defer set.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), set.items.len);
}

test "D08 marker presence alone creates no membership" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/marker/sjon-lsp.sjon",
        \\(sjon-lsp :version 1 :bundles [(bundle :name all :files ["**/*.sjon"])])
    );
    try fake.addFile("/ws/marker/program.sjon",
        \\(shader-module :name root :file "root.wgsl")
    );
    try fake.addFile("/ws/marker/root.wgsl", "fn root() {}");
    try fake.addFile("/ws/marker/stray.wgsl", "fn stray() {}");

    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();
    const roots = [_][]const u8{"/ws/marker"};
    try store.setWorkspaceRoots(&roots);

    var set = try membershipsFor(&store, "/ws/marker/stray.wgsl");
    defer set.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), set.items.len);
    try testing.expectEqual(Types.DiscoveryState.complete, store.discoveryState());
}

test "D09 ancestor program finds an external file" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/outside/program.sjon",
        \\(shader-module :name externalRoot :file "kernels/ext.wgsl")
    );
    try fake.addFile("/outside/kernels/ext.wgsl", "fn ext() {}");

    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);

    var set = try membershipsFor(&store, "/outside/kernels/ext.wgsl");
    defer set.deinit(testing.allocator);
    const membership = try expectMembership(&store, &set, "/outside/kernels/ext.wgsl");
    try testing.expectEqualStrings("externalRoot", partName(&store, membership.part));
    try testing.expectEqualStrings("/outside/program.sjon", programPath(&store, membership.program));
}

test "D10 nested parent and child programs both keep a membership" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/outer/program.sjon",
        \\(shader-module :name outerRoot :file "shared.wgsl")
    );
    try fake.addFile("/ws/outer/inner/program.sjon",
        \\(shader-module :name innerRoot :file "../shared.wgsl")
    );
    try fake.addFile("/ws/outer/shared.wgsl", "fn shared() {}");

    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);

    var set = try membershipsFor(&store, "/ws/outer/shared.wgsl");
    defer set.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), set.items.len);
    // Stable order is canonical document path, then part index.
    try testing.expectEqualStrings("/ws/outer/inner/program.sjon", programPath(&store, set.items[0].program));
    try testing.expectEqualStrings("/ws/outer/program.sjon", programPath(&store, set.items[1].program));
}

test "D11 two documents in one project contribute independent memberships" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/proj/a.sjon",
        \\(shader-module :name rootA :file "shared.wgsl")
    );
    try fake.addFile("/ws/proj/b.sjon",
        \\(shader-module :name rootB :file "shared.wgsl")
    );
    try fake.addFile("/ws/proj/shared.wgsl", "fn shared() {}");

    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);

    var set = try membershipsFor(&store, "/ws/proj/shared.wgsl");
    defer set.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), set.items.len);
    try expectRoots(&store, set.items[0], &.{"rootA"});
    try expectRoots(&store, set.items[1], &.{"rootB"});
}

test "D12 overlapping workspace roots dedupe one canonical program" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/proj/program.sjon",
        \\(shader-module :name root :file "shared.wgsl")
    );
    try fake.addFile("/ws/proj/shared.wgsl", "fn shared() {}");

    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();
    const roots = [_][]const u8{ "/ws", "/ws/proj", "/ws/proj" };
    try store.setWorkspaceRoots(&roots);

    var set = try membershipsFor(&store, "/ws/proj/shared.wgsl");
    defer set.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), set.items.len);
}

test "D13 one file is a fragment in one program and a root in another" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/a/program.sjon",
        \\(wgsl :name lib :file "../shared.wgsl")
        \\(shader-module :name rootA :file "root_a.wgsl" :imports [lib])
    );
    try fake.addFile("/ws/a/root_a.wgsl", "fn root_a() {}");
    try fake.addFile("/ws/b/program.sjon",
        \\(shader-module :name sharedRoot :file "../shared.wgsl")
    );
    try fake.addFile("/ws/shared.wgsl", "fn shared() {}");

    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);

    var set = try membershipsFor(&store, "/ws/shared.wgsl");
    defer set.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), set.items.len);
    try testing.expectEqual(Types.PartKind.wgsl, store.part(set.items[0].part).?.kind);
    try testing.expectEqual(Types.PartKind.shader_module, store.part(set.items[1].part).?.kind);
}

test "D14 equal fragment names resolve inside their own program" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/a/program.sjon",
        \\(wgsl :name shared :file "a.wgsl")
        \\(shader-module :name rootA :file "root_a.wgsl" :imports [shared])
    );
    try fake.addFile("/ws/a/a.wgsl", "fn a() {}");
    try fake.addFile("/ws/a/root_a.wgsl", "fn root_a() {}");
    try fake.addFile("/ws/b/program.sjon",
        \\(wgsl :name shared :file "b.wgsl")
        \\(shader-module :name rootB :file "root_b.wgsl" :imports [shared])
    );
    try fake.addFile("/ws/b/b.wgsl", "fn b() {}");
    try fake.addFile("/ws/b/root_b.wgsl", "fn root_b() {}");

    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);

    var a_set = try membershipsFor(&store, "/ws/a/a.wgsl");
    defer a_set.deinit(testing.allocator);
    const a_membership = try expectMembership(&store, &a_set, "/ws/a/a.wgsl");
    try expectRoots(&store, a_membership, &.{"rootA"});

    var b_set = try membershipsFor(&store, "/ws/b/b.wgsl");
    defer b_set.deinit(testing.allocator);
    const b_membership = try expectMembership(&store, &b_set, "/ws/b/b.wgsl");
    try expectRoots(&store, b_membership, &.{"rootB"});
}

test "D25 missing referenced WGSL keeps an unreadable membership" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon",
        \\(wgsl :name lib :file "missing.wgsl")
        \\(shader-module :name root :file "root.wgsl" :imports [lib])
    );
    try fake.addFile("/ws/root.wgsl", "fn root() {}");

    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);

    var set = try membershipsFor(&store, "/ws/missing.wgsl");
    defer set.deinit(testing.allocator);
    const membership = try expectMembership(&store, &set, "/ws/missing.wgsl");
    try testing.expectEqual(Types.SourceStatus.unreadable, membership.source_status);
    try expectRoots(&store, membership, &.{"root"});
}

test "D26 a missing marker-referenced document is named in an incomplete result" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/sjon-lsp.sjon",
        \\(sjon-lsp :version 1 :bundles [(bundle :name b :files ["missing.sjon"])])
    );

    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);

    try testing.expectEqual(Types.DiscoveryState.incomplete, store.discoveryState());
    const reason = store.incompleteReason() orelse return error.TestExpectedReason;
    try testing.expect(std.mem.indexOf(u8, reason, "missing.sjon") != null);
}

test "D27 syntax-invalid SJON contributes nothing and is incomplete" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon",
        \\(wgsl :name broken :file "x.wgsl"
    );
    try fake.addFile("/ws/x.wgsl", "fn x() {}");

    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);

    try testing.expectEqual(Types.DiscoveryState.incomplete, store.discoveryState());
    var set = try membershipsFor(&store, "/ws/x.wgsl");
    defer set.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), set.items.len);
}

test "D28 last-known-good graph is retained and marked stale" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon",
        \\(wgsl :name lib :file "lib.wgsl")
        \\(shader-module :name root :file "root.wgsl" :imports [lib])
    );
    try fake.addFile("/ws/lib.wgsl", "fn lib() {}");
    try fake.addFile("/ws/root.wgsl", "fn root() {}");

    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);

    var set = try membershipsFor(&store, "/ws/lib.wgsl");
    defer set.deinit(testing.allocator);
    const membership = try expectMembership(&store, &set, "/ws/lib.wgsl");
    const program_id = membership.program;
    try testing.expect(!store.program(program_id).?.stale);
    const generation_before = store.contentGeneration();

    try fake.addFile("/ws/program.sjon", "(wgsl :name lib :file \"lib.wgsl\"");
    try store.setWorkspaceRoots(&roots);

    try testing.expectEqual(Types.DiscoveryState.incomplete, store.discoveryState());
    const retained = store.program(program_id) orelse return error.TestExpectedRetainedProgram;
    try testing.expect(retained.stale);
    try testing.expect(store.contentGeneration() > generation_before);

    var after = try membershipsFor(&store, "/ws/lib.wgsl");
    defer after.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), after.items.len);
}

test "D29 deleting an invalid SJON document removes its program and memberships" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon",
        \\(wgsl :name lib :file "lib.wgsl")
        \\(shader-module :name root :file "root.wgsl" :imports [lib])
    );
    try fake.addFile("/ws/lib.wgsl", "fn lib() {}");
    try fake.addFile("/ws/root.wgsl", "fn root() {}");

    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);

    var set = try membershipsFor(&store, "/ws/lib.wgsl");
    defer set.deinit(testing.allocator);
    const membership = try expectMembership(&store, &set, "/ws/lib.wgsl");
    const program_id = membership.program;

    try fake.addFile("/ws/program.sjon", "(wgsl :name lib :file \"lib.wgsl\"");
    try store.setWorkspaceRoots(&roots);
    try testing.expect(store.program(program_id) != null);

    fake.removeFile("/ws/program.sjon");
    try store.setWorkspaceRoots(&roots);
    try testing.expect(store.program(program_id) == null);

    var after = try membershipsFor(&store, "/ws/lib.wgsl");
    defer after.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), after.items.len);
}

test "D30 a malformed marker contributes no patterns but direct candidates load" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/sjon-lsp.sjon", "(sjon-lsp :version 1 :bundles [");
    try fake.addFile("/ws/program.sjon",
        \\(wgsl :name lib :file "lib.wgsl")
        \\(shader-module :name root :file "root.wgsl" :imports [lib])
    );
    try fake.addFile("/ws/lib.wgsl", "fn lib() {}");
    try fake.addFile("/ws/root.wgsl", "fn root() {}");

    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);

    try testing.expectEqual(Types.DiscoveryState.incomplete, store.discoveryState());
    var set = try membershipsFor(&store, "/ws/lib.wgsl");
    defer set.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), set.items.len);
}

test "D31 bundle glob and nested path load the candidate once" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/sjon-lsp.sjon",
        \\(sjon-lsp :version 1 :bundles [
        \\  (bundle :name b :files ["nested/**/*.sjon" "nested/deep/program.sjon"])
        \\])
    );
    try fake.addFile("/ws/nested/deep/program.sjon",
        \\(wgsl :name lib :file "lib.wgsl")
        \\(shader-module :name root :file "root.wgsl" :imports [lib])
    );
    try fake.addFile("/ws/nested/deep/lib.wgsl", "fn lib() {}");
    try fake.addFile("/ws/nested/deep/root.wgsl", "fn root() {}");

    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);

    try testing.expectEqual(Types.DiscoveryState.complete, store.discoveryState());
    var set = try membershipsFor(&store, "/ws/nested/deep/lib.wgsl");
    defer set.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), set.items.len);
}

test "D36 (import ...) is the distinct unsupported discovery state" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", "(import :file \"base.sjon\")");

    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);

    try testing.expectEqual(Types.DiscoveryState.unsupported, store.discoveryState());
}

test "D42 directory cap is incomplete, not none, and keeps earlier memberships" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/a/program.sjon",
        \\(shader-module :name rootA :file "a.wgsl")
    );
    try fake.addFile("/ws/a/a.wgsl", "fn a() {}");
    try fake.addFile("/ws/b/program.sjon",
        \\(shader-module :name rootB :file "b.wgsl")
    );
    try fake.addFile("/ws/b/b.wgsl", "fn b() {}");
    try fake.addFile("/ws/c/program.sjon",
        \\(shader-module :name rootC :file "c.wgsl")
    );
    try fake.addFile("/ws/c/c.wgsl", "fn c() {}");

    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();
    store.limits.max_directories = 2;
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);

    try testing.expectEqual(Types.DiscoveryState.incomplete, store.discoveryState());
    try testing.expect(store.incompleteReason() != null);
    var set = try membershipsFor(&store, "/ws/a/a.wgsl");
    defer set.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), set.items.len);
}

test "D42 candidate cap is incomplete and never a false none" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/a.sjon",
        \\(shader-module :name rootA :file "a.wgsl")
    );
    try fake.addFile("/ws/a.wgsl", "fn a() {}");
    try fake.addFile("/ws/b.sjon",
        \\(shader-module :name rootB :file "b.wgsl")
    );
    try fake.addFile("/ws/b.wgsl", "fn b() {}");

    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();
    store.limits.max_candidates = 1;
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);

    try testing.expectEqual(Types.DiscoveryState.incomplete, store.discoveryState());
    var set = try membershipsFor(&store, "/ws/a.wgsl");
    defer set.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), set.items.len);
}

test "D42 input byte cap is incomplete with a reason" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon",
        \\(shader-module :name root :file "a.wgsl")
    );
    try fake.addFile("/ws/a.wgsl", "fn a() {}");

    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();
    store.limits.max_input_bytes = 8;
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);

    try testing.expectEqual(Types.DiscoveryState.incomplete, store.discoveryState());
    try testing.expect(store.incompleteReason() != null);
}
