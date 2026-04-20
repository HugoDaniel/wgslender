# Arena transfer for zero-alloc hot path

Follow-on to the incremental-reparse roadmap
(`~/.claude/plans/consider-the-plan-wgsl-bidirectional-too-flickering-cat.md`).
Stages 1–6 of that plan are landed; add/sub splice lives in
`src/Incremental.zig`, and the `S-*` / `M1–M8` test families lock in
correctness. This plan removes the per-hot-path arena allocation and the
unbounded growth of `retained_arenas`.

## Problem

On a successful symbol-free hot path (`tryAddSubSplice`):

- `gpa.create(ArenaAllocator)` + `ArenaAllocator.init` allocates a new
  arena (`src/Incremental.zig:482`).
- Prev's arena is appended to the new result's `retained_arenas`
  (`src/Incremental.zig:774`).
- A second `gpa.create(ArenaAllocator)` + `init` produces an empty stub
  arena for prev (`src/Incremental.zig:781`).

Net per edit: **2 arena-struct allocations**, **2 ArenaAllocator inits**,
**+1 retained-arena entry**. `M8.b` asserts the exact linear growth:
`retained_arenas.items.len == N` after `N` edits. Over a multi-thousand-edit
LSP session this piles up arena structs and holds every stale token /
source / CST copy from the session.

## Goal

A symbol-free hot-path reparse performs **zero arena-level allocations**:
no `gpa.create(ArenaAllocator)`, no `init`, no stub, no growth of
`retained_arenas`. The single live arena keeps absorbing per-edit bytes
as today; a watermark trips a full reparse when it crosses a bound.

Explicit non-goals: changing the fallback path, changing the slow
re-lower path (compound_stmt / decl_stmt), changing LSP protocol,
changing any FFI surface.

## Design

### In-place hot path

Today's `tryIncrementalReparse` allocates the new arena **before** it
knows whether the anchor is symbol-free. The new design inverts that:

1. Compute `new_buf` on `gpa` as scratch (same as today; freed in
   `defer`).
2. Run anchor lookup against `prev.cst` using prev's arena only for
   intermediates.
3. Allocate new_source, re-lex output, sub-CST builder backing, spliced
   CST, and (if symbol-free) the lowered AST subtree **all into
   prev.arena**.
4. On success, return a `ReparseResult` that reuses prev.arena and
   inherits prev.retained_arenas **without appending** prev.arena.
5. Install `.empty` stub + `.empty` retained list on prev so
   `prev.deinit()` stays a no-op.

On any pre-commit failure — `AnchorParseFailed`, `AnchorKindMismatch`,
`AnchorParseError`, `AddWalkRaisedErrors`, etc. — prev's *fields*
(`module`, `cst`, `source`) are byte-exact unchanged; only prev.arena's
byte pool has garbage in it, which `parseFull` ignores and which prev's
eventual `deinit` reclaims.

**Ordering invariant.** All commit-point mutations
(`slot.* = new_lowered`, `prev.module.source = new_source`,
`shiftAstSpans`, `sub_ctx` walk that decrements `use_count`) fire only
**after** every validation gate passes. The sub-walk currently runs at
`Incremental.zig:689` before validation is complete — it must move after
`AnchorParseError` and the span/coverage checks, or be replaced with a
dry-run decrement that's applied at the commit point.

### Watermark-triggered compaction

Per-edit arena growth is the same as today (we just stop wrapping it in
a fresh struct). To bound total footprint, before attempting the hot
path check:

```
arena_bytes = prev.arena.queryCapacity()
if arena_bytes > max(16_384, 8 * prev.source.len): fall through to parseFull
```

This produces exactly one full reparse whenever live arena size crosses
~8× source size, giving us a clean arena again. The constant is
documented in-line; tunable if benchmarks show otherwise.

### Trivia-only shortcut

`Incremental.classifyEdit` already distinguishes trivia-only edits. Add
a front door in `reparse`:

```
if classifyEdit(prev.source, new_buf) == .trivia_only:
    owned = prev.arena.allocSentinel(u8, new_buf.len, 0)
    @memcpy(owned, new_buf)
    prev.module.source = owned
    # shift token start/end in prev.cst by the edit delta — trivia-only
    # means same token count, same tags, only byte positions move
    shiftTokenBytes(&prev.cst, edit, delta)
    return ReparseResult{
        arena = prev.arena,
        module = prev.module,    # pointer-identical to prev
        cst = prev.cst,          # pointer-identical to prev
        source = owned,
        reused = true,
        retained_arenas = prev.retained_arenas,
    }  # then install stub on prev as usual
```

Module + CST pointer-identity is the distinguishing observable; a
`M12`-series test asserts it.

### Optional stats (`-Dincremental-stats`)

Compile-time flag exposes:
- `ReparseResult.arena_bytes: usize` — measured at result construction
- counter for `new_arenas_allocated` (`parseFull` bumps it; hot path
  must not)
- counter for `retained_arenas_peak: usize`

Off by default; tests that assert these values `@import("build_options")`
it and skip when the flag is disabled.

## Rollout

Each step is a self-contained commit; each must pass
`zig build test && zig build && zig build wasm && zig build lsp && zig build lsp-wasm`.

1. **`refactor(incremental): introduce in-place hot-path arena reuse`**
   - Factor `tryIncrementalReparse` so the new-arena allocation moves
     past the anchor classification. Introduce
     `tryIncrementalReparseInPlace` gated by a comptime flag
     (`in_place_hot_path`) so the old behavior is still reachable.
2. **`test(incremental): M9 — retained_arenas stays flat under hot churn`**
   - Add the five M9 scenarios below. They fail with the flag off, pass
     with it on. Running both states in CI is optional; we just need the
     targeted assertions.
3. **`feat(incremental): default to in-place hot path; remove stub + retained append`**
   - Delete the comptime flag, delete the stub-arena allocation, delete
     the retained-append on hot path. Update `M8.b` / delete it
     (superseded by `M9.a`).
4. **`feat(incremental): watermark-triggered compaction`**
   - Add the pre-hot-path size check. Add M10 tests.
5. **`test(incremental): M11 — fallback after partial hot-path writes`**
   - Ensure a late failure leaves prev walkable and the next edit still
     hot-paths. Extends S8 / S16 / M5.e with chained follow-ups.
6. **`feat(incremental): trivia-only shortcut in reparse`**
   - Front-door in `reparse`. Add M12 tests. Wire into
     `lsp/Handler.updateParseAfterEdit` so trivia-only `didChange`
     doesn't touch CST/AST.
7. **`bench: arena stats on long edit sequences`**
   - Add a BENCHMARK.md row + M13 smoke test gated on `-Dincremental-stats`.

## Test scenarios (new M-series)

### M9 — `retained_arenas` stays flat per hot-path edit

Oracle: `parseFull(updated.source)` shape + per-symbol `use_count`.

| ID   | Base                                       | Edit stream                                                                 | Assert                                                           |
|------|--------------------------------------------|-----------------------------------------------------------------------------|------------------------------------------------------------------|
| M9.a | `fn f() -> i32 { return 1 + 2; }`          | 30× literal flip 0–9 on `2`                                                 | each iter: `reused` ∧ `retained_arenas.len == 0`                 |
| M9.b | adds `const a=1; const b=2;` at module     | 20× alternate `return 1 + a;` ↔ `return 1 + b;`                             | `reused`; retained len 0; per-symbol `use_count` matches oracle  |
| M9.c | `fn f(){ let a=1; return a; }`             | 20× alternate `return a;` ↔ `return a + 0;`                                 | `reused` on both anchor kinds; retained len 0                    |
| M9.d | `@compute @workgroup_size(8) fn f() {}`    | 20× literal flip in attribute arg                                           | retained len 0 (stresses M1 path)                                |
| M9.e | two fns in one module                      | interleave 10 hot edits in fnA body, 10 in fnB body                         | retained len 0; both fns' symbol counts correct                  |

### M10 — Arena compaction watermark

| ID    | Scenario                                              | Assert                                                                              |
|-------|-------------------------------------------------------|-------------------------------------------------------------------------------------|
| M10.a | 500× literal churn on a 64-byte base                  | exactly one iteration has `reused == false`; all others `reused == true`           |
| M10.b | mixed 2KB insert edits                                 | watermark trips within first 10 iterations                                          |
| M10.c | 1000× churn on a 32KB synthetic shader                 | trip count within ±1 of `N × avg_edit_bytes / (8 × source_len)`                     |
| M10.d | `-Dincremental-stats=true`                             | `new_arenas_allocated == 1 + number_of_watermark_trips`                             |

### M11 — Hot-path failure must not corrupt prev's arena semantics

| ID    | Trigger (existing repro in parentheses)                | Assert                                                                 |
|-------|--------------------------------------------------------|------------------------------------------------------------------------|
| M11.a | `AnchorKindMismatch` (S8: `1` → `1 * 3` in a literal)  | result correct; a follow-up hot edit on the new result succeeds         |
| M11.b | `AnchorParseError` (S16: `return 2;` → `return +;`)    | same                                                                    |
| M11.c | `AddWalkRaisedErrors` (M5.e use-before-decl)           | same                                                                    |
| M11.d | `InvalidCst` from `lowerSubtree` (placeholder; skip if no natural reproducer) | same                                           |
| M11.e | Allocation injection: failing allocator on N-th alloc, N=1..20 | final module matches clean-gpa `parseFull`; no leaks                  |

### M12 — Trivia-only shortcut

| ID    | Edit                                                  | Assert                                                                  |
|-------|-------------------------------------------------------|-------------------------------------------------------------------------|
| M12.a | Insert `// comment\n` at start of file                | `updated.module == prev.module` (pointer eq); `updated.cst.*` eq; retained 0 |
| M12.b | Extra whitespace between two tokens                   | same pointer-eq checks                                                  |
| M12.c | Replace a block comment body                           | same                                                                    |
| M12.d | Insert `/*` that swallows real code (NOT trivia-only) | `module` pointer must NOT equal prev.module; shortcut must not fire     |

### M13 — Chained-edit memory envelope (smoke, gated on `-Dincremental-stats`)

100-edit sequence on `tests/testdata/compute.toys/prelude.wgsl`; assert
`arena_bytes < 16 × source.len` throughout, proving the watermark bounds
growth rather than only triggering at the end.

### Edit-count coalescing

The byte-watermark above is necessary but not sufficient. On a tiny
shader (< ~100 bytes) where per-edit arena cost stays small relative
to the 256 KiB floor, the byte bound can lag hundreds of edits before
it trips. `HOT_EDIT_COALESCE_MAX = 256` (`src/Incremental.zig`) caps
the number of successful in-place reparses per arena refill cycle:
`tryIncrementalReparseInPlace` raises `error.EditCountWatermarkTripped`
when `prev.hot_edits_since_full` reaches the bound, `reparse()` falls
through to `parseFull`, and the counter resets. On realistic shaders
the byte-watermark trips first and the edit-count bound never
activates; it is a defense-in-depth backstop, not a primary bound.

Threshold rationale: 256 is safely above typical IDE paste bursts
(~100-200 contiguous edits) yet disciplined enough to bound tiny-shader
growth well before the 256 KiB floor would otherwise be reached.
Power-of-two keeps it visible in telemetry. No benchmarking required
because coalescing only decides *when* a full parse runs; the full
parse is already the correctness oracle tested by M11/M13.

### M14 — Chained-reparse invariants across mutation sections

One test per mutation section asserting `retained_arenas.items.len == 0`
on every iteration and correct `hot_edits_since_full` increment/reset
semantics. Long bursts also gate on `coalesce_count >= 1` (or >= 2 for
M14.d/M14.g). M14.e observes counter monotonicity directly.

| ID    | Section       | Fixture                                                     | Edits | Assertion                          |
|-------|---------------|-------------------------------------------------------------|-------|------------------------------------|
| M14.a | M1 attr arg   | `@group(0) @binding(0) var<uniform> u: f32;`                | 300   | invariants + coalesce_count >= 1  |
| M14.b | M3 for-loop   | `fn f() { for (var i=0; i<10; i=i+1) {} }`                  | 300   | invariants + coalesce_count >= 1  |
| M14.c | M4 switch     | `fn f(x:i32) { switch(x) { case 0: {} case 1: {} default: {} } }` | 300 | invariants + coalesce_count >= 1 |
| M14.d | M5 if/else    | `fn f(x:i32)->i32 { if (x>0) { return 1; } else { return 2; } }` | 600 | invariants + coalesce_count >= 2 |
| M14.e | M6 loop/while | `fn f() { var i=0; loop { if (i>5) { break; } i=i+1; } }`   | 200   | monotonic counter + correct reset |
| M14.f | M7 member     | `struct S { a: f32 } fn f(s: S) -> f32 { return s.a; }`     | 300   | invariants + post-coalesce reuse  |
| M14.g | M9 extended   | `fn f() -> i32 { return 1 + 2; }`                           | 512   | invariants + coalesce_count >= 2  |

### M15 — Cross-section sentinel

One test that runs every M14 fixture through a 60-edit burst and
asserts `retained_arenas.items.len == 0` on every result. Catches any
future commit that introduces a new growth site on any mutation
section without going through the edit-count coalesce path.

## Files touched

| File                                                   | Change                                                                       |
|--------------------------------------------------------|------------------------------------------------------------------------------|
| `src/Incremental.zig`                                  | new `tryIncrementalReparseInPlace`, watermark check, trivia-only front door  |
| `src/CstLower.zig`                                     | no API change (`lowerSubtree` already takes an `arena` param)                 |
| `src/Cst.zig`                                          | add `shiftTokenBytes(tree, edit, delta)` helper for the trivia shortcut      |
| `lsp/Handler.zig`                                      | trivia-only fast path in `updateParseAfterEdit`                              |
| `tests/incremental_mutation_longtail_test.zig`         | M9–M13 test families                                                         |
| `BENCHMARK.md`                                         | arena-growth + watermark-trip numbers                                        |
| `build.zig`                                            | `-Dincremental-stats` option plumbed to `build_options`                      |

## Verification

- `zig build test` — all existing + new tests pass.
- `zig build && zig build wasm && zig build lsp && zig build lsp-wasm` — LSP
  stays a first-class deliverable.
- `cd npm/wgslender && node test.js` — FFI regression check.
- `M8.b` is deleted (superseded by `M9.a`); no other `M*` test changes
  semantics.
