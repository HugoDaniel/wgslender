//! Per-root composed analysis (pngine-shaders phase 03, Task 1).
//!
//! The red-first contract:
//!   * sibling fragments resolve because the validator sees assembled text;
//!   * an unsaved open buffer is the analysis input, not disk;
//!   * a content change in one root leaves an unrelated root's cached
//!     analysis identity untouched;
//!   * a changed content key is never answered from a stale cache;
//!   * a repeated estimate request performs no estimation and no provider
//!     reads.
//!
//! Every test drives `Handler` and the in-memory `SourceProvider` from
//! `pngine_test_provider.zig`; no test reads project text from the host
//! filesystem.

const std = @import("std");
const Handler = @import("Handler");
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

fn rootFor(store: *Store, path: []const u8) !Types.PartId {
    var buffer: [512]u8 = undefined;
    var set = try store.membershipsFor(try fileUri(&buffer, path));
    defer set.deinit(testing.allocator);
    if (set.items.len == 0) return error.TestExpectedMembership;
    const membership = set.items[0];
    if (membership.containing_roots.len == 0) return error.TestExpectedRoot;
    return .{
        .program = membership.program,
        .index = membership.containing_roots[0],
    };
}

fn hasCode(result: *const wgslender.Validator.AnalysisResult, code: []const u8) bool {
    for (result.diagnostics.diagnostics.items) |entry| {
        if (std.mem.eql(u8, entry.code, code)) return true;
    }
    return false;
}

/// The validator reports a name that does not resolve as E0100 (unknown
/// identifier), E0200 (unknown type), or E0204 (not callable) depending on
/// where the name appears. A composed-analysis test cares about the family,
/// not the chosen code.
fn hasUnresolved(result: *const wgslender.Validator.AnalysisResult) bool {
    return hasCode(result, "E0100") or hasCode(result, "E0200") or hasCode(result, "E0204");
}

fn dump(result: *const wgslender.Validator.AnalysisResult) void {
    for (result.diagnostics.diagnostics.items) |entry| {
        std.debug.print("  {s}: {s}\n", .{ entry.code, entry.message });
    }
}

fn expectNoUnresolved(result: *const wgslender.Validator.AnalysisResult) !void {
    if (hasUnresolved(result)) {
        std.debug.print("unexpected unresolved name in assembled analysis:\n", .{});
        dump(result);
        return error.UnexpectedDiagnostic;
    }
}

fn expectUnresolved(result: *const wgslender.Validator.AnalysisResult) !void {
    if (!hasUnresolved(result)) {
        std.debug.print("missing unresolved-name diagnostic; got:\n", .{});
        dump(result);
        return error.MissingDiagnostic;
    }
}

fn bindStore(
    fake: *FakeProvider,
    store: *Store,
    handler: *Handler,
) !void {
    store.* = Store.init(testing.allocator, fake.sourceProvider());
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);
    handler.* = Handler.init(testing.allocator);
    handler.setPngineStore(store);
}

// =========================================================================
// T1 — sibling fragment declarations resolve in the assembled unit.
// =========================================================================

const sibling_program =
    \\(wgsl :name lib :file "lib.wgsl")
    \\(wgsl :name use :file "use.wgsl" :imports [lib])
    \\(shader-module :name main :file "root.wgsl" :imports [use])
;

const sibling_lib =
    \\struct Light {
    \\  dir: vec3<f32>,
    \\}
    \\
    \\fn shade(light: Light) -> f32 {
    \\  return light.dir.x;
    \\}
;

const sibling_use =
    \\fn lit() -> f32 {
    \\  var light: Light;
    \\  return shade(light);
    \\}
;

const sibling_root =
    \\@fragment
    \\fn fs_main() -> @location(0) vec4<f32> {
    \\  return vec4<f32>(lit());
    \\}
;

fn addSiblingProgram(fake: *FakeProvider) !void {
    try fake.addFile("/ws/program.sjon", sibling_program);
    try fake.addFile("/ws/lib.wgsl", sibling_lib);
    try fake.addFile("/ws/use.wgsl", sibling_use);
    try fake.addFile("/ws/root.wgsl", sibling_root);
}

test "T1 sibling structs and functions resolve on the assembled unit" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addSiblingProgram(&fake);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    const root = try rootFor(&store, "/ws/root.wgsl");
    const analysis = try handler.analyzeRoot(root);

    // Both names cross the fragment boundary; neither is declared in this
    // module's source-order line table unless assembly put them there.
    try expectNoUnresolved(analysis.result);
    try testing.expect(std.mem.indexOf(u8, analysis.assembled.text, "struct Light") != null);
    try testing.expect(std.mem.indexOf(u8, analysis.assembled.text, "fn shade") != null);

    // Teeth: the same `use.wgsl` analyzed alone really does report the
    // unresolved sibling symbols, so T1 is about assembly, not a validator
    // that silently accepts unknown names.
    const use_z = try testing.allocator.dupeZ(u8, sibling_use);
    defer testing.allocator.free(use_z);
    var standalone = try wgslender.analyzeWithOptions(testing.allocator, use_z, .{});
    defer standalone.deinit();
    try expectUnresolved(&standalone);
}

// =========================================================================
// T2 — unsaved edits are authoritative; no save is involved.
// =========================================================================

const unsaved_program =
    \\(wgsl :name lib :file "lib.wgsl")
    \\(wgsl :name use :file "use.wgsl")
    \\(shader-module :name main :file "root.wgsl" :imports [lib use])
;

const unsaved_disk_lib = "fn shade() -> f32 { return 1.0; }";
const unsaved_disk_use = "fn lit() -> f32 { return shade(); }";
const unsaved_root =
    \\@fragment
    \\fn fs_main() -> @location(0) vec4<f32> {
    \\  return vec4<f32>(lit());
    \\}
;

fn addUnsavedProgram(fake: *FakeProvider) !void {
    try fake.addFile("/ws/program.sjon", unsaved_program);
    try fake.addFile("/ws/lib.wgsl", unsaved_disk_lib);
    try fake.addFile("/ws/use.wgsl", unsaved_disk_use);
    try fake.addFile("/ws/root.wgsl", unsaved_root);
}

test "T2 an unsaved buffer changes the assembled analysis without a save" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addUnsavedProgram(&fake);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var uri_buffer: [256]u8 = undefined;
    const root_uri = try fileUri(&uri_buffer, "/ws/root.wgsl");
    var lib_buffer: [256]u8 = undefined;
    const lib_uri = try fileUri(&lib_buffer, "/ws/lib.wgsl");
    var use_buffer: [256]u8 = undefined;
    const use_uri = try fileUri(&use_buffer, "/ws/use.wgsl");

    try handler.openDocument(root_uri, unsaved_root, 1);
    try handler.openDocument(lib_uri, unsaved_disk_lib, 1);
    try handler.openDocument(use_uri, unsaved_disk_use, 1);

    const root = try rootFor(&store, "/ws/root.wgsl");
    const before = try handler.analyzeRoot(root);
    try expectNoUnresolved(before.result);

    // Rename the sibling declaration in an open buffer. Disk still says
    // `shade`; the analysis must now say the old name is gone.
    try handler.changeDocument(lib_uri, "fn glow() -> f32 { return 2.0; }");
    const renamed = try handler.analyzeRoot(root);
    try expectUnresolved(renamed.result);
    try testing.expect(renamed != before);

    // Use the new name from the still-unsaved `use` buffer. No save, no
    // disk write: the current buffer is the input.
    try handler.changeDocument(use_uri, "fn lit() -> f32 { return glow(); }");
    const after = try handler.analyzeRoot(root);
    try expectNoUnresolved(after.result);

    // The provider's disk text never changed.
    try testing.expectEqualStrings(unsaved_disk_lib, fake.files.get("/ws/lib.wgsl").?);
    try testing.expectEqualStrings(unsaved_disk_use, fake.files.get("/ws/use.wgsl").?);
}

// =========================================================================
// T3 — editing one root leaves an unrelated root's analysis untouched.
// =========================================================================

const independent_program =
    \\(wgsl :name alpha :file "a.wgsl")
    \\(wgsl :name gamma :file "c.wgsl")
    \\(shader-module :name rootA :file "root_a.wgsl" :imports [alpha])
    \\(shader-module :name rootB :file "root_b.wgsl" :imports [gamma])
;

fn addIndependentProgram(fake: *FakeProvider) !void {
    try fake.addFile("/ws/program.sjon", independent_program);
    try fake.addFile("/ws/a.wgsl", "fn alpha_disk() -> f32 { return 1.0; }");
    try fake.addFile("/ws/c.wgsl", "fn gamma_disk() -> f32 { return 2.0; }");
    try fake.addFile("/ws/root_a.wgsl", "fn root_a() -> f32 { return alpha_disk(); }");
    try fake.addFile("/ws/root_b.wgsl", "fn root_b() -> f32 { return gamma_disk(); }");
}

test "T3 editing one root preserves an unrelated root's cached analysis identity" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addIndependentProgram(&fake);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var uri_buffer: [256]u8 = undefined;
    const root_a_uri = try fileUri(&uri_buffer, "/ws/root_a.wgsl");

    try handler.openDocument(root_a_uri, "fn root_a() -> f32 { return alpha_disk(); }", 1);
    try handler.openDocument("file:///ws/root_b.wgsl", "fn root_b() -> f32 { return gamma_disk(); }", 1);

    const root_a = try rootFor(&store, "/ws/root_a.wgsl");
    const root_b = try rootFor(&store, "/ws/root_b.wgsl");

    const a_before = try handler.analyzeRoot(root_a);
    const b_before = try handler.analyzeRoot(root_b);
    const b_revision = store.rootRevision(root_b);

    try handler.changeDocument(root_a_uri, "fn root_a_open() -> f32 { return 3.0; }");

    const a_after = try handler.analyzeRoot(root_a);
    const b_after = try handler.analyzeRoot(root_b);

    try testing.expect(a_after != a_before);
    try testing.expect(a_after.result != a_before.result);
    try testing.expect(std.mem.indexOf(u8, a_after.assembled.text, "root_a_open") != null);

    // Identity, not just equality: the unrelated entry and its validator
    // result must be the same objects, and its per-root revision must not
    // have moved.
    try testing.expect(b_after == b_before);
    try testing.expect(b_after.result == b_before.result);
    try testing.expect(b_after.assembled == b_before.assembled);
    try testing.expectEqual(b_before.input_generation, b_after.input_generation);
    try testing.expectEqual(b_revision, store.rootRevision(root_b));
}

// =========================================================================
// T4 — a changed shared content key is never answered from the old cache.
// =========================================================================

const shared_content_program =
    \\(wgsl :name shared :file "shared.wgsl")
    \\(shader-module :name rootA :file "root_a.wgsl" :imports [shared])
    \\(shader-module :name rootB :file "root_b.wgsl" :imports [shared])
;

const shared_disk = "fn shade() -> f32 { return 1.0; }";
const shared_root_a = "fn root_a() -> f32 { return shade(); }";
const shared_root_b = "fn root_b() -> f32 { return shade(); }";

fn addSharedContentProgram(fake: *FakeProvider) !void {
    try fake.addFile("/ws/program.sjon", shared_content_program);
    try fake.addFile("/ws/shared.wgsl", shared_disk);
    try fake.addFile("/ws/root_a.wgsl", shared_root_a);
    try fake.addFile("/ws/root_b.wgsl", shared_root_b);
}

test "T4 a stale cached analysis is never served after its content key changes" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addSharedContentProgram(&fake);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var uri_buffer: [256]u8 = undefined;
    const shared_uri = try fileUri(&uri_buffer, "/ws/shared.wgsl");
    try handler.openDocument(shared_uri, shared_disk, 1);
    try handler.openDocument("file:///ws/root_a.wgsl", shared_root_a, 1);
    try handler.openDocument("file:///ws/root_b.wgsl", shared_root_b, 1);

    const root_a = try rootFor(&store, "/ws/root_a.wgsl");
    const root_b = try rootFor(&store, "/ws/root_b.wgsl");

    const a_before = try handler.analyzeRoot(root_a);
    const b_before = try handler.analyzeRoot(root_b);
    try expectNoUnresolved(a_before.result);
    try expectNoUnresolved(b_before.result);

    try handler.changeDocument(shared_uri, "fn glow() -> f32 { return 2.0; }");

    const a_after = try handler.analyzeRoot(root_a);
    const b_after = try handler.analyzeRoot(root_b);

    try testing.expect(a_after != a_before);
    try testing.expect(b_after != b_before);
    try testing.expect(a_after.assembled != a_before.assembled);
    try testing.expect(b_after.assembled != b_before.assembled);
    try expectUnresolved(a_after.result);
    try expectUnresolved(b_after.result);
    try testing.expect(std.mem.indexOf(u8, a_after.assembled.text, "fn glow") != null);
    try testing.expect(std.mem.indexOf(u8, b_after.assembled.text, "fn glow") != null);
    try testing.expect(std.mem.indexOf(u8, a_after.assembled.text, "fn shade") == null);
    try testing.expect(std.mem.indexOf(u8, b_after.assembled.text, "fn shade") == null);
}

// =========================================================================
// T5 — the per-root estimate slot coalesces repeat requests.
// =========================================================================

test "T5 a repeated root estimate performs no estimation and no provider reads" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addIndependentProgram(&fake);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    const root = try rootFor(&store, "/ws/root_a.wgsl");
    _ = try handler.analyzeRoot(root);

    const reads_before = fake.read_calls;
    const estimates_before = wgslender.MinifyEstimator.estimate_count;

    const first = try handler.getRootMinifyEstimate(root, .{});
    const estimates_after_first = wgslender.MinifyEstimator.estimate_count;
    try testing.expect(estimates_after_first > estimates_before);

    const reads_between = fake.read_calls;
    const second = try handler.getRootMinifyEstimate(root, .{});
    _ = try handler.analyzeRoot(root);

    try testing.expect(second == first);
    try testing.expectEqual(estimates_after_first, wgslender.MinifyEstimator.estimate_count);
    try testing.expectEqual(reads_between, fake.read_calls);
    try testing.expectEqual(reads_before, reads_between);
}

// =========================================================================
// T6 — a failed rebuild leaves no half-updated entry.
// =========================================================================

fn oomRebuildAttempt(fail_index: usize, saw_failure: *bool) !void {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addIndependentProgram(&fake);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var uri_buffer: [256]u8 = undefined;
    const root_uri = try fileUri(&uri_buffer, "/ws/root_a.wgsl");
    try handler.openDocument(root_uri, "fn root_a() -> f32 { return alpha_disk(); }", 1);

    const root = try rootFor(&store, "/ws/root_a.wgsl");
    const first = try handler.analyzeRoot(root);
    try expectNoUnresolved(first.result);

    // Make the Store's unit different, then fail the analysis half. The
    // Store has already released the old unit by the time the allocator
    // fails, so the old analysis must not survive as a cache hit.
    try handler.changeDocument(root_uri, "fn root_a_new() -> f32 { return 9.0; }");

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
    const real_gpa = handler.gpa;
    handler.gpa = failing.allocator();
    const attempt = handler.analyzeRoot(root);
    handler.gpa = real_gpa;

    if (attempt) |rebuilt| {
        // Past the failure window: the rebuild itself must be correct.
        try testing.expect(std.mem.indexOf(u8, rebuilt.assembled.text, "root_a_new") != null);
        try expectNoUnresolved(rebuilt.result);
    } else |_| {
        saw_failure.* = true;
    }

    // Whatever happened above, a retry with a working allocator must
    // serve the new unit, never the pre-edit analysis.
    const recovered = try handler.analyzeRoot(root);
    try testing.expect(std.mem.indexOf(u8, recovered.assembled.text, "root_a_new") != null);
    try expectNoUnresolved(recovered.result);
}

test "T6 an OOM rebuild never leaves a stale analysis behind" {
    var saw_failure = false;
    var fail_index: usize = 0;
    while (fail_index < 32) : (fail_index += 1) {
        try oomRebuildAttempt(fail_index, &saw_failure);
    }
    try testing.expect(saw_failure);
}
