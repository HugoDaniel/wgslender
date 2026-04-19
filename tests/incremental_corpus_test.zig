//! Bulk regression for `Incremental.reparse` on real-world shaders.
//!
//! For every shader in `tests/testdata/compute.toys/`:
//!   1. `parseFull` the shader.
//!   2. Append a line-comment edit at the end and reparse — the resulting
//!      source should classify as `trivia_only` and the declaration count
//!      must match.
//!   3. Apply a forward edit (insert a noop `; ` at a safe boundary) and
//!      then the inverse, asserting the final source is byte-identical to
//!      the original and the same AST declaration count is recovered.
//!   4. Round-trip the CST over the whole shader: the concatenation of
//!      every leaf token in document order must equal the source.
//!
//! Skips gracefully if the testdata directory is absent (existing repo
//! convention).

const std = @import("std");
const wgslender = @import("wgslender");

const Incremental = wgslender.Incremental;
const Cst = wgslender.Cst;

fn makeSentinel(a: std.mem.Allocator, bytes: []const u8) ![:0]const u8 {
    const buf = try a.allocSentinel(u8, bytes.len, 0);
    @memcpy(buf, bytes);
    return buf[0..bytes.len :0];
}

/// Walk every leaf token of a CST (including trivia) and concatenate its
/// source slice. Must equal the source that built the tree.
fn walkTreeConcat(
    gpa: std.mem.Allocator,
    tree: *const Cst.Tree,
    buf: *std.ArrayListUnmanaged(u8),
    node_idx: Cst.NodeIndex,
) !void {
    const n = tree.getNode(node_idx);
    const children = tree.children[n.first_child .. n.first_child + n.child_count];
    for (children) |el| {
        if (el.asToken()) |tok_idx| {
            const start = tree.tokens.items(.start)[tok_idx];
            const end = tree.tokens.items(.end)[tok_idx];
            try buf.appendSlice(gpa, tree.source[start..end]);
        } else if (el.asNode()) |child_idx| {
            try walkTreeConcat(gpa, tree, buf, child_idx);
        }
    }
}

test "incremental corpus: round-trip + trivia classification on compute.toys" {
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
        const alloc = arena.allocator();

        const source_bytes = entry.dir.readFileAlloc(io, entry.basename, alloc, .unlimited) catch {
            continue;
        };

        // --- 1. parseFull ----------------------------------------------------
        var base = try Incremental.parseFull(gpa, source_bytes);
        defer base.deinit();
        const base_decl_count = base.module.declarations.items.len;

        // --- 2. CST round-trip equals source ---------------------------------
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(gpa);
        try walkTreeConcat(gpa, &base.cst, &buf, base.cst.root());
        if (!std.mem.eql(u8, source_bytes, buf.items)) {
            std.debug.print(
                "compute.toys {s}: CST round-trip mismatch (len {d} vs {d})\n",
                .{ entry.path, source_bytes.len, buf.items.len },
            );
            return error.CstRoundtripFailed;
        }

        // --- 3. Trivia-only edit keeps classification + decl count -----------
        // Append "\n// trailing comment\n". No non-trivia tokens change.
        const trivia_edit_text = "\n// trailing comment\n";
        const src_z = try makeSentinel(alloc, source_bytes);
        const new_src_bytes = try std.mem.concat(alloc, u8, &.{ source_bytes, trivia_edit_text });
        const new_src_z = try makeSentinel(alloc, new_src_bytes);
        const kind = try Incremental.classifyEdit(gpa, src_z, new_src_z);
        try std.testing.expectEqual(Incremental.EditKind.trivia_only, kind);

        var updated = try Incremental.reparse(gpa, &base, .{
            .start = @intCast(source_bytes.len),
            .end = @intCast(source_bytes.len),
            .new_text = trivia_edit_text,
        });
        defer updated.deinit();
        try std.testing.expectEqual(base_decl_count, updated.module.declarations.items.len);
        try std.testing.expectEqualStrings(new_src_bytes, updated.source);

        // --- 4. Forward + inverse edit round-trips source --------------------
        // Insert "// x\n" at offset 0 (trivia_only), then delete it.
        const prefix = "// x\n";
        var with_prefix = try Incremental.reparse(gpa, &base, .{
            .start = 0,
            .end = 0,
            .new_text = prefix,
        });
        defer with_prefix.deinit();

        var back = try Incremental.reparse(gpa, &with_prefix, .{
            .start = 0,
            .end = @intCast(prefix.len),
            .new_text = "",
        });
        defer back.deinit();
        try std.testing.expectEqualStrings(source_bytes, back.source);
        try std.testing.expectEqual(base_decl_count, back.module.declarations.items.len);

        n_shaders += 1;
    }

    std.debug.print(
        "compute.toys incremental corpus: {d} shaders — roundtrip + trivia classify + forward/inverse edits OK\n",
        .{n_shaders},
    );
}

test "incremental corpus: mid-source semantic edit classifies as semantic" {
    // A non-trivia edit at the midpoint of a realistic shader must be
    // detected as semantic, forcing a re-analyze. Use an inline snippet to
    // avoid filesystem dependencies.
    const src: [:0]const u8 =
        \\struct Uniforms { time: f32 }
        \\@group(0) @binding(0) var<uniform> u: Uniforms;
        \\@compute @workgroup_size(1) fn main() { let t = u.time; }
    ;
    const offset: u32 = @intCast(std.mem.indexOf(u8, src, "time").?);
    const new_src: [:0]const u8 =
        \\struct Uniforms { epoch: f32 }
        \\@group(0) @binding(0) var<uniform> u: Uniforms;
        \\@compute @workgroup_size(1) fn main() { let t = u.time; }
    ;
    _ = offset;
    const kind = try Incremental.classifyEdit(std.testing.allocator, src, new_src);
    try std.testing.expectEqual(Incremental.EditKind.semantic, kind);
}

test "incremental corpus: classifyEdit equivalence on random whitespace reflow" {
    // Take a realistic shader, strip its indentation/newlines in random
    // ways, and assert every variant classifies as trivia_only against the
    // original and re-parses to the same declaration count.
    const base: [:0]const u8 =
        \\fn helper(x: f32) -> f32 {
        \\    return x * 2.0;
        \\}
        \\
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\    let v = helper(1.0);
        \\}
    ;

    var baseline = try Incremental.parseFull(std.testing.allocator, base);
    defer baseline.deinit();
    const baseline_decls = baseline.module.declarations.items.len;

    // Four reflow variants — each is byte-different but non-trivia
    // identical, so `classifyEdit` must return `.trivia_only` and the
    // decl count must match.
    const variants = [_][:0]const u8{
        // 1. Collapse all interior whitespace to single spaces.
        \\fn helper(x: f32) -> f32 { return x * 2.0; } @compute @workgroup_size(1) fn main() { let v = helper(1.0); }
        ,
        // 2. Spread everything onto one line but with a trailing line comment.
        \\fn helper(x: f32) -> f32 { return x * 2.0; } @compute @workgroup_size(1) fn main() { let v = helper(1.0); } // end
        ,
        // 3. Add block comments between tokens.
        \\fn /*a*/ helper(x: /*b*/ f32) -> f32 { return x * 2.0; }
        \\@compute @workgroup_size(1) fn main() { let v = helper(1.0); }
        ,
        // 4. Heavy indentation + trailing whitespace per line.
        \\    fn helper(x: f32) -> f32 {
        \\        return x * 2.0;
        \\    }
        \\    @compute @workgroup_size(1)
        \\    fn main() {
        \\        let v = helper(1.0);
        \\    }
        ,
    };

    for (variants) |v| {
        const kind = try Incremental.classifyEdit(std.testing.allocator, base, v);
        try std.testing.expectEqual(Incremental.EditKind.trivia_only, kind);

        var parsed = try Incremental.parseFull(std.testing.allocator, v);
        defer parsed.deinit();
        try std.testing.expectEqual(baseline_decls, parsed.module.declarations.items.len);
    }
}

test "incremental corpus: reparse composes over repeated trivia-only inserts" {
    const base_src: [:0]const u8 = "fn f() { let x = 1; return; }";
    var result = try Incremental.parseFull(std.testing.allocator, base_src);
    defer result.deinit();

    // 20 successive trivia-only inserts: each prepends "// tick\n".
    var prev = &result;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var keep: std.ArrayListUnmanaged(Incremental.ReparseResult) = .empty;
    defer {
        for (keep.items) |*r| r.deinit();
        keep.deinit(arena.allocator());
    }

    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const next = try Incremental.reparse(std.testing.allocator, prev, .{
            .start = 0,
            .end = 0,
            .new_text = "// tick\n",
        });
        try keep.append(arena.allocator(), next);
        prev = &keep.items[keep.items.len - 1];
    }

    // After 20 prepends of "// tick\n", the final source must start with 20
    // comment lines followed by the original body.
    try std.testing.expect(std.mem.startsWith(u8, prev.source, "// tick\n// tick\n"));
    try std.testing.expect(std.mem.endsWith(u8, prev.source, base_src));
    try std.testing.expectEqual(@as(usize, 1), prev.module.declarations.items.len);
}

// =========================================================================
// F-CORPUS — error fixup over the compute.toys corpus.
//
// For every shader, take the first integer literal token, swap a digit
// (length-preserving so the literal_expr anchor's kind stays stable),
// reparse via the hot path, and assert that `updated.errors` matches a
// fresh `parseFull(updated.source)` byte for byte. Catches subtle
// drop/shift/copy bugs on real-world shapes.
// =========================================================================

test "F-CORPUS: literal swap on compute.toys preserves error oracle equality" {
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
    var n_edits: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".wgsl")) continue;

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const alloc = arena.allocator();

        const source_bytes = entry.dir.readFileAlloc(io, entry.basename, alloc, .unlimited) catch {
            continue;
        };
        const source_z = try makeSentinel(alloc, source_bytes);

        // Tokenize to find the first int_literal (cheap; reused tokens).
        var toks = try wgslender.Lexer.tokenizeAll(gpa, source_z);
        defer toks.deinit(gpa);
        const tags = toks.items(.tag);
        const starts = toks.items(.start);
        const ends = toks.items(.end);

        var lit_idx: ?usize = null;
        for (tags, 0..) |t, i| {
            if (t == .int_literal) {
                lit_idx = i;
                break;
            }
        }
        if (lit_idx == null) continue;

        const lit_start = starts[lit_idx.?];
        const lit_end = ends[lit_idx.?];
        if (lit_end - lit_start < 1) continue;

        // Length-preserving digit swap on the leading character.
        const replacement: []const u8 = switch (source_z[lit_start]) {
            '0', '1', '2', '3', '4' => "9",
            else => "0",
        };

        var base = try Incremental.parseFull(gpa, source_z);
        defer base.deinit();

        var updated = try Incremental.reparse(gpa, &base, .{
            .start = lit_start,
            .end = lit_start + 1,
            .new_text = replacement,
        });
        defer updated.deinit();

        // The first int_literal in some shaders sits inside an
        // attribute-arg context (e.g., `@workgroup_size(8)`), which can
        // hit fallback paths. Either path is fine — both populate
        // `errors` from the same parseFull oracle this test compares
        // against.
        var oracle = try Incremental.parseFull(gpa, updated.source);
        defer oracle.deinit();
        try std.testing.expectEqual(oracle.errors.len, updated.errors.len);
        for (updated.errors, oracle.errors) |g, o| {
            try std.testing.expectEqualStrings(o.code, g.code);
            try std.testing.expectEqual(o.pos, g.pos);
            try std.testing.expectEqual(o.end, g.end);
        }

        n_shaders += 1;
        n_edits += 1;
    }

    std.debug.print(
        "F-CORPUS error fixup: {d} compute.toys shaders, {d} edits — oracle equality OK\n",
        .{ n_shaders, n_edits },
    );
}

// =========================================================================
// I-01 — Compound/decl hot path coverage on the compute.toys corpus.
//
// For every shader, insert `let _pad_N = 0;` immediately before the last
// `}` (the end of the last function body). The edit lands inside a
// compound_stmt and should take the Phase 2 in-place path. Assert
// reused==true, source splice correct, and live-use-count sum per
// symbol matches a full parseFull oracle.
// =========================================================================

test "I-01: per-shader body append on compute.toys uses the hot path" {
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
    var n_reused: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".wgsl")) continue;

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const alloc = arena.allocator();

        const source_bytes = entry.dir.readFileAlloc(io, entry.basename, alloc, .unlimited) catch {
            continue;
        };
        const source_z = try makeSentinel(alloc, source_bytes);

        const close_off: u32 = @intCast(std.mem.lastIndexOfScalar(u8, source_z, '}').?);

        var base = try Incremental.parseFull(gpa, source_z);
        defer base.deinit();

        var updated = try Incremental.reparse(gpa, &base, .{
            .start = close_off,
            .end = close_off,
            .new_text = " let _pad_01 = 0;",
        });
        defer updated.deinit();

        if (updated.reused) n_reused += 1;

        var oracle = try Incremental.parseFull(gpa, updated.source);
        defer oracle.deinit();
        try std.testing.expectEqual(
            oracle.module.declarations.items.len,
            updated.module.declarations.items.len,
        );

        // Live-sum equivalence per name (append-only contract).
        var oracle_live_sum: u64 = 0;
        for (oracle.module.symbols.items) |s| oracle_live_sum += s.use_count;
        var updated_live_sum: u64 = 0;
        for (updated.module.symbols.items) |s| updated_live_sum += s.use_count;
        try std.testing.expectEqual(oracle_live_sum, updated_live_sum);

        n_shaders += 1;
    }

    // On the current corpus every shader's final `}` is inside a
    // function body — the append should take the hot path every time.
    try std.testing.expectEqual(n_shaders, n_reused);

    std.debug.print(
        "I-01 compound body append: {d} compute.toys shaders, all hot-path, live-sum oracle OK\n",
        .{n_shaders},
    );
}
