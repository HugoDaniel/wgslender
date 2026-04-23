# CLAUDE.md - wgslender

Commit often. Atomic commits in a style consistent with existing ones (conventional).

## Project Overview

A high-performance WGSL (WebGPU Shading Language) minifier written in Zig, with WASM builds for browser/Node.js usage. Architecture inspired by esbuild.

## Quick Commands

```bash
# Build
zig build              # Native CLI → zig-out/bin/wgslender
zig build wasm         # WASM → zig-out/bin/wgslender.wasm
zig build lsp          # Native LSP → zig-out/bin/wgslender-lsp
zig build lsp-wasm     # WASM LSP → zig-out/bin/wgslender-lsp.wasm

# Test
zig build test         # Run all tests

# Run
./zig-out/bin/wgslender shader.wgsl                    # Basic minification
./zig-out/bin/wgslender --config configs/compute.toys.json shader.wgsl  # With config
echo 'fn main() {}' | ./zig-out/bin/wgslender          # From stdin
./zig-out/bin/wgslender validate shader.wgsl           # Semantic validation
./zig-out/bin/wgslender validate --format json shader.wgsl  # JSON diagnostics

# Lint (configurable rule-based linting, ESLint-inspired)
./zig-out/bin/wgslender lint shader.wgsl                          # @wgslender/recommended by default
./zig-out/bin/wgslender lint --extends @wgslender/strict shader.wgsl
./zig-out/bin/wgslender lint --rule no-magic-numbers=warn shader.wgsl
./zig-out/bin/wgslender lint --fix shader.wgsl                    # apply autofixes in place
./zig-out/bin/wgslender lint --format json shader.wgsl

# Compression-friendly minification (better DEFLATE, 5-29% gzip savings)
./zig-out/bin/wgslender --sort-declarations --scope-local-rename shader.wgsl

# Compile to binary shader
./zig-out/bin/wgslender compile shader.wgsl -o shader.wasm

# NPM package
cd npm/wgslender && node test.js            # Run JS tests
cd npm/wgslender && npm pack --dry-run      # Check package contents
```

## Architecture

```
Source → Lexer → Parser → AST → Minifier → Printer → Output
                           ↓
                       Renamer

Source → Lexer → Parser → AST → Validator → Diagnostics
                                    ↓
                            Types + Builtins
```

### Module Map

| Module | Purpose |
|--------|---------|
| `src/Lexer.zig` | Tokenizer with fast ASCII lookup tables |
| `src/Ast.zig` | AST nodes (tagged unions), Symbol table, Scope tree |
| `src/Parser.zig` | Two-pass parser (parse → visit/bind) |
| `src/Printer.zig` | Code generator with minification + syntax optimization |
| `src/Renamer.zig` | Frequency-based identifier renaming |
| `src/Dce.zig` | Dead code elimination via BFS from entry points |
| `src/Minifier.zig` | Orchestrates the pipeline |
| `src/Config.zig` | JSON config file support + auto-discovery |
| `src/Diagnostic.zig` | Diagnostic messages with codes, locations, JSON serialization |
| `src/Types.zig` | WGSL type system representation |
| `src/Builtins.zig` | Builtin function signatures and uniformity info |
| `src/Validator.zig` | Semantic validation (types, symbols, uniformity) |
| `src/lint/Linter.zig` | Lint orchestrator: resolves config packs + user overrides, runs enabled rules, applies disable comments |
| `src/lint/Rule.zig` | Rule struct + Meta (id, code, category, default_severity, fixable, requires_dce) |
| `src/lint/Context.zig` | Per-invocation state passed to each rule — `report()`, `makeRange()`, `fmt()`, config-resolved severity |
| `src/lint/Disable.zig` | Parses `wgslender-disable[-next-line\|-line\|-file]` comments; filters diagnostics post-lint |
| `src/lint/Fixer.zig` | Applies non-overlapping `Entry.fix` splices to source (ESLint-style) |
| `src/lint/registry.zig` | Comptime `[_]Rule{...}` listing every built-in rule |
| `src/lint/configs.zig` | Shareable packs: @wgslender/recommended, /style, /performance, /portability, /strict |
| `src/lint/walk.zig` | Read-only expression/statement walker — used by rules that scan function bodies |
| `src/lint/rules/` | Individual rule modules (one file per rule, exporting `pub const rule: Rule`) |
| `src/SourceMap.zig` | Source map v3 generation with VLQ encoding |
| `src/Reflect.zig` | Shader reflection and WGSL memory layout computation |
| `src/Compiler.zig` | WGSL → WASM binary shader compiler (BPE + WASM codegen) |
| `src/WasmBinary.zig` | Low-level WASM binary format writer |
| `src/wasm.zig` | WASM entry point (C-ABI exports for JS) |
| `src/lib.zig` | C static library entry point (FFI) |
| `src/root.zig` | Public API |
| `cli/main.zig` | CLI |
| `lsp/main.zig` | LSP server entry point (native, stdio transport) |
| `lsp/wasm.zig` | LSP server WASM entry point |
| `lsp/Handler.zig` | LSP request/notification handler |
| `npm/wgslender` | NPM package |

### Key Design Decisions

**Symbol References (SymbolIndex)**
- `enum(u32)` with `none = maxInt(u32)` as sentinel
- Avoids zero-value bugs — `none` is explicitly the max integer, not zero

**Two-Pass Parser**
- Pass 1: Build AST, declare symbols with `use_count: 0`
- Pass 2: Bind references, increment use counts, mark purity

**External Bindings**
- `@group/@binding` vars marked with `is_external_binding` flag
- Default: Create aliases (`let a = uniforms;`) to preserve API
- With `--mangle-external-bindings`: Rename directly

## Common Tasks

### Adding a New Lint Rule

1. Create `src/lint/rules/<rule>.zig` exporting `pub const rule: Rule = .{ .meta = ..., .run = ... }`.
2. Import it in `src/lint/registry.zig` and add to the `all` array.
3. Add the rule's id to the appropriate pack in `src/lint/configs.zig` (or leave out for opt-in rules).
4. If the rule produces autofixes, set `meta.fixable = true` and attach `Entry.fix` in `run()` — Fixer will splice non-overlapping fixes automatically.
5. If the rule reads `Symbol.is_live`, set `meta.requires_dce = true` so the Linter runs `Dce.mark` before the rule.
6. Register a diagnostic code in `src/Diagnostic.zig` `Code` struct (W02xx for new lint rules).
7. Add unit tests to `tests/lint_rules_test.zig` following the `runLint` + `hasCodeContaining` pattern.
8. If the rule's pack changes, mirror in `npm/wgslender/configs.js` + `configs.d.ts`.

Rules see a `Context` with `.module`, `.source`, `.symbols`, `.arena`, and `.report()`. Rules may use `AstVisit.visit` internally, walk `ctx.module.symbols.items`, or use `src/lint/walk.zig` for expression scans — the Linter doesn't prescribe traversal shape. Severity is config-resolved; `ctx.report()` stamps `code`, `source`, and effective severity automatically.

### Adding a New AST Node Type

1. Add type to `src/Ast.zig`
2. Add parsing in `src/Parser.zig`
3. Add printing in `src/Printer.zig`
4. Add to visit pass if it contains identifiers/types
5. Run `zig build test` — snapshot tests will catch output changes

### Adding a New CLI Flag

1. Add flag parsing in `cli/main.zig` (string matching in `parseArgs`)
2. Add to `src/Config.zig` if it should be in config files (optional field + JSON key)
3. Add to `src/Minifier.zig` Options struct
4. Wire through the pipeline
5. Update `usage_text` in `cli/main.zig`
6. Update README.md

### Debugging Type Renaming Issues

If types like `MyStruct` aren't being renamed:
1. Check `visitType()` is called for the type reference
2. Verify `lookupSymbol()` finds the struct
3. Ensure `printType()` uses `printName(typ.ref)` when `ref.isValid()`

## Test Data

**compute.toys shaders** (`tests/testdata/compute.toys/`):
- Real-world shaders verified working after minification
- Use with `--config configs/compute.toys.json`
- Size reductions: 55-71% typical

**Snapshot tests** (`tests/snapshot_test.zig`):
- Golden file testing for minification output

**Validator tests** (`tests/validation_test.zig`):
- Semantic validation test cases
- Tests for type errors, symbol resolution, uniformity

**Tint tests** (`tests/testdata/tint/`):
- ~7,961 shaders from Google's Dawn Tint project
- Optional — skipped if directory absent

## WGSL Specifics

**Reserved Words**: 120+ words reserved for future use (see `src/Lexer.zig`)

**Not Reserved** (common gotchas):
- `private`, `workgroup`, `uniform`, `storage` - address space keywords, not reserved
- `read`, `write`, `read_write` - access modes

**Nested Comments**: WGSL `/* */` comments nest (unlike C/JS)

**No Hoisting**: Declarations must precede use in text order

**No Recursion**: Functions cannot call themselves

## NPM Package

```javascript
// Node.js
const { initialize, minify } = require('wgslender');
await initialize();
const result = minify(source, { minifyWhitespace: true, minifyIdentifiers: true });

// Browser
import { initialize, minify } from 'wgslender';
await initialize({ wasmURL: '/wgslender.wasm' });
```

**CLI**: `npx wgslender shader.wgsl -o shader.min.wgsl`

## Zig Notes

- Requires Zig master (0.16.x) — install via `zigup master`
- Uses Zig 0.16's `std.process.Init` and `std.Io` APIs for the CLI
- `ArrayListUnmanaged` inits with `.empty` (not `.{}`)
- `SymbolIndex` uses `enum(u32)` with `none = maxInt(u32)`
- All AST nodes use tagged unions
- Arena allocator for all intermediate data — single `deinit` frees everything

## Gotchas

1. **use_count for renaming**: Only symbols with `use_count > 0` get renamed

2. **keepNames for struct fields**: Not needed - fields accessed via `.` operator, not as identifiers

3. **Config auto-discovery**: Walks parent directories for `wgslender.json`, `.wgslenderrc`, `.wgslenderrc.json`

## Binary Shader Compiler

The `compile` subcommand produces a `.wasm` file that generates WGSL at runtime. Uses BPE (byte-pair encoding) for compression with a tiny WASM decoder.

### Architecture

```
WGSL → Lexer → Parser → AST → Renamer/DCE → Sort Declarations → Printer → minified text
                                                                                ↓
                                                                  BPE compress (64 rules)
                                                                                ↓
                                                         BpeVmGen → ~110B WASM decoder
                                                                                ↓
                                                              WasmBinary → .wasm module
```

**Key design**: All WGSL knowledge lives in Zig (compile time). The WASM decoder is a generic BPE expander with zero knowledge of WGSL syntax.

### Key Modules

| Module | Purpose |
|--------|---------|
| `Compiler.zig` | Pipeline: sort declarations → print text → BPE compress → WASM assembly |
| `WasmBinary.zig` | Low-level WASM binary format writer (LEB128, sections, `Emit` instruction helpers) |

### BPE Compression

Byte-pair encoding iteratively replaces the most frequent byte pair with a new byte (0x80+). Up to 64 rules, each stored as 2 bytes (the pair it replaces). The decoder expands rules using a stack.

### Generated WASM Structure

1 function, ~110 bytes code section:
- `generate()→i32`: stack-based BPE expansion, returns WGSL byte length

Memory layout (offsets computed per shader):
```
[0 .. output_len)           Output buffer (WGSL text)
[rules_base .. +N*2)        BPE rules table (N rules × 2 bytes)
[stack_base .. +256)        Expansion stack
[data_start .. +data_len)   BPE-compressed text
```

### Compression-Friendly Minification

Two optional flags improve DEFLATE compression of minified text:

```bash
wgslender --sort-declarations --scope-local-rename shader.wgsl
```

Also available in JSON config:
```json
{"sortDeclarations": true, "scopeLocalRename": true}
```

Both default to `false` for backward compatibility. The `compile` subcommand uses both automatically.

### JS Usage

```javascript
const { instance } = await WebAssembly.instantiate(shaderWasm);
const len = instance.exports.generate();
const wgsl = new TextDecoder().decode(new Uint8Array(instance.exports.memory.buffer, 0, len));
device.createShaderModule({ code: wgsl });
```
