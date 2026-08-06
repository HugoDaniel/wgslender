# Plan — `packages/go/`: a pure-Go package for WGSLender

**Creates:** `packages/go/` — a Go module wrapping the wgslender WASM build via
[wazero](https://github.com/tetratelabs/wazero) (a zero-dependency, pure-Go WebAssembly
runtime). No cgo, no Zig toolchain for consumers: the module `go:embed`s the same
`wgslender.wasm` the npm package ships and is `go get`-able from any platform Go
supports. It lives beside `packages/js-npm/` and `packages/rust/`.

Also creates `cmd/wgslgen`, a `go:generate`-able codegen tool — the Go analog of the
Rust `include_wgsl!` / `include_wgsl_compressed!` / `wgsl_module!` macros (Go has no
compile-time macros; `go generate` + golden files is the idiom).

**Status:** ready to execute, block-per-session. Verified against `main @ a0f890f`,
2026-08-06, macOS arm64, go 1.26.5, zig 0.16.0. Working tree at planning time had
unrelated dirt (`src/reflect/CallGraph.zig`, `tests/reflect_test.zig`, `docs/obsidian/`
untracked) — none of it touches this plan's inputs.

**Why wazero and not cgo:** Go has no `build.rs`. A cgo binding cannot run `zig build
lib` at `go build` time, so it would need prebuilt `libwgslender.a` per platform
checked in or downloaded — the exact vendoring decision that deferred the Rust
crates.io publish (`packages/rust/README.md § Publishing`). The wasm route dissolves
the problem: one 766 KB artifact, every GOOS/GOARCH, `CGO_ENABLED=0` friendly.
Cost: wasm-interpreter/JIT speed instead of native — fine for a minifier; a cgo
fast-path can be added later behind a build tag if a profile ever demands it
(**explicitly deferred**, see § Deferred).

---

## Verified current state (do not re-derive)

### Environment

- `go version go1.26.5 darwin/arm64` at `/opt/homebrew/bin/go`. `golangci-lint` and
  `gofumpt` are **not** installed — the mandatory gate uses `gofmt`/`go vet`/`go test
  -race` only; golangci-lint is an opt-in target that fails loudly when missing
  (mirrors `cargo xtask msrv`'s "a check that did not run has not passed").
- wazero latest is **v1.12.0** (checked via module proxy 2026-08-06). Still v1 —
  Go-1-style compatibility promise holds.
- git remote: `https://git.hugodaniel.com/hugo/wgslender.git` (self-hosted; serves
  `?go-get=1` meta tags if it's Gitea/Forgejo — untested, see § Deferred: publishing).
  Repo is not pushed; consumers today use the module in-repo.

### The wasm artifact and its ABI (empirically probed with wazero v1.12.0, this session)

- `packages/js-npm/wgslender.wasm`: **766,743 bytes**, byte-identical to current
  `zig-out/bin/wgslender.wasm`. Built by `zig build wasm` (`build.zig:48-66`):
  `wasm32-freestanding`, `ReleaseSmall` (hardcoded on the module — `-Doptimize=` flags
  do not reach it), `entry = .disabled`, `rdynamic = true`.
- **Zero imports.** No WASI, no `env`, no start function. wazero instantiates it with a
  plain `wazero.NewModuleConfig()` and nothing else. Verified end-to-end this session:
  `wgslender_version` / `wgslender_version_len` through wazero returned `"1.1.0"` read
  from linear memory.
- Exports: one memory (`memory`) + 23 functions, all-i32 params/results
  (`src/wasm.zig`, all `callconv(.c)`):

```
wgslender_alloc(len) -> ptr                 // 0 = OOM
wgslender_dealloc(ptr, len)
wgslender_minify_json(src, src_len, opts, opts_len) -> ptr
wgslender_minify_and_reflect(src, src_len, opts, opts_len) -> ptr
wgslender_validate(src, src_len, flags) -> ptr        // flags bit0 = strict
wgslender_reflect(src, src_len) -> ptr
wgslender_compile(src, src_len, opts, opts_len) -> ptr
wgslender_lint(src, src_len, cfg, cfg_len) -> ptr
wgslender_lint_fix(src, src_len, cfg, cfg_len) -> ptr
wgslender_find_references(src, src_len, offset, include_decl) -> ptr
wgslender_rename(src, src_len, offset, name, name_len) -> ptr
wgslender_rename_apply(src, src_len, offset, name, name_len) -> ptr
wgslender_stable_id_at_offset(src, src_len, offset) -> ptr
wgslender_locate_stable_id(src, src_len, id, id_len) -> ptr
wgslender_locate_declaration(src, src_len, id, id_len) -> ptr
wgslender_locate_type(src, src_len, id, id_len) -> ptr
wgslender_rename_by_id(src, src_len, id, id_len, name, name_len) -> ptr
wgslender_remove_declaration_by_id(src, src_len, id, id_len) -> ptr
wgslender_remove_declaration_apply_by_id(src, src_len, id, id_len) -> ptr
wgslender_change_type_by_id(src, src_len, id, id_len, type, type_len) -> ptr
wgslender_change_type_apply_by_id(src, src_len, id, id_len, type, type_len) -> ptr
wgslender_version() -> ptr                  // STATIC pointer — never dealloc
wgslender_version_len() -> len
```

Note: the wasm surface has **no bitflag minify** (the C ABI's `wgslender_minify_c`
fast path is C-only); everything goes through JSON options. The wasm `version` split
(`version` + `version_len`) also differs from the C header's out-param form.

### Handshake (mirrors `packages/js-npm/lib/_core.cjs`; every rule below is load-bearing)

1. Compile the module once; instantiate with an empty config. Nothing to call at
   instantiate time.
2. Inbound strings: `ptr = wgslender_alloc(max(len,1))` — **empty string allocates 1
   byte but passes `len = 0`**, and the eventual `dealloc` must use the *allocation*
   length `max(len,1)`. Copy raw UTF-8, no NUL (the Zig side re-copies with a sentinel
   via `api_json.makeSentinelSource`). `alloc` returning 0 = OOM.
3. Call the op. **Re-read `Memory()` after every call** — the wasm side allocates and
   memory can grow mid-call, invalidating prior views (`_core.cjs` rebuilds its
   `DataView` after each call for exactly this reason; in wazero, call
   `mod.Memory().Read` fresh each time and copy out before the next call).
4. Free every input buffer immediately after the call: `wgslender_dealloc(ptr,
   allocLen)`.
5. Result `0` = operation-level failure (OOM / u32 overflow) — the **only** ABI-level
   error channel. All semantic failures (parse error, symbol not found…) arrive inside
   the JSON envelope with a non-null pointer.
6. Read the little-endian `u32` header(s) at the result pointer, copy payloads out,
   then free the envelope with the **exact** total (Zig's `ffi.freeBuf` does
   `wasm_allocator.free(ptr[0..len])` — a wrong length is UB in the allocator):

| producer | layout | dealloc length |
|---|---|---|
| `packLenPrefixed` — minify_json, minify_and_reflect, reflect, all 12 refactor ops | `[u32 json_len][json]` | `4 + json_len` |
| `packValidate` | `[u32 valid][u32 err_count][u32 warn_count][u32 json_len][json]` | `16 + json_len` |
| `packLint` | `[u32 err_count][u32 warn_count][u32 json_len][json]` | `12 + json_len` |
| `packLintFix` | `[u32 fixed_len][u32 err][u32 warn][u32 json_len][fixed][json]` | `16 + fixed_len + json_len` |
| `packCompile` | `[u32 wasm_len][u32 orig_size][u32 err_json_len][wasm][err_json]` | `12 + wasm_len + err_json_len` |
| `version` | raw static bytes | **never dealloc** |

Envelopes are allocated from `wasm_allocator` (not the per-call arena) so they survive
the call; the host owns them. Not freeing = permanent leak inside linear memory (the
module never shrinks).

7. One instance = one single-threaded allocator. **Not goroutine-safe** — serialize
   calls per instance (JS gets this for free; Go must enforce it).

### Wire contracts (from the Zig writers — `src/api_json.zig`, `src/Diagnostic.zig`,
### `src/reflect/Json.zig`; the npm `main.d.ts` lies in places, encode from Zig)

Options JSON (camelCase; keys derived from `src/options.zig` spec table):

- minify/minify_and_reflect/compile: `minifyWhitespace, minifyIdentifiers,
  minifySyntax, treeShaking, mangleExternalBindings, preserveUniformStructTypes,
  keepNames: [string], sortDeclarations, scopeLocalRename, sourceMap,
  sourceMapSources` (booleans unless noted). Zig defaults when absent:
  whitespace/identifiers/syntax/treeShaking **true**, everything else **false**,
  keepNames empty. **`{}` (or empty buffer) = wgslender's own defaults** — options
  are overrides. Malformed options JSON **silently degrades to defaults**.
  `compile` forces sortDeclarations + scopeLocalRename on internally.
- lint/lint_fix config: `extends: ["@wgslender/…"]`, `rules: {id: "off"|"warn"|
  "error" | ["warn"|"error", {opts}]}` (**object only** — an array is silently
  ignored), `reportUnusedDisableDirectives: bool`. **`{}`/empty = run NO rules** —
  the opposite convention from minify. Unknown rule ids are silently ignored.
- validate takes a `u32` flag word (bit0 strict), find_references a `0|1` int.

Response envelopes:

- minify: `{"code","errors":[{"message"}],"originalSize","minifiedSize"[,"sourceMap"]}`
  — minify errors are `{message}` **objects with no line/column**. On parse errors the
  minifier returns the **original source unchanged** plus errors.
- minify_and_reflect: `{"minify":{…},"reflect":{…}}` — minify errors are objects,
  reflect errors are **bare strings** (asymmetric; flatten both to `[]string` like
  Rust does).
- validate: `{"valid","diagnostics":[…],"errorCount","warningCount"}` — the binary
  header duplicates valid/counts; trust the header for counts like npm does, or the
  JSON like Rust does — pick ONE and test it (this plan: header, it's already parsed).
- lint: `{"diagnostics":[…],"errorCount","warningCount","fixableCount"}` —
  diagnostics = analysis (parser/validator) entries **first**, then lint entries;
  `errorCount` = analysis errors + lint errors but **`warningCount` is lint-only**;
  lint-rule entries carry `"source":"wgslender-lint"`. lint_fix's report describes the
  **input**, and its `fixed` buffer is the rewritten source.
- compile: binary wasm + a **bare JSON array** of diagnostics (validate's entry
  shape), non-empty exactly when the source did not parse; `originalSize` = input
  size. The produced module has zero imports and exports `memory` + `generate() ->
  i32` (writes WGSL at offset 0, returns its length).
- diagnostics (single source of truth, `src/Diagnostic.zig:193-257`):
  `{"severity","message"[,"code"],"line","column"[,"specRef"][,"related":[{line,
  column,message}]][,"source"][,"fix":{"range":{startLine,startColumn,startOffset,
  endLine,endColumn,endOffset},"text"}]}` — line/column **1-based**, severity ∈
  `error|warning|info|note|hint|unknown`, **no top-level endLine/endColumn** (only
  inside `fix.range`), codes look like `E0100`/`W0001`/`M0500` and are omitted when
  empty.
- reflect v2 (`src/reflect/Json.zig:36-103`): `{"version":2,"bindings","uniforms",
  "storage","textures","samplers","structs","entryPoints","overrides","functions",
  "aliases"[,"errors"]}`. Wire facts the npm .d.ts gets wrong: texture TypeInfo is
  **flat** `{kind:"texture",dim,texKind[,format][,access][,sampleType]}`; ArrayInfo's
  nested key is **`array`** (not `nested`); entry-point input/output fields are
  **omitted when absent**, not null. TypeInfo kinds: scalar, vec, mat, array, struct,
  atomic, sampler, texture, ptr.
- refactor: edits `{"edits":[{"start","end","newText"}][,"error"]}`; apply
  `{"ok","source","edits"[,"error"]}` (failure echoes the original source);
  references `{"references":[{"start","end","isWrite"}][,"error"]}` (no symbol ⇒
  empty list, **no error** — deliberate, an editor can probe blindly); stable-id
  `{"stableId":"v1:…"|null[,"error"]}`; locate `{"start":N,"end":N}` or
  `{"start":null,"end":null,"error":"…"}` where the literal `"not found"` (or no
  error) means "absent", anything else is a real failure. All offsets are **UTF-8
  byte offsets**.
- Exact wire error strings (pin these; they are the sentinel-error contract):
  `"parse error"`, `"symbol not found"`, `"invalid identifier"`, `"not found"`,
  `"id too long"`, `"not a removable declaration"`,
  `"no type annotation or invalid replacement"`.

### Sibling API surfaces to mirror

- npm exports (all sync after `initialize()`): minify, compile, reflect,
  minifyAndReflect, getBindGroups, validate, lint, lintAndFix, findReferences,
  rename, renameApply, stableIdAtOffset, locateStableId, locateDeclaration,
  locateType, renameByStableId, removeDeclarationByStableId,
  removeDeclarationApplyByStableId, changeTypeByStableId, changeTypeApplyByStableId,
  getVersion/version, initialize/isInitialized.
- Rust (`wgslender-core`): version, minify, minify_with, minify_and_reflect,
  validate, lint, lint_fix, reflect, reflect_json, compile + `refactor::` with the 12
  ops; `Error` enum {Internal, InvalidUtf8, Wire, SourceTooLarge, Compile(Vec<Diagnostic>),
  Refactor(RefactorError)}; philosophy: *a shader's own problems are data; a failed
  call is an `Err`*; forward-compat: unknown wire spellings decode to `Unknown`, all
  wire types `#[non_exhaustive]`.
- The npm test suite (`packages/js-npm/test/_suite.cjs`, ~150 assertions) is the
  behavioral contract; its pins are listed per-block below where they apply.
- The Rust test corpus (`packages/rust/wgslender-core/tests/`) has the table-driven
  shape to imitate and the fixture set to copy: `demo.wgsl` (four binding kinds,
  struct, helper fn, compute entry), `render.wgsl` (vertex+fragment), `invalid.wgsl`
  (undeclared identifier), `warning.wgsl` (valid, two warnings), plus inline
  UNPARSEABLE `"fn main( { let ; }"` and UNUSED sources.

---

## Guidelines binding — `~/llm/mastery/go/`

This plan follows the Go mastery corpus. Read before executing (the corpus' own
reading order, trimmed to what a wrapper library touches):

1. `00-INDEX.md` — map + modernity table (Go 1.26 canon: `errors.AsType[T]`,
   `sync.WaitGroup.Go`, `testing/synctest`, `t.Context()`, `for b.Loop()`, omitzero).
2. `ELITE_GO_PERSONA.md` (condensed) — house style.
3. `GO_MASTERY.md` — package design, naming, doc comments, tooling floor, Go 1 promise.
4. `ERRORS_AND_PANICS.md` — sentinel/typed/opaque; `errors.Is`/`AsType`; never wrap
   what the caller compares by value.
5. `TYPE_DRIVEN_DESIGN.md` — zero value useful; `opt.Value[T]` for wire tri-state;
   typed IDs; Options struct over functional options for stable discoverable sets.
6. `TESTING_AND_FUZZING.md` — table-driven + `t.Run`; external `package wgslender_test`;
   golden files with `-update`; every codec gets a Fuzz; `for b.Loop()` +
   `b.ReportAllocs()`; `-race` always.
7. `CONCURRENCY_PRIMITIVES.md` §§ Mutex, OnceValues, Pool — for the instance pool.
8. `ZERO_ALLOC_PATTERNS.md` §§ Preallocation, sync.Pool, benchmark discipline — for
   Block 6 only; measure before optimizing.

Decisions those files forced:

- **Options struct, not functional options** — the knob set is stable and mirrored
  from two sibling packages; discoverability wins (TYPE_DRIVEN § Functional Options).
- **Tri-state option fields via a tiny `Opt[T]`** (tailscale `opt.Value[T]` pattern)
  because the wire distinguishes absent from `false`, and stdlib `encoding/json`
  honors `omitzero` + `IsZero()` since Go 1.24.
- **Typed string enums, open** (`type Severity string` + consts) — unknown wire
  spellings pass through unchanged instead of failing; this is the Go-natural
  spelling of Rust's `Unknown` catch-alls.
- **Comma-ok for predictable absence** (locate family, stableIDAtOffset), error
  returns only for real failures (ERRORS § When *Not* to Return an Error).
- **`ctx context.Context` first parameter on every wasm-touching function** — wazero's
  `Call` takes ctx natively; not threading it would be a lie.
- **Start with one instance + `sync.Mutex`; pool only after a benchmark says so**
  (CONCURRENCY: profile before RWMutex/Pool; Block 6 is the [PERF] block with
  benchstat evidence).
- **Deps: wazero (runtime) + google/go-cmp (tests only).** Nothing else. stdlib
  `encoding/json`, `compress/flate` cover the rest.
- No logging anywhere in the library. No goroutines in the library (Block 6's pool
  spawns none either).

House rules from memory that bind here: TDD reds-first (every block: failing test,
confirm red, then green); no CI — all gates are local `make` targets; commit style
conventional and atomic.

---

## Design

### Module layout

```
packages/go/
  go.mod                 module git.hugodaniel.com/hugo/wgslender/packages/go   (go 1.26)
  go.sum
  Makefile               check = fmt + vet + build + test -race ; lint/fuzz/bench opt-in
  .golangci.yml          minimal: govet(all), staticcheck, revive, errcheck, ineffassign, errorlint
  README.md
  wgslender/             THE public package (import ends in /wgslender — no named import needed)
    doc.go               package comment + usage sketch
    wgslender.go         Version, lazy init plumbing (thin over internal/wasmabi)
    opt.go               Opt[T] + Set[T]
    options.go           MinifyOptions, LintConfig, Pack, RuleSetting, Strictness
    minify.go            Minify, MinifyAndReflect
    validate.go          Validate
    lint.go              Lint, LintFix
    reflect.go           Reflect, ReflectJSON, BindGroups
    compile.go           Compile, CompileError
    refactor.go          the 12 refactor ops, StableID, ByteRange, Edit, Reference, Applied
    types.go             Diagnostic, Severity, AddressSpace, AccessMode, ShaderStage,
                         Reflection, Binding, StructLayout, Field, TypeInfo, EntryPoint, …
    errors.go            sentinels + wire-string mapping
    *_test.go            package wgslender_test (external), table-driven
    export_test.go       (only if a white-box seam is unavoidable; justify in-line)
    testdata/            fixtures (copied from packages/rust) + golden files + fuzz corpus
  internal/wasmabi/      ABI machinery — the only unsafe-adjacent code
    wgslender.wasm       go:embed'd copy (kept in lockstep with js-npm, see freshness test)
    abi.go               compile-once runtime, instance, alloc/copy/call/read/free
    envelope.go          the five envelope readers (len-prefixed, validate, lint, lintfix, compile)
    abi_test.go          white-box: header decode, free-length math, empty-string rule
  cmd/wgslgen/           go:generate codegen tool (Blocks 7–8)
```

- Module path `git.hugodaniel.com/hugo/wgslender/packages/go`; public import
  `git.hugodaniel.com/hugo/wgslender/packages/go/wgslender`. The extra path segment
  buys a clean final element (`wgslender`) so no named import is needed. Module root
  holds no Go files.
- In-repo consumers (examples, future tooling) use a `go.work` at `packages/go` level
  or a `replace` — nothing at repo root (keep the Zig tree clean).

### Runtime model (internal/wasmabi)

- `var runtime = sync.OnceValues(func() (*abi, error) { … })` — compiles the embedded
  module on first use. **No exported `Initialize`** — Go's lazy init replaces the npm
  `initialize()`/`isInitialized()` dance entirely (document this divergence in
  README).
- v1 (Blocks 0–5): one instantiated module guarded by a `sync.Mutex`. Every public
  function: lock → write inputs → call → copy outputs out of linear memory → free
  inputs+envelope → unlock. All copies happen under the lock; nothing returned
  aliases wasm memory (Pool-discipline rule: copy outputs before releasing).
- Block 6 upgrades to a `sync.Pool` of instances if — and only if — benchmarks show
  the mutex is the bottleneck under parallel load. Pool entries whose linear memory
  grew past a threshold are dropped instead of Put back (memory never shrinks;
  don't let one 100 MB shader pin pages forever).
- ctx: passed through to `api.Function.Call`. v1 does not enable
  `WithCloseOnContextDone`; Block 6 decides whether cancellation mid-call is worth
  the instance-discard bookkeeping.

### Public API surface (complete)

```go
func Version(ctx context.Context) (string, error)

// Options — zero values mean "wgslender's defaults" (minify) / "no rules" (lint).
type Opt[T any] struct{ /* v T; set bool */ }      // IsZero + MarshalJSON; json:",omitzero"
func Set[T any](v T) Opt[T]
func (o Opt[T]) Get() (T, bool)

type MinifyOptions struct {
    MinifyWhitespace           Opt[bool] `json:"minifyWhitespace,omitzero"`
    MinifyIdentifiers          Opt[bool] `json:"minifyIdentifiers,omitzero"`
    MinifySyntax               Opt[bool] `json:"minifySyntax,omitzero"`
    TreeShaking                Opt[bool] `json:"treeShaking,omitzero"`
    MangleExternalBindings     Opt[bool] `json:"mangleExternalBindings,omitzero"`
    PreserveUniformStructTypes Opt[bool] `json:"preserveUniformStructTypes,omitzero"`
    KeepNames                  []string  `json:"keepNames,omitzero"`
    SortDeclarations           Opt[bool] `json:"sortDeclarations,omitzero"`
    ScopeLocalRename           Opt[bool] `json:"scopeLocalRename,omitzero"`
    SourceMap                  Opt[bool] `json:"sourceMap,omitzero"`
    SourceMapSources           Opt[bool] `json:"sourceMapSources,omitzero"`
}

type Strictness int                          // enum, not bool (house rule)
const ( DefaultStrictness Strictness = iota; Strict )

type Pack string
const ( PackRecommended Pack = "@wgslender/recommended"; PackStyle Pack = "@wgslender/style"
        PackPerformance Pack = "@wgslender/performance"; PackPortability Pack = "@wgslender/portability"
        PackMinify Pack = "@wgslender/minify"; PackStrict Pack = "@wgslender/strict" )

type RuleSetting struct{ /* severity string; opts map[string]any */ }
func Off() RuleSetting; func Warn() RuleSetting; func Error() RuleSetting
func WarnWith(opts map[string]any) RuleSetting; func ErrorWith(opts map[string]any) RuleSetting
// MarshalJSON: bare string or ["warn",{...}] pair. Map keys sort deterministically
// (stdlib encoding/json sorts map keys — the BTreeMap analog for free).

type LintConfig struct {
    Extends                       []Pack                 `json:"extends,omitzero"`
    Rules                         map[string]RuleSetting `json:"rules,omitzero"`
    ReportUnusedDisableDirectives Opt[bool]              `json:"reportUnusedDisableDirectives,omitzero"`
}

// Core ops. Nil options == zero options == defaults.
func Minify(ctx context.Context, source string, opts *MinifyOptions) (MinifyResult, error)
func MinifyAndReflect(ctx context.Context, source string, opts *MinifyOptions) (MinifiedShader, error)
func Validate(ctx context.Context, source string, s Strictness) (Validation, error)
func Lint(ctx context.Context, source string, cfg *LintConfig) (LintReport, error)
func LintFix(ctx context.Context, source string, cfg *LintConfig) (LintFixOutcome, error)
func Reflect(ctx context.Context, source string) (Reflection, error)
func ReflectJSON(ctx context.Context, source string) ([]byte, error)   // raw v2 envelope
func Compile(ctx context.Context, source string, opts *MinifyOptions) (CompiledShader, error)

type MinifyResult struct {
    Code          string
    Errors        []string          // flattened from wire {message} objects (Rust parity)
    OriginalSize  int
    MinifiedSize  int
    SourceMap     json.RawMessage   // nil unless SourceMap requested
}
type MinifiedShader struct { MinifyResult; Reflection Reflection }
type Validation  struct { Valid bool; ErrorCount, WarningCount int; Diagnostics []Diagnostic }
type LintReport  struct { ErrorCount, WarningCount, FixableCount int; Diagnostics []Diagnostic }
type LintFixOutcome struct { Fixed string; Report LintReport }   // Report describes the INPUT
type CompiledShader struct { WASM []byte; OriginalSize int }     // exports generate()+memory

type Severity string      // open enum: Error/Warning/Info/Note/Hint consts; unknown passes through
type Diagnostic struct {
    Severity Severity; Message string; Code string
    Line, Column int            // 1-based
    SpecRef string; Source string
    Related []RelatedInfo; Fix *Fix
}

// Reflection — full v2 envelope, typed (see wire facts above; encode from Zig, not .d.ts)
type Reflection struct { Version int; Bindings []Binding; Uniforms, Storage, Textures,
    Samplers []Binding; Structs map[string]StructLayout; EntryPoints []EntryPoint
    Overrides []Override; Functions []Function; Aliases []Alias; Errors []string }
type TypeInfo struct { Kind string; /* flat superset: Name, Width, Cols, Rows, Format *TypeInfo,
    Size, Alignment, Stride, Count *int, Dim, TexKind, SampleType, Access, AddressSpace,
    Comparison … all omitzero */ }
func BindGroups(bindings []Binding) map[uint32]map[uint32]Binding   // npm getBindGroups analog

// Refactor family. Offsets are UTF-8 byte offsets (int in Go; validated >= 0).
type StableID string                                   // "v1:fn:main/block#0/let:y"
type ByteRange struct{ Start, End int }                // half-open
type Edit struct{ Start, End int; NewText string }
type Reference struct{ Start, End int; IsWrite bool }
type Applied struct{ Source string; Edits []Edit }
type Declarations int                                  // enum, not bool (house rule)
const ( WithDeclaration Declarations = iota; WithoutDeclaration )

func FindReferences(ctx context.Context, source string, offset int, d Declarations) ([]Reference, error)
func Rename(ctx context.Context, source string, offset int, newName string) ([]Edit, error)
func RenameApply(ctx context.Context, source string, offset int, newName string) (Applied, error)
func StableIDAtOffset(ctx context.Context, source string, offset int) (StableID, bool, error)
func LocateStableID(ctx context.Context, source string, id StableID) (ByteRange, bool, error)
func LocateDeclaration(ctx context.Context, source string, id StableID) (ByteRange, bool, error)
func LocateType(ctx context.Context, source string, id StableID) (ByteRange, bool, error)
func RenameByID(ctx context.Context, source string, id StableID, newName string) ([]Edit, error)
func RemoveDeclaration(ctx context.Context, source string, id StableID) ([]Edit, error)
func RemoveDeclarationApply(ctx context.Context, source string, id StableID) (Applied, error)
func ChangeType(ctx context.Context, source string, id StableID, newType string) ([]Edit, error)
func ChangeTypeApply(ctx context.Context, source string, id StableID, newType string) (Applied, error)
```

### Error taxonomy (errors.go)

*A shader's own problems are data; a failed call is an error* — verbatim from the
Rust package, translated to Go shapes:

- Sentinels (compare with `errors.Is`): `ErrInternal` (null result = wasm OOM),
  `ErrSourceTooLarge` (input > u32; wrapped with the size via `fmt.Errorf("%w: %d
  bytes", …)`), and the refactor set mapped 1:1 from wire strings —
  `ErrParse` ("parse error"), `ErrSymbolNotFound`, `ErrInvalidIdentifier`,
  `ErrNoTypeAnnotation` ("no type annotation or invalid replacement"),
  `ErrNotRemovable` ("not a removable declaration"), `ErrStableIDTooLong`
  ("id too long"). Unknown wire reasons → opaque `fmt.Errorf("wgslender: %s", msg)`,
  never dropped.
- Typed: `*CompileError{ Diagnostics []Diagnostic }` — a shader that does not parse
  is an error from Compile ("an empty module is not an answer"); inspect with
  `errors.AsType[*CompileError]`.
- Everything else opaque-wrapped with `%w` (wazero traps, JSON decode failures).
- NOT errors: invalid shaders from Validate/Lint (reports), locate-family absence
  (comma-ok; wire `"not found"` or bare null maps to `ok=false, err=nil`),
  FindReferences on a non-symbol (empty slice), Minify of garbage (original source +
  Errors populated).

---

## Blocks

Each block is one session, self-contained: re-read **Verified current state** +
**Design** above, plus the named mastery files. TDD reds-first throughout: write the
table/fixture test, run `make -C packages/go test` and confirm the red is the
*expected* red (missing symbol / wrong value, not a typo), then implement to green.
Gate before every commit: `make -C packages/go check`. Conventional commits, area
`packages/go`.

### Block 0 — scaffold, ABI core, Version

Mastery: GO_MASTERY (package design), CONCURRENCY (Mutex, OnceValues).

1. `mkdir packages/go && go mod init git.hugodaniel.com/hugo/wgslender/packages/go`;
   `go get github.com/tetratelabs/wazero@v1.12.0`. Copy
   `packages/js-npm/wgslender.wasm` → `packages/go/internal/wasmabi/wgslender.wasm`.
2. Makefile: `check` = `fmt vet build test`; `fmt` = `test -z "$$(gofmt -l .)"`;
   `test` = `go test -race ./...`; opt-in `lint` (golangci-lint, hard-fail if
   missing), `fuzz`, `bench`. **No workflow YAML anywhere.**
3. RED: `wgslender/wgslender_test.go` (external package):
   - `TestVersion` — semver shape `^\d+\.\d+\.\d+$`; second assertion pins equality
     with `src/root.zig`'s version string read from the repo (skip if the file is
     absent, so the test survives a future extraction).
   - `TestWasmMatchesNpm` — sha256 of the embedded wasm == sha256 of
     `../../js-npm/wgslender.wasm` (path relative to the test file; skip-if-absent).
     This is the **freshness gate**: whenever the wire changes and js-npm's wasm is
     rebuilt, this test fails until the Go copy is refreshed too.
4. GREEN: `internal/wasmabi/abi.go` — embed, compile-once via `sync.OnceValues`,
   single instance + mutex, `call` helper (alloc inputs with the `max(len,1)` rule,
   invoke, fresh-memory reads, free inputs, return envelope bytes + free with exact
   totals), `Version()`.
5. White-box `abi_test.go`: envelope header decode against hand-built byte slices;
   free-length arithmetic for all five layouts; empty-string alloc rule.
6. Commit: `feat(packages/go): scaffold pure-Go module with wazero ABI core`.

### Block 1 — Minify + options codec

Mastery: TYPE_DRIVEN (Opt pattern), TESTING (tables, fuzz, golden).

1. Copy fixtures from `packages/rust/wgslender-core/tests/fixtures/` into
   `wgslender/testdata/` (demo, render, invalid, warning .wgsl).
2. RED — options codec unit table (this is wire-pinned; mirror the Rust unit tests):
   `MinifyOptions{}` marshals to exactly `{}`;
   `{MinifyWhitespace: Set(true), TreeShaking: Set(false), KeepNames: […"main"]}` →
   `{"minifyWhitespace":true,"treeShaking":false,"keepNames":["main"]}`.
3. RED — minify table (npm-suite pins): basic size reduction; whitespace-only keeps
   identifiers; `@group/@binding` name preserved by default and mangled with
   `MangleExternalBindings: Set(true)`; treeShaking drops unused fn; KeepNames
   preserves; `MinifiedSize < OriginalSize`; `""` → no errors; `fn { broken }` →
   `Code == source` (unchanged-on-parse-error contract) + non-empty Errors;
   nil opts ≡ `&MinifyOptions{}` (defaults-equivalence, the Rust
   `default_options_match_the_default_flags` pin); `SourceMap: Set(true)` →
   `SourceMap` non-nil with `"version":3` inside.
4. GREEN: options.go, opt.go, minify.go.
5. `FuzzMinify(f *testing.F)` — seeds: the fixtures + UNPARSEABLE + `"😀"` + nested
   comments + `enable f16;`; property: no panic/trap, `(MinifyResult, error)` both
   acceptable. Run `-fuzztime=60s` once; check any findings into `testdata/fuzz/`.
6. Idempotence table (Rust props parity, deterministic not fuzz): for
   {demo,render,warning} × 8 boolean-option combinations: `Minify(Minify(x)) ==
   Minify(x)` and the result still validates (defer the validates half to Block 2;
   leave a `t.Skip` marker RED as the block boundary).
7. Commit: `feat(packages/go): minify with tri-state options codec`.

### Block 2 — Validate + Lint + LintFix + Diagnostic

Mastery: ERRORS (report-vs-error line), TESTING.

1. RED — validate table (npm pins): valid fn/compute/vertex → `Valid:true,
   ErrorCount:0`; undeclared variable → invalid; `""` → valid; diagnostics carry
   1-based Line/Column ≥ 1 and ≥ 1 Code; `Strict` →
   `strict.ErrorCount >= def.ErrorCount + def.WarningCount`; counts decoded from the
   binary header (regression pin for the `packValidate` offsets, the npm
   commit-24d21f1 block).
2. RED — lint table: zero-value `LintConfig{}` → 0 diagnostics (**zero rules**
   contract, loudly documented on the type); `Extends: [PackRecommended]` flags
   unused fn with `Code == "W0001"` and `Source == "wgslender-lint"`;
   `Rules: {"no-unused-vars": Error()}` elevates; `Off()` silences;
   `WarnWith(map[string]any{"max":4})` marshals to `["warn",{"max":4}]`;
   disable-comment suppression; `FixableCount >= 1` for a redundant cast;
   warningCount-is-lint-only asymmetry pinned with a fixture that has both validator
   and lint warnings.
3. RED — LintFix: rewrites source, output still validates; clean shader passthrough;
   Report describes the input.
4. GREEN: types.go (Diagnostic + open enums), validate.go, lint.go. Un-skip Block 1's
   minified-still-validates table.
5. Commit: `feat(packages/go): validate and lint with shared diagnostics`.

### Block 3 — Reflect + MinifyAndReflect + BindGroups

1. RED — reflect table (npm pins): uniform binding group/binding/name/addressSpace +
   `Layout.Size == 24` for `{f32, vec2<u32>, f32}`; sampler → `AddressSpace ==
   "handle"`, no Layout; compute entry stage + workgroup size; struct field
   names/count; `""` → empty slices; broken → Errors populated; `Version == 2`;
   subset views populated; **wire-fact pins**: texture TypeInfo flat with `TexKind`,
   nested array key `array`, IO fields omitted-not-null (decode a hand-written JSON
   fixture for these, so the pin survives shader-corpus drift).
2. RED — MinifyAndReflect: names in Reflection match a re-Reflect of `.Code`;
   `NameMapped` keeps the original; parse error surfaces in both halves' errors.
3. RED — BindGroups grid incl. holes (`grid[0][1]` absent; separate groups).
4. GREEN: reflect.go + Reflection/TypeInfo decoding. `ReflectJSON` returns the raw
   envelope for everything the typed view flattens.
5. Commit: `feat(packages/go): typed reflection with bind-group helper`.

### Block 4 — Compile

1. RED — table: basic compute shader → no error, `WASM` starts `00 61 73 6d`,
   `OriginalSize == len(src)`; **the produced module runs**: instantiate it under
   wazero *in the test*, call `generate()`, decode `memory[0:len]`, assert it
   contains `@compute` (the strongest npm pin, and pure Go makes it cheap);
   options change the generated module; unparseable source →
   `errors.AsType[*CompileError]` with non-empty Diagnostics.
2. GREEN: compile.go.
3. Commit: `feat(packages/go): binary shader compiler binding`.

### Block 5 — refactor family

1. RED — tables mirroring `packages/rust/…/tests/refactor.rs` + npm pins: 4 refs for
   `helper` with exactly 1 write; `WithoutDeclaration` drops the decl; no symbol →
   empty + nil error; rename → 4 edits spelling `helper`→`scale`; keyword target →
   `errors.Is(err, ErrInvalidIdentifier)`; missing symbol → `ErrSymbolNotFound`;
   RenameApply failure echoes original source; exact stable-id strings
   (`"v1:fn:compute/block#0/let:y"`, binding `"v1:var:u"`); id survives a prepended
   comment; `LocateStableID` after deleting the symbol → `ok=false, err=nil`;
   unknown-version id `"v2:…"` → `ok=false`; `ChangeTypeApply` struct-member case
   produces exactly `struct S { x: i32, y: f32 }`; `RemoveDeclarationApply` single
   deletion edit with empty NewText; UTF-8 byte-offset pin (multibyte source).
2. Unit table for the wire-string → sentinel map, including the two branches
   integration can't provoke (`"not a removable declaration"`, `"id too long"`) —
   same trick as the Rust unit tests.
3. GREEN: refactor.go, errors.go.
4. Commit: `feat(packages/go): refactor and stable-id operations`.

### Block 6 — concurrency + performance ([PERF])

Mastery: CONCURRENCY (Pool discipline), ZERO_ALLOC (benchmark discipline).

1. RED — `-race` stress test: N goroutines × M mixed ops via `sync.WaitGroup.Go`,
   all results independently correct (this already passes with the mutex — it pins
   correctness before the optimization).
2. Benchmarks first: `BenchmarkMinify{Small,Large}`, `BenchmarkParallelMinify`
   (`b.RunParallel`), all `for b.Loop()` + `b.ReportAllocs()`. Record baseline with
   `-count=6 -benchmem` + benchstat.
3. Implement the instance pool (`sync.Pool` of instances; discard oversized-memory
   instances instead of Put; compile-once shared). Re-run benchstat; the pool lands
   **only if** parallel throughput materially improves; either way the evidence goes
   in the commit message.
4. Leak test: 10k sequential minifies → `Memory().Size()` stabilizes (frees are
   balanced; growth plateaus).
5. Decide `WithCloseOnContextDone` here with a cancellation test if adopted.
6. Commit: `perf(packages/go): instance pooling with benchstat evidence` (or a
   `docs:` commit recording why the mutex stays).

### Block 7 — `cmd/wgslgen`: minified + compressed embedding

The `include_wgsl!` / `include_wgsl_compressed!` analog via `go:generate`.

1. RED — golden tests (testdata in/out pairs, `-update` flag): `wgslgen -var Shader
   -pkg shaders -o out.go in.wgsl` emits a Go file with the minified source as a
   const + a header comment naming tool+input; `-compress` variant stores
   `compress/flate` bytes + lazy inflate via `sync.OnceValue` accessor, and the
   generated accessor round-trips to the plain variant's const; invalid WGSL →
   non-zero exit with diagnostics on stderr (parse errors reject, mirroring
   `include_wgsl!`'s compile_fail).
2. GREEN: cmd/wgslgen (flag parsing, calls the library, `go/format`s its output).
   Generated code compiles — the golden test builds it with `go build` in a temp
   module or type-checks via `go/types`.
3. Commit: `feat(packages/go): wgslgen embed generator`.

### Block 8 — `wgslgen -module`, examples, docs, wrap-up

The `wgsl_module!` analog: typed structs with layout proofs.

1. RED — golden: `-module` emits, per reflected struct, a Go struct with explicit
   padding fields (`_ [N]byte`) so field offsets match WGSL offsets (vec3<f32> →
   `[3]float32` + pad; mat with stride handling; nested structs), plus binding-slot
   consts and entry-point metadata, **plus a generated `_test.go` asserting
   `unsafe.Sizeof`/`unsafe.Offsetof` against the reflection numbers** — the layout
   proof runs on `go test`, the closest Go gets to the bytemuck compile-time check.
   Include the Rust plan's adversarial fixtures: `padded_array.wgsl`,
   `padded_matrix.wgsl` (copy from `packages/rust/wgslender/tests/fixtures/`).
2. Docs pass: every exported identifier gets a doc comment (name-first,
   period-final); `Example_minify`, `Example_reflect`, `ExampleBindGroups` with
   `// Output:`; package doc in doc.go; README (usage, the lint-vs-minify empty-
   options asymmetry, the no-initialize divergence from npm, wasm freshness rule,
   `// go:generate` recipes).
3. Publishing section in README, **decision deferred** like Rust's: options are (a)
   push repo + rely on Gitea go-get meta (verify `?go-get=1` works, set GOPRIVATE
   guidance), (b) vanity import path, (c) mirror to a public host. Do not decide in
   this plan.
4. Final full gate + `zig build test` (nothing in the Zig tree changed, but run it
   anyway — the freshness test's contract depends on js-npm's artifact being
   current).
5. Commit: `feat(packages/go): wgslgen module codegen, examples, docs`.

---

## Behavior/repo changes to flag (none silent)

- **New checked-in build artifact**: `packages/go/internal/wasmabi/wgslender.wasm`
  (766 KB duplicate of js-npm's). The rebuild rule extends: *whenever the wire
  changes, `zig build wasm` and copy to BOTH `packages/js-npm/wgslender.wasm` and
  `packages/go/internal/wasmabi/wgslender.wasm`* — enforced locally by Block 0's
  sha-parity test (there is no automated freshness check on the npm side either;
  this adds the first one).
- No existing file is modified by this plan. No `build.zig` changes (a `gen-go`-style
  copy step was considered and rejected — a two-line `cp` documented in README plus
  the parity test is less machinery than a build-graph edit).
- The Go API deliberately diverges from npm in three places (all documented):
  no `initialize()` (lazy init), refactor errors are Go errors rather than `error`
  fields on results, and minify errors are flattened `[]string` (Rust parity).

## Deferred / out of scope

- **cgo fast-path** (build-tag `wgslender_cgo` against `libwgslender.a`): only if a
  real profile shows wazero too slow. Inherits the Rust vendoring problem; do not
  build speculatively.
- **Publishing** (`go get` from git.hugodaniel.com): blocked on pushing the repo and
  verifying the host serves go-import metadata. Written up in Block 8's README
  section; decision is Hugo's.
- **LSP**: `npm/wgslender-lsp` ships a separate `wgslender-lsp.wasm` (also
  freestanding, `zig build lsp-wasm`). A Go LSP transport would be its own plan.
- **Source-map typed struct**: `MinifyResult.SourceMap` stays `json.RawMessage`.
