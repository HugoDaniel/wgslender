# Overload unification plan — type constructors + builtins on one engine

**Status:** design sketch, not yet scheduled. Written 2026-04-22 after
Phase 3e of Task #9 retired `inferBuiltinReturnType` and the follow-up
`&(*p)` AS/AM fix (commit `5241326`) closed the last code comment that
pointed at unfinished overload work.

## Context

Task #9 migrated every callable builtin except `bitcast` onto the
declarative overload engine in `src/Overload.zig`. The invariant test at
`src/Builtins.zig:2186` ("builtins: every callable entry has declarative
overloads") enforces that. Type-constructor validation — `f32(x)`,
`vec3<f32>(...)`, `mat3x3f(...)`, `S(...)`, `array<f32, 4>(...)` — still
lives in an independent 228-line switch at `src/Validator.zig:3602-3830`
(`checkTypeConstructor`), with helpers at `3481-3500`
(`inferGenericCtorElement`), `3832-3835` (`canConvertScalarTo`), and
`3837-3844` (`elementTypeOf`).

The superficial pitch — "fold constructors into the existing engine" —
doesn't hold up. Multi-arg `vec`/`mat` composition needs a cross-arg
predicate the engine doesn't have, struct/array constructors have
per-call-site signatures the static `sig_table` can't represent, and
constructors uniquely accept transient-abstract element types that the
engine concretizes before resolution runs. The proper move is to name
the resolution-mode axis explicitly and extend the engine along it.

## Problem

Two parallel systems do similar things:

| Concern                              | Builtins                                   | Constructors                                |
|--------------------------------------|--------------------------------------------|---------------------------------------------|
| Shape match (scalar/vector/matrix)   | `Pattern.tparam_*` / `bound_*`             | Hand-rolled `switch (t)` + sub-switches     |
| Element-type conversion              | `bindScalar` + `ScalarFamily.accepts`      | `canConvertScalarTo` wrapper                |
| Unified-scalar inference across args | Solver's tparam unification                | `inferGenericCtorElement` loop              |
| No-match diagnostic                  | Engine's `.no_matching_overload`           | Per-branch `addErrorWithCodeR`              |
| Arity/width suggestions              | Engine says "argument N has type T"        | "requires 3 components, got 4; did you mean 'vec3'?" |

The split is local and works today. The cost is paid every time either
system grows: a new call-site shape forces a choice between extending
the engine (wrong for constructors under the current design) or adding
another validator branch (wrong for builtins). The future-proof fix is
one engine with the right resolution-mode vocabulary, not two.

## Goal

One call-site validator, driven by `Overload`, that covers:

- All 50+ builtins reachable via generic dispatch (**done**).
- `bitcast<T>` via template seeding (**done**).
- Scalar constructors (`f32(x)`, `u32(x)`, …).
- Vector constructors, including variadic composition (`vec4(s, vec2, s)`).
- Matrix constructors, including the all-scalar / all-vector dichotomy.
- Struct and array constructors.

With:

- One diagnostic contract (engine-level, refineable per call site).
- One place to reason about convertibility + scalar-kind unification.
- An invariant test that catches the next "quick check added outside
  the engine" drift.

**Non-goals.** This is not a spec-behavior change — every currently
accepted program must still validate, every currently rejected program
must still fail, and diagnostic regressions must be caught by snapshots
before landing. Not a performance project either; the engine is already
cheap relative to the rest of the validator.

## Design

### 1. Three resolution modes

The engine gains one new entry point; the existing two stay:

```zig
// Existing — full unification. Builtins.
pub fn resolve(sigs, arg_types) ResolveResult;

// Existing — template pre-binds some tparams. bitcast<T>.
pub fn resolveSeeded(sigs, seed, arg_types) ResolveResult;

// New — result type is a known constant; signatures only constrain args.
pub fn resolveTargeted(sigs, target: Types.Type, arg_types) ResolveResult;
```

`Free` and `Seeded` are about how tparams get bound before/during
unification. `Targeted` is different in kind: there is no tparam to
bind for the result, and result-building is trivial (return `target`).
The solver still runs over each sig's `params` exactly as today; only
the result-materialization path shortcuts.

Internally all three collapse to one engine core; the entry points just
differ on seeding and how the result rule is interpreted.

### 2. Two new `Pattern` variants

Constructors need two shapes the current grammar can't express. Both
live in `src/Overload.zig` alongside the existing `tparam_*` / `bound_*`
variants (`Pattern` union starts at line 78):

```zig
/// Variadic component composition for vector constructors.
/// Arg list (any mix of scalars and vectors with mutually convertible
/// element types) must sum-of-widths to exactly `width`. Element type
/// binds to slot `elem_idx` via the ScalarFamily in `elem_family`.
/// Spec: WGSL §16.1 "Value constructors" — vector case.
variadic_components_to_width: struct {
    width: u8,
    elem_idx: u8,
    elem_family: ScalarFamily,
},

/// Matrix-constructor dichotomy: args are either exactly `rows * cols`
/// scalars of the bound element type, or exactly `cols` vectors of
/// width `rows` with the bound element type. No mixing. Single
/// `Pattern` value (not two competing sigs) because the error
/// "requires all scalar values or all column vectors, not a mix" is
/// clearer than a generic no-match. Element binds to slot `elem_idx`.
/// Spec: WGSL §16.1 — matrix case.
all_scalar_or_all_vector: struct {
    cols: u8,
    rows: u8,
    elem_idx: u8,
    elem_family: ScalarFamily,
},
```

Both are cross-arg reductions, unlike existing variants which are
per-slot. The solver's main loop (`src/Overload.zig:288` onward) gets
two new cases that fold across the whole `arg_types` slice before
per-slot matching runs, instead of being called per slot.

### 3. Sig derivation from target type

Constructor sigs are not hand-written in `Builtins.zig`. A new function
emits them from the target type:

```zig
// src/Overload.zig (new)
pub fn ctorSigsFor(arena: Allocator, target: Types.Type) ![]const OverloadSig;
```

Dispatches on `target`:

- **Scalar `T`** — one sig: `(convertible_to_T) -> T`.
- **Vector `vecN<E>`** — four sigs: zero-arg, splat
  (`convertible_to_E`), copy/convert (`vecN<E'>` with `E'` convertible
  to `E`), compose (`variadic_components_to_width{N, E}`).
- **Matrix `matCxR<E>`** — three sigs: zero-arg, copy/convert, compose
  (`all_scalar_or_all_vector{C, R, E}`).
- **Struct `S{f1: T1, ..., fN: TN}`** — two sigs: zero-arg, positional
  `(T1, ..., TN) -> S` with field-by-field `canConvertTo`.
- **Array `array<E, N>`** — two sigs: zero-arg, positional `(E, ..., E)
  × N -> array<E, N>`. Runtime-sized arrays have no constructor form
  (already enforced upstream).

One function, pattern-matched on target. Constructor knowledge lives in
one place instead of scattered across a `switch (t)` with per-arm
sub-switches.

### 4. Diagnostic refiner hook

The engine currently emits one diagnostic: "no matching overload for
'{name}': argument {i} has type '{t}'". For builtins that is fine. For
constructors the existing messages are noticeably better:
`"'vec3' requires 3 components, got 4"`, `"'matCxR' constructor
requires all scalar values or all column vectors, not a mix"`, `"did
you mean 'vec3'?"` etc. Replacing those with the generic message is a
regression.

Solution: the engine accepts an optional refiner on its failure path.

```zig
// src/Overload.zig
pub const DiagnosticRefiner = *const fn (
    sigs: []const OverloadSig,
    arg_types: []const ?Types.Type,
    partial: Bindings,   // best partial match the solver found
    ctx: *anyopaque,
) ?RefinedDiagnostic;

pub const RefinedDiagnostic = struct {
    code: Diagnostic.Code,
    message: []const u8,
};
```

Callers pass a refiner alongside the sig set. Constructors install one
that knows about width-off-by-one ("did you mean 'vec3'?"), matrix
arg-kind mixing, and component-sum vs target-width. Builtins pass
`null` and get the generic message.

Keep the signature tight. The refiner sees the candidate set and the
partial bindings; it does **not** see the AST. If a refinement needs
AST-level context (e.g. "argument 3 was written as `v.xy`, did you
mean the full swizzle?"), that's a post-engine sweep at the call site,
not the refiner's job.

### 5. Dead-code removal

Once constructors route through the engine:

- Delete `canConvertScalarTo` (`src/Validator.zig:3832-3835`) — three
  lines, one caller, inline `Types.canConvertTo(.{ .scalar = src },
  .{ .scalar = dst })` at the two engine sites that still need it.
- Delete `elementTypeOf` (`src/Validator.zig:3837-3844`) — six lines,
  subsumed by the new `Pattern` variants' reduction logic.
- Delete `inferGenericCtorElement` (`src/Validator.zig:3481-3500`) —
  the scalar-kind unification it hand-rolls collapses into the
  existing tparam `ScalarFamily` machinery once the constructor goes
  through `resolveTargeted`. The two call sites at `3171` and `3198`
  both become `const sigs = try Overload.ctorSigsFor(arena, t);
  return Overload.resolveTargeted(sigs, t, arg_types);`.
- Delete the `checkTypeConstructor` switch body (`3621-3828`, ~210
  lines). Keep the outer constructibility gate (`3611-3619`) —
  `is_transient_abstract` is still needed as a precondition for
  `resolveTargeted`.

Net delta: roughly `-230` LOC in `Validator.zig`, `+150` LOC in
`Overload.zig` for the two new variants, `Targeted` entry point,
`ctorSigsFor`, and the refiner hook. Real win is not the ~80 LOC
difference — it's collapsing two call-site dialects into one.

### 6. Extended invariant

`src/Builtins.zig:2186` currently asserts "every callable entry has
declarative overloads". Add a sibling in `tests/inference/`:

```zig
test "call sites: validator does no ad-hoc arg-type checking outside Overload" {
    // Walk checkCallExpr and checkTypeConstructor paths, assert the
    // only exit points producing types are Overload.resolve* or the
    // constructibility gate. Exact form TBD — likely a grep-based
    // smoke test that catches new `canConvertTo` / `canConvertScalarTo`
    // calls appearing outside src/Overload.zig and the few allowed
    // boundaries.
}
```

The intent is to catch the "someone added a quick shape check"
regression before it compounds. Exact mechanism is a step-5 detail,
not load-bearing for the design.

## Sequence

Five roughly ½-day chunks, each independently landable and
conventional-commit-able.

1. **Mode + grammar.** Add `resolveTargeted` + the two new `Pattern`
   variants. Unit-test via throwaway callers in
   `tests/inference/overload_phase4_test.zig` (mirroring the existing
   `overload_phase3c_test.zig` / `overload_phase3d_test.zig` pattern).
   No validator changes yet.
2. **Scalar + simple vec/mat.** Port scalar constructors and the
   zero-arg / splat / copy-convert cases for vectors and matrices
   through `resolveTargeted`. Snapshot error messages before the
   change; diff after to verify diagnostic parity (add refiner entries
   as needed). Keep the old switch fall-through for the variadic
   branches.
3. **Variadic vec composition.** Wire `variadic_components_to_width`
   for multi-arg `vec`. Retire the old multi-arg branch at
   `Validator.zig:3682-3712`. Extend the refiner to emit the
   component-count message with suggestion.
4. **Matrix composition.** Wire `all_scalar_or_all_vector` for
   matrices. Retire the old multi-arg matrix branch
   (`Validator.zig:3740-3787`). Refiner handles the mix-error case.
5. **Struct + array + cleanup.** Port the remaining two constructor
   kinds. Delete the now-dead helpers (§5). Land the invariant test
   from §6. Update `CLAUDE.md`'s "Common Tasks" section so
   "Adding a new AST node type" points new-constructor work at
   `ctorSigsFor` instead of `checkTypeConstructor`.

Each step should land green on `zig build test` and the tint suite (no
new failures) before moving to the next. Snapshot any error-message
changes in `tests/testdata/validation/errors/` and review them as part
of the PR, not as a silent regression.

## Risks & open questions

- **Diagnostic refiner scope creep.** If the refiner grows beyond
  ~100 lines per call-site family, the "uniform diagnostics" win
  evaporates — you just moved the switch-per-target into
  refiner-per-target. Mitigation: budget before starting step 2. If
  the refiner for vectors alone exceeds ~50 LOC, reconsider whether
  the two new Pattern variants should emit richer structured failures
  that the refiner only formats, rather than re-running per-arg logic.

- **Abstract element concretization timing.** `is_transient_abstract`
  at `Validator.zig:3611-3615` exists because constructors receive
  element types that are still abstract (e.g. `vec2(1, 2)` → element
  is `abstract-int`) and concretize later at the use site. The engine
  today concretizes args before running. For `resolveTargeted` with an
  abstract-element target, the solver needs to defer concretization
  until after the sig is chosen, or run against abstract args directly
  with the existing `ScalarFamily` machinery (which already handles
  abstract variants). Unclear which is correct; worth prototyping
  during step 1 on a single vec case and pinning with a test before
  rolling out.

- **Struct constructor with nested constructibility.** `S(a, nested_S,
  c)` where `nested_S` itself has an abstract element chain. Current
  `checkTypeConstructor` at `3789-3805` uses `Types.canConvertTo`
  recursively; that keeps working through the engine only if the
  refiner/sig derivation surfaces field-index context on failure.
  Need to look at whether any existing test in
  `tests/testdata/validation/types/` exercises this before committing
  to an approach.

- **Performance.** `ctorSigsFor` allocates per call site. At CLI
  throughput that's fine; on the LSP hot path it runs on every
  keystroke's parse. If profiling shows it's measurable, cache the
  derived sig slices by target-type identity on the validator's arena
  (arena lifetime matches validator lifetime). Don't pre-optimize —
  measure step 2 end-to-end first.

- **Interaction with the `canConvertTo` AM-widening bug.** Noted during
  the `&(*p)` follow-up: `Types.canConvertTo` (`src/Types.zig:1005-
  1013`) ignores pointer `access_mode`. Constructors don't touch
  pointer arguments, so this doesn't block the plan — but since the
  unification would make `Types.canConvertTo` more load-bearing, fix
  that bug first, in a separate commit, so the migration doesn't also
  change pointer-arg convertibility behavior.

## Cost

End-to-end: 2-3 days of focused work for one person. Split across five
landable steps so it can be done in sessions. Not a crunch project —
the current split works; this is only worth doing when either (a) the
*next* call-site shape has to be added and the two-dialect tax is
about to be paid again, or (b) the diagnostic-uniformity work picks it
up as a dependency.
