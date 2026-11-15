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

All Zig lanes run on `obs-dev` through the `obs` wrapper with
`ulimit -c 0`; Node lanes run on `ai-linux`.

## Lanes verified (phase-05 Task 6, tree at `a5ee8c6`, 2026-11-15)

| Lane | Host | Result |
|------|------|--------|
| `zig build test -j1` | `obs-dev` | 361/361 steps, 4795/4795 tests |
| `zig build`, `zig build lsp` | `obs-dev` | exit 0 |
| `zig build -Dlsp=false`, `zig build wasm -Dlsp=false`, `zig build lib`, `zig build lsp-wasm` | `obs-dev` | exit 0; fresh `ZIG_GLOBAL_CACHE_DIR` probe resolved neither `lsp_kit` nor SJON and materialized nothing |
| `zig build release-assets -Dlsp=false` | `obs-dev` | exit 0; committed asset copies reproduced byte-for-byte |
| Tarball boundary (`wasm`/`lib`/`lsp-wasm`, no `../SJON`, empty SJON cache, network blackholed) | `obs-dev` | exit 0 ×3, zero SJON fetches, `zig-pkg/` never created |
| Native tarball (`zig build`, `zig build lsp`; offline second build) | `obs-dev` | SJON resolved once by URL+hash into `zig-pkg/`; offline reruns exit 0 |
| `SKIP_FOREIGN=1 ./scripts/release.sh --check` | `obs-dev` | exit 0, tree clean afterwards |
| pngine parity (`zig build test-wgslender-assembly-parity -Dinercia=../inercia-2026` from `../pngine`) | `obs-dev` | exit 0, 7 corpus roots compared |
| `npm test` in `npm/wgslender-lsp` | `ai-linux` | 42 passed, 0 failed |
| `npm test` in `packages/js-npm` (single-source API stays project-free) | `ai-linux` | 226 passed, 0 failed |
| `npm run test:unit` in `npm/wgslender-vscode` (node runner, no Electron) | `ai-linux` | 7 passed, 0 failed |

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
