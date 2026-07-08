//! In-place AST/CST splice paths for the incremental hot path.
//!
//! Three sibling entry points, dispatched by the driver in
//! `Incremental.tryIncrementalReparseInPlace` once an anchor and its
//! kind are pinned down:
//!
//!   - `tryAddSubSpliceInPlace` — symbol-free anchors (expressions and
//!     non-declaring statements). Sub-walks the old subtree to drop
//!     `use_count`, lowers the new subtree, slots it into the existing
//!     AST `*Stmt` / `*Expr`, and add-walks to re-resolve idents.
//!   - `tryCompoundSpliceInPlace` — `compound_stmt` anchors. The block
//!     is mutated in place by overwriting the `*CompoundStmt` pointee;
//!     the parent's pointer (function body, if-body, …) stays valid.
//!   - `tryDeclStmtSpliceInPlace` — `decl_stmt` anchors. A renamed `let`
//!     can invalidate sibling references by name, so the revisit root
//!     is the PARENT compound, not the decl_stmt.
//!
//! All three reuse `prev.arena` (no new ArenaAllocator per edit) and
//! commit by transferring arena ownership to the returned ReparseResult
//! while installing `Incremental.sentinel_stub` on `prev` so
//! `prev.deinit()` stays a safe no-op.
//!
//! Slot machinery (`findAstSlot`, `findCompoundBySpan`, the
//! `findSlotIn*` family, `matchesStmtKind` / `matchesExprKind`) lives
//! here too — these walkers exist solely to bridge a CST anchor's
//! byte-span back to the AST `*Stmt` / `*Expr` slot the splice
//! overwrites, and they have no callers outside this module.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("../Ast.zig");
const Cst = @import("../Cst.zig");
const Parser = @import("../Parser.zig");
const AstVisit = @import("../AstVisit.zig");
const Incremental = @import("../Incremental.zig");
const Errors = @import("Errors.zig");
const ScopeMap = @import("ScopeMap.zig");
const constants = @import("../constants.zig");

/// For a `compound_stmt` or `decl_stmt` anchor, return the `compound_stmt`
/// CST node we will revisit.
///
///   - compound_stmt → the anchor itself
///   - decl_stmt     → the nearest `compound_stmt` ancestor
///
/// Returns null if the decl_stmt's nearest statement container is NOT a
/// compound_stmt (legal positions: `for_stmt` init/update, where the
/// DeclStmt is stored by value inside `ForStmt` and the in-place
/// slot-replace story does not apply). Caller falls back to parseFull.
pub fn enclosingCompoundCst(cst: *const Cst.Tree, node: Cst.NodeIndex) ?Cst.NodeIndex {
    const start_kind = cst.getNode(node).kind;
    if (start_kind == .compound_stmt) return node;

    // decl_stmt anchor: walk parents until we hit compound_stmt or run
    // out of parents. The only other scope-opener kind is `for_stmt`;
    // hitting one means the decl_stmt sits in a for-init/update slot,
    // which the splice paths don't handle — bail.
    var cur = node;
    for (0..constants.max_tree_walk_iterations) |_| {
        const n = cst.getNode(cur);
        if (n.parent == cur) return null; // reached root without a compound_stmt
        cur = n.parent;
        const k = cst.getNode(cur).kind;
        if (k == .compound_stmt) return cur;
        if (k == .for_stmt) return null;
    } else unreachable;
}

/// DFS-collect every descendant scope of `root` into `out` in creation
/// (AST-append) order. Used to reconstruct `scopes_in_order` for a
/// targeted `AstVisit` over a previously-lowered subtree (sub-walk path).
pub fn collectScopeSubtreeDfs(
    arena: Allocator,
    root: *Ast.Scope,
    out: *std.ArrayList(*Ast.Scope),
) error{OutOfMemory}!void {
    for (root.children.items) |c| {
        try out.append(arena, c);
        try collectScopeSubtreeDfs(arena, c, out);
    }
}

/// Shared commit epilogue for every in-place splice path.
///
/// Points the reused module at `new_source`, splices `prev`'s parse errors
/// across the anchor edit and merges them with the add-walk's freshly
/// emitted entries (so `result.errors` matches a fresh full parse — the F-*
/// families in tests/incremental_error_fixup_test.zig gate this against a
/// parseFull oracle), then builds the `ReparseResult` that takes ownership
/// of `prev`'s arena / errors / retained_arenas and neutralizes `prev` so
/// its `deinit()` is a safe no-op. No append to `retained_arenas` — reusing
/// the arena in place is the whole point of this path. Callers must not
/// touch `prev` after this returns.
fn commitInPlace(
    gpa: Allocator,
    prev: *Incremental.ReparseResult,
    prev_arena: Allocator,
    new_source: [:0]const u8,
    new_tree: Cst.Tree,
    scope_for_cst_node: std.AutoHashMapUnmanaged(u32, *Ast.Scope),
    old_anchor_span: Ast.Span,
    delta: i64,
    add_errors: []const Parser.ParseError,
) Allocator.Error!Incremental.ReparseResult {
    prev.module.source = new_source;
    const fixed = try Errors.fixupErrors(prev_arena, prev.errors, old_anchor_span, delta);
    const merged = try Errors.mergeErrorsByPos(prev_arena, fixed, add_errors);

    const result = Incremental.ReparseResult{
        .gpa = gpa,
        .arena = prev.arena,
        .source = new_source,
        .module = prev.module,
        .cst = new_tree,
        .reused = true,
        .scope_for_cst_node = scope_for_cst_node,
        .retained_arenas = prev.retained_arenas,
        .errors = merged,
        .hot_edits_since_full = prev.hot_edits_since_full + 1,
        .module_version = prev.module_version +% 1,
    };

    prev.arena = &Incremental.sentinel_stub;
    prev.retained_arenas = .empty;
    prev.errors = &.{};
    prev.moved = true;

    return result;
}

/// In-place add/sub splice for symbol-free anchors.
///
/// Locates the AST `*Stmt` / `*Expr` slot whose span matches the old
/// anchor, sub-walks the slot's old contents to drop `use_count` for
/// every resolved ident, overwrites the slot with `new_lowered` (the AST
/// node the sub-parser already built alongside the anchor's CST, in
/// `prev.arena`), then add-walks the new subtree to rebind idents against
/// the prev module's symbol table.
///
/// `prev.arena` is reused (no new `ArenaAllocator`); `prev` is left
/// holding `sentinel_stub` so `prev.deinit()` stays a safe no-op.
pub fn tryAddSubSpliceInPlace(
    gpa: Allocator,
    prev: *Incremental.ReparseResult,
    new_source: [:0]const u8,
    new_tree_in: Cst.Tree,
    new_subtree_node: Cst.NodeIndex,
    anchor_kind: Cst.Kind,
    old_anchor_span: Ast.Span,
    new_lowered: Parser.ParsedAnchor,
) !Incremental.ReparseResult {
    var new_tree = new_tree_in;
    const prev_arena = prev.arena.allocator();

    // 1. Find the AST slot matching the old anchor.
    const info = findAstSlot(prev.module, old_anchor_span, anchor_kind) orelse return error.AstSlotNotFound;
    const slot = info.slot;

    // 2. Sub-walk: decrement use_counts for every resolved ident in the
    //    old subtree. Skipped only for slots inside an attribute whose
    //    args are NOT user-symbol references — `@builtin`, `@interpolate`,
    //    `@diagnostic` (per `Ast.attributeArgsResolveSymbols`). For those,
    //    full-parse Pass 2 never bumps the use count and never sets
    //    `IdentExpr.was_counted`, so a sub-walk would correctly do
    //    nothing — but skipping keeps the hot path symmetric with the
    //    add-walk's own predicate gate. For const-expression attrs
    //    (`@group`, `@workgroup_size`, `@id`, ...), full-parse DOES bump,
    //    so the hot path must decrement here to maintain parity.
    var discard_errors: std.ArrayList(Parser.ParseError) = .empty;
    defer discard_errors.deinit(prev_arena);
    var sub_ctx = AstVisit.Context{
        .arena = prev_arena,
        .symbols = prev.module.symbols.items,
        .scopes_in_order = &.{},
        .scope = prev.module.scope,
        .errors = &discard_errors,
        .safety_budget = @max(64, prev.cst.tokens.len * 2),
        .mode = .sub,
        .use_counts = &prev.module.use_counts,
    };
    const should_walk = !info.in_attribute or info.attr_resolves_symbols;
    if (should_walk) switch (slot) {
        .stmt => |p| try AstVisit.visitSubtreeStmt(&sub_ctx, p.*),
        .expr => |p| _ = try AstVisit.visitSubtreeExpr(&sub_ctx, p.*),
    };

    // 3. Shift downstream AST spans by delta before splicing in the new
    //    subtree (so spans remain consistent during the add-walk below).
    const old_len: u32 = old_anchor_span.end - old_anchor_span.start;
    const new_node_span = new_tree.getNode(new_subtree_node);
    const new_len: u32 = new_node_span.end - new_node_span.start;
    const delta: i64 = @as(i64, new_len) - @as(i64, old_len);
    prev.module.shiftModuleForEdit(old_anchor_span.end, delta);

    // 4. The new AST subtree is `new_lowered` — the node the sub-parser
    //    already built while emitting the anchor's CST (spans in current
    //    coordinates, ident refs unresolved). No second lowering.

    // 5. Splice AST in place.
    switch (slot) {
        .stmt => |p| switch (new_lowered) {
            .stmt => |s| p.* = s,
            .expr => return error.SlotKindMismatch,
        },
        .expr => |p| switch (new_lowered) {
            .expr => |e| p.* = e,
            .stmt => return error.SlotKindMismatch,
        },
    }

    // 6. Build the scope-for-CST-node map against the new tree.
    var tmp_result = Incremental.ReparseResult{
        .gpa = gpa,
        .arena = prev.arena,
        .source = new_source,
        .module = prev.module,
        .cst = new_tree,
    };
    try ScopeMap.buildScopeForCstNodeMap(prev_arena, &tmp_result);
    const anchor_scope = ScopeMap.scopeAtCstNode(&tmp_result, new_subtree_node);

    // 7. Add-walk. Skipped only for attr-arg slots whose enclosing
    //    attribute's args are enum-keyword (per the step-2 comment). For
    //    const-expression attrs, full-parse Pass 2 binds and bumps via
    //    `AstVisit.visitAttributes`, so the hot path mirrors that. Both
    //    paths gate on the same `attributeArgsResolveSymbols` predicate,
    //    so neither bumps `use_count` on idents the oracle leaves at zero.
    var add_errors: std.ArrayList(Parser.ParseError) = .empty;
    defer add_errors.deinit(prev_arena);
    var add_ctx = AstVisit.Context{
        .arena = prev_arena,
        .symbols = prev.module.symbols.items,
        .scopes_in_order = &.{},
        .scope = anchor_scope,
        .errors = &add_errors,
        .safety_budget = @max(64, new_tree.tokens.len * 2),
        .mode = .add,
        .use_counts = &prev.module.use_counts,
    };
    if (should_walk) switch (slot) {
        .stmt => |p| try AstVisit.visitSubtreeStmt(&add_ctx, p.*),
        .expr => |p| p.* = try AstVisit.visitSubtreeExpr(&add_ctx, p.*),
    };
    // Add-walk errors are not a fallback signal — typing an unresolved
    // identifier is a normal editing state. They get merged into the
    // result's error list below alongside prev's spliced-through errors.

    // 8. Commit — see commitInPlace: hands prev's arena / errors /
    //    retained_arenas to the result and neutralizes prev.
    return commitInPlace(gpa, prev, prev_arena, new_source, new_tree, tmp_result.scope_for_cst_node, old_anchor_span, delta, add_errors.items);
}

/// In-place splice for `compound_stmt` anchors.
///
/// Reuses prev.arena. Mutates the AST compound at the anchor's span in
/// place by copying the freshly-lowered compound's fields over it; the
/// parent's `*CompoundStmt` pointer stays valid. Symbols declared inside
/// the old compound stay in `module.symbols` with `use_count == 0`
/// (append-only; existing `SymbolIndex` values unchanged).
///
/// Ordering of mutations:
///   1. Resolve the OLD AST compound via span lookup.
///   2. Sub-walk the old compound (Pass 2 `.sub` mode) — decrements
///      use_counts for every resolved ident inside. Internal (let/var)
///      use_counts drop to 0 by construction.
///   3. Detach old block scope from its parent's children list.
///   4. Shift downstream AST spans by delta.
///   5. Re-parse the new subtree with `Parser.reparseAnchorInScope` —
///      appends symbols, pushes a fresh scope subtree under parent.
///   6. Reorder parent.children so the new scope sits at the OLD index
///      (pushScope always appends; move-to-position preserves DFS order).
///   7. Copy the new compound's fields over the old `*CompoundStmt`.
///   8. Rebuild `scope_for_cst_node`.
///   9. Add-walk the updated compound (Pass 2 `.add` mode) using the
///      freshly-collected `scopes_in_order`.
///   10. Fixup errors + commit arena transfer.
pub fn tryCompoundSpliceInPlace(
    gpa: Allocator,
    prev: *Incremental.ReparseResult,
    new_source: [:0]const u8,
    new_tree_in: Cst.Tree,
    new_subtree_node: Cst.NodeIndex,
    old_anchor_span: Ast.Span,
    new_stream: Parser.TokenStream,
    nt_pos: u32,
) !Incremental.ReparseResult {
    var new_tree = new_tree_in;
    const prev_arena = prev.arena.allocator();

    // 1. Resolve the OLD AST compound by span. The anchor CST range
    //    includes trivia; the AST compound's span uses non-trivia
    //    boundaries. Use the OLD scope map to retrieve the block scope
    //    the old compound opened, then match by scope → compound.
    const old_block_scope = prev.scope_for_cst_node.get(@intFromEnum(new_subtree_node)) orelse return error.ScopeSpliceMalformed;
    const parent_scope = old_block_scope.parent orelse return error.ScopeSpliceMalformed;

    const old_compound = findCompoundBySpan(prev.module, old_anchor_span) orelse return error.AstSlotNotFound;

    // 2. Sub-walk the old compound. Scopes_in_order is the DFS listing
    //    starting with the compound's own scope (the walker calls
    //    `enterNextScope` once on entering the compound).
    var sub_scopes: std.ArrayList(*Ast.Scope) = .empty;
    defer sub_scopes.deinit(prev_arena);
    try sub_scopes.append(prev_arena, old_block_scope);
    try collectScopeSubtreeDfs(prev_arena, old_block_scope, &sub_scopes);

    var discard_errors: std.ArrayList(Parser.ParseError) = .empty;
    defer discard_errors.deinit(prev_arena);
    var sub_ctx = AstVisit.Context{
        .arena = prev_arena,
        .symbols = prev.module.symbols.items,
        .scopes_in_order = sub_scopes.items,
        .scope = parent_scope,
        .errors = &discard_errors,
        .safety_budget = @max(64, prev.cst.tokens.len * 2),
        .mode = .sub,
        .use_counts = &prev.module.use_counts,
    };
    try AstVisit.visitSubtreeStmt(&sub_ctx, .{ .compound = old_compound });

    // 3. Detach old block scope from parent.children. Remember its index
    //    so we can insert the new scope at the same DFS position after
    //    `pushScope` appends it to the end of parent.children.
    const old_scope_idx = blk: {
        for (parent_scope.children.items, 0..) |c, i| {
            if (c == old_block_scope) break :blk i;
        }
        return error.ScopeSpliceMalformed;
    };
    _ = parent_scope.children.orderedRemove(old_scope_idx);

    // 4. Shift downstream AST spans by delta.
    const old_len: u32 = old_anchor_span.end - old_anchor_span.start;
    const new_node = new_tree.getNode(new_subtree_node);
    const new_len: u32 = new_node.end - new_node.start;
    const delta: i64 = @as(i64, new_len) - @as(i64, old_len);
    prev.module.shiftModuleForEdit(old_anchor_span.end, delta);

    // 5. Re-parse the new subtree under `parent_scope`, appending new
    //    symbols and pushing fresh scopes. The Parser's Pass 1 builds the
    //    same AST/symbols/scope tree the retired `CstLower.lowerSubtreeInScope`
    //    did (both run the identical `parseCompoundStmt`/`declareSymbol`/
    //    `pushScope` routines) — no CST is emitted; the anchor's CST is
    //    already spliced into `new_tree`. The reparse runs AFTER the step-3
    //    detach so `pushScope` sees the same sibling set the lower did.
    const lowered = try Parser.reparseAnchorInScope(
        prev_arena,
        new_source,
        new_stream,
        nt_pos,
        parent_scope,
        &prev.module.symbols,
    );
    const new_compound = switch (lowered.stmt) {
        .compound => |c| c,
        else => return error.SlotKindMismatch,
    };

    // The re-parsed block occupies the exact source slot the old block
    // held, so it must carry the old block's `sibling_index`. `pushScope`
    // (inside the lower) counted the same-kind siblings *remaining after
    // the step-3 detach*, which over-counts whenever the edited block was
    // not the last same-kind sibling — landing the replacement on the
    // wrong index vs a full parse. `new_scopes[0]` is the compound's own
    // block scope (pushed before any nested scope). Gated by
    // tests/incremental_mutation_test.zig "B3b-C2".
    if (lowered.new_scopes.items.len > 0) {
        lowered.new_scopes.items[0].sibling_index = old_block_scope.sibling_index;
    }

    // 6. `pushScope` appended the new block scope at the end of
    //    `parent_scope.children`. Move it back to `old_scope_idx` so DFS
    //    order is preserved for any downstream stable-ID / scope-walk
    //    consumer.
    const new_children = &parent_scope.children.items;
    const last = new_children.len - 1;
    if (last != old_scope_idx) {
        const top = new_children.*[last];
        var i: usize = last;
        while (i > old_scope_idx) : (i -= 1) {
            new_children.*[i] = new_children.*[i - 1];
        }
        new_children.*[old_scope_idx] = top;
    }

    // 7. Copy the new compound's fields over the in-place `*CompoundStmt`.
    //    The parent's pointer (function body, if-body, stmt.compound,
    //    etc.) stays valid; only the pointee's contents change.
    old_compound.* = new_compound.*;

    // 8. Rebuild scope_for_cst_node against the new CST + updated AST.
    var tmp_result = Incremental.ReparseResult{
        .gpa = gpa,
        .arena = prev.arena,
        .source = new_source,
        .module = prev.module,
        .cst = new_tree,
    };
    try ScopeMap.buildScopeForCstNodeMap(prev_arena, &tmp_result);

    // 9. Add-walk the updated compound. scopes_in_order must match what
    //    the walker will encounter: the compound's own scope first, then
    //    its DFS descendants — exactly what `reparseAnchorInScope` pushed.
    //    The compound's own scope is the LAST entry appended to
    //    `parent_scope.children` by the reparse (then moved to
    //    `old_scope_idx` above). Its descendants are in `lowered.new_scopes`
    //    minus the compound's own scope, which is the first entry of
    //    `new_scopes`.
    var add_scopes: std.ArrayList(*Ast.Scope) = .empty;
    defer add_scopes.deinit(prev_arena);
    try add_scopes.appendSlice(prev_arena, lowered.new_scopes.items);

    // The lower may have appended new symbols to `prev.module.symbols`;
    // grow `use_counts` to match before the add-walk indexes into it.
    try prev.module.resizeUseCounts(prev_arena, prev.module.symbols.items.len);

    var add_errors: std.ArrayList(Parser.ParseError) = .empty;
    defer add_errors.deinit(prev_arena);
    var add_ctx = AstVisit.Context{
        .arena = prev_arena,
        .symbols = prev.module.symbols.items,
        .scopes_in_order = add_scopes.items,
        .scope = parent_scope,
        .errors = &add_errors,
        .safety_budget = @max(64, new_tree.tokens.len * 2),
        .mode = .add,
        .use_counts = &prev.module.use_counts,
    };
    try AstVisit.visitSubtreeStmt(&add_ctx, .{ .compound = old_compound });

    // 10. Commit — see commitInPlace.
    return commitInPlace(gpa, prev, prev_arena, new_source, new_tree, tmp_result.scope_for_cst_node, old_anchor_span, delta, add_errors.items);
}

/// In-place splice for `decl_stmt` anchors.
///
/// Unlike compound_stmt, a decl_stmt edit can affect sibling statements
/// in the enclosing compound (a renamed `let` invalidates sibling refs
/// by name). The revisit root is therefore the PARENT compound_stmt,
/// not the decl_stmt itself.
///
/// Ordering:
///   1. Locate the parent compound_stmt CST node (`enclosingCompoundCst`).
///      Decl_stmts inside `for_stmt` init/update positions are stored by
///      value in `ForStmt` and don't fit the slot-replace story; bail in
///      that case so `reparse()` falls back to `parseFull`.
///   2. Resolve the parent AST compound (`findCompoundBySpan`) and the
///      parent block scope (`scope_for_cst_node`).
///   3. Find the decl_stmt's slot in `parent_compound.stmts.items` by
///      span match.
///   4. Read the OLD decl's name and remove it from `parent_scope.members`
///      so the forthcoming `declareSymbol` doesn't spuriously emit E0101
///      on a same-name re-decl.
///   5. Sub-walk the WHOLE parent compound (decrements use_counts for
///      every resolved ident across the parent + descendants; the
///      removed decl's symbol drops to use_count 0).
///   6. Shift downstream AST spans by delta.
///   7. Re-parse the new decl_stmt via `Parser.reparseAnchorInScope` —
///      appends a fresh symbol and `put`s its scope-member entry.
///   8. Write the new `Ast.Stmt` back into the parent's stmts slot.
///   9. Rebuild `scope_for_cst_node` and add-walk the parent compound
///      (resolves every ident, increments use_counts).
///   10. Fixup errors + commit arena transfer.
pub fn tryDeclStmtSpliceInPlace(
    gpa: Allocator,
    prev: *Incremental.ReparseResult,
    new_source: [:0]const u8,
    new_tree_in: Cst.Tree,
    new_subtree_node: Cst.NodeIndex,
    old_anchor_span: Ast.Span,
    new_stream: Parser.TokenStream,
    nt_pos: u32,
) !Incremental.ReparseResult {
    var new_tree = new_tree_in;
    const prev_arena = prev.arena.allocator();

    // 1. Revisit-root CST node = the enclosing compound_stmt. The anchor
    //    CST node was spliced into prev.cst by `Cst.spliceSubtree`, so
    //    its parent chain is still walkable.
    const parent_compound_cst = enclosingCompoundCst(&new_tree, new_subtree_node) orelse return error.DeclStmtNotInCompound;

    // 2. Parent AST compound + parent block scope.
    const parent_scope = prev.scope_for_cst_node.get(@intFromEnum(parent_compound_cst)) orelse return error.ScopeSpliceMalformed;

    // findCompoundBySpan wants the parent compound's OLD span. The
    // parent compound's CST range spans some bytes in NEW coords (its
    // end may have shifted by delta); its AST span is in OLD coords
    // (shifts happen in step 6, below). Reconstruct the OLD parent
    // span by un-shifting the NEW CST range.
    const parent_cst_node = new_tree.getNode(parent_compound_cst);
    const delta_for_parent: i64 = blk: {
        // The parent compound contains the anchor; its span grew by the
        // same delta as the anchor (end-shifted, start unchanged).
        const old_len: u32 = old_anchor_span.end - old_anchor_span.start;
        const new_anchor = new_tree.getNode(new_subtree_node);
        const new_len: u32 = new_anchor.end - new_anchor.start;
        break :blk @as(i64, new_len) - @as(i64, old_len);
    };
    const parent_span_old = Ast.Span{
        .start = parent_cst_node.start,
        .end = @intCast(@as(i64, parent_cst_node.end) - delta_for_parent),
    };
    const parent_compound = findCompoundBySpan(prev.module, parent_span_old) orelse return error.AstSlotNotFound;

    // 3. Find the decl_stmt slot in parent_compound.stmts by span
    //    containment (the anchor's CST range contains the AST decl_stmt's
    //    non-trivia span).
    const slot_idx = blk: {
        for (parent_compound.stmts.items, 0..) |s, i| {
            if (s != .decl) continue;
            if (spanContains(old_anchor_span, s.decl.span)) break :blk i;
        }
        return error.AstSlotNotFound;
    };
    const old_stmt = parent_compound.stmts.items[slot_idx];

    // 4. Remove the OLD decl's name from parent_scope.members, but only
    //    if it currently points at the OLD decl's symbol — a duplicate
    //    earlier decl with the same name (E0101 territory) should keep
    //    its entry. Entries referenced by a different (earlier) symbol
    //    index stay intact.
    const old_sym_idx = old_stmt.decl.decl.nameRef();
    if (old_sym_idx.isValid()) {
        const name = prev.module.symbols.items[old_sym_idx.index()].original_name;
        if (parent_scope.members.get(name)) |mem| {
            if (mem.ref == old_sym_idx) _ = parent_scope.members.remove(name);
        }
    }

    // 5. Sub-walk the PARENT compound (not just the decl). Uses
    //    scopes_in_order = [parent_scope] + DFS descendants so the
    //    walker's `enterNextScope` advances correctly.
    var sub_scopes: std.ArrayList(*Ast.Scope) = .empty;
    defer sub_scopes.deinit(prev_arena);
    try sub_scopes.append(prev_arena, parent_scope);
    try collectScopeSubtreeDfs(prev_arena, parent_scope, &sub_scopes);

    var discard_errors: std.ArrayList(Parser.ParseError) = .empty;
    defer discard_errors.deinit(prev_arena);
    var sub_ctx = AstVisit.Context{
        .arena = prev_arena,
        .symbols = prev.module.symbols.items,
        .scopes_in_order = sub_scopes.items,
        .scope = parent_scope.parent orelse prev.module.scope,
        .errors = &discard_errors,
        .safety_budget = @max(64, prev.cst.tokens.len * 2),
        .mode = .sub,
        .use_counts = &prev.module.use_counts,
    };
    try AstVisit.visitSubtreeStmt(&sub_ctx, .{ .compound = parent_compound });

    // 6. Shift downstream AST spans by delta.
    const old_len: u32 = old_anchor_span.end - old_anchor_span.start;
    const new_anchor_node = new_tree.getNode(new_subtree_node);
    const new_len: u32 = new_anchor_node.end - new_anchor_node.start;
    const delta: i64 = @as(i64, new_len) - @as(i64, old_len);
    prev.module.shiftModuleForEdit(old_anchor_span.end, delta);

    // 7. Re-parse the new decl_stmt into prev.arena. `reparseAnchorInScope`
    //    appends a fresh symbol to `module.symbols`, puts its entry into
    //    parent_scope.members (the old name was removed in step 4, so no
    //    spurious E0101), and (for decl_stmt) pushes no new scopes. Same
    //    Pass-1 build the retired `CstLower.lowerSubtreeInScope` produced.
    const lowered = try Parser.reparseAnchorInScope(
        prev_arena,
        new_source,
        new_stream,
        nt_pos,
        parent_scope,
        &prev.module.symbols,
    );
    // The reparse must have produced no new scopes for a decl_stmt. Defensive
    // check — if it did, something is off and we bail rather than leave
    // a stray scope attached.
    if (lowered.new_scopes.items.len != 0) return error.UnexpectedScopeInDecl;

    // 8. Replace the stmts slot.
    parent_compound.stmts.items[slot_idx] = lowered.stmt;

    // 9. Rebuild scope_for_cst_node; then add-walk the parent compound.
    var tmp_result = Incremental.ReparseResult{
        .gpa = gpa,
        .arena = prev.arena,
        .source = new_source,
        .module = prev.module,
        .cst = new_tree,
    };
    try ScopeMap.buildScopeForCstNodeMap(prev_arena, &tmp_result);

    var add_scopes: std.ArrayList(*Ast.Scope) = .empty;
    defer add_scopes.deinit(prev_arena);
    try add_scopes.append(prev_arena, parent_scope);
    try collectScopeSubtreeDfs(prev_arena, parent_scope, &add_scopes);

    // The lower may have appended new symbols to `prev.module.symbols`;
    // grow `use_counts` to match before the add-walk indexes into it.
    try prev.module.resizeUseCounts(prev_arena, prev.module.symbols.items.len);

    var add_errors: std.ArrayList(Parser.ParseError) = .empty;
    defer add_errors.deinit(prev_arena);
    var add_ctx = AstVisit.Context{
        .arena = prev_arena,
        .symbols = prev.module.symbols.items,
        .scopes_in_order = add_scopes.items,
        .scope = parent_scope.parent orelse prev.module.scope,
        .errors = &add_errors,
        .safety_budget = @max(64, new_tree.tokens.len * 2),
        .mode = .add,
        .use_counts = &prev.module.use_counts,
    };
    try AstVisit.visitSubtreeStmt(&add_ctx, .{ .compound = parent_compound });

    // 10. Commit — see commitInPlace.
    return commitInPlace(gpa, prev, prev_arena, new_source, new_tree, tmp_result.scope_for_cst_node, old_anchor_span, delta, add_errors.items);
}

// =========================================================================
// Slot-finder machinery.
//
// `findCompoundBySpan` and `findAstSlot` bridge a CST anchor's byte-span
// back to a mutable AST handle (a `*CompoundStmt`, or a `*Stmt` / `*Expr`
// slot). Used only by the splice paths above.
// =========================================================================

/// Return the outermost `*Ast.CompoundStmt` whose `span` is contained
/// within `target`. "Outermost" because the CST anchor range tightly
/// surrounds exactly one AST compound — the one whose non-trivia span
/// matches the anchor's first/last non-trivia tokens; any deeper
/// compound is a strict subset.
///
/// Walks through everything that can contain a CompoundStmt: function
/// bodies, standalone compound statements, if/switch/loop/for/while
/// bodies, plus for-init/update stmt positions.
fn findCompoundBySpan(module: *Ast.Module, target: Ast.Span) ?*Ast.CompoundStmt {
    // A prior splice may have left `interior_pending` on the decl that
    // contains this edit (as a "non-owner" decl for that earlier edit).
    // Absorb that bias now so the descendants' spans are in coordinates
    // that match `target` (which comes from the newly spliced CST).
    module.absorbOwnerFor(target);
    for (module.declarations.items) |decl| {
        if (findCompoundInDecl(decl, target)) |c| return c;
    }
    return null;
}

fn findCompoundInDecl(decl: Ast.Decl, target: Ast.Span) ?*Ast.CompoundStmt {
    return switch (decl) {
        .function => |f| if (f.body) |body| findCompoundInCompound(body, target) else null,
        else => null,
    };
}

fn findCompoundInCompound(c: *Ast.CompoundStmt, target: Ast.Span) ?*Ast.CompoundStmt {
    // This compound fits inside target → it is the outermost match.
    if (spanContains(target, c.span)) return c;
    // Otherwise, the only way a descendant can match is if this compound
    // strictly contains target. Skip disjoint compounds.
    if (!spanContains(c.span, target)) return null;
    for (c.stmts.items) |stmt| {
        if (findCompoundInStmt(stmt, target)) |m| return m;
    }
    return null;
}

fn findCompoundInStmt(s: Ast.Stmt, target: Ast.Span) ?*Ast.CompoundStmt {
    return switch (s) {
        .compound => |c| findCompoundInCompound(c, target),
        .@"if" => |ifs| blk: {
            if (findCompoundInCompound(ifs.body, target)) |m| break :blk m;
            if (ifs.else_branch) |eb| break :blk findCompoundInStmt(eb, target);
            break :blk null;
        },
        .@"switch" => |sw| blk: {
            for (sw.cases.items) |c| {
                if (findCompoundInCompound(c.body, target)) |m| break :blk m;
            }
            break :blk null;
        },
        .@"for" => |fs| blk: {
            if (fs.init_stmt) |is| if (findCompoundInStmt(is, target)) |m| break :blk m;
            if (fs.update) |u| if (findCompoundInStmt(u, target)) |m| break :blk m;
            break :blk findCompoundInCompound(fs.body, target);
        },
        .@"while" => |ws| findCompoundInCompound(ws.body, target),
        .loop => |l| blk: {
            if (findCompoundInCompound(l.body, target)) |m| break :blk m;
            if (l.continuing) |c| break :blk findCompoundInCompound(c, target);
            break :blk null;
        },
        else => null,
    };
}

/// Mutable reference to a statement- or expression-slot inside an AST.
/// Returned by `findAstSlot` so the hot path can rewrite the slot in
/// place without re-walking the parent.
const AstSlot = union(enum) {
    stmt: *Ast.Stmt,
    expr: *Ast.Expr,
};

/// Slot lookup result. `in_attribute` is true when the slot was reached
/// via `findSlotInAttribute` (i.e., it sits inside an `Ast.Attribute`'s
/// `args`). `attr_resolves_symbols` (only meaningful when `in_attribute`
/// is true) records whether the enclosing attribute's args are user-symbol
/// references — `AstVisit.visitDecl` walks those, and the hot-path add/sub
/// walks must mirror. False means the attribute is `@builtin`, `@interpolate`,
/// or `@diagnostic` (enum-keyword args); full-parse Pass 2 leaves their idents
/// at `use_count = 0`, so the hot path skips them too to keep parity.
const AstSlotInfo = struct {
    slot: AstSlot,
    in_attribute: bool,
    attr_resolves_symbols: bool = false,
};

/// Walks the module's AST looking for the slot whose span equals
/// `target` and whose kind matches `kind`. `kind` is the CST anchor kind
/// — we map it to the expected Ast.Stmt / Ast.Expr tag and return the
/// first slot that matches both.
///
/// Returns null if no matching slot exists (e.g., edit boundaries
/// crossed an Ast node the walker doesn't descend into, or the span was
/// empty). Caller falls back to `parseFull` on null.
fn findAstSlot(module: *Ast.Module, target: Ast.Span, kind: Cst.Kind) ?AstSlotInfo {
    // Absorb bias on the owning decl so descendants' spans match the
    // coordinate system of `target` (from the freshly-spliced CST).
    module.absorbOwnerFor(target);
    for (module.declarations.items) |*decl_ptr| {
        const decl = decl_ptr.*;
        if (findSlotInDecl(decl, target, kind)) |info| return info;
    }
    return null;
}

fn spanEq(a: Ast.Span, b: Ast.Span) bool {
    return a.start == b.start and a.end == b.end;
}

/// Does `outer` fully contain `inner`?
fn spanContains(outer: Ast.Span, inner: Ast.Span) bool {
    return outer.start <= inner.start and inner.end <= outer.end;
}

fn bareSlot(s: ?AstSlot) ?AstSlotInfo {
    return if (s) |slot| .{ .slot = slot, .in_attribute = false } else null;
}

fn attrSlot(s: ?AstSlot, attr_name: []const u8) ?AstSlotInfo {
    return if (s) |slot| .{
        .slot = slot,
        .in_attribute = true,
        .attr_resolves_symbols = Ast.attributeArgsResolveSymbols(attr_name),
    } else null;
}

fn findSlotInDecl(decl: Ast.Decl, target: Ast.Span, kind: Cst.Kind) ?AstSlotInfo {
    return switch (decl) {
        .@"const" => |d| if (d.initializer != null) bareSlot(findSlotInExprField(&d.initializer.?, d.initializer.?, target, kind)) else null,
        .override => |d| blk: {
            for (d.attributes.items) |*a| if (findSlotInAttribute(a, target, kind)) |m| break :blk attrSlot(m, a.name);
            if (d.initializer != null) break :blk bareSlot(findSlotInExprField(&d.initializer.?, d.initializer.?, target, kind));
            break :blk null;
        },
        .@"var" => |d| blk: {
            for (d.attributes.items) |*a| if (findSlotInAttribute(a, target, kind)) |m| break :blk attrSlot(m, a.name);
            if (d.initializer != null) break :blk bareSlot(findSlotInExprField(&d.initializer.?, d.initializer.?, target, kind));
            break :blk null;
        },
        .let => |d| if (d.initializer != null) bareSlot(findSlotInExprField(&d.initializer.?, d.initializer.?, target, kind)) else null,
        .function => |d| blk: {
            for (d.attributes.items) |*a| if (findSlotInAttribute(a, target, kind)) |m| break :blk attrSlot(m, a.name);
            for (d.parameters.items) |*p| {
                for (p.attributes.items) |*a| if (findSlotInAttribute(a, target, kind)) |m| break :blk attrSlot(m, a.name);
            }
            for (d.return_attr.items) |*a| if (findSlotInAttribute(a, target, kind)) |m| break :blk attrSlot(m, a.name);
            if (d.body) |body| break :blk findSlotInCompound(body, target, kind);
            break :blk null;
        },
        .@"struct" => |d| blk: {
            for (d.members.items) |*m| {
                for (m.attributes.items) |*a| if (findSlotInAttribute(a, target, kind)) |match| break :blk attrSlot(match, a.name);
            }
            break :blk null;
        },
        .alias => null,
        .const_assert => |d| bareSlot(findSlotInExprField(&d.expr, d.expr, target, kind)),
    };
}

fn findSlotInAttribute(attr: *Ast.Attribute, target: Ast.Span, kind: Cst.Kind) ?AstSlot {
    if (!spanContains(attr.span, target)) return null;
    for (attr.args.items) |*arg| {
        if (findSlotInExprField(arg, arg.*, target, kind)) |m| return m;
    }
    return null;
}

fn findSlotInCompound(body: *Ast.CompoundStmt, target: Ast.Span, kind: Cst.Kind) ?AstSlotInfo {
    for (body.stmts.items) |*stmt_ptr| {
        if (findSlotInStmt(stmt_ptr, target, kind)) |s| return s;
    }
    return null;
}

fn findSlotInStmt(stmt_ptr: *Ast.Stmt, target: Ast.Span, kind: Cst.Kind) ?AstSlotInfo {
    const stmt = stmt_ptr.*;
    const stmt_span = stmt.span();

    // Three span relationships to consider:
    //  - stmt is entirely inside target (`target` covers this stmt + leading
    //    trivia): candidate for stmt-kind anchor if kind matches.
    //  - target is entirely inside stmt: descend.
    //  - disjoint: skip.
    const stmt_fits_in_target = spanContains(target, stmt_span);
    const target_fits_in_stmt = spanContains(stmt_span, target);
    if (!stmt_fits_in_target and !target_fits_in_stmt) return null;

    if (stmt_fits_in_target and matchesStmtKind(stmt, kind)) {
        return .{ .slot = .{ .stmt = stmt_ptr }, .in_attribute = false };
    }

    // Descend into nested exprs and child compounds.
    switch (stmt) {
        .compound => |s| return findSlotInCompound(s, target, kind),
        .@"return" => |s| {
            if (s.value) |v| return bareSlot(findSlotInExprField(&s.value.?, v, target, kind));
            return null;
        },
        .@"if" => |s| {
            if (findSlotInExprField(&s.condition, s.condition, target, kind)) |m| return bareSlot(m);
            if (findSlotInCompound(s.body, target, kind)) |m| return m;
            if (s.else_branch != null) {
                return findSlotInStmt(&s.else_branch.?, target, kind);
            }
            return null;
        },
        .@"switch" => |s| {
            if (findSlotInExprField(&s.expr, s.expr, target, kind)) |m| return bareSlot(m);
            for (s.cases.items) |*c| {
                for (c.selectors.items) |*sel| {
                    if (findSlotInExprField(sel, sel.*, target, kind)) |m| return bareSlot(m);
                }
                if (findSlotInCompound(c.body, target, kind)) |m| return m;
            }
            return null;
        },
        .@"for" => |s| {
            if (s.init_stmt) |is| {
                // init_stmt is stored by value in ForStmt — we can't take
                // its mutable slot pointer through the union here, so
                // only descend if init_stmt itself contains target by
                // span. If the target IS the init_stmt, bail: a slot
                // replace at this position would have to rewrite the
                // ForStmt's by-value field, which the splice paths do
                // not handle.
                if (spanContains(is.span(), target)) {
                    if (spanEq(is.span(), target)) return null;
                    if (findSlotInStmt(&s.init_stmt.?, target, kind)) |m| return m;
                }
            }
            if (s.condition) |cond| {
                if (findSlotInExprField(&s.condition.?, cond, target, kind)) |m| return bareSlot(m);
            }
            if (s.update) |upd| {
                if (spanContains(upd.span(), target)) {
                    if (spanEq(upd.span(), target)) return null;
                    if (findSlotInStmt(&s.update.?, target, kind)) |m| return m;
                }
            }
            if (findSlotInCompound(s.body, target, kind)) |m| return m;
            return null;
        },
        .@"while" => |s| {
            if (findSlotInExprField(&s.condition, s.condition, target, kind)) |m| return bareSlot(m);
            if (findSlotInCompound(s.body, target, kind)) |m| return m;
            return null;
        },
        .loop => |s| {
            if (findSlotInCompound(s.body, target, kind)) |m| return m;
            if (s.continuing) |c| if (findSlotInCompound(c, target, kind)) |m| return m;
            return null;
        },
        .break_if => |s| return bareSlot(findSlotInExprField(&s.condition, s.condition, target, kind)),
        .assign => |s| {
            if (findSlotInExprField(&s.left, s.left, target, kind)) |m| return bareSlot(m);
            if (findSlotInExprField(&s.right, s.right, target, kind)) |m| return bareSlot(m);
            return null;
        },
        .incr_decr => |s| return bareSlot(findSlotInExprField(&s.expr, s.expr, target, kind)),
        .call => |s| {
            if (s.call.func) |f| if (findSlotInExprField(&s.call.func.?, f, target, kind)) |m| return bareSlot(m);
            for (s.call.args.items) |*arg| {
                if (findSlotInExprField(arg, arg.*, target, kind)) |m| return bareSlot(m);
            }
            return null;
        },
        .decl => |s| {
            // decl_stmt itself is not a symbol-free anchor, but the
            // initializer expression inside `let b = x;` is — descend
            // into the inner Decl to reach Expr slots. The inner decl
            // may have its own attributes (stmt-level attribute lists);
            // propagate `in_attribute` as findSlotInDecl sees fit.
            return findSlotInDecl(s.decl, target, kind);
        },
        .@"break", .@"continue", .discard => return null,
    }
}

fn findSlotInExprField(slot: *Ast.Expr, expr: Ast.Expr, target: Ast.Span, kind: Cst.Kind) ?AstSlot {
    const expr_span = expr.span();

    const expr_fits_in_target = spanContains(target, expr_span);
    const target_fits_in_expr = spanContains(expr_span, target);
    if (!expr_fits_in_target and !target_fits_in_expr) return null;

    // If this expression's span is inside the anchor's CST range (which
    // may include leading trivia) AND the kind matches, this is our
    // slot. The Parser emits Ast spans from non-trivia token
    // boundaries while the CST raw range can start on trivia — use
    // containment to bridge.
    if (expr_fits_in_target and matchesExprKind(expr, kind)) {
        return .{ .expr = slot };
    }
    switch (expr) {
        .literal, .ident => return null,
        .binary => |e| {
            if (findSlotInExprField(&e.left, e.left, target, kind)) |m| return m;
            if (findSlotInExprField(&e.right, e.right, target, kind)) |m| return m;
            return null;
        },
        .unary => |e| return findSlotInExprField(&e.operand, e.operand, target, kind),
        .call => |e| {
            if (e.func) |f| if (findSlotInExprField(&e.func.?, f, target, kind)) |m| return m;
            for (e.args.items) |*arg| {
                if (findSlotInExprField(arg, arg.*, target, kind)) |m| return m;
            }
            return null;
        },
        .index => |e| {
            if (findSlotInExprField(&e.base, e.base, target, kind)) |m| return m;
            if (findSlotInExprField(&e.idx, e.idx, target, kind)) |m| return m;
            return null;
        },
        .member => |e| return findSlotInExprField(&e.base, e.base, target, kind),
        .paren => |e| return findSlotInExprField(&e.expr, e.expr, target, kind),
    }
}

fn matchesStmtKind(s: Ast.Stmt, k: Cst.Kind) bool {
    return switch (k) {
        .return_stmt => s == .@"return",
        .assign_stmt => s == .assign,
        .incr_decr_stmt => s == .incr_decr,
        .call_stmt => s == .call,
        .break_stmt => s == .@"break",
        .break_if_stmt => s == .break_if,
        .continue_stmt => s == .@"continue",
        .discard_stmt => s == .discard,
        .compound_stmt => s == .compound,
        else => false,
    };
}

fn matchesExprKind(e: Ast.Expr, k: Cst.Kind) bool {
    return switch (k) {
        .literal_expr => e == .literal,
        .ident_expr => e == .ident,
        .binary_expr => e == .binary,
        .unary_expr => e == .unary,
        .call_expr => e == .call,
        .index_expr => e == .index,
        .member_expr => e == .member,
        .paren_expr => e == .paren,
        else => false,
    };
}
