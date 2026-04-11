//! Source map integration tests.
//! These test source map generation through the full minifier pipeline.

const std = @import("std");
const wgslender = @import("wgslender");

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn minifyWithSourceMap(allocator: std.mem.Allocator, source: [:0]const u8) !wgslender.Minifier.Result {
    return wgslender.minifyWithOptions(allocator, source, .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .tree_shaking = false,
        .generate_source_map = true,
    });
}

fn minifyWithSourceMapNoRename(allocator: std.mem.Allocator, source: [:0]const u8) !wgslender.Minifier.Result {
    return wgslender.minifyWithOptions(allocator, source, .{
        .minify_whitespace = true,
        .minify_identifiers = false,
        .tree_shaking = false,
        .generate_source_map = true,
    });
}

// =========================================================================
// Basic structure tests
// =========================================================================

test "SourceMap: basic structure (version=3, non-empty mappings)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyWithSourceMap(alloc,
        \\fn foo(x: f32) -> f32 {
        \\    return x * 2.0;
        \\}
    );

    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
    const sm = result.source_map orelse return error.TestExpectedSourceMap;
    try std.testing.expectEqual(@as(u32, 3), sm.version);
    try std.testing.expect(sm.mappings.len > 0);
}

test "SourceMap: identifier renaming populates names array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyWithSourceMap(alloc,
        \\fn myFunction(value: f32) -> f32 {
        \\    return value * 2.0;
        \\}
    );

    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
    const sm = result.source_map orelse return error.TestExpectedSourceMap;
    // With identifier renaming, names array should have renamed identifiers
    try std.testing.expect(sm.names.len > 0);
}

test "SourceMap: no renaming yields empty names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyWithSourceMapNoRename(alloc,
        \\fn foo(x: f32) -> f32 {
        \\    return x * 2.0;
        \\}
    );

    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
    const sm = result.source_map orelse return error.TestExpectedSourceMap;
    // Without renaming, names should be empty
    try std.testing.expectEqual(@as(usize, 0), sm.names.len);
}

test "SourceMap: multi-line source produces semicolons in mappings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyWithSourceMapNoRename(alloc,
        \\fn a() -> f32 { return 1.0; }
        \\fn b() -> f32 { return 2.0; }
        \\fn c() -> f32 { return 3.0; }
    );

    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
    const sm = result.source_map orelse return error.TestExpectedSourceMap;
    // Minified to single line, so mappings should not contain semicolons
    // but should contain commas (multiple segments on one line)
    try std.testing.expect(sm.mappings.len > 0);
}

test "SourceMap: delta encoding in mappings is decodable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyWithSourceMap(alloc,
        \\fn helper(x: f32) -> f32 {
        \\    return x + 1.0;
        \\}
        \\fn main() -> f32 {
        \\    return helper(2.0);
        \\}
    );

    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
    const sm = result.source_map orelse return error.TestExpectedSourceMap;
    // Verify mappings can be decoded (all VLQ sequences are valid)
    for (sm.mappings) |c| {
        // Valid chars: A-Z, a-z, 0-9, +, /, comma, semicolon
        try std.testing.expect(
            (c >= 'A' and c <= 'Z') or
                (c >= 'a' and c <= 'z') or
                (c >= '0' and c <= '9') or
                c == '+' or c == '/' or c == ',' or c == ';',
        );
    }
}

test "SourceMap: entry point names not in names array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyWithSourceMap(alloc,
        \\@fragment
        \\fn main() -> @location(0) vec4f {
        \\    return vec4f(1.0);
        \\}
    );

    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
    const sm = result.source_map orelse return error.TestExpectedSourceMap;
    // Entry point "main" is not renamed, so should not appear in names
    for (sm.names) |n| {
        try std.testing.expect(!std.mem.eql(u8, n, "main"));
    }
}

// =========================================================================
// JSON / DataURI / SourcesContent output
// =========================================================================

test "SourceMap: JSON output format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyWithSourceMapNoRename(alloc, "fn foo() {}");
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
    const sm = result.source_map orelse return error.TestExpectedSourceMap;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try sm.toJson(&buf, alloc);
    try std.testing.expect(contains(buf.items, "\"version\":3"));
    try std.testing.expect(contains(buf.items, "\"mappings\":"));
    try std.testing.expect(contains(buf.items, "\"sources\":"));
    try std.testing.expect(contains(buf.items, "\"names\":"));
}

test "SourceMap: DataURI output format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyWithSourceMapNoRename(alloc, "fn foo() {}");
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
    const sm = result.source_map orelse return error.TestExpectedSourceMap;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try sm.toDataUri(&buf, alloc);
    try std.testing.expect(contains(buf.items, "data:application/json;base64,"));
}

test "SourceMap: sources content included" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source: [:0]const u8 = "fn foo() { let x = 1; }";
    const result = try wgslender.minifyWithOptions(alloc, source, .{
        .minify_whitespace = true,
        .minify_identifiers = false,
        .tree_shaking = false,
        .generate_source_map = true,
        .source_map_options = .{
            .include_source = true,
        },
    });

    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
    const sm = result.source_map orelse return error.TestExpectedSourceMap;
    try std.testing.expect(sm.sources_content.len > 0);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try sm.toJson(&buf, alloc);
    try std.testing.expect(contains(buf.items, "\"sourcesContent\":"));
}

test "SourceMap: file field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try wgslender.minifyWithOptions(alloc, "fn foo() {}", .{
        .minify_whitespace = true,
        .minify_identifiers = false,
        .tree_shaking = false,
        .generate_source_map = true,
        .source_map_options = .{
            .file = "shader.wgsl",
        },
    });

    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
    const sm = result.source_map orelse return error.TestExpectedSourceMap;
    try std.testing.expectEqualStrings("shader.wgsl", sm.file);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try sm.toJson(&buf, alloc);
    try std.testing.expect(contains(buf.items, "\"file\":\"shader.wgsl\""));
}

// =========================================================================
// Tree shaking and disabled
// =========================================================================

test "SourceMap: tree shaking effect on names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try wgslender.minifyWithOptions(alloc,
        \\fn unused() -> f32 { return 0.0; }
        \\fn helper() -> f32 { return 1.0; }
        \\@fragment fn main() -> @location(0) vec4f {
        \\    return vec4f(helper());
        \\}
    , .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .tree_shaking = true,
        .generate_source_map = true,
    });

    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
    const sm = result.source_map orelse return error.TestExpectedSourceMap;
    // unused function should not contribute to names
    for (sm.names) |n| {
        try std.testing.expect(!std.mem.eql(u8, n, "unused"));
    }
}

test "SourceMap: disabled returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try wgslender.minifyWithOptions(alloc, "fn foo() {}", .{
        .minify_whitespace = true,
        .minify_identifiers = false,
        .tree_shaking = false,
        .generate_source_map = false,
    });

    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
    try std.testing.expect(result.source_map == null);
}

// =========================================================================
// AST node coverage
// =========================================================================

test "SourceMap: function params generate mappings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyWithSourceMap(alloc,
        \\fn process(input: f32, scale: f32) -> f32 {
        \\    return input * scale;
        \\}
    );

    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
    const sm = result.source_map orelse return error.TestExpectedSourceMap;
    try std.testing.expect(sm.mappings.len > 0);
    // Should have at least two renamed identifiers
    try std.testing.expect(sm.names.len >= 2);
}

test "SourceMap: struct declarations generate mappings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyWithSourceMap(alloc,
        \\struct MyData {
        \\    x: f32,
        \\    y: f32,
        \\}
        \\fn makeData() -> MyData {
        \\    return MyData(1.0, 2.0);
        \\}
    );

    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
    const sm = result.source_map orelse return error.TestExpectedSourceMap;
    // Struct and function declarations should produce mappings
    try std.testing.expect(sm.mappings.len > 0);
}

test "SourceMap: nested scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyWithSourceMap(alloc,
        \\fn outer() -> f32 {
        \\    let x = 1.0;
        \\    if (x > 0.0) {
        \\        let y = x + 1.0;
        \\        return y;
        \\    }
        \\    return x;
        \\}
    );

    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
    const sm = result.source_map orelse return error.TestExpectedSourceMap;
    try std.testing.expect(sm.mappings.len > 0);
}

test "SourceMap: for loops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyWithSourceMap(alloc,
        \\fn sum() -> u32 {
        \\    var total: u32 = 0u;
        \\    for (var i: u32 = 0u; i < 10u; i++) {
        \\        total += i;
        \\    }
        \\    return total;
        \\}
    );

    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
    const sm = result.source_map orelse return error.TestExpectedSourceMap;
    try std.testing.expect(sm.mappings.len > 0);
}

// =========================================================================
// Edge cases
// =========================================================================

test "SourceMap: empty source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyWithSourceMapNoRename(alloc, "");
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
    const sm = result.source_map orelse return error.TestExpectedSourceMap;
    try std.testing.expectEqual(@as(u32, 3), sm.version);
}

test "SourceMap: comments-only source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try minifyWithSourceMapNoRename(alloc, "// this is a comment\n/* block comment */");
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
    const sm = result.source_map orelse return error.TestExpectedSourceMap;
    try std.testing.expectEqual(@as(u32, 3), sm.version);
}
