//! Composed completion and member resolution (pngine-shaders phase 04,
//! Task 4).
//!
//! The red-first contract:
//!   * completing inside a fragment offers every containing root's assembled
//!     module-scope names — imported library globals, root declarations and
//!     inline `:code` declarations — each label once even when several roots
//!     reach the same declaration;
//!   * locals keep the standalone source-order rule, but `VisibleLocals` is
//!     evaluated at each context's *assembled* cursor offset, never at the
//!     author offset;
//!   * a visible fragment local shadows a library name: one label, the
//!     local's type;
//!   * duplicate labels with incompatible root type details are omitted
//!     rather than resolved by root order;
//!   * `x.` resolves through the mapped AST/symbol first, and the
//!     error-recovery name fallback only considers active, visible,
//!     mutually compatible symbols — never the first same-named symbol
//!     across roots;
//!   * the attribute/builtin/keyword/type/swizzle inventories are exactly
//!     the standalone inventories.
//!
//! Every project test drives `Handler` and the in-memory `SourceProvider`
//! from `pngine_test_provider.zig`; no test reads project text from the host
//! filesystem. `CompletionItem` carries a label, kind and detail only — it
//! has no location field, so no URI is invented for an inline item.

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

/// 0-based LSP position of `needle` + `delta` bytes in `source`.
fn positionOf(source: []const u8, needle: []const u8, delta: u32) Handler.Position {
    const start = std.mem.indexOf(u8, source, needle) orelse unreachable;
    return Handler.offsetToLspPosition(source, @intCast(start + delta)) orelse unreachable;
}

fn partFor(store: *Store, program: Types.ProgramId, name: []const u8) Types.PartId {
    const program_value = store.program(program) orelse unreachable;
    const index = program_value.findFragment(name) orelse unreachable;
    return .{ .program = program, .index = index };
}

fn rootFor(store: *Store, path: []const u8) !Types.PartId {
    var buffer: [512]u8 = undefined;
    var set = try store.membershipsFor(try fileUri(&buffer, path));
    defer set.deinit(testing.allocator);
    if (set.items.len == 0) return error.TestExpectedMembership;
    const membership = set.items[0];
    if (membership.containing_roots.len == 0) return error.TestExpectedRoot;
    return .{ .program = membership.program, .index = membership.containing_roots[0] };
}

fn bindStore(fake: *FakeProvider, store: *Store, handler: *Handler) !void {
    store.* = Store.init(testing.allocator, fake.sourceProvider());
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);
    handler.* = Handler.init(testing.allocator);
    handler.setPngineStore(store);
}

fn hasItem(items: []const Handler.CompletionItem, label: []const u8) bool {
    return countLabel(items, label) > 0;
}

fn countLabel(items: []const Handler.CompletionItem, label: []const u8) usize {
    var n: usize = 0;
    for (items) |item| {
        if (std.mem.eql(u8, item.label, label)) n += 1;
    }
    return n;
}

fn detailOf(items: []const Handler.CompletionItem, label: []const u8) ?[]const u8 {
    for (items) |item| {
        if (std.mem.eql(u8, item.label, label)) return item.detail;
    }
    return null;
}

fn expectSameItems(
    actual: []const Handler.CompletionItem,
    expected: []const Handler.CompletionItem,
) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (actual, expected) |a, e| {
        try testing.expectEqualStrings(e.label, a.label);
        try testing.expectEqual(e.kind, a.kind);
        try testing.expectEqualStrings(e.detail, a.detail);
    }
}

// =========================================================================
// T4-1 — imported globals and root declarations, deduplicated across roots.
// =========================================================================

const union_program =
    \\(wgsl :name lib :file "lib.wgsl")
    \\(wgsl :name frag :file "frag.wgsl" :imports [lib])
    \\(shader-module :name root_a :file "root_a.wgsl" :imports [frag lib])
    \\(shader-module :name root_b :file "root_b.wgsl" :imports [frag lib])
;

const union_lib =
    \\const LIB_CONST: f32 = 1.0;
    \\struct LibData { value: f32 }
    \\fn lib_helper() -> f32 { return LIB_CONST; }
;

const union_frag =
    \\fn frag_fn() -> f32 {
    \\  /*HERE*/
    \\  return 1.0;
    \\}
;

const union_frag_edited =
    \\const EDITED_CONST: f32 = 8.0;
    \\fn frag_fn() -> f32 {
    \\  /*HERE*/
    \\  return 1.0;
    \\}
;

const union_root_a =
    \\const ROOT_A_VALUE: f32 = 2.0;
    \\@fragment fn fs_a() -> @location(0) vec4<f32> {
    \\  return vec4<f32>(frag_fn());
    \\}
;

const union_root_b =
    \\const ROOT_B_VALUE: f32 = 3.0;
    \\@fragment fn fs_b() -> @location(0) vec4<f32> {
    \\  return vec4<f32>(frag_fn());
    \\}
;

test "T4-1 completing a fragment unions imported and root module symbols once" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", union_program);
    try fake.addFile("/ws/lib.wgsl", union_lib);
    try fake.addFile("/ws/frag.wgsl", union_frag);
    try fake.addFile("/ws/root_a.wgsl", union_root_a);
    try fake.addFile("/ws/root_b.wgsl", union_root_b);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var frag_buffer: [256]u8 = undefined;
    const frag_uri = try fileUri(&frag_buffer, "/ws/frag.wgsl");
    try handler.openDocument(frag_uri, union_frag, 1);
    try testing.expect(store.hasOverlay(frag_uri));

    const items = try handler.computeCompletion(frag_uri, positionOf(union_frag, "/*HERE*/", 0));
    defer testing.allocator.free(items);

    // The imported library's module scope: const, struct and function. The
    // declaration is reached through both roots but appears once.
    for ([_][]const u8{ "LIB_CONST", "LibData", "lib_helper" }) |label| {
        try testing.expectEqual(@as(usize, 1), countLabel(items, label));
    }
    try testing.expectEqualStrings("f32", detailOf(items, "LIB_CONST").?);

    // Root-supplied declarations from each root are in the union.
    try testing.expect(hasItem(items, "ROOT_A_VALUE"));
    try testing.expect(hasItem(items, "ROOT_B_VALUE"));

    // Current open-buffer text is authoritative: the edit joins the
    // assembled unit without reopening or rediscovering the project.
    try handler.changeDocument(frag_uri, union_frag_edited);
    const edited_items = try handler.computeCompletion(frag_uri, positionOf(union_frag_edited, "/*HERE*/", 0));
    defer testing.allocator.free(edited_items);
    try testing.expect(hasItem(edited_items, "EDITED_CONST"));
    try testing.expectEqual(@as(usize, 1), countLabel(edited_items, "LIB_CONST"));
    try testing.expect(hasItem(edited_items, "ROOT_A_VALUE"));
    try testing.expect(hasItem(edited_items, "ROOT_B_VALUE"));
}

// =========================================================================
// T4-2 — inline `:code` parts complete from the assembled unit.
// =========================================================================

const inline_code = "const INLINE_CONST: f32 = 4.0; struct InlineData { v: f32 } fn inline_value() -> f32 { /*HERE*/ return INLINE_CONST; }";

const inline_program =
    \\(wgsl :name inlinepart :code "const INLINE_CONST: f32 = 4.0; struct InlineData { v: f32 } fn inline_value() -> f32 { /*HERE*/ return INLINE_CONST; }")
    \\(wgsl :name use :file "use.wgsl" :imports [inlinepart])
    \\(shader-module :name root :file "root.wgsl" :imports [use])
;

const inline_use =
    \\const USE_CONST: f32 = 5.0;
    \\fn use_value() -> f32 { /*FILE_HERE*/ return inline_value(); }
;

const inline_root =
    \\const ROOT_ONLY: f32 = 6.0;
    \\@fragment fn fs_main() -> @location(0) vec4<f32> {
    \\  return vec4<f32>(use_value());
    \\}
;

test "T4-2 an inline part completes from the assembled unit" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", inline_program);
    try fake.addFile("/ws/use.wgsl", inline_use);
    try fake.addFile("/ws/root.wgsl", inline_root);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    const root = try rootFor(&store, "/ws/use.wgsl");
    const inline_part = partFor(&store, root.program, "inlinepart");

    // Part-addressed: no virtual URI exists yet and `CompletionItem` has no
    // location field, so the answer can only be labels/kinds/details.
    const part_items = try Handler.computeCompletionForPart(
        &handler,
        inline_part,
        positionOf(inline_code, "/*HERE*/", 0),
    );
    defer testing.allocator.free(part_items);
    for ([_][]const u8{ "INLINE_CONST", "InlineData", "inline_value", "USE_CONST", "ROOT_ONLY" }) |label| {
        try testing.expect(hasItem(part_items, label));
    }

    // And the file part sees the inline module scope in its own request.
    var use_buffer: [256]u8 = undefined;
    const use_uri = try fileUri(&use_buffer, "/ws/use.wgsl");
    const file_items = try handler.computeCompletion(use_uri, positionOf(inline_use, "/*FILE_HERE*/", 0));
    defer testing.allocator.free(file_items);
    try testing.expect(hasItem(file_items, "INLINE_CONST"));
    try testing.expect(hasItem(file_items, "inline_value"));
    try testing.expect(hasItem(file_items, "ROOT_ONLY"));
}

// =========================================================================
// T4-3 — locals are collected at each assembled cursor offset.
// =========================================================================

const locals_program =
    \\(wgsl :name lib :file "lib.wgsl")
    \\(wgsl :name frag :file "frag.wgsl" :imports [lib])
    \\(shader-module :name root :file "root.wgsl" :imports [frag lib])
;

// The two padding comments put the fragment's author cursor offset (well
// under 100) inside `lib_noise`'s assembled body. Evaluating `VisibleLocals`
// at the author offset would therefore offer `wrong_local`; the correct
// assembled offset is past this function.
const locals_lib =
    \\fn lib_noise() -> f32 {
    \\  let wrong_local = 9.0;
    \\  // padding padding padding padding padding padding padding padding
    \\  // padding padding padding padding padding padding padding padding
    \\  // padding padding padding padding padding padding padding padding
    \\  return wrong_local;
    \\}
;

const locals_frag =
    \\fn frag_fn(param_x: f32) -> f32 {
    \\  let before = 1.0;
    \\  /*HERE*/
    \\  let after = 2.0;
    \\  return param_x + before + after;
    \\}
;

const locals_root =
    \\@fragment fn fs_main() -> @location(0) vec4<f32> {
    \\  return vec4<f32>(frag_fn(1.0));
    \\}
;

test "T4-3 locals follow source order at the assembled cursor offset" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", locals_program);
    try fake.addFile("/ws/lib.wgsl", locals_lib);
    try fake.addFile("/ws/frag.wgsl", locals_frag);
    try fake.addFile("/ws/root.wgsl", locals_root);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var frag_buffer: [256]u8 = undefined;
    const frag_uri = try fileUri(&frag_buffer, "/ws/frag.wgsl");
    const items = try handler.computeCompletion(frag_uri, positionOf(locals_frag, "/*HERE*/", 0));
    defer testing.allocator.free(items);

    try testing.expectEqual(@as(usize, 1), countLabel(items, "before"));
    try testing.expectEqual(@as(usize, 1), countLabel(items, "param_x"));
    try testing.expect(!hasItem(items, "after"));
    try testing.expect(!hasItem(items, "wrong_local"));

    // Module scope from the assembled unit is still present, so this is a
    // local-scope test rather than a missing-context accident.
    try testing.expect(hasItem(items, "frag_fn"));
    try testing.expect(hasItem(items, "lib_noise"));
}

// =========================================================================
// T4-4 — a visible local shadows a library name.
// =========================================================================

const shadow_program =
    \\(wgsl :name lib :file "lib.wgsl")
    \\(wgsl :name frag :file "frag.wgsl" :imports [lib])
    \\(shader-module :name root :file "root.wgsl" :imports [frag lib])
;

const shadow_lib =
    \\struct LibType { from_lib: f32 }
    \\const shadowed: LibType = LibType(1.0);
;

const shadow_frag =
    \\struct FragType { from_frag: f32 }
    \\fn frag_fn(lib: LibType) -> f32 {
    \\  let shadowed = FragType(2.0);
    \\  /*HERE*/
    \\  return shadowed.from_frag + lib.from_lib;
    \\}
;

const shadow_root =
    \\@fragment fn fs_main() -> @location(0) vec4<f32> {
    \\  return vec4<f32>(frag_fn(LibType(3.0)));
    \\}
;

test "T4-4 a fragment local shadows the library name without duplicating it" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", shadow_program);
    try fake.addFile("/ws/lib.wgsl", shadow_lib);
    try fake.addFile("/ws/frag.wgsl", shadow_frag);
    try fake.addFile("/ws/root.wgsl", shadow_root);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var frag_buffer: [256]u8 = undefined;
    const frag_uri = try fileUri(&frag_buffer, "/ws/frag.wgsl");
    const items = try handler.computeCompletion(frag_uri, positionOf(shadow_frag, "/*HERE*/", 0));
    defer testing.allocator.free(items);

    try testing.expectEqual(@as(usize, 1), countLabel(items, "shadowed"));
    try testing.expectEqualStrings("FragType", detailOf(items, "shadowed").?);
}

// =========================================================================
// T4-5 — conflicting root type details are omitted, compatible ones merge.
// =========================================================================

const conflict_program =
    \\(wgsl :name sup_a :file "sup_a.wgsl")
    \\(wgsl :name sup_b :file "sup_b.wgsl")
    \\(wgsl :name frag :file "frag.wgsl")
    \\(shader-module :name root_a :file "root_a.wgsl" :imports [sup_a frag])
    \\(shader-module :name root_b :file "root_b.wgsl" :imports [sup_b frag])
;

const conflict_sup_a =
    \\const CONFLICT: f32 = 1.0;
    \\const AGREE: f32 = 7.0;
;

const conflict_sup_b =
    \\const CONFLICT: vec2<f32> = vec2<f32>(1.0, 2.0);
    \\const AGREE: f32 = 7.0;
;

const conflict_frag =
    \\fn frag_fn() -> f32 {
    \\  /*HERE*/
    \\  return 1.0;
    \\}
;

const conflict_root_a =
    \\@fragment fn fs_a() -> @location(0) vec4<f32> {
    \\  return vec4<f32>(frag_fn());
    \\}
;

const conflict_root_b =
    \\@fragment fn fs_b() -> @location(0) vec4<f32> {
    \\  return vec4<f32>(frag_fn());
    \\}
;

test "T4-5 conflicting root types omit the label; equal details merge" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", conflict_program);
    try fake.addFile("/ws/sup_a.wgsl", conflict_sup_a);
    try fake.addFile("/ws/sup_b.wgsl", conflict_sup_b);
    try fake.addFile("/ws/frag.wgsl", conflict_frag);
    try fake.addFile("/ws/root_a.wgsl", conflict_root_a);
    try fake.addFile("/ws/root_b.wgsl", conflict_root_b);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var frag_buffer: [256]u8 = undefined;
    const frag_uri = try fileUri(&frag_buffer, "/ws/frag.wgsl");
    const items = try handler.computeCompletion(frag_uri, positionOf(conflict_frag, "/*HERE*/", 0));
    defer testing.allocator.free(items);

    // `CONFLICT` is f32 in root_a and vec2<f32> in root_b: no silent
    // first-root type, so the label is not offered at all.
    try testing.expect(!hasItem(items, "CONFLICT"));
    // `AGREE` has the same detail in both roots: one item survives.
    try testing.expectEqual(@as(usize, 1), countLabel(items, "AGREE"));
    try testing.expectEqualStrings("f32", detailOf(items, "AGREE").?);
    // Control: the ordinary module scope is present.
    try testing.expect(hasItem(items, "frag_fn"));
}

// =========================================================================
// T4-6 — member resolution through a sibling part.
// =========================================================================

const sibling_program =
    \\(wgsl :name types :file "types.wgsl")
    \\(wgsl :name frag :file "frag.wgsl" :imports [types])
    \\(shader-module :name root :file "root.wgsl" :imports [frag types])
;

const sibling_types =
    \\struct SiblingData {
    \\  sibling_field: f32,
    \\  sibling_other: u32,
    \\}
;

const sibling_frag =
    \\fn use_sibling() -> f32 {
    \\  var x: SiblingData;
    \\  let r = x.;
    \\  return r;
    \\}
;

const sibling_root =
    \\@fragment fn fs_main() -> @location(0) vec4<f32> {
    \\  return vec4<f32>(use_sibling());
    \\}
;

test "T4-6 x. resolves fields through the assembled symbol in a sibling part" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", sibling_program);
    try fake.addFile("/ws/types.wgsl", sibling_types);
    try fake.addFile("/ws/frag.wgsl", sibling_frag);
    try fake.addFile("/ws/root.wgsl", sibling_root);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var frag_buffer: [256]u8 = undefined;
    const frag_uri = try fileUri(&frag_buffer, "/ws/frag.wgsl");
    const items = try handler.computeCompletion(frag_uri, positionOf(sibling_frag, "x.", 2));
    defer testing.allocator.free(items);

    try testing.expect(hasItem(items, "sibling_field"));
    try testing.expect(hasItem(items, "sibling_other"));
    try testing.expectEqualStrings("f32", detailOf(items, "sibling_field").?);
    try testing.expectEqualStrings("u32", detailOf(items, "sibling_other").?);
}

// =========================================================================
// T4-7 — error-recovery fallback never picks one root's same-named symbol.
// =========================================================================

const fallback_program =
    \\(wgsl :name sup_a :file "sup_a.wgsl")
    \\(wgsl :name sup_b :file "sup_b.wgsl")
    \\(wgsl :name frag :file "frag.wgsl")
    \\(shader-module :name root_a :file "root_a.wgsl" :imports [sup_a frag])
    \\(shader-module :name root_b :file "root_b.wgsl" :imports [sup_b frag])
;

const fallback_sup_a =
    \\struct A { from_a: f32 }
    \\var<private> p: A;
;

const fallback_sup_b =
    \\struct B { from_b: f32 }
    \\var<private> p: B;
;

// `helper`'s local `p` is not visible in `probe`; a whole-module name scan
// (the pre-composed fallback) would still hand back `FragP`'s fields.
const fallback_frag =
    \\struct FragP { from_frag: f32 }
    \\fn helper() -> f32 {
    \\  var p: FragP;
    \\  return p.from_frag;
    \\}
    \\fn probe() -> f32 {
    \\  let r = p.;
    \\  return r;
    \\}
;

const fallback_root_a =
    \\@fragment fn fs_a() -> @location(0) vec4<f32> {
    \\  return vec4<f32>(probe());
    \\}
;

const fallback_root_b =
    \\@fragment fn fs_b() -> @location(0) vec4<f32> {
    \\  return vec4<f32>(probe());
    \\}
;

test "T4-7 the member fallback requires compatible active symbols" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", fallback_program);
    try fake.addFile("/ws/sup_a.wgsl", fallback_sup_a);
    try fake.addFile("/ws/sup_b.wgsl", fallback_sup_b);
    try fake.addFile("/ws/frag.wgsl", fallback_frag);
    try fake.addFile("/ws/root_a.wgsl", fallback_root_a);
    try fake.addFile("/ws/root_b.wgsl", fallback_root_b);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var frag_buffer: [256]u8 = undefined;
    const frag_uri = try fileUri(&frag_buffer, "/ws/frag.wgsl");
    // The open buffer makes the old standalone fallback observable: it
    // would pick `helper`'s local `p` (FragP) by name.
    try handler.openDocument(frag_uri, fallback_frag, 1);

    const probe_needle = "let r = p.";
    const items = try handler.computeCompletion(
        frag_uri,
        positionOf(fallback_frag, probe_needle, @intCast(probe_needle.len)),
    );
    defer testing.allocator.free(items);

    try testing.expectEqual(@as(usize, 0), items.len);
}

// The same struct name can be defined differently by two roots. The member
// fallback must compare the fields, not just the type name.
const hole_frag =
    \\var<private> p: Hole;
    \\fn probe() -> f32 {
    \\  let r = p.;
    \\  return r;
    \\}
;

test "T4-7b same-named root structs with different fields answer nothing" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", fallback_program);
    try fake.addFile("/ws/sup_a.wgsl", "struct Hole { from_a: f32 }");
    try fake.addFile("/ws/sup_b.wgsl", "struct Hole { from_b: f32 }");
    try fake.addFile("/ws/frag.wgsl", hole_frag);
    try fake.addFile("/ws/root_a.wgsl", fallback_root_a);
    try fake.addFile("/ws/root_b.wgsl", fallback_root_b);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var frag_buffer: [256]u8 = undefined;
    const frag_uri = try fileUri(&frag_buffer, "/ws/frag.wgsl");
    const probe_needle = "let r = p.";
    const items = try handler.computeCompletion(
        frag_uri,
        positionOf(hole_frag, probe_needle, @intCast(probe_needle.len)),
    );
    defer testing.allocator.free(items);

    try testing.expectEqual(@as(usize, 0), items.len);
}

// =========================================================================
// T4-8 — attribute/builtin/keyword/type/swizzle inventories are unchanged.
// =========================================================================

const static_program =
    \\(wgsl :name frag :file "frag.wgsl")
    \\(shader-module :name root :file "root.wgsl" :imports [frag])
;

const static_frag =
    \\fn frag_fn() -> f32 {
    \\  /*HERE*/
    \\  return 1.0;
    \\}
;

const static_root =
    \\@fragment fn fs_main() -> @location(0) vec4<f32> {
    \\  return vec4<f32>(frag_fn());
    \\}
;

test "T4-8 composed general completion keeps the standalone static inventories" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", static_program);
    try fake.addFile("/ws/frag.wgsl", static_frag);
    try fake.addFile("/ws/root.wgsl", static_root);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var plain = Handler.init(testing.allocator);
    defer plain.deinit();
    try plain.openDocument("test://plain.wgsl", "", 1);
    const expected = try plain.computeCompletion("test://plain.wgsl", .{ .line = 0, .character = 0 });
    defer testing.allocator.free(expected);

    var frag_buffer: [256]u8 = undefined;
    const frag_uri = try fileUri(&frag_buffer, "/ws/frag.wgsl");
    const items = try handler.computeCompletion(frag_uri, positionOf(static_frag, "/*HERE*/", 0));
    defer testing.allocator.free(items);

    try testing.expect(items.len >= expected.len);
    try expectSameItems(items[items.len - expected.len ..], expected);
}

const at_frag = "@";
const at_root =
    \\@fragment fn fs_main() -> @location(0) vec4<f32> {
    \\  return vec4<f32>(1.0);
    \\}
;

const swizzle_frag =
    \\fn frag_fn() -> f32 {
    \\  var v: vec3<f32>;
    \\  let s = v.;
    \\  return s;
    \\}
;

test "T4-9 composed @ and vector member completions match the standalone path" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon",
        \\(wgsl :name atpart :file "at.wgsl")
        \\(wgsl :name swpart :file "sw.wgsl")
        \\(shader-module :name root :file "root.wgsl" :imports [atpart swpart])
    );
    try fake.addFile("/ws/at.wgsl", at_frag);
    try fake.addFile("/ws/sw.wgsl", swizzle_frag);
    try fake.addFile("/ws/root.wgsl", at_root);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var plain = Handler.init(testing.allocator);
    defer plain.deinit();

    var at_buffer: [256]u8 = undefined;
    const at_uri = try fileUri(&at_buffer, "/ws/at.wgsl");
    try plain.openDocument("test://at.wgsl", at_frag, 1);
    const expected_at = try plain.computeCompletion("test://at.wgsl", .{ .line = 0, .character = 1 });
    defer testing.allocator.free(expected_at);
    const composed_at = try handler.computeCompletion(at_uri, .{ .line = 0, .character = 1 });
    defer testing.allocator.free(composed_at);
    try expectSameItems(composed_at, expected_at);

    var sw_buffer: [256]u8 = undefined;
    const sw_uri = try fileUri(&sw_buffer, "/ws/sw.wgsl");
    try plain.openDocument("test://sw.wgsl", swizzle_frag, 1);
    const sw_position = positionOf(swizzle_frag, "v.", 2);
    const expected_sw = try plain.computeCompletion("test://sw.wgsl", sw_position);
    defer testing.allocator.free(expected_sw);
    const composed_sw = try handler.computeCompletion(sw_uri, sw_position);
    defer testing.allocator.free(composed_sw);
    try expectSameItems(composed_sw, expected_sw);
}
