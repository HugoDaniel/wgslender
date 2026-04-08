# wgslender

A high-performance WGSL minifier, validator, and reflection tool written in Zig.

**[Try the online demo](https://hugodaniel.com/pages/wgslender/)**

```bash
# CLI
wgslender shader.wgsl -o shader.min.wgsl

# npm
npm install wgslender
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
| **Validation**     | Type checking, symbol resolution, uniformity analysis          |
| **Reflection**     | Extract bindings, struct layouts, entry points                 |
| **Source Maps**    | Debug minified shaders with v3 source maps                     |
| **Binary shaders** | Compile WGSL to `.wasm` — BPE compression + tiny WASM decoder  |
| **Multi-platform** | CLI, npm/WASM, Zig library, C library (FFI)                    |
| **Well tested**    | Validated against Dawn Tint test suite (7,961 shaders)         |

## Installation

### CLI

```bash
zig build -Doptimize=ReleaseSafe   # → zig-out/bin/wgslender
```

Requires [Zig master](https://ziglang.org/download/) (0.16.x).

### npm (Browser/Node.js)

```bash
npm install wgslender
```

### C Library

```bash
zig build -Doptimize=ReleaseSafe   # Produces static library
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
| `--minify-whitespace`        | Only minify whitespace               |
| `--minify-identifiers`       | Only minify identifiers              |
| `--minify-syntax`            | Only minify syntax (numeric literals)|
| `--no-mangle`                | Don't rename identifiers             |
| `--mangle-external-bindings` | Rename uniform/storage vars directly |
| `--keep-names <names>`       | Preserve specific names              |
| `--no-tree-shaking`          | Keep unused declarations             |
| `--sort-declarations`        | Sort declarations by kind (compression) |
| `--scope-local-rename`       | Per-function canonical naming (compression) |
| `--source-map`               | Generate source map                  |
| `--config <file>`            | Use config file                      |
| `--no-config`                | Ignore config files                  |

### Subcommands

```bash
# Validate - check for errors without minifying
wgslender validate shader.wgsl
wgslender validate --format json shader.wgsl
wgslender validate --strict shader.wgsl  # Warnings as errors

# Reflect - extract binding/struct info as JSON
wgslender reflect shader.wgsl
wgslender reflect --compact shader.wgsl

# Compile - produce a binary shader (.wasm)
wgslender compile shader.wgsl -o shader.wasm
```

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
import {
  initialize,
  minify,
  minifyAndReflect,
  reflect,
  validate,
} from "wgslender";

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
const validation = validate(source, { strictMode: true });
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

// Combined minify + reflect (with minified names)
const combined = minifyAndReflect(source);
console.log(combined.code);
console.log(combined.reflect.bindings);
```

See [npm/wgslender/README.md](npm/wgslender/README.md) for full API documentation.

## Config File

Create `wgslender.json` in your project:

```json
{
  "minifyWhitespace": true,
  "minifyIdentifiers": true,
  "minifySyntax": true,
  "treeShaking": true,
  "keepNames": ["myUniform"]
}
```

Config files are auto-discovered by walking parent directories. Supported names: `wgslender.json`, `.wgslenderrc`, `.wgslenderrc.json`.

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

## Development

```bash
zig build              # Build CLI → zig-out/bin/wgslender
zig build wasm         # Build WASM → zig-out/bin/wgslender.wasm
zig build test         # Run all tests

# Run
echo 'fn main() {}' | ./zig-out/bin/wgslender
./zig-out/bin/wgslender validate shader.wgsl
./zig-out/bin/wgslender compile shader.wgsl -o shader.wasm

# NPM package tests
cd npm/wgslender && node test.js
```

Requires [Zig master](https://ziglang.org/download/) (0.16.x) — install via `zigup master`.

## Documentation

- [Why minify WGSL?](docs/why-minify-wgsl.md) - Benefits of shader minification
- [Why pre-validate WGSL?](docs/why-pre-validate-wgsl.md) - Benefits of build-time validation
- [Why reflect WGSL?](docs/why-reflect-wgsl.md) - Benefits of shader reflection
- [npm package docs](npm/wgslender/README.md) - JavaScript/TypeScript API
- [Building with wgslender](BUILDING_WITH_WGSLENDER.md) - Integration guide

## License

CC0 Public Domain - See [LICENSE](LICENSE)
