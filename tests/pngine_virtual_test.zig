//! Inline virtual documents and native provider parity (pngine-shaders
//! phase 04, Task 6).
//!
//! The red-first contract:
//!   * a virtual part URI round-trips the canonical program path, the
//!     source-order part index and the content hash, and URL-escapes every
//!     byte outside the unreserved set exactly once;
//!   * an inline `:code` part mints a stable `wgslender-pngine:` URI and the
//!     part handler returns its current author text with language id `wgsl`;
//!   * a URI whose part disappeared reports `error.MissingPart`, and a URI
//!     whose `:code` text changed reports `error.StalePart`; neither invents
//!     text or serves the old bytes;
//!   * definition and hover work in both directions between a file part and
//!     the virtual document, with ranges local to the document that owns
//!     them;
//!   * every native LSP result shape (hover, definition, references,
//!     completion labels, diagnostics codes/ranges) is identical whether the
//!     project text came from an open buffer or the provider.
//!
//! Every project test drives `Handler`, `NativeServer` and the in-memory
//! `SourceProvider` from `pngine_test_provider.zig`; no test reads project
//! text from the host filesystem.

const std = @import("std");
const lsp = @import("lsp");
const wgslender = @import("wgslender");
const Handler = @import("Handler");
const NativeServer = @import("NativeServer");
const lspkit = @import("lspkit");
const native_editing = @import("native_editing");
const native_navigation = @import("native_navigation");
const provider_mod = @import("pngine_test_provider.zig");
const parity = @import("lsp_parity_helpers.zig");

const Pngine = wgslender.Pngine;
const Types = Pngine.Types;
const Store = Pngine.Store;
const VirtualUri = Pngine.VirtualUri;
const FakeProvider = provider_mod.FakeProvider;

const testing = std.testing;
const Position = Handler.Position;

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
fn positionOf(source: []const u8, needle: []const u8, delta: u32) Position {
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

fn bindStore(fake: *FakeProvider, store: *Store, handler: *Handler) !void {
    store.* = Store.init(testing.allocator, fake.sourceProvider());
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);
    handler.* = Handler.init(testing.allocator);
    handler.setPngineStore(store);
}

const NullTransport = struct {
    transport: lsp.Transport,

    fn init() NullTransport {
        return .{ .transport = .{
            .vtable = &.{
                .readJsonMessage = readJsonMessage,
                .writeJsonMessage = writeJsonMessage,
            },
        } };
    }

    fn readJsonMessage(_: *lsp.Transport, _: std.Io, _: std.mem.Allocator) lsp.Transport.ReadError![]u8 {
        return error.EndOfStream;
    }

    fn writeJsonMessage(_: *lsp.Transport, _: std.Io, _: []const u8) lsp.Transport.WriteError!void {}
};

/// Construct a native server bound to `fake` and initialise the `/ws`
/// workspace. The caller owns the returned server.
fn setupServer(fake: *FakeProvider, transport: *NullTransport) !*NativeServer {
    const server = try testing.allocator.create(NativeServer);
    errdefer testing.allocator.destroy(server);
    server.* = NativeServer.init(testing.allocator, &transport.transport, std.testing.io);
    server.pngine_provider_override = fake.sourceProvider();

    const folders = [_]lsp.types.workspace.Folder{
        .{ .uri = "file:///ws", .name = "ws" },
    };
    // `initialize` takes a per-call arena in production; mirror that so its
    // path decoding does not outlive the call.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    _ = server.initialize(arena.allocator(), .{
        .capabilities = .{},
        .workspaceFolders = &folders,
    });
    return server;
}

fn teardownServer(server: *NativeServer) void {
    server.deinit();
    testing.allocator.destroy(server);
}

// =========================================================================
// T6-1 — stable URI codec.
// =========================================================================

test "T6-1 virtual URI round-trips path, part index and hash with percent-encoding once" {
    const hash = Types.contentHash("fn inline_value() -> f32 { return 1.0; }");
    // A literal `%2F` in the program path must become `%252F`: a decoder
    // that runs a URL decoder twice would turn it into a path separator.
    const program_path = "/ws/pro%2Fgram dir/\u{0161}.sjon";

    const uri = try VirtualUri.encode(testing.allocator, program_path, 7, hash);
    defer testing.allocator.free(uri);

    try testing.expect(std.mem.startsWith(u8, uri, "wgslender-pngine://part/"));
    try testing.expect(std.mem.indexOf(u8, uri, "%252F") != null);
    try testing.expect(std.mem.indexOf(u8, uri, "%20") != null);
    try testing.expect(std.mem.indexOf(u8, uri, "\u{0161}") == null);
    // `!` is not unreserved even though encodeURIComponent leaves it raw.
    const bang = try VirtualUri.encode(testing.allocator, "/ws/a!b.sjon", 0, hash);
    defer testing.allocator.free(bang);
    try testing.expect(std.mem.indexOf(u8, bang, "%21") != null);

    var decoded = try VirtualUri.decode(testing.allocator, uri);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqualStrings(program_path, decoded.program_path);
    try testing.expectEqual(@as(u32, 7), decoded.part_index);
    try testing.expectEqualSlices(u8, &hash, &decoded.content_hash);

    // The byte shape is pinned independently of the hash value so the
    // TypeScript codec's test can assert the same string.
    const zero_hash = [_]u8{0} ** 32;
    const pinned = try VirtualUri.encode(testing.allocator, program_path, 7, zero_hash);
    defer testing.allocator.free(pinned);
    try testing.expectEqualStrings(
        "wgslender-pngine://part/%2Fws%2Fpro%252Fgram%20dir%2F%C5%A1.sjon/7/" ++
            "0000000000000000000000000000000000000000000000000000000000000000",
        pinned,
    );
}

test "T6-1b malformed virtual URIs are rejected without guessing" {
    const hash = Types.contentHash("x");
    const uri = try VirtualUri.encode(testing.allocator, "/ws/program.sjon", 2, hash);
    defer testing.allocator.free(uri);

    const cases = [_][]const u8{
        "file:///ws/program.sjon",
        "wgslender-pngine://part/",
        "wgslender-pngine://part/%2Fws%2Fprogram.sjon",
        "wgslender-pngine://part/%2Fws%2Fprogram.sjon/not-a-number/0123",
        "wgslender-pngine://part/%2Fws%2Fprogram.sjon/2/not-a-hash",
        "wgslender-pngine://part/%2Fws%2Fprogram.sjon/2/%ZZ",
        "wgslender-pngine://other/%2Fws%2Fprogram.sjon/2/0123",
    };
    for (cases) |bad| {
        try testing.expectError(error.InvalidPartUri, VirtualUri.decode(testing.allocator, bad));
    }

    // The encoded form itself is the only valid spelling: a raw path
    // separator would make the segment split ambiguous.
    const raw_separator = "wgslender-pngine://part//ws/program.sjon/2/0123";
    try testing.expectError(error.InvalidPartUri, VirtualUri.decode(testing.allocator, raw_separator));
}

// =========================================================================
// T6-2 … T6-4 — inline part identity, text, missing and stale.
// =========================================================================

const inline_program =
    \\(wgsl :name lib :file "lib.wgsl")
    \\(wgsl :name inlinepart :code "fn inline_value() -> f32 { return LIB_VALUE; }")
    \\(wgsl :name use :file "use.wgsl" :imports [lib inlinepart])
    \\(shader-module :name root :file "root.wgsl" :imports [use lib])
;

const inline_lib = "const LIB_VALUE: f32 = 1.0;";
const inline_code = "fn inline_value() -> f32 { return LIB_VALUE; }";
const inline_use = "fn file_use() -> f32 { return inline_value(); }";
const inline_root =
    "@fragment fn fs_main() -> @location(0) vec4<f32> { return vec4<f32>(file_use()); }";

fn addInlineFixture(fake: *FakeProvider) !void {
    try fake.addFile("/ws/program.sjon", inline_program);
    try fake.addFile("/ws/lib.wgsl", inline_lib);
    try fake.addFile("/ws/use.wgsl", inline_use);
    try fake.addFile("/ws/root.wgsl", inline_root);
}

test "T6-2 an inline part mints a stable URI whose handler returns its author text" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addInlineFixture(&fake);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    const root = try rootFor(&store, "/ws/use.wgsl");
    const inline_part = partFor(&store, root.program, "inlinepart");

    const uri = (try Handler.originUri(&handler, testing.allocator, inline_part)) orelse
        return error.MissingVirtualUri;
    defer testing.allocator.free(uri);
    try testing.expect(std.mem.startsWith(u8, uri, "wgslender-pngine://part/"));

    var decoded = try VirtualUri.decode(testing.allocator, uri);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqualStrings("/ws/program.sjon", decoded.program_path);
    try testing.expectEqual(inline_part.index, decoded.part_index);
    var current = store.textForPart(inline_part) catch return error.MissingText;
    defer current.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &current.content_hash, &decoded.content_hash);

    var document = try Handler.PngineContext.partDocument(&handler, testing.allocator, uri);
    defer document.deinit(testing.allocator);
    try testing.expectEqualStrings(inline_code, document.text);
    try testing.expectEqualStrings("wgsl", document.language_id);

    // The same part mints the same URI while its text is unchanged.
    const again = (try Handler.originUri(&handler, testing.allocator, inline_part)) orelse
        return error.MissingVirtualUri;
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(uri, again);

    // A part-addressed request keeps its no-URI shape; only virtual
    // documents get the minted spelling.
    const contexts = try Handler.contextsForPart(
        &handler,
        inline_part,
        positionOf(inline_code, "inline_value", 2),
    );
    defer Handler.freeContexts(&handler, contexts);
    try testing.expectEqual(@as(usize, 1), contexts.len);
    try testing.expectEqual(@as(?[]const u8, null), contexts[0].request_uri);
}

test "T6-3 a removed inline part reports missing part instead of inventing text" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addInlineFixture(&fake);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    const root = try rootFor(&store, "/ws/use.wgsl");
    const inline_part = partFor(&store, root.program, "inlinepart");
    const uri = (try Handler.originUri(&handler, testing.allocator, inline_part)) orelse
        return error.MissingVirtualUri;
    defer testing.allocator.free(uri);

    const replacement =
        \\(wgsl :name lib :file "lib.wgsl")
        \\(wgsl :name use :file "use.wgsl" :imports [lib])
        \\(shader-module :name root :file "root.wgsl" :imports [use lib])
    ;
    try fake.addFile("/ws/program.sjon", replacement);
    store.invalidatePath("/ws/program.sjon");

    try testing.expectError(
        error.MissingPart,
        Handler.PngineContext.partDocument(&handler, testing.allocator, uri),
    );

    // A feature request on the stale-identity URI also refuses mapping
    // rather than treating the old author bytes as current.
    const contexts = try Handler.contextsAt(&handler, uri, positionOf(inline_code, "inline_value", 2));
    defer Handler.freeContexts(&handler, contexts);
    try testing.expectEqual(@as(usize, 0), contexts.len);
}

test "T6-4 a changed inline part reports stale and never serves the old bytes" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addInlineFixture(&fake);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    const root = try rootFor(&store, "/ws/use.wgsl");
    const inline_part = partFor(&store, root.program, "inlinepart");
    const old_uri = (try Handler.originUri(&handler, testing.allocator, inline_part)) orelse
        return error.MissingVirtualUri;
    defer testing.allocator.free(old_uri);

    const changed_code = "fn inline_value() -> f32 { return LIB_VALUE + 1.0; }";
    const changed_program =
        \\(wgsl :name lib :file "lib.wgsl")
        \\(wgsl :name inlinepart :code "fn inline_value() -> f32 { return LIB_VALUE + 1.0; }")
        \\(wgsl :name use :file "use.wgsl" :imports [lib inlinepart])
        \\(shader-module :name root :file "root.wgsl" :imports [use lib])
    ;
    try fake.addFile("/ws/program.sjon", changed_program);
    store.invalidatePath("/ws/program.sjon");

    try testing.expectError(
        error.StalePart,
        Handler.PngineContext.partDocument(&handler, testing.allocator, old_uri),
    );

    const root_after = try rootFor(&store, "/ws/use.wgsl");
    const part_after = partFor(&store, root_after.program, "inlinepart");
    const new_uri = (try Handler.originUri(&handler, testing.allocator, part_after)) orelse
        return error.MissingVirtualUri;
    defer testing.allocator.free(new_uri);
    try testing.expect(!std.mem.eql(u8, old_uri, new_uri));

    var document = try Handler.PngineContext.partDocument(&handler, testing.allocator, new_uri);
    defer document.deinit(testing.allocator);
    try testing.expectEqualStrings(changed_code, document.text);

    // The old URI is not accepted by a feature request either.
    const contexts = try Handler.contextsAt(&handler, old_uri, positionOf(changed_code, "inline_value", 2));
    defer Handler.freeContexts(&handler, contexts);
    try testing.expectEqual(@as(usize, 0), contexts.len);
}

// =========================================================================
// T6-5 — sending a native `wgslender/pnginePart` request.
// =========================================================================

test "T6-5 native pnginePart serves current text and distinguishes missing from stale" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addInlineFixture(&fake);

    var transport = NullTransport.init();
    const server = try setupServer(&fake, &transport);
    defer teardownServer(server);

    const store = server.pngine_store orelse return error.MissingStore;
    const root = try rootFor(store, "/ws/use.wgsl");
    const inline_part = partFor(store, root.program, "inlinepart");
    const uri = (try Handler.originUri(&server.handler, testing.allocator, inline_part)) orelse
        return error.MissingVirtualUri;
    defer testing.allocator.free(uri);

    const result = try server.pnginePart(testing.allocator, .{ .uri = uri });
    defer testing.allocator.free(result.text);
    try testing.expectEqualStrings(inline_code, result.text);
    try testing.expectEqualStrings("wgsl", result.languageId);

    const replacement =
        \\(wgsl :name lib :file "lib.wgsl")
        \\(wgsl :name use :file "use.wgsl" :imports [lib])
        \\(shader-module :name root :file "root.wgsl" :imports [use lib])
    ;
    try fake.addFile("/ws/program.sjon", replacement);
    store.invalidatePath("/ws/program.sjon");
    try testing.expectError(
        error.MissingPart,
        server.pnginePart(testing.allocator, .{ .uri = uri }),
    );

    const changed_code = "fn inline_value() -> f32 { return 42.0; }";
    const changed_program =
        \\(wgsl :name lib :file "lib.wgsl")
        \\(wgsl :name inlinepart :code "fn inline_value() -> f32 { return 42.0; }")
        \\(wgsl :name use :file "use.wgsl" :imports [lib inlinepart])
        \\(shader-module :name root :file "root.wgsl" :imports [use lib])
    ;
    try fake.addFile("/ws/program.sjon", changed_program);
    store.invalidatePath("/ws/program.sjon");
    try testing.expectError(
        error.StalePart,
        server.pnginePart(testing.allocator, .{ .uri = uri }),
    );

    const root_after = try rootFor(store, "/ws/use.wgsl");
    const part_after = partFor(store, root_after.program, "inlinepart");
    const new_uri = (try Handler.originUri(&server.handler, testing.allocator, part_after)) orelse
        return error.MissingVirtualUri;
    defer testing.allocator.free(new_uri);
    const document = try server.pnginePart(testing.allocator, .{ .uri = new_uri });
    defer testing.allocator.free(document.text);
    try testing.expectEqualStrings(changed_code, document.text);
}

// =========================================================================
// T6-6 — definition and hover across the virtual boundary.
// =========================================================================

test "T6-6 definition and hover cross between file text and the virtual document" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try addInlineFixture(&fake);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var use_buffer: [256]u8 = undefined;
    const use_uri = try fileUri(&use_buffer, "/ws/use.wgsl");
    var lib_buffer: [256]u8 = undefined;
    const lib_uri = try fileUri(&lib_buffer, "/ws/lib.wgsl");

    const root = try rootFor(&store, "/ws/use.wgsl");
    const inline_part = partFor(&store, root.program, "inlinepart");
    const virtual_uri = (try Handler.originUri(&handler, testing.allocator, inline_part)) orelse
        return error.MissingVirtualUri;
    defer testing.allocator.free(virtual_uri);

    // File → inline declaration: one location on the virtual document,
    // with the exact author-local declaration range.
    const definition = (try handler.computeDefinition(
        use_uri,
        positionOf(inline_use, "inline_value", 1),
    )) orelse return error.MissingDefinition;
    defer Handler.freeDefinitionLocations(&handler, definition);
    try testing.expectEqual(@as(usize, 1), definition.len);
    try testing.expectEqualStrings(virtual_uri, definition[0].uri);
    try testing.expectEqualDeep(
        rangeIn(inline_code, "inline_value", 0, "inline_value".len),
        definition[0].range,
    );

    // Hover on the virtual document itself resolves through the assembled
    // root and reports a range in the virtual document, not assembled bytes.
    const hover = (try handler.computeHover(
        virtual_uri,
        positionOf(inline_code, "inline_value", 2),
    )) orelse return error.MissingHover;
    defer testing.allocator.free(hover.contents);
    try testing.expect(std.mem.indexOf(u8, hover.contents, "inline_value") != null);
    try testing.expectEqualDeep(
        @as(?Handler.Range, rangeIn(inline_code, "inline_value", 0, "inline_value".len)),
        hover.range,
    );

    // Virtual → file declaration: the inline `LIB_VALUE` use lands in
    // `lib.wgsl`, not in the virtual document.
    const back = (try handler.computeDefinition(
        virtual_uri,
        positionOf(inline_code, "LIB_VALUE", 2),
    )) orelse return error.MissingBackDefinition;
    defer Handler.freeDefinitionLocations(&handler, back);
    try testing.expectEqual(@as(usize, 1), back.len);
    try testing.expectEqualStrings(lib_uri, back[0].uri);
    try testing.expectEqualDeep(
        rangeIn(inline_lib, "LIB_VALUE", 0, "LIB_VALUE".len),
        back[0].range,
    );

    // References include the virtual location with its own URI.
    const refs = (try handler.computeReferences(
        lib_uri,
        positionOf(inline_lib, "LIB_VALUE", 2),
        true,
    )) orelse return error.MissingReferences;
    defer Handler.freeReferences(&handler, refs);
    var saw_virtual = false;
    for (refs) |ref| {
        if (ref.uri) |uri_value| {
            if (std.mem.eql(u8, uri_value, virtual_uri)) {
                saw_virtual = true;
                try testing.expectEqualDeep(
                    rangeIn(inline_code, "LIB_VALUE", 0, "LIB_VALUE".len),
                    ref.range,
                );
            }
        }
    }
    try testing.expect(saw_virtual);
}

// =========================================================================
// T6-7 — native result-shape parity: open buffer vs filesystem provider.
// =========================================================================

const parity_program =
    \\(wgsl :name lib :file "lib.wgsl")
    \\(wgsl :name inlinepart :code "fn inline_value() -> f32 { return lib_helper(); }")
    \\(wgsl :name frag :file "frag.wgsl" :imports [lib inlinepart])
    \\(shader-module :name root :file "root.wgsl" :imports [frag lib])
;

const parity_lib =
    \\const LIB_VALUE: f32 = 1.0;
    \\fn lib_helper() -> f32 { return LIB_VALUE; }
;
const parity_inline = "fn inline_value() -> f32 { return lib_helper(); }";
const parity_frag =
    \\fn frag_fn() -> f32 {
    \\  let bad: i32 = 1.0;
    \\  /*HERE*/
    \\  return lib_helper() + LIB_VALUE + inline_value();
    \\}
;
const parity_root =
    "@fragment fn fs_main() -> @location(0) vec4<f32> { return vec4<f32>(frag_fn()); }";

fn addParityFixture(fake: *FakeProvider) !void {
    try fake.addFile("/ws/program.sjon", parity_program);
    try fake.addFile("/ws/lib.wgsl", parity_lib);
    try fake.addFile("/ws/frag.wgsl", parity_frag);
    try fake.addFile("/ws/root.wgsl", parity_root);
}

/// One JSON object holding every native LSP result shape the task names.
fn nativeShape(
    handler: *Handler,
    arena: std.mem.Allocator,
    frag_uri: []const u8,
) !std.json.Value {
    var object: std.json.ObjectMap = .empty;

    const hover = native_navigation.handleHover(handler, .{
        .textDocument = .{ .uri = frag_uri },
        .position = lspkit.primitives.toLspKitPosition(positionOf(parity_frag, "lib_helper", 2)),
    });
    defer if (hover) |value| switch (value.contents) {
        .markup_content => |content| handler.gpa.free(@constCast(content.value)),
        else => {},
    };
    try object.put(arena, "hover", if (hover) |value|
        try parity.writeAndParseResult(arena, lsp.types.Hover, value)
    else
        .null);

    const definition = native_navigation.handleDefinition(handler, arena, .{
        .textDocument = .{ .uri = frag_uri },
        .position = lspkit.primitives.toLspKitPosition(positionOf(parity_frag, "lib_helper", 2)),
    });
    try object.put(arena, "definition", if (definition) |value|
        try parity.writeAndParseResult(arena, lsp.types.Definition.Result, value)
    else
        .null);

    const inline_definition = native_navigation.handleDefinition(handler, arena, .{
        .textDocument = .{ .uri = frag_uri },
        .position = lspkit.primitives.toLspKitPosition(positionOf(parity_frag, "inline_value", 2)),
    });
    try object.put(arena, "inline_definition", if (inline_definition) |value|
        try parity.writeAndParseResult(arena, lsp.types.Definition.Result, value)
    else
        .null);

    const references = native_navigation.handleReferences(handler, arena, .{
        .textDocument = .{ .uri = frag_uri },
        .position = lspkit.primitives.toLspKitPosition(positionOf(parity_frag, "lib_helper", 2)),
        .context = .{ .includeDeclaration = true },
    });
    try object.put(arena, "references", if (references) |value|
        try parity.writeAndParseResult(arena, []const lsp.types.Location, value)
    else
        .null);

    const completion = native_editing.handleCompletion(handler, arena, .{
        .textDocument = .{ .uri = frag_uri },
        .position = lspkit.primitives.toLspKitPosition(positionOf(parity_frag, "/*HERE*/", 0)),
    });
    try object.put(arena, "completion", if (completion) |value|
        try parity.writeAndParseResult(arena, lsp.types.completion.Result, value)
    else
        .null);

    const diags = try handler.validatePngineDocument(frag_uri, .{});
    defer Handler.freeDiagnostics(handler.gpa, diags);
    const bridged = try lspkit.diagnostics.toLspKitDiagnosticsOwned(arena, diags, frag_uri);
    try object.put(arena, "diagnostics", try parity.writeAndParseResult(
        arena,
        []const lsp.types.Diagnostic,
        bridged,
    ));

    return .{ .object = object };
}

test "T6-7 native result shapes are identical for open-buffer and provider text" {
    // A: every project text comes from the provider.
    var disk_fake = FakeProvider.init(testing.allocator);
    defer disk_fake.deinit();
    try addParityFixture(&disk_fake);

    var disk_store: Store = undefined;
    var disk_handler: Handler = undefined;
    try bindStore(&disk_fake, &disk_store, &disk_handler);
    defer disk_handler.deinit();
    defer disk_store.deinit();

    var disk_uri_buffer: [256]u8 = undefined;
    const disk_frag_uri = try fileUri(&disk_uri_buffer, "/ws/frag.wgsl");
    const disk_root = try rootFor(&disk_store, "/ws/frag.wgsl");
    const disk_frag_part = partFor(&disk_store, disk_root.program, "frag");
    var disk_text = disk_store.textForPart(disk_frag_part) catch return error.MissingText;
    defer disk_text.deinit(testing.allocator);
    try testing.expectEqual(Types.SourceOrigin.disk, disk_text.origin);

    // B: the same bytes arrive as an open buffer for the same part. The
    // provider still holds identical disk text underneath.
    var buffer_fake = FakeProvider.init(testing.allocator);
    defer buffer_fake.deinit();
    try addParityFixture(&buffer_fake);

    var buffer_store: Store = undefined;
    var buffer_handler: Handler = undefined;
    try bindStore(&buffer_fake, &buffer_store, &buffer_handler);
    defer buffer_handler.deinit();
    defer buffer_store.deinit();

    var buffer_uri_buffer: [256]u8 = undefined;
    const buffer_frag_uri = try fileUri(&buffer_uri_buffer, "/ws/frag.wgsl");
    try buffer_handler.openDocument(buffer_frag_uri, parity_frag, 1);

    const buffer_root = try rootFor(&buffer_store, "/ws/frag.wgsl");
    const buffer_frag_part = partFor(&buffer_store, buffer_root.program, "frag");
    var buffer_text = buffer_store.textForPart(buffer_frag_part) catch return error.MissingText;
    defer buffer_text.deinit(testing.allocator);
    try testing.expectEqual(Types.SourceOrigin.open_buffer, buffer_text.origin);
    try testing.expectEqualStrings(disk_text.text, buffer_text.text);

    var disk_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer disk_arena.deinit();
    var buffer_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer buffer_arena.deinit();

    const disk_shape = try nativeShape(&disk_handler, disk_arena.allocator(), disk_frag_uri);
    const buffer_shape = try nativeShape(&buffer_handler, buffer_arena.allocator(), buffer_frag_uri);
    try parity.expectEqualJson(disk_shape, buffer_shape);
}
