# Contributing to wgslender

Thanks for considering a contribution. wgslender is a high-performance
WGSL minifier, validator, linter, and language server, built with Zig.

## Prerequisites

- **Zig 0.16.0** — install via [`zigup`](https://github.com/marler8997/zigup):
  `zigup 0.16.0`. The codebase asserts this minimum at compile time.
- **Node.js ≥16** — only needed if you're working on the npm wrapper.

## Build & test

```bash
zig build              # native CLI → zig-out/bin/wgslender
zig build wasm         # WASM build → zig-out/bin/wgslender.wasm
zig build lsp          # native LSP → zig-out/bin/wgslender-lsp
zig build lsp-wasm     # WASM LSP → zig-out/bin/wgslender-lsp.wasm
zig build test         # full test suite
```

The npm wrapper has its own test suite:

```bash
cd packages/js-npm && npm test
```

## Project layout

See [`CLAUDE.md`](./CLAUDE.md) for an architectural overview and a module
map. Key entry points:

- `cli/main.zig` — CLI argument parsing and pipeline orchestration.
- `lsp/main.zig` and `lsp/Handler.zig` — LSP server.
- `src/Minifier.zig` — minification pipeline coordinator.
- `src/lint/` — linter, rules, and config packs.
- `src/Validator.zig` and `src/validator/` — semantic validation phases.

## Adding things

`CLAUDE.md` has step-by-step recipes for the most common changes:

- Adding a new lint rule.
- Adding a new AST node type.
- Adding a new CLI flag.

Following those recipes keeps the change set small and the existing
snapshot / wire-protocol parity tests green.

## Commit style

Conventional commits (`feat:`, `fix:`, `refactor:`, `test:`, `chore:`,
`docs:`) with an optional scope (`feat(lsp): ...`, `refactor(parse): ...`).
Atomic commits are strongly preferred — one logical change per commit.

## Pull requests

- Run `zig build test` and `cd packages/js-npm && npm test` locally before
  pushing.
- Keep refactors and behavior changes in separate commits.
- If you change wire formats, public APIs, or the CLI surface, mention
  it explicitly in the PR description — these are not just refactors.

## Releasing

One version line spans every package. Bump it in one place and let the
build write it everywhere:

```bash
$EDITOR src/root.zig        # `pub const version` — the only manual edit
./scripts/release.sh        # stamp, rebuild, test everything, prove the tree is fresh
git diff                    # review what the stamp and the rebuild changed
git commit -am "chore: release X.Y.Z"
```

`release.sh` stamps every manifest (`zig build gen-version`), rebuilds both
WASM modules into all five destinations (`zig build release-assets`), runs
the Zig, Go, Rust, and npm suites, reports dependency drift without applying
it, and finishes with `git diff --exit-code`. That last step is the gate:
both WASM builds are byte-reproducible, so a tree that moved after the
script means what was committed was stale. `--check` does the same but
restores the tree.

Bump dependencies in their own commits *before* a release, never inside one.

### Tags

A release needs **two** tags on the same commit. Go resolves a module in a
subdirectory by its path prefix, so `packages/go` cannot share the plain one:

```
v1.1.0                  the repo / Zig / npm / crates release
packages/go/v1.1.0      what `go get …/wgslender/packages/go@v1.1.0` resolves
```

`release.sh` prints both commands rather than running them — tagging is
irreversible, and tags are awkward to move after publication.

Cut `CHANGELOG.md`'s `## [Unreleased]` section into a versioned one as part
of the release commit.

## License

Contributions are released under [CC0-1.0](./LICENSE) — public domain.
By submitting a PR you agree to this licensing.
