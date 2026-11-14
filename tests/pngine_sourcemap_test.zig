//! Author-origin source maps for composed pngine minification
//! (pngine-shaders phase 05, Task 4).
//!
//! The contract these reds pin:
//!   * the minifier's assembled map is translated through the phase-02
//!     segments, not rescanned, so `sources[]` names the author files and
//!     each mapping's source position is author-local;
//!   * a mapping on the hoisted copy of a directive resolves to the line
//!     the author wrote it on (the hoisted copy is the semantic one);
//!   * generated positions and `names[]` survive byte-for-byte;
//!   * an inline `:code` part becomes its stable `wgslender-pngine://`
//!     virtual URI and `sourcesContent[]` aligns when requested;
//!   * CRLF and non-ASCII lines report the author's UTF-16 column;
//!   * no mappings yields a valid empty map, and a mapping with no honest
//!     author origin is dropped with one report-level warning naming the
//!     root.
//!
//! Remap-level tests build the assembled unit through the real phase-02
//! assembler, so hoisted/blanked segments come from production code. The
//! artifact tests drive the real Store + `PngineArtifacts` pipeline.

const std = @import("std");
const wgslender = @import("wgslender");
const selection = @import("PngineSelection");
const artifacts = @import("PngineArtifacts");
const provider_mod = @import("pngine_test_provider.zig");

const pngine = wgslender.Pngine;
const SourceMap = wgslender.SourceMap;
const SourceMaps = pngine.SourceMaps;
const Types = pngine.Types;
const Store = selection.Store;
const FakeProvider = provider_mod.FakeProvider;
const testing = std.testing;

const Allocator = std.mem.Allocator;

// =========================================================================
// Fixtures
// =========================================================================

const File = struct {
    path: []const u8,
    text: []const u8,
};

/// In-memory project Store, as `tests/pngine_artifacts_test.zig` builds it.
const StoreFixture = struct {
    fake: FakeProvider,
    store: Store,

    fn init(self: *StoreFixture, program: []const u8, files: []const File) !void {
        self.fake = FakeProvider.init(testing.allocator);
        errdefer self.fake.deinit();
        try self.fake.addFile("/ws/sm/program.sjon", program);
        for (files) |file| try self.fake.addFile(file.path, file.text);
        self.store = Store.init(testing.allocator, self.fake.sourceProvider());
    }

    fn deinit(self: *StoreFixture) void {
        self.store.deinit();
        self.fake.deinit();
    }

    fn select(self: *StoreFixture, input: []const u8, root: ?[]const u8) !selection.ProjectSelection {
        return selection.selectProjectWithFailure(&self.store, input, null, root, false, null);
    }

    fn selectExplicit(self: *StoreFixture, root: ?[]const u8) !selection.ProjectSelection {
        return selection.selectProjectWithFailure(&self.store, null, "/ws/sm/program.sjon", root, false, null);
    }
};

/// A Program whose parts are inline, so assembly needs no Store. The
/// assembled rows/segments are still the production assembler's.
const AssemblyFixture = struct {
    arena: std.heap.ArenaAllocator,
    parts: std.ArrayList(Types.Part) = .empty,
    sources: std.ArrayList(?[]const u8) = .empty,
    roots: std.ArrayList(u32) = .empty,

    fn init(backing: Allocator) AssemblyFixture {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    fn deinit(self: *AssemblyFixture) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn add(
        self: *AssemblyFixture,
        kind: Types.PartKind,
        name: []const u8,
        text: []const u8,
        imports: []const []const u8,
    ) !u32 {
        const a = self.arena.allocator();
        const refs = try a.alloc(Types.ImportRef, imports.len);
        for (imports, 0..) |import_name, i| {
            refs[i] = .{
                .name = import_name,
                .span = .{ .start = 0, .end = @intCast(import_name.len) },
            };
        }
        const index: u32 = @intCast(self.parts.items.len);
        try self.parts.append(a, .{
            .kind = kind,
            .name = name,
            .name_span = .{ .start = 0, .end = @intCast(name.len) },
            .form_span = .{ .start = 0, .end = 0 },
            .origin = .{ .inline_code = .{
                .code = text,
                .span = .{ .start = 0, .end = @intCast(text.len) },
            } },
            .imports = refs,
        });
        try self.sources.append(a, text);
        if (kind != .wgsl) try self.roots.append(a, index);
        return index;
    }

    fn program(self: *const AssemblyFixture) Types.Program {
        return .{
            .document_path = "/ws/sm/program.sjon",
            .parts = self.parts.items,
            .roots = self.roots.items,
            .diagnostics = &.{},
        };
    }

    fn assemble(self: *AssemblyFixture, root_index: u32) !pngine.Assembled {
        var program_value = self.program();
        return pngine.Assemble.assemble(
            self.arena.allocator(),
            &program_value,
            self.sources.items,
            .{ .program = 7, .index = root_index },
            null,
        );
    }
};

/// A minifier-shaped input map over assembled text: generated positions are
/// synthetic (the translation must not care), source positions are real
/// byte offsets in `text`.
const InputMap = struct {
    gen: SourceMap.Generator,
    map: SourceMap.Result,

    const Entry = struct {
        gen_line: u32,
        gen_col: u32,
        offset: u32,
        name: []const u8 = "",
    };

    fn init(allocator: Allocator, text: []const u8, entries: []const Entry) !InputMap {
        var gen = try SourceMap.Generator.init(allocator, text);
        errdefer gen.deinit();
        gen.setSourceName("assembled");
        gen.setCoverLinesWithoutMappings(false);
        for (entries) |entry| {
            try gen.addMapping(entry.gen_line, entry.gen_col, entry.offset, entry.name);
        }
        const map = try gen.generate();
        return .{ .gen = gen, .map = map };
    }

    fn deinit(self: *InputMap) void {
        self.gen.deinit();
        self.* = undefined;
    }
};

fn offsetOf(haystack: []const u8, needle: []const u8) !u32 {
    const index = std.mem.indexOf(u8, haystack, needle) orelse return error.NeedleNotFound;
    return @intCast(index);
}

/// Inverse of `SourceMap.LineIndex.byteOffsetToLineColumnUtf16`, used to
/// prove a decoded mapping lands on the author's bytes.
fn byteOffsetForUtf16Column(text: []const u8, line_index: *const SourceMap.LineIndex, line: u32, col: u32) u32 {
    const starts = line_index.line_starts.items;
    if (starts.len == 0) return 0;
    const clamped_line: u32 = if (line >= starts.len) @intCast(starts.len - 1) else line;
    var i: usize = starts[clamped_line];
    var units: u32 = 0;
    while (i < text.len and units < col) {
        const byte = text[i];
        if (byte == '\n' or byte == '\r') break;
        const len = std.unicode.utf8ByteSequenceLength(byte) catch {
            i += 1;
            units += 1;
            continue;
        };
        if (i + len > text.len) break;
        const cp = std.unicode.utf8Decode(text[i..][0..len]) catch {
            i += 1;
            units += 1;
            continue;
        };
        const width: u32 = if (cp >= 0x10000) 2 else 1;
        if (units + width > col) break;
        units += width;
        i += len;
    }
    return @intCast(i);
}

fn sourceIndexByName(map: *const SourceMap.Result, name: []const u8) ?u32 {
    for (map.sources, 0..) |source, index| {
        if (std.mem.eql(u8, source, name)) return @intCast(index);
    }
    return null;
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected text to contain '{s}'\n--- text ---\n{s}\n", .{ needle, haystack });
        return error.TestExpectedText;
    }
}

fn mapJson(allocator: Allocator, map: *const SourceMap.Result) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try map.toJson(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

// =========================================================================
// 1. Multiple sources: author files, author-local mappings.
// =========================================================================

test "composed minification lists every author file and maps into them" {
    var fixture: StoreFixture = undefined;
    try fixture.init(
        \\(wgsl :name lib :file "lib.wgsl")
        \\(wgsl :name mid :file "mid.wgsl" :imports [lib])
        \\(shader-module :name main :file "root.wgsl" :imports [mid])
    ,
        &.{
            .{ .path = "/ws/sm/lib.wgsl", .text = "fn lib_helper() -> f32 { return 1.0; }\n" },
            .{ .path = "/ws/sm/mid.wgsl", .text = "fn mid_helper() -> f32 { return lib_helper() + 1.0; }\n" },
            .{ .path = "/ws/sm/root.wgsl", .text = "fn fs() -> f32 { return mid_helper(); }\n" },
        },
    );
    defer fixture.deinit();

    var selected = try fixture.select("/ws/sm/root.wgsl", "main");
    defer selected.deinit(testing.allocator);

    var map_options = wgslender.Minifier.defaultOptions();
    map_options.generate_source_map = true;
    map_options.source_map_options = .{
        .source_name = "root.wgsl",
        .file = "root.min.wgsl",
        .include_source = true,
    };

    var result = try artifacts.run(
        testing.allocator,
        &fixture.store,
        &selected,
        "/ws/sm/root.wgsl",
        .minify,
        .{ .minify_options = map_options },
    );
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expect(result.source_map != null);
    const map = &result.source_map.?;

    try testing.expectEqualStrings("root.min.wgsl", map.file);
    try testing.expectEqual(@as(usize, 3), map.sources.len);
    for ([_][]const u8{ "lib.wgsl", "mid.wgsl", "root.wgsl" }) |name| {
        try testing.expect(sourceIndexByName(map, name) != null);
    }
    try testing.expectEqual(@as(usize, 3), map.sources_content.len);

    var decoded = try SourceMap.decodeMappings(testing.allocator, map.mappings);
    defer decoded.deinit();
    try testing.expect(decoded.items.len > 0);

    var seen = [_]bool{false} ** 3;
    for (decoded.items) |mapping| {
        try testing.expect(mapping.src_index < 3);
        seen[mapping.src_index] = true;

        const source_name = map.sources[mapping.src_index];
        const source_content = switch (mapping.src_index) {
            0 => "fn lib_helper() -> f32 { return 1.0; }\n",
            1 => "fn mid_helper() -> f32 { return lib_helper() + 1.0; }\n",
            else => "fn fs() -> f32 { return mid_helper(); }\n",
        };
        var line_index = try SourceMap.LineIndex.init(testing.allocator, source_content);
        defer line_index.deinit(testing.allocator);
        const offset = byteOffsetForUtf16Column(
            source_content,
            &line_index,
            mapping.src_line,
            mapping.src_col,
        );
        try testing.expect(offset < source_content.len);
        const byte = source_content[offset];
        try testing.expect(byte == '_' or std.ascii.isAlphabetic(byte));

        // The root is written after two imported parts in assembled text;
        // its author line is 0. A map left in assembled coordinates would
        // report a later line here.
        if (std.mem.eql(u8, source_name, "root.wgsl")) {
            try testing.expectEqual(@as(u32, 0), mapping.src_line);
        }
    }
    try testing.expect(seen[0] and seen[1] and seen[2]);
}

// =========================================================================
// 2. Hoisted directives map to the author's directive line.
// =========================================================================

test "a mapping on hoisted directive text resolves to the author line" {
    const fragment =
        "enable f16;\n" ++
        "fn helper() -> f16 { return f16(1.0); }\n";
    const root = "fn main() -> f16 { return helper(); }\n";

    var fixture: AssemblyFixture = .init(testing.allocator);
    defer fixture.deinit();
    _ = try fixture.add(.wgsl, "frag", fragment, &.{});
    const root_index = try fixture.add(.shader_module, "main", root, &.{"frag"});

    var assembled = try fixture.assemble(root_index);
    defer assembled.deinit(fixture.arena.allocator());

    var saw_hoisted = false;
    for (assembled.segments) |segment| {
        if (segment.kind == .hoisted) saw_hoisted = true;
    }
    try testing.expect(saw_hoisted);

    // The hoisted block starts assembled line 1 with the author's bytes.
    try testing.expect(std.mem.startsWith(u8, assembled.text, "enable f16;\n"));
    const hoisted_offset = try offsetOf(assembled.text, "f16;");

    var input = try InputMap.init(testing.allocator, assembled.text, &.{
        .{ .gen_line = 0, .gen_col = 0, .offset = hoisted_offset },
    });
    defer input.deinit();

    var sources = [_]SourceMaps.Source{
        .{ .origin = .{ .program = 7, .index = 0 }, .name = "frag.wgsl", .content = fragment },
        .{ .origin = .{ .program = 7, .index = root_index }, .name = "root.wgsl", .content = root },
    };
    var remapped = try SourceMaps.remap(
        testing.allocator,
        &assembled,
        &sources,
        &input.map,
        .{},
    );
    defer remapped.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 0), remapped.dropped);
    try testing.expectEqual(@as(usize, 1), remapped.map.sources.len);
    try testing.expectEqualStrings("frag.wgsl", remapped.map.sources[0]);

    var decoded = try SourceMap.decodeMappings(testing.allocator, remapped.map.mappings);
    defer decoded.deinit();
    try testing.expectEqual(@as(usize, 1), decoded.items.len);
    const mapping = decoded.items[0];
    try testing.expectEqual(@as(u32, 0), mapping.src_line);
    try testing.expectEqual(@as(u32, hoisted_offset), mapping.src_col);
    try testing.expectEqual(hoisted_offset, try offsetOf(fragment, "f16;"));
}

// =========================================================================
// 3. Names survive with consistent indices.
// =========================================================================

test "names are preserved and their indices stay consistent" {
    const text = "fn foo() -> f32 { let x = foo(); return x; }\n";

    var fixture: AssemblyFixture = .init(testing.allocator);
    defer fixture.deinit();
    const root_index = try fixture.add(.shader_module, "main", text, &.{});

    var assembled = try fixture.assemble(root_index);
    defer assembled.deinit(fixture.arena.allocator());

    const foo_offset = try offsetOf(assembled.text, "foo");
    const x_offset = try offsetOf(assembled.text, "x =");

    var input = try InputMap.init(testing.allocator, assembled.text, &.{
        .{ .gen_line = 0, .gen_col = 0, .offset = foo_offset, .name = "foo" },
        .{ .gen_line = 0, .gen_col = 5, .offset = x_offset, .name = "x" },
    });
    defer input.deinit();
    try testing.expectEqual(@as(usize, 2), input.map.names.len);

    var sources = [_]SourceMaps.Source{
        .{ .origin = .{ .program = 7, .index = root_index }, .name = "main.wgsl", .content = text },
    };
    var remapped = try SourceMaps.remap(
        testing.allocator,
        &assembled,
        &sources,
        &input.map,
        .{},
    );
    defer remapped.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), remapped.map.names.len);
    try testing.expectEqualStrings("foo", remapped.map.names[0]);
    try testing.expectEqualStrings("x", remapped.map.names[1]);

    var decoded = try SourceMap.decodeMappings(testing.allocator, remapped.map.mappings);
    defer decoded.deinit();
    try testing.expectEqual(@as(usize, 2), decoded.items.len);
    try testing.expect(decoded.items[0].has_name);
    try testing.expectEqual(@as(i32, 0), decoded.items[0].name_index);
    try testing.expect(decoded.items[1].has_name);
    try testing.expectEqual(@as(i32, 1), decoded.items[1].name_index);
    try testing.expectEqualStrings("foo", remapped.map.names[@intCast(decoded.items[0].name_index)]);
    try testing.expectEqualStrings("x", remapped.map.names[@intCast(decoded.items[1].name_index)]);
}

// =========================================================================
// 4. Inline `:code` becomes a stable virtual URI with aligned content.
// =========================================================================

test "an inline root maps to its virtual URI and sourcesContent follows the flag" {
    const code = "fn inline_root() -> f32 { return 1.0; }";
    var fixture: StoreFixture = undefined;
    try fixture.init(
        \\(shader-module :name main :code "fn inline_root() -> f32 { return 1.0; }")
    ,
        &.{},
    );
    defer fixture.deinit();

    var selected = try fixture.selectExplicit("main");
    defer selected.deinit(testing.allocator);

    const expected_uri = try pngine.VirtualUri.encode(
        testing.allocator,
        "/ws/sm/program.sjon",
        0,
        Types.contentHash(code),
    );
    defer testing.allocator.free(expected_uri);

    inline for (.{ true, false }) |include_source| {
        var map_options = wgslender.Minifier.defaultOptions();
        map_options.generate_source_map = true;
        map_options.source_map_options.include_source = include_source;

        var result = try artifacts.run(
            testing.allocator,
            &fixture.store,
            &selected,
            null,
            .minify,
            .{ .minify_options = map_options },
        );
        defer result.deinit(testing.allocator);

        try testing.expectEqual(@as(u8, 0), result.exit_code);
        const map = &result.source_map.?;
        try testing.expectEqual(@as(usize, 1), map.sources.len);
        try testing.expectEqualStrings(expected_uri, map.sources[0]);

        if (include_source) {
            try testing.expectEqual(@as(usize, 1), map.sources_content.len);
            try testing.expectEqualStrings(code, map.sources_content[0]);
        } else {
            try testing.expectEqual(@as(usize, 0), map.sources_content.len);
        }
    }
}

// =========================================================================
// 5. CRLF and UTF-16 columns.
// =========================================================================

test "CRLF and non-ASCII lines report the author's UTF-16 column" {
    const crlf = "/* 😀 */ fn abc() {}\r\nfn def() {}\r\n";
    const root = "fn main() {}\n";

    var fixture: AssemblyFixture = .init(testing.allocator);
    defer fixture.deinit();
    _ = try fixture.add(.wgsl, "crlf", crlf, &.{});
    const root_index = try fixture.add(.shader_module, "main", root, &.{"crlf"});

    var assembled = try fixture.assemble(root_index);
    defer assembled.deinit(fixture.arena.allocator());

    const abc_offset = try offsetOf(assembled.text, "abc");
    const def_offset = try offsetOf(assembled.text, "def");

    var input = try InputMap.init(testing.allocator, assembled.text, &.{
        .{ .gen_line = 0, .gen_col = 0, .offset = abc_offset },
        .{ .gen_line = 1, .gen_col = 0, .offset = def_offset },
    });
    defer input.deinit();

    var sources = [_]SourceMaps.Source{
        .{ .origin = .{ .program = 7, .index = 0 }, .name = "crlf.wgsl", .content = crlf },
        .{ .origin = .{ .program = 7, .index = root_index }, .name = "root.wgsl", .content = root },
    };
    var remapped = try SourceMaps.remap(
        testing.allocator,
        &assembled,
        &sources,
        &input.map,
        .{},
    );
    defer remapped.deinit(testing.allocator);

    var decoded = try SourceMap.decodeMappings(testing.allocator, remapped.map.mappings);
    defer decoded.deinit();
    try testing.expectEqual(@as(usize, 2), decoded.items.len);

    // "/* 😀 */ fn " is twelve UTF-16 code units before "abc" (the emoji is
    // a surrogate pair); a byte column would say fourteen. "def" sits at
    // column three on line 1, which is only reachable if the CRLF split is
    // handled.
    try testing.expectEqual(@as(u32, 0), decoded.items[0].src_line);
    try testing.expectEqual(@as(u32, 12), decoded.items[0].src_col);
    try testing.expectEqual(@as(u32, 1), decoded.items[1].src_line);
    try testing.expectEqual(@as(u32, 3), decoded.items[1].src_col);

    var author_index = try SourceMap.LineIndex.init(testing.allocator, crlf);
    defer author_index.deinit(testing.allocator);
    const abc_byte = byteOffsetForUtf16Column(crlf, &author_index, 0, 12);
    const def_byte = byteOffsetForUtf16Column(crlf, &author_index, 1, 3);
    try testing.expectEqualStrings("abc", crlf[abc_byte..][0..3]);
    try testing.expectEqualStrings("def", crlf[def_byte..][0..3]);
}

// =========================================================================
// 6. Empty mappings.
// =========================================================================

test "no mappings yields a valid empty source map" {
    const text = "fn main() {}\n";

    var fixture: AssemblyFixture = .init(testing.allocator);
    defer fixture.deinit();
    const root_index = try fixture.add(.shader_module, "main", text, &.{});

    var assembled = try fixture.assemble(root_index);
    defer assembled.deinit(fixture.arena.allocator());

    const empty = SourceMap.Result{ .version = 3, .file = "out.wgsl", .mappings = "" };
    var sources = [_]SourceMaps.Source{
        .{ .origin = .{ .program = 7, .index = root_index }, .name = "main.wgsl", .content = text },
    };
    var remapped = try SourceMaps.remap(
        testing.allocator,
        &assembled,
        &sources,
        &empty,
        .{ .file = "out.wgsl", .include_sources_content = true },
    );
    defer remapped.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 3), remapped.map.version);
    try testing.expectEqualStrings("out.wgsl", remapped.map.file);
    try testing.expectEqual(@as(usize, 0), remapped.map.mappings.len);
    try testing.expectEqual(@as(usize, 0), remapped.map.sources.len);
    try testing.expectEqual(@as(usize, 0), remapped.map.sources_content.len);
    try testing.expectEqual(@as(u32, 0), remapped.dropped);

    const json = try mapJson(testing.allocator, &remapped.map);
    defer testing.allocator.free(json);
    try expectContains(json, "\"version\":3");
    try expectContains(json, "\"mappings\":\"\"");
}

// =========================================================================
// 7. Dropped mappings: drop the origin, warn once per report.
// =========================================================================

test "a mapping without an honest origin is dropped and warned once" {
    const fragment =
        "enable f16;\n" ++
        "fn helper() -> f16 { return f16(1.0); }\n";
    const root = "fn main() -> f16 { return helper(); }\n";

    var fixture: AssemblyFixture = .init(testing.allocator);
    defer fixture.deinit();
    _ = try fixture.add(.wgsl, "frag", fragment, &.{});
    const root_index = try fixture.add(.shader_module, "main", root, &.{"frag"});

    var assembled = try fixture.assemble(root_index);
    defer assembled.deinit(fixture.arena.allocator());

    var blanked: ?pngine.Assemble.Segment = null;
    for (assembled.segments) |segment| {
        if (segment.kind == .blanked) {
            blanked = segment;
            break;
        }
    }
    const segment = blanked orelse return error.TestExpectedBlankedSegment;
    try testing.expect(segment.assembled.end - segment.assembled.start >= 3);

    var input = try InputMap.init(testing.allocator, assembled.text, &.{
        .{ .gen_line = 0, .gen_col = 0, .offset = segment.assembled.start },
        .{ .gen_line = 0, .gen_col = 1, .offset = segment.assembled.start + 1 },
        .{ .gen_line = 0, .gen_col = 2, .offset = segment.assembled.start + 2 },
    });
    defer input.deinit();

    var sources = [_]SourceMaps.Source{
        .{ .origin = .{ .program = 7, .index = 0 }, .name = "frag.wgsl", .content = fragment },
        .{ .origin = .{ .program = 7, .index = root_index }, .name = "main.wgsl", .content = root },
    };
    var remapped = try SourceMaps.remap(
        testing.allocator,
        &assembled,
        &sources,
        &input.map,
        .{},
    );
    defer remapped.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 3), remapped.dropped);
    try testing.expectEqual(@as(usize, 0), remapped.map.mappings.len);
    try testing.expectEqual(@as(usize, 0), remapped.map.sources.len);
    try testing.expectEqual(@as(usize, 0), remapped.map.sources_content.len);

    const warning = try SourceMaps.warningLine(testing.allocator, assembled.root_name, remapped.dropped);
    defer testing.allocator.free(warning);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, warning, "warning:"));
    try expectContains(warning, "main");
    try expectContains(warning, "3");
}

// =========================================================================
// 8. A one-part root is byte-identical to the single-source pipeline.
// =========================================================================

test "a one-part root's map matches the single-source pipeline byte-for-byte" {
    const source =
        \\struct Params {
        \\  scale: f32,
        \\}
        \\
        \\@group(0) @binding(0) var<uniform> params: Params;
        \\
        \\fn fs() -> f32 {
        \\  return params.scale;
        \\}
        \\
    ;

    var fixture: StoreFixture = undefined;
    try fixture.init(
        \\(shader-module :name main :file "root.wgsl")
    ,
        &.{.{ .path = "/ws/sm/root.wgsl", .text = source }},
    );
    defer fixture.deinit();

    var selected = try fixture.select("/ws/sm/root.wgsl", "main");
    defer selected.deinit(testing.allocator);

    var map_options = wgslender.Minifier.defaultOptions();
    map_options.generate_source_map = true;
    map_options.source_map_options = .{
        .source_name = "root.wgsl",
        .file = "root.min.wgsl",
        .include_source = true,
    };

    const source_z = try testing.allocator.dupeZ(u8, source);
    defer testing.allocator.free(source_z);
    var direct = try wgslender.minifyWithOptions(testing.allocator, source_z, map_options);
    defer direct.deinit(testing.allocator);

    var result = try artifacts.run(
        testing.allocator,
        &fixture.store,
        &selected,
        "/ws/sm/root.wgsl",
        .minify,
        .{ .minify_options = map_options },
    );
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings(direct.code, result.artifact);

    const direct_map = direct.source_map.?;
    const remapped_map = result.source_map.?;
    try testing.expectEqual(@as(usize, 1), remapped_map.sources.len);
    try testing.expectEqualStrings("root.wgsl", remapped_map.sources[0]);
    try testing.expectEqualStrings("root.min.wgsl", remapped_map.file);
    try testing.expectEqual(@as(usize, 1), remapped_map.sources_content.len);
    try testing.expectEqualStrings(source, remapped_map.sources_content[0]);

    const direct_json = try mapJson(testing.allocator, &direct_map);
    defer testing.allocator.free(direct_json);
    const remapped_json = try mapJson(testing.allocator, &remapped_map);
    defer testing.allocator.free(remapped_json);
    try testing.expectEqualStrings(direct_json, remapped_json);
}
