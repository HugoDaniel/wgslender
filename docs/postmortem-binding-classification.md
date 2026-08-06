# Post-mortem: one flag, three bugs — and what building an example found

**Date:** 2026-08-06 · **Commit range:** `4f60211..441f374` · **Audience:** internal

Building `examples/js-ts` (plan 01) surfaced a reflection bug that had been shipping
for a long time. Fixing it turned up the same root confusion in two more places, a
fourth site that had quietly forked a shared predicate, and a class of test fixture
that does not parse. This records what was wrong, why none of it looked wrong, and
which of the fixes were *not* taken.

> **Line numbers rot.** Symbols are named instead where possible; grep before
> editing against anything here.

---

## 1. The headline: `is_external_binding` does not mean what it reads like

`Ast.Symbol.Flags.is_external_binding` reads as "this is a `@group`/`@binding`
variable". It is not. `Parser.parseVarDecl` sets it from the **address space**:

```zig
if (decl.address_space == .uniform or decl.address_space == .storage) {
    flags.is_external_binding = true;
}
```

Textures and samplers live in the `handle` address space — usually *implicitly*, since
`var tex: texture_2d<f32>;` names no address space at all. So every texture and every
sampler fails a test that looks like it should pass. Its doc comment said "Set for
@group/@binding vars", which is precisely what made it dangerous: the comment
described the intent, the code implemented something narrower, and every reader
believed the comment.

The codebase also had the flag that *would* have been right — `is_api_facing`,
documented "Set for @group/@binding vars and config-preserved names" — **read in four
places and written in none.** Every branch guarding on it was dead. So the situation
was: a flag that lies about what it tests, and beside it the flag that would have told
the truth, never set.

### The three sites

| Site | Symptom | Who notices |
|---|---|---|
| `reflect/CallGraph.zig` → `recordIdent` | `entryPoints[].resources` and `functions[].directResources` omitted every texture and sampler | Anyone building a per-entry-point bind-group layout from `resources` — silently loses them |
| `Validator.AnalysisResult.isUnusedBindingReportable` | An unused texture reported `W0001` "declared but never used" instead of `W0003` "consumes a bind group layout slot" | Anyone linting a shader with a forgotten texture — gets the true-but-useless message |
| `Validator.AnalysisResult.isDeadCodeReportable` | Exempted uniform/storage bindings from `W0002` but not handles | Latent; no reported instance |

### Why it stayed hidden

Each symptom is *individually plausible*:

- `resources` listing only buffers looks like a deliberate scope decision. The field is
  always present and well-formed. There is no crash, no empty array, no exception —
  nothing that reads as broken.
- `W0001` on an unused texture is a **true statement**. It is just the less useful of
  two true statements. A wrong-but-true diagnostic is far harder to notice than a
  missing one.
- The tint corpus cannot catch either. The goldens pin diagnostic *histograms*, and
  `W0001` vs `W0003` is a code swap that shows up only if you are looking; `resources`
  is not in any golden at all.

It took writing an **example** — code whose job is to print reflection output for a
human to read — before anyone looked at the field closely enough to notice a texture
missing from it.

### Why the one-line fix was wrong

Widening `is_external_binding` to cover handles is a one-line change and would have
fixed all three sites at once. It is also wrong. That flag additionally drives:

`RenamePolicy` · `MinifyEstimator` · three `Validator` checks · five lint rules

Setting it on handles would make every texture and sampler rename-preserved, changing
**minified output for every shader that has one**. A reflection bug does not justify a
repo-wide output change. The two concepts had to stay separate.

### What was done

| Commit | Change |
|---|---|
| `bb5def5` | Reflect attributes resources against the bindings it already extracted, matching `BindingInfo.name_offset == sym.loc` |
| `11e0c98` | `is_api_facing` set from the **attributes** (`hasBindingAttrs`); `isUnusedBindingReportable` and `isDeadCodeReportable` re-keyed to it |
| `441f374` | `no-dead-code` stops re-deriving `isUnusedReportable` |

Two details worth keeping:

**Matching on declaration offset, not name.** In `CallGraph`, a function-local `var`
that shadows a binding has the same `original_name` and a different `loc`. Offset
matching keeps it out of the resource list — a job the buggy flag had been doing *by
accident*, and which a name-based fix would have silently broken. There is an existing
shadowing test that would have caught it.

**Half of `is_api_facing`'s documented job is not implementable here.** The doc said
"@group/@binding vars **and config-preserved names**". `keep_names` is a per-invocation
`Minifier` option consumed by `RenamePolicy`, and B.M5 deliberately moved per-pipeline
state *off* `Symbol` so the record stays immutable past Pass 1. Putting it back would
undo that. The flag now means only the attribute half, and says so.

### The rule, stated once

> `is_external_binding` = **address space**. It answers "does the Printer need to alias
> this, and must the renamer leave the name alone?" — narrower on purpose.
>
> `is_api_facing` = **attributes**. It answers "is this a binding?"
>
> Never read the former as the latter.

Both flags now carry doc comments saying this, because the previous comments are what
caused the bug.

---

## 2. The codebase already knew

`tests/lint_rules_test.zig` contained a test named:

> `no-unused-binding: textures are currently caught by no-unused-vars, not this rule`

…whose comment identified the root cause (address-space flag), predicted the
consequence, and **named the fix**: "a future fix (detect `@group/@binding` attrs
directly)". It was kept explicitly "as a regression guard so a future fix is a visible,
tested change rather than a silent behavior drift."

It did its job perfectly. The knowledge was found, understood, written down, pinned by
a test — and then sat there. Nothing connects a known-limitation test to the *other*
places that share its root cause, so the reflect bug and the dead-code exemption went
on shipping beside a test that explained them both.

> **Practice:** a test whose name contains *currently*, *for now*, or *does not yet* is
> a TODO with a test attached. Grep for them before designing a fix in that area — one
> of them may already be the spec.

---

## 3. A whole class of test fixture does not parse

Phony assignment — `_ = expr;`, standard WGSL — **is not accepted by the parser**. This
was already known and open (found during plan 04; the lexer has an `underscore` token
the parser never uses; 737 tint corpus shaders use the syntax).

What was *not* known: **49 fixtures across `tests/*.zig` use `_ = x;`**. Every one of
those tests runs against a source with parse errors:

```
$ wgslender validate --format json phony.wgsl
{"valid":false,"diagnostics":[
  {"message":"expected expression in statement","line":4,"column":3},
  {"message":"expected expression in statement","line":4,"column":5},
  {"message":"expected assignment, increment, or function call","line":5,"column":1}],
 "errorCount":3,"warningCount":0}
```

They pass because the parser recovers well enough that the rules still see the symbols,
and because each test asserts on a specific lint code that parse errors do not emit.
That is luck, not design. The risk is vacuity: a test asserting *absence* (`0 W0200`)
passes trivially if the fixture degrades enough that the rule never runs.

Only the fixture added in this work was fixed. The other 48 are untouched and remain a
standing hazard.

> **Practice:** for an assertion of absence, prove the fixture can produce the thing.
> The new naming-convention test was verified by temporarily disabling the fix
> (`if (false and hasBindingAttrs(...))`) and confirming it reports 2 × `W0200`. That
> takes one edit and one test run.

---

## 4. The npm type surface contradicted its own runtime

The TypeScript example could not be written at all until four declarations were fixed
(`4f60211`). Correct, documented runtime calls were type errors:

| Defect | Reality |
|---|---|
| `initialize(options)` declared **required** | Implementation does `options \|\| {}`; in Node no options are ever needed. The documented `await initialize()` was `TS2554`. |
| `ValidateOptions.strictMode` declared | The wrapper reads `options.strict`. The typed name was a **silent no-op**; the working name did not type-check. |
| `diagnosticFilters` declared | Unimplementable through this ABI — validate takes a single `u32` flags word. |
| `getVersion()` undeclared | Exists at runtime… on two of the four entry points. |

That last one is the interesting one. `getVersion` is a member of the CJS factory
object that `lib/main.js` re-exports wholesale — but `esm/node.mjs` and
`esm/browser.js` enumerate their re-exports **by hand** and had omitted it. One `.d.ts`
types all four entry points, so simply declaring it (what the plan asked for) would
have made `getVersion()` compile and then throw for every ESM consumer. Fixed on both
sides: the declaration *and* the two missing re-exports.

### The resolution asymmetry underneath it

TypeScript resolves `wgslender` by walking the exports map, finding no
`esm/node.d.mts` beside the ESM entry, and **falling through to the `require` branch's
`lib/main.d.ts`**:

```
File '…/esm/node.d.mts' does not exist.
File '…/lib/main.d.ts' exists - use it as a name resolution result.
```

So **ESM consumers are typed by the CJS declarations.** That is the mechanism by which
a symbol missing from only the ESM wrappers still type-checks. It works on TS 5.9.3 and
needed no `types` condition — but it is why the export lists must be kept in sync by
hand, and nothing enforces that.

Still latent, deliberately not fixed: `version` is declared `string` while ESM ships an
object surrogate with `toString`/`valueOf` (because `export const` snapshots at
evaluation time, before the version is knowable). The package's own suite accommodates
it with `String(wgslender.version)`. `getVersion()` is now the honest path on all four.

> **Rule:** one declaration file, four entry points. Check a symbol exists on **all
> four** before declaring it.

---

## 5. Plans were wrong wherever they were not oracle-pinned

Three plan assumptions were false. All three were caught by running the tool instead of
trusting the prose — which the plans' own ground rules instructed, and which they
nonetheless failed to do for themselves.

- **`warning.wgsl` fixture.** The plan specified a non-uniform `workgroupBarrier()` to
  demonstrate a warning being promoted under strict mode. That is `E0701`, an **error**
  — it can never demonstrate promotion. Replaced with unreachable code (`W0103`) and a
  redundant cast (`W0101`): 0e/2w by default, 2e/0w strict. **This is the second plan
  to make this exact mistake**; plan 04 hit it too. Uniformity violations are errors;
  the only warning emitters are `addWarningR` / `addWarningWithCodeR`.
- **"Invalid source ⇒ `minify` reports errors."** False. A semantic error minifies
  cleanly and returns renamed nonsense; `errors[]` is populated by **parse** errors
  only. The same is true of `reflect` and `compile`. Consequence worth repeating:
  **minification gates nothing on its own.**
- **Plan 03's substring table** expected `@compute` from a demo shader that is a
  vertex/fragment pair.

---

## 6. Environment

- **`node --test test/` no longer accepts a bare directory** on node 26 —
  `Cannot find module '…/test'`. Use a glob: `node --test "test/*.test.mjs"`.
- The npm suite is **182 × 4**, not the 175 × 4 recorded in the plan baseline. It grew;
  nothing regressed. `plans/README.md` now notes the drift.

---

## 7. Verification techniques that earned their keep

**Stash-diff for "this changes nothing".** Used twice, both times to replace an
assertion with a measurement:

```bash
git stash && zig build && <capture> ; git stash pop && zig build && <capture> ; diff
```

- After the parser-flag change: minified output **byte-identical**. The claim "no
  minify-path code reads this flag" was grep-supported, but a parser-set flag deserves
  more than a grep.
- After the `no-dead-code` refactor: `lint --extends @wgslender/strict` over the seven
  compute.toys shaders **identical, 283 lines**. That is what justified *not* rebuilding
  the WASM for that commit.

**Negative controls in the same commit as a widened predicate.** Every widening added
the case that would break if it widened too far — "module-scope `private`/`workgroup`
vars must still not be resources", "a plain module-scope var is still no-unused-vars'
job". These pass before *and* after; their value is entirely in the future.

**Computed verdicts in examples.** `examples/js-ts` prints
`helper 'luminance': default -> renamed, keepNames -> kept` rather than claiming it,
so the assertion cannot pass off text the example printed earlier.

---

## 8. Deliberately not fixed

| Item | Why |
|---|---|
| `version` typed `string`, an object under ESM | Pre-existing; fixing it changes the published type surface for a value everyone reads through `String()`. Its own decision. |
| `strictMode` / `diagnosticFilters` still declared | Deleting them breaks consumers' compiles. Kept, `@deprecated`, with the working name documented. |
| Phony assignment `_ = expr;` unparsed | Real parser gap, 737 tint shaders use it. Open since plan 04. |
| The other 48 `_ = x;` test fixtures | Mechanical but wide; worth a dedicated sweep once the parser accepts the syntax, which would fix them all at once. |
| Renaming `is_external_binding` | Its **name is the trap** — something like `needs_binding_alias` would make the confusion impossible to write. ~15 sites; deferred as its own change. |
| `no_dead_code`'s function-branch flags | Fixed (`441f374`), but note the shape: it was a *forked copy* of a shared predicate, and the dead clauses are what advertised the fork. |

---

## 9. What to take away

1. **A flag whose name and comment disagree with its implementation will be misread by
   every subsequent author.** Three sites made the same mistake independently. The fix
   is not just correcting the logic — it is making the name and comment carry the
   distinction.
2. **Wrong-but-true output is the hardest defect class to spot.** `W0001` on an unused
   texture is accurate. `resources` without textures is well-formed. Nothing looks
   broken, so nothing gets reported.
3. **Examples are tests with a human in the loop.** This bug survived a corpus of
   11,952 shaders and a 182-case package suite; it did not survive one person printing
   the field and reading it.
4. **Known-limitation tests need to be findable from the code they describe.** The
   answer existed, tested, for as long as the bug did.
