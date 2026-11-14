//! Reflected, minified, and compiled artifacts for one pngine root
//! (pngine-shaders phase 05, Task 3).
//!
//! The contract these reds pin:
//!   * `reflect` on a fragment selected with `--root` sees sibling
//!     declarations, sibling resources, and the assembled unit's entry
//!     points;
//!   * an artifact command with more than one containing root refuses with
//!     the candidate root names instead of choosing one;
//!   * a parse error anywhere in the assembled unit prints against its
//!     author file and emits no artifact;
//!   * reflection's numeric spans and offsets index the assembled text and
//!     are never relabelled as author offsets;
//!   * a one-part root produces byte-identical output to the existing
//!     single-source pipeline, because it is the same pipeline.
//!
//! Every test drives the in-memory `SourceProvider`; no test opens a
//! project document directly.

const std = @import("std");
const wgslender = @import("wgslender");
const selection = @import("PngineSelection");
const artifacts = @import("PngineArtifacts");
const provider_mod = @import("pngine_test_provider.zig");

const Store = selection.Store;
const FakeProvider = provider_mod.FakeProvider;
const testing = std.testing;

const File = struct {
    path: []const u8,
    text: []const u8,
};

const Fixture = struct {
    fake: FakeProvider,
    store: Store,

    /// Initialize in place: the fake provider's address is the store's
    /// provider context, so returning a `Fixture` by value would move the
    /// provider out from under the store.
    fn init(self: *Fixture, program: []const u8, files: []const File) !void {
        self.fake = FakeProvider.init(testing.allocator);
        errdefer self.fake.deinit();
        try self.fake.addFile("/ws/art/program.sjon", program);
        for (files) |file| try self.fake.addFile(file.path, file.text);
        self.store = Store.init(testing.allocator, self.fake.sourceProvider());
    }

    fn deinit(self: *Fixture) void {
        self.store.deinit();
        self.fake.deinit();
    }

    fn select(self: *Fixture, input: []const u8, root: ?[]const u8) !selection.ProjectSelection {
        return selection.selectProjectWithFailure(&self.store, input, null, root, false, null);
    }
};

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected text to contain '{s}'\n--- text ---\n{s}\n", .{ needle, haystack });
        return error.TestExpectedText;
    }
}

fn findObject(value: std.json.Value, name: []const u8) ?std.json.Value {
    for (value.array.items) |item| {
        if (std.mem.eql(u8, item.object.get("name").?.string, name)) return item;
    }
    return null;
}

fn dupeZ(allocator: std.mem.Allocator, text: []const u8) ![:0]const u8 {
    const out = try allocator.dupeZ(u8, text);
    return out[0..text.len :0];
}

const reflect_fixture_program =
    \\(wgsl :name first :file "first.wgsl")
    \\(wgsl :name lib :file "lib.wgsl")
    \\(shader-module :name main :file "root.wgsl" :imports [first lib])
;

const reflect_fixture_first = "fn first_helper() -> f32 { return 1.0; }\n";

const reflect_fixture_lib =
    \\struct Globals {
    \\  tint: vec4f,
    \\}
    \\
    \\fn palette(t: f32) -> f32 {
    \\  return t * 0.5;
    \\}
    \\
;

const reflect_fixture_root =
    \\@group(0) @binding(0) var<uniform> globals: Globals;
    \\
    \\@fragment
    \\fn fs() -> @location(0) vec4f {
    \\  return globals.tint * palette(1.0);
    \\}
    \\
;

fn initReflectFixture(fixture: *Fixture) !void {
    try fixture.init(reflect_fixture_program, &.{
        .{ .path = "/ws/art/first.wgsl", .text = reflect_fixture_first },
        .{ .path = "/ws/art/lib.wgsl", .text = reflect_fixture_lib },
        .{ .path = "/ws/art/root.wgsl", .text = reflect_fixture_root },
    });
}

// =========================================================================
// 1. Sibling declarations and resources reach the reflection artifact.
// =========================================================================

test "reflect on a selected fragment reports sibling declarations and resources" {
    var fixture: Fixture = undefined;
    try initReflectFixture(&fixture);
    defer fixture.deinit();

    var selected = try fixture.select("/ws/art/lib.wgsl", "main");
    defer selected.deinit(testing.allocator);

    var result = try artifacts.run(
        testing.allocator,
        &fixture.store,
        &selected,
        "/ws/art/lib.wgsl",
        .reflect,
        .{},
    );
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expect(result.artifact.len > 0);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result.artifact, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    // The struct and function are declared in a sibling fragment, never in
    // the author file named on the command line.
    try testing.expect(root.get("structs").?.object.contains("Globals"));

    const palette = findObject(root.get("functions").?, "palette") orelse
        return error.TestExpectedFunction;
    try testing.expect(palette.object.get("declSpan") != null);

    // The binding declared in the root resolves its struct type through the
    // sibling's declaration.
    const bindings = root.get("bindings").?.array.items;
    try testing.expect(bindings.len > 0);
    var found_binding = false;
    for (bindings) |binding| {
        const object = binding.object;
        if (object.get("group").?.integer == 0 and object.get("binding").?.integer == 0) {
            found_binding = true;
            try testing.expectEqualStrings("Globals", object.get("type").?.string);
        }
    }
    try testing.expect(found_binding);

    // The entry point comes from the root part and is reported exactly as
    // the assembled unit declares it.
    const fs = findObject(root.get("entryPoints").?, "fs") orelse
        return error.TestExpectedEntryPoint;
    try testing.expectEqualStrings("fragment", fs.object.get("stage").?.string);
}

// =========================================================================
// 2. More than one containing root: usage refusal naming the candidates.
// =========================================================================

test "artifact commands refuse a multi-root input without --root" {
    var fixture: Fixture = undefined;
    try fixture.init(
        \\(wgsl :name palette :file "palette.wgsl")
        \\(shader-module :name bgCode :file "bg.wgsl" :imports [palette])
        \\(shader-module :name squaresCode :file "squares.wgsl" :imports [palette])
    ,
        &.{
            .{ .path = "/ws/art/palette.wgsl", .text = "fn palette() -> f32 { return 1.0; }\n" },
            .{ .path = "/ws/art/bg.wgsl", .text = "fn bg() -> f32 { return palette(); }\n" },
            .{ .path = "/ws/art/squares.wgsl", .text = "fn squares() -> f32 { return palette(); }\n" },
        },
    );
    defer fixture.deinit();

    var selected = try fixture.select("/ws/art/palette.wgsl", null);
    defer selected.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), selected.roots.len);

    inline for (.{ artifacts.Command.reflect, .minify, .compile }) |command| {
        var result = try artifacts.run(
            testing.allocator,
            &fixture.store,
            &selected,
            "/ws/art/palette.wgsl",
            command,
            .{},
        );
        defer result.deinit(testing.allocator);

        try testing.expectEqual(@as(u8, 2), result.exit_code);
        try testing.expectEqual(@as(usize, 0), result.artifact.len);
        try expectContains(result.diagnostics, "--root");
        try expectContains(result.diagnostics, "bgCode");
        try expectContains(result.diagnostics, "squaresCode");
    }
}

// =========================================================================
// 3. Mapped diagnostics and no output on error, for every artifact command.
// =========================================================================

test "artifact commands map a sibling parse error and emit no artifact" {
    var fixture: Fixture = undefined;
    try fixture.init(
        \\(wgsl :name lib :file "lib.wgsl")
        \\(shader-module :name main :file "root.wgsl" :imports [lib])
    ,
        &.{
            .{ .path = "/ws/art/lib.wgsl", .text = "fn ok() {}\n\nfn broken( {\n" },
            .{ .path = "/ws/art/root.wgsl", .text = "@fragment\nfn fs() {}\n" },
        },
    );
    defer fixture.deinit();

    var selected = try fixture.select("/ws/art/root.wgsl", "main");
    defer selected.deinit(testing.allocator);

    inline for (.{ artifacts.Command.reflect, .minify, .compile }) |command| {
        var result = try artifacts.run(
            testing.allocator,
            &fixture.store,
            &selected,
            "/ws/art/root.wgsl",
            command,
            .{},
        );
        defer result.deinit(testing.allocator);

        try testing.expectEqual(@as(u8, 1), result.exit_code);
        // No partial artifact: no JSON, no minified text, no .wasm.
        try testing.expectEqual(@as(usize, 0), result.artifact.len);
        // The error is located in the fragment that wrote it, not in the
        // root file named on the command line.
        try expectContains(result.diagnostics, "/ws/art/lib.wgsl:3:");
        try testing.expect(std.mem.indexOf(u8, result.diagnostics, "/ws/art/root.wgsl:3: error") == null);
    }
}

// =========================================================================
// 4. Assembled-coordinate honesty for reflection spans.
// =========================================================================

test "reflection spans and offsets index the assembled text" {
    var fixture: Fixture = undefined;
    try initReflectFixture(&fixture);
    defer fixture.deinit();

    var selected = try fixture.select("/ws/art/lib.wgsl", "main");
    defer selected.deinit(testing.allocator);

    var result = try artifacts.run(
        testing.allocator,
        &fixture.store,
        &selected,
        "/ws/art/lib.wgsl",
        .reflect,
        .{},
    );
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result.artifact, .{});
    defer parsed.deinit();

    const palette = findObject(parsed.value.object.get("functions").?, "palette") orelse
        return error.TestExpectedFunction;
    const span = palette.object.get("declSpan").?.object;
    const start: usize = @intCast(span.get("start").?.integer);
    const end: usize = @intCast(span.get("end").?.integer);
    const name_offset: usize = @intCast(palette.object.get("nameOffset").?.integer);

    const assembled = try fixture.store.assembleRoot(selected.roots[0]);
    try testing.expect(start < end);
    try testing.expect(end <= assembled.text.len);
    try testing.expect(std.mem.startsWith(u8, assembled.text[start..end], "fn palette"));
    try testing.expect(std.mem.startsWith(u8, assembled.text[name_offset..], "palette"));

    // The assembled text starts with the `first` fragment, so the offset is
    // demonstrably not the author-local offset in lib.wgsl.
    const author_start = std.mem.indexOf(u8, reflect_fixture_lib, "fn palette").?;
    try testing.expect(start != author_start);
    try testing.expect(start >= reflect_fixture_first.len);
}

// =========================================================================
// 5. Single-source parity: same pipeline, byte-identical output.
// =========================================================================

test "a one-part root is byte-identical to the single-source pipeline" {
    const source =
        \\struct Params {
        \\  scale: f32,
        \\}
        \\
        \\@group(0) @binding(0) var<uniform> params: Params;
        \\
        \\@fragment
        \\fn fs() -> @location(0) vec4f {
        \\  return vec4f(params.scale);
        \\}
        \\
    ;

    var fixture: Fixture = undefined;
    try fixture.init(
        \\(shader-module :name main :file "root.wgsl")
    ,
        &.{.{ .path = "/ws/art/root.wgsl", .text = source }},
    );
    defer fixture.deinit();

    var selected = try fixture.select("/ws/art/root.wgsl", null);
    defer selected.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), selected.roots.len);

    const source_z = try dupeZ(testing.allocator, source);
    defer testing.allocator.free(source_z);

    // Minify: same options, same bytes.
    {
        var expected = try wgslender.minifyWithOptions(testing.allocator, source_z, .{});
        defer expected.deinit(testing.allocator);
        var result = try artifacts.run(
            testing.allocator,
            &fixture.store,
            &selected,
            "/ws/art/root.wgsl",
            .minify,
            .{},
        );
        defer result.deinit(testing.allocator);
        try testing.expectEqual(@as(u8, 0), result.exit_code);
        try testing.expectEqualStrings(expected.code, result.artifact);
    }

    // Reflect: the existing parse + reflect + serializer, unchanged.
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        const tokens = try wgslender.Lexer.tokenize(alloc, source_z);
        var parser = try wgslender.Parser.init(alloc, source_z, tokens);
        const module = try parser.parse();
        const reflected = try wgslender.Reflect.reflect(alloc, module);
        var json: std.ArrayList(u8) = .empty;
        try reflected.toJsonPrettyVersion(&json, alloc, .v2);
        try json.append(alloc, '\n');

        var result = try artifacts.run(
            testing.allocator,
            &fixture.store,
            &selected,
            "/ws/art/root.wgsl",
            .reflect,
            .{},
        );
        defer result.deinit(testing.allocator);
        try testing.expectEqual(@as(u8, 0), result.exit_code);
        try testing.expectEqualStrings(json.items, result.artifact);
    }

    // Compile: same binary.
    {
        var expected = try wgslender.compile(testing.allocator, source_z, .{ .minify = true });
        defer expected.deinit(testing.allocator);
        var result = try artifacts.run(
            testing.allocator,
            &fixture.store,
            &selected,
            "/ws/art/root.wgsl",
            .compile,
            .{},
        );
        defer result.deinit(testing.allocator);
        try testing.expectEqual(@as(u8, 0), result.exit_code);
        try testing.expectEqualStrings(expected.wasm, result.artifact);
    }
}
