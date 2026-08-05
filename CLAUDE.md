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
cd packages/js-npm && npm test                # Run all 4 wrapper variants
cd packages/js-npm && npm pack --dry-run      # Check package contents
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
| `src/Cst.zig` | Concrete syntax tree (green+red) — lossless, trivia-preserving; built by the Parser alongside the AST for the incremental hot path |
| `src/Parser.zig` | Two-pass parser (parse → visit/bind) |
| `src/Ast.zig` | AST nodes (tagged unions), Symbol table, Scope tree |
| `src/AstVisit.zig` | Pass-2 AST visitor run by `Parser` (bind refs, use counts, purity) |
| `src/Printer.zig` | Code generator with minification + syntax optimization |
| `src/Renamer.zig` | Frequency-based identifier renaming |
| `src/RenamePolicy.zig` | Per-pipeline policy for which symbols may be renamed |
| `src/UseCounts.zig` | Per-symbol use counts produced by `AstVisit` Pass 2 (gates renaming) |
| `src/Dce.zig` | Dead code elimination via BFS from entry points |
| `src/Liveness.zig` | Per-symbol liveness bits produced by `Dce.mark` |
| `src/Minifier.zig` | Orchestrates the pipeline |
| `src/MinifySettings.zig` | Minifier-mode settings shared by CLI/LSP/magic-comment scanner |
| `src/MinifyEstimator.zig` | Fast byte-size estimator for minified output |
| `src/MagicComment.zig` | `wgslender-minify-*` per-document magic-comment override layer |
| `src/Pipeline.zig` | Composable processing passes (default list = the Minifier sequence) |
| `src/Config.zig` | JSON config file support + auto-discovery |
| `src/options.zig` | Comptime spec table for configuration options (one source of truth per option) |
| `src/Diagnostic.zig` | Diagnostic messages with codes, locations, JSON serialization |
| `src/Suggest.zig` | Fuzzy "did you mean?" helpers shared by Parser and Validator |
| `src/Types.zig` | WGSL type system representation |
| `src/Builtins.zig` | Builtin function signatures and uniformity info |
| `src/Overload.zig` | Declarative builtin overload signatures + unification solver |
| `src/ConstEval.zig` | Shared const-expression evaluator (`{int,float,bool}` domain, comptime `OverflowMode`, `anytype` resolver); consumed by `Reflect` (full-domain `.wrap` via `eval`) and the `Validator` folder (int-only `.saturate` via `evalIntOnly`, narrowed with `Value.asInt`/`asBool`) |
| `src/Validator.zig` | Semantic validation orchestrator: drives the `src/validator/*` submodules through the fixed `runPhases` sequence, and hosts the shared toolbox they all reach via re-export aliases — loc/range helpers, diagnostic emitters, and the `tryExtractIntValue`/`tryEvalConstBool`/`extractLiteralIntValue` const folders (thin shims over `ConstEval.evalIntOnly`). Type resolution now lives in `src/validator/TypeResolve.zig`; `AnalysisResult` is the retained-state (`Outputs`) surface consumed by the LSP + lint |
| `src/validator/Declarations.zig` | Top-level decls: directives, structs, vars, fn signatures, recursion, entry-point IO |
| `src/validator/Expressions.zig` | Expression type-checking + inference (`checkExpr` family, type constructors) |
| `src/validator/Statements.zig` | Statement validation + control-flow analysis |
| `src/validator/TypeResolve.zig` | Type resolution shared by Declarations & Expressions: `resolveType` + per-kind resolvers (ident/vec/mat/array/ptr/atomic/sampler/texture), `lookupType`, the `vecN`/`matCxR` shorthand parsers, and the `suggestType`/`suggestIdentifier`/`suggestCallable` did-you-mean helpers — all `v: *Validator`, reached via `Validator`'s re-export aliases |
| `src/validator/Uniformity.zig` | Phase 5 uniformity analysis (WGSL §15; E0700–E0703) |
| `src/Incremental.zig` | Incremental reparse driver (LSP fast path) |
| `src/incremental/Splice.zig` | In-place AST/CST splice paths for the incremental hot path |
| `src/incremental/Anchor.zig` | Anchor classification + edit shape for the incremental driver |
| `src/incremental/ScopeMap.zig` | CST↔AST scope-pairing helpers for the incremental hot path |
| `src/incremental/Errors.zig` | Error-list plumbing across the splice boundary |
| `src/StableId.zig` | Reparse-stable, human-readable symbol IDs (find-references / rename) |
| `src/Edits.zig` | Source edits from an analyzed module (byte-offset, transport-independent) |
| `src/lint/Linter.zig` | Lint orchestrator: resolves config packs + user overrides, runs enabled rules, applies disable comments |
| `src/lint/Rule.zig` | Rule struct + Meta (id, code, category, default_severity, fixable, requires_dce) |
| `src/lint/Context.zig` | Per-invocation state passed to each rule — `report()`, `makeRange()`, `fmt()`, config-resolved severity |
| `src/lint/Disable.zig` | Parses `wgslender-disable[-next-line\|-line\|-file]` comments; filters diagnostics post-lint |
| `src/lint/Fixer.zig` | Applies non-overlapping `Entry.fix` splices to source (ESLint-style) |
| `src/lint/registry.zig` | Comptime `[_]Rule{...}` listing every built-in rule |
| `src/lint/configs.zig` | Shareable packs: @wgslender/recommended, /style, /performance, /portability, /minify, /strict |
| `src/lint/span.zig` | Expression source-span helpers (`exprStart`/`exprEnd`) shared by lint rules |
| `src/lint/MultiVisitor.zig` | Multi-listener AST walker — one traversal fans out to N subscribed rules |
| `src/lint/rules/` | Individual rule modules (one file per rule, exporting `pub const rule: Rule`) |
| `src/SourceMap.zig` | Source map v3 generation with VLQ encoding |
| `src/Reflect.zig` | Shader reflection **façade** — public data types (`ReflectResult`, `TypeInfo`, `BindingInfo`, …), the `reflect`/`reflectWithRenamer` driver, binding/entry-point extraction, `renderExprText`; re-exports the three seams below as `Reflect.{Layout,Json,CallGraph}`. Everyone spells `wgslender.Reflect.*` |
| `src/reflect/Layout.zig` | Memory-layout seam: `LayoutComputer` engine + WGSL §6.2.10 size/align rules, `primitive_layouts`, struct/array/`TypeInfo` builders, shorthand parsers, type-to-string (const-expr folding via `src/ConstEval.zig`, wrapping mode). Duplicates the *numeric* rules of `Types.Struct.computeLayout` by design (AST domain vs resolved-`Types.Type` domain — cross-referenced, deliberately not unified) |
| `src/reflect/Json.zig` | JSON-serialization seam: the `write*Json` family, v1/v2 subset filters, `prettyPrint`. Reads only the materialized public structs — wire-pinned by the npm suite |
| `src/reflect/CallGraph.zig` | Call-graph + resource-attribution seam: `buildCallGraph`, body/stmt/expr walkers, `propagateEntryReachability`. Operates on `Ast.Module`; independent of layout and serialization |
| `src/Compiler.zig` | WGSL → WASM binary shader compiler (BPE + WASM codegen) |
| `src/WasmBinary.zig` | Low-level WASM binary format writer |
| `src/wasm.zig` | WASM entry point (C-ABI exports for JS) |
| `src/lib.zig` | C static library entry point (FFI) |
| `src/ffi.zig` | Shared FFI helpers for WASM entry points (`src/wasm.zig`, `lsp/wasm.zig`) |
| `src/api_json.zig` | Shared JSON layer between the C-ABI (`lib.zig`) and WASM (`wasm.zig`) shells |
| `src/root.zig` | Public API |
| `src/constants.zig` | Compile-time tunable limits shared across the pipeline |
| `src/unicode_xid.zig` | Unicode XID_Start / XID_Continue identifier lookups + table-integrity invariants (WGSL identifiers) |
| `src/unicode_xid_data.zig` | Generated XID range tables (rebuilt by `zig build gen-xid`; see `tools/gen_xid.zig`) |
| `cli/main.zig` | CLI |
| `lsp/main.zig` | LSP server entry point (native, stdio transport) |
| `lsp/wasm.zig` | LSP server WASM entry point |
| `lsp/NativeServer.zig` | Native (stdio) callback dispatcher — thin lsp-kit-shaped wrapper that forwards each request/notification into `Handler` and converts Handler↔lsp-kit types; owns the `handler_mutex` and the debounce timer thread |
| `lsp/Handler.zig` | LSP request/notification handler; delegates to `lsp/handler/*` |
| `lsp/handler/` | Per-feature LSP handlers (completion, hover, definition, code_actions, incremental_sync, semantic_tokens, … one file per feature) |
| `lsp/native/` | Native-transport adapters — the per-feature bodies `NativeServer` dispatches into (lifecycle, document_sync, diagnostics, navigation, symbols, editing, code_actions, call_hierarchy, workspace_commands) |
| `lsp/wasm/` | WASM-transport adapters — same per-feature split as `lsp/native/`, but lsp-kit-free: pure Handler calls + manual JSON built from `wire.*`; bound into the `Ctx` by `lsp/wasm.zig` |
| `lsp/wire_root.zig` | Public surface for the manual-JSON codec tree; registered as the single `wire` module (`wire.primitives`, `wire.diagnostics`, …) |
| `lsp/wire/` | Per-feature manual-JSON codecs — pure encoder/decoder pairs, no I/O. Driven directly by the WASM transport; native parity tests use them to assert byte-equivalence with the lsp-kit writers |
| `lsp/lspkit_root.zig` | Public surface for the lsp-kit codec tree; registered as the single `lspkit` module (`lspkit.primitives`, `lspkit.diagnostics`, …) |
| `lsp/lspkit/` | Per-feature bridges between transport-agnostic `Handler` types and lsp-kit's JSON-shaped types — pure functions, no I/O, consumed by the native adapters |
| `lsp/Debouncer.zig` | Idle-debounce bookkeeping for the native timer — pure "fire URI X at time Y" map; re-arming a pending URI replaces its deadline. WASM debounces JS-side and doesn't use it |
| `lsp/uri.zig` | `file://` URI → filesystem path conversion (posix-only, `%XX`-decoding) — used by the native entry to pick a `wgslender.json` discovery root from `workspaceFolders`/`rootUri` |
| `packages/js-npm` | NPM package |

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
8. If the rule's pack changes, run `zig build gen-npm` to regenerate `packages/js-npm/configs.js` + `configs.d.ts` from `src/lint/configs.zig` (do **not** hand-edit them — `tests/npm_generated_test.zig` byte-compares them against the generator and fails with "run `zig build gen-npm`" on drift), then commit the regenerated files.

Rules see a `Context` with `.module`, `.source`, `.symbols`, `.arena`, and `.report()`. A rule is either a **listener** (a pure per-node observer folded into one shared `MultiVisitor.walk`) or a **run** pass (table scans over `ctx.module.symbols.items`, subtree folds, block-sequential or context-sensitive walks); see the taxonomy in `src/lint/MultiVisitor.zig`. Either style may use `src/lint/span.zig` for expression positions — the Linter doesn't prescribe traversal shape. Severity is config-resolved; `ctx.report()` stamps `code`, `source`, and effective severity automatically.

### Adding a New AST Node Type

1. Add type to `src/Ast.zig`
2. Add parsing in `src/Parser.zig`
3. Add printing in `src/Printer.zig`
4. Add to visit pass if it contains identifiers/types
5. Run `zig build test` — snapshot tests will catch output changes

### Adding a New Value Constructor Form

Constructor validation (`f32(x)`, `vec3<f32>(...)`, `mat2x2f(...)`, `S(...)`, `array<f32,4>(...)`) resolves through the overload engine, not a hand-rolled switch:

1. Emit the target's overload set in `Overload.ctorSigsFor` (`src/Overload.zig`) — one arm per target kind (scalar/vector/matrix/struct/array).
2. Constructor-only shapes are `Pattern` variants: `variadic_components_to_width` (vector composition), `all_scalar_or_all_vector` (matrix scalar/column dichotomy), `composite_convert` (explicit vecN/matCxR copy/convert, §16.2.2).
3. The call site is `checkTypeConstructor` → `ctorViaEngine` (`src/validator/Expressions.zig`): resolves via `Overload.resolveTargetedRefined`, and on failure `ctorRefine` reproduces the specific per-family diagnostic.
4. Exact error wording + positions are pinned by `tests/validation_location_test.zig` — add a case there for any new message (and re-run the `-j1` full suite; the corpus/tint suites are memory-heavy and flake under concurrent `zig build test`).

### Adding a New CLI Flag

A flag is one `OptionSpec` row in `src/options.zig` plus a matching field on
each target struct — the spec table is the single source of truth that
derives the JSON key, the CLI flag, and the help line. Hand-rolled arg
matching and `usage_text` edits are only for outliers.

1. Add the field to the target struct(s): `Minifier.Options` (snake_case),
   and `src/Config.zig` as `?T` if it belongs in `wgslender.json`.
2. Add one row to the matching table in `src/options.zig`
   (`minifier_options_specs` / `source_map_specs` / `lint_specs` /
   `lsp_toggle_specs`). The row derives the camelCase JSON key, the
   `--kebab` CLI flag (via `dispatchSpecFlag` in `cli/main.zig`), and — from
   a non-empty `summary` — the `--help` line (via `printHelp`). Scope it with
   `.subcommands`.
3. `zig build` — the `assertSpecFieldsExist` comptime guards in `Config.zig`
   and `Minifier.zig` fail the build if the spec row and the struct field
   disagree in name or type.
4. Read the field where it takes effect (the relevant `Minifier` / pipeline
   pass).
5. CLI outliers only: a flag that doesn't fit the derived `--flag` /
   `--no-flag` shape (e.g. the tri-state `--minify*` cluster) still needs
   hand-rolled parsing in `cli/main.zig` and a help line in
   `usage_minify_outliers`; mark its spec `.cli_simple = false` (an empty
   `summary` also opts it out of `printHelp`).
6. Update tests and README.md; if the npm API exposes the option, mirror it
   in the package's TypeScript types (`packages/js-npm/*.d.ts`). A new
   `minifier_options_specs` row also feeds `lspSettingsSchema` — run `zig
   build gen-npm` to regenerate `configs.{js,d.ts}` (see the lint-rule step 8
   note; the freshness test enforces it).

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
- 11,952 WGSL shaders from Google's Dawn Tint project (`test/tint` sparse checkout), pinned to the dawn revision in `scripts/tint-testdata.rev`
- Semantic-preservation test (`tests/tint_test.zig`, `zig build tint-test`) exercises all 11,952 (8,114 run; f16/subgroups/`diagnostic(...)` shaders skipped)
- Two validator goldens produced by one walk (`tests/inference_corpus_pinning_test.zig`) over 9,399 processed shaders (2,553 excluded):
  - `tests/inference/corpus_golden.txt` — per-code diagnostic histogram
  - `tests/inference/triage_golden.txt` — that histogram split by Tint's own verdict into fp/tp/unk (`tests/tint_oracle.zig` classifies each shader's sibling `.expected.wgsl`; fp = a code we emit on a shader Tint accepts = false-positive candidate)
- Triage tool (`tools/tint_triage.zig`): `zig build tint-triage -- --code E0200 --bucket fp [--max-per-code N]` prints a `path<TAB>line:col<TAB>message` false-positive worklist; `-- --tsv report.tsv` writes a per-shader report; no args prints the summary table. Reports only; the golden test is the gate.
- Regenerate both goldens after an intentional change: `rm tests/inference/corpus_golden.txt tests/inference/triage_golden.txt && zig build test`
- Bump the pinned corpus: edit `scripts/tint-testdata.rev`, then `rm -rf tests/testdata/tint tests/inference/corpus_golden.txt tests/inference/triage_golden.txt && ./scripts/fetch-tint-testdata.sh && zig build test`, and commit the rev + both goldens together
- Optional — all corpus tests self-skip if the directory is absent

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

- Requires Zig 0.16.0 — install via `zigup 0.16.0` (pinned in `build.zig.zon` `minimum_zig_version`)
- Uses Zig 0.16's `std.process.Init` and `std.Io` APIs for the CLI
- `ArrayListUnmanaged` inits with `.empty` (not `.{}`)
- `SymbolIndex` uses `enum(u32)` with `none = maxInt(u32)`
- All AST nodes use tagged unions
- Arena allocator for all intermediate data — single `deinit` frees everything
- **Reserve `usize` for slice indexing and platform-word-sized math.** Use
  `u32` for shader-bounded counts and offsets (token indices, symbol
  indices, byte offsets in source / WASM) — they fit by construction and
  match `Diagnostic.Position`'s wire format. Use `u8` for vec width / mat
  cols/rows (already enforced by `Types.zig`).

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
