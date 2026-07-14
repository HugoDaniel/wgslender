# ConstEval extraction — implementation plan

**Status:** deferred work, not started. Planned 2026-07-14, verified against `main` @ `87b967c`.
**Origin:** the master-craft program's "Deferred" register: *"ConstEval extraction (shared module
for Reflect.LayoutComputer + Validator.tryExtractIntValue): different value domains (f64 vs i64),
different resolution contexts, neither wrong today; earns its keep only when a third consumer
arrives (real §11 const-eval). Action now: cross-referencing doc comments naming the future
`src/ConstEval.zig`."* — **Note: that "action now" was never executed.** `grep -rn ConstEval src/`
finds only the unrelated `Builtin.isConstEval` (`src/Builtins.zig:101`). Block C0 delivers it.
**Ordering:** run this plan **before** `reflect-split.md` (its Block R2 is this plan's C1) and
ideally before `validator-decomposition.md` (C2 removes ~220 lines of const-eval helpers from
Validator.zig that the decomposition would otherwise have to move twice). Independent of
`uniformity-dataflow-upgrade.md`. See `docs/deferred/README.md` for shared house rules.

---

## 0. House rules for whoever implements this

- One block per commit (or a few small commits per block); conventional-commit style; any behavior
  change flagged `⚠ BEHAVIOR` in the commit body.
- TDD reds-first — for a behavior-preserving extraction that means **characterization pins**:
  exact-value tests that are green before the move and must stay green after.
- Full gate per block: `zig build && zig build wasm && zig build lsp && zig build lsp-wasm &&
  zig build test` with the test step **`-j1`** (corpus suites flake under concurrency). Fast loop:
  `zig test --dep wgslender -Mroot=tests/<file>.zig -Mwgslender=src/root.zig`; for src-internal
  pins `zig test src/<File>.zig` runs the whole src graph.
- Corpus goldens (`tests/inference/*.txt`): this plan targets **zero drift** until Block C3;
  any drift before C3 is a bug. C3 drift is regenerated in-commit with a ⚠ note.
- No CI. All gates are local.

## 1. Current state — three evaluators, two value domains, two overflow semantics

All claims verified at `87b967c`.

### 1a. Validator-side: `tryExtractIntValue` family (`src/Validator.zig:1303-1521`)

- `tryExtractIntValue(v, expr) ?i64` (`:1338`) → `tryExtractIntValueDepth` (`:1342`), depth cap 32.
  Handles literal / ident / unary `neg`+`bit_not` / paren / binary. **Saturating arithmetic**
  (`+|`, `-|`, `*|`, `:1365-1367`); div/mod zero-guarded; shifts clamped to `0..64`; comparisons
  and logical ops → null.
- Ident resolution: **precomputed map** `v.const_values: AutoHashMapUnmanaged(u32, i64)`
  (`src/Validator.zig:368`), populated at exactly one site — `validateConstDecl`
  (`src/validator/Declarations.zig:641-646`): only `const` decls whose initializer already
  int-reduces get an entry. Consequence: `const N = u32(sin(radians(90)) + 3);` is invisible to
  the Validator (float chain) but fully evaluated by Reflect — a real, documented capability gap.
- `tryEvalConstBool(v, expr) ?bool` (`:1303`) — bool domain: `true`/`false`, `.not`, paren, and
  int comparisons via two `tryExtractIntValue` calls (`:1319-1320`). Sole caller: `const_assert`
  (`Declarations.zig:1085`, E0807).
- `extractLiteralIntValue` (`:1393`) + `extractLiteralIntValueDepth` (`:1397`) — a **third,
  freestanding** integer evaluator (no const lookup; literal/unary/paren/binary, saturating), for
  helpers without a `*Validator` (`getLocationInfo`/`getBlendSrcInfo`,
  `Declarations.zig:1842/1856`; aliased at `Declarations.zig:21`).
- Shared literal parser `extractLiteralInt` (`:1382`): strips `i`/`u` suffix,
  `parseInt(i64, …, 0)`.
- Adjacent but distinct: `classifyExprStage` (`:1433-1496`) is the const/override/runtime *stage*
  classifier (gates, doesn't evaluate) and stays where the decomposition plan puts it — not part
  of this extraction.

**All 16 `tryExtractIntValue` call sites** (the behavior surface to preserve): array element count
(`Validator.zig:694`, E0313); comparison operands in `tryEvalConstBool` (`:1319-1320`); struct
member `@align`/`@size` capture + checks (`Declarations.zig:321,365,374`); `const_values`
population (`:643`); `@id` range/dup (`:750`); `@group`/`@binding` pair dedup (`:851,855`);
`@location` non-negative (`:1314`); `@workgroup_size` dims + product overflow (`:1350`); switch
case-selector dedup (`Statements.zig:330`); const div-by-zero (`Expressions.zig:533`), mod-by-zero
(`:564`), shift bit-width (`:608`); literal index bounds (`:1929`, E0211).

### 1b. Reflect-side: the `LayoutComputer` interpreter (`src/Reflect.zig`)

- Value domain `ConstValue = union(enum) { int: i64, float: f64, bool }` (`Reflect.zig:1170-1190`)
  with `toI64` (truncates finite floats) / `toF64`.
- Entry: `evaluateConstExpr(expr) i32` (`:1723`) — **the single seam**: every one of the 9
  layout/extraction call sites (`:665, 985, 1049, 1356, 1585, 1639, 2087, 2167, 2264`) goes
  through this i32 wrapper (`-1` = unknown); nothing else touches `evalConst`/`ConstValue`.
- Core: `evalConst(expr, depth)` (`:1734`, depth cap 64), `evalBinary` (`:1766`) — **wrapping**
  arithmetic (`+%`, `-%`, `*%`), int comparisons → bool, float promotion path; `evalIdent`
  (`:1816`) → `evalConstSymbol` (`:1829`) — **lazy recursive walk over module decls, memoized in
  `const_cache: AutoHashMapUnmanaged(u32, ?ConstValue)`** (`:1201`) with a null placeholder for
  cycle breaking (`:1832`); `evalCall` (`:1850`) — scalar ctor casts `u32/i32/f32/f16/bool`,
  `radians/degrees/abs`, 13 one-arg float builtins, `min/max/pow`, `clamp`; `evalMember`
  (`:1950`) — `const a = Foo(2, 10.5); a.x`; literal/builtin support at `:2538-2608`.
  Total ≈ 380 LOC.
- The float machinery exists to serve one real pattern (wgsl_reflect parity `const2`:
  `array<vec4f, u32(sin(radians(90)) + 3)>`, pinned at `tests/reflect_wgslreflect_test.zig:599`).

### 1c. The divergences a shared module must reconcile

| Aspect | Validator | Reflect |
|---|---|---|
| Value domain | bare `i64` (+ separate `?bool` path) | `{int: i64, float: f64, bool}` |
| Overflow | **saturating** (`+\|`) | **wrapping** (`+%`) |
| Ident resolution | eager precomputed `const_values` (int-only) | lazy memoized AST walk (full domain) |
| Calls/members | not handled (→ null) | casts, float builtins, struct-ctor member |
| Depth cap | 32 | 64 |
| Failure encoding | `?i64` | `?ConstValue`, then `-1` via i32 wrapper |

Neither overflow semantic matches WGSL §11, which requires a **diagnostic** when a const-expression
overflows. Today's `integer_overflow` (E0317, `src/Diagnostic.zig:836`) is wired only to
*individual literal* range checks (`checkIntLiteralRange`, `src/validator/Expressions.zig:159-207`)
— `const x: u32 = 5_000_000_000 / 2;`-style folded overflow is never diagnosed. That gap is the
"third consumer" that justifies this module (Block C3).

No other value-folding exists anywhere: Printer/Minifier/MinifyEstimator/Compiler do no constant
folding, and `src/Overload.zig`'s "folds" are type-list reductions, never concrete values.

## 2. Design

### 2.1 Shape of `src/ConstEval.zig`

One canonical value type and one recursive evaluator, parameterized by (a) an identifier resolver
and (b) an overflow mode. The module imports only `std`, `Ast` — **never Validator or Reflect**
(they import it). Precedent for breaking potential import cycles with `anytype`: `src/options.zig`
cannot import Minifier and targets `anytype` instead — same trick here for the resolver.

```zig
pub const Value = union(enum) {
    int: i64,
    float: f64,
    bool: bool,
    pub fn toI64(self: Value) ?i64 { ... }   // lift from Reflect.ConstValue verbatim
    pub fn toF64(self: Value) f64 { ... }
};

pub const OverflowMode = enum { saturate, wrap, checked };
// saturate  → today's Validator semantics (+|)
// wrap      → today's Reflect semantics (+%)
// checked   → §11 semantics: overflow returns null AND reports via the resolver hook (C3)

/// resolver: anytype exposing
///   fn resolveIdent(self, ref: Ast.SymbolIndex) ?Value
/// plus (C3 only) an optional `fn onOverflow(self, loc: u32) void` hook.
pub fn eval(resolver: anytype, comptime mode: OverflowMode, expr: Ast.Expr, depth: u32) ?Value
```

- The **core** (literal, paren, unary, binary, casts, float builtins, member — i.e. today's
  Reflect `evalConst` body) is written once; `mode` selects the arithmetic ops at comptime, so
  there is zero runtime dispatch and the migrated code paths stay branch-identical.
- **Resolvers stay with their owners.** The Validator's resolver is a 5-line struct wrapping
  `const_values` (int domain, eager). Reflect's resolver keeps `evalConstSymbol`'s lazy
  memoized walk + `const_cache` + cycle placeholder — it lives in Reflect (it needs
  `module.declarations` and the cache), and calls back into `ConstEval.eval` for initializers.
  This preserves the two "different resolution contexts" the deferred note identified instead of
  pretending they were accidental.
- **Literal parsing** (`parseIntLiteral`/`parseFloatLiteral`, suffix stripping) moves into
  ConstEval — it is currently duplicated (`Validator.zig:1382` vs `Reflect.zig:2551-2566`).
- Depth cap: one constant in `src/constants.zig` (house pattern for tunable limits). Unify on 64;
  the Validator's 32 → 64 widening is behavior-visible only for expressions nested 33-64 deep,
  which today return null (un-evaluable) — strictly more evaluation, and depth-33 const
  expressions do not exist in any test or the corpus. Call it out in the commit anyway
  (⚠ BEHAVIOR, theoretical).

### 2.2 What deliberately does NOT move

- `classifyExprStage` / `classifyIdentByName` (`Validator.zig:1433-1521`) — stage classification,
  not evaluation. The Validator decomposition plan owns their placement.
- `checkIntLiteralRange` (`Expressions.zig:159-207`) — literal *range* checking against target
  types; a neighbor, not a value evaluator. C3 may call ConstEval but the function stays.
- Reflect's `renderExprText` (`Reflect.zig:2370-2433`) — source-text rendering for override
  defaults; unrelated to evaluation.
- `OverrideInfo.default` stays raw source text (`Reflect.zig:563-565`) — overrides are
  pipeline-creation values; evaluating them would be wrong.

### 2.3 Rejected alternatives

- **One shared resolution context** (make the Validator adopt Reflect's lazy walk, or Reflect
  adopt `const_values`): changes *which* expressions evaluate on both sides (the
  `u32(sin(...))` gap would silently start affecting validation) — that's C3's job to do
  deliberately, with golden regen, not a side effect of an extraction.
- **Vtable/interface instead of `anytype`**: two call sites, both known at comptime; a vtable adds
  indirection for nothing.
- **Waiting for the third consumer** (status quo): both other deferred plans (Reflect split,
  Validator decomposition) want this code moved anyway; extraction now is two-birds.

## 3. Blocks

### Block C0 — cross-referencing docs + characterization pins
**Steps:**
1. The doc comments the original deferred note asked for: on `tryExtractIntValue`
   (`Validator.zig:1335-1338`), on `ConstValue` (`Reflect.zig:1164-1170`), and on `evalConst`
   (`Reflect.zig:1730-1734`) — each naming `src/ConstEval.zig` and the other site. (If C1 lands
   in the same sitting this is folded into C1; commit C0 separately if the extraction might stall.)
2. **Characterization pins (all green before any move):** new `tests/const_eval_test.zig`
   pinning today's exact divergent semantics through the *public* surfaces:
   - Validator side (via `wgslender.analyze` → `const_values`, or an array-count fixture):
     saturation — `const N = 9223372036854775807 + 1;` + `array<f32, N>` behavior; depth-32 cap;
     comparison-based `const_assert`; the float-chain *invisibility*
     (`const N = u32(sin(radians(90)) + 3); array<f32, N>` — pin that validation today leaves
     count unknown and emits whatever it emits).
   - Reflect side (via `wgslender.reflect`): wrapping (`0 -% x` on `-(-9223372036854775807-1)`
     class cases is already implicit — pin a simple wrap case), the `const2` float chain
     (already pinned at `reflect_wgslreflect_test.zig:599` — reference, don't duplicate),
     member-access eval, memoized const chains.
3. Register the test file in `build.zig` next to its peers.
**Gates:** new pins green; full `-j1` suite; zero golden drift.
**LOC:** ≈ +120. **Risk:** none.

### Block C1 — create `src/ConstEval.zig`; migrate Reflect
**Red:** none beyond C0's pins (behavior-preserving move; the 135 reflect tests + oom/fuzz/
determinism suites are the gate).
**Steps:**
1. Create `src/ConstEval.zig`: `Value` (lift `ConstValue` verbatim), `OverflowMode`, literal
   parsers, and `eval` — body lifted from `evalConst`/`evalBinary`/`evalCall`/`evalMember`/
   `evalLiteral` + the 13 builtin f64 wrappers (`Reflect.zig:1734-1990, 2538-2608`), with the
   arithmetic ops routed through comptime `mode` (Reflect passes `.wrap`).
2. In Reflect: keep `evaluateConstExpr(expr) i32` as the façade (unchanged signature, still the
   only thing layout code calls); its body becomes resolver construction + `ConstEval.eval(...)`
   + the existing `toI64`/range/`-1` policy. `evalConstSymbol` + `const_cache` stay in Reflect as
   the resolver; `findStructDeclByName` stays (member resolution helper).
3. Export `pub const ConstEval = @import("ConstEval.zig");` from `src/root.zig` (tier:
   experimental).
4. Move the in-ConstEval-scope unit tests; add direct unit tests for `eval` with a stub resolver
   (each op, each mode, div/mod-by-zero, shift guards, depth cap, cycle via resolver returning
   null).
**Gates:** `tests/reflect_test.zig` (110 tests — incl. the interpreter-integration pins at
:1494-1614), `tests/reflect_wgslreflect_test.zig` (25), `tests/determinism_test.zig:164`,
`tests/oom_test.zig` (checkAllAllocationFailures — error-return paths must survive the move
exactly), `tests/fuzz_test.zig:170`, `cd npm/wgslender && npm test` (wire JSON byte-pinned by
`test/_suite.cjs:184-274`), full `-j1` suite. Zero golden drift.
**LOC:** ≈ +420 new module / −380 in Reflect. **Risk:** low-medium (pure move with a comptime
seam; OOM suite is the trap — keep allocation points identical).

### Block C2 — migrate the Validator family
**Red:** C0's Validator-side pins (must stay green — especially saturation).
**Steps:**
1. `tryExtractIntValueDepth` body → `ConstEval.eval(ValidatorResolver{v}, .saturate, expr, d)`
   with `.toI64()`-style narrowing preserving today's null-on-non-int results. **Note:** the
   shared core evaluates strictly more forms (casts, float builtins, members) than today's
   Validator extractor; with mode `.saturate` and the `const_values`-backed resolver those extra
   forms now *can* produce values (e.g. `u32(3.0)` as an `@align` arg). That is behavior drift.
   **Decision: suppress it in C2** — pass a comptime feature-set flag (or a second `eval`
   entry, `evalIntOnly`) so C2 is byte-neutral; widening what the Validator evaluates is C3's
   explicit, golden-regenerating decision. Do not let it happen by accident here.
2. `tryEvalConstBool` → thin wrapper over the same eval (comparisons return `Value.bool` in the
   core already); pin E0807 fixtures unchanged.
3. `extractLiteralIntValue` → `ConstEval.eval(NullResolver{}, .saturate, ...)`; keep the
   `Declarations.zig:21` alias working (it's referenced by name).
4. Keep all three public names on Validator as one-line shims (the decomposition plan may later
   re-home them; LSP/lint/tests reference nothing below them).
**Gates:** `tests/validation_test.zig` (the 76 const-context cases), `validation_location_test` +
`validation_range_test` (positions of E0211/E0313/E0316/E0317 etc. must not move),
`validation_dedup_test`, `tests/inference/` **zero golden drift** (the whole point of the
feature-suppression flag), full `-j1`.
**LOC:** ≈ −130 in Validator.zig (`:1303-1431` moves; `classifyExprStage` at `:1433-1521` stays —
see §2.2). **Risk:** medium — the "accidentally more capable" trap above
is the one real hazard; the goldens catch it.

### Block C3 — the third consumer: real §11 const-eval in the Validator (optional, separate decision)
This is a scoped-down first bite of §11, not full const-eval. Propose to Hugo before starting;
it is **behavior-expanding** by design.
**Red first:** fixtures — `const x: u32 = 4294967295 + 1;` → expect E0317 at the initializer;
`array<f32, N>` where `N = u32(sin(radians(90)) + 3)` → expect count 4 accepted (capability gap
closes); overflow inside `@workgroup_size` args.
**Steps:**
1. Switch `validateConstDecl`'s evaluation to mode `.checked` with the full feature set; widen
   `const_values` from `i64` to `ConstEval.Value` (touches its 5 LSP consumer sites —
   `hover.zig:65/96/172`, `inlay_hints.zig:201-215`, `code_lens.zig:96` — and the
   `AnalysisResult` field; mechanical but cross-cutting).
2. Emit E0317 via the resolver's `onOverflow` hook at const-decl initializers and const-context
   attribute args; reuse E0316 (division_by_zero) where the core detects it (already
   diagnosed today at `Expressions.zig:533/564` — don't double-report: the post-checks become
   consumers of the eval result rather than independent extractions).
3. Regenerate corpus goldens in-commit; run `zig build tint-triage -- --code E0317 --bucket fp`
   and drive fp to zero (Tint is the oracle for §11 semantics).
**Gates:** everything in C2 plus regenerated goldens + triage fp=0. ⚠ BEHAVIOR (feature-class):
new diagnostics on previously-accepted shaders; float-chain consts become visible to validation.
**LOC:** ≈ +200. **Risk:** medium-high; do not start without an explicit go-ahead.

## 4. Behavior-change register

| Block | Change | Class |
|---|---|---|
| C1 | none (byte-identical reflect output; OOM paths preserved) | — |
| C2 | Validator depth cap 32→64 (theoretical); otherwise none by construction | guarded |
| C3 | E0317 on folded const overflow; float-chain consts visible to array counts/attrs; `const_values` value domain widens | feature (opt-in block) |

## 5. Success criteria

1. `src/ConstEval.zig` exists; Reflect and Validator both consume it; `grep -c "ConstEval" src/`
   shows the cross-references the deferred note asked for.
2. Through C2: zero corpus-golden drift, zero reflect-JSON drift (npm suite), all
   characterization pins green untouched.
3. Exactly one literal parser, one arithmetic core, one `Value` type in the repo
   (`grep -rn "parseIntLiteral\|ConstValue" src/` finds only ConstEval + shims).
4. CLAUDE.md module map gains a `src/ConstEval.zig` row; `Reflect.zig` and `Validator.zig` row
   descriptions updated.
