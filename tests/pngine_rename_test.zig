//! References, document highlights, and safe multi-file rename across
//! pngine file parts (pngine-shaders phase 04, Task 3).
//!
//! The red-first contract:
//!   * a declaration shared by several parts reports every use once, each
//!     with its own author URI and author-local range;
//!   * when two roots resolve the same author position to different
//!     declaration identities, references report both identities and
//!     rename/prepareRename decline instead of merging them;
//!   * `includeDeclaration` behaves on the composed path exactly as the
//!     standalone path does;
//!   * a use inside an inline `:code` part is a reference with no file URI
//!     (the virtual-document layer arrives later) and rename/prepareRename
//!     refuse because the edit set would write that virtual text;
//!   * a use reachable through two roots appears once per `(URI, range)`;
//!   * rename produces a multi-file `WorkspaceEdit` grouped by URI, and an
//!     open unsaved sibling is measured from its current buffer text;
//!   * `new_name` is validated as WGSL, and a name that would collide with a
//!     declaration in any affected root refuses the whole rename;
//!   * document highlight keeps only the requested document's references and
//!     preserves read/write kinds.
//!
//! Every project test drives `Handler` and the in-memory `SourceProvider`
//! from `pngine_test_provider.zig`; no test reads project text from the host
//! filesystem.

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");
const lspkit = @import("lspkit");
const native_navigation = @import("native_navigation");
const native_symbols = @import("native_symbols");
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

/// 0-based LSP position of `needle` + `delta` bytes in `source`.
fn positionOf(source: []const u8, needle: []const u8, delta: u32) Handler.Position {
    const start = std.mem.indexOf(u8, source, needle) orelse unreachable;
    return Handler.offsetToLspPosition(source, @intCast(start + delta)) orelse unreachable;
}

fn offsetOf(source: []const u8, needle: []const u8, delta: u32) u32 {
    const start = std.mem.indexOf(u8, source, needle) orelse unreachable;
    return @intCast(start + delta);
}

fn rangeIn(source: []const u8, needle: []const u8, delta: u32, len: u32) Handler.Range {
    const start = offsetOf(source, needle, delta);
    return Handler.offsetRangeToLspRange(source, start, start + len) orelse unreachable;
}

/// The range of the `nth` (0-based) occurrence of `needle`.
fn nthRange(source: []const u8, needle: []const u8, nth: usize) Handler.Range {
    var from: usize = 0;
    var seen: usize = 0;
    while (std.mem.indexOfPos(u8, source, from, needle)) |at| {
        if (seen == nth) {
            return Handler.offsetRangeToLspRange(
                source,
                @intCast(at),
                @intCast(at + needle.len),
            ) orelse unreachable;
        }
        seen += 1;
        from = at + needle.len;
    }
    unreachable;
}

fn bindStore(fake: *FakeProvider, store: *Store, handler: *Handler) !void {
    store.* = Store.init(testing.allocator, fake.sourceProvider());
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);
    handler.* = Handler.init(testing.allocator);
    handler.setPngineStore(store);
}

fn uriEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn expectReference(
    refs: []const Handler.ReferenceLocation,
    uri: ?[]const u8,
    range: Handler.Range,
) !void {
    for (refs) |ref| {
        if (!uriEql(ref.uri, uri)) continue;
        if (!std.meta.eql(ref.range, range)) continue;
        return;
    }
    return error.MissingReference;
}

fn expectNoReference(
    refs: []const Handler.ReferenceLocation,
    uri: ?[]const u8,
    range: Handler.Range,
) !void {
    for (refs) |ref| {
        if (!uriEql(ref.uri, uri)) continue;
        if (!std.meta.eql(ref.range, range)) continue;
        return error.UnexpectedReference;
    }
}

fn documentFor(changes: Handler.WorkspaceChanges, uri: []const u8) ?Handler.DocumentEdits {
    for (changes.documents) |document| {
        if (std.mem.eql(u8, document.uri, uri)) return document;
    }
    return null;
}

// =========================================================================
// Shared fixture: one library declaration used by three fragments and both
// roots. `root_b` imports only `f1`, so `f1` and the library declaration are
// reachable through two roots while `f2`/`f3` are reachable only through
// `root_a`.
// =========================================================================

const shared_program =
    \\(wgsl :name lib :file "lib.wgsl")
    \\(wgsl :name f1 :file "f1.wgsl" :imports [lib])
    \\(wgsl :name f2 :file "f2.wgsl" :imports [lib])
    \\(wgsl :name f3 :file "f3.wgsl" :imports [lib])
    \\(shader-module :name root_a :file "root_a.wgsl" :imports [f1 f2 f3 lib])
    \\(shader-module :name root_b :file "root_b.wgsl" :imports [f1 lib])
;

const shared_lib = "fn shared_value() -> f32 { return 1.0; }";
const shared_f1 = "fn use_one() -> f32 { return shared_value(); }";
const shared_f2 = "fn use_two() -> f32 { return shared_value(); }";
const shared_f3 = "fn use_three() -> f32 { return shared_value(); }";
const shared_root_a =
    "@fragment fn fs_a() -> @location(0) vec4<f32> { return vec4<f32>(use_one() + use_two() + use_three() + shared_value()); }";
const shared_root_b =
    "@fragment fn fs_b() -> @location(0) vec4<f32> { return vec4<f32>(use_one() + shared_value()); }";

fn addSharedFixture(fake: *FakeProvider) !void {
    try fake.addFile("/ws/program.sjon", shared_program);
    try fake.addFile("/ws/lib.wgsl", shared_lib);
    try fake.addFile("/ws/f1.wgsl", shared_f1);
    try fake.addFile("/ws/f2.wgsl", shared_f2);
    try fake.addFile("/ws/f3.wgsl", shared_f3);
    try fake.addFile("/ws/root_a.wgsl", shared_root_a);
    try fake.addFile("/ws/root_b.wgsl", shared_root_b);
}

// =========================================================================
// T3-1 — shared declaration across three fragments and the root.
// =========================================================================

test "T3-1 references return every shared use with its own URI and range" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addSharedFixture(&fake);
    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var lib_buffer: [256]u8 = undefined;
    const lib_uri = try fileUri(&lib_buffer, "/ws/lib.wgsl");
    var f1_buffer: [256]u8 = undefined;
    const f1_uri = try fileUri(&f1_buffer, "/ws/f1.wgsl");
    var f2_buffer: [256]u8 = undefined;
    const f2_uri = try fileUri(&f2_buffer, "/ws/f2.wgsl");
    var f3_buffer: [256]u8 = undefined;
    const f3_uri = try fileUri(&f3_buffer, "/ws/f3.wgsl");
    var root_a_buffer: [256]u8 = undefined;
    const root_a_uri = try fileUri(&root_a_buffer, "/ws/root_a.wgsl");
    var root_b_buffer: [256]u8 = undefined;
    const root_b_uri = try fileUri(&root_b_buffer, "/ws/root_b.wgsl");

    const position = positionOf(shared_lib, "shared_value", 2);
    const refs = (try handler.computeReferences(lib_uri, position, true)) orelse
        return error.MissingReferences;
    defer Handler.freeReferences(&handler, refs);

    // Declaration + f1 + f2 + f3 + root_a + root_b. The library declaration
    // and the f1 use are reached through both roots but appear once.
    try testing.expectEqual(@as(usize, 6), refs.len);
    try expectReference(refs, lib_uri, rangeIn(shared_lib, "shared_value", 0, 12));
    try expectReference(refs, f1_uri, rangeIn(shared_f1, "shared_value", 0, 12));
    try expectReference(refs, f2_uri, rangeIn(shared_f2, "shared_value", 0, 12));
    try expectReference(refs, f3_uri, rangeIn(shared_f3, "shared_value", 0, 12));
    try expectReference(refs, root_a_uri, rangeIn(shared_root_a, "shared_value", 0, 12));
    try expectReference(refs, root_b_uri, rangeIn(shared_root_b, "shared_value", 0, 12));

    // A composed reference is always a real file location or an explicit
    // inline origin; this fixture has no inline parts.
    for (refs) |ref| try testing.expect(ref.uri != null);

    // The native adapter carries each reference's own URI, not the request
    // document's URI for every entry.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const locations = native_navigation.handleReferences(&handler, arena.allocator(), .{
        .textDocument = .{ .uri = lib_uri },
        .position = lspkit.primitives.toLspKitPosition(position),
        .context = .{ .includeDeclaration = true },
    }) orelse return error.MissingNativeReferences;
    try testing.expectEqual(@as(usize, 6), locations.len);
    for (locations) |location| try testing.expect(location.uri.len > 0);
}

// =========================================================================
// T3-2 — divergent root bindings.
// =========================================================================

const divergent_program =
    \\(wgsl :name sup_a :file "sup_a.wgsl")
    \\(wgsl :name sup_b :file "sup_b.wgsl")
    \\(wgsl :name frag :file "frag.wgsl" :requires [Hole])
    \\(shader-module :name root_a :file "root_a.wgsl" :imports [sup_a frag])
    \\(shader-module :name root_b :file "root_b.wgsl" :imports [sup_b frag])
;

const divergent_sup_a = "struct Hole {\n  a: f32,\n}";
const divergent_sup_b = "struct Hole {\n  a: f32,\n  b: f32,\n}";
const divergent_frag =
    \\fn sample() -> f32 {
    \\  var h: Hole;
    \\  return h.a;
    \\}
;
const divergent_root_a =
    "@fragment fn fs_a() -> @location(0) vec4<f32> { return vec4<f32>(sample()); }";
const divergent_root_b =
    "@fragment fn fs_b() -> @location(0) vec4<f32> { return vec4<f32>(sample()); }";

test "T3-2 divergent root bindings report both identities and refuse rename" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", divergent_program);
    try fake.addFile("/ws/sup_a.wgsl", divergent_sup_a);
    try fake.addFile("/ws/sup_b.wgsl", divergent_sup_b);
    try fake.addFile("/ws/frag.wgsl", divergent_frag);
    try fake.addFile("/ws/root_a.wgsl", divergent_root_a);
    try fake.addFile("/ws/root_b.wgsl", divergent_root_b);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var frag_buffer: [256]u8 = undefined;
    const frag_uri = try fileUri(&frag_buffer, "/ws/frag.wgsl");
    var sup_a_buffer: [256]u8 = undefined;
    const sup_a_uri = try fileUri(&sup_a_buffer, "/ws/sup_a.wgsl");
    var sup_b_buffer: [256]u8 = undefined;
    const sup_b_uri = try fileUri(&sup_b_buffer, "/ws/sup_b.wgsl");

    const position = positionOf(divergent_frag, "Hole", 1);
    const refs = (try handler.computeReferences(frag_uri, position, true)) orelse
        return error.MissingReferences;
    defer Handler.freeReferences(&handler, refs);

    // Each root resolves `Hole` to its own declaration. References report
    // both identities rather than silently choosing the first root.
    try testing.expectEqual(@as(usize, 3), refs.len);
    try expectReference(refs, sup_a_uri, rangeIn(divergent_sup_a, "Hole", 0, 4));
    try expectReference(refs, sup_b_uri, rangeIn(divergent_sup_b, "Hole", 0, 4));
    try expectReference(refs, frag_uri, rangeIn(divergent_frag, "Hole", 0, 4));

    // Editing either declaration's identity would merge unrelated symbols.
    try testing.expect((try handler.computeRename(frag_uri, position, "Shape")) == null);
    try testing.expect((try handler.prepareRename(frag_uri, position)) == null);
}

// =========================================================================
// T3-3 — includeDeclaration on the composed path.
// =========================================================================

test "T3-3 includeDeclaration is honoured on the composed path" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addSharedFixture(&fake);
    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var lib_buffer: [256]u8 = undefined;
    const lib_uri = try fileUri(&lib_buffer, "/ws/lib.wgsl");
    const position = positionOf(shared_lib, "shared_value", 2);
    const declaration_range = rangeIn(shared_lib, "shared_value", 0, 12);

    const with_declaration = (try handler.computeReferences(lib_uri, position, true)) orelse
        return error.MissingReferences;
    defer Handler.freeReferences(&handler, with_declaration);
    const without_declaration = (try handler.computeReferences(lib_uri, position, false)) orelse
        return error.MissingReferences;
    defer Handler.freeReferences(&handler, without_declaration);

    try testing.expectEqual(with_declaration.len, without_declaration.len + 1);
    try expectReference(with_declaration, lib_uri, declaration_range);
    try expectNoReference(without_declaration, lib_uri, declaration_range);
}

// =========================================================================
// T3-4 — inline references and the virtual-text edit boundary.
// =========================================================================

const inline_program =
    \\(wgsl :name lib :file "lib.wgsl")
    \\(wgsl :name inlinepart :code "fn inline_use() -> f32 { return shared_value(); }")
    \\(wgsl :name use :file "use.wgsl" :imports [lib inlinepart])
    \\(shader-module :name root :file "root.wgsl" :imports [use])
;

const inline_lib = "fn shared_value() -> f32 { return 1.0; }";
const inline_code = "fn inline_use() -> f32 { return shared_value(); }";
const inline_use = "fn file_use() -> f32 { return shared_value(); }";
const inline_root =
    "@fragment fn fs_main() -> @location(0) vec4<f32> { return vec4<f32>(file_use()); }";

test "T3-4 inline references have no file URI and refuse rename" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", inline_program);
    try fake.addFile("/ws/lib.wgsl", inline_lib);
    try fake.addFile("/ws/use.wgsl", inline_use);
    try fake.addFile("/ws/root.wgsl", inline_root);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var lib_buffer: [256]u8 = undefined;
    const lib_uri = try fileUri(&lib_buffer, "/ws/lib.wgsl");
    var use_buffer: [256]u8 = undefined;
    const use_uri = try fileUri(&use_buffer, "/ws/use.wgsl");

    const position = positionOf(inline_lib, "shared_value", 2);
    const refs = (try handler.computeReferences(lib_uri, position, true)) orelse
        return error.MissingReferences;
    defer Handler.freeReferences(&handler, refs);

    // Library declaration + file use + inline use.
    try testing.expectEqual(@as(usize, 3), refs.len);
    try expectReference(refs, lib_uri, rangeIn(inline_lib, "shared_value", 0, 12));
    try expectReference(refs, use_uri, rangeIn(inline_use, "shared_value", 0, 12));
    try expectReference(refs, null, rangeIn(inline_code, "shared_value", 0, 12));

    // An edit set that includes the inline use would have to write a virtual
    // document; both prepare and rename refuse the whole rename.
    try testing.expect((try handler.prepareRename(lib_uri, position)) == null);
    try testing.expect((try handler.computeRename(lib_uri, position, "renamed_value")) == null);

    // The adapter omits the inline entry rather than inventing a URI.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const locations = native_navigation.handleReferences(&handler, arena.allocator(), .{
        .textDocument = .{ .uri = lib_uri },
        .position = lspkit.primitives.toLspKitPosition(position),
        .context = .{ .includeDeclaration = true },
    }) orelse return error.MissingNativeReferences;
    try testing.expectEqual(@as(usize, 2), locations.len);
}

// =========================================================================
// T3-5 — dedupe by (URI, range) across roots.
// =========================================================================

test "T3-5 a use reached through two roots appears once" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addSharedFixture(&fake);
    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var lib_buffer: [256]u8 = undefined;
    const lib_uri = try fileUri(&lib_buffer, "/ws/lib.wgsl");
    var f1_buffer: [256]u8 = undefined;
    const f1_uri = try fileUri(&f1_buffer, "/ws/f1.wgsl");

    const position = positionOf(shared_lib, "shared_value", 2);
    const refs = (try handler.computeReferences(lib_uri, position, true)) orelse
        return error.MissingReferences;
    defer Handler.freeReferences(&handler, refs);

    // `f1` is imported by both roots; its use must still be one entry.
    var f1_uses: usize = 0;
    for (refs) |ref| {
        const uri = ref.uri orelse continue;
        if (!std.mem.eql(u8, uri, f1_uri)) continue;
        if (!std.meta.eql(ref.range, rangeIn(shared_f1, "shared_value", 0, 12))) continue;
        f1_uses += 1;
    }
    try testing.expectEqual(@as(usize, 1), f1_uses);

    // No `(URI, range)` pair appears twice in the whole result.
    for (refs, 0..) |ref, i| {
        for (refs[0..i]) |earlier| {
            if (!uriEql(ref.uri, earlier.uri)) continue;
            if (!std.meta.eql(ref.range, earlier.range)) continue;
            return error.DuplicateReference;
        }
    }
}

// =========================================================================
// T3-6 — multi-file edits over current (buffer) ranges.
// =========================================================================

test "T3-6 rename groups edits by URI and uses unsaved sibling ranges" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addSharedFixture(&fake);
    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var lib_buffer: [256]u8 = undefined;
    const lib_uri = try fileUri(&lib_buffer, "/ws/lib.wgsl");
    var f1_buffer: [256]u8 = undefined;
    const f1_uri = try fileUri(&f1_buffer, "/ws/f1.wgsl");
    var f2_buffer: [256]u8 = undefined;
    const f2_uri = try fileUri(&f2_buffer, "/ws/f2.wgsl");
    var f3_buffer: [256]u8 = undefined;
    const f3_uri = try fileUri(&f3_buffer, "/ws/f3.wgsl");
    var root_a_buffer: [256]u8 = undefined;
    const root_a_uri = try fileUri(&root_a_buffer, "/ws/root_a.wgsl");
    var root_b_buffer: [256]u8 = undefined;
    const root_b_uri = try fileUri(&root_b_buffer, "/ws/root_b.wgsl");

    // The unsaved sibling moves its use one line down; the edit must target
    // the buffer range, not the provider's disk range.
    const modified_f2 = "// unsaved sibling\n" ++ shared_f2;
    try handler.openDocument(f2_uri, modified_f2, 2);

    const position = positionOf(shared_lib, "shared_value", 2);
    const changes = (try handler.computeRename(lib_uri, position, "renamed_value")) orelse
        return error.MissingRename;
    defer Handler.freeWorkspaceChanges(&handler, changes);

    try testing.expectEqual(@as(usize, 6), changes.documents.len);
    const documents = [_]struct { uri: []const u8, range: Handler.Range }{
        .{ .uri = lib_uri, .range = rangeIn(shared_lib, "shared_value", 0, 12) },
        .{ .uri = f1_uri, .range = rangeIn(shared_f1, "shared_value", 0, 12) },
        .{ .uri = f2_uri, .range = rangeIn(modified_f2, "shared_value", 0, 12) },
        .{ .uri = f3_uri, .range = rangeIn(shared_f3, "shared_value", 0, 12) },
        .{ .uri = root_a_uri, .range = rangeIn(shared_root_a, "shared_value", 0, 12) },
        .{ .uri = root_b_uri, .range = rangeIn(shared_root_b, "shared_value", 0, 12) },
    };
    for (documents) |expected| {
        const document = documentFor(changes, expected.uri) orelse return error.MissingDocument;
        try testing.expectEqual(@as(usize, 1), document.edits.len);
        try testing.expectEqualStrings("renamed_value", document.edits[0].new_text);
        try testing.expectEqualDeep(expected.range, document.edits[0].range);
    }
    const f2_document = documentFor(changes, f2_uri) orelse return error.MissingDocument;
    try testing.expect(!std.meta.eql(
        f2_document.edits[0].range,
        rangeIn(shared_f2, "shared_value", 0, 12),
    ));

    // prepareRename answers in the request document's own coordinates.
    const prepared = (try handler.prepareRename(lib_uri, position)) orelse
        return error.MissingPrepareRename;
    try testing.expectEqualDeep(rangeIn(shared_lib, "shared_value", 0, 12), prepared);
    const prepared_f1 = (try handler.prepareRename(
        f1_uri,
        positionOf(shared_f1, "shared_value", 2),
    )) orelse return error.MissingPrepareRename;
    try testing.expectEqualDeep(rangeIn(shared_f1, "shared_value", 0, 12), prepared_f1);

    // A request on a use reaches the same declaration identity and the same
    // multi-file edit set.
    const from_use = (try handler.computeRename(
        f1_uri,
        positionOf(shared_f1, "shared_value", 2),
        "renamed_value",
    )) orelse return error.MissingRenameFromUse;
    defer Handler.freeWorkspaceChanges(&handler, from_use);
    try testing.expectEqual(@as(usize, 6), from_use.documents.len);

    // The native adapter produces one changes key per destination URI and
    // still targets the unsaved buffer range.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const rename = native_symbols.handleRename(&handler, aa, .{
        .textDocument = .{ .uri = lib_uri },
        .position = lspkit.primitives.toLspKitPosition(position),
        .newName = "renamed_value",
    }) orelse return error.MissingNativeRename;
    const changes_map = rename.changes orelse return error.MissingChanges;
    try testing.expectEqual(@as(usize, 6), changes_map.map.count());
    const f2_edits = changes_map.map.get(f2_uri) orelse return error.MissingRenameDocument;
    try testing.expectEqual(@as(usize, 1), f2_edits.len);
    try testing.expectEqualDeep(
        rangeIn(modified_f2, "shared_value", 0, 12),
        lspkit.primitives.fromLspKitRange(f2_edits[0].range),
    );
}

// =========================================================================
// T3-7 — identifier validation and per-root collision safety.
// =========================================================================

const collision_program =
    \\(wgsl :name lib :file "lib.wgsl")
    \\(wgsl :name f1 :file "f1.wgsl" :imports [lib])
    \\(shader-module :name root_a :file "root_a.wgsl" :imports [lib f1])
    \\(shader-module :name root_b :file "root_b.wgsl" :imports [lib f1])
;

const collision_lib = "fn shared_value() -> f32 { return 1.0; }";
const collision_f1 = "fn use_one() -> f32 { return shared_value(); }";
const collision_root_a =
    "@fragment fn fs_a() -> @location(0) vec4<f32> { return vec4<f32>(use_one()); }";
const collision_root_b =
    "const renamed_value: f32 = 2.0;\n" ++
    "@fragment fn fs_b() -> @location(0) vec4<f32> { return vec4<f32>(use_one() + renamed_value); }";

test "T3-7 rename validates the name and refuses any root collision" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", collision_program);
    try fake.addFile("/ws/lib.wgsl", collision_lib);
    try fake.addFile("/ws/f1.wgsl", collision_f1);
    try fake.addFile("/ws/root_a.wgsl", collision_root_a);
    try fake.addFile("/ws/root_b.wgsl", collision_root_b);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var lib_buffer: [256]u8 = undefined;
    const lib_uri = try fileUri(&lib_buffer, "/ws/lib.wgsl");
    const position = positionOf(collision_lib, "shared_value", 2);

    // `root_b` already declares `renamed_value`: the same edit would create
    // a duplicate module declaration there, so no root may receive edits.
    try testing.expect((try handler.computeRename(lib_uri, position, "renamed_value")) == null);
    // prepareRename does not know the new name; it still offers the symbol.
    try testing.expect((try handler.prepareRename(lib_uri, position)) != null);

    // Invalid WGSL names keep the standalone rejection on the composed path.
    try testing.expect((try handler.computeRename(lib_uri, position, "return")) == null);
    try testing.expect((try handler.computeRename(lib_uri, position, "__reserved")) == null);

    // A non-colliding name still renames both the library and its use.
    const changes = (try handler.computeRename(lib_uri, position, "fresh_value")) orelse
        return error.MissingRename;
    defer Handler.freeWorkspaceChanges(&handler, changes);
    try testing.expectEqual(@as(usize, 2), changes.documents.len);
}

// =========================================================================
// T3-8 — composed document highlights stay local.
// =========================================================================

const highlight_program =
    \\(wgsl :name lib :file "lib.wgsl")
    \\(wgsl :name f1 :file "f1.wgsl" :imports [lib])
    \\(wgsl :name f2 :file "f2.wgsl" :imports [lib])
    \\(shader-module :name root_a :file "root_a.wgsl" :imports [f1 f2 lib])
    \\(shader-module :name root_b :file "root_b.wgsl" :imports [f1 lib])
;

const highlight_lib =
    "var shared_counter: i32 = 0;\n" ++
    "fn read_counter() -> i32 { return shared_counter; }";
const highlight_f1 = "fn touch_one() { shared_counter = shared_counter + 1; }";
const highlight_f2 = "fn touch_two() -> i32 { return shared_counter; }";
const highlight_root_a =
    "@fragment fn fs_a() -> @location(0) vec4<f32> { return vec4<f32>(f32(touch_two())); }";
const highlight_root_b =
    "@fragment fn fs_b() -> @location(0) vec4<f32> { return vec4<f32>(f32(touch_one())); }";

test "T3-8 highlights stay in the requested document with read/write kinds" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", highlight_program);
    try fake.addFile("/ws/lib.wgsl", highlight_lib);
    try fake.addFile("/ws/f1.wgsl", highlight_f1);
    try fake.addFile("/ws/f2.wgsl", highlight_f2);
    try fake.addFile("/ws/root_a.wgsl", highlight_root_a);
    try fake.addFile("/ws/root_b.wgsl", highlight_root_b);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var lib_buffer: [256]u8 = undefined;
    const lib_uri = try fileUri(&lib_buffer, "/ws/lib.wgsl");
    var f1_buffer: [256]u8 = undefined;
    const f1_uri = try fileUri(&f1_buffer, "/ws/f1.wgsl");

    // From the shared fragment: the declaration and the other file's uses
    // are filtered out; the write and the read remain.
    const f1_highlights = (try handler.computeDocumentHighlight(
        f1_uri,
        positionOf(highlight_f1, "shared_counter", 3),
    )) orelse return error.MissingHighlights;
    defer testing.allocator.free(f1_highlights);
    try testing.expectEqual(@as(usize, 2), f1_highlights.len);

    var writes: usize = 0;
    var reads: usize = 0;
    for (f1_highlights) |highlight| {
        if (std.meta.eql(highlight.range, nthRange(highlight_f1, "shared_counter", 0))) {
            try testing.expectEqual(Handler.HighlightKind.write, highlight.kind);
            writes += 1;
        } else if (std.meta.eql(highlight.range, nthRange(highlight_f1, "shared_counter", 1))) {
            try testing.expectEqual(Handler.HighlightKind.read, highlight.kind);
            reads += 1;
        } else {
            return error.HighlightOutsideRequestedDocument;
        }
    }
    try testing.expectEqual(@as(usize, 1), writes);
    try testing.expectEqual(@as(usize, 1), reads);

    // From the declaration: only the library's own declaration/read are
    // reported, never the fragment uses.
    const lib_highlights = (try handler.computeDocumentHighlight(
        lib_uri,
        positionOf(highlight_lib, "shared_counter", 0),
    )) orelse return error.MissingHighlights;
    defer testing.allocator.free(lib_highlights);
    try testing.expectEqual(@as(usize, 2), lib_highlights.len);
    for (lib_highlights) |highlight| {
        if (std.meta.eql(highlight.range, nthRange(highlight_lib, "shared_counter", 0))) {
            try testing.expectEqual(Handler.HighlightKind.write, highlight.kind);
        } else if (std.meta.eql(highlight.range, nthRange(highlight_lib, "shared_counter", 1))) {
            try testing.expectEqual(Handler.HighlightKind.read, highlight.kind);
        } else {
            return error.HighlightOutsideRequestedDocument;
        }
    }
}
