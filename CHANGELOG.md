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

## [1.0.0] — initial release

- WGSL minifier (lexer, parser, printer, renamer, DCE).
- Validator with type checking and uniformity analysis.
- CLI (`wgslender`) and NPM package (`wgslender`) with WASM build.
- C static library and FFI header.
- Source map v3 generation.
