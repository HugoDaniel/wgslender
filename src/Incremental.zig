//! Incremental reparse driver.
//!
//! Top-level API for building — and later, incrementally updating — a
//! unified parse state that carries the source, the AST, and the CST side
//! by side. Stage 6 MVP: every call to `reparse` performs a full source
//! splice + full parse. The `ReparseResult` shape is the real deliverable,
//! so LSP / FFI callers can commit to a stable API that doesn't change
//! when subtree reuse lands in a follow-up.
//!
//! Fast path today:
//!   - `classifyEdit` inspects the old + new sources and reports whether
//!     the edit is confined to trivia tokens (pure whitespace / comment
//!     content). A `.trivia_only` classification is a legal signal for
//!     callers to keep any cached semantic analysis hot while still
//!     updating the source + trees.
//!
//! Slow path (semantic edits): a fresh full parse, new arena.
//!
//! When subtree reuse arrives, the hot path migrates to an
//! `anchor_found + subtree_splice` strategy; callers keep the same API.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Cst = @import("Cst.zig");
const Lexer = @import("Lexer.zig");
const Parser = @import("Parser.zig");

const Incremental = @This();

/// A single contiguous byte-level edit, in OLD-source coordinates.
/// `[start, end)` is the range being replaced (may be empty for pure
/// inserts), `new_text` is the replacement (may be empty for pure deletes).
pub const Edit = struct {
    start: u32,
    end: u32,
    new_text: []const u8,

    pub fn isEmpty(self: Edit) bool {
        return self.start == self.end and self.new_text.len == 0;
    }
};

/// How an edit affected the token stream.
pub const EditKind = enum {
    /// The edit is a pure no-op (`start == end`, `new_text` empty).
    no_op,
    /// Only trivia tokens (whitespace + comments) changed — the non-trivia
    /// token sequence is byte-identical on both sides after shifting for
    /// the delta. Cached semantic analysis stays valid.
    trivia_only,
    /// Real tokens changed. Full re-analysis required.
    semantic,
};

/// Result of a parse or reparse. Owns an arena that holds the module, CST,
/// and source bytes. Dropping a `ReparseResult` frees the lot.
pub const ReparseResult = struct {
    gpa: Allocator,
    arena: *std.heap.ArenaAllocator,
    source: [:0]const u8,
    module: *Ast.Module,
    cst: Cst.Tree,
    /// True if this result came from a subtree-reuse hot path in
    /// `reparse`. Always `false` today — the MVP full-parses every edit
    /// — but the flag is part of the API so tests and telemetry can
    /// start asserting on it ahead of the anchor-based implementation.
    reused: bool = false,

    pub fn deinit(self: *ReparseResult) void {
        // All arena-owned: module, CST nodes/children/errors, source buffer.
        self.arena.deinit();
        self.gpa.destroy(self.arena);
    }
};

/// Kinds that are valid targets for anchor-based re-parse: each one can be
/// produced by a dedicated parser entry point given a token slice, without
/// needing any surrounding context. Non-anchor kinds (attribute_list,
/// parameter_list, struct_member_list, etc.) need to promote to a parent
/// anchor when an edit lands inside them.
pub fn isReparseAnchor(k: Cst.Kind) bool {
    return switch (k) {
        // Module items.
        .const_decl,
        .override_decl,
        .var_decl,
        .let_decl,
        .fn_decl,
        .struct_decl,
        .alias_decl,
        .const_assert_decl,
        .directive,
        // Statements.
        .compound_stmt,
        .return_stmt,
        .if_stmt,
        .switch_stmt,
        .for_stmt,
        .while_stmt,
        .loop_stmt,
        .break_stmt,
        .break_if_stmt,
        .continue_stmt,
        .discard_stmt,
        .assign_stmt,
        .incr_decr_stmt,
        .call_stmt,
        .decl_stmt,
        // Expressions.
        .binary_expr,
        .unary_expr,
        .call_expr,
        .index_expr,
        .member_expr,
        .paren_expr,
        .ident_expr,
        .literal_expr,
        // Types.
        .type_ident,
        .type_vec,
        .type_mat,
        .type_array,
        .type_ptr,
        .type_atomic,
        .type_sampler,
        .type_texture,
        // Attribute.
        .attribute,
        => true,
        else => false,
    };
}

/// Find the smallest reparse-anchor CST node whose old-source range fully
/// covers `[edit.start, edit.end)`. Returns `null` when the edit straddles
/// root-level boundaries (e.g. spans across two top-level decls) — callers
/// must fall back to `parseFull` in that case. The current `reparse` still
/// full-parses regardless; this function is the scaffolding the hot path
/// will consume once subtree reuse lands.
pub fn findAnchor(cst: *const Cst.Tree, edit: Edit) ?Cst.Cursor {
    const needle = Cst.Span{ .start = edit.start, .end = edit.end };
    const root = cst.rootCursor();
    if (!root.range().contains(needle)) return null;

    var best: ?Cst.Cursor = if (isReparseAnchor(root.kind())) root else null;
    var cur = root;
    descend: while (true) {
        for (cur.childElements()) |el| {
            const n = el.asNode() orelse continue;
            const child = Cst.Cursor{ .tree = cur.tree, .node = n };
            if (child.range().contains(needle)) {
                if (isReparseAnchor(child.kind())) best = child;
                cur = child;
                continue :descend;
            }
        }
        break;
    }
    return best;
}

/// Parse `source` from scratch into a `ReparseResult`. The result owns a
/// private arena; `gpa` is used for arena allocations and the arena struct
/// itself.
pub fn parseFull(gpa: Allocator, source: []const u8) !ReparseResult {
    const arena_ptr = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena_ptr);
    arena_ptr.* = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_ptr.deinit();

    const arena = arena_ptr.allocator();

    // Copy the source so the arena owns it; parser holds slices into it.
    const owned_source = try arena.allocSentinel(u8, source.len, 0);
    @memcpy(owned_source, source);

    var all_tokens = try Lexer.tokenizeAll(arena, owned_source);
    const stream = try Parser.TokenStream.init(arena, &all_tokens);

    var builder = Cst.Builder.init(gpa);
    defer builder.deinit();

    var parser = try Parser.initWithCst(arena, owned_source, stream, &builder);
    const module = try parser.parse();

    const tree = try builder.finish(arena, all_tokens, owned_source);

    return .{
        .gpa = gpa,
        .arena = arena_ptr,
        .source = owned_source,
        .module = module,
        .cst = tree,
    };
}

/// Apply `edit` to `prev.source` and return a fresh `ReparseResult` for
/// the resulting source. Today this always splices + full-parses; the
/// call site API is the stake.
pub fn reparse(
    gpa: Allocator,
    prev: *const ReparseResult,
    edit: Edit,
) !ReparseResult {
    std.debug.assert(edit.start <= edit.end);
    std.debug.assert(edit.end <= prev.source.len);

    if (edit.isEmpty()) {
        // Pure no-op: still full-parse to return an independent result.
        // Callers that want to avoid the cost should short-circuit before
        // calling reparse.
        return parseFull(gpa, prev.source);
    }

    const new_len = prev.source.len - (edit.end - edit.start) + edit.new_text.len;
    const new_buf = try gpa.alloc(u8, new_len);
    defer gpa.free(new_buf);
    @memcpy(new_buf[0..edit.start], prev.source[0..edit.start]);
    @memcpy(new_buf[edit.start .. edit.start + edit.new_text.len], edit.new_text);
    @memcpy(
        new_buf[edit.start + edit.new_text.len ..],
        prev.source[edit.end..],
    );

    return parseFull(gpa, new_buf);
}

/// Compare the non-trivia token sequences of two sources and report
/// whether the edit was confined to trivia. This is the cheapest shortcut
/// today — callers that see `.trivia_only` can keep their cached semantic
/// analysis and just swap in the new tree. Quadratic-in-token-count in the
/// pathological case but O(n) in practice.
pub fn classifyEdit(
    gpa: Allocator,
    old_source: [:0]const u8,
    new_source: [:0]const u8,
) !EditKind {
    if (std.mem.eql(u8, old_source, new_source)) return .no_op;

    var old_tokens = try Lexer.tokenize(gpa, old_source);
    defer old_tokens.deinit(gpa);
    var new_tokens = try Lexer.tokenize(gpa, new_source);
    defer new_tokens.deinit(gpa);

    const old_tags = old_tokens.items(.tag);
    const new_tags = new_tokens.items(.tag);
    const old_starts = old_tokens.items(.start);
    const new_starts = new_tokens.items(.start);
    const old_ends = old_tokens.items(.end);
    const new_ends = new_tokens.items(.end);

    // Same token count + same tag + same text ⇒ only trivia differs.
    if (old_tags.len != new_tags.len) return .semantic;
    for (old_tags, new_tags, 0..) |ot, nt, i| {
        if (ot != nt) return .semantic;
        const ol = old_ends[i] - old_starts[i];
        const nl = new_ends[i] - new_starts[i];
        if (ol != nl) return .semantic;
        if (!std.mem.eql(u8, old_source[old_starts[i] .. old_ends[i]], new_source[new_starts[i] .. new_ends[i]])) {
            return .semantic;
        }
    }
    return .trivia_only;
}

// =========================================================================
// Tests
// =========================================================================

const testing = std.testing;

test "Incremental.parseFull builds AST + CST from source" {
    var result = try Incremental.parseFull(testing.allocator, "const x = 1;");
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.module.declarations.items.len);
    try testing.expectEqual(Cst.Kind.module, result.cst.rootCursor().kind());
    try testing.expectEqualStrings("const x = 1;", result.source);
}

test "Incremental.reparse: insert at end" {
    var base = try Incremental.parseFull(testing.allocator, "const x = 1;");
    defer base.deinit();

    var updated = try Incremental.reparse(testing.allocator, &base, .{
        .start = @intCast(base.source.len),
        .end = @intCast(base.source.len),
        .new_text = "\nconst y = 2;",
    });
    defer updated.deinit();

    try testing.expectEqualStrings("const x = 1;\nconst y = 2;", updated.source);
    try testing.expectEqual(@as(usize, 2), updated.module.declarations.items.len);
}

test "Incremental.reparse: replace middle" {
    const base_source: [:0]const u8 = "const x = 1;\nconst y = 2;";
    var base = try Incremental.parseFull(testing.allocator, base_source);
    defer base.deinit();

    // Replace "1" with "42": find the byte offset of the `1`.
    const one_offset: u32 = @intCast(std.mem.indexOfScalar(u8, base_source, '1').?);
    var updated = try Incremental.reparse(testing.allocator, &base, .{
        .start = one_offset,
        .end = one_offset + 1,
        .new_text = "42",
    });
    defer updated.deinit();

    try testing.expectEqualStrings("const x = 42;\nconst y = 2;", updated.source);
    try testing.expectEqual(@as(usize, 2), updated.module.declarations.items.len);
}

test "Incremental.reparse: pure delete" {
    const base_source: [:0]const u8 = "const x = 1;\nconst y = 2;";
    var base = try Incremental.parseFull(testing.allocator, base_source);
    defer base.deinit();

    // Delete "const y = 2;" including the leading newline.
    const nl = std.mem.indexOfScalar(u8, base_source, '\n').?;
    var updated = try Incremental.reparse(testing.allocator, &base, .{
        .start = @intCast(nl),
        .end = @intCast(base_source.len),
        .new_text = "",
    });
    defer updated.deinit();

    try testing.expectEqualStrings("const x = 1;", updated.source);
    try testing.expectEqual(@as(usize, 1), updated.module.declarations.items.len);
}

test "Incremental.classifyEdit: whitespace-only change is trivia_only" {
    const old: [:0]const u8 = "const x = 1;";
    const new: [:0]const u8 = "const  x = 1;"; // extra space
    const kind = try Incremental.classifyEdit(testing.allocator, old, new);
    try testing.expectEqual(EditKind.trivia_only, kind);
}

test "Incremental.classifyEdit: comment-only change is trivia_only" {
    const old: [:0]const u8 = "// before\nconst x = 1;";
    const new: [:0]const u8 = "// after\nconst x = 1;";
    const kind = try Incremental.classifyEdit(testing.allocator, old, new);
    try testing.expectEqual(EditKind.trivia_only, kind);
}

test "Incremental.classifyEdit: renaming identifier is semantic" {
    const old: [:0]const u8 = "const x = 1;";
    const new: [:0]const u8 = "const xx = 1;";
    const kind = try Incremental.classifyEdit(testing.allocator, old, new);
    try testing.expectEqual(EditKind.semantic, kind);
}

test "Incremental.classifyEdit: identical sources are no_op" {
    const s: [:0]const u8 = "const x = 1;";
    const kind = try Incremental.classifyEdit(testing.allocator, s, s);
    try testing.expectEqual(EditKind.no_op, kind);
}

test "Incremental.classifyEdit: adding a new decl is semantic" {
    const old: [:0]const u8 = "const x = 1;";
    const new: [:0]const u8 = "const x = 1;\nconst y = 2;";
    const kind = try Incremental.classifyEdit(testing.allocator, old, new);
    try testing.expectEqual(EditKind.semantic, kind);
}

test "Incremental.reparse after inverse edit round-trips the source" {
    const base_source: [:0]const u8 = "fn f() { let x = 1; }";
    var base = try Incremental.parseFull(testing.allocator, base_source);
    defer base.deinit();

    // Insert "y" between "= " and "1;"
    const eq = std.mem.indexOfScalar(u8, base_source, '=').?;
    const ins_at: u32 = @intCast(eq + 2);
    var with_ins = try Incremental.reparse(testing.allocator, &base, .{
        .start = ins_at,
        .end = ins_at,
        .new_text = "y+",
    });
    defer with_ins.deinit();

    // Inverse: delete the 2 bytes we inserted.
    var back = try Incremental.reparse(testing.allocator, &with_ins, .{
        .start = ins_at,
        .end = ins_at + 2,
        .new_text = "",
    });
    defer back.deinit();

    try testing.expectEqualStrings(base_source, back.source);
}

test "Incremental.reparse: reused flag is false on the MVP path" {
    var base = try Incremental.parseFull(testing.allocator, "const x = 1;");
    defer base.deinit();
    try testing.expect(!base.reused);

    var updated = try Incremental.reparse(testing.allocator, &base, .{
        .start = 10,
        .end = 11,
        .new_text = "42",
    });
    defer updated.deinit();
    try testing.expect(!updated.reused);
}

test "Incremental.findAnchor: edit inside a literal lands on literal_expr" {
    const src: [:0]const u8 = "const x = 1;";
    var base = try Incremental.parseFull(testing.allocator, src);
    defer base.deinit();

    const one_off: u32 = @intCast(std.mem.indexOfScalar(u8, src, '1').?);
    const anchor = Incremental.findAnchor(&base.cst, .{
        .start = one_off,
        .end = one_off + 1,
        .new_text = "2",
    }) orelse return error.TestUnexpectedNull;
    try testing.expectEqual(Cst.Kind.literal_expr, anchor.kind());
}

test "Incremental.findAnchor: edit in identifier lands on ident_expr or a parent anchor" {
    const src: [:0]const u8 = "fn f() { let x = y; }";
    var base = try Incremental.parseFull(testing.allocator, src);
    defer base.deinit();

    const y_off: u32 = @intCast(std.mem.indexOfScalar(u8, src, 'y').?);
    const anchor = Incremental.findAnchor(&base.cst, .{
        .start = y_off,
        .end = y_off + 1,
        .new_text = "z",
    }) orelse return error.TestUnexpectedNull;
    // Narrow anchor: the ident_expr wrapping `y`.
    try testing.expectEqual(Cst.Kind.ident_expr, anchor.kind());
}

test "Incremental.findAnchor: edit bridging two decls promotes to module" {
    const src: [:0]const u8 = "const x = 1;\nconst y = 2;";
    var base = try Incremental.parseFull(testing.allocator, src);
    defer base.deinit();

    // Edit spans from inside the first decl to inside the second — no
    // single anchor covers it, so findAnchor must bail out (null) or at
    // best return the module root, which is not itself a reparse anchor.
    const anchor = Incremental.findAnchor(&base.cst, .{
        .start = 5,
        .end = 18,
        .new_text = "//",
    });
    // Either no anchor, or the result is the module root but module is
    // not itself a reparse anchor. Concretely: should be null.
    try testing.expectEqual(@as(?Cst.Cursor, null), anchor);
}
