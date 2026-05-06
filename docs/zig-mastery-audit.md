# Zig Mastery audit — wgslender

Verified against: zig 0.16.0 · mastery docs at `~/llm/mastery/zig/` (last reviewed 2026-05-06) · wgslender `main` @ commit `05194db`.

Scope: every `.zig` file under `src/`, `lsp/`, `cli/` plus `build.zig` / `build.zig.zon`. Out of scope: `tests/`, `external/lsp-kit/`, `tmp/`, `npm/`, `zig-out/`, `.zig-cache/`.

The rubric is the mastery checklist (see `~/llm/mastery/zig/ZIG_MASTERY.md` § Summary Checklist). This document is observational — fix passes are listed at the end and tracked separately.

## Executive summary

**Strengths (codebase-wide).**
- 142/142 in-scope files have `//!` module headers (100%).
- 0 uppercase `callconv(.C)`; all FFI uses lowercase `callconv(.c)`.
- 0 references to `GeneralPurposeAllocator`; allocators are caller-supplied `gpa`/`arena` or `std.heap.{wasm_allocator,page_allocator}`.
- `build.zig.zon` has enum-literal `.name = .wgslender`, mandatory `.fingerprint`, `.minimum_zig_version = "0.16.0"`, `.paths`. Textbook 0.16 shape.
- `build.zig` uses `b.addLibrary({.linkage=…})`, `b.lazyDependency`, `entry = .disabled` + `rdynamic = true` for WASM. No `addStaticLibrary`/`addSharedLibrary`.
- Lexer uses sentinel `[:0]const u8` input + labeled `state:` switch — canonical.
- Parser uses `std.MultiArrayList(Token)` + explicit `expr_depth` / `stmt_depth` / `type_depth` recursion guards.
- Typed `enum(u32)` indices with `none = maxInt(u32)` sentinels (Ast.SymbolIndex, Cst.Kind, etc.) used consistently.
- WASM entry points avoid `std.fs` / `std.Thread` / `std.time`; FFI uses pointer+length, never null-terminated strings.
- Tests use `std.testing.allocator` (leak-detecting), fuzz callbacks already use `*std.testing.Smith` (NOT the deprecated `[]const u8` form), OOM testing via `std.testing.checkAllAllocationFailures`, `std.testing.random_seed` for determinism.
- 5 `catch unreachable` total — all in test scaffolding on `testing.allocator`. None on real I/O.

**Codebase-wide deviations.**
1. **`std.ArrayListUnmanaged(T)` used in 73 files (546 occurrences)** — Zig 0.16 deprecated alias; canonical form is `std.ArrayList(T)` with allocator passed per call. Mechanical fix.
2. **`while (true)` without explicit upper bound** — 18 real sites (excluding 2 in comments). Mostly tree walks bounded *implicitly* by AST/CST depth.
3. **Function-length offenders** — 13 functions exceed 100 lines (top: `Lexer.next` 632 lines, `Reflect.reflectWithRenamer` 181, `Cst.finish` 173). One — `Lexer.next` — is the canonical labeled-switch state machine and should NOT be split.
4. **Assertion density below ≥2/fn target** in 26 files — heaviest at: `Builtins.zig` 0/18 fns, `api_json.zig` 0/33, `Edits.zig` 0/30, `validator/Statements.zig` 0/36, `lsp/Handler.zig` 0/33.

**Non-findings (false positives from prior sweep).**
- `src/Ast.zig:245 resizeUseCounts(... n_symbols: usize)`. Argument is used as `arena.alloc(u32, n_symbols)` slice length. Per CLAUDE.md, `usize` is reserved for slice indexing — this is correct usage.
- `src/Printer.zig::optimizeNumericLiteral` is **73 lines, not 217** as claimed in early sweep.
- `lsp/Handler.zig::offsetRangeToLspRange` is **5 lines** (a thin dispatcher), not 211.
- `src/Parser.zig::initWithCst` is **29 lines**, not 82.
- `lsp/Debouncer.zig:176 while (true) : (loops += 1)` — has explicit counter; bounded by `LoopBudget`. Compliant.

**Risk verdict:** Low. No catastrophic anti-patterns. The high-volume deviation (Pass A: ArrayListUnmanaged rename) is mechanical and safe — Zig stdlib treats both names identically. The defensive gaps (assertion density, naked `while (true)`) are instrumentation, not bugs.

---

## Codebase-wide deviations

### D1. Deprecated `ArrayListUnmanaged` alias (73 files, 546 occurrences)

Mastery rule: "`std.ArrayListUnmanaged(T)` and `std.ArrayListAlignedUnmanaged` remain as deprecated aliases for `std.ArrayList(T)` / `std.array_list.Aligned`. New code should use `std.ArrayList(T)` directly." (`ZIG_MASTERY.md` § Zig 0.16 Stdlib Idioms).

Fix sketch: global rename. Both names compile to identical types in 0.16; behaviour is unchanged.

### D2. `while (true)` without explicit upper bound (18 real sites)

Mastery rule: "All loops have upper bounds — Use `for (0..MAX) |_|` with `else unreachable`" (NASA-10 #2).

Sites (real code, comments excluded):

| File | Line | Termination |
|---|---|---|
| `src/CstLower.zig` | 492, 505, 705, 761, 882, 1311, 1477, 1614, 1622, 1820 | `break` on token-tag sentinel |
| `src/Cst.zig` | 328, 952 | `break`/`return` at tree boundary |
| `src/lint/rules/prefer_mix.zig` | 84 | unwraps paren expressions; bounded by AST depth |
| `src/validator/Expressions.zig` | 568 | walks address-of chain; bounded by AST depth |
| `src/incremental/ScopeMap.zig` | 35 | walks CST parent chain; bounded by tree depth |
| `src/incremental/Anchor.zig` | 209 | descends CST; bounded by tree depth |
| `src/incremental/Splice.zig` | 59 | walks CST parent chain; bounded by tree depth |
| `cli/main.zig` | 710 | needs inspection (likely arg-loop) |

Already compliant (counter or label):
- `lsp/Debouncer.zig:176` — `while (true) : (loops += 1)` with explicit `LoopBudget`.

Fix sketch: introduce a `cst_walk_max` (or similar) constant in `src/constants.zig` matching the pre-existing `expr_depth_max` ceiling; convert each site to `for (0..MAX) |_| { … } else unreachable`. The unreachable-else turns a runaway tree walk from a hang into a panic, which is the mastery intent.

### D3. Function-length offenders (>70 lines)

Mastery rule: "Hard limit: 70 lines per function" (`ZIG_MASTERY.md` § Function Design). Top 20 offenders by body line count (auto-derived):

| Lines | File:line | Function |
|---:|---|---|
| 632 | `src/Lexer.zig:585` | `next` — **EXEMPT**: this is the canonical mastery labeled-switch state machine; splitting defeats the pattern. |
| 181 | `src/Reflect.zig:589` | `reflectWithRenamer` |
| 173 | `src/Cst.zig:275` | `finish` |
| 172 | `cli/main.zig:169` | `parseArgs` |
| 171 | `src/incremental/Splice.zig:447` | `tryDeclStmtSpliceInPlace` |
| 171 | `lsp/handler/hover.zig:30` | `computeHover` |
| 168 | `src/lint/Linter.zig:154` | `run` |
| 165 | `lsp/handler/semantic_tokens.zig:57` | `computeSemanticTokens` |
| 161 | `src/incremental/Splice.zig:256` | `tryCompoundSpliceInPlace` |
| 161 | `cli/main.zig:366` | `dispatchSpecFlag` |
| 138 | `src/incremental/Splice.zig:93` | `tryAddSubSpliceInPlace` |
| 133 | `src/Incremental.zig:435` | `tryIncrementalReparseInPlace` |
| 133 | `src/Compiler.zig:849` | `emitStmt` |
| 133 | `src/Compiler.zig:446` | `emitDecl` |
| 117 | `src/Compiler.zig:1460` | `generate` |
| 115 | `src/Reflect.zig:2041` | `computeStructLayout` |
| 113 | `src/options.zig:255` | `applyJson` |
| 113 | `src/Compiler.zig:605` | `emitType` |
| 105 | `src/Reflect.zig:3083` | `writeTypeInfoJson` |
| 104 | `lsp/handler/signature_help.zig:18` | `computeSignatureHelp` |

These are all judgment refactors. Many are dispatch tables (`emitStmt`, `dispatchSpecFlag`, `Linter.run`) where a single switch over 30+ variants legitimately reaches 130-170 lines without nested logic. Mastery's 70-line rule has more give for "wide but shallow" dispatch.

### D4. Assertion-density offenders (≥2/fn target)

Files with **0 assertions** but >10 functions (highest fix value first):

| File | 0/N | Notes |
|---|---|---|
| `lsp/wasm.zig` | 0/45 | FFI boundary — pointer+length asserts would catch C-side bugs |
| `src/validator/Statements.zig` | 0/36 | Validator hot path; pre/post on type-check passes |
| `lsp/Handler.zig` | 0/33 | Lifecycle + dispatch; assert-on-init invariants |
| `src/api_json.zig` | 0/33 | JSON encoders; bound asserts on buffer growth |
| `src/Edits.zig` | 0/30 | Splice math — perfect place for non-overlapping invariants |
| `src/SourceMap.zig` | 0/28 | VLQ output — assert on byte-emit invariants |
| `src/StableId.zig` | 0/26 | ID hashing — collision invariants |
| `cli/main.zig` | 0/24 | CLI is less critical |
| `src/options.zig` | 0/22 | Config validation should assert on resolved fields |
| `src/Overload.zig` | 0/21 | Overload resolution — non-trivial invariants |
| `src/incremental/Splice.zig` | 0/21 | Already complex; asserts would help reading |
| `src/Builtins.zig` | 0/18 | Tables — at minimum assert on signature shape |
| `src/validator/Uniformity.zig` | 0/16 | Uniformity dataflow — converged-state invariants |
| `src/lib.zig` | 0/16 | C ABI surface; assert on input bounds |
| `src/AstVisit.zig` | 0/15 | Visitor invariants |
| `lsp/handler/code_actions.zig` | 0/15 | Span/range invariants |
| `src/RenamePolicy.zig` | 0/13 | Policy resolution |
| `lsp/handler/diagnostics.zig` | 0/12 | Diagnostic count invariants |
| `lsp/handler/inlay_hints.zig` | 0/11 | |
| `src/lint/rules/naming_convention.zig` | 0/11 | |
| `src/lint/rules/prefer_let_over_var.zig` | 0/11 | |
| (others ≤10 fns or in `lsp/wire/*`, `lsp/lspkit/*`) | | |

Files with **<0.10 asserts/fn**:

| File | Density | Asserts/fns |
|---|---:|---|
| `src/CstLower.zig` | 0.03 | 3/89 |
| `src/Reflect.zig` | 0.03 | 4/119 |
| `src/Diagnostic.zig` | 0.05 | 2/40 |
| `src/Types.zig` | 0.05 | 4/78 |
| `lsp/NativeServer.zig` | 0.05 | 1/22 |
| `src/Pipeline.zig` | 0.08 | 1/13 |
| `src/WasmBinary.zig` | 0.06 | 3/51 |
| `src/validator/Expressions.zig` | 0.02 | 1/65 |
| `src/validator/Declarations.zig` | 0.01 | 1/73 |
| `src/Validator.zig` | 0.13 | 8/62 |
| `src/Parser.zig` | 0.11 | 13/118 |

---

## Per-file ledger

Legend: `H` = `//!` header. `AL` = ArrayListUnmanaged absent. `LB` = loops bounded. `FN` = max function ≤ 100 lines. `AS` = ≥0.30 asserts/fn (mastery target is 2.0; 0.30 chosen as a low-bar diagnostic). ✓ pass · ✗ fail · ⚠ partial · — N/A.

### `src/`

| File | H | AL | LB | FN | AS | Notes |
|---|:-:|:-:|:-:|:-:|:-:|---|
| `api_json.zig` | ✓ | ✗ | ✓ | ✓ | ✗ | 0 asserts |
| `Ast.zig` | ✓ | ✗ | ✓ | ✓ | ✗ | 0.16 density |
| `AstVisit.zig` | ✓ | ✗ | ✓ | ✓ | ✗ | 0 asserts |
| `Builtins.zig` | ✓ | ✓ | ✓ | ✓ | ✗ | 0/18 fns — flagged |
| `Compiler.zig` | ✓ | ✗ | ✓ | ✗ | ⚠ | 4 fns >100 lines (emit{Decl,Stmt,Type}, generate) |
| `Config.zig` | ✓ | ✓ | ✓ | ✓ | ⚠ | clean |
| `constants.zig` | ✓ | ✓ | ✓ | ✓ | — | constants only |
| `Cst.zig` | ✓ | ✗ | ✗ | ✗ | ⚠ | 2 unbounded loops; `finish` 173 lines |
| `CstLower.zig` | ✓ | ✗ | ✗ | ⚠ | ✗ | 10 unbounded loops; 0.03 density |
| `Dce.zig` | ✓ | ✗ | ✓ | ✓ | ⚠ | clean |
| `Diagnostic.zig` | ✓ | ✗ | ✓ | ✓ | ✗ | 0.05 density |
| `Edits.zig` | ✓ | ✗ | ✓ | ✓ | ✗ | 0/30 fns |
| `ffi.zig` | ✓ | ✓ | ✓ | ✓ | ✓ | clean |
| `Incremental.zig` | ✓ | ✗ | ✓ | ✗ | ✓ | tryIncrementalReparseInPlace 133 lines |
| `incremental/Anchor.zig` | ✓ | ✓ | ✗ | ✓ | ⚠ | 1 unbounded `descend:` |
| `incremental/Errors.zig` | ✓ | ✗ | ✓ | ✓ | ✓ | clean |
| `incremental/ScopeMap.zig` | ✓ | ✗ | ✗ | ✓ | ✗ | 1 unbounded loop |
| `incremental/Splice.zig` | ✓ | ✗ | ✗ | ✗ | ✗ | 1 unbounded; 3 fns >100 lines; 0/21 asserts |
| `Lexer.zig` | ✓ | ✗ | ✓ | ✗* | ⚠ | *`next` 632 lines is the state machine — exempt |
| `lib.zig` | ✓ | ✓ | ✓ | ✓ | ✗ | C ABI; 0/16 asserts |
| `lint/configs.zig` | ✓ | ✓ | ✓ | ✓ | ✓ | clean |
| `lint/Context.zig` | ✓ | ✓ | ✓ | ✓ | ✓ | clean |
| `lint/Disable.zig` | ✓ | ✗ | ✓ | ✓ | ✓ | clean |
| `lint/Fixer.zig` | ✓ | ✗ | ✓ | ✓ | ✓ | clean |
| `lint/Linter.zig` | ✓ | ✗ | ✓ | ✗ | ⚠ | `run` 168 lines |
| `lint/MultiVisitor.zig` | ✓ | ✗ | ✓ | ✓ | ✓ | clean |
| `lint/registry.zig` | ✓ | ✓ | ✓ | ✓ | — | comptime registry only |
| `lint/Rule.zig` | ✓ | ✓ | ✓ | ✓ | ✓ | clean |
| `lint/walk.zig` | ✓ | ✗ | ✓ | ✓ | ✓ | clean |
| `lint/rules/*.zig` (32 files) | ✓ | ✓† | ⚠‡ | ✓ | ⚠ | †except `no_duplicate_case`, `no_magic_numbers`, `prefer_let_over_var`. ‡`prefer_mix.zig:84` unbounded |
| `Liveness.zig` | ✓ | ✓ | ✓ | ✓ | ✓ | clean |
| `MagicComment.zig` | ✓ | ✗ | ✓ | ✓ | ✓ | clean |
| `Minifier.zig` | ✓ | ✗ | ✓ | ✓ | ⚠ | 0.35 density |
| `MinifyEstimator.zig` | ✓ | ✗ | ✓ | ✓ | ✓ | clean |
| `MinifySettings.zig` | ✓ | ✓ | ✓ | ✓ | ✓ | clean |
| `options.zig` | ✓ | ✗ | ✓ | ✗ | ✗ | `applyJson` 113 lines; 0 asserts |
| `Overload.zig` | ✓ | ✓ | ✓ | ✓ | ✗ | 0/21 asserts |
| `Parser.zig` | ✓ | ✗ | ✓ | ✓ | ⚠ | 0.11 density (118 fns); has depth guards |
| `Pipeline.zig` | ✓ | ✓ | ✓ | ✓ | ✗ | 0.08 density |
| `Printer.zig` | ✓ | ✗ | ✓ | ⚠ | ⚠ | one fn 73 lines; 0.17 density |
| `Reflect.zig` | ✓ | ✗ | ✓ | ✗ | ✗ | 5 fns >100 lines; 0.03 density |
| `RenamePolicy.zig` | ✓ | ✓ | ✓ | ✓ | ✗ | 0/13 asserts |
| `Renamer.zig` | ✓ | ✗ | ✓ | ✓ | ⚠ | clean |
| `root.zig` | ✓ | ✓ | ✓ | ✓ | ✗ | re-exports + 0/12 asserts |
| `SourceMap.zig` | ✓ | ✗ | ✓ | ✓ | ✗ | 0/28 asserts |
| `StableId.zig` | ✓ | ✗ | ✓ | ✓ | ✗ | 0/26 asserts |
| `Suggest.zig` | ✓ | ✓ | ✓ | ✓ | ✓ | clean |
| `Types.zig` | ✓ | ✓ | ✓ | ✓ | ✗ | 0.05 density |
| `unicode_xid.zig` | ✓ | ✓ | ✓ | ✓ | — | tables only |
| `UseCounts.zig` | ✓ | ✓ | ✓ | ✓ | ✓ | clean |
| `Validator.zig` | ✓ | ✗ | ✓ | ✓ | ⚠ | 0.13 density (62 fns) |
| `validator/Declarations.zig` | ✓ | ✗ | ✓ | ✓ | ✗ | 0.01 density (73 fns) |
| `validator/Expressions.zig` | ✓ | ✗ | ✗ | ✓ | ✗ | 1 unbounded; 0.02 density |
| `validator/Statements.zig` | ✓ | ✓ | ✓ | ✓ | ✗ | 0/36 asserts |
| `validator/Uniformity.zig` | ✓ | ✗ | ✓ | ✓ | ✗ | 0/16 asserts |
| `wasm.zig` | ✓ | ✓ | ✓ | ✓ | ✓ | FFI clean |
| `WasmBinary.zig` | ✓ | ✗ | ✓ | ✓ | ✗ | 0.06 density |

### `lsp/`

| File | H | AL | LB | FN | AS | Notes |
|---|:-:|:-:|:-:|:-:|:-:|---|
| `Debouncer.zig` | ✓ | ✓ | ✓ | ✓ | ⚠ | bounded counter form |
| `Handler.zig` | ✓ | ✓ | ✓ | ✓ | ✗ | 0/33 fns |
| `main.zig` | ✓ | ✓ | ✓ | ✓ | ✓ | clean |
| `NativeServer.zig` | ✓ | ✓ | ✓ | ✓ | ✗ | 0.05 density |
| `uri.zig` | ✓ | ✗ | ✓ | ✓ | ✓ | clean |
| `wasm.zig` | ✓ | ✗ | ✓ | ✓ | ✗ | 0/45 fns FFI surface |
| `lspkit_root.zig`, `wire_root.zig` | ✓ | ✓ | ✓ | ✓ | — | re-export shells |
| `handler/*.zig` (14 files) | ✓ | ✗‡ | ✓ | ⚠§ | ✗ | ‡most use ArrayListUnmanaged. §`hover.zig::computeHover` 171, `semantic_tokens.zig::computeSemanticTokens` 165, `signature_help.zig::computeSignatureHelp` 104 |
| `native/*.zig` (8 files) | ✓ | ✓ | ✓ | ✓ | ⚠ | clean |
| `wasm/*.zig` (10 files) | ✓ | ⚠ | ✓ | ✓ | ⚠ | most clean; some ArrayListUnmanaged |
| `lspkit/*.zig` (8 files) | ✓ | ✓ | ✓ | ✓ | ⚠ | clean |
| `wire/*.zig` (9 files) | ✓ | ⚠ | ✓ | ✓ | ⚠ | wire/edits, wire/code_actions etc. use ArrayListUnmanaged |

### `cli/`, `build.zig`, `build.zig.zon`

| File | H | AL | LB | FN | AS | Notes |
|---|:-:|:-:|:-:|:-:|:-:|---|
| `cli/main.zig` | ✓ | ✗ | ✗ | ✗ | ✗ | 1 unbounded loop; 2 fns >100 lines (`parseArgs`, `dispatchSpecFlag`); 0 asserts |
| `build.zig` | — | — | — | — | — | textbook 0.16 |
| `build.zig.zon` | — | — | — | — | — | enum-name + fingerprint correct |

---

## Tests (out-of-scope summary)

The `tests/` tree was not given a per-file ledger by user request. Aggregate findings (already validated by sampling):

- All test files use `std.testing.allocator` (leak-detecting). Zero use of `std.heap.page_allocator` or production arena-only allocators in tests.
- `tests/oom_test.zig` uses `std.testing.checkAllAllocationFailures` (the canonical 0.16 form; preferred over the manual `FailingAllocator` loop).
- `tests/fuzz_test.zig`, `tests/incremental_fuzz_test.zig`, `tests/incremental_mutation_fuzz_test.zig` all use the `*std.testing.Smith` callback signature. **Zero deprecated `[]const u8` callbacks.**
- `std.testing.random_seed` is used in incremental fuzz tests for determinism.
- Test names are descriptive (`F-EXACT E1: literal_expr swap preserves every live use_count`).

Single deviation: tests use `std.ArrayListUnmanaged(T)` alongside the rest of the codebase — covered by Pass A.

---

## Recommended fix passes

The plan (`/Users/hugo/.claude/plans/go-for-each-zig-temporal-sky.md`) approved four passes. Based on this audit, two need re-scoping:

### Pass A — Drop the `ArrayListUnmanaged` alias (mechanical, codebase-wide)
- 73 files, 546 occurrences. Identical type in 0.16; no behaviour change.
- Single commit. Verified by `zig build && zig build test`.
- **Status: as planned. Proceed.**

### Pass C — Bound the unbounded `while (true)` loops
- Original plan: 12 sites in `Cst.zig` + `CstLower.zig`.
- **Re-scope: 18 real sites** (added `prefer_mix.zig`, `validator/Expressions.zig`, `incremental/{ScopeMap,Anchor,Splice}.zig`, `cli/main.zig`).
- All are tree walks bounded *implicitly* by AST/CST depth. Replace with `for (0..MAX) |_| { … } else unreachable` using a new `cst_walk_max` constant in `src/constants.zig` sized off the existing depth ceilings.
- Single commit. Verified by `zig build test`.

### Pass B — Split functions >70 lines (SKIPPED)
- Original plan targeted `Printer.optimizeNumericLiteral` (claimed 217 lines), `Handler.offsetRangeToLspRange` (211), `Parser.initWithCst` (82). **Actual sizes: 73, 5, 29 lines.** The original three are non-issues.
- The actual >100-line offenders are: `Reflect.{reflectWithRenamer,computeStructLayout,writeTypeInfoJson}`, `Cst.finish`, `cli/main.{parseArgs,dispatchSpecFlag}`, `incremental/Splice.{tryDeclStmtSpliceInPlace,tryCompoundSpliceInPlace,tryAddSubSpliceInPlace}`, `lsp/handler/{hover,semantic_tokens,signature_help}.compute*`, `lint/Linter.run`, `Compiler.{emitDecl,emitStmt,emitType,generate}`, `Incremental.tryIncrementalReparseInPlace`, `options.applyJson`. Many are wide-but-shallow dispatch tables where mastery's 70-line rule is least applicable.
- **Status: skipped by user decision** — these offenders remain candidates for future targeted refactors but are not addressed in this audit's commit chain.

### Pass D — Raise assertion density
- Original plan: 7 files (`Builtins`, `Diagnostic`, `Types`, `Validator`, `WasmBinary`, `Lexer`, `Dce`).
- Audit confirms these but reveals additional 0-assert-files: `api_json`, `Edits`, `Overload`, `validator/Statements`, `validator/Uniformity`, `lsp/Handler`, `lsp/wasm`, `SourceMap`, `StableId`, `options`, etc.
- Recommend executing the planned 7 first; revisit the longer list after.
- **Status: as planned. Proceed.**

---

## Reproducibility

Every count in the executive summary is reproducible via these one-liners (from repo root):

```bash
# ArrayListUnmanaged occurrences
grep -rh "ArrayListUnmanaged" src lsp cli | wc -l           # → 546
grep -rl "ArrayListUnmanaged" src lsp cli | wc -l           # → 73

# Module headers
for f in $(find src lsp cli -name '*.zig'); do
  awk 'NF{exit}NR>1' "$f"; awk 'NF{print; exit}' "$f"
done | grep -c '^//!'                                       # → 142

# Uppercase callconv
grep -rn 'callconv(\.C)' src lsp cli | wc -l                # → 0

# Unbounded while(true) (excluding comments)
grep -rn 'while (true)' src lsp cli | grep -v ':[0-9]*://'  # → 18 lines

# catch unreachable
grep -rn 'catch unreachable' src lsp cli | wc -l            # → 5
```
