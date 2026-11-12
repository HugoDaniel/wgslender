//! Anchor classification + edit shape for the incremental driver.
//!
//! "Anchor" is the smallest reparse-able CST subtree that fully
//! contains a byte-level edit. Three predicates carve up `Cst.Kind`:
//!
//!   - `isReparseAnchor` — kinds the parser can re-enter at via a
//!     dedicated `reparseAnchor` entry point. Used by `findAnchor`
//!     during DFS descent: once we know the edit is contained, we
//!     prefer the deepest enclosing kind that survives this filter.
//!   - `isHotPathAnchor` — anchor kinds we trust on the in-place hot
//!     path (the union of symbol-free + compound_stmt + decl_stmt).
//!     Anything else falls back to `parseFull`.
//!   - `isSymbolFreeAnchor` — anchor kinds the add/sub splice can
//!     handle without touching the symbol table. Compound_stmt and
//!     decl_stmt are hot-path but NOT symbol-free; they go through
//!     dedicated splice paths instead.
//!
//! `findAnchor` does the descent. `classifyEdit` is the trivia-only
//! shortcut — same-token-stream means cached semantic analysis stays
//! valid and only source bytes need to be swapped.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Cst = @import("../Cst.zig");
const Lexer = @import("../Lexer.zig");
const constants = @import("../constants.zig");

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
        .phony_stmt,
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

/// Anchor kinds the parser can re-enter at via `reparseAnchor` and whose
/// lowering the incremental hot path can splice. Three families:
///
///   - Expressions (no symbol introduction).
///   - Non-scope-introducing statements (return, assign, ...).
///   - Scope/symbol-introducing statements (`compound_stmt`, `decl_stmt`).
///     These dispatch to the dedicated splice routines in `Splice.zig`,
///     which append new symbols to `module.symbols` and patch the scope
///     tree under the enclosing parent without re-lowering the whole
///     module.
pub fn isHotPathAnchor(k: Cst.Kind) bool {
    return switch (k) {
        // Expressions never declare symbols.
        .literal_expr,
        .ident_expr,
        .binary_expr,
        .unary_expr,
        .call_expr,
        .index_expr,
        .member_expr,
        .paren_expr,
        // Statements that do not open a scope and do not declare anything.
        .return_stmt,
        .assign_stmt,
        .phony_stmt,
        .incr_decr_stmt,
        .call_stmt,
        .break_stmt,
        .break_if_stmt,
        .continue_stmt,
        .discard_stmt,
        // Scope-introducing / declaring statements. Safe because we
        // re-lower the whole module after splice.
        .compound_stmt,
        .decl_stmt,
        => true,
        else => false,
    };
}

/// True for the anchor kinds where the add/sub hot path is safe:
/// expressions (which never declare symbols) and non-scope-introducing
/// statements. `compound_stmt` and `decl_stmt` are hot-path anchors but
/// NOT symbol-free — they introduce scopes and/or symbols and route to
/// `tryCompoundSpliceInPlace` / `tryDeclStmtSpliceInPlace` instead.
pub fn isSymbolFreeAnchor(k: Cst.Kind) bool {
    return switch (k) {
        // Expressions.
        .literal_expr,
        .ident_expr,
        .binary_expr,
        .unary_expr,
        .call_expr,
        .index_expr,
        .member_expr,
        .paren_expr,
        // Statements that neither open a scope nor declare symbols.
        .return_stmt,
        .assign_stmt,
        .phony_stmt,
        .incr_decr_stmt,
        .call_stmt,
        .break_stmt,
        .break_if_stmt,
        .continue_stmt,
        .discard_stmt,
        => true,
        else => false,
    };
}

/// CST kinds that lower to `Ast.Stmt` (vs. `Ast.Expr`). Used by the
/// dispatcher to pick the parser's anchor entry point and by the splice
/// machinery to choose between a stmt-slot and an expr-slot writeback.
pub fn isStmtKind(k: Cst.Kind) bool {
    return switch (k) {
        .return_stmt,
        .assign_stmt,
        .phony_stmt,
        .incr_decr_stmt,
        .call_stmt,
        .break_stmt,
        .break_if_stmt,
        .continue_stmt,
        .discard_stmt,
        .compound_stmt,
        .decl_stmt,
        => true,
        else => false,
    };
}

/// Find the smallest reparse-anchor CST node whose old-source range fully
/// covers `[edit.start, edit.end)`. Returns `null` when the edit straddles
/// root-level boundaries (e.g. spans across two top-level decls); callers
/// must fall back to `parseFull` in that case.
pub fn findAnchor(cst: *const Cst.Tree, edit: Edit) ?Cst.Cursor {
    const root = cst.rootCursor();
    if (!containsEditForDescent(root, edit)) return null;

    var best: ?Cst.Cursor = if (isReparseAnchor(root.kind())) root else null;
    var cur = root;
    descend: for (0..constants.max_tree_walk_iterations) |_| {
        for (cur.childElements()) |el| {
            const n = el.asNode() orelse continue;
            const child = Cst.Cursor{ .tree = cur.tree, .node = n };
            if (!containsEditForDescent(child, edit)) continue;
            if (isReparseAnchor(child.kind())) best = child;
            cur = child;
            continue :descend;
        }
        break;
    } else unreachable;
    return best;
}

/// Like `Span.contains(edit_range)` but treats pure insertions at the
/// non-trivia boundary of a node as *not contained* — they belong to
/// the parent. Rationale:
///   - a pure insert `[P, P)` at `P == node.end` appends bytes outside
///     the node; reparsing it would leave them dangling.
///   - a pure insert at `P == first_non_trivia_start` prepends bytes
///     before the node's first real token. For a single-statement node
///     like `decl_stmt`, the inserted text might be a sibling statement,
///     which the enclosing container (compound_stmt) can absorb but the
///     node itself cannot.
/// For non-empty edits we keep the existing half-open containment — the
/// edit has at least one byte in the node, so the reparse is well-defined.
fn containsEditForDescent(cursor: Cst.Cursor, edit: Edit) bool {
    const r = cursor.range();
    if (edit.start == edit.end) {
        const nt_start = firstNonTriviaStart(cursor) orelse r.start;
        return edit.start > nt_start and edit.end < r.end;
    }
    return edit.start >= r.start and edit.end <= r.end;
}

/// First non-trivia token's start byte inside a node's subtree, or null
/// if the subtree has no non-trivia tokens (e.g., all whitespace).
fn firstNonTriviaStart(cursor: Cst.Cursor) ?u32 {
    const tree = cursor.tree;
    const tags = tree.tokens.items(.tag);
    const starts = tree.tokens.items(.start);
    for (tree.childrenOf(cursor.node)) |el| {
        if (el.asToken()) |t| {
            if (!tags[t].isTrivia()) return starts[t];
        } else if (el.asNode()) |n| {
            if (firstNonTriviaStart(.{ .tree = tree, .node = n })) |s| return s;
        }
    }
    return null;
}

/// Compare the non-trivia token sequences of two sources and report
/// whether the edit was confined to trivia. A `.trivia_only` result
/// means cached semantic analysis stays valid and only the source +
/// trees need updating. Quadratic-in-token-count worst case but O(n)
/// in practice.
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

    if (!realTokenStreamsEqual(old_source, &old_tokens, new_source, &new_tokens)) {
        return .semantic;
    }
    return .trivia_only;
}

/// True when both streams hold the same non-trivia token count with
/// matching tags, lengths, and byte text. Used by the public
/// `classifyEdit` (its two `Lexer.tokenize` arrays); the internal
/// edit-aware gate has its own fused lockstep walk over all-token
/// streams.
fn realTokenStreamsEqual(
    old_source: [:0]const u8,
    old_tokens: *const std.MultiArrayList(Lexer.Token),
    new_source: [:0]const u8,
    new_tokens: *const std.MultiArrayList(Lexer.Token),
) bool {
    const old_tags = old_tokens.items(.tag);
    const new_tags = new_tokens.items(.tag);
    const old_starts = old_tokens.items(.start);
    const new_starts = new_tokens.items(.start);
    const old_ends = old_tokens.items(.end);
    const new_ends = new_tokens.items(.end);

    if (old_tags.len != new_tags.len) return false;
    for (old_tags, new_tags, 0..) |ot, nt, i| {
        if (ot != nt) return false;
        const ol = old_ends[i] - old_starts[i];
        const nl = new_ends[i] - new_starts[i];
        if (ol != nl) return false;
        if (!std.mem.eql(u8, old_source[old_starts[i]..old_ends[i]], new_source[new_starts[i]..new_ends[i]])) {
            return false;
        }
    }
    return true;
}

/// Facts about a gate-passing trivia edit, consumed by the AST trivia
/// shift (`Cst.retokenizeTrivia` re-derives the gap from the streams
/// itself).
pub const TriviaEdit = struct {
    /// Replaced byte range, in OLD coordinates. The replacement range in
    /// NEW coordinates is `[start, start + new_text.len)`.
    start: u32,
    end: u32,
    new_text: []const u8,
    /// `new_text.len - (end - start)`; equals the source-length delta.
    delta: i64,
};

/// Internal edit-aware trivia gate for the incremental driver. Unlike the
/// public `classifyEdit` (which the LSP uses to keep analysis caches hot),
/// this classifier knows the byte-level edit and can therefore prove the
/// stronger property the offset-reuse shortcut needs — that every real
/// token satisfies
///
/// ```text
/// new_start = old_start + (old_start >= edit.end ? delta : 0)
/// ```
///
/// and that the old replaced range and the new replacement range are each
/// confined to a single inter-non-trivia-token trivia gap (a pure
/// insertion may not lie strictly inside a real token). This rejects a
/// whole-range replacement that happens to preserve the token stream
/// while redistributing whitespace internally, and closes the theoretical
/// zero-delta offset hole (zero delta alone does not prove that every
/// token stayed at its old offset).
///
/// Pure over the two ALL-token streams (`Lexer.tokenizeAll` output,
/// trivia included): the caller passes `prev.cst.tokens` for the old side
/// — no lex at all — and the SAME single `tokenizeAll` of the new source
/// that `Cst.retokenizeTrivia` consumes for the rebuild. The gate never
/// lexes anything itself (B3: no second lex for the gap check).
///
/// Returns `null` when the edit is not a confined trivia edit — the
/// caller must fall back to the anchor path / `parseFull`.
pub fn classifyTriviaEdit(
    old_source: []const u8,
    old_all: *const std.MultiArrayList(Lexer.Token),
    new_source: []const u8,
    new_all: *const std.MultiArrayList(Lexer.Token),
    edit: Edit,
) ?TriviaEdit {
    const old_tags = old_all.items(.tag);
    const new_tags = new_all.items(.tag);

    // 1. No lexer errors on either side — an `.error` token means the
    //    stream is truncated and the ordinal mapping below is unprovable.
    for (old_tags) |t| {
        if (t == .@"error") return null;
    }
    for (new_tags) |t| {
        if (t == .@"error") return null;
    }

    const old_starts = old_all.items(.start);
    const old_ends = old_all.items(.end);
    const new_starts = new_all.items(.start);
    const new_ends = new_all.items(.end);

    const delta: i64 = @as(i64, @intCast(edit.new_text.len)) - @as(i64, edit.end - edit.start);
    const new_range_end_i64: i64 = @as(i64, edit.start) + @as(i64, @intCast(edit.new_text.len));
    const new_range_end: u32 = @intCast(new_range_end_i64);

    // 2–5 fused into one lockstep walk over real tokens by ordinal
    //    (trivia skipped in both streams): identical count, tags,
    //    lengths, and byte text; the per-ordinal coordinate transform;
    //    and one-gap confinement. Gap containment is checked streaming —
    //    between consecutive real tokens at most one trivia gap can
    //    contain a byte range, so ordinal-indexed arrays are unneeded.
    //    `ordinal == -1` is the leading gap; the `.eof` token is a real
    //    (zero-length) token at source end, so the gap before it is the
    //    trailing gap and nothing follows it.
    var gap: ?i32 = null;
    var oi: u32 = 0;
    var ni: u32 = 0;
    var ordinal: i32 = -1;
    var prev_old_end: u32 = 0;
    var prev_new_end: u32 = 0;
    while (true) {
        while (oi < old_tags.len and old_tags[oi].isTrivia()) oi += 1;
        while (ni < new_tags.len and new_tags[ni].isTrivia()) ni += 1;
        const old_done = oi == old_tags.len;
        const new_done = ni == new_tags.len;
        // Identical non-trivia token count.
        if (old_done != new_done) return null;

        if (gap == null) {
            const old_gap_end: u32 = if (old_done) @intCast(old_source.len) else old_starts[oi];
            const new_gap_end: u32 = if (new_done) @intCast(new_source.len) else new_starts[ni];
            // Both ranges must sit in the SAME ordinal's gap: the old
            // replaced range in the old gap, the new replacement range in
            // the new gap (an empty range at a boundary belongs to that
            // gap — a pure insertion at `p` may sit at either end).
            if (prev_old_end <= edit.start and edit.end <= old_gap_end and
                prev_new_end <= edit.start and new_range_end <= new_gap_end)
            {
                gap = ordinal;
            }
        }

        if (old_done) break;

        // Identical tag, length, byte text.
        if (old_tags[oi] != new_tags[ni]) return null;
        if (old_ends[oi] - old_starts[oi] != new_ends[ni] - new_starts[ni]) return null;
        if (!std.mem.eql(
            u8,
            old_source[old_starts[oi]..old_ends[oi]],
            new_source[new_starts[ni]..new_ends[ni]],
        )) return null;

        // Coordinate transform per real-token ordinal.
        const shift: i64 = if (old_starts[oi] >= edit.end) delta else 0;
        if (@as(i64, new_starts[ni]) != @as(i64, old_starts[oi]) + shift) return null;
        if (@as(i64, new_ends[ni]) != @as(i64, old_ends[oi]) + shift) return null;

        prev_old_end = old_ends[oi];
        prev_new_end = new_ends[ni];
        ordinal += 1;
        oi += 1;
        ni += 1;
    }
    // Both ranges must have been confined to one gap.
    if (gap == null) return null;

    return .{
        .start = edit.start,
        .end = edit.end,
        .new_text = edit.new_text,
        .delta = delta,
    };
}
