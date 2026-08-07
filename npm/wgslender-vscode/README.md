# wgslender — WGSL language support for VS Code

Rich WGSL editing powered by [wgslender](https://github.com/HugoDaniel/wgslender) — minifier, linter, validator, formatter, and Language Server, all in one extension.

## Features

- **Language server** — diagnostics, hover, completion, signature help, definition, declaration, references, formatting, semantic tokens, code actions, inlay hints, code lens, call hierarchy, folding, document symbols, workspace symbol search, rename, type definition, document highlight, selection range. All via the bundled WASM LSP, no Node child process or remote server.
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

See `wgslender.*` in the settings UI. The settings schema is identical to
`wgslender.json` — anything you can set in the workspace file you can set
in your editor too, with the same key names. Key knobs:

**Lint**
- `wgslender.extends` — config packs (default `["@wgslender/recommended"]`).
- `wgslender.rules` — per-rule severity overrides keyed by rule id.
- `wgslender.reportUnusedDisableDirectives` — flag `wgslender-disable` comments that don't suppress anything.
- `wgslender.lint.fixOnSave` — apply autofixes on save.

**LSP feature toggles**
- `wgslender.lsp.inlayHints.enabled` — show inlay hints (sizes, parameter names).
- `wgslender.lsp.diagnostics.enabled` — publish diagnostics.

**Minify insights** (drive the LSP-side estimator + inlay hints / code lens)
- `wgslender.lsp.minifyMode` — `off` | `insights` | `strict`.
- `wgslender.lsp.minifyInsights.format` — `delta` | `bytes` | `both`.
- `wgslender.lsp.minifyInsights.functionSize` / `declSize` / `totalSize` — granularity toggles.
- `wgslender.lsp.minifyLints.enabled` — run M01xx hygiene checks (auto-on with `strict`).
- `wgslender.lsp.minifyLints.budgetBytes` — per-shader byte budget; M0500 fires above it. `null` = no budget.
- `wgslender.lsp.minifyEstimator.useFullMinify` — opt-in: production minifier + gzip for ground-truth bytes (slower).

**Minifier knobs** (reused by **Minify Preview**, **Save Minified As…**, and **Compile**, and by the LSP estimator)
- `wgslender.minifyWhitespace` / `minifyIdentifiers` / `minifySyntax` / `treeShaking` — pipeline toggles (default on).
- `wgslender.preserveUniformStructTypes` — keep struct types referenced by uniform/storage vars.
- `wgslender.mangleExternalBindings` — rename `@group/@binding` vars directly (default keeps `let` aliases). Same knob also gates the LSP M0100 hint; to silence M0100 without changing minifier behavior, set `wgslender.rules` to include `"minify/external-binding-blocks-rename": "off"`.
- `wgslender.sortDeclarations` / `scopeLocalRename` — improve DEFLATE compression of minified output.
- `wgslender.keepNames` — names that must never be renamed.

**Other**
- `wgslender.compile.outputDirectory` — default save location for **Compile to Binary Shader** (relative to the workspace folder; empty = alongside the source).
- `wgslender.reflect.version` — `v1` | `v2` schema for the reflection panel and JSON command.
- `wgslender.format.enable` — toggle formatter.
- `wgslender.trace.server` — LSP communication trace.

## Development

The two `.wasm` files in `dist/` are build artefacts of the Zig tree, not
checked in. Populate them before anything else:

```
zig build vscode-assets     # from the repository root
npm install
npm run build               # esbuild → dist/{extension,web-extension,server}.js
```

There are two hosts and a test for each. Neither substitutes for the other:
they load different bundles.

```
npm test               # desktop host — @vscode/test-electron loads dist/extension.js
npm run test:web-host  # browser host — headless Chrome drives dist/server.js in a real Worker
```

`npm test` downloads a VS Code build on first run and opens it. `test:web-host`
needs Google Chrome (`CHROME_PATH` overrides) and serves `dist/` over a local
port. It exists because the interesting failures on the web side — a bundle
that throws on load, a WASM URL that 404s, an advertised command list that
drifted — all look fine from Node, and the desktop bundle once shipped broken
for exactly that reason.

Note that the language server's `workspace/executeCommand` ids live in
`wgslender.server.*`, separate from this extension's own `wgslender.*` command
ids. They must stay separate: vscode-languageclient registers a VS Code command
for every id the server advertises, so a shared name breaks activation.

## License

CC0-1.0
