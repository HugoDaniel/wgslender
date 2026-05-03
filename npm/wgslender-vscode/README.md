# wgslender — WGSL language support for VS Code

Rich WGSL editing powered by [wgslender](https://github.com/HugoDaniel/wgslender) — minifier, linter, validator, formatter, and Language Server, all in one extension.

## Features

- **Language server** — diagnostics, hover, completion, signature help, definition, references, formatting, semantic tokens, code actions, inlay hints, code lens, call hierarchy, folding, document symbols, rename, type definition, document highlight, selection range. All via the bundled WASM LSP, no Node child process or remote server.
- **Lint** with configurable rule packs (`@wgslender/recommended`, `/style`, `/performance`, `/portability`, `/strict`).
- **Palette commands**:
  - `wgslender: Minify Preview` — opens a live read-only `.min.wgsl` view beside the source.
  - `wgslender: Save Minified As…` — writes the minified text to disk.
  - `wgslender: Compile to Binary Shader` — produces a self-extracting `.wasm` shader you can feed straight to `WebAssembly.instantiate` + `device.createShaderModule`.
  - `wgslender: Show Reflection JSON` — opens the reflection result for the active document.
  - `wgslender: Toggle Minify Insights Mode` — cycles `off → insights → strict`.
  - `wgslender: Recompute Minify Insights` — re-runs the estimator on demand.
  - `wgslender: Focus / Refresh Reflection`.
- **Reflection sidebar** — TreeView showing entry points, bind groups, structs, overrides, in-use functions, and aliases for the active `.wgsl` document.
- **Status bar** — minified byte size with savings ratio; click cycles minify insights mode.

Works on both **VS Code Desktop** and **vscode.dev / github.dev** (web).

## Settings

See `wgslender.*` in the settings UI. Key knobs:

- `wgslender.extends` — config packs (default `["@wgslender/recommended"]`).
- `wgslender.rules` — per-rule severity overrides.
- `wgslender.lint.fixOnSave` — apply autofixes on save.
- `wgslender.lsp.minifyMode` — `off` | `insights` | `strict`.
- `wgslender.lsp.mangleExternalBindings` — silence M0100 when the consuming pipeline mangles bindings.
- `wgslender.sortDeclarations` / `scopeLocalRename` / `keepNames` — minifier knobs reused by **Minify Preview** and **Save Minified As…**.
- `wgslender.compile.outputDirectory` — default save location for **Compile to Binary Shader** (relative to the workspace folder; empty = alongside the source).
- `wgslender.reflect.version` — `v1` | `v2` schema for the reflection panel and JSON command.
- `wgslender.format.enable` — toggle formatter.
- `wgslender.trace.server` — LSP communication trace.

## License

CC0-1.0
