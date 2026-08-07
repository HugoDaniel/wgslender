# wgslender

[![npm](https://img.shields.io/npm/v/wgslender)](https://www.npmjs.com/package/wgslender)
[![license: CC0-1.0](https://img.shields.io/badge/license-CC0--1.0-blue)](LICENSE)

Ship smaller, safer WebGPU shaders. wgslender minifies, validates, lints, and reflects WGSL — with a language server that runs natively or in the browser.

**[Playground](https://hugodaniel.com/pages/wgslender/)** · **[VS Code extension](https://marketplace.visualstudio.com/items?itemName=hugodaniel.wgslender-vscode)** · **[Benchmarks](BENCHMARK.md)**

## Quick start

```bash
npm install wgslender
```

```javascript
import { initialize, minify } from "wgslender";

await initialize();

const result = minify(source);
console.log(result.code); // minified WGSL
```

Same engine on every surface — see [Install](#install) for the CLI, Rust, Go, C, and editors.

## Highlights

- **Smaller shaders** — up to 86% smaller raw, 63% after gzip ([benchmarks](BENCHMARK.md))
- **[Binary shaders](#binary-shaders)** — WGSL compiled to a self-extracting `.wasm` with a ~110-byte decoder
- **[Validation](#reflection--validation)** — type checking, symbol resolution, and uniformity analysis before the GPU sees the shader
- **[Lint](#lint)** — ESLint-style rules, shareable config packs, `--fix` autofixes, disable comments
- **Reflection** — bindings, entry points, and struct layouts as JSON ([format](docs/reflect.md))
- **[Editor support](#editor-support)** — a full language server, native or as WASM in the browser
- **Trustworthy** — tested against the Dawn Tint suite (11,952 shaders); one dependency-free Zig core behind every binding; CC0

## Install

| Surface | Install | Docs |
| ------- | ------- | ---- |
| JavaScript / TypeScript | `npm install wgslender` | [packages/js-npm](packages/js-npm/README.md) |
| CLI | `zig build -Doptimize=ReleaseSafe` → `zig-out/bin/wgslender` | requires [Zig 0.16.0](https://ziglang.org/download/) |
| Rust | `cargo add wgslender` | [packages/rust](packages/rust/README.md) |
| Go | `go get git.hugodaniel.com/hugo/wgslender/packages/go/wgslender` | [packages/go](packages/go/README.md) |
| C | `zig build lib` → `libwgslender.a` + `wgslender.h` | [C API](docs/C-API.md) |
| LSP server | `npm install wgslender-lsp` (browser) · `zig build lsp` (native) | [Editor support](#editor-support) |
| VS Code | [Marketplace](https://marketplace.visualstudio.com/items?itemName=hugodaniel.wgslender-vscode) | [extension docs](npm/wgslender-vscode/README.md) |

## CLI

```bash
wgslender shader.wgsl -o shader.min.wgsl     # minify
wgslender --no-mangle shader.wgsl            # whitespace-only (safest)
wgslender validate shader.wgsl               # check errors without minifying
wgslender lint shader.wgsl                   # quality rules
wgslender reflect shader.wgsl                # bindings + layouts as JSON
wgslender compile shader.wgsl -o shader.wasm # binary shader (see below)
```

<details>
<summary>All 19 flags, subcommand variants, and what gets preserved</summary>

| Flag                         | Description                          |
| ---------------------------- | ------------------------------------ |
| `-o <file>`                  | Output file (default: stdout)        |
| `--minify`                   | Force-enable all minification passes |
| `--minify-whitespace`        | Only minify whitespace               |
| `--minify-identifiers`       | Only minify identifiers              |
| `--minify-syntax`            | Only minify syntax (numeric literals)|
| `--no-mangle`                | Don't rename identifiers             |
| `--mangle-external-bindings` | Rename uniform/storage vars directly |
| `--keep-names <names>`       | Preserve specific names              |
| `--no-tree-shaking`          | Keep unused declarations             |
| `--preserve-uniform-struct-types` | Keep struct names used in uniforms |
| `--sort-declarations`        | Sort declarations by kind (compression) |
| `--scope-local-rename`       | Per-function canonical naming (compression) |
| `--source-map`               | Generate source map                  |
| `--source-map-inline`        | Embed source map as inline data URI  |
| `--source-map-sources`       | Include original source in source map|
| `--config <file>`            | Use config file                      |
| `--no-config`                | Ignore config files                  |
| `--line-offset <n>`          | Add n to reported line numbers (validate/lint) |
| `--reflect-format <v1\|v2>`  | Reflect JSON schema (default: v2)    |

```bash
wgslender validate --format json shader.wgsl    # machine-readable diagnostics
wgslender validate --strict shader.wgsl         # warnings as errors
wgslender reflect --compact shader.wgsl
wgslender lint --extends @wgslender/strict shader.wgsl
wgslender lint --rule no-unused-vars=error shader.wgsl
wgslender lint --fix-dry-run shader.wgsl        # preview autofixes to stdout
```

`--source-map` writes a v3 source map next to the output; from JS, pass
`minify(source, { sourceMap: true, sourceMapSources: true })`.

**What gets preserved:**

| Always Preserved                                       | Minified            |
| ------------------------------------------------------ | ------------------- |
| Entry point names (`@vertex`, `@fragment`, `@compute`) | Local variables     |
| `@builtin` names                                       | Function parameters |
| `@location` members                                    | Helper functions    |
| `@group`/`@binding` indices                            | Private structs     |
| `override` names                                       | Type aliases        |
| Uniform/storage var names*                             |                     |

*Use `--mangle-external-bindings` to also minify uniform/storage names.

</details>

## Lint

```bash
wgslender lint shader.wgsl        # @wgslender/recommended by default
wgslender lint --fix shader.wgsl  # apply autofixes in place
```

Rules ship in five shareable packs — `@wgslender/recommended`, `/style`, `/performance`, `/portability`, and `/strict` as a CI gate.

<details>
<summary>Rule packs and disable comments</summary>

| Pack                       | Rules                                                                      |
| -------------------------- | -------------------------------------------------------------------------- |
| `@wgslender/recommended`   | `no-unused-vars`, `no-dead-code`, `no-unused-binding`, `no-unreachable`, `no-constant-condition`, `for-direction`, `no-duplicate-case`, `no-self-assign`, `no-redundant-casts` |
| `@wgslender/style`         | `naming-convention`, `prefer-let-over-var`, `no-empty`, `no-useless-return`, `no-lonely-if`, `no-shadow` |
| `@wgslender/performance`   | `no-large-local-arrays`, `prefer-mix`                                      |
| `@wgslender/portability`   | `require-entry-point-attrs`, `consistent-binding-annotations`, `no-f16-without-extension` |
| `@wgslender/strict`        | Everything above (except `no-magic-numbers`) at error severity, plus complexity-bound rules (`max-params`, `max-depth`, `complexity`, `max-lines-per-function`) — CI gate |

Opt-in rule not included in any pack by default: `no-magic-numbers` (flags
bare numeric literals outside `{-1, 0, 1, 2}`).

Silence specific rules inline:

```wgsl
// wgslender-disable-next-line no-unused-vars
fn scratchHelper() {}

let magic = 42; // wgslender-disable-line no-magic-numbers

/* wgslender-disable no-magic-numbers */
let a = 99;
let b = 77;
/* wgslender-enable no-magic-numbers */

// wgslender-disable-file naming-convention
```

Rule ids are comma-separated. An empty list silences every lint rule. Pass
`--report-unused-disable-directives` to be warned about dangling directives.

</details>

## Binary shaders

`wgslender compile` turns a shader into a self-contained `.wasm` that regenerates the WGSL at runtime — BPE-compressed text plus a ~110-byte decoder. Above the ~5 KB crossover it beats gzipped minified text, making it the smallest way to ship a big shader ([benchmarks](BENCHMARK.md)).

```bash
wgslender compile shader.wgsl -o shader.wasm
```

<details>
<summary>Loading a compiled shader in the browser</summary>

```javascript
const { instance } = await WebAssembly.instantiate(await fetch("shader.wasm").then(r => r.arrayBuffer()));
const len = instance.exports.generate();
const wgsl = new TextDecoder().decode(new Uint8Array(instance.exports.memory.buffer, 0, len));
device.createShaderModule({ code: wgsl });
```

</details>

## Reflection & validation

```javascript
const validation = validate(source); // { valid, diagnostics: [{ line, column, message, ... }] }
const info = reflect(source);        // bindings, entry points, struct layouts
```

Validation catches the errors the browser would raise — at build time instead ([why?](docs/why-pre-validate-wgsl.md)). Reflection emits bindings, entry points, and exact struct memory layouts as JSON, ready to drive bind-group creation ([why?](docs/why-reflect-wgsl.md), [output format](docs/reflect.md)).

## Editor support

- **VS Code** — install [wgslender from the Marketplace](https://marketplace.visualstudio.com/items?itemName=hugodaniel.wgslender-vscode): diagnostics, hover, completion, rename, formatting, semantic tokens, inlay hints, a size code lens, and a reflection sidebar — all from a bundled WASM server, no separate binary ([extension docs](npm/wgslender-vscode/README.md)).
- **Neovim and other editors** — `zig build lsp -Doptimize=ReleaseSafe` builds `zig-out/bin/wgslender-lsp`, a stdio language server; point your LSP client at it for `.wgsl` files.
- **Browser editors** — `npm install wgslender-lsp` runs the same server as WASM with no backend; the [playground](https://hugodaniel.com/pages/wgslender/) is it, live.

<details>
<summary>LSP capabilities and CodeMirror wiring</summary>

| Capability | Details |
| ---------- | ------- |
| Diagnostics | Push on open/change/save **and** pull model (`textDocument/diagnostic`) with `resultId` cache |
| Quick fixes | Typo fixes, safe casts, duplicate-binding renumbering, unused-removal, "did you mean?" |
| Hover / signature help | Resolved types, function signatures, docstrings; parameter info triggered by `(` and `,` |
| Completion | Identifier + attribute completion (triggered by `.` and `@`) |
| Navigation | Definition, type definition, references, document highlight, call hierarchy |
| Rename | With `prepareRename`, validates the new name against reserved words |
| Outline | Document symbols, folding ranges, selection range |
| Inlay hints | Evaluated `const` array sizes and other computed values (toggleable) |
| Code lens | Binding / entry-point annotations + module total-size lens (`<src> B → <min> B min → <gz> B gz`) |
| Formatting | Pretty-print the full file |
| Semantic tokens | 9 token types × 3 modifiers |
| Incremental sync | Only changed ranges are reparsed |
| `workspace/configuration` | Pulls the `wgslender` section; schema mirrors `wgslender.json`, with LSP-only knobs under `lsp.*` |
| `workspace/executeCommand` | `wgslender.server.{setMinifyMode,toggleMinifyMode,recomputeMinifyInsights,showMinifiedOutput}` |

Both transports expose the same capability set; the native transport
additionally offers reflection as the `wgslender.server.reflect` command.

**Minifier-mode size budget.** With `lsp.minifyMode = "strict"` the server runs
the `@wgslender/minify` lint pack, and `M0500 minify/shader-exceeds-size-budget`
fires when the estimated minified size exceeds `budgetBytes`. The same value
powers an `(over budget)` badge on the total-size code lens; without it the
rule is a no-op.

```json
{
    "lsp": {
        "minifyMode": "strict",
        "minifyLints": { "enabled": true, "budgetBytes": 8192 }
    },
    "rules": { "minify/shader-exceeds-size-budget": "warning" }
}
```

**CodeMirror wiring:**

```javascript
import { initialize, createTransport } from "wgslender-lsp";
import { LSPClient, languageServerExtensions } from "@codemirror/lsp-client";

await initialize();
const transport = createTransport();
const client = new LSPClient({ extensions: languageServerExtensions() });
client.connect(transport);
```

</details>

## JavaScript API

`minify`, `validate`, `reflect`, `lint`, `lintAndFix`, and a refactoring API — full documentation, TypeScript types, and bundler recipes in [packages/js-npm/README.md](packages/js-npm/README.md).

<details>
<summary>Options, lint, and the refactoring API</summary>

```javascript
import { initialize, minify, lint, lintAndFix } from "wgslender";
import { recommended, strict } from "wgslender/configs";

await initialize({ wasmURL: "/wgslender.wasm" });

const result = minify(source, {
  minifyWhitespace: true,
  minifyIdentifiers: true,
  minifySyntax: true,
  treeShaking: true,
  keepNames: ["myHelper"],
});

const report = lint(source, {
  extends: [recommended.name],
  rules: { "no-unused-vars": "error" },
});
console.log(`${report.errorCount} errors, ${report.warningCount} warnings`);

// Apply autofixes and rewrite the source in one call
const { fixed } = lintAndFix(source, { extends: [strict.name] });
```

The same analyzer that powers the language server is exposed as pure
functions, so any editor or build tool can drive find-references, rename,
and structural edits without an LSP session:

```javascript
import { findReferences, renameApply, stableIdAtOffset, renameByStableId } from "wgslender";

const refs = findReferences(source, cursorByteOffset);       // { references: [{ start, end, isWrite }] }
const { source: next } = renameApply(source, cursorByteOffset, "newName");

const { stableId } = stableIdAtOffset(source, cursorByteOffset);
renameByStableId(source, stableId, "newName");               // survives reparses + unrelated edits
```

Stable IDs survive reparses and edits that don't move the declaration across
a block scope, so callers can cache them across keystrokes. Every function
returns an `error` field instead of throwing, and `*Apply` variants always
return a usable `source` string (the original on failure). Also available:
`rename`, `locateStableId`, `locateDeclaration`, `locateType`,
`changeTypeByStableId`/`changeTypeApplyByStableId`,
`removeDeclarationByStableId`/`removeDeclarationApplyByStableId`.

</details>

## Configuration

Drop a `wgslender.json` next to your shaders — the CLI, LSP, JS, and C surfaces all read the same file. It is auto-discovered by walking parent directories (also as `.wgslenderrc` / `.wgslenderrc.json`); pass `--no-config` to skip discovery.

```json
{
  "minifyWhitespace": true,
  "minifyIdentifiers": true,
  "keepNames": ["myUniform"],
  "extends": ["@wgslender/recommended"],
  "rules": { "no-unused-vars": "error" }
}
```

<details>
<summary>Precedence rules and presets</summary>

Settings layer lowest-first: built-in defaults, then the config file, then
command-line flags. A flag wins over the config file on the field it names
and leaves every other config value in place — so
`wgslender --config c.json --sort-declarations` keeps everything in `c.json`
*and* sorts declarations. Two exceptions:

- `--keep-names` **replaces** the config's `keepNames` rather than appending
  to it (per-field last-layer-wins, like every other flag). The lint
  accumulators `extends` and `rules` are the opposite — they concatenate, so
  config packs compose with CLI ones and CLI entries win on conflict.
- The `--minify` / `--minify-*` / `--no-mangle` / `--no-whitespace` /
  `--no-syntax` cluster is resolved last and outranks both layers.

Pre-built configs live in `configs/`: `compute.toys.json` for
[compute.toys](https://compute.toys) shaders, `pngine.json` for
[PNGine](https://github.com/HugoDaniel/pngine).

</details>

## Learn more

- [Why minify WGSL?](docs/why-minify-wgsl.md) · [Why pre-validate?](docs/why-pre-validate-wgsl.md) · [Why reflect?](docs/why-reflect-wgsl.md)
- [Reflection output format](docs/reflect.md)
- [C API reference](docs/C-API.md) · [worked examples in C and TypeScript](examples/README.md)
- [Building with wgslender](BUILDING_WITH_WGSLENDER.md) — the integration guide
- [Benchmarks](BENCHMARK.md) · [Changelog](CHANGELOG.md)

## Development

```bash
zig build        # CLI → zig-out/bin/wgslender
zig build test   # full test suite
```

Requires [Zig 0.16.0](https://ziglang.org/download/) (`zigup 0.16.0`). Each language package documents its own test gate in its README; the contribution workflow lives in [CONTRIBUTING.md](CONTRIBUTING.md).

## License

CC0 Public Domain — see [LICENSE](LICENSE).
