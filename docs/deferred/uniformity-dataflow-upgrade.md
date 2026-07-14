# Uniformity dataflow upgrade — implementation plan

**Status:** deferred work, not started. Planned 2026-07-14, verified against `main` @ `87b967c`.
**Origin:** the master-craft program's "Deferred" register: *"current analysis is a name-matching
approximation (self-labeled 'Simplified', Uniformity.zig:298-300) — honest scope, but naga's
analyzer-grade per-expression side table is the model if E07xx is ever to be trusted for real
shaders. Feature-scale project; separate track."*
**Prerequisites:** none — independent of the other deferred tracks (ConstEval, Validator
decomposition, Reflect split). See `docs/deferred/README.md` for shared house rules.

---

## 0. House rules for whoever implements this

- **Cadence:** one block per commit (or a few small commits per block). Conventional-commit style
  matching `git log`. Flag any behavior change in the commit body with a `⚠ BEHAVIOR` note.
- **TDD reds-first:** every block starts by adding failing fixtures, running them to *confirm red*,
  then making them green. Fast per-file loop:
  `zig test --dep wgslender -Mroot=tests/<file>.zig -Mwgslender=src/root.zig --test-filter "..."`
- **Full gate per block:** `zig build && zig build wasm && zig build lsp && zig build lsp-wasm &&
  zig build test` — run the test step **`-j1`** (the tint-corpus suites are memory-heavy and flake
  under concurrent runs). Trust the exit code, not grep for "failed".
- **Corpus goldens:** `tests/inference/corpus_golden.txt` (per-code diagnostic histogram over 9,399
  tint shaders) and `tests/inference/triage_golden.txt` (same histogram split by Tint's own verdict
  into fp/tp/unk). Any drift must be regenerated **in the same commit**
  (`rm tests/inference/corpus_golden.txt tests/inference/triage_golden.txt && zig build test`) with
  a ⚠ note explaining the delta. A crashed corpus run writes nothing and therefore shows no diff —
  "no drift" is only proven by a run that exited 0.
- **Triage tool:** `zig build tint-triage -- --code E0700 --bucket fp` prints a
  `path<TAB>line:col<TAB>message` worklist of shaders Tint accepts but we now flag. This is the
  empirical oracle for the whole plan.
- **No CI.** Everything above is local/on-demand.

## 1. Current state (all claims verified at `87b967c`)

The analyzer is `src/validator/Uniformity.zig` (417 LOC), run as phase 5 from
`src/Validator.zig:451-452` (phase list documented at `src/Validator.zig:14-23`). It is a single
AST walk per function that keeps one scalar `state: {uniform, may_be_non_uniform, non_uniform}`
and a list of "non-uniform sources".

**What fires today.** A diagnostic is emitted only when a builtin call with
`uniformity == .uniform_flow` (`src/Builtins.zig:96-98`; rows: derivatives :334-342, sampling
:351-370, barriers + `workgroupUniformLoad` :422-425, subgroup ops :433-455) occurs while
`state != .uniform` (`Uniformity.zig:267-271`). State becomes non-uniform only via `if`/`while`/
`for` conditions (`switch` too), where a condition is "non-uniform" iff it contains:
- an identifier whose **name string** equals a recorded `@builtin(...)` argument name
  (`Uniformity.zig:276-287`) — the recorder (`analyzeParameters`, :93-112) stores the *builtin's*
  name (`global_invocation_id`), **not the parameter's symbol**;
- an identifier whose name is literally one of nine builtin names (`isNonUniformBuiltin`,
  :390-403), regardless of what it resolves to;
- any call to a `.texture`-kind builtin (`:297-300`, the self-labeled `// Simplified`).

**Codes and plumbing that already exist (keep all of it):**
- `E0700` non_uniform_derivative, `E0701` non_uniform_barrier, `E0702` non_uniform_texture,
  `E0703` non_uniform_subgroup — `src/Diagnostic.zig:866-869`.
- Filterable rule names `derivative_uniformity` / `subgroup_uniformity`
  (`src/Diagnostic.zig:977-978`) + `DiagnosticFilter` (severity override / disable,
  `src/Diagnostic.zig:986-1030`). E0701 is deliberately unfilterable (`Uniformity.zig:341-343`).
- `Builtins.UniformityRequirement = {none, uniform_flow, uniform_args}` (`src/Builtins.zig:50-54`)
  — `uniform_args` is declared but enforced nowhere.
- Related-information diagnostics: `Diagnostic.RelatedInfo` (`src/Diagnostic.zig:85`, entry field
  :157-158, JSON at :217-224) — pinned by `tests/validation_related_test.zig`.
- LSP maps every E07xx to the spec's `#uniformity` anchor
  (`tests/lsp_publish_diagnostics_test.zig:180-208`).

**The headline metric: the analyzer never fires on real shaders.** Neither corpus golden contains
a single E07xx line — across 9,399 real tint-corpus shaders, zero uniformity diagnostics. The one
fixture that demonstrates a firing (`tests/lsp_publish_diagnostics_test.zig:181-193`) only works
because the parameter is *literally named* `global_invocation_id`.

**Known false negatives (each becomes a fixture in Block U0):**
1. Renamed builtin param: `fn main(@builtin(global_invocation_id) gid: vec3<u32>) { if (gid.x > 0u) { workgroupBarrier(); } }` — no diagnostic.
2. Value propagation: `let idx = gid.x; if (idx > 0u) { workgroupBarrier(); }` — no diagnostic even with the magic param name (`idx` matches nothing).
3. Non-builtin sources: a condition on a `var<storage, read_write>` load or a `var<workgroup>` load is non-uniform per spec §15; never detected.
4. Cross-function, callee side: a helper containing an unconditional `workgroupBarrier()` called from inside a non-uniform `if` — no diagnostic (user calls aren't looked up, `Uniformity.zig:267` only hits `Builtins.lookup`).
5. Cross-function, value side: `fn f() -> u32 { return gid.x; }`-style helpers returning non-uniform values — callers see `uniform`.
6. Divergent exits: `if (gid.x > 0u) { return; } workgroupBarrier();` — the barrier runs in non-uniform control flow per spec (no reconvergence when a branch escapes), but state is restored at :169 and nothing fires.

**Known false-positive surfaces (latent — they don't show on the corpus only because the firing
conditions are rare):**
1. `isNonUniformBuiltin(e.name)` at :283 taints **any user identifier** named `position`,
   `sample_mask`, etc. — a fragment shader with `let position = ...; if (position.x > 0) { textureSample(...); }` misfires E0702.
2. `builtin.kind == .texture → non-uniform` at :297-300 includes `textureDimensions`/
   `textureNumLevels` etc., whose results are perfectly uniform.

**Dead/unwired pieces to resolve along the way:**
- `UniformityAnalyzer.current_stage` is computed (:70-80) and never read. Delete or use.
- `Validator.Options.diagnostic_filters` (`src/Validator.zig:91`) is read by the analyzer
  (:21) but **no production caller ever constructs a filter** — and the `diagnostic(...)`
  directive validation (`src/validator/Declarations.zig:84-110`) checks well-formedness only.
  So `diagnostic(off, derivative_uniformity)` in WGSL source has no effect today. Block U4.

**Assets to reuse:**
- `Ast.IdentExpr.ref: SymbolIndex` is bound by AstVisit Pass 2 (`src/Ast.zig:883-891`) — symbol-
  grounded tracking needs no parser/AST changes.
- `checkRecursiveFunctions` (`src/validator/Declarations.zig:452-491`) already builds a
  fn-symbol-indexed call graph and runs as phase 3.75 — i.e. **before** phase 5, so by the time
  the analyzer runs, the call graph is guaranteed acyclic and a bottom-up order exists.
- The validation fixture harness: `tests/testdata/validation/uniformity/*.wgsl` with
  `// @expect-valid` / `@expect-error` headers, embedded via `tests/testdata_validation.zig` and
  driven by `runValidationTest` (`tests/validation_test.zig:784-796`). Only two fixtures exist,
  both `@expect-valid`.

## 2. Design

### 2.1 The one rule that governs every approximation

The tint corpus + triage oracle make "false positive against Tint" a measurable, gated quantity.
Tint implements spec §15 exactly; we approximate. Therefore:

> **Every approximation must lean false-negative.** When the analysis cannot prove a value or
> control flow non-uniform *by a spec rule we implement exactly*, it must assume uniform.
> Target: the fp bucket for E0700-E0703 in `triage_golden.txt` is **zero** at the end of every
> block (each nonzero entry is either an analyzer bug to fix in-block, or a documented,
> hand-verified Tint divergence recorded in the golden's commit message).

This inverts the usual static-analysis instinct ("when unsure, taint") — deliberately. A WGSL
validator that flags shaders Dawn accepts is worse than one that misses violations; missing
violations is today's status quo (zero diagnostics fired).

### 2.2 Architecture: per-function dataflow + bottom-up call summaries

Model: WGSL spec §15's per-function analysis with function "tags", as tint and naga implement it.
The implementer **must read spec §15** (https://www.w3.org/TR/WGSL/#uniformity) before Block U2 —
the reconvergence and value rules below are a faithful summary, but the spec text is normative and
the corpus oracle will punish any drift.

Keep it all in `src/validator/Uniformity.zig` (it will grow to ~1,100 LOC; that's fine — split
into `src/validator/uniformity/` only if it passes ~1,500). Keep the existing contract: the
analyzer holds its own state, reads the module + diagnostic sink off `*Validator`, and does not
borrow the validator's per-function fields (`Uniformity.zig:1-7`).

Core data model (names indicative, adjust to taste):

```zig
const Source = struct { loc: u32, desc: []const u8 };       // for related-info chains
const ValueUniformity = union(enum) { uniform, non_uniform: Source };
const CfUniformity = union(enum) { uniform, non_uniform: Source };

// Per-function, keyed by SymbolIndex (u32): params + locals.
values: std.AutoHashMapUnmanaged(u32, ValueUniformity)

// Statement behaviors, spec §9.1 "Behaviors": which ways a statement can complete.
const Behaviors = packed struct { next: bool, ret: bool, brk: bool, cont: bool };

const FnSummary = struct {
    /// Non-null if calling this function from non-uniform control flow is a violation:
    /// the function (transitively) reaches a uniform_flow builtin while its own CF is
    /// still equal to entry CF. Carries the root builtin's kind (for E070x selection),
    /// name, and callee-side loc (for the related-info chain).
    call_site_requirement: ?struct { kind: Builtins.Kind, name: []const u8, loc: u32 },
    /// Uniformity of the return value.
    ret: union(enum) { uniform, non_uniform: Source, depends_on_args: ArgBitset },
};
summaries: std.AutoHashMapUnmanaged(u32, FnSummary)  // keyed by fn SymbolIndex
```

**Value rules (spec §15 "uniformity of values", encoded exactly — these are the only taint
sources; everything else defaults to uniform per §2.1):**

| Read of | Uniformity |
|---|---|
| `@builtin` param among: vertex_index, instance_index, position (fragment input), front_facing, sample_index, sample_mask, local_invocation_id/index, global_invocation_id, subgroup_invocation_id | non-uniform (keep/extend the :390-403 list; check spec for subgroup builtins) |
| workgroup_id, num_workgroups, subgroup_size | uniform |
| user-defined entry-point params (`@location` inputs) | fragment/vertex: non-uniform; compute: n/a |
| `var<uniform>`, `var<storage, read>` loads | uniform (address uniformity handled via index exprs) |
| `var<storage, read_write>` loads | non-uniform |
| `var<workgroup>` loads | non-uniform (except via `workgroupUniformLoad`, which returns uniform — that's its purpose) |
| `var<private>` loads | see calibration note below |
| module `const` / `override` / local `let`/`const` | uniformity of the initializer (override = pipeline-constant = uniform) |
| function-local `var` loads | current `values` entry (assignment-tracked) |
| literals, type ctors, most builtin results | uniform iff all operands/args uniform |
| results of specific builtins the spec lists as never-uniform (e.g. subgroup scans/ballot per spec table) | non-uniform — encode as a per-row column, Block U3 |

Calibration note on `var<private>`: the spec treats private storage per-invocation; a simplistic
"private read = non-uniform" will flag valid shaders where the only stores are uniform. Start with:
non-uniform iff any assignment anywhere in the module stores a non-uniform value (cheap pre-scan),
else uniform. Recalibrate against the fp bucket.

**Control-flow rules:**
- Entry CF = uniform (for entry points). For non-entry functions, CF is analyzed relative to
  entry; the *caller's* CF is applied via the summary at the call site.
- `if (c)`: branch bodies run at CF ⊔ uniformity(c). **Reconvergence:** CF after the `if` returns
  to the pre-`if` CF **iff both branches' behavior sets are exactly `{Next}`**; otherwise CF after
  is CF ⊔ uniformity(c). This single rule is what fixes false-negative #6 while keeping the
  balanced-if fixtures green. (Behavior computation: `return`→{Return}, `break`→{Break},
  `continue`→{Continue}, `discard`→{Next} — discard demotes to helper invocation precisely so
  derivatives stay defined; it is *not* a divergence for uniformity. Compounds/sequences per
  spec §9.1.)
- `switch`: same as `if` over all cases.
- `loop`/`while`/`for`: body CF starts at CF ⊔ uniformity(condition, if any). `break`/`continue`
  under non-uniform CF make the *post-loop* / next-iteration CF non-uniform. Iterate the body to a
  fixed point on (`values`, CF) — the lattice is two-point and monotone, so it terminates; in
  practice 2 passes. `break if (c)` in `continuing` taints like a condition.
- Assignments/`var` decls update `values` (compound assign, `++`/`--`, phony `_ =` included —
  phony evaluates the RHS but binds nothing).
- Pointers: v1 handles only the trivially-resolvable local case (`let p = &x;` → deref reads/writes
  hit `x`'s entry). Anything else — pointers as function params, pointer-typed returns — falls back
  to §2.1: reads through them are **uniform** (false-negative-safe), writes through them taint
  nothing. Document at the code site; full pointer tags are Block U5 / non-goal.

**Call rules (Block U3):**
- Bottom-up over the call graph (rebuild it the way `checkRecursiveFunctions` does, or extract
  that builder into a shared helper — acyclicity is already guaranteed by phase 3.75).
- Direct builtin call with `uniformity == .uniform_flow` at non-uniform CF → violation (as today).
- User call: if callee summary has `call_site_requirement` and CF is non-uniform → violation
  **reported at the caller's call site**, code chosen by the root builtin's kind, with related-info
  entries: (a) the source that made CF non-uniform, (b) the callee-side builtin location
  ("call chain reaches workgroupBarrier here").
- Call *result* uniformity: from `ret` in the summary (`depends_on_args` folds the actual args'
  uniformity at the call site).

**Diagnostics:** codes, messages (`Uniformity.zig:370-376`), severities, and the E0701-unfilterable
rule stay exactly as-is. New: attach `related` entries carrying the taint chain (source → condition
→ call). Additive on the wire (LSP `relatedInformation`, JSON `related` array) — mark ⚠ additive.

### 2.3 Rejected alternatives

- **Per-expression side table (naga's `FunctionInfo`)**: naga needs it because its IR is
  handle-based and expressions are visited out of order. Here expressions are arena pointers
  walked in order; recursive evaluation with a symbol-keyed map gives the same precision without
  a table. Revisit only if Block U5's pointer tags demand it.
- **Full spec graph construction (nodes+edges+reachability)**: the spec's presentation, not a
  requirement. The dataflow formulation above computes the same verdicts for the subset we
  implement and stays debuggable.
- **Blanket taint-on-unknown**: violates §2.1; would flood the fp bucket and make E07xx *less*
  trustworthy than today's silence.

## 3. Blocks

### Block U0 — fixture harness + truth table (pins first)
**Steps:**
1. New fixtures under `tests/testdata/validation/uniformity/` using the existing
   `@expect-valid`/`@expect-error` header convention; register them in
   `tests/testdata_validation.zig` + `tests/validation_test.zig` (mirror :784-796).
2. Commit the **currently-green** pins immediately: the two existing valid fixtures stay; add
   (a) the magic-name case from the LSP fixture as `@expect-error E0701`; (b) balanced-if
   reconvergence: barrier *after* a non-uniform `if` whose branches both fall through →
   `@expect-valid`; (c) `textureDimensions` in a condition + `textureSample` inside →
   `@expect-valid` — **this one is red today** (fp surface #2). Fixing it is U1's first green.
3. Write the full red inventory as fixtures with a `// @blocked-on: U1|U2|U3` comment line, but
   do **not** register the red ones yet — each later block registers its own (reds-first per
   block, suite stays green between blocks).
**Gates:** full `-j1` suite; corpus goldens untouched.
**LOC:** ≈ +150 (fixtures + registration). **Risk:** low.

### Block U1 — symbol-grounded sources (kill the name matching)
**Red:** register fixtures: renamed-param case (#1 above, `@expect-error E0701`); user-variable-
named-`position` fp case (`@expect-valid`); `textureDimensions` fp case from U0.
**Steps:**
1. `analyzeParameters` records the **parameter's `SymbolIndex`** (`p.name`) with the builtin's
   uniformity classification — not the builtin name string.
2. `analyzeExprUniformity` `.ident` arm: consult `e.ref` against the recorded set; delete the
   `src.builtin_name` string comparison and the bare `isNonUniformBuiltin(e.name)` call (:276-287).
   `isNonUniformBuiltin` remains, consulted only when *classifying parameters*.
3. Delete the `.texture`-kind blanket (:297-300): builtin call results default to
   "uniform iff args uniform" (fold over args — already walked at :302-306).
4. Delete the dead `current_stage` field (:36, :70-80) — or wire it if a spec rule needs it; today
   nothing reads it.
**Gates:** all uniformity fixtures green (incl. the LSP fixture via full suite —
`tests/lsp_publish_diagnostics_test.zig` keeps passing because `global_invocation_id` the *param
name* now binds to the param *symbol*); corpus goldens — expect still zero E07xx (nothing new
taints yet beyond renamed params; if E07xx appears, triage fp to zero before committing).
**LOC:** ≈ +40/−50. **Risk:** low.

### Block U2 — intra-function dataflow (values, behaviors, reconvergence, loops)
**Red:** register fixtures #2 (let-propagation), #3 (storage/workgroup loads), #6 (divergent
return), plus valid twins: uniform-buffer-load condition → `@expect-valid`; barrier after
balanced non-uniform if → `@expect-valid` (already pinned in U0 — must stay green).
**Steps:**
1. Introduce `values` map + `ValueUniformity`; seed from params (U1's set) at function entry.
2. Implement the value table from §2.2 for loads/idents/literals/ctors; assignments and decls
   update the map. Address-space classification comes off the resolved symbol's declaration
   (module `var` address space is on its AST decl; the symbol table exposes it — follow how
   `no_unused_binding`/validator address-space checks read it).
3. Implement `Behaviors` for every statement kind; apply the reconvergence rule to `if`/`switch`.
4. Loop fixed point (bounded re-walk until `values`+CF stable).
5. Replace the ad-hoc `state` save/restore with CF values threaded through the walk; keep
   `may_be_non_uniform` only if the spec mapping actually uses it — otherwise delete the enum
   variant (it is write-only today).
6. Attach related-info: the `Source` that tainted the CF becomes a `related` entry on the
   violation ("control flow becomes non-uniform here: read of storage buffer 'data'").
   ⚠ BEHAVIOR (additive): E07xx entries gain `related` on both CLI JSON and LSP.
**Gates:** fixtures; `tests/validation_related_test.zig` (extend with one E07xx-related case);
full suite; **corpus goldens will drift** — E07xx rows appear for the first time. Regenerate
in-commit, then `zig build tint-triage -- --code E0700 --bucket fp` (and E0701/2/3): drive fp to
zero before the commit lands. tp/unk growth is the success metric — quote it in the commit body.
**LOC:** ≈ +450/−120. **Risk:** medium-high — this is the calibration block; budget a full session.

### Block U3 — cross-function summaries
**Red:** register fixtures #4 (barrier-in-helper called under non-uniform if → error at call
site) and #5 (helper returning non-uniform value feeding a condition → error at the downstream
barrier), plus valid twins (helper with barrier called from uniform flow; helper returning
uniform value).
**Steps:**
1. Build/reuse the call graph (share the builder with `checkRecursiveFunctions`,
   `Declarations.zig:452-491`); compute a bottom-up order (post-order DFS — acyclic by phase 3.75).
2. Compute `FnSummary` per function during its analysis pass: `call_site_requirement` = first
   uniform_flow builtin (or requiring callee) reached while CF still == entry; `ret` folded from
   all `return` expressions (`depends_on_args` via param-index bitset).
3. Call sites: enforce + consume summaries per §2.2. Entry points are analyzed with entry
   CF = uniform; unreachable non-entry functions still get summaries (cheap, order-independent).
4. Builtin result-uniformity column: add to the `def(...)` row shape in `src/Builtins.zig` only
   if the spec's never-uniform-result list demands it (subgroup ops); otherwise defer to U5.
**Gates:** fixtures; corpus regen + fp-to-zero as in U2; full suite.
**LOC:** ≈ +250. **Risk:** medium.

### Block U4 — wire the diagnostic controls (make `diagnostic(...)` real)
**Red:** fixture: `diagnostic(off, derivative_uniformity);` directive + a U2-detectable derivative
violation → `@expect-valid`; same with `(warning, ...)` → expect W-severity E0700 (check the
harness supports severity expectations; extend if not); `@diagnostic(off, derivative_uniformity)`
as a **function attribute** scoping only that function.
**Steps:**
1. Phase 1 directive walk (`Declarations.zig:84-110`) additionally populates a
   `DiagnosticFilter` owned by the Validator (arena) when it sees well-formed
   `derivative_uniformity`/`subgroup_uniformity` rules; `analyzeUniformity` consumes it merged
   with any caller-provided `options.diagnostic_filters` (caller wins? — no: **innermost scope
   wins per spec §2.3 diagnostic filtering**; document the merge).
2. Function-level `@diagnostic` attributes: nearest-enclosing-scope severity for violations inside
   that function. Statement-level scoping: out of scope (document).
3. E0701 stays unfilterable (spec: barriers are hard errors — keep :341-343 semantics).
**Gates:** fixtures; snapshot test (directive printing already pinned at
`tests/snapshot_test.zig:376-377` — unchanged); corpus goldens: shaders using these directives may
*lose* E07xx rows — regen in-commit. ⚠ BEHAVIOR: source-level `diagnostic(...)` now actually
suppresses/demotes E0700/E0702/E0703 (bugfix-class; today it's parsed and ignored).
**LOC:** ≈ +120. **Risk:** low-medium.

### Block U5 (optional, separate decision) — `uniform_args` + pointer tags
Enforce `Builtins.UniformityRequirement.uniform_args` (e.g. texture/sampler operands, subgroup
broadcast ids) and real pointer-parameter tags (spec's ParameterContents tags). Only worth it if
U2-U4's triage shows real shaders exercising these. Not planned; decide after U4.

## 4. Behavior-change register

| Block | Change | Class |
|---|---|---|
| U1 | user identifiers shadowing builtin names no longer taint; `textureDimensions`-class calls no longer taint | bugfix (fp removal) |
| U2 | E07xx fires on real shaders (corpus histogram gains rows); diagnostics gain `related` chains | feature + additive wire |
| U3 | violations reported at call sites of user functions | feature |
| U4 | `diagnostic(...)` directives/attributes actually filter E0700/2/3 | bugfix-class |

No LSP protocol shape changes; no npm wasm rebuild needed unless `Diagnostic` JSON shape changes
(it doesn't — `related` already serializes, Diagnostic.zig:217-224).

## 5. Success criteria

1. Every fixture in the U0 truth table green; the six false-negative classes each have a firing
   fixture and a non-firing twin.
2. `triage_golden.txt`: E0700-E0703 fp bucket = 0; tp bucket > 0 (quote the counts in the final
   commit). Zero drift in non-E07xx rows at U1; explained drift only afterwards.
3. `tests/lsp_publish_diagnostics_test.zig` and `tests/validation_spec_ref_test.zig` (uniformity
   spec-URL slug, :124) untouched and green.
4. Full `-j1` suite exit 0; all four artifacts build.
