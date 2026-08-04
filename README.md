# wgslender

A high-performance WGSL minifier, validator, and reflection tool written in Zig — with a built-in language server.

**[Try the online demo](https://hugodaniel.com/pages/wgslender/)**

```bash
# CLI
wgslender shader.wgsl -o shader.min.wgsl

# npm
npm install wgslender

# Editor support (LSP)
npm install wgslender-lsp
```

## Quick Start

```javascript
import { initialize, minify, reflect, validate } from "wgslender";

await initialize();

// Minify
const result = minify(source);
console.log(result.code); // Minified WGSL

// Validate
const validation = validate(source);
console.log(validation.valid); // true/false

// Reflect
const info = reflect(source);
console.log(info.bindings); // Uniform/storage bindings
console.log(info.entryPoints); // Entry point metadata
```

## Features

| Feature            | Description                                                    |
| ------------------ | -------------------------------------------------------------- |
| **Minification**   | Whitespace removal, identifier renaming, dead code elimination |
| **Validation**     | Type checking, symbol resolution, uniformity analysis, rich diagnostics |
| **Lint**           | ESLint-style configurable rules + shareable configs + disable comments |
| **Reflection**     | Extract bindings, struct layouts, entry points                 |
| **Source Maps**    | Debug minified shaders with v3 source maps                     |
| **Binary shaders** | Compile WGSL to `.wasm` — BPE compression + tiny WASM decoder  |
| **Multi-platform** | CLI, npm/WASM, Zig library, C library (FFI)                    |
| **Editor support** | Full-featured language server — see [Language Server](#language-server-lsp) |
| **Refactoring API** | Programmatic find-references, rename, and reparse-stable IDs from JS/C |
| **Well tested**    | Validated against Dawn Tint test suite (11,952 shaders)         |

## Installation

### CLI

```bash
zig build -Doptimize=ReleaseSafe   # → zig-out/bin/wgslender
```

Requires [Zig 0.16.0](https://ziglang.org/download/).

### npm (Browser/Node.js)

```bash
npm install wgslender
```

### C Library

```bash
zig build -Doptimize=ReleaseSafe   # Produces static library
```

### LSP Server

```bash
# Native (VS Code, Neovim — stdio transport)
zig build lsp -Doptimize=ReleaseSafe   # → zig-out/bin/wgslender-lsp

# Browser editors
npm install wgslender-lsp
```

## CLI Usage

```bash
# Basic minification
wgslender shader.wgsl -o shader.min.wgsl

# Validate shader
wgslender validate shader.wgsl

# Extract reflection data
wgslender reflect shader.wgsl

# Compile to binary shader (.wasm)
wgslender compile shader.wgsl -o shader.wasm

# Whitespace-only (safest)
wgslender --no-mangle shader.wgsl

# With source map
wgslender --source-map shader.wgsl -o shader.min.wgsl
```

### CLI Options

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

### Subcommands

```bash
# Validate - check for errors without minifying
wgslender validate shader.wgsl
wgslender validate --format json shader.wgsl
wgslender validate --strict shader.wgsl  # Warnings as errors

# Reflect - extract binding/struct info as JSON
wgslender reflect shader.wgsl
wgslender reflect --compact shader.wgsl

# Lint - run configurable quality rules
wgslender lint shader.wgsl                                 # @wgslender/recommended by default
wgslender lint --extends @wgslender/strict shader.wgsl     # CI-grade preset
wgslender lint --rule no-unused-vars=error shader.wgsl     # override a rule
wgslender lint --format json shader.wgsl                   # machine-readable
wgslender lint --fix shader.wgsl                           # apply autofixes in place
wgslender lint --fix-dry-run shader.wgsl                   # preview fixes to stdout

# Compile - produce a binary shader (.wasm)
wgslender compile shader.wgsl -o shader.wasm
```

### Lint Rules

Rules are organized into shareable config packs:

| Pack                       | Rules                                                                      |
| -------------------------- | -------------------------------------------------------------------------- |
| `@wgslender/recommended`   | `no-unused-vars`, `no-dead-code`, `no-unused-binding`, `no-unreachable`, `no-constant-condition`, `for-direction`, `no-duplicate-case`, `no-self-assign`, `no-redundant-casts` |
| `@wgslender/style`         | `naming-convention`, `prefer-let-over-var`, `no-empty`, `no-useless-return`, `no-lonely-if`, `no-shadow` |
| `@wgslender/performance`   | `no-large-local-arrays`, `prefer-mix`                                      |
| `@wgslender/portability`   | `require-entry-point-attrs`, `consistent-binding-annotations`, `no-f16-without-extension` |
| `@wgslender/strict`        | Everything above (except `no-magic-numbers`) at error severity, plus complexity-bound rules (`max-params`, `max-depth`, `complexity`, `max-lines-per-function`) — CI gate |

Opt-in rule not included in any pack by default: `no-magic-numbers` (flags
bare numeric literals outside `{-1, 0, 1, 2}`).

### Disable Comments

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

## What Gets Preserved

| Always Preserved                                       | Minified            |
| ------------------------------------------------------ | ------------------- |
| Entry point names (`@vertex`, `@fragment`, `@compute`) | Local variables     |
| `@builtin` names                                       | Function parameters |
| `@location` members                                    | Helper functions    |
| `@group`/`@binding` indices                            | Private structs     |
| `override` names                                       | Type aliases        |
| Uniform/storage var names*                             |                     |

*Use `--mangle-external-bindings` to also minify uniform/storage names.

## JavaScript/TypeScript API

```javascript
import { initialize, minify, reflect, validate } from "wgslender";

await initialize({ wasmURL: "/wgslender.wasm" });

// Minify with options
const result = minify(source, {
  minifyWhitespace: true,
  minifyIdentifiers: true,
  minifySyntax: true,
  treeShaking: true,
  keepNames: ["myHelper"],
});

// Validate (strictMode treats warnings as errors)
const validation = validate(source, {
  strictMode: true,
  diagnosticFilters: { derivative_uniformity: "warning" },
});
if (!validation.valid) {
  for (const d of validation.diagnostics) {
    console.log(`${d.line}:${d.column}: ${d.message}`);
  }
}

// Reflect
const info = reflect(source);
for (const b of info.bindings) {
  console.log(`@group(${b.group}) @binding(${b.binding}) ${b.name}: ${b.type}`);
}

// Lint
import { lint, lintAndFix } from "wgslender";
import { recommended, strict } from "wgslender/configs";

const report = lint(source, {
  extends: [recommended.name],
  rules: { "no-unused-vars": "error" },
});
console.log(`${report.errorCount} errors, ${report.warningCount} warnings`);
for (const d of report.diagnostics) {
  console.log(`${d.line}:${d.column} ${d.severity} [${d.code}] ${d.message}`);
}

// Apply autofixes and rewrite the source in one call
const { fixed } = lintAndFix(source, { extends: [strict.name] });
```

See [npm/wgslender/README.md](npm/wgslender/README.md) for full API documentation.

### Refactoring API

The same analyzer that powers the language server is exposed as pure functions,
so any editor or build tool can drive find-references, rename, and structural
edits without running a full LSP session.

```javascript
import {
  findReferences, rename, renameApply,
  stableIdAtOffset, locateStableId, locateDeclaration, locateType,
  renameByStableId,
  removeDeclarationByStableId, removeDeclarationApplyByStableId,
  changeTypeByStableId, changeTypeApplyByStableId,
} from "wgslender";

// Offset-based (good for cursor-in-editor workflows)
const refs = findReferences(source, cursorByteOffset);   // { references: [{start,end,isWrite}] }
const edits = rename(source, cursorByteOffset, "newName"); // { edits: [{start,end,newText}] }
const { source: next } = renameApply(source, cursorByteOffset, "newName");

// Stable-ID based (survives reparses + unrelated edits)
const { stableId } = stableIdAtOffset(source, cursorByteOffset);
const decl   = locateDeclaration(source, stableId); // { start, end } of full decl
const typeSp = locateType(source, stableId);         // { start, end } of `: T` annotation
renameByStableId(source, stableId, "newName");
changeTypeApplyByStableId(source, stableId, "vec3<f32>");
removeDeclarationApplyByStableId(source, stableId);
```

Stable IDs survive reparses and edits that don't move the declaration across a
block scope, so callers can cache them across keystrokes. Every function
returns an `error` field (e.g. `"invalid identifier"`, `"symbol not found"`)
instead of throwing, and `*Apply` variants always return a usable `source`
string (the original on failure).

## Config File

Create `wgslender.json` in your project:

```json
{
  "minifyWhitespace": true,
  "minifyIdentifiers": true,
  "minifySyntax": true,
  "treeShaking": true,
  "keepNames": ["myUniform"],

  "extends": ["@wgslender/recommended"],
  "rules": {
    "no-unused-vars": "error",
    "no-magic-numbers": ["warn", { "allowlist": [-1, 0, 1, 2] }]
  }
}
```

Config files are auto-discovered by walking parent directories. Supported names: `wgslender.json`, `.wgslenderrc`, `.wgslenderrc.json`.

All four surfaces (CLI `lint`, LSP, JS `lint()`, C `wgslender_lint_c`) read
the `extends`, `rules`, and `reportUnusedDisableDirectives` keys from the
same config. CLI flags (`--extends`, `--rule`, `--no-recommended`,
`--report-unused-disable-directives`) layer on top: extends and rules
append to the config-derived list (CLI rules win on per-id conflict);
`--no-recommended` suppresses the `@wgslender/recommended` auto-add.

Pre-built configs available in `configs/`:

- `compute.toys.json` - For [compute.toys](https://compute.toys) shaders
- `pngine.json` - For [PNGine](https://github.com/HugoDaniel/pngine)

## Source Maps

```bash
wgslender --source-map shader.wgsl -o shader.min.wgsl
# Creates shader.min.wgsl and shader.min.wgsl.map
```

```javascript
const result = minify(source, { sourceMap: true, sourceMapSources: true });
// result.sourceMap contains v3 source map JSON
```

## Binary Shaders

Compile WGSL shaders into self-contained `.wasm` files that generate the WGSL string at runtime. Uses BPE (byte-pair encoding) compression with a ~110-byte WASM decoder.

```bash
wgslender compile shader.wgsl -o shader.wasm
```

```javascript
// Load binary shader in the browser
const { instance } = await WebAssembly.instantiate(await fetch("shader.wasm").then(r => r.arrayBuffer()));
const len = instance.exports.generate();
const wgsl = new TextDecoder().decode(new Uint8Array(instance.exports.memory.buffer, 0, len));
device.createShaderModule({ code: wgsl });
```

## Language Server (LSP)

A full-featured WGSL language server built from the same analyzer as the CLI.

| Capability | Details |
| ---------- | ------- |
| Diagnostics | Push on open/change/save **and** pull model (`textDocument/diagnostic`) with `resultId` cache |
| Quick fixes | Code actions for typo fixes, safe casts, duplicate-binding renumbering, unused-removal, "did you mean?" |
| Hover | Resolved type info + function signatures + docstrings |
| Go to definition / type definition | Jump to decl or to the struct/alias behind a value |
| Find references / document highlight | All uses of the symbol under the cursor |
| Rename | With `prepareRename`, validates the new name against reserved words |
| Completion | Identifier + attribute completion (triggered by `.` and `@`) |
| Signature help | Parameter info while typing a call (triggered by `(` and `,`) |
| Document symbols | Hierarchical outline — structs, fields, functions, params, locals |
| Folding ranges | Blocks, functions, structs |
| Inlay hints | Evaluated `const` array sizes and other computed values (toggleable) |
| Code lens | Binding / entry-point annotations + module total-size lens (`<src> B → <min> B min → <gz> B gz`, click → minified text) |
| Document formatting | Pretty-print the full file |
| Semantic tokens | 9 token types × 3 modifiers (keyword, function, struct, parameter, variable, number, type, comment, decorator) |
| Selection range | Smart expand/shrink up the AST |
| Call hierarchy | Incoming and outgoing calls |
| Incremental sync | `TextDocumentSyncKind.Incremental` — only changed ranges are reparsed |
| `workspace/configuration` | Pulls `wgslender` section. Schema mirrors `wgslender.json`: LSP-only knobs under `lsp.*` (`lsp.inlayHints.enabled`, `lsp.diagnostics.enabled`, `lsp.minifyMode`, `lsp.minifyLints.{enabled,budgetBytes}`); CLI knobs at top-level (`mangleExternalBindings`, `minifyWhitespace`, …); per-rule severities at top-level `rules` (id-keyed, ESLint-shape) |
| `workspace/executeCommand` | `wgslender.setMinifyMode`, `wgslender.toggleMinifyMode`, `wgslender.showMinifiedOutput` |

Both transports (native stdio and browser WASM) expose the same capability set.

#### Minifier-mode size budget

When `lsp.minifyMode = "strict"` is on, the LSP runs the minifier-mode
lint pack (`@wgslender/minify`). The `M0500 minify/shader-exceeds-size-budget`
rule fires when the estimated minified size exceeds a configured byte
budget. Set the budget through workspace config:

```json
{
    "lsp": {
        "minifyMode": "strict",
        "minifyLints": {
            "enabled": true,
            "budgetBytes": 8192
        }
    },
    "rules": {
        "minify/shader-exceeds-size-budget": "warning"
    }
}
```

The same `budgetBytes` value powers an `(over budget)` badge on the
module-level total-size code lens. Without `budgetBytes`, the rule
stays a no-op and the lens shows just the size triple. CLI users can
supply the budget via the standard rule-options shape:

```json
{
    "rules": {
        "minify/shader-exceeds-size-budget": ["warn", { "maxBytes": 8192 }]
    }
}
```

Clicking the total-size lens triggers `workspace/executeCommand` with
`wgslender.showMinifiedOutput`. The server runs the full minifier and
returns `{ uri, minified_text, byte_count, gz_count }`; the client is
expected to open a virtual document (e.g. `wgslender-minified:` URI
scheme) with the returned text — wgslender does not create files.

### Native (VS Code / Neovim)

```bash
zig build lsp -Doptimize=ReleaseSafe
# → zig-out/bin/wgslender-lsp (stdio transport)
```

Configure your editor to run `wgslender-lsp` as a language server for `.wgsl` files.

### Browser (CodeMirror)

```bash
npm install wgslender-lsp
```

```javascript
import { initialize, createTransport } from "wgslender-lsp";
import { LSPClient, languageServerExtensions } from "@codemirror/lsp-client";

await initialize();
const transport = createTransport();
const client = new LSPClient({ extensions: languageServerExtensions() });
client.connect(transport);
```

## Development

```bash
zig build              # Build CLI → zig-out/bin/wgslender
zig build wasm         # Build WASM → zig-out/bin/wgslender.wasm
zig build lsp          # Build LSP server → zig-out/bin/wgslender-lsp
zig build lsp-wasm     # Build WASM LSP → zig-out/bin/wgslender-lsp.wasm
zig build test         # Run all tests

# Run
echo 'fn main() {}' | ./zig-out/bin/wgslender
./zig-out/bin/wgslender validate shader.wgsl
./zig-out/bin/wgslender compile shader.wgsl -o shader.wasm

# NPM package tests
cd npm/wgslender && npm test                # all 4 wrapper variants
cd npm/wgslender-lsp && node test.js
```

Requires [Zig 0.16.0](https://ziglang.org/download/) — install via `zigup 0.16.0`.

## Documentation

- [Why minify WGSL?](docs/why-minify-wgsl.md) - Benefits of shader minification
- [Why pre-validate WGSL?](docs/why-pre-validate-wgsl.md) - Benefits of build-time validation
- [Why reflect WGSL?](docs/why-reflect-wgsl.md) - Benefits of shader reflection
- [npm package docs](npm/wgslender/README.md) - JavaScript/TypeScript API
- [C API reference](docs/C-API.md) - C/FFI integration
- [Building with wgslender](BUILDING_WITH_WGSLENDER.md) - Integration guide

## License

CC0 Public Domain - See [LICENSE](LICENSE)
