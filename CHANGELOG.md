# Changelog

All notable changes to wgslender are recorded here. The project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] — 2026-05-06

This release synchronizes versions across all artifacts (`build.zig.zon`,
`npm/wgslender`, `npm/wgslender-lsp`) and consolidates the LSP, linter,
and npm wrapper work that landed since 1.0.0.

### Added

- **Linter** (`wgslender lint`): rule-based, ESLint-inspired linter with
  shareable config packs (`@wgslender/recommended`, `/style`,
  `/performance`, `/portability`, `/strict`), per-rule severity overrides,
  autofixes (`--fix`), and `wgslender-disable` comment directives. See
  `src/lint/`.
- **LSP server**: native (stdio) and WASM builds with full coverage of
  hover, definition, references, completion, signature help, call
  hierarchy, rename, code actions, diagnostics, formatting, folding,
  semantic tokens, document symbols, and inlay hints. Multi-threaded
  parsing with debounced incremental reparse.
- **Binary shader compiler** (`wgslender compile`): emits a tiny WASM
  module that decodes a BPE-compressed minified shader at runtime.
- **Reflection** (`wgslender reflect`): bind-group / binding metadata and
  WGSL memory layout computation for use from JS.
- **NPM wrapper**: parameterised test harness covering CJS, ESM, and
  browser-shim entry points; refactored shared `_core.cjs` factory.

### Changed

- Validator split into per-phase modules under `src/Validator/`
  (Declarations, Statements, Expressions, Uniformity).
- LSP codecs lifted into shared `lspkit` + per-feature wire trees, with
  native and WASM adapter directories under `lsp/native/` and `lsp/wasm/`.
- Diagnostic-message parsing replaced with structured `QuickFixHint`
  payload between linter and LSP code actions.

### Infrastructure

- CI builds all four artifacts (CLI, WASM, LSP, LSP-WASM) and runs the
  npm wrapper test suite.
- CI pinned to Zig 0.16.0; tests run on Linux, macOS, and Windows.
- `prepublishOnly` script in `npm/wgslender` rebuilds the CLI and WASM
  before publish to prevent stale bytes shipping.

### Fixed

- **lint W0206 (`require-entry-point-attrs`)**: diagnostic range now
  points at the actual `@compute` attribute instead of
  `attributes.items[0]`. Affects the multi-attribute case where another
  attribute (e.g. `@diagnostic(...)`) precedes `@compute`. **Behavior
  change**: range shifts in that case — surfaces through `validate
  --format json`, lint JSON output, and LSP
  `textDocument/publishDiagnostics`.
- **Linter `fixable_count`**: tally moved below the
  `wgslender-disable*` filter. Diagnostics silenced by an active
  directive no longer inflate the count returned to the npm wrapper,
  the LSP `applyAllFixes` summary, and the CLI. **Behavior change**:
  `fixable_count` shrinks for sources with active disable directives.
- **CLI**: `-o` / `--output` and `--config` now exit with code 1 and a
  clear `error: <flag> requires a value` message when invoked without a
  value. Previously the value silently became `null`, the minifier ran
  with default behavior, and the user's intent was lost. **Behavior
  change**: missing-value invocations now fail loudly.
- **LSP `Position`**: `line` / `character` from inbound JSON are
  bounds-checked against `u32` range. Negative or `> maxInt(u32)`
  values now reject cleanly via `std.math.cast` instead of panicking
  in debug or silently wrapping in release.
- **WASM API**: pack envelope helpers (`wgslender_validate`,
  `wgslender_compile`, `wgslender_lint`, `wgslender_lint_fix`,
  `wgslender_minify_*`) route slice lengths through
  `std.math.cast(u32, ...)` with checked addition. Oversized payloads
  now return `null` (the existing OOM signal) instead of silently
  truncating the header length while `@memcpy` walked the full slice.
- **AST `Decl.interior_pending`**: widened from `i32` to `i64` and
  switched to saturating add. A pathological sequence of incremental
  edits could previously wrap the bias and corrupt every interior span
  on the next absorb. Internal field — no FFI / wire / JSON change.
- **`MinifyRenamer`**: `SymbolSlot` no longer holds a `[]const u8`
  slice into `name_buf`. Names resolve through `name_offsets` on every
  lookup, so any future append to `name_buf` after `assignNames`
  cannot dangle prior names. Pure internal refactor.

## [1.0.0] — initial release

- WGSL minifier (lexer, parser, printer, renamer, DCE).
- Validator with type checking and uniformity analysis.
- CLI (`wgslender`) and NPM package (`wgslender`) with WASM build.
- C static library and FFI header.
- Source map v3 generation.
