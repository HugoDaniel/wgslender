//! pngine warm-keystroke performance acceptance (pngine-shaders phase 03,
//! Task 6).
//!
//! Red-first contract: after a warm discovery, two independent programs, and
//! every participating root analyzed once, 200 buffer edits through
//! `Handler` must do *no* project work beyond the edited root:
//!   * zero discovery scans (the discovery generation never moves);
//!   * zero project `SourceProvider` reads — neither WGSL sources nor a
//!     `.sjon` document — on the WGSL edit path;
//!   * zero unrelated-root analyses (the untouched root's analysis identity,
//!     root revision and program revision are unchanged);
//!   * zero `.sjon` re-reads, asserted through the counting provider rather
//!     than by inspection.
//!
//! Counters are printed so a green run says exactly what it observed. They
//! are existing observables (provider reads, candidate enumeration,
//! generations, cache identity); no production instrumentation is added.

const std = @import("std");
const Handler = @import("Handler");
const wgslender = @import("wgslender");
const provider_mod = @import("pngine_test_provider.zig");

const pngine = wgslender.Pngine;
const Types = pngine.Types;
const Store = pngine.Store;
const FakeProvider = provider_mod.FakeProvider;

const testing = std.testing;

const program_a =
    \\(wgsl :name shared :file "shared.wgsl")
    \\(shader-module :name rootA :file "root_a.wgsl" :imports [shared])
;

const program_b =
    \\(wgsl :name lib :file "lib.wgsl")
    \\(shader-module :name rootB :file "root_b.wgsl" :imports [lib])
;

const shared_initial = "const K: f32 = 0.125;";
const root_a_source =
    \\@fragment
    \\fn fs_a() -> @location(0) vec4f {
    \\  return vec4f(K);
    \\}
;
const lib_source = "fn twice(x: f32) -> f32 { return x * 2.0; }";
const root_b_source =
    \\@fragment
    \\fn fs_b() -> @location(0) vec4f {
    \\  return vec4f(twice(2.0));
    \\}
;

fn fileUri(buffer: []u8, path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "file://{s}", .{path});
}

fn rootFor(store: *Store, path: []const u8) !Types.PartId {
    var buffer: [256]u8 = undefined;
    var set = try store.membershipsFor(try fileUri(&buffer, path));
    defer set.deinit(testing.allocator);
    if (set.items.len == 0) return error.TestExpectedMembership;
    const membership = set.items[0];
    if (membership.containing_roots.len == 0) return error.TestExpectedRoot;
    return .{ .program = membership.program, .index = membership.containing_roots[0] };
}

fn sameUri(affected: []const []const u8, uri: []const u8) bool {
    for (affected) |item| {
        if (std.mem.eql(u8, item, uri)) return true;
    }
    return false;
}

test "200 warm WGSL edits do no discovery, provider, or unrelated-root work" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/a/program.sjon", program_a);
    try fake.addFile("/ws/a/shared.wgsl", shared_initial);
    try fake.addFile("/ws/a/root_a.wgsl", root_a_source);
    try fake.addFile("/ws/b/program.sjon", program_b);
    try fake.addFile("/ws/b/lib.wgsl", lib_source);
    try fake.addFile("/ws/b/root_b.wgsl", root_b_source);

    var store = Store.init(testing.allocator, fake.sourceProvider());
    defer store.deinit();
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);

    var handler = Handler.init(testing.allocator);
    defer handler.deinit();
    handler.setPngineStore(&store);

    var shared_buffer: [256]u8 = undefined;
    const shared_uri = try fileUri(&shared_buffer, "/ws/a/shared.wgsl");
    var root_a_buffer: [256]u8 = undefined;
    const root_a_uri = try fileUri(&root_a_buffer, "/ws/a/root_a.wgsl");
    var root_b_buffer: [256]u8 = undefined;
    const root_b_uri = try fileUri(&root_b_buffer, "/ws/b/root_b.wgsl");
    var lib_buffer: [256]u8 = undefined;
    const lib_uri = try fileUri(&lib_buffer, "/ws/b/lib.wgsl");

    // Open every participating document, exactly as an editor would. Each
    // open is a D45 boundary refresh; all warm-up reads happen here.
    try handler.openDocument(shared_uri, shared_initial, 1);
    try handler.openDocument(root_a_uri, root_a_source, 1);
    try handler.openDocument(lib_uri, lib_source, 1);
    try handler.openDocument(root_b_uri, root_b_source, 1);

    const root_a = try rootFor(&store, "/ws/a/root_a.wgsl");
    const root_b = try rootFor(&store, "/ws/b/root_b.wgsl");

    // Warm both analyses and the assemble cache. `b_before` is the identity
    // the edit burst must never replace.
    const a_before = try handler.analyzeRoot(root_a);
    const b_before = try handler.analyzeRoot(root_b);
    const b_root_revision = store.rootRevision(root_b);
    const b_program_revision = store.programRevision(root_b.program);
    const b_assembled = b_before.assembled;

    const reads_before = fake.read_calls;
    const wgsl_reads_before = fake.wgsl_read_calls;
    const sjon_reads_before = fake.sjon_read_calls;
    const candidates_before = fake.candidate_calls;
    const discovery_before = store.discoveryGeneration();
    const content_before = store.contentGeneration();

    var unrelated_root_analyses: usize = 0;
    var root_a_rebuilds: usize = 0;
    var previous_a: *Handler.RootAnalysis = a_before;

    var edit: usize = 0;
    while (edit < 200) : (edit += 1) {
        var text_buffer: [128]u8 = undefined;
        const text = try std.fmt.bufPrint(&text_buffer, "const K: f32 = {d}.125;\n", .{edit});
        try handler.changeDocument(shared_uri, text);

        const affected = try handler.affectedOpenDocuments(shared_uri);
        defer handler.gpa.free(affected);

        // The fanout is the real edit path: the edited part and every open
        // document sharing a root with it. Root B shares nothing.
        try testing.expect(sameUri(affected, shared_uri));
        try testing.expect(sameUri(affected, root_a_uri));
        try testing.expect(!sameUri(affected, root_b_uri));
        try testing.expect(!sameUri(affected, lib_uri));

        for (affected) |uri| {
            if (!std.mem.eql(u8, uri, shared_uri) and !std.mem.eql(u8, uri, root_a_uri)) {
                unrelated_root_analyses += 1;
            }
            const diags = try Handler.Diagnostics.validateDocumentCheap(&handler, uri);
            defer Handler.Diagnostics.freeDiagnostics(handler.gpa, diags);
        }

        const a_now = try handler.analyzeRoot(root_a);
        if (a_now != previous_a) root_a_rebuilds += 1;
        previous_a = a_now;
    }

    const reads_after = fake.read_calls;
    const wgsl_reads_after = fake.wgsl_read_calls;
    const sjon_reads_after = fake.sjon_read_calls;
    const candidates_after = fake.candidate_calls;
    const discovery_after = store.discoveryGeneration();
    const content_after = store.contentGeneration();

    // The untouched root is asked for only after the burst; the cheap key
    // moved (global content generation), so this exercises the Store's
    // "same unit, adopt the key" path rather than a rebuild.
    const b_after = try handler.analyzeRoot(root_b);

    std.debug.print(
        "pngine perf (200 edits): provider reads total {d} (+{d}), wgsl {d} (+{d}), sjon {d} (+{d}), candidates {d} (+{d}) | discovery gen {d}->{d} (+{d}) | content gen {d}->{d} | rootA rebuilds {d} | unrelated-root analyses {d} | rootB analysis identity {s}, root rev {d}->{d}, program rev {d}->{d}\n",
        .{
            reads_after,                        reads_after - reads_before,
            wgsl_reads_after,                   wgsl_reads_after - wgsl_reads_before,
            sjon_reads_after,                   sjon_reads_after - sjon_reads_before,
            candidates_after,                   candidates_after - candidates_before,
            discovery_before,                   discovery_after,
            discovery_after - discovery_before, content_before,
            content_after,                      root_a_rebuilds,
            unrelated_root_analyses,            if (b_after == b_before) "preserved" else "changed",
            b_root_revision,                    store.rootRevision(root_b),
            b_program_revision,                 store.programRevision(root_b.program),
        },
    );

    // The threshold is exact: zero, not "small".
    try testing.expectEqual(candidates_before, candidates_after);
    try testing.expectEqual(discovery_before, discovery_after);
    try testing.expectEqual(wgsl_reads_before, wgsl_reads_after);
    try testing.expectEqual(sjon_reads_before, sjon_reads_after);
    try testing.expectEqual(reads_before, reads_after);
    try testing.expectEqual(@as(usize, 0), unrelated_root_analyses);

    // The edited root really was re-analyzed — otherwise the zeros above
    // would merely mean the burst did nothing.
    try testing.expect(root_a_rebuilds > 0);
    try testing.expect(content_after > content_before);

    // Unrelated root: same analysis object, same borrowed assembly, no
    // revision movement, and no read to re-derive it.
    try testing.expect(b_after == b_before);
    try testing.expect(b_after.result == b_before.result);
    try testing.expect(b_after.assembled == b_assembled);
    try testing.expectEqual(b_root_revision, store.rootRevision(root_b));
    try testing.expectEqual(b_program_revision, store.programRevision(root_b.program));
    try testing.expectEqual(reads_before, fake.read_calls);
    try testing.expectEqual(sjon_reads_before, fake.sjon_read_calls);
}
