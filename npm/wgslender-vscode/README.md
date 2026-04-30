# wgslender — WGSL language support for VS Code

Rich WGSL editing powered by [wgslender](https://github.com/HugoDaniel/wgslender) — minifier, linter, validator, formatter, and Language Server, all in one extension.

## Features

- **Diagnostics, hover, completion, signature help, definition, references, formatting, semantic tokens, code actions, inlay hints, code lens, call hierarchy, folding, document symbols** — via the bundled WASM language server.
- **Lint** with configurable rule packs (`@wgslender/recommended`, `/style`, `/performance`, `/portability`, `/strict`).
- **Minify Preview** — read-only side-by-side minified view.
- **Compile to Binary Shader** — produce a self-extracting `.wasm` shader.
- **Reflection sidebar** — browse entry points, bind groups, structs, overrides.
- **Status bar** — shows minified byte size; click to cycle minify-insights mode.

Works on both **VS Code Desktop** and **vscode.dev / github.dev** (web).

## Settings

See `wgslender.*` in the settings UI. Key knobs:

- `wgslender.lint.extends` — config packs (default `["@wgslender/recommended"]`).
- `wgslender.lint.rules` — per-rule severity overrides.
- `wgslender.lint.fixOnSave` — apply autofixes on save.
- `wgslender.minify.mode` — `off` | `insights` | `strict`.
- `wgslender.format.enable` — toggle formatter.
- `wgslender.trace.server` — LSP communication trace.

## License

CC0-1.0
