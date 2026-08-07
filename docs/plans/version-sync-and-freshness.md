# Plan — one version, no stale artifacts

**Creates:** a single canonical version constant that every package is stamped from
or reads through, a `zig build release-assets` step that writes every WASM copy from
one build, in-suite drift gates for both, and a `scripts/release.sh` that makes
"rebuilding changed nothing" the release check.

**Motivation:** the repo ships six version-bearing artifacts across four languages and
they are already out of sync (`packages/rust` and `npm/wgslender-vscode` at `0.1.0`,
everything else at `1.1.0`), and one committed WASM binary is stale *right now*
(`npm/wgslender-lsp/wgslender-lsp.wasm`, verified below) because nothing in the build
graph ever writes to that directory. Both failures are silent: a drifted version
misleads consumers, and a drifted WASM does not crash — it answers questions using
the old wire format.

**Status:** ready to execute. That is an intention, not evidence — check
`git log --oneline -- docs/plans/version-sync-and-freshness.md scripts/release.sh tools/gen_version.zig`
before assuming any block has landed.

**Constraint:** no CI. Every gate here is a local command or a test inside
`zig build test`. Nothing in this plan produces a workflow file.

---

## Decisions taken (2026-08-07)

Two questions were answered before writing; the blocks below assume both.

1. **Every package joins the shared version line, VS Code included.** No exceptions
   to remember. `packages/rust` (4 crates) and `npm/wgslender-vscode` both jump
   `0.1.0 → 1.1.0`. See the behavior-change register — the Rust jump is a semver
   promise, not a formality.
2. **The gate is `scripts/release.sh`**, sitting beside `fetch-tint-testdata.sh` and
   `mirror.sh`. It orchestrates the Zig build steps *and* the three foreign test
   suites (`go test`, `cargo xtask check`, `npm test`), which a `build.zig` step
   cannot reach cleanly.

---

## Verified current state (do not re-derive)

Measured against `main @ 7fe9827`, 2026-08-07, macOS arm64, Zig 0.16.0.
**Line numbers rot — re-verify every `file:line` with a grep before editing against it.**

### The release surface

| Artifact | Version | Where the version lives | Binary artifact | Freshness gate today |
|---|---|---|---|---|
| Zig core | 1.1.0 | `build.zig.zon:3` (`.version`) | — | — |
| Zig core | 1.1.0 | `src/root.zig:11` (`pub const version`) | — | — |
| LSP server info (native) | 1.1.0 | `lsp/native/lifecycle.zig:9` — **hardcoded literal** | — | none |
| LSP server info (wasm) | 1.1.0 | `lsp/wasm/lifecycle.zig:44` — **hardcoded literal**, inside a `++` concat | — | none |
| `packages/js-npm` | 1.1.0 | `package.json:3` | `wgslender.wasm` committed | none |
| `packages/go` | *(git tag)* | reads it out of the WASM at runtime | own copy of `wgslender.wasm` | **two tests** |
| `packages/rust` | **0.1.0** | `packages/rust/Cargo.toml:6` + three pins at `:22-24` | builds `libwgslender.a` from source (`build.rs`) | cannot go stale by construction |
| `npm/wgslender-lsp` | 1.1.0 | `package.json:3` | `wgslender-lsp.wasm` committed | **none — and it is stale** |
| `npm/wgslender-vscode` | **0.1.0** | `package.json:5` | `dist/*.wasm` | fed by `zig build vscode-assets` |

Six version *sites* (`build.zig.zon`, `src/root.zig`, two LSP literals, and four
manifests — counting the Rust workspace's four as one stamp target). Go has no
version file: it reports whatever the embedded WASM says, which is the right design
and needs nothing from the generator.

### Finding 1 — both WASM builds are byte-reproducible from a cold cache

This is the load-bearing fact for the whole plan. Rebuilt into a scratch cache dir
with a clean prefix (`zig build wasm lsp-wasm --cache-dir <scratch>/zc --prefix
<scratch>/out`), so no warm-cache artifact could be echoed back:

```
1450c06587db5d8e6ba5f26ca2359cc2a8b875b8b7d96e57f9a7191cbe3289b0  wgslender.wasm
434417729cf34cf3898c8caaaa577d4792d6579db5e03f6be37dfc085f826c1a  wgslender-lsp.wasm
```

`wgslender.wasm` at `1450c065…` is **byte-identical to the copy committed in
`9a8debb`**. Both `packages/js-npm/wgslender.wasm` and
`packages/go/internal/wasmabi/wgslender.wasm` carry that hash and are current.

Reproducibility is what makes Block 5's `git diff --exit-code` a gate rather than a
nuisance: if the build were nondeterministic, "the tree moved after a rebuild" would
fire on every run and be trained away within a week.

### Finding 2 — `npm/wgslender-lsp/wgslender-lsp.wasm` is stale

Committed at `20806fa` ("chore: sync version to 1.1.0 across all release artifacts");
a fresh build produces `434417…` against the committed `721e80a…`. The cause is
structural, not a missed step: **nothing in `build.zig` writes to
`npm/wgslender-lsp/`**, and `npm/wgslender-lsp/package.json` has no `scripts` key at
all. The `vscode-assets` step (`build.zig:339-348`) copies both WASM files, but only
into `npm/wgslender-vscode/dist/` — which is why the VS Code copy is current and this
one is not.

Everything merged into the LSP WASM since `20806fa` (2026-05-06) is therefore absent
from the published `wgslender-lsp` package: **137 commits** touching `lsp/` or `src/`.
Wire-visible among them — a new `wgslender/constInventory` request (`8c6a49e`),
semantic-token lengths corrected to UTF-16 code units (`41f8e7f`), semantic tokens
resolved via `NodeAtOffset` (`1cd61b7`), signature help backed by real signatures
(`aa017d5`), diagnostics carrying every configured lint pack (`b4a902b`), one per-file
lint result object (`98faf37`), control bytes escaped in diagnostic JSON (`2ee6844`),
and the new `E0700`–`E0703` uniformity codes. That is the failure mode the
drifted-copy problem produces.

*(Corrected during execution: an earlier draft named `8cd45d0`, the structured
`QuickFixHint` payload, as being in this window. It is not — it landed 2026-05-05,
one day before `20806fa`.)*

### Finding 3 — `prepublishOnly`'s optimize flag is a no-op

`packages/js-npm/package.json` runs
`zig build wasm -Doptimize=ReleaseSafe && cp zig-out/bin/wgslender.wasm …`, but
`build.zig:58` hardcodes `.optimize = .ReleaseSmall` on the WASM module, so
`-Doptimize` never reaches it. Harmless today — and the hardcoding is part of why
Finding 1 holds — but it reads like it controls something, and someone will
eventually "fix" it by threading `optimize` through and silently change what ships.

### Dependencies

| Package | Runtime deps | State |
|---|---|---|
| `packages/js-npm` | **none** | nothing to rot |
| `packages/go` | `wazero v1.12.0`, `golang.org/x/sys v0.44.0` | **x/sys behind (v0.47.0 available)** |
| `packages/rust` | serde, serde_json, thiserror, proc-macro2, quote, syn, miniz_oxide, proptest (dev) | not audited here |
| `npm/wgslender-vscode` | devDeps only | **well behind** — `esbuild ^0.20`, `@vscode/vsce ^2.24` |
| `external/lsp-kit` | vendored path dep, `.lazy = true` | pinned by vendoring |

`examples/js-ts` and `npm/wgslender-vscode` both depend on the packages by `file:`
reference, not by version range — so nothing there needs stamping.

### Finding 4 — the repo has no git tags at all

`git tag` is empty. `packages/go`'s module path is
`git.hugodaniel.com/hugo/wgslender/packages/go`, so Go consumers can currently only
`go get` a pseudo-version. Block 6 fixes the scheme, not just the sync.

### Two precedents to copy rather than invent

- **`gen-npm`** (`tools/gen_npm.zig` → `packages/js-npm/configs.{js,d.ts}`, gated by
  `tests/npm_generated_test.zig`) is this repo's established shape for "generated file
  that can never be stale": generate in-process, byte-compare against the committed
  file, fail with *"run `zig build gen-npm` and commit the result"*. Block 2 copies the
  UX; see its note on where it deliberately diverges.
- **`packages/go/wgslender/wgslender_test.go`** already has both halves of the WASM
  gate: `TestVersion` pins the version reported *by the embedded WASM* against
  `src/root.zig`, and `TestWasmMatchesNpm` sha-compares its copy against
  `packages/js-npm/wgslender.wasm`. Both skip cleanly when the sibling file is absent,
  so the module still builds if extracted. Block 4 generalizes this, it does not
  replace it.

---

## Behavior-change register

Every item here is user-visible and belongs in the commit body with a `⚠ BEHAVIOR`
note, and in `CHANGELOG.md`.

1. **`packages/rust` 0.1.0 → 1.1.0.** A `1.x` version number is a public promise of
   API stability under semver. The crate is unpublished (crates.io publishing is still
   a deferred decision — `packages/rust/README.md § Publishing`), so nothing breaks
   today, but the first published version being `1.1.0` means breaking changes after
   it require `2.0.0`. This was chosen deliberately over letting Rust float; if that
   promise is not wanted, the decision to revisit is *this line*, not the mechanism.
2. **`npm/wgslender-vscode` 0.1.0 → 1.1.0.** The extension's marketplace version
   jumps, and from here it moves with core releases whether or not the extension
   changed.
3. **`npm/wgslender-lsp/wgslender-lsp.wasm` content changes** (Block 3). This is a
   fix, but it is not a no-op: consumers of that package get every LSP change since
   `20806fa` at once, including `8cd45d0`'s `QuickFixHint` wire shape. If
   `npm/wgslender-lsp` has ever been published, this warrants its own changelog entry
   describing what moved, not just "refresh WASM".
4. **LSP `serverInfo.version` becomes derived** (Block 1). No observable change now —
   both literals already read `1.1.0` — but from here the LSP reports the core version
   automatically instead of whatever was last hand-edited. The parity tests that assert
   on `initialize` responses must keep passing byte-for-byte; if any of them hardcode
   `"1.1.0"`, that is the assertion to update, and it is the point of the change.

---

## House rules

- **One block per session/commit.** Conventional-commit messages matching `git log`.
- **TDD reds-first.** Failing test first, confirm red, then green. For the drift gates
  this is easy and worth doing literally: write the test, watch it fail against the
  current out-of-sync tree, *then* stamp.
- **Full gate:** `zig build && zig build wasm && zig build lsp && zig build lsp-wasm &&
  zig build test`, with the test step run `-j1` (the corpus suites are memory-heavy and
  flake concurrently). All four artifacts are first-class deliverables.
- **Trust exit codes, not output grep.** If the gate runs in the background with a
  trailing `echo EXIT=$?`, read the redirected file and grep that sentinel — the task
  wrapper's own exit code is meaningless.
- **Corpus goldens** (`tests/inference/corpus_golden.txt`, `triage_golden.txt`) must
  not drift. Nothing in this plan should touch them; if one moves, stop and find out
  why. A crashed corpus run writes nothing and so shows no diff — "no drift" is only
  proven by an exit-0 run.

---

## Block 1 — read-through: delete the two version literals you can

**Why first:** it is the only block that *removes* sites rather than synchronizing
them, and it shrinks what Block 2's generator has to own from six to four. Sites that
do not exist cannot drift.

**The wasm side is nearly free.** `lsp/wasm/lifecycle.zig` already imports the
`wgslender` module (`lsp/wasm/lifecycle.zig:8`), so its literal at `:44` becomes a
comptime concat with no `build.zig` change:

```zig
ctx.sendResult(id, "{\"capabilities\":" ++ Handler.capabilities_json ++
    ",\"serverInfo\":{\"name\":\"wgslender-lsp\",\"version\":\"" ++ wgslender.version ++ "\"}}");
```

**The native side needs one build wiring line.** `native_lifecycle_mod`
(`build.zig:166-173`) imports only `lsp`. Add `.{ .name = "wgslender", .module =
wgslender_mod }` to its `.imports`, then `lsp/native/lifecycle.zig:9` becomes
`.version = wgslender.version`.

**Steps**

1. **Red:** add a test asserting both transports report `wgslender.version` in
   `serverInfo` — for wasm, that the emitted `initialize` result JSON contains it; for
   native, that `native_lifecycle.server_info.version` equals it. With the literals in
   place this passes trivially (both are `1.1.0`), so make it a real red by
   temporarily bumping `src/root.zig`'s constant and confirming both fail. Revert the
   bump.
2. Wire `wgslender` into `native_lifecycle_mod`; replace both literals.
3. Grep for surviving hardcoded `"1.1.0"` under `lsp/` and in the LSP parity tests —
   `tests/lsp_*` assert on `initialize` responses and may pin the string.
4. Full gate. `zig build lsp-wasm` must still produce a WASM; confirm the emitted
   `initialize` bytes are unchanged (they should be — same string, different origin).

**Done when** `grep -rn '"1\.1\.0"' lsp/` is empty and the gate is green.

---

## Block 2 — `zig build gen-version` and its drift test

**Scope:** the four remaining stamp targets.

| Target | Site | Shape |
|---|---|---|
| `build.zig.zon` | `.version = "1.1.0",` | ZON field |
| `packages/js-npm/package.json` | `"version": "1.1.0",` | JSON field |
| `npm/wgslender-lsp/package.json` | `"version": "1.1.0",` | JSON field |
| `npm/wgslender-vscode/package.json` | `"version": "0.1.0",` | JSON field |
| `packages/rust/Cargo.toml` | `version = "0.1.0"` at `:6`, plus three `version = "0.1.0"` pins at `:22-24` | TOML — **four occurrences, all must move together** |

Canonical source: `src/root.zig`'s `pub const version`. It is already what
`packages/go` pins against and what the C ABI's `wgslender_version_c`
(`include/wgslender.h:312`) returns, so it is the version every consumer can already
observe at runtime. Do not introduce a new canonical file.

**Deliberate divergence from `gen-npm`.** `gen-npm` owns its output files entirely and
byte-compares. A version stamper must not own `package.json` or `Cargo.toml` — those
are hand-maintained. So:

- **The generator does a targeted field rewrite**, not a whole-file emit. Locate the
  version assignment, replace the string, write the file back otherwise byte-identical.
- **The test compares fields, not bytes**: read each manifest, extract its version,
  assert it equals `root.zig`'s. Failure message keeps the `gen-npm` UX — *"version
  drift: run `zig build gen-version` and commit the result"*.

Keep the field extraction strict and fail loudly on a miss. A stamper that silently
matches nothing is worse than no stamper: it reports success, the test then fails, and
the two disagree about who is broken. If a manifest's version line cannot be located,
that is a hard error naming the file.

**The `Cargo.toml` pins are the trap.** `packages/rust/Cargo.toml:22-24` pin the three
member crates by `version = "0.1.0"` alongside their `path`. Cargo requires the pin to
match the member's actual version at publish time. Stamping `:6` and leaving `:22-24`
produces a workspace that builds fine locally (path wins) and fails only at `cargo
publish`. Stamp all four, and have the test assert all four.

**Steps**

1. **Red:** write `tests/version_sync_test.zig` asserting all four manifests match
   `root.zig`. It fails immediately on the real tree — Rust and VS Code are at `0.1.0`.
   Confirm the red names both.
2. Write `tools/gen_version.zig`. Read `src/root.zig`, extract `pub const version`,
   rewrite the five locations (four files, seven occurrences counting Cargo's four).
   Follow `tools/gen_npm.zig:124-133` for the `std.process.Init` / `Io.Dir.cwd()`
   shape.
3. Register the step in `build.zig` beside `gen-npm` (`build.zig:556-574`): create the
   module, `addExecutable`, `addRunArtifact`, `setCwd(b.path("."))`, `b.step("gen-version", …)`.
4. Register the test with `addTestStep`. Note the `@embedFile`-can't-escape-the-package
   gotcha documented in `tests/npm_generated_test.zig:10-12` — read the manifests at
   runtime relative to the build cwd, exactly as that test does.
5. Run `zig build gen-version`. Rust and VS Code move to `1.1.0`. Green.
6. Full gate, plus `cd packages/rust && cargo xtask check` — the version bump touches
   all four crates and their inter-pins.

**Done when** the test is green, and hand-editing any one manifest to `9.9.9` turns it
red with the run-`gen-version` hint. Verify that last part by actually doing it.

---

## Block 3 — `release-assets`: every WASM copy from one build

Fixes Finding 2 and makes it structurally unable to recur.

**Current state:** `vscode-assets` (`build.zig:338-348`) copies both WASM files into
`npm/wgslender-vscode/dist/`. Three other destinations are fed by hand:
`packages/js-npm/wgslender.wasm` (by `prepublishOnly`),
`packages/go/internal/wasmabi/wgslender.wasm` (by nothing), and
`npm/wgslender-lsp/wgslender-lsp.wasm` (by nothing — hence stale).

**Change:** rename to `release-assets` and add the three missing `addInstallFile`
calls. Keep `vscode-assets` as an alias depending on the same steps so any existing
muscle memory or doc reference keeps working.

Destinations after this block:

```
zig build release-assets
  wgslender.wasm      -> packages/js-npm/wgslender.wasm
                      -> packages/go/internal/wasmabi/wgslender.wasm
                      -> npm/wgslender-vscode/dist/wgslender.wasm
  wgslender-lsp.wasm  -> npm/wgslender-lsp/wgslender-lsp.wasm
                      -> npm/wgslender-vscode/dist/wgslender-lsp.wasm
```

`packages/go` keeps its own copy because `go:embed` cannot reach outside the module —
already documented at `packages/go/internal/wasmabi/abi.go:25-28`. That copy is
unavoidable; what changes is that a build step writes it instead of a person.

**Also in this block:** fix Finding 3. Either drop `-Doptimize=ReleaseSafe` from
`packages/js-npm/package.json`'s `prepublishOnly` (accurate — `build.zig:58` hardcodes
`ReleaseSmall`), or better, replace the whole script with `cd ../.. && zig build wasm
release-assets` so the npm package stops carrying its own copy instruction. Prefer the
second: it deletes a second place that knows where the WASM goes.

**Steps**

1. Extend the step in `build.zig`; keep the `vscode-assets` alias.
2. Run `zig build wasm lsp-wasm release-assets`. Expect exactly one file to change:
   `npm/wgslender-lsp/wgslender-lsp.wasm`, `721e80a… → 434417…`. If any *other* copy
   moves, stop — that means a second artifact was stale too, and it needs its own
   register entry.
3. Update `prepublishOnly`.
4. Full gate + `cd packages/go && go test ./...` (its two WASM tests are the ones most
   likely to notice) + `cd npm/wgslender-lsp && node -e "…"` smoke, or whatever
   exercises that package.
5. Commit with a `⚠ BEHAVIOR` body covering register item 3 — say what landed in the
   LSP WASM since `20806fa`, do not write "refresh WASM".

**Done when** `zig build release-assets && git diff --exit-code` is clean on a
second run.

---

## Block 4 — the in-suite WASM freshness gate, and its honest limits

**State the limit first, in the test file's doc comment, or this block does harm.**
A committed binary cannot be proven fresh by anything committed alongside it — a hash
pinned in the same commit is circular. Only a rebuild proves freshness, and that lives
in Block 5. What belongs in `zig build test` are two cheap approximations:

- **(a) copy-equality** — all copies of a given WASM are byte-identical to each other.
  Catches the drift in Finding 2 (one copy refreshed, another not), which is the
  failure that actually happened.
- **(b) version pin** — the version string reported by the WASM equals
  `src/root.zig`'s. Catches a WASM left behind across a release, but not one left
  behind *within* a version.

`packages/go` already implements both for `wgslender.wasm`
(`packages/go/wgslender/wgslender_test.go:29-58` and `:67+`). Generalize rather than
duplicate:

1. Extend the Go sha comparison to cover all three `wgslender.wasm` copies, not just
   the npm one.
2. Add the equivalent for `wgslender-lsp.wasm` across its two destinations. There is no
   Go consumer of the LSP WASM, so this one belongs in `zig build test` as a Zig test
   reading both files at runtime — same cwd-relative pattern as Block 2, same
   skip-if-absent courtesy as the Go tests.

The failure message must name the fix: *"WASM copies differ — run `zig build wasm
lsp-wasm release-assets` and commit the result"*.

**Do not** add a hash constant to the test. It would need updating on every WASM
rebuild, which is exactly the manual step this plan exists to delete, and a constant
that is updated reflexively stops being a gate.

---

## Block 5 — `scripts/release.sh`

The real freshness gate, and the one command a release runs.

Follow the conventions in `scripts/fetch-tint-testdata.sh:1-14`: `#!/usr/bin/env bash`,
a usage comment block, `set -euo pipefail`, `ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"`.

```
./scripts/release.sh [--check]

  1. zig build gen-version gen-npm        stamp + regenerate
  2. zig build wasm lsp-wasm release-assets   rebuild, copy everywhere
  3. zig build && zig build lsp            all four artifacts
  4. zig build test -j1                    the Zig suite
  5. (cd packages/go   && go test ./...)
  6. (cd packages/rust && cargo xtask check)
  7. (cd packages/js-npm && npm test)
  8. dependency freshness report           report only, never auto-update
  9. git diff --exit-code                  THE GATE
```

**Step 9 is the whole point.** Because both WASM builds reproduce byte-for-byte
(Finding 1) and steps 1-2 rewrite every generated and copied file, a dirty tree after
this script *is* the staleness error. It needs no hashes, no pins, and no maintenance:
anything the build can regenerate is covered automatically, including files added
years from now. Print the `git status --short` output on failure with a one-line
explanation — "these were regenerated and differ from what is committed; review and
commit them" — because the bare `--exit-code` failure is otherwise inscrutable.

`--check` runs everything and reports without leaving the tree modified (stash or
`git checkout` the regenerated files at the end), for use as a pre-release smoke test.

**Step 8 reports, it does not update.** `go list -m -u all`, `cargo update --dry-run`
(or `cargo outdated` if installed — degrade gracefully when it is not), and `npm
outdated` in `npm/wgslender-vscode`. Auto-bumping dependencies inside a release is how
an unrelated surprise ships in a patch release. The report tells you; you decide, in a
separate commit, before you release.

**Ordering matters.** Stamp and regenerate (1-2) *before* testing (3-7), so the suite
runs against what will actually ship rather than against the pre-stamp tree. Then step
9 confirms the tested tree is the committed tree.

**Steps**

1. Write the script. Get it green on the current tree first *without* step 9, so
   failures are attributable.
2. Add step 9. Confirm it fires: touch `packages/js-npm/wgslender.wasm`, rerun, see it
   fail with a readable message. Restore.
3. Confirm the clean case: run twice in a row; the second run must be green with an
   untouched tree.

**Done when** two consecutive runs are green and a deliberately corrupted artifact
produces a message that names the fix.

---

## Block 6 — tags, dependency bumps, and documentation

**Tag scheme.** The repo has no tags at all (Finding 4). Go requires the module's
subdirectory as the tag prefix, so a release needs two tags:

```
v1.1.0                  the repo / Zig / npm / crates release
packages/go/v1.1.0      what `go get git.hugodaniel.com/hugo/wgslender/packages/go@v1.1.0` resolves
```

Both point at the same commit. `scripts/release.sh` should *print* the two `git tag`
commands rather than run them — tagging is the irreversible step and belongs to a
human hand. Record the scheme in `CONTRIBUTING.md`; without it the `packages/go/`
prefix is non-obvious and will be forgotten exactly once, permanently, since tags are
awkward to move after publication.

**Dependency bumps**, each its own commit, before the release, never inside it:

- `packages/go`: `golang.org/x/sys v0.44.0 → v0.47.0` (`go get -u ./... && go mod
  tidy`, then `go test ./...`).
- `npm/wgslender-vscode`: `esbuild ^0.20` and `@vscode/vsce ^2.24` are both well
  behind. Bump, rebuild the extension, and confirm `dist/` still assembles.
- `packages/rust`: `cargo update` within the existing ranges, then `cargo xtask check`.

**Documentation.** A "Releasing" section in `CONTRIBUTING.md`: bump `src/root.zig`,
run `./scripts/release.sh`, review the diff, commit, tag twice, publish. Add the same
three lines to `CLAUDE.md` under Quick Commands, since that is where the next session
will look. Cut `CHANGELOG.md`'s `## [Unreleased]` into a versioned section as part of
the bump — optionally have `release.sh` warn when `[Unreleased]` is empty, which is
usually the sign that a release is being cut without notes.

---

## What this leaves manual, on purpose

- **Choosing the version number.** Editing `src/root.zig` is the one deliberate act;
  everything else follows from it. Automating the semver decision would mean inferring
  intent from commit messages, which is a second thing to maintain and get wrong.
- **Tagging and publishing.** Irreversible and outward-facing. The script prints the
  commands.
- **Accepting dependency updates.** Reported, never applied.

Everything else — stamping five files, rebuilding two binaries into five destinations,
regenerating the npm config mirrors, and proving all of it consistent — is one command
and no ongoing maintenance.

---

## Risk register

| Risk | Mitigation |
|---|---|
| `gen_version` silently matches nothing in a manifest and reports success | Hard error naming the file when the version line is not located; the field test is the second line of defence |
| Cargo's three inter-crate pins stamped inconsistently → fails only at `cargo publish` | Stamp all four occurrences; assert all four in the test; run `cargo xtask check` in Block 2 |
| A future Zig upgrade breaks WASM byte-reproducibility, making step 9 fire spuriously | Re-run the cold-cache check in Finding 1 after any Zig bump. If it stops holding, step 9 must narrow to the generated text files and Block 4's copy-equality becomes the only WASM gate |
| Rust's `1.1.0` implies API stability the crate is not ready for | Registered as behavior change 1 — a decision to revisit before the first `cargo publish`, not after |
| `npm/wgslender-lsp` consumers get a large WASM jump in one release | Behavior change 3 — changelog the wire-shape change (`8cd45d0`) explicitly |
