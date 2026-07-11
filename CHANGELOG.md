# Changelog

All notable changes to wgslender are recorded here. The project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **Bitwise operators** (`&` `|` `^`): invalid integer operand pairs that the
  validator previously accepted *silently* — mixed-sign (`1i & 1u`),
  width-mismatched (`vec3<i32> & vec2<i32>`), and scalar↔vector combinations —
  now report `E0201` instead of producing a typeless result with no diagnostic.
  Every valid pair keeps its exact result type. Part of routing operator
  type-checking through the shared overload engine.
- **Equality operators** (`==` `!=`): matrix operands (`m == m`) that the
  validator previously accepted *silently* — returning `bool` even though WGSL
  defines equality only on scalars and vectors — now report `E0201`
  ("requires scalar or vector operands"). Scalar/vector equality, including
  `bool` and `vecN<bool>` operands, is unchanged, as is the "requires
  compatible types" wording for mismatched scalar/vector pairs. Part of
  routing operator type-checking through the shared overload engine.
- **Additive operators** (`+` `-`): routed through the shared overload engine,
  fixing two latent bugs in the old checker. (1) `bool` operands
  (`true + true`, `vecN<bool> + vecN<bool>`, and `bool` scalar-broadcast),
  previously accepted *silently* with a `bool` result, now report `E0201` —
  `bool` is not a numeric type. (2) An abstract-integer literal added to a
  float or unsigned vector (`1 + vec2<f32>`, `1 + vec2<u32>`, and the reverse)
  was previously **rejected**: the checker concretized the literal to `i32`
  before broadcasting, so `i32`-into-`f32`/`u32` failed. It now converts the
  literal to the vector's element type per WGSL §8.7, matching other WGSL
  implementations. Valid scalar / vector / same-shape-matrix additions keep
  their exact result types. (The compound form `+=` / `-=` still uses the
  legacy path and is unified in a later change.)
- **Division operator** (`/`): routed through the shared overload engine,
  fixing three latent bugs in the old `commonType`-based checker. (1) `bool`
  operands (`true / true`, `vecN<bool> / vecN<bool>`, and `bool`
  scalar-broadcast), previously accepted *silently* with a `bool` result, now
  report `E0201` — `bool` is not a numeric type. (2) Same-shape matrix division
  (`matCxR / matCxR`), previously accepted *silently* and returning a matrix,
  now reports `E0201` — WGSL defines no matrix division. (3) An abstract-integer
  literal divided with a float or unsigned vector (`1 / vec2<f32>`,
  `1 / vec2<u32>`, and the reverse) was previously **rejected**: the checker
  concretized the literal to `i32` before broadcasting, so `i32`-into-`f32` /
  `u32` failed. It now converts the literal to the vector's element type per
  WGSL §8.7. Valid scalar / vector / scalar-broadcast divisions keep their exact
  result types, and the const division-by-zero diagnostic is unchanged. (The
  compound form `/=` still uses the legacy path and is unified in a later
  change.)
- **Modulo operator** (`%`): routed through the shared overload engine (WGSL
  `%` is the remainder for both integers and floats). The old checker took the
  `commonType` of its operands, so it silently failed — typeless, no
  diagnostic — on every numeric-but-incompatible pair. (1) Mixed-sign
  (`1i % 1u`), int-vs-float, and width- or element-mismatched pairs now report
  `E0201` ("requires compatible types") instead of producing a typeless result.
  (2) Scalar/vector broadcasts, which the old `commonType`-only path never
  handled — `vec3<f32> % 1.0`, and an abstract-integer literal against a float
  or unsigned vector — now resolve per WGSL section 8.7. `bool` and matrix
  operands stay rejected with the unchanged "requires numeric operands"
  wording, and the const modulo-by-zero diagnostic is unchanged. Valid scalar /
  vector / scalar-broadcast moduli keep their exact result types. (The compound
  form `%=` still uses the legacy path and is unified in a later change.)
- **Multiplication operator** (`*`): routed through the shared overload engine —
  completing the binary-operator migration, so every WGSL binary operator now
  resolves its operand shapes through one engine. Multiplication is the richest
  arithmetic operator (scalar, vector, matrix·scalar, matrix·vector,
  vector·matrix, matrix·matrix), and the old `commonType`-based checker had
  several latent bugs, all now fixed. (1) `bool` operands (`true * true`,
  `vecN<bool> * vecN<bool>`, and `bool` scalar-broadcast), previously accepted
  *silently* with a `bool` result, now report `E0201` — `bool` is not numeric.
  (2) An abstract-integer literal multiplied with a float or unsigned **vector**
  (`2 * vec2<f32>`, `2 * vec2<u32>`, and the reverse) was previously
  **rejected**: the checker concretized the literal to `i32` before
  broadcasting. It now converts the literal to the operand's element type per
  WGSL §8.7. (3) The same premature concretization rejected an abstract-integer
  literal times a **matrix** (`2 * mat2x2<f32>` and the reverse); these now
  resolve to the matrix type. (4) **Matrix·matrix** was wrong in *two*
  directions: the checker had no general `matKxR * matCxK -> matCxR` arm, so it
  **rejected** the six valid non-square products (`mat2x3 * mat3x2` …), while
  its same-type fast path **accepted** the undefined non-square same-type
  products (`mat2x3 * mat2x3`, `mat3x2 * mat3x2`), returning a nonsense matrix.
  Both are fixed: the inner-dimension conformance rule (`A.cols == B.rows`) is
  now enforced and the result is `mat(B.cols)x(A.rows)`. Across the real tint
  corpus this eliminates five false-positive `E0201` diagnostics (valid shaders
  previously rejected) with no new false positives and no missed errors. Valid
  scalar / vector / matrix·scalar / matrix·vector / conformant matrix·matrix
  products keep their exact result types. (The compound form `*=` still uses the
  legacy path and is unified in a later change.)
- **Compound assignment** (`+=` `-=` `*=` `/=` `%=` `&=` `|=` `^=` `<<=` `>>=`):
  `v op= e` is defined as `v = v op e`, so its operand shapes now resolve
  through the same shared overload engine (`Operators.binarySigs`) as the binary
  operator `op`, completing Block 2.1 — the compound forms no longer diverge from
  the binary forms migrated above. The old path computed the result with the
  legacy `commonType`-based `Types.*ResultType` helpers and so carried the same
  latent bugs those helpers had, in both directions. Wrongly **accepted**, now
  `E0201`: bool arithmetic (`v += true`), matrix division (`m /= m`), mixed-sign
  bitwise (`i32 &= 1u`), and the undefined non-conformant same-type matrix
  products (`mat2x3 *= mat2x3`). Wrongly **rejected**, now accepted: abstract-
  integer literals broadcast into a float/uint vector or matrix (`vec2f += 1`,
  `mat2x2f *= 2`, `vec3f %= 1.0`, per §8.7) and conformant non-square matrix
  products whose result stores back (`mat2x3 *= mat2x2` → mat2x3). A conformant
  product whose result cannot store back into the target (`mat2x3 *= mat3x2`
  yields mat3x3) now reports the more precise assignability error (`E0200`,
  "result type … is not assignable") rather than a flat operand error (`E0201`):
  the multiplication is well-defined, it is the assignment that fails. Every
  compound assignment on matching concrete scalars/vectors keeps its exact
  behavior. On the tint corpus this eliminates 4 false-positive `E0201`
  diagnostics — valid shaders whose compound-assignment operands (abstract-int
  broadcasts and conformant non-square products) the legacy path wrongly
  rejected — with no true-positive change. The value-dependent post-checks the
  binary `/` `%` `<<` `>>` shells apply (div/mod-by-zero, shift bit width) gate
  const-expression contexts a mutable assignment target is not, so they remain
  unapplied to the compound forms, exactly as before.

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
