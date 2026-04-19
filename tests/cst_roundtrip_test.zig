//! CST round-trip: the concatenation of every leaf token (trivia
//! included) under the root must equal the source byte-for-byte.
//!
//! This is the lossless-CST contract the incremental reparse leans on.
//! Covers the handcrafted edge cases from the original plan's
//! Verification §1, plus a bulk pass over `tests/testdata/compute.toys/`
//! that catches regressions on real shaders.
//!
//! The token-level round-trip is already asserted inline in
//! `src/Lexer.zig` for `tokenizeAll`; this test suite asserts the same
//! property one level up — at the CST level, where nested nodes walk
//! the flat `children` table. If either the Builder drops a token or
//! `finish` mis-links a subtree, this catches it immediately.

const std = @import("std");
const wgslender = @import("wgslender");

const Incremental = wgslender.Incremental;
const Cst = wgslender.Cst;

fn walkConcat(
    gpa: std.mem.Allocator,
    tree: *const Cst.Tree,
    buf: *std.ArrayListUnmanaged(u8),
    node_idx: Cst.NodeIndex,
) !void {
    const n = tree.getNode(node_idx);
    const children = tree.children[n.first_child .. n.first_child + n.child_count];
    for (children) |el| {
        if (el.asToken()) |tok| {
            const s = tree.tokens.items(.start)[tok];
            const e = tree.tokens.items(.end)[tok];
            try buf.appendSlice(gpa, tree.source[s..e]);
        } else if (el.asNode()) |child| {
            try walkConcat(gpa, tree, buf, child);
        }
    }
}

fn expectRoundtrip(gpa: std.mem.Allocator, source: []const u8) !void {
    var result = try Incremental.parseFull(gpa, source);
    defer result.deinit();
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try walkConcat(gpa, &result.cst, &buf, result.cst.root());
    try std.testing.expectEqualStrings(source, buf.items);
}

// =========================================================================
// Handcrafted edge cases
// =========================================================================

test "cst roundtrip: empty" {
    try expectRoundtrip(std.testing.allocator, "");
}

test "cst roundtrip: single decl, no trivia" {
    try expectRoundtrip(std.testing.allocator, "const x=1;");
}

test "cst roundtrip: leading and trailing whitespace" {
    try expectRoundtrip(std.testing.allocator, "\n\n  const x = 1;  \n");
}

test "cst roundtrip: tabs + CRLF newlines" {
    try expectRoundtrip(std.testing.allocator, "const a = 1;\r\n\tconst b = 2;\r\n");
}

test "cst roundtrip: line-only comments interleaved with decls" {
    try expectRoundtrip(
        std.testing.allocator,
        "// first\nconst a = 1; // after\n// middle\nconst b = 2;\n",
    );
}

test "cst roundtrip: block comment between tokens" {
    try expectRoundtrip(std.testing.allocator, "fn/*x*/f() {}\n");
}

test "cst roundtrip: nested block comment" {
    try expectRoundtrip(
        std.testing.allocator,
        "/* outer /* inner */ still outer */\nfn f() {}\n",
    );
}

test "cst roundtrip: function with interior trivia" {
    try expectRoundtrip(
        std.testing.allocator,
        "fn main() {\n  // step 1\n  let x = 1; /* step 2 */ return;\n}\n",
    );
}

test "cst roundtrip: struct with trailing comma + trivia" {
    try expectRoundtrip(
        std.testing.allocator,
        "struct S {\n  x: f32, // x\n  y: vec3<f32>, /* y */\n}\n",
    );
}

test "cst roundtrip: attribute with call expression" {
    try expectRoundtrip(
        std.testing.allocator,
        "@compute @workgroup_size(8, 8, 1) fn main() {}\n",
    );
}

test "cst roundtrip: template-heavy type" {
    try expectRoundtrip(
        std.testing.allocator,
        "var<storage, read_write> buf: array<vec3<f32>, 4>;\n",
    );
}

test "cst roundtrip: unterminated block comment covers remainder" {
    // Lexer produces a block_comment trivia token spanning to EOF; the
    // round-trip must still cover every byte.
    try expectRoundtrip(std.testing.allocator, "/* never closes");
}

test "cst roundtrip: unicode in comment" {
    try expectRoundtrip(
        std.testing.allocator,
        "// \xF0\x9F\x8E\x89 emoji\nfn f() {}\n",
    );
}

// =========================================================================
// Bulk corpus — real shaders
// =========================================================================

test "cst roundtrip: compute.toys corpus" {
    const io = std.Options.debug_io;
    const dir_path = "tests/testdata/compute.toys";
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound or err == error.NotFound) {
            std.debug.print("skip: compute.toys directory missing\n", .{});
            return;
        }
        return err;
    };
    defer dir.close(io);

    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    var n_shaders: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".wgsl")) continue;

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();

        const bytes = entry.dir.readFileAlloc(io, entry.basename, arena.allocator(), .unlimited) catch continue;
        expectRoundtrip(gpa, bytes) catch |err| {
            std.debug.print(
                "cst roundtrip failed on compute.toys/{s}: {}\n",
                .{ entry.path, err },
            );
            return err;
        };
        n_shaders += 1;
    }

    std.debug.print("cst roundtrip: verified on {d} compute.toys shaders\n", .{n_shaders});
}
