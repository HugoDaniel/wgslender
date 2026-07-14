# Deferred-work plans

Implementation plans for the four items the master-craft program (completed 2026-07-14) documented
as deliberately out of scope. Each plan is self-contained — written to be handed to a fresh
model/session with no other context — and was researched against the codebase at `main` @
`87b967c` (2026-07-14). **Line numbers rot: re-verify any `file:line` reference with a grep
before editing against it.**

| Plan | Size | Risk | Depends on |
|---|---|---|---|
| [consteval-extraction.md](consteval-extraction.md) — one shared const-expression evaluator (`src/ConstEval.zig`) replacing the three divergent ones | 3-4 blocks | low→medium | nothing |
| [reflect-split.md](reflect-split.md) — split the 3,571-LOC `src/Reflect.zig` along its three verified seams (JSON / call graph / layout) | 5 blocks | low | ConstEval C0-C1 |
| [validator-decomposition.md](validator-decomposition.md) — materialize the god-struct's field groups, extract type resolution, narrow the 68-alias layer | 5 blocks | low | ConstEval C0-C2 (soft) |
| [uniformity-dataflow-upgrade.md](uniformity-dataflow-upgrade.md) — replace the name-matching uniformity approximation with spec-§15 dataflow + call summaries | 5-6 blocks | medium-high | nothing |

**Recommended order:** ConstEval → Reflect split → Validator decomposition, with the Uniformity
track runnable in parallel at any point (it touches only `src/validator/Uniformity.zig`,
`src/Builtins.zig` rows, and fixtures). The first three form a chain because ConstEval's
extraction removes the interpreter from Reflect (~380 LOC) and the const-eval helpers from
Validator (~130 LOC) — running it first means those lines move once, not twice.

All four are **behavior-preserving refactors except where explicitly registered**: each plan
carries its own behavior-change register, and only the Uniformity plan (feature work by nature)
and ConstEval's optional Block C3 expand behavior.

## Shared house rules (summarized in each plan; canonical here)

- **Cadence:** one block per session/commit; conventional-commit messages matching `git log`;
  `⚠ BEHAVIOR` note in the commit body for any wire/wording/diagnostic change.
- **TDD reds-first.** New behavior: failing test first, confirm red, then green. Behavior-
  preserving moves: characterization pins, green before and after.
- **Full gate:** `zig build && zig build wasm && zig build lsp && zig build lsp-wasm &&
  zig build test`, test step run `-j1` (corpus suites are memory-heavy and flake concurrently).
  All four artifacts are first-class deliverables. Trust exit codes, not output grep — and if a
  gate runs in the background with a trailing `echo EXIT=$?`, read the redirected file and grep
  that sentinel; the task wrapper's own exit code is meaningless.
- **Corpus goldens** (`tests/inference/corpus_golden.txt`, `triage_golden.txt`): drift only with
  in-commit regeneration (`rm` both + `zig build test`) and a ⚠ explanation. A crashed corpus run
  writes nothing and therefore shows no diff — "no drift" is only proven by an exit-0 run.
  Triage worklists: `zig build tint-triage -- --code E0xxx --bucket fp`.
- **Fast red/green loops:** `zig test --dep wgslender -Mroot=tests/<file>.zig
  -Mwgslender=src/root.zig [--test-filter "..."]` for `tests/` files;
  `zig test src/<File>.zig` compiles the whole src graph for src-internal pins.
- **No CI.** Heavy suites stay local/on-demand; never add workflow YAML.
- **Ownership is never a bool** — express borrow-vs-own as named functions or enums.
- **npm mirrors are generated**, not hand-synced: wire or pack changes → `zig build gen-npm` and
  commit the regenerated files (a freshness test byte-compares them).
- When a plan's assumptions about *current* code state matter, **verify the starting state via
  git/grep before executing a step** — plans go stale in both directions (the master-craft
  program twice found its assumed starting state already half-landed).
