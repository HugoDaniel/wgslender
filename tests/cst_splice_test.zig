//! `Cst.spliceSubtree` unit tests.
//!
//! Each test builds a full CST from a source via `Incremental.parseFull`,
//! re-parses a specific anchor subtree via `Parser.reparseAnchor` on the
//! edited source, and calls `Cst.spliceSubtree`. The resulting tree is
//! compared field-by-field against a fresh full parse of the edited
//! source — the splice must produce byte-identical node counts, node
//! spans, and child-table structure.

const std = @import("std");
const wgslender = @import("wgslender");

const Cst = wgslender.Cst;
const Incremental = wgslender.Incremental;
const Lexer = wgslender.Lexer;
const Parser = wgslender.Parser;
const Ast = wgslender.Ast;

/// Render the tree as a compact S-expression (kinds + leaf spans). Used
/// as a structural oracle — two trees that render identically are
/// considered equivalent for splice purposes.
fn renderTree(
    gpa: std.mem.Allocator,
    tree: *const Cst.Tree,
    buf: *std.ArrayListUnmanaged(u8),
    node_idx: Cst.NodeIndex,
) !void {
    const n = tree.getNode(node_idx);
    const header = try std.fmt.allocPrint(gpa, "({s} {d}..{d}", .{ @tagName(n.kind), n.start, n.end });
    defer gpa.free(header);
    try buf.appendSlice(gpa, header);
    const children = tree.children[n.first_child .. n.first_child + n.child_count];
    for (children) |el| {
        try buf.append(gpa, ' ');
        if (el.asNode()) |child| {
            try renderTree(gpa, tree, buf, child);
        } else {
            const token = el.asToken().?;
            const starts = tree.tokens.items(.start);
            const ends = tree.tokens.items(.end);
            const leaf = try std.fmt.allocPrint(gpa, "[t{d}:{d}..{d}]", .{ token, starts[token], ends[token] });
            defer gpa.free(leaf);
            try buf.appendSlice(gpa, leaf);
        }
    }
    try buf.append(gpa, ')');
}

/// Given an old tree and an edit, construct the expected "spliced"
/// tree by parsing the new source from scratch and returning its tree.
/// The test then compares this oracle to whatever `spliceSubtree`
/// produces. `anchor_start`/`anchor_end` define the byte range of the
/// target anchor node in `old_source`; the test looks up the smallest
/// CST node covering that exact span. `edit_start`/`edit_end` define
/// the bytes replaced by `replacement` — they must lie inside the
/// anchor.
fn runSplice(
    gpa: std.mem.Allocator,
    old_source: []const u8,
    anchor_start: u32,
    anchor_end: u32,
    edit_start: u32,
    edit_end: u32,
    replacement: []const u8,
    anchor_kind: Parser.AnchorKind,
    expected_anchor_kind: Cst.Kind,
) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    // Parse old.
    var old_result = try Incremental.parseFull(gpa, old_source);
    defer old_result.deinit();

    const anchor_cursor = old_result.cst.rootCursor().findSmallestContaining(.{
        .start = anchor_start,
        .end = anchor_end,
    });
    try std.testing.expectEqual(expected_anchor_kind, anchor_cursor.kind());

    // Build new source: replace bytes [edit_start, edit_end) with `replacement`.
    const new_len = old_source.len - (edit_end - edit_start) + replacement.len;
    const new_source_buf = try gpa.alloc(u8, new_len);
    defer gpa.free(new_source_buf);
    @memcpy(new_source_buf[0..edit_start], old_source[0..edit_start]);
    @memcpy(new_source_buf[edit_start .. edit_start + replacement.len], replacement);
    @memcpy(new_source_buf[edit_start + replacement.len ..], old_source[edit_end..]);

    // Re-lex the new source.
    const new_source_z = try aa.allocSentinel(u8, new_source_buf.len, 0);
    @memcpy(new_source_z, new_source_buf);
    var new_all_tokens = try Lexer.tokenizeAll(aa, new_source_z);
    const new_stream = try Parser.TokenStream.init(aa, &new_all_tokens);

    // Locate the anchor's first non-trivia token in the new stream.
    const anchor_byte = anchor_cursor.range().start;
    var nt_pos: u32 = 0;
    while (nt_pos < new_stream.non_trivia_starts.len and new_stream.non_trivia_starts[nt_pos] < anchor_byte) : (nt_pos += 1) {}
    std.debug.assert(nt_pos < new_stream.non_trivia_starts.len);

    // Re-parse the anchor.
    var sub_builder = Cst.Builder.init(gpa);
    defer sub_builder.deinit();
    var sub_parser = try Parser.initWithCst(aa, new_source_z, new_stream, &sub_builder);
    _ = try sub_parser.reparseAnchor(anchor_kind, nt_pos);
    var new_sub = try sub_builder.finish(aa, new_all_tokens, new_source_z);

    try std.testing.expectEqual(expected_anchor_kind, new_sub.rootCursor().kind());

    // Splice.
    var spliced = try Cst.spliceSubtree(aa, &old_result.cst, anchor_cursor.node, &new_sub, new_source_z, new_all_tokens);

    // Oracle: fresh full-parse of the new source.
    var oracle = try Incremental.parseFull(gpa, new_source_buf);
    defer oracle.deinit();

    // Structural comparison — render both and compare.
    var spliced_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer spliced_buf.deinit(gpa);
    var oracle_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer oracle_buf.deinit(gpa);
    try renderTree(gpa, &spliced, &spliced_buf, spliced.root());
    try renderTree(gpa, &oracle.cst, &oracle_buf, oracle.cst.root());

    std.testing.expectEqualStrings(oracle_buf.items, spliced_buf.items) catch |err| {
        std.debug.print("spliced differs from oracle for edit at [{d}..{d}] → \"{s}\"\n", .{ edit_start, edit_end, replacement });
        std.debug.print("oracle:  {s}\n", .{oracle_buf.items});
        std.debug.print("spliced: {s}\n", .{spliced_buf.items});
        return err;
    };

    // Source sanity: source on the spliced tree must match new_source_buf.
    try std.testing.expectEqualStrings(new_source_buf, spliced.source);
}

/// Locate the byte offset of the first occurrence of `needle` starting
/// at or after `from`. Used by tests to pin anchor byte ranges without
/// false positives on earlier substring matches.
fn findAt(src: []const u8, needle: []const u8, from: usize) u32 {
    const idx = std.mem.indexOfPos(u8, src, from, needle).?;
    return @intCast(idx);
}

test "spliceSubtree: literal replacement (same length)" {
    const src = "fn f() -> i32 { return 42; }";
    const off = findAt(src, "42", 0);
    try runSplice(
        std.testing.allocator,
        src,
        off,
        off + 2,
        off,
        off + 2,
        "99",
        .expression,
        .literal_expr,
    );
}

test "spliceSubtree: literal replacement (grows)" {
    const src = "fn f() -> i32 { return 88888; }";
    const off = findAt(src, "88888", 0);
    try runSplice(
        std.testing.allocator,
        src,
        off,
        off + 5,
        off,
        off + 5,
        "1370000",
        .expression,
        .literal_expr,
    );
}

test "spliceSubtree: literal replacement (shrinks)" {
    const src = "fn f() -> i32 { return 12345; }";
    const off = findAt(src, "12345", 0);
    try runSplice(
        std.testing.allocator,
        src,
        off,
        off + 5,
        off,
        off + 5,
        "7",
        .expression,
        .literal_expr,
    );
}

test "spliceSubtree: ident use-site rename" {
    const src = "fn uses() { let a = 1; let b = a; }";
    // Find the USE-site "a" (after "let b = "), skipping the declaration
    // site inside "let a = 1;".
    const decl_a = findAt(src, "a", 0);
    const use_a = findAt(src, "a", decl_a + 1);
    try runSplice(
        std.testing.allocator,
        src,
        use_a,
        use_a + 1,
        use_a,
        use_a + 1,
        "aa",
        .expression,
        .ident_expr,
    );
}

test "spliceSubtree: replace whole binary expression with literal" {
    // Anchor: the outer binary_expr "1 + 2" wrapping two literals.
    // Replacement is a literal, but kind stays binary_expr only if we
    // replace with another binary expression. Here we use a literal,
    // which will produce a kind mismatch — so the test asserts we bail
    // out at the `expectEqual` step BEFORE splicing.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const src: [:0]const u8 = "fn f() -> i32 { return 1 + 2; }";
    var result = try Incremental.parseFull(std.testing.allocator, src);
    defer result.deinit();

    const needle = "1 + 2";
    const anchor_start: u32 = @intCast(std.mem.indexOf(u8, src, needle).?);
    const anchor = result.cst.rootCursor().findSmallestContaining(.{
        .start = anchor_start,
        .end = anchor_start + @as(u32, @intCast(needle.len)),
    });
    try std.testing.expectEqual(Cst.Kind.binary_expr, anchor.kind());

    // Build new source with "1 + 2" → "7".
    const new_buf = try std.testing.allocator.alloc(u8, src.len - needle.len + 1);
    defer std.testing.allocator.free(new_buf);
    @memcpy(new_buf[0..anchor_start], src[0..anchor_start]);
    new_buf[anchor_start] = '7';
    @memcpy(new_buf[anchor_start + 1 ..], src[anchor_start + needle.len ..]);

    // Re-lex + re-parse anchor.
    const new_z = try aa.allocSentinel(u8, new_buf.len, 0);
    @memcpy(new_z, new_buf);
    var new_tokens = try Lexer.tokenizeAll(aa, new_z);
    const stream = try Parser.TokenStream.init(aa, &new_tokens);
    var nt: u32 = 0;
    while (nt < stream.non_trivia_starts.len and stream.non_trivia_starts[nt] < anchor.range().start) : (nt += 1) {}
    var sub_b = Cst.Builder.init(std.testing.allocator);
    defer sub_b.deinit();
    var sub_p = try Parser.initWithCst(aa, new_z, stream, &sub_b);
    _ = try sub_p.reparseAnchor(.expression, nt);
    var sub = try sub_b.finish(aa, new_tokens, new_z);
    // Kind mismatch surfaces: new anchor is literal_expr, not binary_expr.
    try std.testing.expectEqual(Cst.Kind.literal_expr, sub.rootCursor().kind());
    // Caller (Incremental.reparse) will bail to full parse on this case;
    // we do not invoke spliceSubtree when kinds differ.
}

test "spliceSubtree: nested expression deep inside function body" {
    const src = "fn f() -> i32 { let a = 1; let b = 2; return a + b * 3; }";
    // Anchor the literal "3" at the end of "b * 3" (not the one in i32
    // or digits elsewhere).
    const three = findAt(src, "* 3;", 0) + 2;
    try runSplice(
        std.testing.allocator,
        src,
        three,
        three + 1,
        three,
        three + 1,
        "42",
        .expression,
        .literal_expr,
    );
}

test "spliceSubtree: return statement replacement (same kind)" {
    const src = "fn f() -> i32 { return 1; }";
    const ret_start = findAt(src, "return", 0);
    const semi = findAt(src, ";", ret_start) + 1;
    try runSplice(
        std.testing.allocator,
        src,
        ret_start,
        semi,
        ret_start,
        semi,
        "return 100;",
        .statement,
        .return_stmt,
    );
}

test "spliceSubtree: ident in second of several decls shifts later offsets" {
    const src = "const a = 1;\nconst b = 2;\nconst c = 3;";
    // Target the "2" in the second decl.
    const two = findAt(src, "2", 0);
    try runSplice(
        std.testing.allocator,
        src,
        two,
        two + 1,
        two,
        two + 1,
        "20000",
        .expression,
        .literal_expr,
    );
}

// =========================================================================
// reparseAnchor returned-AST-node tests
//
// Since Block 1.4, `reparseAnchor` returns the `Ast` node it built while
// emitting the anchor's CST — the incremental symbol-free splice consumes it
// directly instead of re-lowering the CST. These pin the returned node's
// shape; ident refs are left unresolved (the caller's `.add`-mode visit
// binds them).
// =========================================================================

test "reparseAnchor: literal_expr produces Ast.LiteralExpr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const src: [:0]const u8 = "42";
    var all_tokens = try Lexer.tokenizeAll(aa, src);
    const stream = try Parser.TokenStream.init(aa, &all_tokens);
    var builder = Cst.Builder.init(std.testing.allocator);
    defer builder.deinit();
    var parser = try Parser.initWithCst(aa, src, stream, &builder);
    const lowered = try parser.reparseAnchor(.expression, 0);
    switch (lowered) {
        .expr => |e| {
            const lit = e.literal;
            try std.testing.expectEqualStrings("42", lit.value);
            try std.testing.expectEqual(Lexer.Tag.int_literal, lit.kind);
        },
        else => return error.TestUnexpectedSubtreeVariant,
    }
}

test "reparseAnchor: ident_expr has unresolved ref" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const src: [:0]const u8 = "foo";
    var all_tokens = try Lexer.tokenizeAll(aa, src);
    const stream = try Parser.TokenStream.init(aa, &all_tokens);
    var builder = Cst.Builder.init(std.testing.allocator);
    defer builder.deinit();
    var parser = try Parser.initWithCst(aa, src, stream, &builder);
    const lowered = try parser.reparseAnchor(.expression, 0);
    switch (lowered) {
        .expr => |e| {
            const id = e.ident;
            try std.testing.expectEqualStrings("foo", id.name);
            // Unresolved on the hot path — caller's visitSubtree binds it.
            try std.testing.expect(!id.ref.isValid());
        },
        else => return error.TestUnexpectedSubtreeVariant,
    }
}

test "reparseAnchor: return statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const src: [:0]const u8 = "return 1;";
    var all_tokens = try Lexer.tokenizeAll(aa, src);
    const stream = try Parser.TokenStream.init(aa, &all_tokens);
    var builder = Cst.Builder.init(std.testing.allocator);
    defer builder.deinit();
    var parser = try Parser.initWithCst(aa, src, stream, &builder);
    const lowered = try parser.reparseAnchor(.statement, 0);
    switch (lowered) {
        .stmt => |s| {
            try std.testing.expect(s == .@"return");
            const ret = s.@"return";
            try std.testing.expect(ret.value != null);
        },
        else => return error.TestUnexpectedSubtreeVariant,
    }
}

test "reparseAnchor: a compound parses as a .stmt (gating is the driver's job)" {
    // reparseAnchor itself does NOT reject scope-bearing anchors — the
    // Parser happily builds a compound. The symbol-free vs scope-bearing
    // split is enforced upstream by `Anchor.isSymbolFreeAnchor` + the
    // incremental driver's dispatch, not here. (This replaces the old
    // `CstLower.lowerSubtree` InvalidCst-on-compound bail, which no longer
    // exists.)
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const src: [:0]const u8 = "{ return 1; }";
    var all_tokens = try Lexer.tokenizeAll(aa, src);
    const stream = try Parser.TokenStream.init(aa, &all_tokens);
    var builder = Cst.Builder.init(std.testing.allocator);
    defer builder.deinit();
    var parser = try Parser.initWithCst(aa, src, stream, &builder);
    const lowered = try parser.reparseAnchor(.statement, 0);
    try std.testing.expect(lowered == .stmt);
    try std.testing.expect(lowered.stmt == .compound);
}
