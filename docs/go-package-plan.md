# Plan — `packages/go/`: a pure-Go package for WGSLender

**Creates:** `packages/go/` — a Go module wrapping the wgslender WASM build via
[wazero](https://github.com/tetratelabs/wazero) (a zero-dependency, pure-Go WebAssembly
runtime). No cgo, no Zig toolchain for consumers: the module `go:embed`s the same
`wgslender.wasm` the npm package ships and is `go get`-able from any platform Go
supports. It lives beside `packages/js-npm/` and `packages/rust/`.

Also creates `cmd/wgslgen`, a `go:generate`-able codegen tool — the Go analog of the
Rust `include_wgsl!` / `include_wgsl_compressed!` / `wgsl_module!` macros (Go has no
compile-time macros; `go generate` + golden files is the idiom).

**Status:** 🏁 **executed — all nine blocks (0 through 8) landed.**
`git log -- packages/go` is the authority on what is actually done, not this line.
Originally verified against `main @ 9726727`
on 2026-08-06 (macOS arm64, go 1.26.5, zig 0.16.0) by running a throwaway wazero
harness over the shipped wasm — every ABI, wire, and Go-language claim below was
observed, not inferred. Working tree is clean apart from untracked `docs/obsidian/`.

**Why wazero and not cgo:** Go has no `build.rs`. A cgo binding cannot run `zig build
lib` at `go build` time, so it would need prebuilt `libwgslender.a` per platform
checked in or downloaded — the exact vendoring decision that deferred the Rust
crates.io publish (`packages/rust/README.md § Publishing`). The wasm route dissolves
the problem: one 766 KB artifact, every GOOS/GOARCH, no cgo required
(`CGO_ENABLED=0` builds fine). Cost: wasm-JIT speed instead of native — measured at
~60 µs to minify a 445-byte shader, which is fine for a minifier; a cgo fast-path can
be added later behind a build tag if a profile ever demands it (**explicitly
deferred**, see § Deferred).

wazero is pure Go but **not** dependency-free at the module level: `v1.12.0` requires
`golang.org/x/sys v0.44.0` (also pure Go). The go.sum will have two entries, not one.

---

## Verified current state (do not re-derive)

### Environment

- `go version go1.26.5 darwin/arm64` at `/opt/homebrew/bin/go`. `golangci-lint`,
  `gofumpt` and `staticcheck` are all **not** installed — the mandatory gate uses
  `gofmt`/`go vet`/`go test -race` only; golangci-lint is an opt-in target that fails
  loudly when missing (mirrors `cargo xtask msrv`'s "a check that did not run has not
  passed").
- Go-1.26 features this plan leans on, each compiled and run on this toolchain:
  `errors.AsType[T]` ✓, `sync.WaitGroup.Go` ✓, `omitzero` honouring a generic type's
  `IsZero() bool` ✓ (see the `Opt[T]` note below), `for b.Loop()`.
- wazero latest is **v1.12.0** (module proxy, 2026-08-06; published 2026-05-28).
  Still v1 — Go-1-style compatibility promise holds. Pulls in `golang.org/x/sys
  v0.44.0` as its only requirement.
- git remote: `https://git.hugodaniel.com/hugo/wgslender.git` (self-hosted; serves
  `?go-get=1` meta tags if it's Gitea/Forgejo — untested, see § Deferred: publishing).
  Repo is not pushed; consumers today use the module in-repo.

The `Opt[T]` codec was proved out standalone before it went into the plan:

```go
type Opt[T any] struct{ v T; set bool }
func (o Opt[T]) IsZero() bool                 { return !o.set }
func (o Opt[T]) MarshalJSON() ([]byte, error) { return json.Marshal(o.v) }
// MinifyOptions{}                                        -> {}
// {MinifyWhitespace: Set(true), TreeShaking: Set(false)} -> {"minifyWhitespace":true,"treeShaking":false}
```

One nuance to document: `omitzero` on `KeepNames []string` omits a **nil** slice but
emits an explicitly-empty one as `"keepNames":[]`. Harmless (the Zig side treats an
empty list as "no names"), but the options-codec test should pin both.

### The wasm artifact and its ABI (empirically probed with wazero v1.12.0, this session)

- `packages/js-npm/wgslender.wasm`: **766,743 bytes**, byte-identical to current
  `zig-out/bin/wgslender.wasm` (sha256 `b354a731ec1f…f322ddd` on both). Built by `zig
  build wasm` (`build.zig:48-66`): `wasm32-freestanding`, `ReleaseSmall` (hardcoded on
  the module — `-Doptimize=` flags do not reach it), `entry = .disabled`,
  `rdynamic = true`.
- **Zero imports.** Confirmed via `CompiledModule.ImportedFunctions()` = 0 and
  `ImportedMemories()` = 0. No WASI, no `env`, no start function. wazero instantiates
  it with a plain `wazero.NewModuleConfig()` and nothing else. Verified end-to-end:
  `wgslender_version` / `wgslender_version_len` through wazero returned `"1.1.0"` read
  from linear memory (a static pointer into linear memory, `src/root.zig:11`).
- Exports: one memory (`memory`, 19 pages / 1,245,184 B at instantiate) + exactly 23
  functions, all-i32 params/results (`src/wasm.zig`, all `callconv(.c)`):

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
module never shrinks). Balanced frees do hold: 500 sequential minifies moved
`Memory().Size()` by **zero** bytes.

7. One instance = one single-threaded allocator. **Not goroutine-safe**, and this is
   not a theoretical hazard — 16 goroutines × 60 unsynchronized minifies on one
   instance produced **959 failures out of 960**, as guest traps (`invalid table
   access`, `out of bounds memory access`), not as wrong answers. Serialize calls per
   instance; JS gets this for free, Go must enforce it. Two consequences for the
   design:
   - the mutex is a correctness requirement, not a performance choice;
   - **a call that returns an error must retire its instance.** A trapped guest may
     have a corrupted heap, and corruption is not self-announcing — after the storm
     above the same instance went on serving *plausible* results. Never return a
     trapped instance to a pool or reuse it behind the mutex.

Measured costs on this machine (445-byte shader, wazero v1.12.0, arm64):

| operation | cost |
|---|---|
| `CompileModule` (once, behind `sync.OnceValues`) | **~127 ms** |
| `InstantiateModule` | **~32 µs** |
| one `minify_json` round trip | **~57 µs** |
| 320 minifies, serial | 18.3 ms |
| 320 minifies, 8 goroutines × own instance | 2.8 ms (**~6.4×**) |

So: compile-once is clearly worth the `OnceValues`; instantiation is cheap enough that
pooling — or even instantiate-per-call — is affordable; and the parallel win is real
rather than speculative. Block 6 still measures before landing the pool, but it starts
from this prior rather than from nothing.

**Confirmed in Block 6, and the prior was slightly pessimistic.** Measured through
the public API rather than the raw ABI (`benchstat`, n=6, `-cpu 1,8`, 884-byte
shader): one minify is **87 µs** serial, and eight-way parallel minification went
from **94.7 µs/op to 12.2 µs/op (−87%, 7.2×)** once the pool landed. Serial cost did
not move (`Minify/Small` 88.4 µs → 87.1 µs, p=0.065). Two facts the prior did not
contain:

- **`api.Module.ExportedFunction` is not a lookup.** It builds a call engine with a
  cloned execution stack every time it is called, and there are six guest calls
  behind one minify (2 allocs, the export, 3 deallocs). Caching the handles per
  instance took a minify from **58.4 KiB/op to 2.6 KiB/op (−95%)** and 32 allocs to
  25. This is independent of pooling and would have been worth doing either way.
- **`WithCloseOnContextDone` costs 4.5×**, not "a bit" as its doc says: every
  benchmark rose by 250–350% (87 µs → 387 µs serial). Rejected — see Block 6 below.

### Wire contracts (from the Zig writers — `src/api_json.zig`, `src/Diagnostic.zig`,
### `src/reflect/Json.zig`; the npm `main.d.ts` lies in places, encode from Zig)

Options JSON (camelCase; keys derived from `src/options.zig` spec table):

- minify/minify_and_reflect/compile: `minifyWhitespace, minifyIdentifiers,
  minifySyntax, treeShaking, mangleExternalBindings, preserveUniformStructTypes,
  keepNames: [string], sortDeclarations, scopeLocalRename, sourceMap,
  sourceMapSources` (booleans unless noted). Zig defaults when absent:
  whitespace/identifiers/syntax/treeShaking **true**, everything else **false**,
  keepNames empty. **`{}` (or empty buffer) = wgslender's own defaults** — options
  are overrides. Malformed options JSON **silently degrades to defaults** (all three
  of `""`, `{}` and `{not json` produce byte-identical output —
  `Config.parseJson(...) catch Config{}`, `src/api_json.zig:110`).
  `compile` forces sortDeclarations + scopeLocalRename on internally.
  **Amended during Block 4** — that understates it. Of the eleven options,
  `compile` reads **four**: `minifyIdentifiers`, `treeShaking`,
  `mangleExternalBindings`, `keepNames`. The other seven —
  `minifyWhitespace`, `minifySyntax`, `sortDeclarations`, `scopeLocalRename`,
  `preserveUniformStructTypes`, `sourceMap`, `sourceMapSources` — produce a
  **byte-identical module** whatever they are set to, because the compiler
  hardcodes its printer config (`src/Compiler.zig:1743-1745`:
  `minify_syntax=false, sort_declarations=true, scope_local_rename=true`) and
  forces `preserve_uniform_struct_types=false` (`:281`). Consequence, verified
  by round-tripping the module: `compile`'s regenerated text equals
  `Minify(src, {sortDeclarations:true, scopeLocalRename:true,
  minifySyntax:false})` **exactly**, and differs from `Minify(src, {})` — e.g.
  `0.2126` where default minification writes `.2126`.
  `sourceMapInline` exists in `src/options.zig`'s `source_map_specs` and `Config`
  parses it, but the **wasm minify path never reads it** — only `source_map` and
  `source_map_sources` are applied (`src/api_json.zig:112-113`). Inline data-URI
  emission is a CLI concern. Leave it off `MinifyOptions`; this is deliberate, not an
  oversight.
- lint/lint_fix config: `extends: ["@wgslender/…"]`, `rules: {id: "off"|"warn"|
  "error" | ["warn"|"error", {opts}]}` (**object only** — an array is silently
  ignored — `{"rules":["no-unused-vars"]}` yields zero diagnostics),
  `reportUnusedDisableDirectives: bool`. **`{}`/empty = run NO rules** — the opposite
  convention from minify. Unknown rule ids are silently ignored (an `"error"`-severity
  override on a nonexistent rule produces no diagnostic and no failure). Per-rule
  option objects (`["warn",{…}]`) parse fine; the *option names* are per-rule and must
  be read out of the rule source, never guessed.
- validate takes a `u32` flag word (bit0 strict). find_references'
  `include_declaration` is tested `!= 0`, so any non-zero value means "include" — the
  Go binding should still send exactly 0 or 1.

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
  "aliases"[,"errors"]}`. Every one of those keys is **always present** except
  `errors`, which appears only when non-empty. Empty source ⇒ all arrays `[]`,
  `structs` `{}`, no `errors`.

  The envelope is **much richer than a naive `{group,binding,name,type}` sketch**, and
  Block 3 must budget for that. Observed key sets (dumped from the live wasm, not from
  the .d.ts):

  - **Binding**: `group, binding, name, nameMapped, nameOffset, stableId,
    declSpan{start,end}, typeSpan{start,end}, addressSpace, type, typeMapped,
    typeInfo` + optional `accessMode` (storage), optional **`layout`** (a full
    StructLayout, present when the binding's type is a struct — the npm suite pins
    `bindings[0].layout.size === 24`), optional **`array`** (an ArrayInfo
    `{depth,elementCount,elementStride,totalSize,elementType,elementTypeMapped}`).
  - **StructLayout**: `size, alignment, fields[]`; each field `name, nameMapped,
    nameOffset, stableId, typeSpan, type, typeMapped, offset, size, alignment,
    typeInfo`.
  - **EntryPoint**: `name, nameOffset, stableId, declSpan, stage, workgroupSize,
    inputs[], outputs[], resources[]` + `overrides[]` **only when non-empty**.
  - **Override**: `name, nameMapped, nameOffset, stableId, declSpan, id, type,
    typeInfo, default` — `default` is rendered expression *text* (`"8u"`).
  - **Alias**: `name, nameMapped, nameOffset, stableId, declSpan, type, typeMapped,
    typeInfo`.
  - **Function**: `name, nameOffset, declSpan, inUse, calls[], directResources[],
    directOverrides[]`. Entry points appear here too. Populated even when the source
    failed to parse (with `inUse:false`).

  Corrected wire facts (the previous revision of this plan got the last two wrong):

  - texture TypeInfo is **flat**: `{kind:"texture",dim,texKind[,format][,access]
    [,sampleType]}` ✓.
  - the **binding-level** key holding ArrayInfo is `array` (not `nested`) ✓ — but note
    that is a *separate* key from the array's `typeInfo`, which spells its element
    type as **`format`** and adds `count` / `stride` / `size` / `alignment`. Two
    different array views, both present on the same binding.
  - ✗ **`inputs`/`outputs` are NOT omitted when absent** — both arrays are always
    emitted, `[]` when empty. What *is* omitted is each IO entry's `location` and
    `builtin` (exactly one of the two is present). A fragment return value has
    `"name":""` rather than no name.
  - ✗ **`workgroupSize` is `null`, not omitted**, on non-compute entry points
    (`src/reflect/Json.zig:588`). Same for `overrides[].id` when there's no `@id`.
    Decode as `*[3]int` / `*int`, not as an absent field. An override-driven size
    like `@workgroup_size(grid)` folds to **`[0,1,1]`** — worth pinning.
  - the `uniforms`/`storage`/`textures`/`samplers` subset views **duplicate the whole
    binding object**, they are not indices into `bindings`.

  TypeInfo kinds: scalar, vec, mat, array, struct, atomic, sampler, texture, ptr. A
  struct's TypeInfo is just `{kind:"struct",name,size,alignment}` — the fields live in
  `layout` / `structs`.

  Found while *executing* Block 3, by reading `src/reflect/Json.zig` end to end and
  re-probing the live wasm. The inventory above was written from a partial dump and
  is short in six places; all six are now decoded and pinned:

  - **`format` carries two different JSON types under one key.** On vec / mat / array
    / atomic / ptr it is a nested TypeInfo *object*; on texture it is a format-name
    *string* (`"rgba8unorm"`). A single flat struct with `Format *TypeInfo` fails to
    decode any storage texture. Go dispatches on `kind` in `TypeInfo.UnmarshalJSON`
    and lands the two in `Format` and `TexFormat`. **This is the only genuine
    wire↔Go shape mismatch in the whole reflect envelope** — which is why Go decodes
    reflection straight into the public types (json tags) instead of through the
    mirror-struct pattern Blocks 1–2 use.
  - **Binding has an optional `relations[]`** — the samplers a texture is used with,
    and back again. Not in the inventory at all.
  - **A struct field has an optional `layout`** (the nested StructLayout) when the
    member is itself a struct, so StructLayout is mutually recursive with Field.
  - **ArrayInfo has an optional `elementLayout`** (struct elements) **and an optional
    `array`** (the next dimension in) — it is recursive, and `depth` counts
    outward-in.
  - **Function has optional `nameMapped` and `stableId`**; an IO entry has an
    optional `interpolate:{type[,sampling]}`.
  - **`declSpan`/`typeSpan` are omitted, not nulled**, when the engine has none — its
    own presence test is `end > start` (`SpanInfo.present`), so a zero `Span` is
    exactly the absent one and no real span can be zero.

  Two corrections to Block 3's own step list, both confirmed against the live wasm:

  - ✗ Step 3 says "`NameMapped` keeps the original". **It is the other way round**:
    `name` is what the author wrote and `nameMapped` is what minification produced
    (`tex` → `d`). Pinned by a test that asserts `NameMapped` appears in `.Code` as a
    whole identifier and `Name` does not.
  - the `layout.size === 24` npm pin and demoWGSL's `Params` (16) are both now in one
    table, keyed by fixture, so crossing them cannot pass.
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
  `"no type annotation or invalid replacement"`. Which are reachable from
  integration, probed one by one:

  | string | how to provoke |
  |---|---|
  | `"symbol not found"` | offset on whitespace, or an unknown stable id |
  | `"invalid identifier"` | rename to a keyword (`"fn"`) |
  | `"no type annotation or invalid replacement"` | `changeType` on an **inferred `let`** (`let y = helper(1.0)`) — no annotation to replace |
  | `"parse error"` | any refactor op on unparseable source |
  | `"not found"` | locate-family on an absent id |
  | `"not a removable declaration"` | **not reachable** — fns, struct members and vars all removed cleanly |
  | `"id too long"` | **not reachable** — a 5000-char id returns `"not found"`, not this |

  So Block 5's unit table for the last two rows is load-bearing, exactly as planned.

  **Amended in Block 5 — three of those rows are wrong.** Re-probed op by op
  through the live wasm; **all seven strings are reachable from integration**, so
  the unit table is not load-bearing for coverage (it is still worth having for
  the *unknown*-reason branch, which no shader can produce). Corrections:

  | string | actually |
  |---|---|
  | `"parse error"` | **not** "any op on unparseable source". The parser recovers from most bad input and hands back a module, so a refactor over `"fn main( { let ; }"` answers normally — `symbol not found`, or an empty reference list. This branch needs source `Parser.parse` *abandons*, i.e. `analyzeOrNull` returning `module == null`: `"fn f() { if }"` does it, as does ~200-deep block nesting. All twelve ops then report it. |
  | `"not a removable declaration"` | **reachable** — a struct member (`v1:struct:S/member:x`) or a function parameter (`v1:fn:f/param:x`). Fns, vars, aliases, overrides, entry points and local `let`s all remove cleanly, which is what the original probe happened to try. |
  | `"id too long"` | **reachable** — from the *producing* side, not the lookup side. `stableIdAtOffset` on a source with a ~2000-char identifier returns it (1000 chars still fits). The original probe only tried *looking up* a long id, where the answer is `"not found"`. |

  Also found while probing, and pinned by the Go tests:

  - `include_declaration` is `!= 0`, so `Declarations` must be converted
    explicitly — `WithDeclaration` is the zero value and maps to **1**.
  - `stableIdAtOffset` does **not** resolve struct members (returns `null` at the
    member's own offset), yet the member ID that `Reflect` hands out works in
    `locateStableId`, `locateType`, `renameByStableId` and `changeType`.
    `locateDeclaration` is the other half of the asymmetry: it answers
    `"not found"` for a member.
  - `changeType` on a **function** id retargets its *return type*.
  - `Edits.isValidWgslIdentifier` (`src/Edits.zig:59`) is **ASCII-only**, where the
    lexer accepts any XID_Start rune. So the engine will find and rename `héllo`
    but refuses to rename anything *to* `wörld` — a limit of the renamer, not of
    WGSL. Pinned by `TestRenameRefusesNonASCIINames`.

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
- **Deps: wazero (runtime) + google/go-cmp (tests only).** Nothing else *chosen* —
  the go.mod will additionally carry `golang.org/x/sys` as wazero's own requirement.
  stdlib `encoding/json`, `compress/flate` cover the rest.
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
- **Any error out of a wasm call retires the instance.** A trap can leave the guest
  heap inconsistent without saying so, so the recovery is to discard and re-instantiate
  (~32 µs), never to keep using it. This holds in both the mutex and the pool designs
  and is the reason the ABI layer, not the callers, owns instance lifetime.
- Block 6 upgrades to a `sync.Pool` of instances if — and only if — benchmarks confirm
  the mutex is the bottleneck under parallel load. The prior is favourable (~6.4× on
  8-way parallel, § measured costs), but the benchmark still decides. Pool entries
  whose linear memory grew past a threshold are dropped instead of Put back (memory
  never shrinks; don't let one 100 MB shader pin pages forever).
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

type Span struct{ Start, End int }
type Binding struct {
    Group, Binding uint32
    Name, NameMapped string; NameOffset int; StableID StableID
    DeclSpan, TypeSpan Span
    AddressSpace, AccessMode string        // AccessMode empty unless storage
    Type, TypeMapped string
    Layout *StructLayout                   // struct-typed bindings only
    Array  *ArrayInfo                      // array-typed bindings only
    TypeInfo TypeInfo
}
type StructLayout struct { Size, Alignment int; Fields []Field }
type Field struct { Name, NameMapped string; NameOffset int; StableID StableID
    TypeSpan Span; Type, TypeMapped string; Offset, Size, Alignment int; TypeInfo TypeInfo }
type ArrayInfo struct { Depth, ElementCount, ElementStride, TotalSize int
    ElementType, ElementTypeMapped string }
type EntryPoint struct {
    Name string; NameOffset int; StableID StableID; DeclSpan Span
    Stage string                           // "compute" | "vertex" | "fragment"
    WorkgroupSize *[3]int                  // wire NULL on non-compute — pointer, not omitted
    Overrides []string                     // omitted from the wire when empty
    Inputs, Outputs []IOVar                // ALWAYS present; [] when empty
    Resources []string
}
type IOVar struct { Name string; Location *int; Builtin string  // exactly one is set
                    Type string; TypeInfo TypeInfo }            // Name is "" for a fragment return
type Override struct { Name, NameMapped string; NameOffset int; StableID StableID
    DeclSpan Span; ID *int; Type string; TypeInfo TypeInfo; Default string }  // Default is expr TEXT
type Alias struct { Name, NameMapped string; NameOffset int; StableID StableID
    DeclSpan Span; Type, TypeMapped string; TypeInfo TypeInfo }
type Function struct { Name string; NameOffset int; DeclSpan Span; InUse bool
    Calls, DirectResources, DirectOverrides []string }

type TypeInfo struct { Kind string; /* flat superset: Name, Width, Cols, Rows, Format *TypeInfo,
    Size, Alignment, Stride, Count *int, Dim, TexKind, SampleType, Access, AddressSpace,
    Comparison … all omitzero. Arrays spell their element type as Format, not Nested. */ }
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
     `../../js-npm/wgslender.wasm` (relative to `packages/go/wgslender/`, so it
     resolves to `packages/js-npm/wgslender.wasm`; skip-if-absent). This is the
     **freshness gate**: whenever the wire changes and js-npm's wasm is rebuilt, this
     test fails until the Go copy is refreshed too. Requires `internal/wasmabi` to
     expose the embedded bytes (or a `Checksum() [32]byte`) — `internal/` is importable
     from anywhere inside this module, including an external `_test` package.
4. GREEN: `internal/wasmabi/abi.go` — embed, compile-once via `sync.OnceValues`,
   single instance + mutex, `call` helper (alloc inputs with the `max(len,1)` rule,
   invoke, fresh-memory reads, free inputs, return envelope bytes + free with exact
   totals), **discard the instance on any call error**, `Version()`.
5. White-box `abi_test.go`: envelope header decode against hand-built byte slices;
   free-length arithmetic for all five layouts; empty-string alloc rule.
6. Sanity assertions worth encoding while the ABI is fresh: the compiled module has
   0 imported functions and 0 imported memories, and exports exactly 23 functions +
   1 memory. Cheap, and they turn any future `zig build wasm` surface change into a
   named failure instead of a mysterious one.
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

Probed values to use as pins (445-byte demo shader, defaults): `""`, `{}` and
`{not json` all produce identical 161-byte output; `{"keepNames":["helper"]}` → 171 B
with `helper` intact; `{"mangleExternalBindings":true}` → the `@group/@binding` name is
gone; `{"treeShaking":false,"minifyIdentifiers":false}` → 181 B. `{"sourceMap":true}`
yields a `sourceMap` object with keys `mappings, names, sources, version` and
`"version":3`.

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

Block 3 is the largest of the blocks — see the corrected reflect key inventory in
§ Wire contracts. Budget for ~10 wire structs, not 3.

1. RED — reflect table (npm pins): uniform binding group/binding/name/addressSpace +
   `Layout.Size == 24`. **That pin belongs to the npm suite's own inline shader**
   (`struct Inputs { time: f32, resolution: vec2<u32>, brightness: f32 }`,
   `_suite.cjs:186`), *not* to `demo.wgsl` — the Rust fixture's `Params { resolution:
   vec2f, time: f32, frame: u32 }` lays out to **16** bytes, and silently crossing the
   two is the obvious way to write a wrong test. Also: sampler → `AddressSpace ==
   "handle"`, no Layout; compute entry stage + workgroup size; struct field
   names/count; `""` → all-empty envelope with no `errors` key; broken → Errors
   populated *and* `functions` still populated with `InUse:false`; `Version == 2`;
   subset views populated (and carrying whole binding objects, not indices).
2. RED — **wire-fact pins**, decoded from hand-written JSON fixtures so they survive
   shader-corpus drift: texture TypeInfo flat with `TexKind`; binding-level `array`
   key distinct from the array TypeInfo's `format`/`count`/`stride`; `inputs`/
   `outputs` present-but-empty rather than absent; `workgroupSize: null` on a
   vertex/fragment entry point decoding to a nil `*[3]int`; `@workgroup_size(grid)`
   → `[0,1,1]`; `overrides[].id: null`; a fragment return decoding to `Name == ""`.
3. RED — MinifyAndReflect: names in Reflection match a re-Reflect of `.Code`;
   `NameMapped` keeps the original; parse error surfaces in both halves' errors —
   note the asymmetry is real and was re-confirmed: `minify.errors` is
   `[{"message":…}]` objects while `reflect.errors` is `["…"]` bare strings, for the
   same four parse errors.
4. RED — BindGroups grid incl. holes (`grid[0][1]` absent; separate groups).
5. GREEN: reflect.go + Reflection/TypeInfo decoding. `ReflectJSON` returns the raw
   envelope for everything the typed view flattens.
6. Commit: `feat(packages/go): typed reflection with bind-group helper`.

### Block 4 — Compile

1. RED — table: basic compute shader → no error, `WASM` starts `00 61 73 6d`,
   `OriginalSize == len(src)`; **the produced module runs**: instantiate it under
   wazero *in the test*, call `generate()`, decode `memory[0:len]`, assert it
   contains `@compute` (the strongest npm pin, and pure Go makes it cheap);
   options change the generated module; unparseable source →
   `errors.AsType[*CompileError]` with non-empty Diagnostics.
2. GREEN: compile.go.
3. Commit: `feat(packages/go): binary shader compiler binding`.

**Executed.** Corrections learned in the doing, beyond the options amendment
above: "options change the generated module" is only true of four of the eleven
(see § Wire contracts), so the options row became a table of *which* — the seven
that are silently ignored are the part a caller cannot guess from the type.
`wasm_len == 0` and non-empty diagnostics coincide today, so the error is keyed
on the diagnostics (Rust does the same) and an empty module with nothing said
about it is a separate `ErrInternal` rather than a success with an unusable
`WASM` field. Also worth knowing for Block 6: the produced module round-trips
through `Validate` cleanly, which makes "compile → generate → validate" a cheap
end-to-end assertion available to any later block that wants one.

### Block 5 — refactor family

1. RED — tables mirroring `packages/rust/…/tests/refactor.rs` + npm pins: refs for
   `helper` with exactly 1 write (the declaration itself is the `isWrite:true` entry);
   `WithoutDeclaration` drops the decl; no symbol → empty + nil error (also true for a
   wildly out-of-range offset — no trap, no error, just `[]`); rename → edits spelling
   `helper`→`scale`; keyword target (`"fn"`) → `errors.Is(err, ErrInvalidIdentifier)`;
   missing symbol → `ErrSymbolNotFound`; RenameApply failure echoes original source
   with `"ok":false`; exact stable-id strings — probed forms: `"v1:fn:helper"`,
   `"v1:var:u"`, `"v1:struct:Params/member:a"`, `"v1:fn:helper/param:x"`,
   `"v1:fn:cs_main/block#0/let:y"`, `"v1:override:grid"`, `"v1:alias:F"`; id survives a
   prepended comment; `LocateStableID` after deleting the symbol → `ok=false,
   err=nil`; unknown-version id `"v2:…"` → `ok=false`; `ChangeTypeApply` struct-member
   case; `ChangeType` on an inferred `let` → `ErrNoTypeAnnotation`;
   `RemoveDeclarationApply` single deletion edit with empty NewText; UTF-8
   byte-offset pin — a source whose first line is `// 🎨🎨 comment` puts `fn héllo` at
   **byte** 23 (rune 19), and the reference spans come back as byte offsets.
2. Unit table for the wire-string → sentinel map, including the two branches
   integration can't provoke (`"not a removable declaration"`, `"id too long"` —
   confirmed unreachable, see the provocation table in § Wire contracts) — same trick
   as the Rust unit tests.
3. GREEN: refactor.go, and the refactor sentinels added to `errors.go` (which
   already exists — Block 1 created it for `ErrInvalidUTF8` and the two
   re-exported ABI sentinels).
4. Commit: `feat(packages/go): refactor and stable-id operations`.

**Executed.** The provocation table above was wrong in three places; the
amendment there is the record. Beyond it:

- **`ByteRange` was not added.** `Span` already existed for reflection, means
  exactly the same thing, and its JSON tags already match the locate wire
  (`{"start","end"}`) — a second identical type would have been a second concept
  for one idea. `Edit` and `Reference` **embed** it, so `e.Start` and `e.Span`
  both work and the flat wire decodes straight in. `Span` and `StableID` moved
  out of the reflection section of `types.go` into a shared one.
- **One sentinel more than the plan listed: `ErrInvalidOffset`.** The plan says
  offsets are "validated >= 0" without saying what that failure is. It covers a
  negative offset and one beyond u32 — the two an offset into a Go string could
  not have produced. An offset merely *past the end* is deliberately **not** one:
  the engine answers "nothing there", which is true and is what an editor probing
  blindly wants.
- The `"not found"` reason is handled before the sentinel map rather than in it,
  so the map stays a map of *failures*. `refactor_internal_test.go` pins both
  halves: `notFoundReason` maps to no sentinel, and an unrecognised reason stays
  an error carrying the engine's words.
- Five mutations verified the pins bite (each restored, restoration diffed):
  passing `Declarations` through as a raw number (8 failures), routing absence
  through the failure map (7), letting an apply failure hand back the echoed
  original (5), dropping an unrecognised reason (2), truncating an unsendable
  offset (3). One of them first reported *zero* failures because the mutation did
  not compile and `grep -c '--- FAIL'` saw nothing — the false-green trap; check
  the build, not just the grep.

### Block 6 — concurrency + performance ([PERF])

Mastery: CONCURRENCY (Pool discipline), ZERO_ALLOC (benchmark discipline).

1. RED — `-race` stress test: N goroutines × M mixed ops via `sync.WaitGroup.Go`,
   all results independently correct (this already passes with the mutex — it pins
   correctness before the optimization). This test has teeth: the same shape *without*
   the mutex failed 959/960 calls when probed directly against the raw ABI, so a
   regression that drops the lock cannot slip through quietly.
2. Benchmarks first: `BenchmarkMinify{Small,Large}`, `BenchmarkParallelMinify`
   (`b.RunParallel`), all `for b.Loop()` + `b.ReportAllocs()`. Record baseline with
   `-count=6 -benchmem` + benchstat. Rough expectations from the raw-ABI probe:
   ~57 µs/minify serial for a 445-byte shader, ~6.4× throughput at 8-way parallel with
   per-goroutine instances, ~32 µs to instantiate, ~127 ms one-time compile.
3. Implement the instance pool (`sync.Pool` of instances; discard oversized-memory
   instances instead of Put; **discard trapped instances unconditionally**;
   compile-once shared). Re-run benchstat; the pool lands **only if** parallel
   throughput materially improves; either way the evidence goes in the commit message.
4. Leak test: 10k sequential minifies → `Memory().Size()` stabilizes. The prior is
   strong — 500 sequential minifies moved it by exactly 0 bytes — so a *failure* here
   means a genuine unbalanced free, not noise; treat it as a bug, not a threshold to
   tune.
5. Decide `WithCloseOnContextDone` here with a cancellation test if adopted. Note it
   interacts with the discard rule: a context-closed module is dead and must be
   retired, which is the behaviour the ABI layer already needs for traps.
6. Commit: `perf(packages/go): instance pooling with benchstat evidence` (or a
   `docs:` commit recording why the mutex stays).

**Executed.** The pool landed; the numbers are in the measured-costs section above.
Four things the plan did not anticipate:

- **`sync.Pool` is unusable here, and not for a performance reason.** wazero threads
  every instance onto a list rooted in the runtime — anonymous ones included
  (`internal/wasm/store_module_list.go:61`, `registerModule` appends to
  `s.moduleList` regardless of name) — and only `Close` unlinks it. An instance a
  `sync.Pool` discards at GC is therefore *still reachable*, so it is never
  collected and its linear memory never comes back. Every GC would have leaked a few
  megabytes, permanently. The pool is two channels instead: `idle` holds instances,
  `permits` holds the right to build one, and their sum is invariant so neither can
  block on send.
- **Reuse must beat creation explicitly.** A single channel of instances-or-empty-slots
  is FIFO, so purely sequential calls take an empty slot every time and build the
  whole pool. `acquire` does a non-blocking receive on `idle` *before* the blocking
  select, because that select would otherwise choose at random between an idle
  instance and a permit. Pinned by `TestPoolGrowsOnlyUnderContention`.
- **Cancellation is honoured at the queue, not inside the call.** `acquire` checks
  `ctx.Err()` before its selects — a select whose cases are both ready picks at
  random, so a caller who has already given up has to be turned away explicitly
  rather than by a `case <-ctx.Done()`. Interrupting a *running* call needs
  `WithCloseOnContextDone`, which costs 4.5× on every call and is rejected; the
  package documents that a cancelled context stops a call from starting and nothing
  more.
- **An instance is retired on error *or* size.** `memoryLimit` is 8 MiB: guest memory
  only grows (a fresh instance settles at ~1.8 MB and rises ~70 bytes per byte of
  source), so without a cap one outsized shader leaves the whole pool holding its
  high-water mark for the life of the process.

Six mutations, each confirmed to compile before being believed: dropping the
`ctx.Err()` check (4 failures), dropping reuse-before-create (8 instances where 1 is
wanted), never retiring on error (idle+permit assertions), ignoring `oversized`,
leaking the result envelope (the leak test catches it at iteration 312 of 10,000),
and releasing an instance one line before the call that uses it — which does not
produce wrong answers but kills the process with a split stack overflow raised from
inside the guest.

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

**Executed.** The tool is `packages/go/cmd/wgslgen`, and the plan's four flags were
not enough — reading `packages/rust/wgslender-macros/src/lib.rs` (on the unmerged
`rust-examples` branch) settled the surface:

- **The generator validates, and that is the point.** `include_wgsl!` defaults to
  `validate = true` and fails the build on a diagnostic; a Go tool that only minified
  would be strictly worse than its Rust sibling, because minification does not care.
  `testdata/broken.wgsl` proves it: the validator rejects it with `E0100`, and
  `Minify` shortens it 265 → 73 bytes reporting **no errors at all**. So `-validate`
  (default true), `-strict`, `-keep-names`, and one flag per `MinifyOptions` boolean.
  A shader that does not *parse* is refused either way, since the minifier hands back
  the source verbatim and there is nothing to embed.
- **The minify flags are tri-state, so `flag.Bool` cannot express them.** Absent means
  "wgslender decides", which is not false; `flag.Bool` would have this tool pinning a
  stale copy of the engine's defaults. `optBool` implements `flag.Value` over
  `wgslender.Opt[bool]` and records only what was given. Its `String` tolerates a nil
  target because the flag package calls it on a zero value of the type to decide
  whether to print a default.
- **`-var` is required rather than derived.** A name derived from the filename is one
  every caller has to predict, and `2d-blur.wgsl` has no good answer. The error
  suggests one instead.
- **Warnings are reported and not fatal**, mirroring the validator's own reading;
  `-strict` is what promotes them, and `-strict -validate=false` is refused rather
  than resolved.

The plan's "the golden test builds it with `go build` in a temp module" is what makes
the goldens mean anything, and it needs to be `go test`: the round-trip is a run-time
claim about `sync.OnceValue` and DEFLATE, not a typing one. The three goldens are
written into one temp module with a generated `_test.go` asserting
`BlurCompressed() == Blur`.

Two findings worth keeping:

- **A golden comparison cannot check its own golden.** `TestGeneratedCodeBuildsAndRoundTrips`
  reads the files on disk, so it is the only thing standing behind `-update`: mutating
  the accessor *and* regenerating the goldens leaves `TestGolden` green and that test
  the sole failure. The two are a pair, not redundant.
- **`format.Source` was unpinnable from the output.** The templates are written out
  gofmt-clean, so making `formatGo` a pass-through changed nothing any golden could
  see — the mutation survived. What it protects is a *template edit*, so the pin is
  now a unit test on `formatGo` itself.

Nine mutations, each confirmed to compile before being believed: never validating (5
failures), `formatGo` as a pass-through (survived until the pin above existed),
`optBool.Set` not recording (`TestGolden/named`), an accessor that does not round-trip
with goldens regenerated (the temp-module test alone), `-o` also writing to stdout,
dropping the `-strict`/`-validate` guard, `unexport` leaving the stream constant
exported, warnings reported only when fatal, and a usage error exiting zero.

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

**Executed.** `-module` is a flag on the existing tool rather than a second tool: it
appends the shader's interface to the file `-var` already produced, and writes the
layout proof beside it. Four decisions the plan did not settle, each of them read out
of the reflection rather than reasoned about:

- **Nothing is refused for having no Go type.** This is the one place the Go binding
  deliberately does *more* than its Rust sibling, which refuses the whole invocation
  by name (`tests/ui/module_padded_matrix.stderr`). Rust has to: a proc macro's
  natural failure is a compile error, and a partially expanded module with a field
  silently missing would be a landmine. wgslgen writes a file a person reads, so the
  answer can be visible instead: a member Go cannot spell becomes **padding of
  exactly its reflected size** — so every member after it stays put — plus a
  `<Struct><Member>Offset` constant, a comment saying why, and a `note:` on stderr.
  A `mat3x3f` in a uniform struct is common enough that refusing it would make
  `-module` useless for the shaders most likely to want it.
- **The layout proof is a generated `_test.go`, so `-module` requires `-o`.** Go does
  have a compile-time equality assert (`[1]struct{}{}[unsafe.Sizeof(T{})-N]`, which
  fails to index when the difference is not zero), and it was rejected: its error is
  `invalid argument: index 4 out of bounds`, which names neither the struct nor the
  shader. The proof file's derived name inserts `_test` **before the extension**
  (`layouts_gen.go` → `layouts_gen_test.go`), which is also what lets the golden pair
  be pinned as `module.golden` / `module_test.golden`.
- **Names come from the shader, and `-prefix` is the way out.** Go has no module
  namespace to put them in, so two shaders generated into one package can collide on
  a struct they both call `Params`. Collisions are refused by name rather than left
  to the Go compiler, whose complaint would be about an identifier nobody wrote.
  Exporting every generated name also settles the keyword problem for free: every Go
  keyword is lower case, so `range`, `map` and `func` — all of them ordinary WGSL
  member names, all verified accepted by the parser — are `Range`, `Map` and `Func`.
- **Structs are emitted in declaration order**, recovered from each struct's first
  member's `NameOffset`, because reflection hands them over as a map. Sorting by name
  would be one line and would put the file in an order matching nothing the author
  can see.

Facts that came out of probing the live engine, none of them in the plan:

- **`format` is a nested `TypeInfo` on vec/mat/array/atomic**, and the component
  chain has to be walked to know a stride. `mat3x3f` reflects as `stride: 16` with
  `rows: 3`; `array<vec3f, 4>` as `stride: 16` with an element of `size: 12`. Both
  are the padded case, reached by two different rules.
- **A struct that is nothing but a runtime-sized array has `size: 0`** (`Trail`), and
  its member has `size: 0` with `count: null`. It generates `type Trail struct{}`
  and the proof asserts `unsafe.Sizeof(Trail{}) == 0`.
- **Entry-point IO structs are in `Structs` too** (`VertexOut` with
  `@builtin(position)`), with layouts computed. They are generated like any other:
  a struct the shader merely declares is still one a host may want to describe.
- **`bool` reflects as a scalar of size 4** even though WGSL bools are not
  host-shareable. It is unmapped, like `f16`, and takes the padding path.
- **Go inserts no padding of its own** on top of what is written, and that is not a
  hope: every generated type is built from 4-byte scalars, so every field's Go
  alignment is 4 and every WGSL offset for such a member is a multiple of 4. What Go
  *cannot* be told is a struct's own alignment — WGSL aligns `Scene` to 16, Go
  computes 4 from the fields — so the proof checks sizes and offsets and says nothing
  about alignment, which is documented in the generated struct's own doc comment.

Two testing notes:

- **`t.Chdir` is what makes a golden of a generated header possible.** The header
  records the command line verbatim, so a temporary directory anywhere on it is a
  golden that never matches twice. Each case copies its fixture into a directory of
  its own and runs there, so every path on the command line is short and relative.
- **The generated proof is checked by running it.** `TestGeneratedModuleProvesItsLayout`
  writes the pair into a temp module and runs `go test`; `TestLayoutProofCatchesAWrongLayout`
  widens one `_ [4]byte` to `_ [8]byte` and insists it fails. Without the second, a
  proof that asserted nothing would pass exactly as loudly as one that asserted
  everything.

Ten mutations, each confirmed to compile before being believed (two did not on the
first attempt and were rewritten — `unicode` left unused, `ext` declared and unused):
padding never emitted, no trailing pad to the struct size, the matrix stride check
disabled, structs sorted by name, `claim` never colliding, `export` lowercasing,
`-prefix` dropped on a nested struct type, the proof file never written, `proofPath`
returning the module's own path, and the member-collision check disabled. The
strongest was the third: disabling the stride check made the *generated* proof fail
(`TestTransformLayout`), which is the whole point of generating it.

That last mutation exists because reading the finished code found a hole the tests had
not. `claim` covers the module's namespace, so `params` and `Params` as two structs
are refused — but a **field** name lives in its own struct's namespace, and
`struct Params { count: u32, Count: u32 }` was generating a Go struct with two `Count`
fields. It is the same class of mistake, and it was being left to the Go compiler,
whose complaint would have been about a field nobody wrote.

The docs pass renamed the plan's `Example_minify` to **`ExampleMinify`** and its
siblings, so that each example appears beside the function it demonstrates rather
than under the package. A `go/doc` sweep over the package found exactly one
undocumented exported declaration (`CompileError.Error`); the enum constants are
covered by their types' block comments, which is idiomatic and was left alone.

- **New checked-in build artifact**: `packages/go/internal/wasmabi/wgslender.wasm`
  (766 KB duplicate of js-npm's). The rebuild rule extends: *whenever the wire
  changes, `zig build wasm` and copy to BOTH `packages/js-npm/wgslender.wasm` and
  `packages/go/internal/wasmabi/wgslender.wasm`* — enforced locally by Block 0's
  sha-parity test (there is no automated freshness check on the npm side either;
  this adds the first one).
- No existing file is modified by this plan. No `build.zig` changes (a `gen-go`-style
  copy step was considered and rejected — a two-line `cp` documented in README plus
  the parity test is less machinery than a build-graph edit).
- The Go API deliberately diverges from npm in four places (all documented):
  no `initialize()` (lazy init), refactor errors are Go errors rather than `error`
  fields on results, minify errors are flattened `[]string` (Rust parity), and
  **non-UTF-8 input is refused** rather than silently mangled (see below).
- **`ErrInvalidUTF8` — found by Block 1's fuzzer, not predicted by this plan.**
  `Diagnostic.appendJsonEscaped` (`src/Diagnostic.zig:259`) passes every byte
  ≥ 0x20 through verbatim, so a source that is not valid UTF-8 produces a reply
  that is not valid UTF-8 either; `encoding/json` then substitutes U+FFFD without
  complaint and the caller gets back bytes that are not theirs (`"let\x95"` →
  `MinifiedSize` 4, `len(Code)` 6). Rust cannot reach this — `&str` is UTF-8 by
  construction — and npm does the substituting via `TextDecoder`. Go's `string`
  has no such guarantee, so the binding checks at the boundary: every
  caller-supplied text argument is `utf8.ValidString`-checked before the call
  (`checkUTF8` in `wgslender/errors.go`). Later blocks must apply it to *their*
  string arguments too — source, new names, stable IDs, type text.
  Block 2 added the mirror case on the *output* side: `LintFix` re-checks the
  rewritten source, because a fix is a byte-offset splice and a rule that
  computed one mid-rune would produce non-UTF-8 output from UTF-8 input. Any
  later op that returns engine-rewritten text (the refactor family in Block 5)
  owes the same check.
- `MinifyOptions` deliberately omits `sourceMapInline` even though `Config` parses it,
  because the wasm minify path ignores it (see § Wire contracts). Recorded here so a
  later reader doesn't "restore" a knob that would silently do nothing.

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
