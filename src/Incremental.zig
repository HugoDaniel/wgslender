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
const CstLower = @import("CstLower.zig");
const Lexer = @import("Lexer.zig");
const Parser = @import("Parser.zig");
const AstVisit = @import("AstVisit.zig");
const Anchor = @import("incremental/Anchor.zig");
const Errors = @import("incremental/Errors.zig");

const Incremental = @This();

/// Re-exports of the anchor-classification surface. See
/// `src/incremental/Anchor.zig` for the actual definitions; the public
/// API of this module routes everything through these aliases so the
/// rest of the codebase keeps importing `@import("Incremental.zig")`.
pub const Edit = Anchor.Edit;
pub const EditKind = Anchor.EditKind;
pub const isReparseAnchor = Anchor.isReparseAnchor;
pub const findAnchor = Anchor.findAnchor;
pub const classifyEdit = Anchor.classifyEdit;

/// Maximum successful in-place hot-path reparses before the driver
/// forces a coalescing full parse. Pairs with the byte-watermark in
/// `tryIncrementalReparseInPlace`: the byte bound catches long sessions
/// on mid-size shaders, this count bound catches long sessions on tiny
/// shaders where arena capacity drifts slower than the keystroke rate.
/// Exposed for tests that assert exact coalesce boundaries.
pub const HOT_EDIT_COALESCE_MAX: u16 = 256;

/// Shared sentinel stub. Every hot-path return installs this on
/// `prev.arena` so `prev.deinit()` has something valid to call; no bytes
/// are ever allocated into it. `ReparseResult.deinit` detects this
/// pointer by identity and skips teardown. Backed by `page_allocator`
/// for process-lifetime independence from any caller's gpa — since
/// nothing ever allocates, `page_allocator` is never actually invoked.
/// Exposed for tests that assert sentinel identity after hot-path
/// returns.
pub var sentinel_stub: std.heap.ArenaAllocator =
    std.heap.ArenaAllocator.init(std.heap.page_allocator);

/// Result of a parse or reparse. Owns one or more arenas that hold the
/// module, CST, source bytes, and the scope-map. Dropping frees the lot.
///
/// **Ownership model.** `arena` always points to the "current" arena
/// from which fresh allocations happen. On every hot path (symbol-free,
/// `compound_stmt`, `decl_stmt`) this is simply `prev.arena` — extended
/// in place, not replaced — and `prev` receives an empty stub arena so
/// `prev.deinit()` stays a safe no-op. `retained_arenas` is reserved
/// for a future non-in-place path; today it is **always empty** after
/// any `reparse` or `parseFull` return. The field is kept so
/// `arenaBytes()` sums defensively and external telemetry readers
/// don't break if the invariant is ever relaxed.
///
/// **Lifecycle.** A `ReparseResult` is in one of three states:
///
///   1. **Fresh.** Returned by `parseFull` or by a successful
///      `reparse`. Owns its arena; every field is read-safe.
///      `moved == false`.
///   2. **Moved-from.** The `prev` argument to a successful `reparse`
///      call. Ownership of the arena, module pointer, CST, source,
///      scope map, and errors has been transferred to the returned
///      result. Only `deinit()` and reading `moved` are legal. Reading
///      any of `source`, `module`, `cst`, `scope_for_cst_node`,
///      `errors`, `retained_arenas`, or calling `arenaBytes` /
///      `scopeAtCstNode` is UB once the recipient's `deinit` fires,
///      and returns inconsistent state even before. `moved == true`,
///      `arena == &sentinel_stub`.
///   3. **Deinit'd.** `deinit()` has run. The struct is dead storage.
///
/// The state machine is one-way: Fresh → Moved-from (via `reparse`) →
/// Deinit'd (via `deinit`). A moved-from value can be `deinit`'d
/// directly — the sentinel-stub guard makes that a no-op. A moved-from
/// value cannot be reparsed again: `reparse` rejects it with
/// `error.PrevAlreadyMoved`.
pub const ReparseResult = struct {
    gpa: Allocator,
    arena: *std.heap.ArenaAllocator,
    /// Invariant: always empty. See the ownership-model block above.
    retained_arenas: std.ArrayListUnmanaged(*std.heap.ArenaAllocator) = .empty,
    source: [:0]const u8,
    module: *Ast.Module,
    cst: Cst.Tree,
    /// True if this result came from a subtree-reuse hot path in
    /// `reparse`. Tests and telemetry gate on this to measure hot-path
    /// coverage; callers treat it as informational only.
    reused: bool = false,
    /// True once another `reparse` call has taken ownership of this
    /// result's arena, module pointer, CST, source, scope map, and
    /// errors. A moved value is *legally inert*: the only safe
    /// operations are `deinit()` (a no-op on the sentinel arena) and
    /// reading `moved` itself. Every other field points at storage now
    /// co-owned by the recipient `ReparseResult` and may be freed by
    /// the recipient's `deinit` at any time.
    ///
    /// Set by every commit block in `tryTriviaOnlyShortcut`,
    /// `tryAddSubSpliceInPlace`, `tryCompoundSpliceInPlace`, and
    /// `tryDeclStmtSpliceInPlace`. Never set by `parseFull` or the
    /// fallback path — those leave `prev` untouched.
    moved: bool = false,
    /// Monotonic counter over "module has been mutated in a way that
    /// invalidates semantic caches (types, expr_types, struct_types,
    /// symbol_types, const_values, diagnostic line index)". Preserved
    /// by `tryTriviaOnlyShortcut` (zero-delta trivia cannot affect any
    /// of the above). Bumped by every other successful path, including
    /// symbol-free anchors (which mutate AST pointers), compound_stmt
    /// and decl_stmt (symbol table mutations), and `parseFull` (fresh
    /// module). Consumers that cache analysis results keyed off a
    /// `ReparseResult` compare the stored version against the current
    /// one to decide cache validity — pointer equality on `module` is
    /// insufficient because every hot path preserves the pointer by
    /// design. Wraps on overflow; callers must compare with `!=`.
    module_version: u32 = 0,
    /// Successful in-place hot-path reparses since the last full parse
    /// (either an initial `parseFull` or a coalescing fallback). The
    /// byte-watermark (`prev.arena.queryCapacity() > 8 * source.len`)
    /// bounds memory growth per edit, but can lag hundreds of edits on
    /// a tiny shader before the 256 KiB floor is passed. This counter
    /// backstops that: `tryIncrementalReparseInPlace` bails with
    /// `error.EditCountWatermarkTripped` when it reaches
    /// `HOT_EDIT_COALESCE_MAX`, yielding one forced `parseFull` per
    /// 256-edit burst. `parseFull` resets the counter to 0; the
    /// trivia-only shortcut preserves it (trivia costs nothing but also
    /// doesn't discharge accumulated debt on prev.arena).
    hot_edits_since_full: u16 = 0,
    /// Side-table mapping scope-opener CST nodes (fn_decl, compound_stmt,
    /// for_stmt) to the AST scope they correspond to. Populated by
    /// `buildScopeForCstNodeMap` after every full parse, and by the
    /// add/sub hot path after splice, so the hot path can locate an
    /// anchor's enclosing scope in O(CST depth) via `scopeAtCstNode`.
    ///
    /// Key is the raw `@intFromEnum(Cst.NodeIndex)` to keep the map
    /// storage `*Ast.Module`-agnostic. Lives on `ReparseResult` (not
    /// `Ast.Module`) so non-incremental consumers — `validate`,
    /// `minify`, `reflect` — pay no extra allocation.
    scope_for_cst_node: std.AutoHashMapUnmanaged(u32, *Ast.Scope) = .empty,

    /// Parser + Pass-2 (visit) errors collected while building this
    /// result, in source order. Allocated in `arena`. Empty after a
    /// clean parse. On the symbol-free hot path, prev's entries are
    /// spliced through `fixupErrors` and merged with the add-walk's new
    /// entries; on every other path (parseFull, full re-lower for
    /// compound_stmt/decl_stmt, trivia-only shortcut), this is the
    /// union of `Parser.errors` and `LowerCtx.errors` from the
    /// producing pass.
    errors: []Parser.ParseError = &.{},

    /// Total live + free-list capacity of every arena this result
    /// references, in bytes. Used by telemetry and the compaction
    /// watermark smoke test (M13) to bound long-session memory drift.
    pub fn arenaBytes(self: *const ReparseResult) usize {
        std.debug.assert(!self.moved);
        var bytes: usize = self.arena.queryCapacity();
        for (self.retained_arenas.items) |a| bytes += a.queryCapacity();
        return bytes;
    }

    pub fn deinit(self: *ReparseResult) void {
        // Invariant lock: the retained list should always be empty after
        // any `reparse` / `parseFull` return. This assertion catches any
        // future commit that reintroduces a growth site.
        std.debug.assert(self.retained_arenas.items.len == 0);

        // Drop retained arenas first (if any slipped through in a
        // non-debug build), then our own.
        for (self.retained_arenas.items) |a| {
            a.deinit();
            self.gpa.destroy(a);
        }
        self.retained_arenas.deinit(self.gpa);

        // Sentinel guard: hot-path returns leave the *old* ReparseResult
        // pointing at the shared `sentinel_stub`. That arena is
        // process-lifetime and must never be deinit'd or destroyed —
        // doing so would poison every subsequent hot-path return.
        if (self.arena != &sentinel_stub) {
            self.arena.deinit();
            self.gpa.destroy(self.arena);
        }
    }
};

/// Walk a CST node's ancestor chain until we find one that has a
/// registered scope in `result.scope_for_cst_node`, and return that scope.
/// Falls back to `result.module.scope` if none is found (e.g., when the
/// map is empty because the caller bypassed `buildScopeForCstNodeMap`).
///
/// Used by the add/sub hot path to position `AstVisit.Context.scope` at
/// the anchor's enclosing scope before an add-walk.
pub fn scopeAtCstNode(result: *const ReparseResult, node: Cst.NodeIndex) *Ast.Scope {
    std.debug.assert(!result.moved);
    var cur = node;
    while (true) {
        if (result.scope_for_cst_node.get(@intFromEnum(cur))) |s| return s;
        const n = result.cst.getNode(cur);
        if (n.parent == cur) return result.module.scope; // reached the root
        cur = n.parent;
    }
}

/// True when this CST kind opens an AST scope during lowering. Kept in
/// lockstep with the `pushScope` call sites in `Parser` and `CstLower`.
fn isScopeOpener(k: Cst.Kind) bool {
    return switch (k) {
        .fn_decl, .compound_stmt, .for_stmt => true,
        else => false,
    };
}

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
fn enclosingCompoundCst(cst: *const Cst.Tree, node: Cst.NodeIndex) ?Cst.NodeIndex {
    const start_kind = cst.getNode(node).kind;
    if (start_kind == .compound_stmt) return node;

    // decl_stmt anchor: walk parents until we hit compound_stmt or run
    // out of parents. Any intervening scope-opener that is NOT a
    // compound_stmt (only for_stmt qualifies today) means we are inside
    // a for-init/update slot — bail.
    var cur = node;
    while (true) {
        const n = cst.getNode(cur);
        if (n.parent == cur) return null; // reached root without a compound_stmt
        cur = n.parent;
        const k = cst.getNode(cur).kind;
        if (k == .compound_stmt) return cur;
        if (k == .for_stmt) return null;
    }
}

/// DFS-collect every descendant scope of `root` into `out` in creation
/// (AST-append) order. Used to reconstruct `scopes_in_order` for a
/// targeted `AstVisit` over a previously-lowered subtree (sub-walk path).
fn collectScopeSubtreeDfs(
    arena: Allocator,
    root: *Ast.Scope,
    out: *std.ArrayListUnmanaged(*Ast.Scope),
) error{OutOfMemory}!void {
    for (root.children.items) |c| {
        try out.append(arena, c);
        try collectScopeSubtreeDfs(arena, c, out);
    }
}

fn collectCstOpeners(
    gpa: Allocator,
    cst: *const Cst.Tree,
    node: Cst.NodeIndex,
    out: *std.ArrayListUnmanaged(Cst.NodeIndex),
) error{OutOfMemory}!void {
    const n = cst.getNode(node);
    if (isScopeOpener(n.kind)) try out.append(gpa, node);
    for (cst.children[n.first_child .. n.first_child + n.child_count]) |el| {
        if (el.asNode()) |child| {
            try collectCstOpeners(gpa, cst, child, out);
        }
    }
}

fn collectAstScopes(
    gpa: Allocator,
    scope: *Ast.Scope,
    out: *std.ArrayListUnmanaged(*Ast.Scope),
) error{OutOfMemory}!void {
    for (scope.children.items) |c| {
        try out.append(gpa, c);
        try collectAstScopes(gpa, c, out);
    }
}

/// Populate `result.scope_for_cst_node` by pairing CST scope-openers
/// (fn_decl, compound_stmt, for_stmt) with non-root AST scopes in the same
/// DFS-open order. Both front-ends (Parser and CstLower) push scopes in
/// the exact order the CST nodes are opened, so index-zip yields a
/// correct mapping.
///
/// Idempotent: re-runs clear the existing map first. Called from
/// `parseFull` at the end of each full parse and from the hot path after
/// a successful splice.
pub fn buildScopeForCstNodeMap(
    arena: Allocator,
    result: *ReparseResult,
) !void {
    result.scope_for_cst_node.clearRetainingCapacity();

    var cst_openers: std.ArrayListUnmanaged(Cst.NodeIndex) = .empty;
    defer cst_openers.deinit(arena);
    try collectCstOpeners(arena, &result.cst, result.cst.root(), &cst_openers);

    var ast_scopes: std.ArrayListUnmanaged(*Ast.Scope) = .empty;
    defer ast_scopes.deinit(arena);
    try collectAstScopes(arena, result.module.scope, &ast_scopes);

    // Parser/CstLower and the CST emit scope-openers in the same DFS-open
    // order, so cardinalities match. If they ever diverge, fall back to
    // an empty map — `scopeAtCstNode` still returns a valid scope (the
    // module) and the hot path's correctness degrades to a full
    // re-lower, not a crash.
    if (cst_openers.items.len != ast_scopes.items.len) return;

    try result.scope_for_cst_node.ensureTotalCapacity(arena, @intCast(cst_openers.items.len));
    for (cst_openers.items, ast_scopes.items) |opener, scope| {
        result.scope_for_cst_node.putAssumeCapacity(@intFromEnum(opener), scope);
    }
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
    _ = try parser.parse(); // drive the CST builder; discard Parser's AST
    const tree = try builder.finish(arena, all_tokens, owned_source);

    // Lower the AST from the CST. Using CstLower (not Parser.parse's
    // direct AST) means every `Ast.Expr` gains a populated `span`, which
    // the incremental add/sub hot path relies on to locate the AST slot
    // corresponding to a CST anchor.
    var visit_errors: std.ArrayListUnmanaged(Parser.ParseError) = .empty;
    const module = try CstLower.lowerTreeWithErrors(gpa, arena, &tree, &visit_errors);

    // Merge parser-grammar errors (E0001/E0004/E0101/E0401) with
    // CstLower's visit-pass errors (E0102). Skip parser's own visit-pass
    // entries — Parser.parse runs its own Pass 2 over the discarded
    // Parser AST and would double-report E0102; CstLower's pass over the
    // canonical CST-lowered AST is the source of truth.
    const parser_grammar = try Errors.filterNonVisitErrors(arena, parser.errors.items);
    const errors_slice = try Errors.mergeErrorsByPos(arena, parser_grammar, visit_errors.items);

    // Pair CST scope-opener nodes with the AST scopes produced in the
    // same DFS order, so `scopeAtCstNode` resolves in O(CST depth).
    var result = ReparseResult{
        .gpa = gpa,
        .arena = arena_ptr,
        .source = owned_source,
        .module = module,
        .cst = tree,
        .errors = errors_slice,
    };
    try buildScopeForCstNodeMap(arena, &result);
    return result;
}

/// Apply `edit` to `prev.source` and return a fresh `ReparseResult`
/// for the resulting source. Hot path: find a symbol-free anchor in
/// `prev.cst`, re-parse only that subtree, splice the CST, and re-lower.
///
/// **Precondition.** `prev.moved == false`. Passing a moved-from result
/// (one that was itself `prev` to an earlier successful `reparse`) is
/// rejected with `error.PrevAlreadyMoved` rather than silently reading
/// from a sentinel-stub arena. See `ReparseResult`'s lifecycle doc.
///
/// **Note.** `prev` is taken by mutable pointer because the add/sub hot
/// path transfers ownership of prev's arena into the new result. After
/// a successful hot-path `reparse`, `prev.moved` is true, `prev.arena`
/// points at the shared sentinel stub, and every other field of `prev`
/// becomes UB to read. `prev.deinit()` remains safe (the sentinel guard
/// short-circuits it), so callers that `defer prev.deinit()` keep
/// working without code changes — they just must not read `prev` after
/// the call returns.
///
/// Any hot-path failure falls back to `parseFull` (with `reused = false`
/// and an untouched prev), so correctness degrades gracefully into the
/// known-good full-parse path.
pub fn reparse(
    gpa: Allocator,
    prev: *ReparseResult,
    edit: Edit,
) !ReparseResult {
    if (prev.moved) return error.PrevAlreadyMoved;
    const result = try reparseImpl(gpa, prev, edit);
    // Invariant lock: every successful path must return a result with
    // zero retained arenas (see ReparseResult.retained_arenas doc).
    std.debug.assert(result.retained_arenas.items.len == 0);
    std.debug.assert(!result.moved);
    return result;
}

fn reparseImpl(
    gpa: Allocator,
    prev: *ReparseResult,
    edit: Edit,
) !ReparseResult {
    std.debug.assert(edit.start <= edit.end);
    std.debug.assert(edit.end <= prev.source.len);

    if (edit.isEmpty()) {
        // Pure no-op: still full-parse to return an independent result.
        // Callers that want to avoid the cost should short-circuit before
        // calling reparse.
        var result = try parseFull(gpa, prev.source);
        result.module_version = prev.module_version +% 1;
        return result;
    }

    // Build new source byte buffer. Needed both for the hot path and
    // the fallback, so compute it up front. Sentinel-terminated so it
    // can flow straight into `classifyEdit`.
    const new_len = prev.source.len - (edit.end - edit.start) + edit.new_text.len;
    const new_buf = try gpa.allocSentinel(u8, new_len, 0);
    defer gpa.free(new_buf);
    @memcpy(new_buf[0..edit.start], prev.source[0..edit.start]);
    @memcpy(new_buf[edit.start .. edit.start + edit.new_text.len], edit.new_text);
    @memcpy(
        new_buf[edit.start + edit.new_text.len ..],
        prev.source[edit.end..],
    );

    // Trivia-only fast path. A zero-delta edit (new_text.len equals
    // the replaced byte range) that leaves every non-trivia token
    // tag/length/text unchanged cannot affect the AST or the CST's
    // node ranges — just the source bytes and trivia content. Swap
    // the source pointer in place and reuse prev's module + CST
    // without re-lex, re-parse, or re-lower. Non-zero-delta trivia
    // edits (whitespace insert/delete, comment length changes) still
    // require shifting CST ranges and AST spans — they fall through
    // to the regular path.
    if (edit.new_text.len == (edit.end - edit.start)) {
        if (classifyEdit(gpa, prev.source, new_buf)) |kind| {
            if (kind == .trivia_only) {
                return tryTriviaOnlyShortcut(gpa, prev, new_buf);
            }
        } else |_| {
            // classifyEdit OOM'd — fall through to the regular path.
        }
    }

    // Attempt the hot path. On any fallback trigger, fall through to
    // `parseFull`. Wrapped in a small helper so every early return
    // still frees the scratch builder; failures land on the common
    // bottom path.
    if (tryIncrementalReparseInPlace(gpa, prev, edit, new_buf)) |result| {
        return result;
    } else |_| {
        // Any error (OOM, InvalidCst, kind mismatch, error_tree in the
        // reparsed subtree) bails to full reparse. parseFull is also
        // the correctness oracle, so this is safe.
    }

    var result = try parseFull(gpa, new_buf);
    result.module_version = prev.module_version +% 1;
    return result;
}

/// Zero-delta trivia-only shortcut. Copies the new source into
/// prev.arena, repoints `prev.module.source` at it, and transfers
/// prev's arena + retained list + scope map into the result. prev's
/// module pointer, CST struct, and symbol table are reused byte-for-
/// byte — callers can compare `result.module == prev_module_pointer`
/// to confirm the shortcut fired.
fn tryTriviaOnlyShortcut(
    gpa: Allocator,
    prev: *ReparseResult,
    new_buf: []const u8,
) !ReparseResult {
    const arena = prev.arena.allocator();
    const owned = try arena.allocSentinel(u8, new_buf.len, 0);
    @memcpy(owned, new_buf);

    prev.module.source = owned;

    // Trivia-only shortcut runs only when new_text.len == (end - start)
    // (zero-delta). No anchor is replaced, so prev's errors pass through
    // unchanged — same byte positions are still valid in the new source.
    // `hot_edits_since_full` is preserved: trivia doesn't allocate new
    // arena bytes but also doesn't discharge existing debt.
    const result = ReparseResult{
        .gpa = gpa,
        .arena = prev.arena,
        .source = owned,
        .module = prev.module,
        .cst = prev.cst,
        .reused = true,
        .scope_for_cst_node = prev.scope_for_cst_node,
        .retained_arenas = prev.retained_arenas,
        .errors = prev.errors,
        .hot_edits_since_full = prev.hot_edits_since_full,
        // Trivia-only zero-delta: non-trivia tokens are byte-identical,
        // spans unchanged, symbol table unchanged. Analysis caches keyed
        // off this version stay valid without a Validator re-run.
        .module_version = prev.module_version,
    };

    prev.arena = &sentinel_stub;
    prev.retained_arenas = .empty;
    prev.scope_for_cst_node = .empty;
    prev.errors = &.{};
    prev.moved = true;

    return result;
}

// =========================================================================
// In-place hot-path variant (see `docs/arena-transfer-zero-alloc-plan.md`).
//
// `tryIncrementalReparseInPlace` mirrors `tryIncrementalReparse` but for
// symbol-free anchors it allocates the new source, tokens, CST splice,
// and lowered AST subtree directly into `prev.arena`. On success:
//
//   - `result.arena = prev.arena` (no `gpa.create(ArenaAllocator)` on the
//     hot path).
//   - `result.retained_arenas = prev.retained_arenas` unchanged — prev's
//     own arena is NOT appended, so a hot-path burst doesn't grow the
//     retained chain.
//   - `prev` gets an empty stub arena so `prev.deinit()` stays a safe
//     no-op (unchanged semantics for callers).
//
// Non-symbol-free anchors (compound_stmt / decl_stmt) still go through
// the original fresh-arena path; this function delegates to
// `tryIncrementalReparse` for that case.
// =========================================================================

fn tryIncrementalReparseInPlace(
    gpa: Allocator,
    prev: *ReparseResult,
    edit: Edit,
    new_buf: []const u8,
) !ReparseResult {
    // 0. Compaction watermark. The in-place hot path extends prev.arena
    //    forever; left unchecked, a long editing session accumulates
    //    stale CST splices, old source copies, and dead token arrays in
    //    that arena. Before committing to another in-place edit, bail
    //    when prev.arena's live capacity has drifted past 8× the prev
    //    source size (floor 256 KiB to absorb the initial parse's
    //    overhead and to give short edit bursts on small sources room
    //    to run purely on the hot path). `reparse()` catches the error
    //    and falls through to `parseFull`, which allocates a clean
    //    arena and starts a new growth window.
    // 1. Anchor lookup — same as the fresh-arena path. Reads only
    //    prev.cst, no allocation into prev.arena yet.
    var anchor_cursor = findAnchor(&prev.cst, edit) orelse return error.NoAnchor;
    while (!Anchor.isHotPathAnchor(anchor_cursor.kind())) {
        anchor_cursor = anchor_cursor.parent() orelse return error.NotHotPathAnchor;
    }
    const anchor_kind = anchor_cursor.kind();

    // Route compound_stmt and decl_stmt anchors through the Phase 2
    // in-place scope-splice paths. `isHotPathAnchor` (checked above)
    // admits exactly the union of symbol-free + compound_stmt +
    // decl_stmt kinds, so any other kind here would be a routing bug.
    const is_compound_inplace = anchor_kind == .compound_stmt;
    const is_decl_stmt_inplace = anchor_kind == .decl_stmt;
    std.debug.assert(Anchor.isSymbolFreeAnchor(anchor_kind) or is_compound_inplace or is_decl_stmt_inplace);

    // 0. Compaction watermark. The in-place hot path extends prev.arena
    //    forever; left unchecked, a long editing session accumulates
    //    stale CST splices, old source copies, and dead token arrays in
    //    that arena. `reparse()` catches the error below and falls
    //    through to `parseFull`, which allocates a clean arena.
    //
    //    Symbol-free edits and compound/decl_stmt edits use different
    //    floors because their per-edit cost differs by roughly an order
    //    of magnitude: symbol-free touches one stmt/expr (~KB/edit);
    //    compound_stmt and decl_stmt re-lower and re-visit the entire
    //    enclosing body plus append symbols, so realistic edit bursts
    //    on typical module sizes need more headroom before compacting.
    // Edit-count coalesce. On tiny shaders the byte-watermark below
    // can take hundreds of edits to trip; this bound forces a fresh
    // parseFull every `HOT_EDIT_COALESCE_MAX` in-place extensions so
    // arena debt never accumulates without bound.
    if (prev.hot_edits_since_full >= HOT_EDIT_COALESCE_MAX) return error.EditCountWatermarkTripped;

    const big_floor: bool = is_compound_inplace or is_decl_stmt_inplace;
    const compaction_floor: usize = if (big_floor) 4 * 1024 * 1024 else 256 * 1024;
    const compaction_ratio: usize = 8;
    const threshold = @max(compaction_floor, prev.source.len * compaction_ratio);
    if (prev.arena.queryCapacity() > threshold) return error.ArenaWatermarkTripped;

    const arena = prev.arena.allocator();

    // 2. Copy the new source into prev.arena.
    const new_source = try arena.allocSentinel(u8, new_buf.len, 0);
    @memcpy(new_source, new_buf);

    // 3. Lex into prev.arena.
    var new_all_tokens = try Lexer.tokenizeAll(arena, new_source);
    const new_stream = try Parser.TokenStream.init(arena, &new_all_tokens);

    // 4. Locate the non-trivia token that begins the anchor.
    const anchor_byte = anchor_cursor.range().start;
    var nt_pos: u32 = 0;
    while (nt_pos < new_stream.non_trivia_starts.len and
        new_stream.non_trivia_starts[nt_pos] < anchor_byte) : (nt_pos += 1)
    {}
    if (nt_pos >= new_stream.non_trivia_starts.len) return error.AnchorBoundaryShifted;
    if (new_stream.non_trivia_starts[nt_pos] > edit.start) return error.AnchorBoundaryShifted;

    // 5. Reparse the anchor into prev.arena.
    var sub_builder = Cst.Builder.init(gpa);
    defer sub_builder.deinit();
    var sub_parser = try Parser.initWithCst(arena, new_source, new_stream, &sub_builder);
    const parser_kind: Parser.AnchorKind = if (Anchor.isStmtKind(anchor_kind)) .statement else .expression;
    sub_parser.reparseAnchor(parser_kind, nt_pos) catch return error.AnchorParseFailed;
    if (sub_parser.errors.items.len > 0) return error.AnchorParseError;
    var new_sub = try sub_builder.finish(arena, new_all_tokens, new_source);

    // 6. Validate the reparse — identical to the fresh-arena path.
    if (new_sub.nodes.len == 0) return error.AnchorParseFailed;
    if (new_sub.rootCursor().kind() != anchor_kind) return error.AnchorKindMismatch;
    if (new_sub.errors.len > 0) return error.AnchorParseError;
    if (new_sub.rootCursor().range().start == new_sub.rootCursor().range().end) {
        return error.AnchorParseFailed;
    }
    const old_anchor = anchor_cursor.range();
    const delta: i64 = @as(i64, @intCast(edit.new_text.len)) - @as(i64, edit.end - edit.start);
    const expected_new_end: u32 = @intCast(@as(i64, old_anchor.end) + delta);
    if (new_sub.rootCursor().range().end != expected_new_end) {
        return error.AnchorParseDidNotCoverEdit;
    }

    const old_anchor_span: Ast.Span = .{
        .start = anchor_cursor.range().start,
        .end = anchor_cursor.range().end,
    };

    // 7. Splice the CST into prev.arena.
    const new_tree = try Cst.spliceSubtree(arena, &prev.cst, anchor_cursor.node, &new_sub, new_source, new_all_tokens);

    // 8. Dispatch on anchor kind. Symbol-free anchors go through the
    //    existing add/sub splice. compound_stmt goes through the Phase 2
    //    scope-splice path which rebuilds the enclosing scope subtree
    //    and re-runs a targeted Pass 2. decl_stmt goes through a sibling
    //    path that revisits the decl's PARENT compound.
    if (is_compound_inplace) {
        return try tryCompoundSpliceInPlace(
            gpa,
            prev,
            new_source,
            new_tree,
            anchor_cursor.node,
            old_anchor_span,
        );
    }
    if (is_decl_stmt_inplace) {
        return try tryDeclStmtSpliceInPlace(
            gpa,
            prev,
            new_source,
            new_tree,
            anchor_cursor.node,
            old_anchor_span,
        );
    }
    return try tryAddSubSpliceInPlace(
        gpa,
        prev,
        new_source,
        new_tree,
        anchor_cursor.node,
        anchor_kind,
        old_anchor_span,
    );
}

/// In-place symbol-free add/sub splice. See `tryAddSubSplice` for the
/// semantics; the only difference is that `prev.arena` is reused rather
/// than replaced, so `retained_arenas` does not grow and no new
/// `ArenaAllocator` is created for the hot-path result itself. A stub
/// arena is still installed on `prev` so `prev.deinit()` remains a
/// safe no-op — one `gpa.create(ArenaAllocator)` per edit, down from
/// two.
fn tryAddSubSpliceInPlace(
    gpa: Allocator,
    prev: *ReparseResult,
    new_source: [:0]const u8,
    new_tree_in: Cst.Tree,
    new_subtree_node: Cst.NodeIndex,
    anchor_kind: Cst.Kind,
    old_anchor_span: Ast.Span,
) !ReparseResult {
    var new_tree = new_tree_in;
    const prev_arena = prev.arena.allocator();

    // 1. Find the AST slot matching the old anchor.
    const info = findAstSlot(prev.module, old_anchor_span, anchor_kind) orelse return error.AstSlotNotFound;
    const slot = info.slot;

    // 2. Sub-walk: decrement use_counts for every resolved ident in the
    //    old subtree. Skipped only for slots inside an attribute whose
    //    args are NOT user-symbol references — `@builtin`, `@interpolate`,
    //    `@diagnostic` (per `Ast.attributeArgsResolveSymbols`). For those,
    //    full-parse Pass 2 never bumps `use_count` and never sets
    //    `flags.use_count_incremented`, so a sub-walk would correctly do
    //    nothing — but skipping keeps the hot path symmetric with the
    //    add-walk's own predicate gate. For const-expression attrs
    //    (`@group`, `@workgroup_size`, `@id`, ...), full-parse DOES bump,
    //    so the hot path must decrement here to maintain parity.
    var discard_errors: std.ArrayListUnmanaged(Parser.ParseError) = .empty;
    defer discard_errors.deinit(prev_arena);
    var sub_ctx = AstVisit.Context{
        .arena = prev_arena,
        .symbols = prev.module.symbols.items,
        .scopes_in_order = &.{},
        .scope = prev.module.scope,
        .errors = &discard_errors,
        .safety_budget = @max(64, prev.cst.tokens.len * 2),
        .mode = .sub,
    };
    const should_walk = !info.in_attribute or info.attr_resolves_symbols;
    if (should_walk) switch (slot) {
        .stmt => |p| try AstVisit.visitSubtreeStmt(&sub_ctx, p.*),
        .expr => |p| _ = try AstVisit.visitSubtreeExpr(&sub_ctx, p.*),
    };

    // 3. Shift downstream AST spans by delta before splicing in the new
    //    subtree — same ordering as `tryAddSubSplice`.
    const old_len: u32 = old_anchor_span.end - old_anchor_span.start;
    const new_node_span = new_tree.getNode(new_subtree_node);
    const new_len: u32 = new_node_span.end - new_node_span.start;
    const delta: i64 = @as(i64, new_len) - @as(i64, old_len);
    prev.module.shiftModuleForEdit(old_anchor_span.end, delta);

    // 4. Lower the new CST subtree into prev.arena.
    const new_lowered = try CstLower.lowerSubtree(prev_arena, &new_tree, new_subtree_node);

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
    var tmp_result = ReparseResult{
        .gpa = gpa,
        .arena = prev.arena,
        .source = new_source,
        .module = prev.module,
        .cst = new_tree,
    };
    try buildScopeForCstNodeMap(prev_arena, &tmp_result);
    const anchor_scope = scopeAtCstNode(&tmp_result, new_subtree_node);

    // 7. Add-walk. Skipped only for attr-arg slots whose enclosing
    //    attribute's args are enum-keyword (per the step-2 comment). For
    //    const-expression attrs, full-parse Pass 2 binds and bumps via
    //    `AstVisit.visitAttributes`, so the hot path mirrors here. The
    //    historical hazard the gate guarded against — bumping `use_count`
    //    on sibling symbols that the oracle leaves at zero — is now
    //    closed by the predicate filter in both paths.
    var add_errors: std.ArrayListUnmanaged(Parser.ParseError) = .empty;
    defer add_errors.deinit(prev_arena);
    var add_ctx = AstVisit.Context{
        .arena = prev_arena,
        .symbols = prev.module.symbols.items,
        .scopes_in_order = &.{},
        .scope = anchor_scope,
        .errors = &add_errors,
        .safety_budget = @max(64, new_tree.tokens.len * 2),
        .mode = .add,
    };
    if (should_walk) switch (slot) {
        .stmt => |p| try AstVisit.visitSubtreeStmt(&add_ctx, p.*),
        .expr => |p| p.* = try AstVisit.visitSubtreeExpr(&add_ctx, p.*),
    };
    // Add-walk errors are not a fallback signal — typing an unresolved
    // identifier is a normal editing state. They get merged into the
    // result's error list below alongside prev's spliced-through errors.

    // 8. Commit: hand prev.arena (and prev.retained_arenas unchanged) to
    //    the result. Install an empty stub on prev. No append to
    //    retained_arenas — this is the whole point of the in-place path.
    prev.module.source = new_source;

    // Splice prev's parse errors across the anchor edit and merge with
    // the add-walk's freshly emitted entries. After this, `result.errors`
    // matches what a fresh full parse of the new source would produce
    // (the F-* test families in tests/incremental_error_fixup_test.zig
    // verify this against a parseFull oracle).
    const fixed = try Errors.fixupErrors(prev_arena, prev.errors, old_anchor_span, delta);
    const merged = try Errors.mergeErrorsByPos(prev_arena, fixed, add_errors.items);

    const result = ReparseResult{
        .gpa = gpa,
        .arena = prev.arena,
        .source = new_source,
        .module = prev.module,
        .cst = new_tree,
        .reused = true,
        .scope_for_cst_node = tmp_result.scope_for_cst_node,
        .retained_arenas = prev.retained_arenas,
        .errors = merged,
        .hot_edits_since_full = prev.hot_edits_since_full + 1,
        .module_version = prev.module_version +% 1,
    };

    prev.arena = &sentinel_stub;
    prev.retained_arenas = .empty;
    prev.errors = &.{};
    prev.moved = true;

    return result;
}

/// Phase 2 in-place splice for `compound_stmt` anchors.
///
/// Reuses prev.arena. Mutates the AST compound at the anchor's span in
/// place by copying the freshly-lowered compound's fields over it; the
/// parent's `*CompoundStmt` pointer stays valid. Symbols declared inside
/// the old compound stay in `module.symbols` with `use_count == 0`
/// (append-only; existing `SymbolIndex` values unchanged).
///
/// Ordering of mutations, gated on every validation already passed
/// upstream:
///   1. Resolve the OLD AST compound via span lookup.
///   2. Sub-walk the old compound (Pass 2 `.sub` mode) — decrements
///      use_counts for every resolved ident inside. Internal (let/var)
///      use_counts drop to 0 by construction.
///   3. Detach old block scope from its parent's children list.
///   4. Shift downstream AST spans by delta.
///   5. Lower the new subtree with `CstLower.lowerSubtreeInScope` —
///      appends symbols, pushes a fresh scope subtree under parent.
///   6. Reorder parent.children so the new scope sits at the OLD index
///      (pushScope always appends; move-to-position preserves DFS order).
///   7. Copy the new compound's fields over the old `*CompoundStmt`.
///   8. Rebuild `scope_for_cst_node`.
///   9. Add-walk the updated compound (Pass 2 `.add` mode) using the
///      freshly-collected `scopes_in_order`.
///   10. Fixup errors + commit arena transfer.
fn tryCompoundSpliceInPlace(
    gpa: Allocator,
    prev: *ReparseResult,
    new_source: [:0]const u8,
    new_tree_in: Cst.Tree,
    new_subtree_node: Cst.NodeIndex,
    old_anchor_span: Ast.Span,
) !ReparseResult {
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
    var sub_scopes: std.ArrayListUnmanaged(*Ast.Scope) = .empty;
    defer sub_scopes.deinit(prev_arena);
    try sub_scopes.append(prev_arena, old_block_scope);
    try collectScopeSubtreeDfs(prev_arena, old_block_scope, &sub_scopes);

    var discard_errors: std.ArrayListUnmanaged(Parser.ParseError) = .empty;
    defer discard_errors.deinit(prev_arena);
    var sub_ctx = AstVisit.Context{
        .arena = prev_arena,
        .symbols = prev.module.symbols.items,
        .scopes_in_order = sub_scopes.items,
        .scope = parent_scope,
        .errors = &discard_errors,
        .safety_budget = @max(64, prev.cst.tokens.len * 2),
        .mode = .sub,
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

    // 5. Lower the new subtree under `parent_scope`, appending new
    //    symbols and pushing fresh scopes.
    const lowered = try CstLower.lowerSubtreeInScope(
        prev_arena,
        &new_tree,
        new_subtree_node,
        parent_scope,
        &prev.module.symbols,
    );
    const new_compound = switch (lowered.stmt) {
        .compound => |c| c,
        else => return error.SlotKindMismatch,
    };

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
    var tmp_result = ReparseResult{
        .gpa = gpa,
        .arena = prev.arena,
        .source = new_source,
        .module = prev.module,
        .cst = new_tree,
    };
    try buildScopeForCstNodeMap(prev_arena, &tmp_result);

    // 9. Add-walk the updated compound. scopes_in_order must match what
    //    the walker will encounter: the compound's own scope first, then
    //    its DFS descendants — exactly what `lowerSubtreeInScope` pushed.
    //    The compound's own scope is the LAST entry appended to
    //    `parent_scope.children` by the lower (then moved to
    //    `old_scope_idx` above). Its descendants are in `lowered.new_scopes`
    //    minus the compound's own scope, which is the first entry of
    //    `new_scopes`.
    var add_scopes: std.ArrayListUnmanaged(*Ast.Scope) = .empty;
    defer add_scopes.deinit(prev_arena);
    try add_scopes.appendSlice(prev_arena, lowered.new_scopes.items);

    var add_errors: std.ArrayListUnmanaged(Parser.ParseError) = .empty;
    defer add_errors.deinit(prev_arena);
    var add_ctx = AstVisit.Context{
        .arena = prev_arena,
        .symbols = prev.module.symbols.items,
        .scopes_in_order = add_scopes.items,
        .scope = parent_scope,
        .errors = &add_errors,
        .safety_budget = @max(64, new_tree.tokens.len * 2),
        .mode = .add,
    };
    try AstVisit.visitSubtreeStmt(&add_ctx, .{ .compound = old_compound });

    // 10. Commit.
    prev.module.source = new_source;

    const fixed = try Errors.fixupErrors(prev_arena, prev.errors, old_anchor_span, delta);
    const merged = try Errors.mergeErrorsByPos(prev_arena, fixed, add_errors.items);

    const result = ReparseResult{
        .gpa = gpa,
        .arena = prev.arena,
        .source = new_source,
        .module = prev.module,
        .cst = new_tree,
        .reused = true,
        .scope_for_cst_node = tmp_result.scope_for_cst_node,
        .retained_arenas = prev.retained_arenas,
        .errors = merged,
        .hot_edits_since_full = prev.hot_edits_since_full + 1,
        .module_version = prev.module_version +% 1,
    };

    prev.arena = &sentinel_stub;
    prev.retained_arenas = .empty;
    prev.errors = &.{};
    prev.moved = true;

    return result;
}

/// Phase 2 in-place splice for `decl_stmt` anchors.
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
///   7. Lower the new decl_stmt via `CstLower.lowerSubtreeInScope` —
///      appends a fresh symbol and `put`s its scope-member entry.
///   8. Write the new `Ast.Stmt` back into the parent's stmts slot.
///   9. Rebuild `scope_for_cst_node` and add-walk the parent compound
///      (resolves every ident, increments use_counts).
///   10. Fixup errors + commit arena transfer.
fn tryDeclStmtSpliceInPlace(
    gpa: Allocator,
    prev: *ReparseResult,
    new_source: [:0]const u8,
    new_tree_in: Cst.Tree,
    new_subtree_node: Cst.NodeIndex,
    old_anchor_span: Ast.Span,
) !ReparseResult {
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
    var sub_scopes: std.ArrayListUnmanaged(*Ast.Scope) = .empty;
    defer sub_scopes.deinit(prev_arena);
    try sub_scopes.append(prev_arena, parent_scope);
    try collectScopeSubtreeDfs(prev_arena, parent_scope, &sub_scopes);

    var discard_errors: std.ArrayListUnmanaged(Parser.ParseError) = .empty;
    defer discard_errors.deinit(prev_arena);
    var sub_ctx = AstVisit.Context{
        .arena = prev_arena,
        .symbols = prev.module.symbols.items,
        .scopes_in_order = sub_scopes.items,
        .scope = parent_scope.parent orelse prev.module.scope,
        .errors = &discard_errors,
        .safety_budget = @max(64, prev.cst.tokens.len * 2),
        .mode = .sub,
    };
    try AstVisit.visitSubtreeStmt(&sub_ctx, .{ .compound = parent_compound });

    // 6. Shift downstream AST spans by delta.
    const old_len: u32 = old_anchor_span.end - old_anchor_span.start;
    const new_anchor_node = new_tree.getNode(new_subtree_node);
    const new_len: u32 = new_anchor_node.end - new_anchor_node.start;
    const delta: i64 = @as(i64, new_len) - @as(i64, old_len);
    prev.module.shiftModuleForEdit(old_anchor_span.end, delta);

    // 7. Lower the new decl_stmt into prev.arena. `lowerSubtreeInScope`
    //    appends a fresh symbol to `module.symbols`, puts its entry into
    //    parent_scope.members, and (for decl_stmt) pushes no new scopes.
    const lowered = try CstLower.lowerSubtreeInScope(
        prev_arena,
        &new_tree,
        new_subtree_node,
        parent_scope,
        &prev.module.symbols,
    );
    // The lower must have produced no new scopes for a decl_stmt. Defensive
    // check — if it did, something is off and we bail rather than leave
    // a stray scope attached.
    if (lowered.new_scopes.items.len != 0) return error.UnexpectedScopeInDecl;

    // 8. Replace the stmts slot.
    parent_compound.stmts.items[slot_idx] = lowered.stmt;

    // 9. Rebuild scope_for_cst_node; then add-walk the parent compound.
    var tmp_result = ReparseResult{
        .gpa = gpa,
        .arena = prev.arena,
        .source = new_source,
        .module = prev.module,
        .cst = new_tree,
    };
    try buildScopeForCstNodeMap(prev_arena, &tmp_result);

    var add_scopes: std.ArrayListUnmanaged(*Ast.Scope) = .empty;
    defer add_scopes.deinit(prev_arena);
    try add_scopes.append(prev_arena, parent_scope);
    try collectScopeSubtreeDfs(prev_arena, parent_scope, &add_scopes);

    var add_errors: std.ArrayListUnmanaged(Parser.ParseError) = .empty;
    defer add_errors.deinit(prev_arena);
    var add_ctx = AstVisit.Context{
        .arena = prev_arena,
        .symbols = prev.module.symbols.items,
        .scopes_in_order = add_scopes.items,
        .scope = parent_scope.parent orelse prev.module.scope,
        .errors = &add_errors,
        .safety_budget = @max(64, new_tree.tokens.len * 2),
        .mode = .add,
    };
    try AstVisit.visitSubtreeStmt(&add_ctx, .{ .compound = parent_compound });

    // 10. Commit.
    prev.module.source = new_source;

    const fixed = try Errors.fixupErrors(prev_arena, prev.errors, old_anchor_span, delta);
    const merged = try Errors.mergeErrorsByPos(prev_arena, fixed, add_errors.items);

    const result = ReparseResult{
        .gpa = gpa,
        .arena = prev.arena,
        .source = new_source,
        .module = prev.module,
        .cst = new_tree,
        .reused = true,
        .scope_for_cst_node = tmp_result.scope_for_cst_node,
        .retained_arenas = prev.retained_arenas,
        .errors = merged,
        .hot_edits_since_full = prev.hot_edits_since_full + 1,
        .module_version = prev.module_version +% 1,
    };

    prev.arena = &sentinel_stub;
    prev.retained_arenas = .empty;
    prev.errors = &.{};
    prev.moved = true;

    return result;
}

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
                // span. If the target IS the init_stmt, bail (non-anchor
                // position in Phase 1).
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
    // slot. Parser/CstLower emits Ast spans from non-trivia token
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

test "Incremental.reparse: reused flag is true on hot-path literal edit" {
    var base = try Incremental.parseFull(testing.allocator, "const x = 1;");
    defer base.deinit();
    try testing.expect(!base.reused);

    // Replace "1" with "42". Anchor is literal_expr, which is
    // symbol-free; hot path fires.
    var updated = try Incremental.reparse(testing.allocator, &base, .{
        .start = 10,
        .end = 11,
        .new_text = "42",
    });
    defer updated.deinit();
    try testing.expectEqualStrings("const x = 42;", updated.source);
    try testing.expect(updated.reused);
}

test "Incremental.reparse: reused flag is false when fallback fires" {
    // Top-level decl edit — the whole `const_decl` anchor is not in
    // the symbol-free allowlist, so the hot path bails and we fall
    // back to parseFull with `reused = false`.
    const base_src: [:0]const u8 = "const x = 1;\nconst y = 2;";
    var base = try Incremental.parseFull(testing.allocator, base_src);
    defer base.deinit();

    // Rename `y` → `yy` at its declaration site (byte 19).
    var updated = try Incremental.reparse(testing.allocator, &base, .{
        .start = 19,
        .end = 20,
        .new_text = "yy",
    });
    defer updated.deinit();
    try testing.expectEqualStrings("const x = 1;\nconst yy = 2;", updated.source);
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

test "Incremental.scopeAtCstNode: literal inside fn body resolves to block scope" {
    const src: [:0]const u8 = "fn f() { let x = 7; return x; }";
    var base = try Incremental.parseFull(testing.allocator, src);
    defer base.deinit();

    // Locate the literal expression `7` — an anchor somewhere deep
    // inside the function body.
    const off: u32 = @intCast(std.mem.indexOfScalar(u8, src, '7').?);
    const anchor = Incremental.findAnchor(&base.cst, .{
        .start = off,
        .end = off + 1,
        .new_text = "8",
    }) orelse return error.TestUnexpectedNull;

    const scope = Incremental.scopeAtCstNode(&base, anchor.node);
    // The anchor's enclosing scope must be a block (the fn body), parent
    // must be a function scope, and grandparent must be the module.
    try testing.expectEqual(Ast.ScopeKind.block, scope.kind);
    const parent = scope.parent orelse return error.TestUnexpectedNull;
    try testing.expectEqual(Ast.ScopeKind.function, parent.kind);
    const gp = parent.parent orelse return error.TestUnexpectedNull;
    try testing.expectEqual(Ast.ScopeKind.module, gp.kind);
    try testing.expect(gp.parent == null);
}

test "Incremental.scopeAtCstNode: module-level anchor falls through to module.scope" {
    const src: [:0]const u8 = "const x = 1;";
    var base = try Incremental.parseFull(testing.allocator, src);
    defer base.deinit();

    const off: u32 = @intCast(std.mem.indexOfScalar(u8, src, '1').?);
    const anchor = Incremental.findAnchor(&base.cst, .{
        .start = off,
        .end = off + 1,
        .new_text = "2",
    }) orelse return error.TestUnexpectedNull;

    const scope = Incremental.scopeAtCstNode(&base, anchor.node);
    try testing.expectEqual(base.module.scope, scope);
}
