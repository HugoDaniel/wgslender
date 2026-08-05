# plans/ — WGSLender embedding example plans

Independent, executable plans. Plans 1–3 each build a fully worked, fully **tested**
example of consuming WGSLender from another language, covering the three main parts
of the library: **minify**, **validate**, and **reflect**. Plan 4 goes further: a
publishable Rust cargo workspace (`packages/rust/`) covering the **entire** C ABI plus
compile-time embedding proc-macros.

| Plan | File | Target | Creates |
|------|------|--------|---------|
| 1 | [01-js-ts.md](01-js-ts.md) | JS/TS via the npm package (WASM) | `examples/js-ts/` |
| 2 | [02-rust.md](02-rust.md) | Rust via the C static library (FFI) — **superseded by plan 4 if 4 executes** | `examples/rust/` |
| 3 | [03-c.md](03-c.md) | C via `libwgslender.a` (examples already exist — plan hardens + tests them) | `examples/c/` test harness |
| 4 | [04-rust-package.md](04-rust-package.md) | Publishable Rust cargo workspace: full-ABI safe API + compile-time `include_wgsl!` / `include_wgsl_compressed!` / `wgsl_module!` proc-macros | `packages/rust/` |

**Plan 4 is executed** — all ten blocks, landed in `packages/rust/`, gate green
(`cd packages/rust && cargo xtask check`). Publishing to crates.io was explicitly
out of its scope; what stands in the way is written up in
[`packages/rust/README.md` § Publishing](../packages/rust/README.md#publishing).
Plan 2 is therefore superseded.

**Plan 3 is executed** — all five blocks, landed in `examples/c/`: a table-driven
smoke suite over all ten examples (`make -C examples/c test`) and a glibc
cross-compile check (`make -C examples/c lint-portability`).

**Plan 1 is the only embedding-example plan left.**

## Other plans (not part of the embedding-example set)

| Plan | File | Fixes |
|------|------|-------|
| 5 | [05-lsp-validation-integration.md](05-lsp-validation-integration.md) | Five gaps where LSP handlers (signature help, semantic tokens, completion, code actions) bypass validator-resolved data, plus general lint packs never surfacing over LSP |

## Suggested execution order

The plans are **independent** — any order works, one plan (or one block) per session.
Suggested order if executing all:

1. **03-c** first — cheapest, and it creates the automated test harness over the
   already-existing `examples/c/` suite, hardening the same `libwgslender.a` that
   the Rust plans link against.
2. **04-rust-package** — the real Rust deliverable (supersedes 02; see its
   "Relationship to plan 02" section). Execute 02 only if you deliberately want the
   small raw-FFI example *instead of* the package.
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
- `cd packages/js-npm && npm test` — **175 passed, 0 failed** in each of the 4 wrapper
  variants (node-cjs, node-esm, browser CJS shim, browser ESM shim).
- Library version: `1.1.0` (`src/root.zig:11`).
- There is **no** automated testing of `examples/c/` anywhere (verified exhaustively:
  no reference in `build.zig`, no Makefile `test` target, no script, no CI).
- There is **no** Rust binding anywhere; the entire Rust story is a 2-line `build.rs`
  snippet in `docs/C-API.md:18-22`.
