# Plan: phony assignment (`_ = expr;`) — parser support, and the 50 fixtures waiting on it

**Status:** ready to execute · **Written:** 2026-08-06 against `main` @ `24c6f51`
· **Companion:** [postmortem-binding-classification.md](postmortem-binding-classification.md) §3

> **Line numbers rot.** Symbols are named where possible; re-verify any `file:line`
> with a grep before editing against it.

---

## 0. Two corrections to the framing

This plan was requested as "fix the remaining 48 phony assignment fixtures". Two things
have to be said before any of it is executable.

**The count is 50, not 48.** The post-mortem's figure came from the narrow grep
`_ = [a-z]`, which misses every fixture whose right-hand side does not start with a
lowercase letter — `_ = 1;`, `_ = big[0];`, `_ = takes(&buf);`, `_ = u[0].a;`,
`_ = (*unknown).field;`. The accurate inventory is in [§8](#8-appendix--full-inventory);
re-derive it with:

```bash
grep -rnE '^[[:space:]]*\\\\.*_[[:space:]]*=' tests/*.zig | wc -l   # → 50
```

**Rewriting the fixtures is the wrong first move.** They are invalid because the parser
does not accept standard WGSL. That gap also fails **737 shaders in the tint corpus**.
Fixing the parser makes all 50 fixtures valid with *zero* fixture rewrites; rewriting
them first is throwaway work that also leaves the conformance bug in place. The
fixtures still need an **audit** afterwards — but auditing 50 tests is much less work,
and much less risk, than redesigning 50 fixtures around a defect.

Route B (rewrite only, leave the parser alone) is specified in full at [§7](#7-route-b--fallback)
in case that trade is wanted anyway.

---

## 1. Verified current state

Every claim below was measured on 2026-08-06; the command to re-derive it is given.

| Fact | Evidence |
|---|---|
| `_ = x;` does not parse — 3 errors, no recovery of the statement | `printf '@compute @workgroup_size(1)\nfn main(){let x=1.0;_ = x;}\n' \| ./zig-out/bin/wgslender validate --format json -` |
| `let _ = 3.14;` cascades into **6** errors | same, with `let _ = 3.14;` |
| 50 fixture lines across 8 test files | grep above |
| **737** tint shaders use a phony-assignment statement | `grep -rlE '^[[:space:]]*_[[:space:]]*=' tests/testdata/tint \| wc -l` |
| 23,729 `.wgsl` files in the corpus total | `find tests/testdata/tint -name '*.wgsl' \| wc -l` |
| The lexer already has the token | `src/Lexer.zig` — `Tag.underscore`, symbol `"_"`, plus a passing test `lexer: single underscore is underscore token` |
| The parser never consumes it | `grep -n underscore src/Parser.zig` → no hits |
| ~21 files switch over `Ast.Stmt` | `grep -rn incr_decr src lsp \| awk -F: '{print $1}' \| sort -u \| wc -l` |
| Suite baseline | `zig build test` green; tint `11952 total, 8390 passed, 0 failed, 3562 skipped` |

---

## 2. What phony assignment is, and why it is not cosmetic

WGSL §9.3, `variable_updating_statement`:

```
| lhs_expression ( '=' | compound_assignment_operator ) expression
| '_' '=' expression                                  ← this one
| lhs_expression '++'
| lhs_expression '--'
```

The expression is evaluated and its value discarded. It exists for two real jobs:

1. **Silencing an unused-value diagnostic** without inventing a variable — which is
   exactly what all 49 Class-A fixtures use it for.
2. **Forcing a resource into the pipeline layout.** `_ = tex;` marks a binding as
   statically used so it survives into the bind-group layout even when nothing reads
   it. This is idiomatic and has no substitute — which is why the corpus is full of it.

`_` is *not* an identifier. It lexes as its own token, and `eatIdent` does not accept
it, so no `Symbol` is ever created for it. That is by design and the validator's
comments already assume it (see §3.C).

---

## 3. Three defects, one root

### A. `_ = expr;` does not parse — 49 fixtures, 737 corpus shaders

`parseStatementInner` parses a leading expression, then looks for an assignment
operator (`parseAssignOp`). `_` is not an expression, so `parseExpression` fails with
*"expected expression in statement"* before the `=` is ever considered.

### B. `let _ = expr;` cascades — 1 fixture + 2 C examples

```
'let ' requires an initializer [E0300]      1:1
expected '='                                3:7
expected expression after '=' in let decl   3:7
expected ';'                                3:9
expected expression in statement            3:9
expected assignment, increment, or call     4:1
```

Six errors for one line. This is *not* the same bug as A: `let _ = …` is genuinely
invalid WGSL (you may not declare `_`), so it **should** be rejected — but with one
clear diagnostic, not a six-error cascade that misattributes the failure to the
previous line.

Affected: `tests/reflect_test.zig` (1), `examples/c/lint.c` and
`examples/c/lint_fix.c`. The C examples ship a demo shader with six parse errors while
purporting to demonstrate linting.

### C. The reserved-`_` check is dead code

`validator/Declarations.zig` → `checkReservedIdentifiers` has:

```zig
const is_bare_underscore = name.len == 1 and name[0] == '_';
…
"identifier '_' is reserved: it may only appear as the left-hand side of a phony assignment"
```

That branch **can never fire**. It scans `module.symbols`, and a symbol named `_` is
never created: `_` lexes as `.underscore`, and `eatIdent` accepts only `.ident` and
`.reserved_ident`. The `__`-prefix branch beside it *is* reachable (`__foo` lexes as
`.reserved_ident`, which `eatIdent` does accept) and has three tests; the bare-`_`
branch has none.

This is the same shape as the `is_api_facing` finding in the post-mortem: **a written,
plausible, tested-looking branch that nothing can reach.** Its comment ("the parser
does not build a `Symbol` for that case") documents the intended design — the parser
was *supposed* to handle `_` and never did.

---

## 4. Route decision

| | **Route A — parser first** (recommended) | **Route B — rewrite fixtures** |
|---|---|---|
| Fixture edits | 0 rewrites, 50 audits | 50 rewrites, each preserving test intent |
| Conformance | 737 corpus shaders start parsing | unchanged |
| Dead branch §3.C | resolved | untouched |
| Corpus goldens | **will move** — must be regenerated and reviewed | unchanged |
| Blast radius | ~21 files switch over `Ast.Stmt` | test files only |
| Risk | medium — new AST node touching printer, CST, incremental, DCE | low |
| Wasted work if the other is done later | none | all 50 rewrites |

Route A is recommended. Route B's only advantage is a small blast radius, and it buys
that by making 50 test fixtures permanently weirder than the language they test.

**Execute Route A. If it stalls at Block 6 (goldens), Route B remains available and
nothing done in Blocks 1–5 is wasted.**

---

## 5. Route A — blocks

Conventions: one conventional, atomic commit per block. TDD reds-first — write the
failing test, run it, confirm the stated red, then implement. No CI. Blocks are
self-contained: each restates what it needs.

### Block 1 — Parse `_ = expr;`

**Red.** In `tests/parser_test.zig` (or nearest parser suite), assert that
`@compute @workgroup_size(1) fn main() { let x = 1.0; _ = x; }` parses with zero
errors. Expect *"expected expression in statement"* today.

**AST design — decide once, here.** Add a new `Ast.Stmt` variant:

```zig
phony: *PhonyStmt,

pub const PhonyStmt = struct {
    loc: u32 = 0,      // the `_` token
    expr: Expr,
    span: Span = .empty,
};
```

Rejected alternatives, with reasons — do not relitigate silently:

- *Reuse `AssignStmt` with a `_`-shaped `left`.* Requires an `Expr` variant for `_`,
  which pollutes every expression switch and every ident-resolution path with a case
  that is not an expression. The grammar makes `_` a statement-level token, not an
  lhs_expression; the AST should say the same.
- *Desugar to `CallStmt` when the RHS is a call, drop otherwise.* Breaks CST/AST
  losslessness and round-trip printing, and silently discards non-call RHS.

**Why a new variant is the right cost:** `Ast.Stmt` is a tagged union and the codebase
switches over it exhaustively in ~21 files. Adding a variant turns "have I handled this
everywhere?" from a review question into a **compile error at every site that must
change**. That is the cheapest possible completeness guarantee and the main argument
for Route A being tractable at all.

**Also:** add `Cst.Kind.phony_stmt` beside `assign_stmt` and lower to it, or the CST
stops being lossless. Check `src/incremental/Anchor.zig` — statement kinds are
classified there for the incremental hot path.

**Verify.** `zig build test`. Expect compile errors first, at each exhaustive switch;
work through them. Sites that legitimately do not care get an explicit arm, not a
widened `else`.

**Commit.** `feat(parser): accept phony assignment (_ = expr)`

### Block 2 — Bind the RHS and count it as a use

**Context.** Block 1 parses the statement; nothing yet walks its expression.

**Red.** Assert that in `fn f(){ let x = 1.0; _ = x; }` the symbol `x` has
`use_count == 1` — and that `no-unused-vars` (W0001) does **not** fire on it. Both fail
until `AstVisit` walks `PhonyStmt.expr`.

This is the property all 49 Class-A fixtures silently depend on, so it is worth its own
block and its own test rather than being folded into Block 1.

**Green.** Walk `.phony` in `src/AstVisit.zig` pass 2. Then audit the other walkers the
compiler flagged in Block 1 — `Dce.zig`, `reflect/CallGraph.zig`,
`validator/Statements.zig`, `validator/Uniformity.zig`, `lint/MultiVisitor.zig` — and
make sure each treats the RHS as a real evaluated expression.

**Watch for:** `_ = tex;` must mark `tex` as a used resource (see §2, job 2). Add a
reflect test asserting a binding referenced *only* by a phony assignment still appears
in `entryPoints[].resources`. That connects directly to the bug fixed in `bb5def5`.

**Commit.** `feat(parser): bind phony-assignment operands as uses`

### Block 3 — Print, minify, round-trip

**Red.** A snapshot/round-trip test: `_ = x;` survives parse → print, and minifies to
`_=x;`.

**Green.** `Printer.zig` arm. Confirm the CST round-trip and `ast_equal`/`cst_lower`
parity gates cover the new node — per
`memory: reference_parity_gate_coverage`, those gates only compare the fields they are
told about, so a new node can pass them vacuously. Assert the node's presence
explicitly.

**Do not** make the minifier drop phony assignments in this block, even when the RHS is
pure. It is a legitimate optimization and a separate decision (§9).

**Commit.** `feat(printer): emit phony assignments`

### Block 4 — Validate it, and fix the `let _` cascade

**Red, two cases.**
1. `_ = voidFn();` where `voidFn` returns nothing → should be one clear error; today
   it will parse (after Block 1) and probably pass validation.
2. `let _ = 3.14;` → should be **one** diagnostic naming the real problem, not the
   six-error cascade in §3.B.

**Green.** For (1), reject a phony assignment whose RHS has no value type. For (2),
recognise `.underscore` where a declaration name is expected and emit the message the
validator already wrote for this case — which resolves §3.C by making the check
reachable, or by moving it to the parser and deleting the dead branch. **Either is
acceptable; do not leave both.**

**Commit.** `fix(validator): diagnose '_' misuse in one message`

### Block 5 — Incremental + LSP surfaces

**Context.** The incremental driver classifies statement kinds
(`src/incremental/Anchor.zig`, `Splice.zig`); LSP features switch over statements
(`lsp/handler/node_at_offset.zig`, `call_hierarchy.zig`).

**Red.** An incremental test that edits inside a phony assignment and asserts
`expectModulesEquivalent` against a full reparse (the established correctness gate —
see `memory: reference_incremental_hotpath_gate`).

**Commit.** `feat(incremental): handle phony assignments on the hot path`

### Block 6 — Corpus goldens (the expensive one)

**This block will produce a large, legitimate diff. Budget a session for it.**

737 shaders currently fail to parse and will start parsing. They then flow into the
validator, so both goldens move:

- `tests/inference/corpus_golden.txt` — per-code diagnostic histogram
- `tests/inference/triage_golden.txt` — that histogram split by Tint's verdict

The tint semantic-preservation counts (`8390 passed / 3562 skipped`) will also move.

**Procedure.**
1. Record the before-state: `zig build test 2>&1 | grep "tint tests:"`.
2. Regenerate: `rm tests/inference/corpus_golden.txt tests/inference/triage_golden.txt && zig build test`.
3. **Review the diff, do not just accept it.** Every newly-parsing shader is a shader
   the validator has never seen. Expect new diagnostics; some will be real validator
   bugs on constructs that were previously unreachable.
4. Triage new false positives: `zig build tint-triage -- --code EXXXX --bucket fp`.
5. Any `fp` bucket growth is a finding, not noise — record it, fix it or file it.

**Memory warning:** the corpus tests are memory-heavy and flake under concurrent
`zig build test`. Run with `-j1`. An OOM-crashed pin **writes nothing and shows no git
diff** — which reads exactly like "no drift". Confirm the goldens' mtime changed.

**Commit.** `test(corpus): regenerate goldens for phony-assignment parsing`

### Block 7 — The 50 fixtures, audited

**Context.** After Blocks 1–6 all 50 fixtures are valid WGSL and need **no rewriting**.
What they need is verification that they now test what their names claim, because the
semantics changed underneath them: `_ = x;` now counts as a use of `x`.

**Procedure, per file** (inventory in §8):
1. Run the file's suite. Anything that fails is a test that was passing *because of*
   the parse failure — the most valuable finding in this block. Record each one in the
   commit body.
2. For every test asserting an **absence** (`countCode(...) == 0`, "no W0001"), prove
   non-vacuity: temporarily break the thing under test in place, confirm the expected
   red, restore. Cheap protocol, one edit and one run — the technique is recorded in
   the post-mortem §3.
3. Where `let x = u; _ = x;` existed only to launder a use, simplify to the direct form
   now that it parses. Optional; prefer leaving fixtures alone unless the indirection
   obscures the test.

**Also in this block:** `examples/c/lint.c` and `examples/c/lint_fix.c` use
`let _ = 3.14;` (Class B). After Block 4 it is a clean single error, but the demo
shader should be valid WGSL — change it to a phony assignment or drop the line. Re-run
`make -C examples/c test`.

**Commit.** `test: audit phony-assignment fixtures after parser support`

### Block 8 — Rebuild artifacts and document

- `zig build wasm && cp zig-out/bin/wgslender.wasm packages/js-npm/wgslender.wasm`;
  `cd packages/js-npm && npm test` (baseline 182 × 4). Diagnostics changed, so the
  committed wasm must be rebuilt or JS consumers never see it.
- `cd packages/rust && cargo xtask check`.
- `make -C examples/c test` (10/10), `cd examples/js-ts && npm test` (28/28).
- Update the post-mortem §3 and §8 tables to say this is resolved, and correct its
  count from 49/48 to 50.

**Commit.** `chore: rebuild artifacts for phony-assignment support`

---

## 6. Route A — definition of done

- [ ] `_ = expr;` parses, binds, prints, minifies and round-trips through the CST.
- [ ] A binding referenced only by a phony assignment appears in `resources`.
- [ ] `let _ = …` produces exactly one diagnostic; the dead branch in §3.C is either
      reachable or deleted — not left as-is.
- [ ] Both corpus goldens regenerated, the diff **reviewed**, and any new `fp`-bucket
      entries recorded.
- [ ] All 50 fixtures pass unmodified; every newly-failing test is explained in a
      commit body rather than adjusted into silence.
- [ ] `zig build test`, `make -C examples/c test`, `cargo xtask check`,
      `packages/js-npm` 182 × 4, `examples/js-ts` 28/28 all green.
- [ ] wasm rebuilt and committed.

---

## 7. Route B — fallback

Only if Route A is explicitly rejected. Leaves the conformance gap and §3.C in place.

**Replacement idioms**, in order of preference:

| Situation | Replacement |
|---|---|
| `let x = u; _ = x;` laundering a use of binding `u` | Write through a storage binding: `sink = u;` with `@group(n) @binding(m) var<storage, read_write> sink: T;` |
| `_ = f(args);` for side effects | Bare call statement: `f(args);` — already parses |
| `_ = expr;` where the value is genuinely unwanted | Return it from a non-entry helper, or delete both the `let` and the `_ =` if nothing depends on the symbol existing |
| `let _ = expr;` (Class B) | Always a bug — rename to `_unused` or delete |

**Hazards.** Every replacement adds declarations, and declarations trip other rules —
a `sink` binding can fire `no-unused-binding`, a helper can fire `no-dead-code`. Each
rewritten fixture must be re-verified against the *specific* assertion its test makes,
which is why this is 50 individual judgements rather than a sed script.

**Mandatory per fixture:** the non-vacuity check from Block 7 step 2. A fixture
rewritten to dodge a parse error is exactly the kind that starts passing for the wrong
reason.

**Commit granularity:** one commit per test file (8 commits), not one for all 50.

---

## 8. Appendix — full inventory

Re-derive: `grep -rnE '^[[:space:]]*\\\\.*_[[:space:]]*=' tests/*.zig`

| File | Count | Class | Notes |
|---|---|---|---|
| `tests/lint_warnings_test.zig` | 22 | A | Mostly `let p = &X; _ = p;` — pointer-to-binding warnings |
| `tests/lint_rules_test.zig` | 11 | A | Mostly `let x = u; _ = x;` laundering a binding use |
| `tests/validation_test.zig` | 6 | A | Includes `_ = u[0].a;` member-access forms |
| `tests/multi_visitor_dispatch_test.zig` | 3 | A | Includes `_ = big[0];` |
| `tests/inlay_hints_test.zig` | 3 | A | `_ = buf;` |
| `tests/code_action_test.zig` | 3 | A | `_ = x;` after a deliberate typo fixture |
| `tests/liveness_test.zig` | 1 | A | `_ = 1;` — literal RHS |
| `tests/reflect_test.zig` | 1 | **B** | `let _ = u.v + textureSampleLevel(…)` |
| **Total** | **50** | 49 A / 1 B | |
| `examples/c/lint.c` | 1 | **B** | `let _ = 3.14;` in the demo shader |
| `examples/c/lint_fix.c` | 1 | **B** | same |

---

## 9. Explicitly out of scope

| Item | Why |
|---|---|
| Dropping pure phony assignments in the minifier | A real optimization (`_ = 1;` has no effect) but a semantics decision of its own — and wrong for `_ = tex;`, whose entire purpose is the side effect on the layout. Decide separately. |
| Rewriting the 49 Class-A fixtures | Route A makes them valid as-is. Only audit them. |
| The `__`-prefix reserved path | Reachable and tested; not part of this bug. |
| Uniformity semantics of the phony RHS | Block 2 makes the walkers see the expression. Whether a phony assignment is a uniformity barrier is a spec question worth its own reading of §15. |
