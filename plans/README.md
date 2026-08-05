# plans/ — WGSLender embedding example plans

Three independent, executable plans. Each one builds a fully worked, fully **tested**
example of consuming WGSLender from another language, covering the three main parts
of the library: **minify**, **validate**, and **reflect**.

| Plan | File | Target | Creates |
|------|------|--------|---------|
| 1 | [01-js-ts.md](01-js-ts.md) | JS/TS via the npm package (WASM) | `examples/js-ts/` |
| 2 | [02-rust.md](02-rust.md) | Rust via the C static library (FFI) | `examples/rust/` |
| 3 | [03-c.md](03-c.md) | C via `libwgslender.a` (examples already exist — plan hardens + tests them) | `examples/c/` test harness |

## Suggested execution order

The plans are **independent** — any order works, one plan (or one block) per session.
Suggested order if executing all three:

1. **03-c** first — cheapest, and it creates the automated test harness over the
   already-existing `examples/c/` suite, hardening the same `libwgslender.a` that
   plan 02 links against.
2. **02-rust** — links the same static archive; reuses the fixtures/oracle patterns.
3. **01-js-ts** — fully independent (npm package + committed WASM artifact).

## Conventions shared by all three plans (read once, they are restated per plan)

- **Blocks are self-contained context blocks.** Each block restates the facts it
  needs (paths, API shapes, commands) so an executor can pick up any single block
  after compaction without the rest of the plan in context. Execute block-per-session
  when context is tight.
- **TDD, reds first.** Every block writes the failing test/harness first, runs it,
  *confirms the red* (the plan states the exact expected failure), then implements
  to green. Tests are table/fixture-driven so new cases are one row, not new code.
- **No CI.** All test entry points are local, on-demand commands (`npm test`,
  `cargo test`, `make test`). Do **not** create workflow YAML.
- **Commit per block**, conventional style, atomic (e.g. `feat(examples): …`,
  `test(examples): …`, `docs: …`). Never include unrelated working-tree changes
  (at plan-writing time `web/src/content/docs/index.mdx` was already modified —
  leave it alone).
- **Behavior changes are called out, never smuggled.** Each plan has an explicit
  "Behavior changes" section. Anything touching wire formats, public API surface,
  or `.d.ts` types is listed there; if a block's step would change behavior, the
  block says so in bold.
- **Numeric expectations are pinned against an oracle.** Where a test asserts exact
  reflect layout numbers (sizes/offsets/alignments), the plan instructs deriving
  them once from the native CLI (`./zig-out/bin/wgslender reflect <file>`) and
  pinning the observed values — never guessing them.

## Verified baseline (2026-08-05, main @ `017cb1d`, macOS arm64)

All three plans were written against this verified state — re-verify only if HEAD
has moved significantly:

- Toolchain: zig `0.16.0`, node `v26.6.0` / npm `11.18.0`, rustc+cargo `1.92.0`, Apple clang 21.
- `zig build lib` → `zig-out/lib/libwgslender.a` + `zig-out/include/wgslender.h` — works.
- `make -C examples/c` builds all 10 C examples; `./minify`, `./validate`, `./reflect`
  run correctly (only a harmless `ld` macOS-version warning).
- `cd npm/wgslender && npm test` — **175 passed, 0 failed** in each of the 4 wrapper
  variants (node-cjs, node-esm, browser CJS shim, browser ESM shim).
- Library version: `1.1.0` (`src/root.zig:11`).
- There is **no** automated testing of `examples/c/` anywhere (verified exhaustively:
  no reference in `build.zig`, no Makefile `test` target, no script, no CI).
- There is **no** Rust binding anywhere; the entire Rust story is a 2-line `build.rs`
  snippet in `docs/C-API.md:18-22`.
