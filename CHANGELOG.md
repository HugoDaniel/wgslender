# Changelog

All notable changes to wgslender are recorded here. The project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] — 2026-08-09

### Added

- **Lint autofixes as editor quickfixes.** Fixable lint rules
  (`no-redundant-casts`, `no-useless-return`, `prefer-mix`, `no-self-assign`,
  `prefer-let-over-var`, `no-f16-without-extension`) previously showed a
  squiggle with no 💡 — their `Entry.fix` rewrite was only reachable through
  `lint --fix`. The LSP diagnostics bridge now converts the fix into a
  `lintFix` data payload (LSP coordinates), both transports round-trip it,
  and the code-action engine offers an `Apply autofix (CODE)` quickfix
  carrying the exact edit the CLI fixer applies. Wire note: diagnostics for
  fixable rules now include a `data` object with `kind: "lintFix"` — clients
  that ignore unknown `data` shapes are unaffected.

- **npm `minifyAndReflect(source, options?)`.** Wires the existing
  `wgslender_minify_and_reflect` WASM export (previously reachable only from
  Zig/C-ABI) into `_core.cjs` and all four JS entry shims. Returns
  `{ minify: MinifyResult, reflect: ReflectResult }` from a single WASM call
  that shares one parsed module and renamer, so `reflect`'s names are
  guaranteed consistent with `minify`'s output without a second parse. No
  WASM rebuild — the export already existed.
- **`wgslender/constInventory` LSP request + `Reflect.constInventory`.** A new
  WASM-LSP custom request (and the `Reflect.constInventory(arena, module) →
  []ConstInfo` façade behind it) surfaces every module-scope `const` with its
  name, scalar type, initializer text, declaration span, and a `liftable`
  flag. `liftable` is `false` when the const is referenced from a
  const-required position — an array element count, `@workgroup_size`,
  `const_assert`, a symbol-bearing attribute argument, an `override`
  initializer, or (transitively) another const whose value is itself
  const-required — so a consumer can tell which compile-time constants can be
  promoted to runtime uniforms without invalidating the module. Result shape:
  `{ uri, consts: [{ name, typ, value, liftable, span: { start, end } }] }`.
  Function-body positions are not scanned yet (v1). No WASM export or reflect
  wire change — the request rides the existing wasm LSP transport.
- **npm CLI `lint` and `compile` subcommands.** `npx wgslender lint [file]`
  and `npx wgslender compile -o out.wasm [file]` now work — previously both
  fell through to `minify` (`compile` even wrote minified WGSL text to the
  `-o` path instead of a `.wasm` binary). `lint` mirrors the native config/CLI
  merge (`--extends` / `--rule` / `--no-recommended` / `--fix`, `@wgslender/
  recommended` by default) and exits non-zero only on errors; `compile`
  reports syntax errors to stderr and exits 1 without writing output. No WASM
  rebuild — both call the existing `wgslender_lint` / `wgslender_compile`
  exports.
- **Generated npm config mirrors.** `packages/js-npm/configs.{js,d.ts}` are now
  generated from the Zig source of truth by `zig build gen-npm` (pack tables
  from `src/lint/configs.zig`, `lspSettingsSchema` minifier knobs from
  `src/options.zig`), and a freshness test (`tests/npm_generated_test.zig`)
  byte-compares the committed files against the generator so they can no
  longer drift silently. Fixing that drift, `wgslender/configs` now exports
  the advisory `@wgslender/minify` pack (its rules use `hint` severity), which
  was previously missing from the hand-maintained mirror.

- **One version line across every package, and a release script.**
  `zig build gen-version` stamps `src/root.zig`'s `pub const version` into
  every manifest (`build.zig.zon`, three `package.json`, and all four
  occurrences in `packages/rust/Cargo.toml`), with
  `tests/version_sync_test.zig` failing on drift.
  `zig build release-assets` (was `vscode-assets`, kept as an alias) writes
  both WASM modules into all five in-tree destinations from a single build.
  `./scripts/release.sh` runs the whole thing — stamp, rebuild, the Zig, Go,
  Rust and npm suites, a dependency-drift report — and ends with
  `git diff --exit-code`: because both WASM builds are byte-reproducible, a
  tree that moved means what was committed was stale.

### Changed

- **Go module path moved to GitHub (⚠ breaking for Go consumers).** The module
  was `git.hugodaniel.com/hugo/wgslender/packages/go`, which only resolved
  against the self-hosted remote. It is now
  `github.com/HugoDaniel/wgslender/packages/go`, so
  `go get github.com/HugoDaniel/wgslender/packages/go/wgslender` works against
  the public mirror. Existing importers must update their import paths; the
  package API itself is unchanged. Code emitted by `wgslgen` imports only the
  standard library and is unaffected.
- **`npm/wgslender-lsp` ships 137 commits of accumulated LSP work (⚠ behavior).**
  Its committed `wgslender-lsp.wasm` had gone stale since 2026-05-06: nothing
  in `build.zig` wrote to that directory and the package had no build script,
  so every LSP change since then was absent from the published package.
  Wire-visible among them: the new `wgslender/constInventory` request,
  semantic-token lengths corrected to UTF-16 code units, semantic tokens
  resolved via `NodeAtOffset` instead of whole-module name match, signature
  help backed by real builtin/function signatures, diagnostics carrying every
  configured lint pack rather than `@wgslender/minify` alone, the per-file
  lint result object, control bytes escaped in diagnostic JSON, and the new
  `E0700`–`E0703` uniformity codes. `zig build release-assets` now writes this
  copy, so it cannot recur.
- **`packages/rust` 0.1.0 → 1.1.0 (⚠ behavior).** The four crates join the
  shared version line. A `1.x` number is a semver promise of API stability;
  the crates are unpublished, so nothing breaks today, but breaking changes
  after the first publish will require `2.0.0`.
- **`npm/wgslender-vscode` 0.1.0 → 1.1.0 (⚠ behavior).** The extension's
  marketplace version joins the shared line and moves with core releases
  whether or not the extension itself changed.
- **LSP `serverInfo.version` is derived, not hardcoded.** Both transports read
  `wgslender.version` instead of a hand-edited literal. No observable change —
  both literals already read `1.1.0` — but the LSP can no longer misreport
  which build it is.
- **npm package moved to `packages/js-npm/`** (was `npm/wgslender/`). Published
  package name (`wgslender`) and public API are unchanged; only the in-repo
  path moved, so this affects local dev commands (`cd packages/js-npm && npm
  test`) and the `wgslender-vscode` extension's local `file:` dependency, not
  npm consumers.
- **Lint JSON schema (⚠ behavior):** the WASM/C-ABI `lint` / `lintAndFix`
  JSON payload changed from a bare diagnostics array `[...]` to a canonical
  per-file result object
  `{"diagnostics":[...],"errorCount":N,"warningCount":N,"fixableCount":N}`.
  The `WgslenderLintResult`/`WgslenderLintFixResult` C extern structs are
  unchanged (their `error_count`/`warning_count` u32s stay authoritative);
  `fixableCount` is new and rides only in the JSON. The npm `LintResult` /
  `LintFixResult` now expose `fixableCount`. The `wgslender lint --format
  json` CLI output is **unchanged** — its ESLint-style
  `{"results":[{"filePath",...}],...}` envelope now wraps the same shared
  object. The npm shipped wasm was rebuilt to match.
- **Compile diagnostics (⚠ behavior):** the `compile` artifact now surfaces
  syntax errors as real diagnostics instead of masking them. Previously a
  malformed shader made `Compiler.compile` return `error.OutOfMemory` (a CLI
  crash) and the JSON surface (WASM/C-ABI `compile`) collapsed every failure
  to `[{"message":"compile failed"}]`. Now `CompileResult` carries an
  `errors` list (mirroring `Minifier.Result`); the JSON `errors` array holds
  positioned diagnostic entries (`severity`/`message`/`code`/`line`/`column`),
  the same shape as validation; and `wgslender compile` prints those
  diagnostics to stderr and exits 1 **without writing an output file**. A real
  OOM still propagates. The npm `CompileResult.errors` type widens from
  `{ message }[]` to `DiagnosticInfo[]`.

### Infrastructure

- **`external/` is no longer a set of git submodules.** Eight reference
  checkouts (gpuweb, eslint, vscode-extension-samples, naga, wgsl-analyzer,
  wgsl_reflect, lsp-client, lsp-kit) were tracked as submodules, so a
  `git clone --recursive` pulled several hundred MB of unrelated projects to
  build a WGSL minifier. They are kept for reading, not building, and are now
  gitignored — clone whatever you want to read into `external/`. The one
  script that consumed a checkout, `tests/cross_check.sh`, is manual, already
  exits 2 when it is absent, and now prints the clone command.

### Fixed

- **`zig build lsp` works from a release tarball.** lsp-kit was a `.path`
  dependency on a git submodule, and `git archive` — the basis of every
  GitHub source tarball — emits submodules as empty directories. Anyone
  building the LSP from a released archive got a missing-file error. It is
  now fetched by `.url` + `.hash`, pinned to the same upstream commit the
  submodule tracked. The submodule additionally carried a local one-line
  patch raising `@setEvalBranchQuota` inside lsp-kit's `MessageType`; that
  quota is a property of the comptime evaluation, so it now lives at our
  own instantiation site in `lsp/main.zig` and lsp-kit is unmodified
  upstream.
- **Format Document is content-preserving.** The LSP formatter ran the
  minifier pipeline with only whitespace/identifier minification disabled, so
  tree shaking silently *deleted* any declaration not yet reachable from an
  entry point, and syntax minification respelled literals (`1.0` → `1.`).
  Both are now off in the formatting path; formatting can never change what a
  document contains.
- **Settings changes refresh pull diagnostics (both LSP transports).** The
  server republished on the push channel after a `workspace/configuration`
  response, but VS Code consumes the pull model — stale pull results lingered
  until the next edit, so turning a lint rule off (`rules`), disabling
  diagnostics, or toggling `lsp.minifyMode` looked like it did nothing. Both
  transports now send `workspace/diagnostic/refresh`,
  `workspace/inlayHint/refresh`, and `workspace/codeLens/refresh` after
  applying a configuration response.
- **VS Code reflection sidebar rendered an error for every shader.** The
  provider `JSON.parse`d the `wgslender/reflect` payload, but both transports
  put it on the wire as a structured object — the parse threw and the view
  showed `Errors (1)` unconditionally. Same trap the reflect palette command
  already documents; the sidebar predated that fix.
- **VS Code minify status bar reacted to a settings section that doesn't
  exist** (`wgslender.minify`), so toggling `wgslender.lsp.minifyMode` never
  showed/hid the item until an editor switch. It now watches the whole
  `wgslender` section and computes the size with the user's configured minify
  options, so the number always matches what *Save Minified As* writes.
- **VS Code compile command ran without `sortDeclarations` /
  `scopeLocalRename`.** `cfg.get(key, true)` can never return `true` when
  `package.json` declares the key `default: false` — the manifest default
  wins over the code fallback — so the command silently diverged from the CLI
  `compile` subcommand (which always applies both before BPE). The
  compile-only defaults now resolve through `inspect()` and only an explicit
  user setting overrides them.
- **A lone surrogate no longer kills document sync in the VS Code
  extension.** `JSON.stringify` escapes an unpaired surrogate as `\ud800`,
  the Zig `std.json` parser inside the LSP wasm rejects the message, and the
  drop was silent — from then on every answer came from stale text. Both the
  in-process transport and the web Worker now replace lone-surrogate escapes
  with U+FFFD (same UTF-16 length, so incremental edit ranges stay aligned).
- **The three declared-but-inert VS Code settings now work.**
  `wgslender.lint.fixOnSave` applies the engine's `lintAndFix` as a save
  participant (the CLI's `lint --fix`); `wgslender.format.enable: false`
  actually disables formatting (client middleware); `wgslender.validate.strict`
  escalates warning diagnostics to errors on both the push and pull channels
  (the CLI's `validate --strict`). All three were advertised in the manifest
  and README but consumed nowhere.

- **Out-of-memory honesty (validator):** the type-resolution and
  constructor-inference paths no longer swallow allocation failures.
  `resolveType` / `lookupType`, the `resolve*Type` helpers, the vector/matrix
  shorthand parsers, and the bare-constructor element inference
  (`inferGenericCtorElement` / `inferArrayCtorType` / `ctorViaEngine`)
  previously returned `null` on OOM — indistinguishable from a genuine "type
  not found" — so under memory pressure a *valid* shader could be reported
  invalid with a fabricated diagnostic. These paths now surface
  `error.OutOfMemory`, which the validator propagates. Diagnostic *emission*
  stays best-effort by documented contract (`fmtError` degrades to the raw
  format string; `Diagnostic.add` drops the entry on OOM) but is verdict-safe:
  a dropped error still marks the result invalid, so OOM can never flip an
  invalid shader to valid. JSON / C-ABI / WASM surfaces are unaffected.
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
- **Unary operators** (`-` `!` `~`): the three unary *value* operators now
  resolve their operand shape through the same shared overload engine
  (`Operators.unarySigs`) as the binary and compound-assignment forms,
  completing Block 2.1 — every WGSL value operator, unary and binary, now
  shares one resolver. `!` (logical not — `bool` scalar / vector) and `~`
  (bitwise not — integer scalar / vector) were already spec-correct and are
  behavior-preserving. Unary minus `-` had one latent bug: the old checker
  gated on `isNumeric`, which admits `u32`, so `-1u` and `-vecN<u32>` were
  wrongly **accepted**, returning the unsigned type — but WGSL §8.6 defines no
  negation for unsigned integers. They now report `E0201`. The neg failure
  message is reworded from "requires numeric type" to "requires a signed
  numeric type": the old phrasing was self-contradictory on the newly-rejected
  `u32` operand (`u32` *is* numeric; it is not *signed*), and the new wording
  is accurate for every neg failure (unsigned, bool, and matrix operands
  alike). `!` and `~` keep their exact wording (pinned by
  `validation_range_test`). No tint-corpus diagnostics change from this
  migration. `*` (deref) and `&` (address-of) manipulate pointers / references,
  are not overloads over value types, and keep their hand-rolled checks.

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

- **⚠ Zig API:** `Validator.Result.deinit` and `Validator.AnalysisResult.deinit`
  no longer take an allocator argument (`result.deinit(gpa)` → `result.deinit()`).
  The parameter was vestigial — both results own an internal arena and ignored
  it. The `validate` / `analyze` family may now also return `error.OutOfMemory`
  where a memory-starved run previously "succeeded" with a corrupted verdict
  (see the resolveType OOM-honesty fix). JSON / C-ABI / WASM surfaces are
  unaffected.
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
