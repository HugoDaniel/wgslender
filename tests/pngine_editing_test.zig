//! Per-file editing views in pngine projects (pngine-shaders phase 04,
//! Task 5).
//!
//! The red-first contract:
//!   * semantic tokens classify a fragment's sibling references through the
//!     assembled analysis, but the emitted stream is lexed from and covers
//!     only the requested file's own bytes;
//!   * two roots that disagree on a token's classification contribute no
//!     token for that span; agreeing roots contribute one;
//!   * inlay hints are projected from every root to the requested origin,
//!     identical hints dedupe, disagreeing hints are omitted, and a
//!     whole-module size hint exists only when one root contains the file;
//!   * code actions built from mapped composed diagnostics are offered only
//!     when the whole edit maps to the requested file; edits into a sibling
//!     file or an inline `:code` part are withheld while the diagnostic
//!     itself remains published;
//!   * formatting a fragment that only parses in project context is exactly
//!     the standalone content-preserving result;
//!   * document symbols, folding ranges, selection ranges and document
//!     highlights stay scoped to the requested part; no assembled outline is
//!     synthesized.
//!
//! Every project test drives `Handler` and the in-memory `SourceProvider`
//! from `pngine_test_provider.zig`; no test reads project text from the host
//! filesystem.

const std = @import("std");
const Handler = @import("Handler");
const wgslender = @import("wgslender");
const PngineDiagnostics = Handler.PngineDiagnostics;
const provider_mod = @import("pngine_test_provider.zig");

const pngine = wgslender.Pngine;
const Types = pngine.Types;
const Store = pngine.Store;
const FakeProvider = provider_mod.FakeProvider;

const testing = std.testing;
const Position = Handler.Position;
const Range = Handler.Range;

// =========================================================================
// Shared fixture helpers
// =========================================================================

fn fileUri(buffer: []u8, path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "file://{s}", .{path});
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

fn wholeRange(source: []const u8) Range {
    return .{
        .start = .{ .line = 0, .character = 0 },
        .end = Handler.offsetToLspPosition(source, @intCast(source.len)) orelse unreachable,
    };
}

fn bindStore(fake: *FakeProvider, store: *Store, handler: *Handler) !void {
    store.* = Store.init(testing.allocator, fake.sourceProvider());
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);
    handler.* = Handler.init(testing.allocator);
    handler.setPngineStore(store);
}

fn applyJson(handler: *Handler, json: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    handler.applyClientConfig(parsed.value);
}

fn partFor(store: *Store, program: Types.ProgramId, name: []const u8) Types.PartId {
    const program_value = store.program(program) orelse unreachable;
    const index = program_value.findFragment(name) orelse unreachable;
    return .{ .program = program, .index = index };
}

fn membershipFor(store: *Store, path: []const u8) !Types.MembershipSet {
    var buffer: [512]u8 = undefined;
    return store.membershipsFor(try fileUri(&buffer, path));
}

fn rootFor(store: *Store, path: []const u8) !Types.PartId {
    var set = try membershipFor(store, path);
    defer set.deinit(testing.allocator);
    if (set.items.len == 0) return error.TestExpectedMembership;
    const membership = set.items[0];
    if (membership.containing_roots.len == 0) return error.TestExpectedRoot;
    return .{ .program = membership.program, .index = membership.containing_roots[0] };
}

const DecodedToken = struct {
    start: Position,
    end: Position,
    length: u32,
    token_type: u32,
    modifiers: u32,
    start_offset: usize,
    end_offset: usize,
};

/// Reconstruct the absolute positions of a delta-encoded semantic-token
/// stream and refuse any token whose range does not exist in `source`.
/// The fixtures are ASCII, so a token's `length` in UTF-16 units maps to
/// the same end position here.
fn decodeTokens(gpa: std.mem.Allocator, data: []const u32, source: []const u8) ![]DecodedToken {
    if (data.len % 5 != 0) return error.BadSemanticTokenData;
    var pm = try Handler.PositionMapper.init(gpa, source);
    defer pm.deinit(gpa);

    var out: std.ArrayList(DecodedToken) = .empty;
    errdefer out.deinit(gpa);

    var line: u32 = 0;
    var character: u32 = 0;
    var i: usize = 0;
    while (i < data.len) : (i += 5) {
        const delta_line = data[i];
        const delta_character = data[i + 1];
        const length = data[i + 2];
        const token_type = data[i + 3];
        const modifiers = data[i + 4];

        if (delta_line == 0) {
            character += delta_character;
        } else {
            line += delta_line;
            character = delta_character;
        }

        const start: Position = .{ .line = line, .character = character };
        const end: Position = .{ .line = line, .character = character + length };
        const start_offset = pm.offsetOf(start) orelse return error.TokenStartOutsideFile;
        const end_offset = pm.offsetOf(end) orelse return error.TokenEndOutsideFile;
        if (end_offset <= start_offset) return error.EmptyToken;
        if (end_offset > source.len) return error.TokenPastEndOfFile;

        try out.append(gpa, .{
            .start = start,
            .end = end,
            .length = length,
            .token_type = token_type,
            .modifiers = modifiers,
            .start_offset = start_offset,
            .end_offset = end_offset,
        });
    }
    return out.toOwnedSlice(gpa);
}

fn tokenAtOffset(tokens: []const DecodedToken, offset: u32) ?DecodedToken {
    for (tokens) |token| {
        if (token.start_offset == offset) return token;
    }
    return null;
}

fn expectSameTokenStream(actual: []const DecodedToken, expected: []const DecodedToken) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (actual, expected) |a, e| {
        try testing.expectEqual(e.start_offset, a.start_offset);
        try testing.expectEqual(e.end_offset, a.end_offset);
        try testing.expectEqual(e.token_type, a.token_type);
        try testing.expectEqual(e.modifiers, a.modifiers);
    }
}

fn freeSelectionChain(gpa: std.mem.Allocator, selection: ?*const Handler.SelectionRangeInfo) void {
    var current = selection;
    while (current) |node| {
        const parent = node.parent;
        gpa.destroy(@constCast(node));
        current = parent;
    }
}

fn standaloneTokens(gpa: std.mem.Allocator, source: []const u8) ![]u32 {
    var plain = Handler.init(gpa);
    defer plain.deinit();
    try plain.openDocument("test://fragment.wgsl", source, 1);
    return plain.computeSemanticTokens("test://fragment.wgsl");
}

// =========================================================================
// T5-1 — cross-part semantic-token classification, current file only.
// =========================================================================

const sem_program =
    \\(wgsl :name lib :file "lib.wgsl")
    \\(wgsl :name frag :file "frag.wgsl" :imports [lib])
    \\(shader-module :name root :file "root.wgsl" :imports [frag lib])
;

const sem_lib =
    \\struct LibData { value: f32 }
    \\const LIB_VALUE: f32 = 1.0;
    \\fn lib_helper() -> f32 { return LIB_VALUE; }
;

const sem_frag =
    \\fn frag_fn() -> f32 {
    \\  let data = LibData(1.0);
    \\  let value = LIB_VALUE;
    \\  return lib_helper() + value;
    \\}
;

const sem_root =
    \\@fragment fn fs_main() -> @location(0) vec4<f32> {
    \\  return vec4<f32>(frag_fn());
    \\}
;

test "T5-1 semantic tokens classify sibling declarations in local bytes only" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", sem_program);
    try fake.addFile("/ws/lib.wgsl", sem_lib);
    try fake.addFile("/ws/frag.wgsl", sem_frag);
    try fake.addFile("/ws/root.wgsl", sem_root);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var frag_buffer: [256]u8 = undefined;
    const frag_uri = try fileUri(&frag_buffer, "/ws/frag.wgsl");
    try handler.openDocument(frag_uri, sem_frag, 1);

    const data = try handler.computeSemanticTokens(frag_uri);
    defer testing.allocator.free(data);

    const composed = try decodeTokens(testing.allocator, data, sem_frag);
    defer testing.allocator.free(composed);

    const baseline_data = try standaloneTokens(testing.allocator, sem_frag);
    defer testing.allocator.free(baseline_data);
    const baseline = try decodeTokens(testing.allocator, baseline_data, sem_frag);
    defer testing.allocator.free(baseline);

    // Every baseline (local/lexical) token survives unchanged. The three
    // sibling references the standalone module cannot resolve are added;
    // nothing from the library's own text is ever emitted.
    try testing.expectEqual(baseline.len + 3, composed.len);
    for (baseline) |token| {
        const found = tokenAtOffset(composed, @intCast(token.start_offset)) orelse
            return error.MissingLocalToken;
        try testing.expectEqual(token.end_offset, found.end_offset);
        try testing.expectEqual(token.token_type, found.token_type);
        try testing.expectEqual(token.modifiers, found.modifiers);
    }

    const lib_data = tokenAtOffset(composed, offsetOf(sem_frag, "LibData", 0)) orelse
        return error.MissingStructToken;
    try testing.expectEqual(@as(u32, 2), lib_data.token_type); // struct
    try testing.expectEqual(@as(usize, "LibData".len), lib_data.end_offset - lib_data.start_offset);

    const lib_value = tokenAtOffset(composed, offsetOf(sem_frag, "LIB_VALUE", 0)) orelse
        return error.MissingConstToken;
    try testing.expectEqual(@as(u32, 4), lib_value.token_type); // variable
    try testing.expect(lib_value.modifiers & 2 != 0); // readonly
    try testing.expectEqual(@as(usize, "LIB_VALUE".len), lib_value.end_offset - lib_value.start_offset);

    const helper = tokenAtOffset(composed, offsetOf(sem_frag, "lib_helper", 0)) orelse
        return error.MissingFunctionToken;
    try testing.expectEqual(@as(u32, 1), helper.token_type); // function
    try testing.expectEqual(@as(usize, "lib_helper".len), helper.end_offset - helper.start_offset);
}

// =========================================================================
// T5-2 — conflicting roots contribute nothing; agreeing roots contribute one.
// =========================================================================

const sem_conflict_program =
    \\(wgsl :name sup_a :file "sup_a.wgsl")
    \\(wgsl :name sup_b :file "sup_b.wgsl")
    \\(wgsl :name frag :file "frag.wgsl")
    \\(shader-module :name root_a :file "root_a.wgsl" :imports [sup_a frag])
    \\(shader-module :name root_b :file "root_b.wgsl" :imports [sup_b frag])
;

const sem_conflict_frag = "fn frag_fn() -> f32 { return clash; }";

const sem_conflict_root_a =
    "@fragment fn fs_a() -> @location(0) vec4<f32> { return vec4<f32>(frag_fn()); }";
const sem_conflict_root_b =
    "@fragment fn fs_b() -> @location(0) vec4<f32> { return vec4<f32>(frag_fn()); }";

test "T5-2 conflicting root classifications omit the token; agreement keeps it" {
    // First: one root sees a function, the other a const.
    {
        var fake = FakeProvider.init(testing.allocator);
        defer fake.deinit();
        try fake.addFile("/ws/program.sjon", sem_conflict_program);
        try fake.addFile("/ws/sup_a.wgsl", "fn clash() -> f32 { return 1.0; }");
        try fake.addFile("/ws/sup_b.wgsl", "const clash: f32 = 2.0;");
        try fake.addFile("/ws/frag.wgsl", sem_conflict_frag);
        try fake.addFile("/ws/root_a.wgsl", sem_conflict_root_a);
        try fake.addFile("/ws/root_b.wgsl", sem_conflict_root_b);

        var store: Store = undefined;
        var handler: Handler = undefined;
        try bindStore(&fake, &store, &handler);
        defer handler.deinit();
        defer store.deinit();

        var frag_buffer: [256]u8 = undefined;
        const frag_uri = try fileUri(&frag_buffer, "/ws/frag.wgsl");
        try handler.openDocument(frag_uri, sem_conflict_frag, 1);

        const data = try handler.computeSemanticTokens(frag_uri);
        defer testing.allocator.free(data);
        const composed = try decodeTokens(testing.allocator, data, sem_conflict_frag);
        defer testing.allocator.free(composed);

        const baseline_data = try standaloneTokens(testing.allocator, sem_conflict_frag);
        defer testing.allocator.free(baseline_data);
        const baseline = try decodeTokens(testing.allocator, baseline_data, sem_conflict_frag);
        defer testing.allocator.free(baseline);

        // No agreement: the disagreement contributes no token at all. The
        // rule is not "first root wins".
        try expectSameTokenStream(composed, baseline);
        try testing.expect(tokenAtOffset(composed, offsetOf(sem_conflict_frag, "clash", 0)) == null);
    }

    // Second: both roots classify the same spelling as a function.
    {
        var fake = FakeProvider.init(testing.allocator);
        defer fake.deinit();
        try fake.addFile("/ws/program.sjon", sem_conflict_program);
        try fake.addFile("/ws/sup_a.wgsl", "fn clash() -> f32 { return 1.0; }");
        try fake.addFile("/ws/sup_b.wgsl", "fn clash() -> f32 { return 2.0; }");
        try fake.addFile("/ws/frag.wgsl", sem_conflict_frag);
        try fake.addFile("/ws/root_a.wgsl", sem_conflict_root_a);
        try fake.addFile("/ws/root_b.wgsl", sem_conflict_root_b);

        var store: Store = undefined;
        var handler: Handler = undefined;
        try bindStore(&fake, &store, &handler);
        defer handler.deinit();
        defer store.deinit();

        var frag_buffer: [256]u8 = undefined;
        const frag_uri = try fileUri(&frag_buffer, "/ws/frag.wgsl");
        try handler.openDocument(frag_uri, sem_conflict_frag, 1);

        const data = try handler.computeSemanticTokens(frag_uri);
        defer testing.allocator.free(data);
        const composed = try decodeTokens(testing.allocator, data, sem_conflict_frag);
        defer testing.allocator.free(composed);

        const baseline_data = try standaloneTokens(testing.allocator, sem_conflict_frag);
        defer testing.allocator.free(baseline_data);
        const baseline = try decodeTokens(testing.allocator, baseline_data, sem_conflict_frag);
        defer testing.allocator.free(baseline);

        try testing.expectEqual(baseline.len + 1, composed.len);
        const clash = tokenAtOffset(composed, offsetOf(sem_conflict_frag, "clash", 0)) orelse
            return error.MissingAgreedToken;
        try testing.expectEqual(@as(u32, 1), clash.token_type); // function
        try testing.expectEqual(@as(usize, "clash".len), clash.end_offset - clash.start_offset);
    }
}

// =========================================================================
// T5-3 — inlay hints: sibling provenance, dedupe, origin filtering.
// =========================================================================

const hint_program =
    \\(wgsl :name lib :file "lib.wgsl")
    \\(wgsl :name frag :file "frag.wgsl" :imports [lib])
    \\(shader-module :name root_a :file "root_a.wgsl" :imports [frag lib])
    \\(shader-module :name root_b :file "root_b.wgsl" :imports [frag lib])
;

const hint_lib =
    \\fn lib_noise() -> f32 {
    \\  let lib_local = 1.0;
    \\  return lib_local;
    \\}
    \\const LIB_VALUE: f32 = 2.0;
;

const hint_frag =
    \\fn frag_fn() -> f32 {
    \\  let x = LIB_VALUE;
    \\  return x;
    \\}
;

const hint_root_a =
    "@fragment fn fs_a() -> @location(0) vec4<f32> { return vec4<f32>(frag_fn()); }";
const hint_root_b =
    "@fragment fn fs_b() -> @location(0) vec4<f32> { return vec4<f32>(frag_fn()); }";

test "T5-3 inlay hints resolve through a sibling and dedupe across roots" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", hint_program);
    try fake.addFile("/ws/lib.wgsl", hint_lib);
    try fake.addFile("/ws/frag.wgsl", hint_frag);
    try fake.addFile("/ws/root_a.wgsl", hint_root_a);
    try fake.addFile("/ws/root_b.wgsl", hint_root_b);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();
    try applyJson(&handler, "{\"lsp\":{\"inlayHints\":{\"typeAnnotations\":true}}}");

    var frag_buffer: [256]u8 = undefined;
    const frag_uri = try fileUri(&frag_buffer, "/ws/frag.wgsl");
    try handler.openDocument(frag_uri, hint_frag, 1);

    const hints = try handler.computeInlayHints(frag_uri, wholeRange(hint_frag));
    defer testing.allocator.free(hints);

    const expected = positionOf(hint_frag, "x = LIB_VALUE", 1);
    var type_hints: usize = 0;
    var saw_sibling: bool = false;
    for (hints) |hint| {
        if (hint.kind != .type_hint) continue;
        type_hints += 1;
        if (hint.position.line == expected.line and hint.position.character == expected.character) {
            try testing.expectEqualStrings("f32", hint.label);
            saw_sibling = true;
        }
    }

    // Both roots infer the same hint; it is one item, not two. The library's
    // own `lib_local` hint is filtered out because it is not in this file.
    try testing.expectEqual(@as(usize, 1), type_hints);
    try testing.expect(saw_sibling);

    for (hints) |hint| {
        const offset = Handler.lspPositionToOffset(hint_frag, hint.position) orelse
            return error.HintOutsideFile;
        try testing.expect(offset <= hint_frag.len);
    }
}

// =========================================================================
// T5-3b — conflicting root types omit the hint; compatible answers remain.
// =========================================================================

const hint_conflict_program =
    \\(wgsl :name sup_a :file "sup_a.wgsl")
    \\(wgsl :name sup_b :file "sup_b.wgsl")
    \\(wgsl :name frag :file "frag.wgsl")
    \\(shader-module :name root_a :file "root_a.wgsl" :imports [sup_a frag])
    \\(shader-module :name root_b :file "root_b.wgsl" :imports [sup_b frag])
;

const hint_conflict_frag =
    \\fn frag_fn() -> f32 {
    \\  let conflict = LIB_VALUE;
    \\  let agreed = SHARED;
    \\  return agreed;
    \\}
;

test "T5-3b conflicting inlay types are omitted; agreed hints remain" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", hint_conflict_program);
    try fake.addFile("/ws/sup_a.wgsl", "const LIB_VALUE: f32 = 1.0;\nconst SHARED: f32 = 3.0;");
    try fake.addFile("/ws/sup_b.wgsl", "const LIB_VALUE: vec2<f32> = vec2<f32>(1.0, 2.0);\nconst SHARED: f32 = 3.0;");
    try fake.addFile("/ws/frag.wgsl", hint_conflict_frag);
    try fake.addFile("/ws/root_a.wgsl", sem_conflict_root_a);
    try fake.addFile("/ws/root_b.wgsl", sem_conflict_root_b);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();
    try applyJson(&handler, "{\"lsp\":{\"inlayHints\":{\"typeAnnotations\":true}}}");

    var frag_buffer: [256]u8 = undefined;
    const frag_uri = try fileUri(&frag_buffer, "/ws/frag.wgsl");
    try handler.openDocument(frag_uri, hint_conflict_frag, 1);

    const hints = try handler.computeInlayHints(frag_uri, wholeRange(hint_conflict_frag));
    defer testing.allocator.free(hints);

    const conflict_pos = positionOf(hint_conflict_frag, "conflict =", 8);
    const agreed_pos = positionOf(hint_conflict_frag, "agreed =", 6);
    var type_hints: usize = 0;
    var saw_agreed: bool = false;
    for (hints) |hint| {
        if (hint.kind != .type_hint) continue;
        type_hints += 1;
        try testing.expect(!(hint.position.line == conflict_pos.line and
            hint.position.character == conflict_pos.character));
        if (hint.position.line == agreed_pos.line and
            hint.position.character == agreed_pos.character)
        {
            try testing.expectEqualStrings("f32", hint.label);
            saw_agreed = true;
        }
    }
    try testing.expectEqual(@as(usize, 1), type_hints);
    try testing.expect(saw_agreed);
}

// =========================================================================
// T5-3c — a module-size hint needs one unambiguous root (M0500 boundary).
// =========================================================================

test "T5-3c module-size inlay hint appears only for one containing root" {
    // One root: the whole assembled module is unambiguous.
    {
        var fake = FakeProvider.init(testing.allocator);
        defer fake.deinit();
        try fake.addFile("/ws/program.sjon",
            \\(wgsl :name lib :file "lib.wgsl")
            \\(wgsl :name frag :file "frag.wgsl" :imports [lib])
            \\(shader-module :name root :file "root.wgsl" :imports [frag lib])
        );
        try fake.addFile("/ws/lib.wgsl", hint_lib);
        try fake.addFile("/ws/frag.wgsl", hint_frag);
        try fake.addFile("/ws/root.wgsl", sem_root);

        var store: Store = undefined;
        var handler: Handler = undefined;
        try bindStore(&fake, &store, &handler);
        defer handler.deinit();
        defer store.deinit();
        try applyJson(&handler, "{\"lsp\":{\"minifyMode\":\"insights\"}}");

        var frag_buffer: [256]u8 = undefined;
        const frag_uri = try fileUri(&frag_buffer, "/ws/frag.wgsl");
        try handler.openDocument(frag_uri, hint_frag, 1);

        const hints = try handler.computeInlayHints(frag_uri, wholeRange(hint_frag));
        defer testing.allocator.free(hints);

        var saw_total = false;
        for (hints) |hint| {
            if (hint.kind != .minify_size) continue;
            if (hint.position.line == 0 and hint.position.character == 0) saw_total = true;
        }
        try testing.expect(saw_total);
    }

    // Two roots: no root's byte count is a property of the shared fragment.
    {
        var fake = FakeProvider.init(testing.allocator);
        defer fake.deinit();
        try fake.addFile("/ws/program.sjon", hint_program);
        try fake.addFile("/ws/lib.wgsl", hint_lib);
        try fake.addFile("/ws/frag.wgsl", hint_frag);
        try fake.addFile("/ws/root_a.wgsl", hint_root_a);
        try fake.addFile("/ws/root_b.wgsl", hint_root_b);

        var store: Store = undefined;
        var handler: Handler = undefined;
        try bindStore(&fake, &store, &handler);
        defer handler.deinit();
        defer store.deinit();
        try applyJson(&handler, "{\"lsp\":{\"minifyMode\":\"insights\"}}");

        var frag_buffer: [256]u8 = undefined;
        const frag_uri = try fileUri(&frag_buffer, "/ws/frag.wgsl");
        try handler.openDocument(frag_uri, hint_frag, 1);

        const hints = try handler.computeInlayHints(frag_uri, wholeRange(hint_frag));
        defer testing.allocator.free(hints);

        for (hints) |hint| {
            if (hint.kind != .minify_size) continue;
            try testing.expect(!(hint.position.line == 0 and hint.position.character == 0));
        }
    }
}

// =========================================================================
// T5-4 — code actions from mapped composed diagnostics.
// =========================================================================

const action_program =
    \\(wgsl :name lib :file "lib.wgsl")
    \\(wgsl :name inlinepart :code "fn inline_fn() -> f32 { return 1.0; }")
    \\(wgsl :name use :file "use.wgsl" :imports [lib inlinepart])
    \\(shader-module :name root :file "root.wgsl" :imports [use])
;

const action_lib = "fn lib_value() -> f32 { return 1.0; }";
const action_inline = "fn inline_fn() -> f32 { return 1.0; }";
const action_use = "fn use_value() -> f32 { return lib_value() + inline_fn(); }";
const action_root =
    "@fragment fn fs_main() -> @location(0) vec4<f32> { return vec4<f32>(use_value()); }";

fn findMessage(diags: []const Handler.LspDiagnostic, needle: []const u8) ?Handler.LspDiagnostic {
    for (diags) |diag| {
        if (std.mem.indexOf(u8, diag.message, needle) != null) return diag;
    }
    return null;
}

fn assembledDiagRange(assembled: *const pngine.Assembled, origin: Types.PartId, start: u32, end: u32) wgslender.Diagnostic.Range {
    const mapped = assembled.fromOrigin(origin, .{ .start = start, .end = end }) orelse unreachable;
    return .{
        .start = .{ .offset = mapped.start },
        .end = .{ .offset = mapped.end },
    };
}

test "T5-4 composed quick fixes are offered only when the whole edit is local" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", action_program);
    try fake.addFile("/ws/lib.wgsl", action_lib);
    try fake.addFile("/ws/use.wgsl", action_use);
    try fake.addFile("/ws/root.wgsl", action_root);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var use_buffer: [256]u8 = undefined;
    const use_uri = try fileUri(&use_buffer, "/ws/use.wgsl");
    try handler.openDocument(use_uri, action_use, 1);

    var set = try membershipFor(&store, "/ws/use.wgsl");
    defer set.deinit(testing.allocator);
    const program_id = set.items[0].program;
    const root = try rootFor(&store, "/ws/use.wgsl");
    const analysis = try handler.analyzeRoot(root);

    const use_part = partFor(&store, program_id, "use");
    const lib_part = partFor(&store, program_id, "lib");
    const inline_part = partFor(&store, program_id, "inlinepart");

    const primary_start = offsetOf(action_use, "use_value", 0);
    const primary_end = primary_start + @as(u32, "use_value".len);
    const primary = assembledDiagRange(analysis.assembled, use_part, primary_start, primary_end);

    const safe_start = offsetOf(action_use, "return", 0);
    const safe_end = safe_start + @as(u32, "return".len);
    const safe_fix = wgslender.Diagnostic.Fix{
        .range = assembledDiagRange(analysis.assembled, use_part, safe_start, safe_end),
        .text = "SAFE",
    };
    const cross_fix = wgslender.Diagnostic.Fix{
        .range = assembledDiagRange(analysis.assembled, lib_part, 0, 1),
        .text = "CROSS",
    };
    const inline_fix = wgslender.Diagnostic.Fix{
        .range = assembledDiagRange(analysis.assembled, inline_part, 0, 1),
        .text = "INLINE",
    };

    const entries = [_]wgslender.Diagnostic.Entry{
        .{ .code = "W0001", .message = "local fix", .range = primary, .fix = &safe_fix },
        .{ .code = "W0001", .message = "cross-origin fix", .range = primary, .fix = &cross_fix },
        .{ .code = "W0001", .message = "inline fix", .range = primary, .fix = &inline_fix },
    };

    var report = PngineDiagnostics.Report.init(testing.allocator, &store, use_uri, set.items);
    defer report.deinit();
    for (&entries) |*entry| try report.add(analysis.assembled, entry);

    const diags = try report.finish();
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 3), diags.len);
    const safe_diag = findMessage(diags, "local fix") orelse return error.MissingSafeDiagnostic;
    try testing.expect(safe_diag.data == .lint_fix);
    const cross_diag = findMessage(diags, "cross-origin fix") orelse
        return error.MissingCrossDiagnostic;
    try testing.expect(cross_diag.data == .none);
    const inline_diag = findMessage(diags, "inline fix") orelse
        return error.MissingInlineDiagnostic;
    try testing.expect(inline_diag.data == .none);

    const actions = try handler.computeCodeActions(diags);
    defer Handler.freeCodeActions(testing.allocator, actions);

    try testing.expectEqual(@as(usize, 1), actions.len);
    try testing.expectEqualStrings("Apply autofix (W0001)", actions[0].title);
    try testing.expectEqual(@as(usize, 1), actions[0].edits.len);
    try testing.expectEqualStrings("SAFE", actions[0].edits[0].new_text);
    try testing.expectEqualDeep(
        Handler.offsetRangeToLspRange(action_use, safe_start, safe_end).?,
        actions[0].edits[0].range,
    );

    // A derived (non-`.lint_fix`) quick fix must read the requested file's
    // text, not whichever document happens to be first in the map. A decoy
    // document makes the old "first open document" selection observable.
    try handler.openDocument("test://decoy.wgsl", "let wrong = 1.0 + 2.0;", 1);
    const cast_start = offsetOf(action_use, "lib_value", 0);
    const cast_end = cast_start + @as(u32, "lib_value()".len);
    const cast_diag = Handler.LspDiagnostic{
        .range = Handler.offsetRangeToLspRange(action_use, cast_start, cast_end).?,
        .severity = .@"error",
        .message = "cannot assign 'f32' to 'i32'",
        .code = "E0200",
        .data = .{ .type_mismatch = .{ .actual = "f32", .expected = "i32" } },
    };
    const cast_actions = try handler.computeCodeActionsForDocument(use_uri, &.{cast_diag});
    defer Handler.freeCodeActions(testing.allocator, cast_actions);
    try testing.expectEqual(@as(usize, 1), cast_actions.len);
    try testing.expectEqualStrings("i32(lib_value())", cast_actions[0].edits[0].new_text);
}

// =========================================================================
// T5-5 — formatting boundary: current buffer, content-preserving path.
// =========================================================================

const edit_program =
    \\(wgsl :name lib :file "lib.wgsl")
    \\(wgsl :name frag :file "frag.wgsl" :imports [lib])
    \\(shader-module :name root :file "root.wgsl" :imports [frag lib])
;

const edit_lib = "const LIB_VALUE: f32 = 1.0;\nfn lib_helper() -> f32 { return LIB_VALUE; }\n";
const edit_frag =
    \\fn frag_fn() -> f32 {
    \\    let x = lib_helper();
    \\    return x + LIB_VALUE;
    \\}
;
const edit_root =
    "@fragment fn fs_main() -> @location(0) vec4<f32> { return vec4<f32>(frag_fn()); }";

test "T5-5 formatting a fragment with sibling holes matches the standalone result" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", edit_program);
    try fake.addFile("/ws/lib.wgsl", edit_lib);
    try fake.addFile("/ws/frag.wgsl", edit_frag);
    try fake.addFile("/ws/root.wgsl", edit_root);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var frag_buffer: [256]u8 = undefined;
    const frag_uri = try fileUri(&frag_buffer, "/ws/frag.wgsl");
    try handler.openDocument(frag_uri, edit_frag, 1);

    const composed_edit = (try handler.computeFormatting(frag_uri)) orelse
        return error.MissingComposedFormatting;
    defer testing.allocator.free(composed_edit.new_text);

    var plain = Handler.init(testing.allocator);
    defer plain.deinit();
    try plain.openDocument("test://frag.wgsl", edit_frag, 1);
    const standalone_edit = (try plain.computeFormatting("test://frag.wgsl")) orelse
        return error.MissingStandaloneFormatting;
    defer testing.allocator.free(standalone_edit.new_text);

    try testing.expectEqualStrings(standalone_edit.new_text, composed_edit.new_text);
    try testing.expectEqualDeep(standalone_edit.range, composed_edit.range);
    try testing.expect(std.mem.indexOf(u8, composed_edit.new_text, "LIB_VALUE") != null);
    try testing.expect(std.mem.indexOf(u8, composed_edit.new_text, "frag_fn") != null);
}

// =========================================================================
// T5-6 — outlines, folding, selection and highlights stay local.
// =========================================================================

const local_frag_highlight =
    \\fn frag_fn() -> f32 {
    \\  return lib_helper() + lib_helper();
    \\}
;

test "T5-6 document symbols, folding, selection and highlights stay local" {
    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", edit_program);
    try fake.addFile("/ws/lib.wgsl", edit_lib);
    try fake.addFile("/ws/frag.wgsl", local_frag_highlight);
    try fake.addFile("/ws/root.wgsl", edit_root);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var frag_buffer: [256]u8 = undefined;
    const frag_uri = try fileUri(&frag_buffer, "/ws/frag.wgsl");
    try handler.openDocument(frag_uri, local_frag_highlight, 1);

    const symbols = try handler.computeDocumentSymbols(frag_uri);
    defer testing.allocator.free(symbols);
    try testing.expectEqual(@as(usize, 1), symbols.len);
    try testing.expectEqualStrings("frag_fn", symbols[0].name);

    var plain = Handler.init(testing.allocator);
    defer plain.deinit();
    try plain.openDocument("test://frag.wgsl", local_frag_highlight, 1);

    const folding = try handler.computeFoldingRanges(frag_uri);
    defer testing.allocator.free(folding);
    const standalone_folding = try plain.computeFoldingRanges("test://frag.wgsl");
    defer testing.allocator.free(standalone_folding);
    try testing.expectEqual(standalone_folding.len, folding.len);
    for (folding, standalone_folding) |a, e| {
        try testing.expectEqual(e.start_line, a.start_line);
        try testing.expectEqual(e.end_line, a.end_line);
        try testing.expectEqual(e.kind, a.kind);
    }

    const selection = (try handler.computeSelectionRange(
        frag_uri,
        positionOf(local_frag_highlight, "lib_helper", 2),
    )) orelse return error.MissingSelection;
    defer freeSelectionChain(testing.allocator, selection);
    const file_end = Handler.offsetToLspPosition(
        local_frag_highlight,
        @intCast(local_frag_highlight.len),
    ) orelse unreachable;
    var node: ?*const Handler.SelectionRangeInfo = selection;
    var outermost: Range = selection.range;
    while (node) |current| {
        outermost = current.range;
        node = current.parent;
    }
    try testing.expectEqualDeep(
        Range{ .start = .{ .line = 0, .character = 0 }, .end = file_end },
        outermost,
    );

    const highlights = (try handler.computeDocumentHighlight(
        frag_uri,
        positionOf(local_frag_highlight, "lib_helper", 2),
    )) orelse return error.MissingHighlights;
    defer testing.allocator.free(highlights);
    try testing.expectEqual(@as(usize, 2), highlights.len);
    for (highlights) |highlight| {
        const offset = Handler.lspPositionToOffset(local_frag_highlight, highlight.range.start) orelse
            return error.HighlightOutsideFile;
        const end = Handler.lspPositionToOffset(local_frag_highlight, highlight.range.end) orelse
            return error.HighlightOutsideFile;
        try testing.expect(end <= local_frag_highlight.len);
        try testing.expect(offset < end);
    }
}
