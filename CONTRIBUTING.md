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
cd npm/wgslender && npm test
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

- Run `zig build test` and `cd npm/wgslender && npm test` locally before
  pushing.
- Keep refactors and behavior changes in separate commits.
- If you change wire formats, public APIs, or the CLI surface, mention
  it explicitly in the PR description — these are not just refactors.

## License

Contributions are released under [CC0-1.0](./LICENSE) — public domain.
By submitting a PR you agree to this licensing.
