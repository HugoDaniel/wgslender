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
/// lowering we trust on the incremental hot path. Symbol introduction
/// (e.g. inside `compound_stmt` or `decl_stmt`) is fine because the hot
/// path re-lowers the whole module via `CstLower.lowerTree`, which
/// rebuilds `module.symbols` and the scope tree from the spliced CST.
/// Surgical symbol-table patching (append-without-relower) is a later
/// optimization.
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
/// NOT symbol-free — they introduce scopes and/or symbols and stay on
/// the whole-module re-lower path in Phase 1.
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
/// root-level boundaries (e.g. spans across two top-level decls) — callers
/// must fall back to `parseFull` in that case. The current `reparse` still
/// full-parses regardless; this function is the scaffolding the hot path
/// will consume once subtree reuse lands.
pub fn findAnchor(cst: *const Cst.Tree, edit: Edit) ?Cst.Cursor {
    const root = cst.rootCursor();
    if (!containsEditForDescent(root, edit)) return null;

    var best: ?Cst.Cursor = if (isReparseAnchor(root.kind())) root else null;
    var cur = root;
    descend: while (true) {
        for (cur.childElements()) |el| {
            const n = el.asNode() orelse continue;
            const child = Cst.Cursor{ .tree = cur.tree, .node = n };
            if (!containsEditForDescent(child, edit)) continue;
            if (isReparseAnchor(child.kind())) best = child;
            cur = child;
            continue :descend;
        }
        break;
    }
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
        if (!std.mem.eql(u8, old_source[old_starts[i]..old_ends[i]], new_source[new_starts[i]..new_ends[i]])) {
            return .semantic;
        }
    }
    return .trivia_only;
}
