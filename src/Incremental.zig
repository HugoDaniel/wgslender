//! Incremental reparse driver.
//!
//! Top-level API for a unified parse state that carries the source, the
//! AST, and the CST side by side. `parseFull` builds it from scratch;
//! `reparse` applies a byte-level edit and returns an updated state,
//! reusing as much of the previous parse as the edit shape allows.
//!
//! `reparse` dispatches on the edit:
//!   - **Trivia-gap shortcut** (`Anchor.classifyTriviaEdit` gate passes) —
//!     an edit at ANY delta confined to a single inter-real-token trivia
//!     gap with an unchanged real-token ordinal stream reuses the module,
//!     symbol table, scope map, and CST topology: the source is swapped,
//!     the edited trivia gap retokenized, and byte offsets shifted. No
//!     re-lower, no symbol churn, nothing retired.
//!   - **Anchor splice** (`tryIncrementalReparseInPlace`) — find the
//!     smallest reparse-able CST subtree containing the edit, reparse
//!     just that anchor, splice the new subtree into prev's CST, then
//!     either patch the AST in place (symbol-free anchors) or re-lower
//!     the affected scope (compound_stmt / decl_stmt anchors).
//!   - **Fallback** — any failure on the splice path drops to a fresh
//!     full parse on a new arena. `parseFull` is the correctness oracle,
//!     so degrading to it is always safe.
//!
//! All splice paths reuse `prev.arena` rather than allocating a new one;
//! prev is left holding `sentinel_stub` so `prev.deinit()` stays a safe
//! no-op for callers that bracket each edit with `defer prev.deinit()`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Cst = @import("Cst.zig");
const Lexer = @import("Lexer.zig");
const Parser = @import("Parser.zig");
const AstVisit = @import("AstVisit.zig");
const Anchor = @import("incremental/Anchor.zig");
const Errors = @import("incremental/Errors.zig");
const ScopeMap = @import("incremental/ScopeMap.zig");
const Splice = @import("incremental/Splice.zig");

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

/// Re-exports of the CST↔AST scope-pairing surface. See
/// `src/incremental/ScopeMap.zig` for the implementation.
pub const scopeAtCstNode = ScopeMap.scopeAtCstNode;
pub const buildScopeForCstNodeMap = ScopeMap.buildScopeForCstNodeMap;

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
/// `prev.deinit()` stays a safe no-op. `retained_arenas` is **always
/// empty** after any `reparse` or `parseFull` return; the field is
/// kept so `arenaBytes()` sums defensively and external telemetry
/// readers don't break if a future path ever appends to it.
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
    retained_arenas: std.ArrayList(*std.heap.ArenaAllocator) = .empty,
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
    /// only by a strictly gated zero-delta trivia edit (real-token
    /// offsets cannot have moved); bumped by every other successful
    /// path — including non-zero-delta trivia, whose real-token CONTENT
    /// is unchanged but whose offset-keyed state (expr_types keys,
    /// f32_literal_locs, diagnostic ranges) moves with the delta,
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
    /// backstops that: both the anchor-splice path and the trivia
    /// shortcut bail with `error.EditCountWatermarkTripped` when it
    /// reaches `HOT_EDIT_COALESCE_MAX`, yielding one forced `parseFull`
    /// per 256-edit burst — every trivia edit (zero-delta included)
    /// allocates a fresh source copy and possibly token/node/child-table
    /// storage, so it counts. `parseFull` resets the counter to 0.
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
    // Keep the Parser's own AST. Since Block 1.2 the Parser stamps a
    // populated `span` on every `Ast.Expr`, so the incremental add/sub hot
    // path can locate the AST slot for a CST anchor directly from
    // `Expr.span()` — no second lowering pass over the CST is needed.
    const module = try parser.parse();
    const tree = try builder.finish(arena, all_tokens, owned_source);

    // Assemble the error list. `Parser.parse` appends its Pass-2 visit
    // errors (E0102) after all Pass-1 grammar errors, so `parser.errors`
    // is two internally source-ordered runs rather than one sorted list.
    // Split them apart and merge by position so the returned slice is
    // globally source-ordered — the order the LSP's `mergeErrorsInto`
    // appends verbatim into diagnostics.
    const grammar = try Errors.filterNonVisitErrors(arena, parser.errors.items);
    const visit = try Errors.filterVisitErrors(arena, parser.errors.items);
    const errors_slice = try Errors.mergeErrorsByPos(arena, grammar, visit);

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

    // Trivia shortcut at ANY delta. `classifyTriviaEdit` is the edit-aware
    // gate: identical non-trivia token count/tags/lengths/text, no error
    // tokens, the old and new edit ranges each confined to one
    // inter-non-trivia-token trivia gap, and every real token satisfying
    // the coordinate transform `new = old + (old >= edit.end ? delta : 0)`.
    // A passing gate means the shortcut can reuse prev's module, symbol
    // table, and CST topology: only the source bytes, one trivia gap, and
    // downstream byte offsets change. Any failure (watermark, gate, CST
    // rebuild, shift preflight) cascades to the anchor path and then
    // `parseFull` — the correctness oracle.
    if (tryTriviaOnlyShortcut(gpa, prev, edit, new_buf)) |result| {
        return result;
    } else |_| {
        // Watermark trips subsume the anchor path's thresholds (the trivia
        // floor is the largest of the three), so the cascade below lands on
        // `parseFull` exactly when the ruling requires it.
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

/// Trivia-only shortcut (any delta). For an edit the edit-aware gate in
/// `Anchor.classifyTriviaEdit` proves confined to one trivia gap with an
/// unchanged real-token ordinal stream, this reuses prev's module, symbol
/// table, scope map, and CST topology — no re-lower, no symbol churn, no
/// retirement. Only the source bytes, the edited gap's trivia tokens, and
/// downstream byte offsets change:
///
///   - The CST is rebuilt by `Cst.retokenizeTrivia` (node indices, kinds,
///     parents, and child structure preserved; ranges recomputed).
///   - AST spans / symbol locs / scope-member locs move through the
///     checked `Module.shiftModuleForTriviaEdit` (preflight + infallible
///     apply).
///   - Parse errors are spliced through `Errors.fixupErrors` with the
///     actual edited span and delta, allocated BEFORE the module is
///     mutated.
///   - `module_version` is bumped iff `delta != 0` (offset-keyed analysis
///     state — expr_types, f32_literal_locs, diagnostic ranges — moves),
///     and preserved for a strictly gated zero-delta edit.
///   - `hot_edits_since_full` increments: trivia edits allocate a new
///     source copy plus token/node/child-table storage comparable to the
///     splice paths, so they count toward both watermarks (4 MiB floor,
///     8 x source ratio, and HOT_EDIT_COALESCE_MAX).
///
/// A zero-delta subcase whose COMPLETE token stream (trivia included) is
/// identical may reuse the old CST node/child arrays directly — offsets
/// cannot have moved.
///
/// Callers can compare `result.module == prev_module_pointer` to confirm
/// the shortcut fired. On any failure the error cascades to the anchor
/// path; `prev` is left un-moved (speculative arena allocations may
/// remain — they are not visible semantic mutations).
fn tryTriviaOnlyShortcut(
    gpa: Allocator,
    prev: *ReparseResult,
    edit: Edit,
    new_buf: [:0]const u8,
) !ReparseResult {
    // Watermarks first, before any gate work. Both of these cascade to
    // `parseFull` (see reparseImpl).
    if (prev.hot_edits_since_full >= HOT_EDIT_COALESCE_MAX) return error.EditCountWatermarkTripped;
    const trivia_floor: usize = 4 * 1024 * 1024;
    const trivia_threshold: usize = @max(trivia_floor, prev.source.len * 8);
    if (prev.arena.queryCapacity() > trivia_threshold) return error.ArenaWatermarkTripped;

    // Gate work is speculative: on a failed gate the anchor path below
    // must still run against an untouched prev.arena, whose queryCapacity
    // feeds the compaction watermark. Leftover speculative allocations
    // (source copy plus the new source's full token stream — both scale
    // with new_text) would trip that watermark and force a parseFull
    // fallback on exactly the large-insert edits the anchor path handles
    // fine. So the gate lexes into a scratch arena that dies with the
    // scope, and only a passing gate adopts its findings into prev.arena.
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const owned_scratch = try scratch.allocator().allocSentinel(u8, new_buf.len, 0);
    @memcpy(owned_scratch, new_buf);

    // ONE lossless lex of the new source serves BOTH the edit-aware gate
    // and the CST rebuild (B3: the gate must not lex again; the old
    // side's all-token stream is `prev.cst.tokens` — no lex at all).
    var new_all_tokens_scratch = try Lexer.tokenizeAll(scratch.allocator(), owned_scratch);

    // Edit-aware gate — pure over the two all-token streams.
    const facts = Anchor.classifyTriviaEdit(prev.cst.source, &prev.cst.tokens, owned_scratch, &new_all_tokens_scratch, edit) orelse
        return error.NotTriviaConfined;

    // The gate passed. Adopt the speculative state into prev.arena: the
    // source copy always (the result's `source` and `module.source` point
    // at it), the token stream only when the CST will be rebuilt from it —
    // the identical-stream subcase below keeps prev's token arrays.
    const arena = prev.arena.allocator();
    const owned = try arena.allocSentinel(u8, new_buf.len, 0);
    @memcpy(owned, owned_scratch);

    // Zero-delta subcase with an identical COMPLETE token stream (trivia
    // tags, counts, and ranges included): nothing moved anywhere; reuse
    // the old node/child arrays byte-for-byte.
    const streams_identical = triviaStreamsIdentical(&prev.cst.tokens, &new_all_tokens_scratch);
    const new_all_tokens = if (streams_identical)
        new_all_tokens_scratch
    else
        try new_all_tokens_scratch.clone(arena);

    var new_tree: Cst.Tree = undefined;
    var new_errors: []Parser.ParseError = undefined;
    if (streams_identical) {
        new_tree = prev.cst;
        new_tree.source = owned;
        // Error positions cannot have moved; pass prev's list through.
        new_errors = prev.errors;
    } else {
        // Rebuild the trivia gap in the CST (fallible — unsupported
        // layouts bail to the anchor path).
        new_tree = try Cst.retokenizeTrivia(arena, &prev.cst, edit.start, edit.end, owned, new_all_tokens);

        // Splice the parse-error list across the edited span BEFORE
        // mutating the module: earlier entries unchanged, later pos/end
        // shifted by delta, pure insertions an empty old span. `prev.errors`
        // is never mutated.
        new_errors = try Errors.fixupErrors(
            arena,
            prev.errors,
            .{ .start = edit.start, .end = edit.end },
            facts.delta,
        );
    }

    // AST + symbol + scope-member offsets. The checked entry point
    // preflights every shifted offset and span ordering before an
    // infallible apply; a preflight failure cascades to `parseFull`
    // with prev still un-moved. Errors were already reallocated above,
    // so no fallible step remains after the module starts mutating.
    try prev.module.shiftModuleForTriviaEdit(edit.start, edit.end, facts.delta);

    prev.module.source = owned;

    const result = ReparseResult{
        .gpa = gpa,
        .arena = prev.arena,
        .source = owned,
        .module = prev.module,
        .cst = new_tree,
        .reused = true,
        .scope_for_cst_node = prev.scope_for_cst_node,
        .retained_arenas = prev.retained_arenas,
        .errors = new_errors,
        .hot_edits_since_full = prev.hot_edits_since_full + 1,
        // Bump whenever delta != 0: offset-keyed analysis state moves even
        // though the real-token CONTENT is unchanged. Preserve for a safe
        // zero-delta edit — real-token offsets did not move.
        .module_version = if (facts.delta != 0)
            prev.module_version +% 1
        else
            prev.module_version,
    };

    prev.arena = &sentinel_stub;
    prev.retained_arenas = .empty;
    prev.scope_for_cst_node = .empty;
    prev.errors = &.{};
    prev.moved = true;

    return result;
}

/// True when two all-token streams agree on count, tags, and byte ranges —
/// the precondition for reusing the old CST arrays wholesale.
fn triviaStreamsIdentical(
    a: *const std.MultiArrayList(Lexer.Token),
    b: *const std.MultiArrayList(Lexer.Token),
) bool {
    if (a.len != b.len) return false;
    const at = a.items(.tag);
    const bt = b.items(.tag);
    const as = a.items(.start);
    const bs = b.items(.start);
    const ae = a.items(.end);
    const be = b.items(.end);
    for (0..a.len) |i| {
        if (at[i] != bt[i] or as[i] != bs[i] or ae[i] != be[i]) return false;
    }
    return true;
}

// =========================================================================
// Anchor-splice driver.
//
// `tryIncrementalReparseInPlace` is the single entry point for every
// hot-path anchor kind. It allocates the new source, tokens, CST splice,
// and lowered AST subtree directly into `prev.arena`, then dispatches
// to the matching splice routine in `incremental/Splice.zig`:
//
//   - symbol-free anchors → `tryAddSubSpliceInPlace`
//   - `compound_stmt` anchors → `tryCompoundSpliceInPlace`
//   - `decl_stmt` anchors → `tryDeclStmtSpliceInPlace`
//
// On success, the returned `ReparseResult` reuses `prev.arena` directly
// (no `gpa.create(ArenaAllocator)` on the hot path), `retained_arenas`
// stays empty, and `prev` is set to `moved = true` with `sentinel_stub`
// installed so `prev.deinit()` remains a safe no-op.
// =========================================================================

fn tryIncrementalReparseInPlace(
    gpa: Allocator,
    prev: *ReparseResult,
    edit: Edit,
    new_buf: []const u8,
) !ReparseResult {
    // 1. Anchor lookup. Reads only prev.cst; no arena allocation yet.
    var anchor_cursor = findAnchor(&prev.cst, edit) orelse return error.NoAnchor;
    while (!Anchor.isHotPathAnchor(anchor_cursor.kind())) {
        anchor_cursor = anchor_cursor.parent() orelse return error.NotHotPathAnchor;
    }
    const anchor_kind = anchor_cursor.kind();

    // `isHotPathAnchor` admits exactly the union of symbol-free anchors
    // plus `compound_stmt` and `decl_stmt`. Each gets its own splice
    // routine in `incremental/Splice.zig` (dispatched at the bottom of
    // this function); any other kind reaching here would be a routing
    // bug.
    const is_compound_inplace = anchor_kind == .compound_stmt;
    const is_decl_stmt_inplace = anchor_kind == .decl_stmt;
    std.debug.assert(Anchor.isSymbolFreeAnchor(anchor_kind) or is_compound_inplace or is_decl_stmt_inplace);

    // 2. Compaction watermarks. The in-place path extends prev.arena
    //    forever; without a bound, a long editing session accumulates
    //    stale CST splices, old source copies, and dead token arrays.
    //    Two complementary watermarks bail to `parseFull` (which starts
    //    a fresh arena):
    //
    //    - Byte watermark: 8× the source size, with a floor that
    //      depends on anchor kind. Symbol-free edits cost ~KB each
    //      (one stmt/expr); compound_stmt and decl_stmt re-lower and
    //      re-visit the whole enclosing body plus append symbols, so
    //      they need a higher floor to avoid premature compaction on
    //      typical-sized shaders.
    //    - Edit count: tiny shaders can take hundreds of edits to
    //      trip the byte watermark, so `HOT_EDIT_COALESCE_MAX` caps
    //      consecutive in-place edits regardless of source size.
    if (prev.hot_edits_since_full >= HOT_EDIT_COALESCE_MAX) return error.EditCountWatermarkTripped;

    const big_floor: bool = is_compound_inplace or is_decl_stmt_inplace;
    const compaction_floor: usize = if (big_floor) 4 * 1024 * 1024 else 256 * 1024;
    const compaction_ratio: usize = 8;
    const threshold = @max(compaction_floor, prev.source.len * compaction_ratio);
    if (prev.arena.queryCapacity() > threshold) return error.ArenaWatermarkTripped;

    const arena = prev.arena.allocator();

    // 3. Copy the new source into prev.arena.
    const new_source = try arena.allocSentinel(u8, new_buf.len, 0);
    @memcpy(new_source, new_buf);

    // 4. Lex into prev.arena.
    var new_all_tokens = try Lexer.tokenizeAll(arena, new_source);
    const new_stream = try Parser.TokenStream.init(arena, &new_all_tokens);

    // 5. Locate the non-trivia token that begins the anchor.
    const anchor_byte = anchor_cursor.range().start;
    var nt_pos: u32 = 0;
    while (nt_pos < new_stream.non_trivia_starts.len and
        new_stream.non_trivia_starts[nt_pos] < anchor_byte) : (nt_pos += 1)
    {}
    if (nt_pos >= new_stream.non_trivia_starts.len) return error.AnchorBoundaryShifted;
    if (new_stream.non_trivia_starts[nt_pos] > edit.start) return error.AnchorBoundaryShifted;

    // 6. Reparse the anchor into prev.arena.
    var sub_builder = Cst.Builder.init(gpa);
    defer sub_builder.deinit();
    var sub_parser = try Parser.initWithCst(arena, new_source, new_stream, &sub_builder);
    const parser_kind: Parser.AnchorKind = if (Anchor.isStmtKind(anchor_kind)) .statement else .expression;
    // This unseeded reparse emits the anchor's CST (spliced below) and
    // validates its kind / coverage / clean-parse. For symbol-free anchors
    // the splice slots its AST node (`parsed_anchor`) straight in. The
    // compound_stmt / decl_stmt paths discard this node and re-parse the same
    // tokens seeded with the parent scope + symbol table
    // (`Parser.reparseAnchorInScope`), which they must do AFTER detaching the
    // old scope so `pushScope` counts the right siblings.
    const parsed_anchor = sub_parser.reparseAnchor(parser_kind, nt_pos) catch return error.AnchorParseFailed;
    if (sub_parser.errors.items.len > 0) return error.AnchorParseError;
    var new_sub = try sub_builder.finish(arena, new_all_tokens, new_source);

    // 7. Validate the reparse.
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

    // 8. Splice the CST into prev.arena.
    const new_tree = try Cst.spliceSubtree(arena, &prev.cst, anchor_cursor.node, &new_sub, new_source, new_all_tokens);

    // 9. Dispatch on anchor kind:
    //    - symbol-free → add/sub splice (rewrites one AST slot, re-runs
    //      the visit walker over the new subtree to rebind idents).
    //    - compound_stmt → scope-splice (rebuilds the enclosing block
    //      scope subtree, re-runs a targeted Pass 2 over the body).
    //    - decl_stmt → sibling path that revisits the decl's PARENT
    //      compound (a renamed decl can invalidate sibling references
    //      by name, so the revisit root has to be the parent block).
    if (is_compound_inplace) {
        return try Splice.tryCompoundSpliceInPlace(
            gpa,
            prev,
            new_source,
            new_tree,
            anchor_cursor.node,
            old_anchor_span,
            new_stream,
            nt_pos,
        );
    }
    if (is_decl_stmt_inplace) {
        return try Splice.tryDeclStmtSpliceInPlace(
            gpa,
            prev,
            new_source,
            new_tree,
            anchor_cursor.node,
            old_anchor_span,
            new_stream,
            nt_pos,
        );
    }
    return try Splice.tryAddSubSpliceInPlace(
        gpa,
        prev,
        new_source,
        new_tree,
        anchor_cursor.node,
        anchor_kind,
        old_anchor_span,
        parsed_anchor,
    );
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

test "Incremental.parseFull: grammar + visit errors merge in position order" {
    // Regression guard for the parseFull error-list contract. The parser
    // produces grammar errors in Pass 1 and visit errors (E0102) in Pass 2,
    // so its raw `errors` list is [all grammar] ++ [all visit] — NOT sorted
    // by position. parseFull must merge the two runs into a single
    // position-ordered list before returning.
    //
    // Here the visit error (`y` used before its `let` at pos 17) precedes
    // two later grammar errors (the `@@` at pos 31/32). A naive path that
    // returned the parser's raw error list would surface E0102 *last*;
    // this pins the merged, position-sorted order the LSP relies on
    // (`mergeErrorsInto` appends verbatim — it does not re-sort).
    var result = try Incremental.parseFull(testing.allocator, "fn f() { let x = y; let y = 1; @@ }");
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.errors.len);
    try testing.expectEqualStrings("E0102", result.errors[0].code);
    try testing.expectEqual(@as(u32, 17), result.errors[0].pos);
    try testing.expectEqual(@as(u32, 31), result.errors[1].pos);
    try testing.expectEqual(@as(u32, 32), result.errors[2].pos);
    // The two trailing entries are grammar errors (no code stamped).
    try testing.expectEqualStrings("", result.errors[1].code);
    try testing.expectEqualStrings("", result.errors[2].code);
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
