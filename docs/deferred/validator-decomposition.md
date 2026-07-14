# Validator god-struct decomposition — implementation plan

**Status:** deferred work, not started. Planned 2026-07-14, verified against `main` @ `87b967c`.
**Origin:** the master-craft program's Block 0.3 deliberately deferred *"god-struct field grouping
and narrowing the ~70 re-export aliases"* (then Validator.zig:476-568; the file has since grown —
the alias block is now **:514-610** and the file is 1,572 lines), and the program's "Deferred"
register carried *"Validator god-struct decomposition / submodule contracts: revisit after
Tiers 1-2 settle the churn."* Tiers 1-2 are long settled.
**Ordering:** run `consteval-extraction.md` Blocks C0-C2 **first** — it removes the ~130-line
const-eval helper block (`Validator.zig:1303-1431`; `classifyExprStage` stays) that this plan
would otherwise have to move twice. Not a hard prerequisite (line numbers below shift if you skip it; re-grep). Independent of
the uniformity and reflect tracks. See `docs/deferred/README.md` for shared house rules.

---

## 0. House rules for whoever implements this

- One block per commit; conventional commits. **This is a behavior-preserving plan end to end** —
  there is no `⚠ BEHAVIOR` entry; if a gate forces one, stop and reconsider.
- The reds are the existing suites (the validator has the densest fixture set in the repo);
  the definition of done for every block is *zero diagnostic drift*: same codes, same positions,
  same ranges, same dedup survivors, same corpus histograms.
- Full gate per block: `zig build && zig build wasm && zig build lsp && zig build lsp-wasm &&
  zig build test` with the test step `-j1`. Zero corpus-golden drift
  (`tests/inference/corpus_golden.txt` + `triage_golden.txt` untouched — a crashed corpus run
  writes nothing and shows no diff; only an exit-0 run proves no drift).
- Key sensitive gates: `tests/validation_location_test.zig` (pins line/col per error category),
  `tests/validation_range_test.zig` (pins start+end), `tests/validation_dedup_test.zig` (pins
  which duplicate survives `diags.deduplicate()` — sensitive to emission order),
  `tests/depth_limits_test.zig` (exercises the `expr_depth`/`stmt_depth` invariants asserted at
  runPhases exit), `tests/oom_test.zig` (validate under injected OOM),
  `tests/inference/expr_types_coverage_test.zig` (pins the `expr_types` cache recording), and the
  LSP parity suites (consume `analyze`/`AnalysisResult`).
- No CI. All gates local.

## 1. Current state (verified at `87b967c`)

### 1a. The struct: 24 flat fields (`src/Validator.zig:321-375`)

Already grouped *by comment*, not by type:

| Group (existing comment) | Fields | Locality (grep-verified) |
|---|---|---|
| refs/alloc/sink/options | `arena` :321, `module` :322, `diags` :323, `options` :324 | everyone |
| **current-function cursor** :326-342 | `current_func`, `current_stage`, `in_loop`, `in_switch`, `in_continuing`, `break_exits_continuing`, `return_type`, `has_return`, `expr_depth`, `stmt_depth` | **Statements-private** except: `current_stage` read 14× by Declarations, `current_func` read 2× (Declarations:1096-1098), `expr_depth` Expressions-private |
| type caches :345-354 | `symbol_types`, `struct_types`, `alias_types`, `expr_types` | shared: Declarations writes, Expressions reads structs/symbols + writes `expr_types` (single site, Expressions.zig:104) |
| per-phase scratch :357-375 | `override_ids`, `binding_pairs`, `binding_infos`, `multi_entry_point`, `const_values`, `enabled_features`, `var_info` | **Declarations-private** except `const_values`/`var_info`/`enabled_features` (1-2 reads from Expressions), `multi_entry_point` written by runPhases:415 |

### 1b. The alias layer (`Validator.zig:514-610`, 68 aliases + 1 import)

`pub const foo = _Submodule.foo;` re-exports make submodule functions callable as `v.foo(...)`
(Zig method sugar: first param `*Validator`). This is the plumbing that lets the four submodules
call each other **without importing each other** — the import graph is a star:

- Declarations block :519-548 — 12 *phase entry points* (called only by `runPhases`) + 16
  *cross-phase helpers* (called by Statements/Expressions via `v.`).
- Statements block :555-579 — 25 aliases (`validateFunctions`, per-statement validators,
  `detectShadowing`, `checkOperatorPrecedence`, …).
- Expressions block :588-602 — 15 aliases (`checkExpr` family).
- Uniformity :610 — `analyzeUniformity`.

Exactly **one** sideways import exists: `Statements.zig:17` imports Expressions for a single call
(`Expressions.binaryResultType`, Statements.zig:554). Everything else routes through `v.`.

### 1c. Phases (`runPhases`, Validator.zig:413-468)

Sixteen ordered steps, phase 0 → 7, then `diags.deduplicate()` (:461) and the depth-invariant
asserts (:466-467). The header comment (:409-412) already **rejects a data-driven pass table**
(phases are fixed, later phases read earlier phases' state) — this plan honors that; nothing here
re-architects the phase driver.

### 1d. The two contracts that are implicit today

- **Output contract:** `analyze` (:477-512) hand-copies five caches into `AnalysisResult`
  (:501-511): `symbol_types`, `struct_types`, `alias_types`, `const_values`, `expr_types`.
  Nothing marks those fields as "outputs" at their declaration.
- **Doc-only contracts that are wrong:** `Expressions.zig:407` names `Statements.checkCompoundAssign`
  — **that function does not exist anywhere** (grep-verified phantom); the Expressions header
  (:4-5) names Statements/Declarations as callers though Expressions imports neither.

### 1e. What else lives in the god file

Beyond struct + phases + aliases: type resolution (`resolveType` + 8 resolvers + `lookupType` +
shorthand parsers, :616-1065, ≈400 LOC, shared by Declarations & Expressions), loc/range helpers
(:1075-1299), diagnostic emitters (:1173-1271), const-eval helpers (:1303-1521 — leaves via
ConstEval C2), suggestion helpers (:890-999). Notable safety property: composite `Types.Type`
values are **not interned** (fresh `create` per resolution; only scalar singletons are shared,
Types.zig:739-745) — so moving resolution code cannot break type identity.

**The reference model already in-tree:** `Uniformity.zig` takes `*Validator`, copies out the four
things it needs (module/diags/arena/filters), and keeps all walker state in its own struct
(Uniformity.zig:16-54). That is what "decomposed with a contract" looks like here.

## 2. Design

Three moves, in decreasing value-per-churn:

1. **Materialize the field groups as nested structs** — the comments become types. Grouping is by
   *destiny*, not just by topic:
   - `fn_ctx: FnContext` — the 10-field mutable cursor (:326-342). Statements resets it per
     function; the depth counters keep their defer-balanced discipline.
   - `out: Outputs` — the five AnalysisResult-bound caches. `analyze`'s copy-out becomes a single
     named handoff; the output contract becomes a type.
   - `scratch: Scratch` — the six validation-internal maps/lists + `multi_entry_point`.
   - `arena`/`module`/`diags`/`options` stay flat (they are the universal context, not a group).
2. **Extract type resolution** into `src/validator/TypeResolve.zig` using the exact sibling
   pattern (functions take `v: *Validator`; Validator re-exports them as aliases). No new
   contract style — consistency beats novelty, and the alias mechanism is load-bearing plumbing,
   not vestige.
3. **Narrow and document the alias layer**: phase entries stop being aliases (runPhases calls
   `_Declarations.processDirectives(v)` directly — those 12 names have no other callers);
   surviving aliases get sectioned by audience ("cross-submodule contract" vs "public API used by
   tests/LSP"); zero-caller aliases die (grep each).

### Traps (read before coding)

- **Do not replace per-field save/restore with whole-struct copies of `FnContext`.** The
  loop/switch validators save and restore *specific* fields (e.g. `validateLoopStmt` saves
  `in_loop` + `break_exits_continuing`, Statements.zig:350-386) while `has_return` must
  **persist** across nested blocks (set at Statements.zig:230/462, read at function end). A
  whole-struct snapshot would silently revert `has_return` and break missing-return
  diagnostics. The grouping is namespacing only.
- **`validateFunction`'s entry reset (Statements.zig:47-53) is a flat reset, not a save/restore**
  (WGSL functions don't nest). Resetting via `v.fn_ctx = .{ ... }` at function entry IS safe and
  is the one place a struct-literal reset improves the code — but keep `expr_depth`/`stmt_depth`
  out of any reset (they are balanced by `defer`, asserted 0 at runPhases:466-467, and are *not*
  per-function state; zeroing them mid-walk would mask an imbalance the asserts exist to catch).
- **Dedup order-sensitivity:** `validation_dedup_test` pins which duplicate survives; don't
  reorder any emission while shuffling code.
- **`Expectation`/abstract-type materialization** (Validator.zig:159-185) is intertwined with the
  `expr_types` single write site (Expressions.zig:104) — `expr_types_coverage_test` pins exactly
  what gets recorded; treat that path as untouchable during moves.

### Rejected alternatives

- **Narrow context structs per submodule** (Statements receives only `&fn_ctx + &diags + ...`):
  the usage matrix says Statements also needs resolveType, checkExpr, validate*Decl — i.e. most
  of the star. Threading six context params through 25 functions trades one god struct for
  parameter-list sprawl. The nested groups give the same readability ("who may touch what" is
  visible at the field access: `v.scratch.` in Expressions is a review flag) without the churn.
- **Data-driven phase table**: already rejected in-repo (Validator.zig:409-412); phases are fixed
  and order-dependent.
- **Splitting Declarations.zig (2,131 LOC)**: it is large but single-purpose per phase; splitting
  by phase would add files without adding boundaries. Not planned.

## 3. Blocks

### Block V0 — contract-comment hygiene (one small commit)
1. Fix the phantom: `Expressions.zig:407` — name the real owner of compound-assign wording
   (grep `binaryResultType` / the assign validator in Statements.zig; state the actual fn).
2. Fix the Expressions header (:4-5) to describe the alias-layer call relationship truthfully
   ("callers reach these via `Validator`'s re-exports").
3. While in there: sanity-grep for other phantom fn names in validator/* doc comments
   (`grep -oE '`[A-Za-z]+\.[a-zA-Z]+`' src/validator/*.zig` and spot-check).
**Gates:** full `-j1` suite (comments only). **LOC:** ~0. **Risk:** none.

### Block V1 — materialize the field groups
**Steps (mechanical, 3 commits — one per group so each diff is reviewable):**
1. `FnContext` struct with the 10 cursor fields; `v.in_loop` → `v.fn_ctx.in_loop` etc. across
   Validator.zig + Statements.zig + Expressions.zig + Declarations.zig (~120 sites, grep-driven).
   Convert `validateFunction`'s entry reset to a struct-literal reset **excluding the depth
   counters** (see Traps). Keep every save/restore per-field.
2. `Outputs` struct with the five exported caches; `analyze` (:501-511) copies `v.out.*`; add the
   doc comment stating the contract ("everything in `Outputs` outlives the Validator via
   AnalysisResult; nothing else does"). `AnalysisResult`'s own field names/layout **do not
   change** (LSP handlers + lint Context consume them; hover.zig/inlay_hints.zig/code_lens.zig
   would churn for nothing).
3. `Scratch` struct with the six internal fields; note on each that it is phase-scoped.
**Gates per commit:** full `-j1`, zero golden drift, `depth_limits_test`, `oom_test`,
`expr_types_coverage_test`, LSP parity suites.
**LOC:** net ≈ +40 (struct decls). **Risk:** low (mechanical) but wide — this is the block most
likely to collide with parallel work; land it in one sitting.

### Block V2 — extract `src/validator/TypeResolve.zig`
**Steps:**
1. Move :616-1065 — `resolveType` + `resolveIdentType/Vec/Mat/Array/Ptr/Atomic/Sampler/Texture`,
   `lookupType`, `parseVectorShorthand`/`parseMatrixShorthand` — plus the suggestion helpers
   (:890-999, `suggestType`/`suggestIdentifier`/`suggestCallable`; they are resolution-adjacent
   and share the same callers) into `src/validator/TypeResolve.zig`. Functions keep the
   `v: *Validator` receiver; Validator re-exports them in a new alias section (same as siblings).
2. Loc/range helpers + diagnostic emitters (:1075-1299) **stay in Validator.zig** — they are the
   toolbox every submodule shares and define the struct's legitimate core.
3. Any in-file tests pinning these helpers move with them (`zig test src/Validator.zig` still
   compiles the graph — run it as the fast check).
**Gates:** full `-j1`; zero golden drift; `validation_suggestions_test` (pins did-you-mean output);
`validation_location_test`/`validation_range_test` (resolution errors' positions).
**LOC:** Validator.zig −450, new file +460. **Risk:** low (types aren't interned; pure moves).

### Block V3 — narrow the alias layer
**Steps:**
1. `runPhases` calls phase entries directly (`try _Declarations.processDirectives(v);` etc.) —
   delete the 12 phase-entry aliases (:519-530) after grepping each for external callers
   (tests sometimes reach them; keep any with callers, note why).
2. Grep every remaining alias for callers outside its own module; delete the dead ones.
3. Section the survivors with audience comments: `// -- cross-submodule contract (called via v.*
   from validator/*) --` vs `// -- public: consumed by tests/LSP --`. This is the "explicit
   submodule contracts" deliverable in its honest form: the contract is *named and enumerated*,
   not re-plumbed.
4. Optional, judgment call: pass `stage: ShaderStage` explicitly to the few Declarations helpers
   that read `v.fn_ctx.current_stage` inside phase 4 (the one genuine cross-module leak — written
   by Statements, read 14× by Declarations). Do it only if the signatures stay clean; otherwise
   leave the field read and document it on `FnContext`.
**Gates:** full `-j1`; zero golden drift.
**LOC:** ≈ −60. **Risk:** low.

### Block V4 — CLAUDE.md + stability tiers (one small commit)
Update CLAUDE.md's module map (add TypeResolve row; adjust the Validator row); add/refresh doc
comments on `validate`/`analyze`/`AnalysisResult` reflecting the `Outputs` contract; re-check the
root.zig stability-tier comments for the validator exports.

## 4. Behavior-change register

None. Every block is behavior-preserving by construction; the gates enforce it. (If Block V3's
alias deletion breaks an external consumer, that consumer was inside the repo — fix the call
site, don't keep the alias.)

## 5. Success criteria

1. `src/Validator.zig` ≤ ~1,000 LOC (from 1,572; assumes ConstEval C2 took its ~130 first):
   struct + nested groups + phases + toolbox + sectioned aliases.
2. Field access reads as intent: `v.fn_ctx.*` (Statements' cursor), `v.out.*` (the exported
   contract), `v.scratch.*` (phase-internal).
3. Zero drift across: corpus goldens, location/range/dedup/related/spec_ref/suggestions suites,
   depth-limit asserts, OOM suite, LSP parity, `expr_types` coverage.
4. `grep -c "pub const" src/Validator.zig` alias count visibly down; every survivor sits under an
   audience section comment.
