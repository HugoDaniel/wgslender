//! pngine CLI selection (pngine-shaders phase 05, Task 1).
//!
//! Every row X01–X17 from the phase-05 inventory has a named test here.
//! Selection runs against the in-memory provider in
//! `pngine_test_provider.zig`; no test opens a project document directly.
//! The CLI flag table itself is exercised by `cli/main.zig`'s own tests.

const std = @import("std");
const wgslender = @import("wgslender");
const selection = @import("PngineSelection");
const provider_mod = @import("pngine_test_provider.zig");

const Store = selection.Store;
const Failure = selection.Failure;
const Flags = selection.Flags;
const FakeProvider = provider_mod.FakeProvider;
const testing = std.testing;

fn rootName(store: *const Store, id: selection.RootId) []const u8 {
    return store.part(id).?.name;
}

fn expectRootNames(store: *const Store, selected: *const selection.ProjectSelection, names: []const []const u8) !void {
    try testing.expectEqual(names.len, selected.roots.len);
    for (names, 0..) |name, index| {
        try testing.expectEqualStrings(name, rootName(store, selected.roots[index]));
    }
}

fn expectMessageContains(failure: *const Failure, needle: []const u8) !void {
    if (failure.message.len == 0) {
        std.debug.print("selection failure had no message\n", .{});
        return error.TestExpectedMessage;
    }
    if (std.mem.indexOf(u8, failure.message, needle) == null) {
        std.debug.print("failure message '{s}' does not contain '{s}'\n", .{ failure.message, needle });
        return error.TestExpectedMessage;
    }
}

// X01 — Bare `.wgsl`, no reference: no selectors means today's single-source
// path, and asking for a project explicitly still has to report absence.
test "X01 bare WGSL without selectors keeps single-source behavior" {
    var failure = Failure{};
    defer failure.deinit(testing.allocator);

    try testing.expect(!selection.selectionRequested(.{}));
    try selection.validateFlagShape(.{}, false, &failure, testing.allocator);

    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();

    try testing.expectError(
        selection.Error.NoProject,
        selection.selectProjectWithFailure(&store, "/standalone.wgsl", null, null, false, &failure),
    );
    try expectMessageContains(&failure, "no pngine project");
}

// X02 — `--no-project` on a referenced file: explicit single-source mode.
test "X02 no-project suppresses discovery for a referenced file" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addCorpus();
    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();

    const flags = Flags{ .no_project = true };
    try testing.expect(!selection.selectionRequested(flags));
    try selection.validateFlagShape(flags, false, null, testing.allocator);

    var failure = Failure{};
    defer failure.deinit(testing.allocator);
    try testing.expectError(
        selection.Error.NoProject,
        selection.selectProjectWithFailure(&store, "/ws/demo/bg.wgsl", null, null, true, &failure),
    );
    try expectMessageContains(&failure, "--no-project");
}

// X03 — `--project program.sjon` on a file bypasses workspace discovery.
test "X03 explicit project bypasses a different discovered workspace" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addCorpus();
    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();
    const workspace = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&workspace);

    var failure = Failure{};
    defer failure.deinit(testing.allocator);
    var selected = try selection.selectProjectWithFailure(
        &store,
        "/ws/demo/palette.wgsl",
        "/ws/demo/program.sjon",
        null,
        false,
        &failure,
    );
    defer selected.deinit(testing.allocator);

    const program = store.program(selected.program).?;
    try testing.expectEqualStrings("/ws/demo/program.sjon", program.document_path);
    try expectRootNames(&store, &selected, &.{ "bgCode", "squaresCode", "postCode", "compositeCode" });
}

// X04 — `--project` names a directory: usage error, exit 2.
test "X04 project naming a directory is a usage error" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addCorpus();
    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();

    var failure = Failure{};
    defer failure.deinit(testing.allocator);
    try testing.expectError(
        selection.Error.ProjectIsDirectory,
        selection.selectProjectWithFailure(&store, "/ws/demo/bg.wgsl", "/ws/demo", null, false, &failure),
    );
    try expectMessageContains(&failure, "/ws/demo");
    try expectMessageContains(&failure, "directory");
}

// X05 — `--root` without a project and without discovered membership.
test "X05 root without a project or membership is a usage error" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();

    var failure = Failure{};
    defer failure.deinit(testing.allocator);
    try testing.expectError(
        selection.Error.RootRequiresProject,
        selection.selectProjectWithFailure(&store, "/standalone.wgsl", null, "bgCode", false, &failure),
    );
    try expectMessageContains(&failure, "--root");
    try expectMessageContains(&failure, "bgCode");
}

// X06 — Unknown root name: usage error naming the available roots.
test "X06 unknown root names the available roots" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addCorpus();
    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();

    var failure = Failure{};
    defer failure.deinit(testing.allocator);
    try testing.expectError(
        selection.Error.UnknownRoot,
        selection.selectProjectWithFailure(&store, "/ws/demo/bg.wgsl", null, "nope", false, &failure),
    );
    try expectMessageContains(&failure, "nope");
    try expectMessageContains(&failure, "bgCode");
    try expectMessageContains(&failure, "compositeCode");
}

// X07 — Duplicate root name: a program/selection error, never first-wins.
test "X07 duplicate root name is refused with the name and location" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/dup/program.sjon",
        \\(wgsl :name frag :file "frag.wgsl")
        \\(shader-module :name twice :file "a.wgsl")
        \\(shader-module :name twice :file "b.wgsl")
    );
    try fake.addFile("/ws/dup/frag.wgsl", "fn frag() {}");
    try fake.addFile("/ws/dup/a.wgsl", "fn a() {}");
    try fake.addFile("/ws/dup/b.wgsl", "fn b() {}");

    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();

    var failure = Failure{};
    defer failure.deinit(testing.allocator);
    try testing.expectError(
        selection.Error.DuplicateRootName,
        selection.selectProjectWithFailure(&store, "/ws/dup/a.wgsl", "/ws/dup/program.sjon", null, false, &failure),
    );
    try expectMessageContains(&failure, "/ws/dup/program.sjon");
    try expectMessageContains(&failure, "twice");
    // Located: the message carries at least one line:column pair.
    try expectMessageContains(&failure, ":3:");
}

// X08 — A fragment inside one root auto-selects that root.
test "X08 fragment in one root selects the containing shader module" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addCorpus();
    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();

    var selected = try selection.selectProjectWithFailure(
        &store,
        "/ws/clock/kernels/scene_lib.wgsl",
        null,
        null,
        false,
        null,
    );
    defer selected.deinit(testing.allocator);

    try expectRootNames(&store, &selected, &.{"sceneCode"});
    try testing.expectEqualStrings(
        "sceneLib",
        store.part(selected.input_part.?).?.name,
    );
}

// X09 — `demo/palette.wgsl` belongs to all four demo roots.
test "X09 shared fragment selects all containing shader modules in order" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addCorpus();
    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();

    var selected = try selection.selectProjectWithFailure(
        &store,
        "/ws/demo/palette.wgsl",
        null,
        null,
        false,
        null,
    );
    defer selected.deinit(testing.allocator);

    try expectRootNames(&store, &selected, &.{ "bgCode", "squaresCode", "postCode", "compositeCode" });
}

// X10 — Multi-root fragment without `--root`: usage error listing roots.
test "X10 multi-root input without root is refused for artifact commands" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addCorpus();
    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();

    var failure = Failure{};
    defer failure.deinit(testing.allocator);
    var selected = try selection.selectProjectWithFailure(
        &store,
        "/ws/demo/palette.wgsl",
        null,
        null,
        false,
        &failure,
    );
    defer selected.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), selected.roots.len);

    try testing.expectError(
        selection.Error.AmbiguousRoots,
        selection.requireSingleRoot(&store, &selected, "/ws/demo/palette.wgsl", &failure, testing.allocator),
    );
    try expectMessageContains(&failure, "--root");
    try expectMessageContains(&failure, "bgCode");
    try expectMessageContains(&failure, "compositeCode");
}

// X11 — Same input with `--root bgCode`: exactly that root.
test "X11 root narrows a multi-root input to one artifact root" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addCorpus();
    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();

    var selected = try selection.selectProjectWithFailure(
        &store,
        "/ws/demo/palette.wgsl",
        null,
        "bgCode",
        false,
        null,
    );
    defer selected.deinit(testing.allocator);

    try expectRootNames(&store, &selected, &.{"bgCode"});
    const root = try selection.requireSingleRoot(&store, &selected, "/ws/demo/palette.wgsl", null, testing.allocator);
    try testing.expectEqual(selected.roots[0], root);
}

// X12 — `--root` selects a root that does not contain the input.
test "X12 root must contain the input file" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addCorpus();
    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();

    var failure = Failure{};
    defer failure.deinit(testing.allocator);
    try testing.expectError(
        selection.Error.RootDoesNotContainInput,
        selection.selectProjectWithFailure(
            &store,
            "/ws/demo/bg.wgsl",
            null,
            "compositeCode",
            false,
            &failure,
        ),
    );
    try expectMessageContains(&failure, "compositeCode");
    try expectMessageContains(&failure, "/ws/demo/bg.wgsl");
}

// X13 — Stdin without project flags: existing stdin behavior.
test "X13 stdin without selectors is not project mode" {
    try testing.expect(!selection.selectionRequested(.{}));
    var failure = Failure{};
    defer failure.deinit(testing.allocator);
    try selection.validateFlagShape(.{}, true, &failure, testing.allocator);
}

// X14 — Stdin with only one of the two selectors: usage error, exit 2.
test "X14 stdin requires both selectors" {
    var failure = Failure{};
    defer failure.deinit(testing.allocator);

    try testing.expectError(
        selection.Error.StdinRequiresBothSelectors,
        selection.validateFlagShape(.{ .project = "program.sjon" }, true, &failure, testing.allocator),
    );
    try expectMessageContains(&failure, "--root");

    failure.deinit(testing.allocator);
    try testing.expectError(
        selection.Error.StdinRequiresBothSelectors,
        selection.validateFlagShape(.{ .root = "bgCode" }, true, &failure, testing.allocator),
    );
    try expectMessageContains(&failure, "--project");
}

// X15 — Stdin with both selectors replaces only the root's own author text.
test "X15 stdin replaces the selected root's author text only" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addCorpus();
    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();

    var failure = Failure{};
    defer failure.deinit(testing.allocator);
    var selected = try selection.selectProjectWithFailure(
        &store,
        null,
        "/ws/demo/program.sjon",
        "bgCode",
        false,
        &failure,
    );
    defer selected.deinit(testing.allocator);
    try testing.expectEqual(@as(?wgslender.Pngine.Types.PartId, null), selected.input_part);

    try selection.applyStdinOverlay(
        &store,
        &selected,
        "fn stdin_replaced() {}\n",
        &failure,
        testing.allocator,
    );

    const assembled = try store.assembleRoot(selected.roots[0]);
    try testing.expect(std.mem.indexOf(u8, assembled.text, "fn stdin_replaced()") != null);
    try testing.expect(std.mem.indexOf(u8, assembled.text, "bg_main") == null);
    // Imports still come from the project's sources.
    try testing.expect(std.mem.indexOf(u8, assembled.text, "fn palette()") != null);
}

// X16 — Stdin selects a pass root: generated-context refusal, exit 2.
test "X16 stdin cannot replace a pass root" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/pass/program.sjon",
        \\(wgsl :name shared :file "shared.wgsl")
        \\(pass :name renderPass :code "fn generated() {}")
    );
    try fake.addFile("/ws/pass/shared.wgsl", "fn shared() {}");

    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();

    var failure = Failure{};
    defer failure.deinit(testing.allocator);
    var selected = try selection.selectProjectWithFailure(
        &store,
        null,
        "/ws/pass/program.sjon",
        "renderPass",
        false,
        &failure,
    );
    defer selected.deinit(testing.allocator);

    try testing.expectError(
        selection.Error.StdinPassRoot,
        selection.applyStdinOverlay(&store, &selected, "fn nope() {}\n", &failure, testing.allocator),
    );
    try expectMessageContains(&failure, "renderPass");
}

// X17 — Missing explicit project/file, plus the explicit-document ceiling.
test "X17 missing explicit project is a located usage error" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addCorpus();
    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();

    var failure = Failure{};
    defer failure.deinit(testing.allocator);
    try testing.expectError(
        selection.Error.ProjectUnreadable,
        selection.selectProjectWithFailure(
            &store,
            "/ws/demo/bg.wgsl",
            "/ws/missing.sjon",
            null,
            false,
            &failure,
        ),
    );
    try expectMessageContains(&failure, "/ws/missing.sjon");
}

test "X17 explicit project input outside the program is refused" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addCorpus();
    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();

    var failure = Failure{};
    defer failure.deinit(testing.allocator);
    try testing.expectError(
        selection.Error.NoProject,
        selection.selectProjectWithFailure(
            &store,
            "/ws/clock/shaders/scene.wgsl",
            "/ws/demo/program.sjon",
            null,
            false,
            &failure,
        ),
    );
    try expectMessageContains(&failure, "/ws/demo/program.sjon");
}

test "X17 explicit project above the ceiling is a usage error, not an assert" {
    try testing.expectEqual(@as(usize, 1 << 28), selection.default_max_project_bytes);

    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/big/program.sjon", "(wgsl :name a :file \"a.wgsl\")\n");
    try fake.addFile("/ws/big/a.wgsl", "fn a() {}");

    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();

    var failure = Failure{};
    defer failure.deinit(testing.allocator);
    try testing.expectError(
        selection.Error.ProjectTooLarge,
        selection.selectProjectWithOptions(
            &store,
            "/ws/big/a.wgsl",
            "/ws/big/program.sjon",
            null,
            false,
            .{ .max_project_bytes = 8 },
            &failure,
        ),
    );
    try expectMessageContains(&failure, "/ws/big/program.sjon");
    try expectMessageContains(&failure, "maximum");
}
