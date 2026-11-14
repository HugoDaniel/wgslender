//! Request mapping and origin-aware result shapes (pngine-shaders phase 04,
//! Task 1).
//!
//! The red-first contract:
//!   * an author position inside a fragment recovers the assembled offset the
//!     analysis used, and the assembled offset maps back to the same author
//!     part and offset — for body text and for a hoisted directive line;
//!   * a file contained by several roots yields one context per root, each
//!     with its own `Assembled` and mapping, without cross-contamination;
//!   * an inline `:code` origin mints a stable virtual URI from the program
//!     path, part index and content hash; the part-addressed context still
//!     carries no request URI;
//!   * a past-EOF position, a duplicate blanked directive, and a synthetic
//!     terminator have no context — never a clamp to a neighbouring part;
//!   * a standalone document still yields one identity context;
//!   * a standalone definition still serializes as a single `Location`
//!     object and a standalone rename as a one-key `changes` map.
//!
//! Every project test drives `Handler` and the in-memory `SourceProvider`
//! from `pngine_test_provider.zig`; no test reads project text from the host
//! filesystem.

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");
const lspkit = @import("lspkit");
const wire = @import("wire");
const native_navigation = @import("native_navigation");
const native_symbols = @import("native_symbols");
const wgslender = @import("wgslender");
const provider_mod = @import("pngine_test_provider.zig");
const parity = @import("lsp_parity_helpers.zig");

const pngine = wgslender.Pngine;
const Types = pngine.Types;
const Store = pngine.Store;
const FakeProvider = provider_mod.FakeProvider;

const testing = std.testing;

fn fileUri(buffer: []u8, path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "file://{s}", .{path});
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

/// 0-based LSP position of `needle` + `delta` bytes in `source`.
fn positionOf(source: []const u8, needle: []const u8, delta: u32) Handler.Position {
    const start = std.mem.indexOf(u8, source, needle) orelse unreachable;
    return Handler.offsetToLspPosition(source, @intCast(start + delta)) orelse unreachable;
}

fn offsetOf(source: []const u8, needle: []const u8, delta: u32) u32 {
    const start = std.mem.indexOf(u8, source, needle) orelse unreachable;
    return @intCast(start + delta);
}

fn expectOrigin(actual: ?pngine.OriginOffset, origin: Types.PartId, offset: u32) !void {
    const value = actual orelse return error.MissingOriginOffset;
    try testing.expectEqual(origin.program, value.origin.program);
    try testing.expectEqual(origin.index, value.origin.index);
    try testing.expectEqual(offset, value.offset);
}

fn expectPart(actual: Types.PartId, expected: Types.PartId) !void {
    try testing.expectEqual(expected.program, actual.program);
    try testing.expectEqual(expected.index, actual.index);
}

fn symbolByName(module: *const wgslender.Ast.Module, name: []const u8) ?wgslender.Ast.SymbolIndex {
    for (module.symbols.items, 0..) |symbol, index| {
        if (symbol.flags.is_retired) continue;
        if (std.mem.eql(u8, symbol.original_name, name)) return @enumFromInt(@as(u32, @intCast(index)));
    }
    return null;
}

fn bindStore(fake: *FakeProvider, store: *Store, handler: *Handler) !void {
    store.* = Store.init(testing.allocator, fake.sourceProvider());
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);
    handler.* = Handler.init(testing.allocator);
    handler.setPngineStore(store);
}

// =========================================================================
// T1 — local → assembled → local, body and hoisted directive.
// =========================================================================

const roundtrip_program =
    \\(wgsl :name lib :file "lib.wgsl")
    \\(wgsl :name frag :file "frag.wgsl" :imports [lib])
    \\(shader-module :name root :file "root.wgsl" :imports [frag])
;

const roundtrip_lib =
    \\struct Light {
    \\  dir: vec3<f32>,
    \\}
;

const roundtrip_frag =
    \\enable f16;
    \\fn shade(light: Light) -> f32 {
    \\  return light.dir.x;
    \\}
;

const roundtrip_root =
    \\@fragment
    \\fn fs_main() -> @location(0) vec4<f32> {
    \\  return vec4<f32>(shade(Light(vec3<f32>(1.0))));
    \\}
;

test "T1 author position maps to assembled and back, hoisted directive included" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", roundtrip_program);
    try fake.addFile("/ws/lib.wgsl", roundtrip_lib);
    try fake.addFile("/ws/frag.wgsl", roundtrip_frag);
    try fake.addFile("/ws/root.wgsl", roundtrip_root);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var uri_buffer: [512]u8 = undefined;
    const frag_uri = try fileUri(&uri_buffer, "/ws/frag.wgsl");
    const root = try rootFor(&store, "/ws/frag.wgsl");
    const frag_part = partFor(&store, root.program, "frag");
    const analysis = try handler.analyzeRoot(root);
    try testing.expect(analysis.assembled.text.len > 0);

    const cases = [_]struct { needle: []const u8, delta: u32, suffix: []const u8 }{
        .{ .needle = "shade", .delta = 0, .suffix = "shade" },
        .{ .needle = "shade", .delta = 2, .suffix = "ade" },
        .{ .needle = "light.dir", .delta = 0, .suffix = "light.dir" },
        .{ .needle = "light.dir", .delta = 6, .suffix = "dir" },
    };
    for (cases) |case| {
        const author_offset = offsetOf(roundtrip_frag, case.needle, case.delta);
        const position = positionOf(roundtrip_frag, case.needle, case.delta);

        const contexts = try Handler.contextsAt(&handler, frag_uri, position);
        defer Handler.freeContexts(&handler, contexts);

        try testing.expectEqual(@as(usize, 1), contexts.len);
        const context = contexts[0];
        try testing.expect(context.isComposed());
        try testing.expectEqual(root.program, context.root.?.program);
        try testing.expectEqual(root.index, context.root.?.index);
        try expectPart(context.origin.?, frag_part);
        try testing.expectEqual(author_offset, context.author_offset);
        try testing.expectEqualStrings(frag_uri, context.request_uri.?);
        try testing.expectEqualStrings(frag_uri, context.origin_uri.?);
        // `analyzeRoot` returns the cached pointer; the context borrows it.
        try testing.expectEqual(analysis, context.analysis.?);

        const expected = analysis.assembled.offsetFromOrigin(.{
            .origin = frag_part,
            .offset = author_offset,
        }) orelse return error.ExpectedAssembledOffset;
        try testing.expectEqual(expected, context.assembled_offset);
        try testing.expect(std.mem.startsWith(
            u8,
            analysis.assembled.text[context.assembled_offset..],
            case.suffix,
        ));
        try expectOrigin(analysis.assembled.offsetToOrigin(context.assembled_offset), frag_part, author_offset);
    }

    // The hoisted directive is the first byte of the assembled unit even
    // though the author wrote it inside `frag.wgsl`.
    const hoisted_position = positionOf(roundtrip_frag, "enable", 0);
    const hoisted_contexts = try Handler.contextsAt(&handler, frag_uri, hoisted_position);
    defer Handler.freeContexts(&handler, hoisted_contexts);
    try testing.expectEqual(@as(usize, 1), hoisted_contexts.len);
    try testing.expectEqual(@as(u32, 0), hoisted_contexts[0].assembled_offset);
    try testing.expect(std.mem.startsWith(u8, analysis.assembled.text, "enable f16;"));
}

// =========================================================================
// T2 — multi-root contexts have independent assemblies and mappings.
// =========================================================================

const multi_program =
    \\(wgsl :name lib :file "lib.wgsl")
    \\(wgsl :name a :file "a.wgsl" :imports [lib])
    \\(wgsl :name b :file "b.wgsl")
    \\(shader-module :name root_a :file "root_a.wgsl" :imports [a])
    \\(shader-module :name root_b :file "root_b.wgsl" :imports [b lib])
;

const multi_lib = "fn shared() -> f32 { return 1.0; }";
const multi_a = "fn use_a() -> f32 { return shared(); }";
const multi_b = "fn use_b() -> f32 { return shared(); }";
const multi_root_a = "@fragment fn fs_a() -> @location(0) vec4<f32> { return vec4<f32>(use_a()); }";
const multi_root_b = "@fragment fn fs_b() -> @location(0) vec4<f32> { return vec4<f32>(use_b()); }";

test "T2 a shared file yields one context per root with its own mapping" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", multi_program);
    try fake.addFile("/ws/lib.wgsl", multi_lib);
    try fake.addFile("/ws/a.wgsl", multi_a);
    try fake.addFile("/ws/b.wgsl", multi_b);
    try fake.addFile("/ws/root_a.wgsl", multi_root_a);
    try fake.addFile("/ws/root_b.wgsl", multi_root_b);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var uri_buffer: [512]u8 = undefined;
    const lib_uri = try fileUri(&uri_buffer, "/ws/lib.wgsl");
    const lib_part = partFor(&store, (try rootFor(&store, "/ws/lib.wgsl")).program, "lib");
    const position = positionOf(multi_lib, "shared", 0);
    const author_offset = offsetOf(multi_lib, "shared", 0);

    const contexts = try Handler.contextsAt(&handler, lib_uri, position);
    defer Handler.freeContexts(&handler, contexts);
    try testing.expectEqual(@as(usize, 2), contexts.len);

    var root_a_context: ?Handler.RequestContext = null;
    var root_b_context: ?Handler.RequestContext = null;
    for (contexts) |context| {
        const root = context.root.?;
        const program = store.program(root.program) orelse unreachable;
        const name = program.parts[root.index].name;
        if (std.mem.eql(u8, name, "root_a")) {
            root_a_context = context;
        } else if (std.mem.eql(u8, name, "root_b")) {
            root_b_context = context;
        }
    }
    const a = root_a_context orelse return error.MissingRootAContext;
    const b = root_b_context orelse return error.MissingRootBContext;

    // Same author part and offset, independent compiled units.
    try expectPart(a.origin.?, lib_part);
    try expectPart(b.origin.?, lib_part);
    try testing.expectEqual(author_offset, a.author_offset);
    try testing.expectEqual(author_offset, b.author_offset);
    try testing.expect(a.analysis != b.analysis);
    try testing.expect(a.analysis.?.assembled != b.analysis.?.assembled);
    try testing.expect(a.assembled_offset != b.assembled_offset);

    // root_a imports only `a`, so `shared` is the first assembled bytes;
    // root_b imports `b` before `lib`, so the same author offset lands
    // later. Neither mapping may borrow the other root's unit.
    try testing.expect(std.mem.startsWith(u8, a.analysis.?.assembled.text, multi_lib));
    try testing.expect(std.mem.startsWith(u8, b.analysis.?.assembled.text, multi_b));
    try testing.expect(std.mem.indexOf(u8, a.analysis.?.assembled.text, "use_b") == null);
    try testing.expect(std.mem.indexOf(u8, b.analysis.?.assembled.text, "use_a") == null);

    try testing.expectEqual(author_offset, a.assembled_offset);
    try testing.expectEqual(
        @as(u32, @intCast(multi_b.len + 1)) + author_offset,
        b.assembled_offset,
    );
    try expectOrigin(a.analysis.?.assembled.offsetToOrigin(a.assembled_offset), lib_part, author_offset);
    try expectOrigin(b.analysis.?.assembled.offsetToOrigin(b.assembled_offset), lib_part, author_offset);
    try testing.expect(std.mem.startsWith(
        u8,
        b.analysis.?.assembled.text[b.assembled_offset..],
        "shared",
    ));

    // Reading root_a's borrowed unit after root_b was analyzed proves the
    // cache kept both alive independently.
    try expectOrigin(a.analysis.?.assembled.offsetToOrigin(a.assembled_offset), lib_part, author_offset);
}

// =========================================================================
// T3 — inline `:code` origins mint stable virtual URIs.
// =========================================================================

const inline_program =
    \\(wgsl :name inlinepart :code "fn inline_value() -> f32 { return 3.0; }")
    \\(wgsl :name use :file "use.wgsl" :imports [inlinepart])
    \\(shader-module :name main :file "root.wgsl" :imports [use])
;

const inline_code = "fn inline_value() -> f32 { return 3.0; }";
const inline_use = "fn lit() -> f32 { return inline_value(); }";
const inline_root = "@fragment fn fs_main() -> @location(0) vec4<f32> { return vec4<f32>(lit()); }";

test "T3 an inline origin mints a stable virtual URI instead of a path" {
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

    var uri_buffer: [512]u8 = undefined;
    const use_uri = try fileUri(&uri_buffer, "/ws/use.wgsl");
    const root = try rootFor(&store, "/ws/use.wgsl");
    const use_part = partFor(&store, root.program, "use");
    const inline_part = partFor(&store, root.program, "inlinepart");

    const use_contexts = try Handler.contextsAt(&handler, use_uri, positionOf(inline_use, "lit", 1));
    defer Handler.freeContexts(&handler, use_contexts);
    try testing.expectEqual(@as(usize, 1), use_contexts.len);
    const use_context = use_contexts[0];
    try expectPart(use_context.origin.?, use_part);
    try testing.expectEqualStrings(use_uri, use_context.origin_uri.?);

    // A part-addressed request has an author origin and no request URI.
    const inline_contexts = try Handler.contextsForPart(
        &handler,
        inline_part,
        positionOf(inline_code, "inline_value", 4),
    );
    defer Handler.freeContexts(&handler, inline_contexts);
    try testing.expectEqual(@as(usize, 1), inline_contexts.len);
    const inline_context = inline_contexts[0];
    try expectPart(inline_context.origin.?, inline_part);
    try testing.expectEqual(@as(?[]const u8, null), inline_context.request_uri);
    try testing.expectEqual(@as(?[]const u8, null), inline_context.origin_uri);
    try testing.expectEqual(
        offsetOf(inline_code, "inline_value", 4),
        inline_context.author_offset,
    );
    try expectOrigin(
        inline_context.analysis.?.assembled.offsetToOrigin(inline_context.assembled_offset),
        inline_part,
        inline_context.author_offset,
    );

    // The URI helper mints the stable virtual identity for an inline part.
    const inline_uri = (try Handler.originUri(&handler, testing.allocator, inline_part)) orelse
        return error.MissingVirtualUri;
    defer testing.allocator.free(inline_uri);
    try testing.expect(std.mem.startsWith(u8, inline_uri, "wgslender-pngine://part/"));
    var decoded = try pngine.VirtualUri.decode(testing.allocator, inline_uri);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqualStrings("/ws/program.sjon", decoded.program_path);
    try testing.expectEqual(inline_part.index, decoded.part_index);
    var inline_text = store.textForPart(inline_part) catch return error.MissingText;
    defer inline_text.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &inline_text.content_hash, &decoded.content_hash);

    const use_origin_uri = (try Handler.originUri(&handler, testing.allocator, use_part)) orelse
        return error.MissingOriginUri;
    defer testing.allocator.free(use_origin_uri);
    try testing.expectEqualStrings(use_uri, use_origin_uri);

    // Symbol identity records the inline origin and its author-local byte
    // range; its URI is the same virtual spelling.
    const module = use_context.analysis.?.result.module orelse return error.ExpectedModule;
    const inline_symbol = symbolByName(module, "inline_value") orelse return error.MissingSymbol;
    const inline_key = Handler.declarationKey(&use_context, inline_symbol) orelse
        return error.MissingDeclarationKey;
    try expectPart(inline_key.origin, inline_part);
    try testing.expectEqual(offsetOf(inline_code, "inline_value", 0), inline_key.declaration_range.start);
    try testing.expectEqual(
        offsetOf(inline_code, "inline_value", 0) + @as(u32, @intCast("inline_value".len)),
        inline_key.declaration_range.end,
    );
    const inline_key_uri = (try Handler.originUri(&handler, testing.allocator, inline_key.origin)) orelse
        return error.MissingVirtualUri;
    defer testing.allocator.free(inline_key_uri);
    try testing.expectEqualStrings(inline_uri, inline_key_uri);

    // A file-backed declaration in the same analysis maps to the file part.
    const file_symbol = symbolByName(module, "lit") orelse return error.MissingSymbol;
    const file_key = Handler.declarationKey(&use_context, file_symbol) orelse
        return error.MissingDeclarationKey;
    try expectPart(file_key.origin, use_part);
    try testing.expectEqual(offsetOf(inline_use, "lit", 0), file_key.declaration_range.start);
}

// =========================================================================
// T4 — invalid positions never clamp to a neighbouring part.
// =========================================================================

const invalid_program =
    \\(wgsl :name first :file "first.wgsl")
    \\(wgsl :name dup :file "dup.wgsl" :imports [first])
    \\(shader-module :name root :file "root.wgsl" :imports [dup])
;

// No trailing newline: assembly appends a synthetic terminator.
const invalid_first = "enable f16;\nfn first_fn() -> f32 { return 1.0; }";
// The duplicate `enable` is blanked with no semantic hoisted twin.
const invalid_dup = "enable f16;\nfn dup_fn() -> f32 { return 2.0; }";
const invalid_root = "@fragment fn fs_main() -> @location(0) vec4<f32> { return vec4<f32>(first_fn() + dup_fn()); }";

test "T4 invalid author positions yield no context, never a clamp" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", invalid_program);
    try fake.addFile("/ws/first.wgsl", invalid_first);
    try fake.addFile("/ws/dup.wgsl", invalid_dup);
    try fake.addFile("/ws/root.wgsl", invalid_root);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var first_buffer: [512]u8 = undefined;
    const first_uri = try fileUri(&first_buffer, "/ws/first.wgsl");
    var dup_buffer: [512]u8 = undefined;
    const dup_uri = try fileUri(&dup_buffer, "/ws/dup.wgsl");

    // Control: the first occurrence's directive maps through its hoisted
    // copy, so this position is valid.
    const valid = try Handler.contextsAt(
        &handler,
        first_uri,
        positionOf(invalid_first, "enable", 2),
    );
    defer Handler.freeContexts(&handler, valid);
    try testing.expectEqual(@as(usize, 1), valid.len);
    try testing.expectEqual(
        offsetOf(invalid_first, "enable", 2),
        valid[0].assembled_offset,
    );

    // Duplicate blanked directive: no semantic copy exists.
    const duplicate = try Handler.contextsAt(
        &handler,
        dup_uri,
        positionOf(invalid_dup, "enable", 2),
    );
    defer Handler.freeContexts(&handler, duplicate);
    try testing.expectEqual(@as(usize, 0), duplicate.len);

    // Control: the same duplicate file maps fine away from the directive,
    // so the empty result above is about the blanked bytes, not a missing
    // membership.
    const dup_body = try Handler.contextsAt(
        &handler,
        dup_uri,
        positionOf(invalid_dup, "dup_fn", 0),
    );
    defer Handler.freeContexts(&handler, dup_body);
    try testing.expectEqual(@as(usize, 1), dup_body.len);

    // Past the last line.
    const past_eof = try Handler.contextsAt(&handler, first_uri, .{ .line = 99, .character = 0 });
    defer Handler.freeContexts(&handler, past_eof);
    try testing.expectEqual(@as(usize, 0), past_eof.len);

    // Past the end of a real line.
    const past_eol = try Handler.contextsAt(&handler, first_uri, .{ .line = 0, .character = 200 });
    defer Handler.freeContexts(&handler, past_eol);
    try testing.expectEqual(@as(usize, 0), past_eol.len);

    // The author EOF of an unterminated part maps to a synthetic
    // terminator: it is not an authored byte, so there is no context.
    const eof_position = Handler.offsetToLspPosition(
        invalid_first,
        @intCast(invalid_first.len),
    ) orelse return error.MissingPosition;
    const at_terminator = try Handler.contextsAt(&handler, first_uri, eof_position);
    defer Handler.freeContexts(&handler, at_terminator);
    try testing.expectEqual(@as(usize, 0), at_terminator.len);
}

// =========================================================================
// T5 — a standalone document is one identity context.
// =========================================================================

test "T5 a standalone document yields one identity context" {
    var handler = Handler.init(testing.allocator);
    defer handler.deinit();

    const uri = "test://standalone.wgsl";
    const source =
        "fn twice(x: i32) -> i32 { return x * 2; }\n" ++
        "fn main() -> i32 { return twice(21); }\n";
    try handler.openDocument(uri, source, 1);

    const position = positionOf(source, "twice(21)", 2);
    const contexts = try Handler.contextsAt(&handler, uri, position);
    defer Handler.freeContexts(&handler, contexts);
    try testing.expectEqual(@as(usize, 1), contexts.len);
    const context = contexts[0];
    try testing.expect(!context.isComposed());
    try testing.expectEqual(@as(?Types.PartId, null), context.root);
    try testing.expectEqual(@as(?pngine.OriginKey, null), context.origin);
    try testing.expect(context.analysis == null);
    try testing.expectEqualStrings(uri, context.request_uri.?);
    const author_offset = offsetOf(source, "twice(21)", 2);
    try testing.expectEqual(author_offset, context.author_offset);
    try testing.expectEqual(author_offset, context.assembled_offset);
}

// =========================================================================
// T6 — origin-aware Location / WorkspaceChanges codecs.
// =========================================================================

const sample_range: Handler.Range = .{
    .start = .{ .line = 1, .character = 2 },
    .end = .{ .line = 1, .character = 7 },
};

test "T6 one origin-aware Location still serializes as a single object" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const location: Handler.Location = .{ .uri = "test://one.wgsl", .range = sample_range };
    const result = lspkit.navigation.toLspKitDefinitionWithUris(aa, &.{location}) catch
        return error.CodecFailed;
    const value = try parity.writeAndParseResult(aa, lsp.types.Definition.Result, result);
    try testing.expect(value == .object);
    const parsed = value.object;
    // Single Location, not an array.
    try testing.expect(parsed.get("uri") != null);
    try testing.expect(parsed.get("locations") == null);
    try testing.expectEqualStrings("test://one.wgsl", parsed.get("uri").?.string);

    // And it is byte-equivalent to the legacy wire shape.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire.navigation.appendLocation(&buf, aa, "test://one.wgsl", sample_range);
    const wire_value = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});
    try parity.expectEqualJson(value, wire_value);
}

test "T6 multiple origin-aware Locations carry their own URIs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const locations = [_]Handler.Location{
        .{ .uri = "test://a.wgsl", .range = sample_range },
        .{ .uri = "test://b.wgsl", .range = sample_range },
    };
    const result = try lspkit.navigation.toLspKitDefinitionWithUris(aa, &locations);
    const value = try parity.writeAndParseResult(aa, lsp.types.Definition.Result, result);
    try testing.expect(value == .array);
    const list = value.array.items;
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("test://a.wgsl", list[0].object.get("uri").?.string);
    try testing.expectEqualStrings("test://b.wgsl", list[1].object.get("uri").?.string);
}

test "T6 one-document WorkspaceChanges is still a one-key changes map" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const edits = [_]Handler.LspTextEdit{
        .{ .range = sample_range, .new_text = "x" },
        .{ .range = sample_range, .new_text = "y" },
    };
    const changes: Handler.WorkspaceChanges = .{ .documents = &.{.{
        .uri = "test://one.wgsl",
        .edits = &edits,
    }} };
    const result = try lspkit.edits.toLspKitWorkspaceChanges(aa, changes);
    const value = try parity.writeAndParseResult(aa, lsp.types.WorkspaceEdit, result);
    const parsed = value.object;
    const map = parsed.get("changes").?.object;
    try testing.expectEqual(@as(usize, 1), map.count());
    const entries = (map.get("test://one.wgsl") orelse return error.MissingDocument).array.items;
    try testing.expectEqual(@as(usize, 2), entries.len);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    wire.edits.appendWorkspaceEdit(&buf, aa, "test://one.wgsl", &edits);
    const wire_value = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});
    try parity.expectEqualJson(value, wire_value);
}

test "T6 multi-document WorkspaceChanges groups by URI and merges duplicates" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const a_edits = [_]Handler.LspTextEdit{
        .{ .range = sample_range, .new_text = "a0" },
        .{ .range = sample_range, .new_text = "a1" },
    };
    const b_edits = [_]Handler.LspTextEdit{
        .{ .range = sample_range, .new_text = "b0" },
    };
    const changes: Handler.WorkspaceChanges = .{ .documents = &.{
        .{ .uri = "test://a.wgsl", .edits = &a_edits },
        .{ .uri = "test://b.wgsl", .edits = &b_edits },
        .{ .uri = "test://a.wgsl", .edits = &b_edits },
    } };
    const result = try lspkit.edits.toLspKitWorkspaceChanges(aa, changes);
    const parsed = (try parity.writeAndParseResult(aa, lsp.types.WorkspaceEdit, result)).object;
    const map = parsed.get("changes").?.object;
    try testing.expectEqual(@as(usize, 2), map.count());
    const a_entries = (map.get("test://a.wgsl") orelse return error.MissingDocument).array.items;
    try testing.expectEqual(@as(usize, 3), a_entries.len);
    try testing.expectEqualStrings("a0", a_entries[0].object.get("newText").?.string);
    try testing.expectEqualStrings("a1", a_entries[1].object.get("newText").?.string);
    try testing.expectEqualStrings("b0", a_entries[2].object.get("newText").?.string);
}

// =========================================================================
// T7 — native adapter legacy shape: standalone definition and rename.
// =========================================================================

// =========================================================================
// T8/T9/T13 — cross-part hover, definition, and signature help.
// =========================================================================

const parts_program =
    \\(wgsl :name lib :file "lib.wgsl")
    \\(wgsl :name frag :file "frag.wgsl" :imports [lib])
    \\(shader-module :name root :file "root.wgsl" :imports [frag])
;

/// Long enough that the fragment's author offsets and the assembled offsets
/// it is analyzed at differ by more than a kilobyte.
const parts_pad = "// 0123456789abcdef0123456789abcdef\n";

fn buildPartsLib(allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (0..40) |_| try out.appendSlice(allocator, parts_pad);
    try out.appendSlice(
        allocator,
        "const TAU: f32 = 6.2831855;\n\n" ++
            "struct Light {\n  dir: vec3<f32>,\n}\n\n" ++
            "fn shade(light: Light) -> f32 {\n  return light.dir.x;\n}\n",
    );
    return out.toOwnedSlice(allocator);
}

const parts_frag =
    \\fn lit(light: Light) -> f32 {
    \\  return shade(light) + TAU * root_scale;
    \\}
    \\
;

const parts_root =
    \\const root_scale: f32 = 2.0;
    \\
    \\@fragment
    \\fn fs_main() -> @location(0) vec4<f32> {
    \\  return vec4<f32>(lit(Light(vec3<f32>(1.0))));
    \\}
    \\
;

fn rangeIn(source: []const u8, needle: []const u8, delta: u32, len: u32) Handler.Range {
    const start = offsetOf(source, needle, delta);
    return Handler.offsetRangeToLspRange(source, start, start + len) orelse unreachable;
}

test "T8 sibling const, function, and type hover map back to the fragment" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    const lib = try buildPartsLib(testing.allocator);
    defer testing.allocator.free(lib);
    try fake.addFile("/ws/program.sjon", parts_program);
    try fake.addFile("/ws/lib.wgsl", lib);
    try fake.addFile("/ws/frag.wgsl", parts_frag);
    try fake.addFile("/ws/root.wgsl", parts_root);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var uri_buffer: [512]u8 = undefined;
    const frag_uri = try fileUri(&uri_buffer, "/ws/frag.wgsl");

    // A library const hovered from the fragment reports the library's type
    // text, and the returned range is the fragment's own token range.
    const tau_hover = (try handler.computeHover(frag_uri, positionOf(parts_frag, "TAU", 2))) orelse
        return error.MissingHover;
    defer testing.allocator.free(tau_hover.contents);
    try testing.expect(std.mem.indexOf(u8, tau_hover.contents, "TAU") != null);
    try testing.expect(std.mem.indexOf(u8, tau_hover.contents, "f32") != null);
    try testing.expectEqualDeep(
        @as(?Handler.Range, rangeIn(parts_frag, "TAU", 0, 3)),
        @as(?Handler.Range, tau_hover.range),
    );

    // The request is resolved at the mapped assembled offset. At the
    // fragment's author offset the assembled text holds padding from the
    // library, so an author-offset lookup would answer the wrong question.
    const contexts = try Handler.contextsAt(&handler, frag_uri, positionOf(parts_frag, "TAU", 2));
    defer Handler.freeContexts(&handler, contexts);
    try testing.expectEqual(@as(usize, 1), contexts.len);
    try testing.expect(contexts[0].assembled_offset > contexts[0].author_offset + 1024);
    try testing.expect(!std.mem.startsWith(
        u8,
        contexts[0].analysis.?.assembled.text[contexts[0].author_offset..],
        "TAU",
    ));

    // A library function hovered at its call site in the fragment.
    const shade_hover = (try handler.computeHover(frag_uri, positionOf(parts_frag, "shade", 1))) orelse
        return error.MissingHover;
    defer testing.allocator.free(shade_hover.contents);
    try testing.expect(std.mem.indexOf(u8, shade_hover.contents, "fn shade(light: Light) -> f32") != null);
    try testing.expectEqualDeep(
        @as(?Handler.Range, rangeIn(parts_frag, "shade", 0, 5)),
        @as(?Handler.Range, shade_hover.range),
    );

    // A library type hovered in the fragment's type annotation.
    const light_hover = (try handler.computeHover(frag_uri, positionOf(parts_frag, "Light", 1))) orelse
        return error.MissingHover;
    defer testing.allocator.free(light_hover.contents);
    try testing.expect(std.mem.indexOf(u8, light_hover.contents, "struct Light") != null);
    try testing.expect(std.mem.indexOf(u8, light_hover.contents, "dir: vec3<f32>") != null);
    try testing.expectEqualDeep(
        @as(?Handler.Range, rangeIn(parts_frag, "Light", 0, 5)),
        @as(?Handler.Range, light_hover.range),
    );
}

test "T12 builtin hover still resolves through the context path" {
    const program =
        \\(wgsl :name frag :file "frag.wgsl")
        \\(shader-module :name root :file "root.wgsl" :imports [frag])
    ;
    const frag = "fn choose(x: f32) -> f32 { return select(x, 0.0, x > 0.0); }";
    const root = "@fragment fn fs_main() -> @location(0) vec4<f32> { return vec4<f32>(choose(1.0)); }";

    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", program);
    try fake.addFile("/ws/frag.wgsl", frag);
    try fake.addFile("/ws/root.wgsl", root);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var uri_buffer: [512]u8 = undefined;
    const frag_uri = try fileUri(&uri_buffer, "/ws/frag.wgsl");
    const hover = (try handler.computeHover(frag_uri, positionOf(frag, "select", 1))) orelse
        return error.MissingHover;
    defer testing.allocator.free(hover.contents);
    try testing.expect(std.mem.indexOf(u8, hover.contents, "fn select(f: T, t: T, cond: bool) -> T") != null);
    try testing.expect(std.mem.indexOf(u8, hover.contents, "Returns t when cond is true") != null);
    try testing.expectEqualDeep(
        @as(?Handler.Range, rangeIn(frag, "select", 0, 6)),
        @as(?Handler.Range, hover.range),
    );

    // A builtin has no user declaration: no fabricated project location.
    const definition = try handler.computeDefinition(frag_uri, positionOf(frag, "select", 1));
    try testing.expect(definition == null);
}

fn findLocation(locations: []const Handler.Location, uri: []const u8) ?Handler.Location {
    for (locations) |location| {
        if (std.mem.eql(u8, location.uri, uri)) return location;
    }
    return null;
}

test "T9 definitions cross parts with each target's own URI and range" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    const lib = try buildPartsLib(testing.allocator);
    defer testing.allocator.free(lib);
    try fake.addFile("/ws/program.sjon", parts_program);
    try fake.addFile("/ws/lib.wgsl", lib);
    try fake.addFile("/ws/frag.wgsl", parts_frag);
    try fake.addFile("/ws/root.wgsl", parts_root);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var uri_buffer: [512]u8 = undefined;
    const frag_uri = try fileUri(&uri_buffer, "/ws/frag.wgsl");
    var lib_buffer: [512]u8 = undefined;
    const lib_uri = try fileUri(&lib_buffer, "/ws/lib.wgsl");
    var root_buffer: [512]u8 = undefined;
    const root_uri = try fileUri(&root_buffer, "/ws/root.wgsl");

    // Fragment call to a library function -> the library's own range.
    {
        const locations = (try handler.computeDefinition(frag_uri, positionOf(parts_frag, "shade", 1))) orelse
            return error.MissingDefinition;
        defer Handler.freeDefinitionLocations(&handler, locations);
        try testing.expectEqual(@as(usize, 1), locations.len);
        try testing.expectEqualStrings(lib_uri, locations[0].uri);
        try testing.expectEqualDeep(rangeIn(lib, "shade", 0, 5), locations[0].range);
    }

    // Root call to a fragment-declared function -> the fragment's range.
    {
        const locations = (try handler.computeDefinition(root_uri, positionOf(parts_root, "lit(", 1))) orelse
            return error.MissingDefinition;
        defer Handler.freeDefinitionLocations(&handler, locations);
        try testing.expectEqual(@as(usize, 1), locations.len);
        try testing.expectEqualStrings(frag_uri, locations[0].uri);
        try testing.expectEqualDeep(rangeIn(parts_frag, "lit", 0, 3), locations[0].range);
    }

    // Fragment reference to a root-supplied declaration -> the root file.
    {
        const locations = (try handler.computeDefinition(frag_uri, positionOf(parts_frag, "root_scale", 1))) orelse
            return error.MissingDefinition;
        defer Handler.freeDefinitionLocations(&handler, locations);
        try testing.expectEqual(@as(usize, 1), locations.len);
        try testing.expectEqualStrings(root_uri, locations[0].uri);
        try testing.expectEqualDeep(rangeIn(parts_root, "root_scale", 0, 10), locations[0].range);
    }

    // Type definition from the fragment's parameter follows the same path.
    {
        const locations = (try handler.computeTypeDefinition(frag_uri, positionOf(parts_frag, "lit(light", 4))) orelse
            return error.MissingTypeDefinition;
        defer Handler.freeDefinitionLocations(&handler, locations);
        try testing.expectEqual(@as(usize, 1), locations.len);
        try testing.expectEqualStrings(lib_uri, locations[0].uri);
        try testing.expectEqualDeep(rangeIn(lib, "struct Light", 7, 5), locations[0].range);
    }
}

const inline_nav_program =
    \\(wgsl :name inlinepart :code "fn inline_value() -> f32 { return 3.0; }")
    \\(wgsl :name use :file "use.wgsl" :imports [inlinepart])
    \\(shader-module :name main :file "nav_root.wgsl" :imports [use])
;

const inline_nav_code = "fn inline_value() -> f32 { return 3.0; }";
const inline_nav_use = "fn lit() -> f32 { return inline_value(); }";
const inline_nav_root = "@fragment fn fs_main() -> @location(0) vec4<f32> { return vec4<f32>(lit()); }";

test "T10 inline targets navigate to the exact virtual document range" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", inline_nav_program);
    try fake.addFile("/ws/use.wgsl", inline_nav_use);
    try fake.addFile("/ws/nav_root.wgsl", inline_nav_root);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var uri_buffer: [512]u8 = undefined;
    const use_uri = try fileUri(&uri_buffer, "/ws/use.wgsl");
    const root = try rootFor(&store, "/ws/use.wgsl");
    const inline_part = partFor(&store, root.program, "inlinepart");
    const inline_uri = (try Handler.originUri(&handler, testing.allocator, inline_part)) orelse
        return error.MissingVirtualUri;
    defer testing.allocator.free(inline_uri);

    // The target is inline text: definition lands on the stable virtual
    // document with the declaration's exact author-local range.
    const definition = (try handler.computeDefinition(
        use_uri,
        positionOf(inline_nav_use, "inline_value", 1),
    )) orelse return error.MissingDefinition;
    defer Handler.freeDefinitionLocations(&handler, definition);
    try testing.expectEqual(@as(usize, 1), definition.len);
    try testing.expectEqualStrings(inline_uri, definition[0].uri);
    try testing.expectEqualDeep(
        rangeIn(inline_nav_code, "inline_value", 0, 12),
        definition[0].range,
    );

    // Hovering the reference is representable in the requesting file.
    const hover = (try handler.computeHover(use_uri, positionOf(inline_nav_use, "inline_value", 1))) orelse
        return error.MissingHover;
    defer testing.allocator.free(hover.contents);
    try testing.expect(std.mem.indexOf(u8, hover.contents, "inline_value") != null);
    try testing.expect(hover.range != null);
    try testing.expectEqualDeep(
        @as(?Handler.Range, rangeIn(inline_nav_use, "inline_value", 0, 12)),
        hover.range,
    );

    // A part-addressed hover has content but no document to place a range
    // in; the caller did not supply the virtual spelling.
    const part_hover = (try Handler.computeHoverForPart(
        &handler,
        inline_part,
        positionOf(inline_nav_code, "inline_value", 2),
    )) orelse return error.MissingHover;
    defer testing.allocator.free(part_hover.contents);
    try testing.expect(std.mem.indexOf(u8, part_hover.contents, "inline_value") != null);
    try testing.expect(part_hover.range == null);

    // A hover requested on the virtual document itself places its range in
    // that document rather than reporting an assembled offset.
    const virtual_hover = (try handler.computeHover(
        inline_uri,
        positionOf(inline_nav_code, "inline_value", 2),
    )) orelse return error.MissingHover;
    defer testing.allocator.free(virtual_hover.contents);
    try testing.expectEqualDeep(
        @as(?Handler.Range, rangeIn(inline_nav_code, "inline_value", 0, 12)),
        virtual_hover.range,
    );
}

const varying_program =
    \\(wgsl :name lib :file "shared.wgsl")
    \\(wgsl :name sup_a :file "sup_a.wgsl")
    \\(wgsl :name sup_b :file "sup_b.wgsl")
    \\(wgsl :name extra :file "extra.wgsl")
    \\(wgsl :name frag :file "frag.wgsl" :requires [Hole only_a])
    \\(shader-module :name root_a :file "root_a.wgsl" :imports [lib sup_a extra frag])
    \\(shader-module :name root_b :file "root_b.wgsl" :imports [lib sup_b frag])
;

const varying_lib = "const SHARED: f32 = 1.0;\nfn helper() -> f32 { return SHARED; }";
const varying_sup_a = "struct Hole {\n  a: f32,\n}";
const varying_sup_b = "struct Hole {\n  a: f32,\n  b: f32,\n}";
const varying_extra = "const only_a: f32 = 3.0;";
const varying_frag =
    \\fn sample() -> f32 {
    \\  var h: Hole;
    \\  return h.a + only_a + SHARED + helper();
    \\}
;
const varying_root_a =
    "@fragment fn fs_a() -> @location(0) vec4<f32> { return vec4<f32>(sample()); }";
const varying_root_b =
    "@fragment fn fs_b() -> @location(0) vec4<f32> { return vec4<f32>(sample()); }";

test "T11 root-varying hover labels variants and deduplicates agreement" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", varying_program);
    try fake.addFile("/ws/shared.wgsl", varying_lib);
    try fake.addFile("/ws/sup_a.wgsl", varying_sup_a);
    try fake.addFile("/ws/sup_b.wgsl", varying_sup_b);
    try fake.addFile("/ws/extra.wgsl", varying_extra);
    try fake.addFile("/ws/frag.wgsl", varying_frag);
    try fake.addFile("/ws/root_a.wgsl", varying_root_a);
    try fake.addFile("/ws/root_b.wgsl", varying_root_b);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var uri_buffer: [512]u8 = undefined;
    const frag_uri = try fileUri(&uri_buffer, "/ws/frag.wgsl");

    // The same hole is a different struct in each root: both layouts are
    // reported, labelled, and the common request range is kept.
    {
        const hover = (try handler.computeHover(frag_uri, positionOf(varying_frag, "Hole", 1))) orelse
            return error.MissingHover;
        defer testing.allocator.free(hover.contents);
        try testing.expect(std.mem.indexOf(u8, hover.contents, "root_a") != null);
        try testing.expect(std.mem.indexOf(u8, hover.contents, "root_b") != null);
        try testing.expect(std.mem.indexOf(u8, hover.contents, "size: 4B") != null);
        try testing.expect(std.mem.indexOf(u8, hover.contents, "size: 8B") != null);
        try testing.expectEqualDeep(
            @as(?Handler.Range, rangeIn(varying_frag, "Hole", 0, 4)),
            hover.range,
        );
    }

    // A hole that only one root supplies is labelled, not silently chosen.
    {
        const hover = (try handler.computeHover(frag_uri, positionOf(varying_frag, "only_a", 1))) orelse
            return error.MissingHover;
        defer testing.allocator.free(hover.contents);
        try testing.expect(std.mem.indexOf(u8, hover.contents, "root_a") != null);
        try testing.expect(std.mem.indexOf(u8, hover.contents, "root_b") == null);
        try testing.expect(std.mem.indexOf(u8, hover.contents, "only_a") != null);
        try testing.expectEqualDeep(
            @as(?Handler.Range, rangeIn(varying_frag, "only_a", 0, 6)),
            hover.range,
        );
    }

    // Identical answers are one entry with no root label.
    {
        const hover = (try handler.computeHover(frag_uri, positionOf(varying_frag, "SHARED", 1))) orelse
            return error.MissingHover;
        defer testing.allocator.free(hover.contents);
        try testing.expect(std.mem.indexOf(u8, hover.contents, "root_a") == null);
        try testing.expect(std.mem.indexOf(u8, hover.contents, "root_b") == null);
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, hover.contents, "SHARED"));
        try testing.expectEqualDeep(
            @as(?Handler.Range, rangeIn(varying_frag, "SHARED", 0, 6)),
            hover.range,
        );
    }

    // Definitions: distinct declarations in distinct files, never merged.
    {
        const locations = (try handler.computeDefinition(frag_uri, positionOf(varying_frag, "Hole", 1))) orelse
            return error.MissingDefinition;
        defer Handler.freeDefinitionLocations(&handler, locations);
        try testing.expectEqual(@as(usize, 2), locations.len);
        var sup_buffer_a: [512]u8 = undefined;
        const sup_uri_a = try fileUri(&sup_buffer_a, "/ws/sup_a.wgsl");
        var sup_buffer_b: [512]u8 = undefined;
        const sup_uri_b = try fileUri(&sup_buffer_b, "/ws/sup_b.wgsl");
        const a_location = findLocation(locations, sup_uri_a) orelse return error.MissingLocationA;
        const b_location = findLocation(locations, sup_uri_b) orelse return error.MissingLocationB;
        try testing.expectEqualDeep(rangeIn(varying_sup_a, "Hole", 0, 4), a_location.range);
        try testing.expectEqualDeep(rangeIn(varying_sup_b, "Hole", 0, 4), b_location.range);
    }

    // A one-root declaration has exactly one location.
    {
        const locations = (try handler.computeDefinition(frag_uri, positionOf(varying_frag, "only_a", 1))) orelse
            return error.MissingDefinition;
        defer Handler.freeDefinitionLocations(&handler, locations);
        try testing.expectEqual(@as(usize, 1), locations.len);
        var extra_buffer: [512]u8 = undefined;
        const extra_uri = try fileUri(&extra_buffer, "/ws/extra.wgsl");
        try testing.expectEqualStrings(extra_uri, locations[0].uri);
        try testing.expectEqualDeep(rangeIn(varying_extra, "only_a", 0, 6), locations[0].range);
    }

    // A declaration shared by both roots is deduplicated by its identity.
    {
        const locations = (try handler.computeDefinition(frag_uri, positionOf(varying_frag, "SHARED", 1))) orelse
            return error.MissingDefinition;
        defer Handler.freeDefinitionLocations(&handler, locations);
        try testing.expectEqual(@as(usize, 1), locations.len);
        var lib_buffer: [512]u8 = undefined;
        const lib_uri = try fileUri(&lib_buffer, "/ws/shared.wgsl");
        try testing.expectEqualStrings(lib_uri, locations[0].uri);
        try testing.expectEqualDeep(rangeIn(varying_lib, "SHARED", 0, 6), locations[0].range);
    }

    // Signature help dedupes the same cross-part callee in both roots.
    {
        const info = (try handler.computeSignatureHelp(frag_uri, positionOf(varying_frag, "helper(", 7))) orelse
            return error.MissingSignature;
        defer testing.allocator.free(info.label);
        if (info.parameters.len > 0) testing.allocator.free(info.parameters);
        try testing.expect(std.mem.indexOf(u8, info.label, "fn helper() -> f32") != null);
        try testing.expect(std.mem.indexOf(u8, info.label, "root_a") == null);
        try testing.expect(std.mem.indexOf(u8, info.label, "root_b") == null);
    }
}

const signature_hole_program =
    \\(wgsl :name sup_a :code "alias Measure = f32;")
    \\(wgsl :name sup_b :code "alias Measure = i32;")
    \\(wgsl :name frag :file "frag.wgsl" :requires [Measure])
    \\(shader-module :name root_a :file "root_a.wgsl" :imports [sup_a frag])
    \\(shader-module :name root_b :file "root_b.wgsl" :imports [sup_b frag])
;

const signature_hole_frag =
    \\fn take(x: Measure) -> f32 { return 1.0; }
    \\fn caller() -> f32 { return take(1.0); }
;
const signature_hole_root_a =
    "@fragment fn fs_a() -> @location(0) vec4<f32> { return vec4<f32>(caller()); }";
const signature_hole_root_b =
    "@fragment fn fs_b() -> @location(0) vec4<f32> { return vec4<f32>(caller()); }";

test "T13 signature help resolves cross-part callees and labels root variants" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    const lib = try buildPartsLib(testing.allocator);
    defer testing.allocator.free(lib);
    try fake.addFile("/ws/program.sjon", parts_program);
    try fake.addFile("/ws/lib.wgsl", lib);
    try fake.addFile("/ws/frag.wgsl", parts_frag);
    try fake.addFile("/ws/root.wgsl", parts_root);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var uri_buffer: [512]u8 = undefined;
    const frag_uri = try fileUri(&uri_buffer, "/ws/frag.wgsl");

    // The callee is declared in the library; the request and its argument
    // are in the fragment.
    const info = (try handler.computeSignatureHelp(frag_uri, positionOf(parts_frag, "shade(", 6))) orelse
        return error.MissingSignature;
    defer testing.allocator.free(info.label);
    if (info.parameters.len > 0) testing.allocator.free(info.parameters);
    try testing.expect(std.mem.indexOf(u8, info.label, "shade") != null);
    try testing.expect(std.mem.indexOf(u8, info.label, "Light") != null);
    try testing.expect(std.mem.indexOf(u8, info.label, "-> f32") != null);
    try testing.expectEqual(@as(u32, 0), info.active_parameter);

    // A hole whose alias differs per root makes the resolved label differ.
    var hole_fake = FakeProvider.init(testing.allocator);
    defer hole_fake.deinit();
    try hole_fake.addFile("/ws/program.sjon", signature_hole_program);
    try hole_fake.addFile("/ws/frag.wgsl", signature_hole_frag);
    try hole_fake.addFile("/ws/root_a.wgsl", signature_hole_root_a);
    try hole_fake.addFile("/ws/root_b.wgsl", signature_hole_root_b);

    var hole_store: Store = undefined;
    var hole_handler: Handler = undefined;
    try bindStore(&hole_fake, &hole_store, &hole_handler);
    defer hole_handler.deinit();
    defer hole_store.deinit();

    var hole_buffer: [512]u8 = undefined;
    const hole_uri = try fileUri(&hole_buffer, "/ws/frag.wgsl");
    const variants = (try hole_handler.computeSignatureHelp(hole_uri, positionOf(signature_hole_frag, "take(1.0)", 5))) orelse
        return error.MissingSignature;
    defer testing.allocator.free(variants.label);
    if (variants.parameters.len > 0) testing.allocator.free(variants.parameters);
    try testing.expect(std.mem.indexOf(u8, variants.label, "root_a") != null);
    try testing.expect(std.mem.indexOf(u8, variants.label, "root_b") != null);
    try testing.expect(std.mem.indexOf(u8, variants.label, "f32") != null);
    try testing.expect(std.mem.indexOf(u8, variants.label, "i32") != null);
}

test "T7 standalone definition is one Location and rename one changes key" {
    var handler = Handler.init(testing.allocator);
    defer handler.deinit();

    const uri = "test://legacy.wgsl";
    const source =
        "fn twice(x: i32) -> i32 { return x * 2; }\n" ++
        "fn main() -> i32 { return twice(21); }\n";
    try handler.openDocument(uri, source, 1);

    const call_position = positionOf(source, "twice(21)", 2);
    const declaration_range = Handler.offsetRangeToLspRange(
        source,
        offsetOf(source, "twice", 0),
        offsetOf(source, "twice", 0) + 5,
    ) orelse return error.MissingRange;

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const definition = native_navigation.handleDefinition(&handler, aa, .{
        .textDocument = .{ .uri = uri },
        .position = lspkit.primitives.toLspKitPosition(call_position),
    }) orelse return error.MissingDefinition;
    switch (definition) {
        .definition => |value| switch (value) {
            .location => |location| {
                try testing.expectEqualStrings(uri, location.uri);
                try testing.expectEqualDeep(
                    declaration_range,
                    lspkit.primitives.fromLspKitRange(location.range),
                );
            },
            .locations => return error.DefinitionShouldBeSingleLocation,
        },
        .definition_links => return error.DefinitionShouldNotBeLinks,
    }

    const rename = native_symbols.handleRename(&handler, aa, .{
        .textDocument = .{ .uri = uri },
        .position = lspkit.primitives.toLspKitPosition(call_position),
        .newName = "thrice",
    }) orelse return error.MissingRename;
    const changes = rename.changes orelse return error.MissingChanges;
    try testing.expectEqual(@as(usize, 1), changes.map.count());
    const edits = changes.map.get(uri) orelse return error.MissingRenameDocument;
    try testing.expectEqual(@as(usize, 2), edits.len);
    for (edits) |edit| try testing.expectEqualStrings("thrice", edit.newText);
    try testing.expectEqualDeep(
        declaration_range,
        lspkit.primitives.fromLspKitRange(edits[0].range),
    );
}
