# Release lanes — where each gate runs

`scripts/release.sh` gates every lane it knows about, but two of them —
the Rust packaging path and the VS Code extension's Electron suite —
need toolchains this project does not vendor. Which lanes actually ran
is therefore a property of the machine a release is cut on, and the
record below says which machine that was. Do not assume a lane ran
because a report or CI log is silent about it.

## Hosts

| Host | OS | Toolchains |
|------|----|------------|
| `obs-dev` | OpenBSD 7.9 | `zig` 0.16.0 (the only Zig on the network), `go`, `npm` |
| `ai-linux` | Debian (Linux 6.12) | `node` 26 / `npm` 11, no `cargo`, no `zig` |
| `PEGO-HUGO` | macOS (arm64) | `zig` 0.16.0 (zigup), `node` 26 / `npm` 11, `cargo` 1.92.0, `go` 1.27.4, `deno` 2.9.8 |

All Zig lanes run on `obs-dev` through the `obs` wrapper with
`ulimit -c 0`; Node lanes run on `ai-linux`.

## Lanes verified (phase-05 Task 6, tree at `a5ee8c6`, 2026-11-15)

| Lane | Host | Result |
|------|------|--------|
| `zig build test -j1` | `obs-dev` | 361/361 steps, 4795/4795 tests |
| `zig build`, `zig build lsp` | `obs-dev` | exit 0 |
| `zig build -Dlsp=false`, `zig build wasm -Dlsp=false`, `zig build lib -Dlsp=false`, `zig build lsp-wasm -Dlsp=false` | `obs-dev` | exit 0; fresh `ZIG_GLOBAL_CACHE_DIR` probe resolved neither `lsp_kit` nor SJON and materialized nothing. The flag is load-bearing: `zig build lib` and `zig build lsp-wasm` **without** it configure the native graph and do resolve both lazy dependencies, so only the flagged form is the project-free proof |
| `zig build release-assets -Dlsp=false` | `obs-dev` | exit 0; committed asset copies reproduced byte-for-byte |
| Tarball boundary (`wasm`/`lib`/`lsp-wasm`, no `../SJON`, empty SJON cache, network blackholed) | `obs-dev` | exit 0 ×3, zero SJON fetches, `zig-pkg/` never created |
| Native tarball (`zig build`, `zig build lsp`; offline second build) | `obs-dev` | SJON resolved once by URL+hash into `zig-pkg/`; offline reruns exit 0 |
| `SKIP_FOREIGN=1 ./scripts/release.sh --check` | `obs-dev` | exit 0, tree clean afterwards |
| pngine parity (`zig build test-wgslender-assembly-parity -Dinercia=../inercia-2026` from `../pngine`) | `obs-dev` | exit 0, 7 corpus roots compared |
| `npm test` in `npm/wgslender-lsp` | `ai-linux` | 42 passed, 0 failed |
| `npm test` in `packages/js-npm` (single-source API stays project-free) | `ai-linux` | 226 passed, 0 failed |
| `npm run test:unit` in `npm/wgslender-vscode` (node runner, no Electron) | `ai-linux` | 7 passed, 0 failed |

## Lanes verified (release 1.6.0, tree at `976f0da`, 2026-11-15)

First host where every lane ran: `PEGO-HUGO` is the first release machine
with `cargo`, and the only one able to launch the VS Code Electron suite.

| Lane | Result |
|------|--------|
| `zig build test -j1` | all 385 steps green — including the exhaustive submodule suites, which the phase-05 hosts never ran (no submodule checkout) |
| `zig build`, `zig build lsp`, `release-assets -Dlsp=false` | exit 0; committed WASM copies reproduced byte-for-byte |
| Go package (`go test ./...`) | ok ×3 |
| Rust packaging (`cargo xtask check`, `cargo xtask package`) | all green; the vendored-tarball proof caught a real gap on its first outing — `tests/pngine_project_free_check.zig` was missing from the vendored set (`46d2b64`) |
| `npm test` in `packages/js-npm` | 226 passed × 4 runners (cjs/esm/browser-cjs/browser-esm), 0 failed |
| `npm test` in `npm/wgslender-lsp` | 42 passed, 0 failed |
| `npm test` in `npm/wgslender-vscode` (Electron) | 46 passing, exit 0 |
| Full `./scripts/release.sh` | exit 0, tree clean afterwards — no `SKIP_FOREIGN` |

Two latent failures surfaced here, both fixed in this release: the
exhaustive submodule's corpus test violated `reparse`'s moved-from
precondition once the any-delta trivia shortcut started taking the hot path
(fixed in the submodule at `c3bc558`), and the trivia gate's speculative
allocations tripped the anchor path's compaction watermark, forcing a full
reparse after every large insert (`cfbb363`). The structural lesson: a host
without `tests/exhaustive` checked out silently runs a narrower gate — the
release gate is only as wide as the checkout.

## What the project-free artefacts contain

Both shipped WASM modules contain no SJON code and no `sjon` strings, but each
does carry the literal `pngine.enabled`: that is the LSP settings-schema key
generated from the shared option-spec table (`src/options.zig`), not project
functionality. The wasm LSP cannot act on it — it advertises no project
capability and has no store — so the key is inert there. If a stricter boundary
is ever wanted, the spec row has to become graph-specific, which trades schema
uniformity for the guarantee; that trade has not been made.

## Lanes NOT run here

| Lane | Why not | Command tried |
|------|---------|---------------|
| Rust packaging (`cargo xtask check`, `cargo xtask package`) | `cargo` exists on neither host | `command -v cargo` on both → not found |
| VS Code extension Mocha suite (Electron) | VS Code 1.146.0 downloaded and launched, but Electron fails to start on this host: `libnspr4.so: cannot open shared object file` (exit 127), and the agent user has no root to install the required system libraries | `(cd npm/wgslender-vscode && npm test)` |
| Go package (`go test ./...` in `packages/go`) | present on `obs-dev` but skipped: the release gate was run as `SKIP_FOREIGN=1` per the phase-05 gate list | — |

Before publishing a release from a machine that has `cargo` (and, for
the vendored-package proof, the ability to run Electron), run the full
`./scripts/release.sh --check` there — the script itself is the gate;
this file is only the record of what has already run where.
