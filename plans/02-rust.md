# Plan 02 — Rust example: using WGSLender from Rust (C FFI over `libwgslender.a`)

**Creates:** `examples/rust/` — a Cargo package with hand-written FFI declarations, a
small **safe wrapper** library, three runnable subexamples (**minify**, **validate**,
**reflect**) as Cargo examples, and a table-driven integration test suite.

**Status:** ready to execute. Verified against `main @ 017cb1d`, 2026-08-05, macOS arm64,
zig 0.16.0, rustc/cargo 1.92.0.

---

## Verified current state (do not re-derive)

- **There is no Rust binding anywhere.** The entire Rust story today is a 2-line
  `build.rs` snippet in `docs/C-API.md:18-22`. `external/wgsl-analyzer` and
  `external/naga` are read-only vendored *reference* checkouts, unrelated.
- `zig build lib` → `zig-out/lib/libwgslender.a` + installed header
  `zig-out/include/wgslender.h`. **Static only** — no shared-library step exists
  (`build.zig:69-83`, `.linkage = .static` hardcoded). Honors `-Dtarget=`/`-Doptimize=`.
  Plain `zig build` does **not** build the lib.
- The C ABI (impl `src/lib.zig`, header `include/wgslender.h`) is **stateless**: no
  init/deinit, one internal arena per call, results copied out via
  `std::heap.page_allocator`. Documented thread-safe (`docs/C-API.md` "Thread Safety").
- **Ownership contract:** every non-NULL result pointer must be freed with
  `wgslender_free_c(ptr, len)` — a **sized** free; the length is required. Never libc
  `free()`. Exception: `wgslender_version_c(&len)` returns a **static** pointer — never
  free it.
- The subset of the ABI this plan binds (header decl line / impl line):

  ```c
  typedef struct { const uint8_t *code_ptr; uint32_t code_len; bool error; } WgslenderResult;
  typedef struct { bool valid; const uint8_t *json_ptr; uint32_t json_len;
                   uint32_t error_count; uint32_t warning_count; } WgslenderValidateResult;
  typedef struct { const uint8_t *json_ptr; uint32_t json_len; bool error; } WgslenderJsonResult;

  WgslenderResult         wgslender_minify_c(const uint8_t *src, uint32_t len, uint32_t flags);        // h:103 / lib.zig:256
  WgslenderResult         wgslender_minify_json_c(const uint8_t *src, uint32_t len,
                                                  const uint8_t *opts, uint32_t opts_len);             // h:111 / lib.zig:274
  WgslenderValidateResult wgslender_validate_c(const uint8_t *src, uint32_t len, uint32_t flags);      // h:119 / lib.zig:297
  WgslenderJsonResult     wgslender_reflect_c(const uint8_t *src, uint32_t len);                       // h:127 / lib.zig:318
  void                    wgslender_free_c(uint8_t *ptr, uint32_t len);                                // h:306 / lib.zig:665
  const uint8_t          *wgslender_version_c(uint32_t *len);                                          // h:312 / lib.zig:670
  ```
- Minify flags (a **frozen** ABI — no new bits will ever be added; new options are
  JSON-only): `WHITESPACE 1<<0, IDENTIFIERS 1<<1, SYNTAX 1<<2, TREE_SHAKING 1<<3,
  MANGLE_EXTERNAL 1<<4, PRESERVE_UNIFORM_STRUCTS 1<<5`; `WGSLENDER_OPT_DEFAULT = 0x0f`.
  Validate flags: `OPT_STRICT = 1<<0`.
- **Load-bearing asymmetry:** both `wgslender_minify_c` and `wgslender_minify_json_c`
  return **plain minified WGSL text** in `code_ptr` — *not* the JSON envelope the WASM/npm
  path gets. There are no size counters, no `errors[]`, no source map on the C surface.
  The JSON `opts` string uses the same camelCase keys as `wgslender.json`
  (`minifyWhitespace`, `minifyIdentifiers`, `minifySyntax`, `treeShaking`,
  `mangleExternalBindings`, `preserveUniformStructTypes`, `keepNames`,
  `sortDeclarations`, `scopeLocalRename`); malformed options JSON silently degrades to
  defaults (`lib.zig:274-290`, `Config.parseJson … catch Config{}`).
- Error signalling differs per struct: `WgslenderResult`/`WgslenderJsonResult` → check
  `.error`; `WgslenderValidateResult` has **no** error flag → `json_ptr == NULL` means
  internal failure (`lib.zig:125-127`).
- Documented minifier contract: on parse errors it returns the **original source
  unchanged**, never partial output (`BUILDING_WITH_WGSLENDER.md:547-558`). Block 2
  verifies this empirically and pins the observed behavior.
- Validate JSON envelope (newline-free, `src/api_json.zig:214-231`):
  `{"valid":bool,"diagnostics":[…],"errorCount":N,"warningCount":N}` — each diagnostic:
  `{"severity":"error"|"warning"|…,"message":…,["code":"E0200"],"line":N,"column":N,…}`
  (1-based positions; optional keys omitted when empty).
- Reflect JSON is the **v2 envelope**, identical bytes to what the npm package parses:
  `{"version":2,"bindings":[…],"uniforms":[…],"storage":[…],"textures":[…],"samplers":[…],
  "structs":{…},"entryPoints":[…],"overrides":[…],"functions":[…],"aliases":[…][,"errors":[…]]}`.
- Library version: `1.1.0`. The macOS linker may warn about a macOS-version mismatch in
  the archive — harmless, ignore it.

## Ground rules

- TDD reds-first. In Rust, "the test fails to **compile** because the API doesn't exist
  yet" is a legitimate red for a new API — each block states the exact expected red
  (compile error vs assertion failure) and requires confirming it before implementing.
- Tests are table-driven (fixture files + a `Case` array); a new scenario is a row.
- No CI; the only entry points are `cargo test` / `cargo run --example …`.
- One conventional commit per block. Commit `Cargo.lock` (this is a leaf example
  project, not a published library).
- Repo convention (from prior feedback): **no boolean parameters in the public wrapper
  API** — use named enums (`Strictness::{Default, Strict}`), and express buffer
  ownership as a named RAII type, not raw pointer/len pairs.
- Exact reflect numbers are pinned from the CLI oracle
  (`./zig-out/bin/wgslender reflect <file>`), never guessed.

## Target layout

```
examples/rust/
  Cargo.toml            package wgslender-example, edition 2021, [workspace] (empty, isolates from any outer workspace)
  Cargo.lock            committed
  build.rs              runs `zig build lib` at the repo root, emits link-search + link-lib
  src/
    ffi.rs              #[repr(C)] structs + extern "C" decls (private module)
    lib.rs              safe wrapper: version, minify, minify_with, validate, reflect
  examples/
    minify.rs
    validate.rs
    reflect.rs
  tests/
    integration.rs      table-driven suite (+ runs the example binaries)
    fixtures/
      demo.wgsl         same fixture family as plan 01 (embedded below — plans are self-contained)
      invalid.wgsl
      warning.wgsl
  README.md
```

---

## Block 1 — Scaffold, `build.rs`, FFI, `version()` (red: test doesn't compile)

**Context recap:** nothing exists under `examples/rust/`. The repo root has no
`Cargo.toml` (no workspace capture risk, but the empty `[workspace]` table guards it
anyway). `zig` 0.16.0 is on PATH (`zigup 0.16.0` if missing).

1. Scaffold:
   - `Cargo.toml`:
     ```toml
     [package]
     name = "wgslender-example"
     version = "0.1.0"
     edition = "2021"          # 2021 on purpose: plain `extern "C"` blocks, no unsafe-extern ceremony
     publish = false

     [dependencies]
     serde = { version = "1", features = ["derive"] }
     serde_json = "1"

     [workspace]
     ```
   - Append `examples/rust/target/` to the repo root `.gitignore`.
2. `build.rs` — self-contained builds: always (re)run `zig build lib` (Zig's cache makes
   the no-change case fast), then emit link directives:
   ```rust
   use std::{env, path::PathBuf, process::Command};

   fn main() {
       let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
       let repo_root = manifest.ancestors().nth(2).unwrap().to_path_buf(); // examples/rust -> repo root
       let status = Command::new("zig")
           .args(["build", "lib"])
           .current_dir(&repo_root)
           .status()
           .expect("failed to run `zig` — install Zig 0.16.0 (e.g. `zigup 0.16.0`)");
       assert!(status.success(), "`zig build lib` failed");
       println!("cargo:rustc-link-search=native={}", repo_root.join("zig-out/lib").display());
       println!("cargo:rustc-link-lib=static=wgslender");
       for f in ["src/lib.zig", "src/api_json.zig", "include/wgslender.h", "build.zig"] {
           println!("cargo:rerun-if-changed={}", repo_root.join(f).display());
       }
   }
   ```
3. **Red.** Create `tests/integration.rs` starting with only the version case, written
   against the not-yet-existing wrapper:
   ```rust
   use wgslender_example::version;

   #[test]
   fn version_is_semver() {
       let v = version();
       assert_eq!(v.split('.').count(), 3, "expected semver, got {v:?}");
   }
   ```
   `cargo test` → **expected red:** `E0432 unresolved import wgslender_example::version`
   (the crate compiles empty or doesn't exist yet). Confirm.
4. **Green.** `src/ffi.rs` (private): the three `#[repr(C)]` structs and six `extern "C"`
   fns exactly as in the header subset above. Notes for the executor:
   - Rust `bool` is ABI-compatible with C `_Bool` — use it for the `error`/`valid`
     fields, but name the field `error_` or `is_error` in Rust (`error` is fine too;
     it is not a Rust keyword — keep `error` to mirror the header).
   - All lengths are `u32`. Pointers in results are `*const u8`; `wgslender_free_c`
     takes `*mut u8` (cast at the call site).
   `src/lib.rs`: the RAII buffer type + `version()`:
   ```rust
   /// Bytes owned by libwgslender; freed with the library's sized free on Drop.
   struct LibBuffer { ptr: std::ptr::NonNull<u8>, len: u32 }
   impl LibBuffer {
       /// Adopts (ptr, len) from a result struct. Returns None for NULL.
       unsafe fn adopt(ptr: *const u8, len: u32) -> Option<Self> { … }
       fn as_bytes(&self) -> &[u8] { … }
       fn into_string(self) -> Result<String, std::str::Utf8Error> { … } // copies, then Drop frees
   }
   impl Drop for LibBuffer {
       fn drop(&mut self) { unsafe { ffi::wgslender_free_c(self.ptr.as_ptr(), self.len) } }
   }

   pub fn version() -> &'static str { … } // wgslender_version_c: static ptr, NOT wrapped in LibBuffer
   ```
   `version()` must **not** free — that's exactly why the ownership lives in a named
   type: the static pointer never becomes a `LibBuffer`.
5. `cargo test` → green (1 test). First build also proves the whole link chain
   (`zig build lib` + static link) works.
6. Commit: `feat(examples): rust scaffold — build.rs link chain, FFI decls, version()`

---

## Block 2 — `minify` + `minify_with` (red: assertion table fails to compile, then runs)

**Context recap:** `examples/rust/` compiles; `LibBuffer` (RAII, sized free) and the FFI
module exist. `wgslender_minify_c(src, len, flags)` / `wgslender_minify_json_c(src, len,
opts_json, opts_len)` both return `WgslenderResult { code_ptr, code_len, error }` holding
**plain minified WGSL text** (no envelope, no sizes, no error list — C-surface
asymmetry vs npm). Default flags `0x0f`. Malformed options JSON degrades silently to
defaults. Documented contract: parse errors return the original source unchanged.

1. Add fixtures `tests/fixtures/{demo,invalid,warning}.wgsl` — identical content to
   plan 01 Block 1 (self-contained copy):
   - `demo.wgsl`: `Params` uniform struct (`resolution: vec2f, time: f32, frame: u32`),
     `@group(0) @binding(0) var<uniform> params`, `@group(0) @binding(1)
     var<storage, read_write> data: array<vec4f>`, `@group(1)` texture+sampler, helper
     `fn luminance(c: vec3f) -> f32`, `@compute @workgroup_size(8, 8, 1) fn main(...)`
     using all of them.
   - `invalid.wgsl`: `fn main() -> f32 { return undeclared_variable; }`
   - `warning.wgsl`: storage buffer + `@compute @workgroup_size(64)` entry with
     `workgroupBarrier()` inside `if (i < 32u) { … }` (non-uniform ⇒ warning).
   Sanity-check all three against the CLI (`zig build` then
   `./zig-out/bin/wgslender validate <f>`): demo passes, invalid fails, warning has
   ≥1 warning / 0 errors. Adjust fixture + expectations to the oracle if needed.
2. **Red.** Extend `tests/integration.rs` with a table-driven minify suite against the
   not-yet-existing API (compile-error red first, assertion red after):
   ```rust
   struct MinifyCase {
       name: &'static str,
       source: &'static str,
       options: Option<MinifyOptions>,
       check: fn(&str, &str), // (original, minified)
   }
   ```
   Rows: (a) demo/defaults ⇒ `minified.len() < original.len()`, contains `@compute`
   and `fn main`; (b) demo + `keep_names: ["luminance"]` ⇒ contains `luminance`,
   while row (a)'s output must not; (c) demo + whitespace-only options
   (`minify_identifiers: false, minify_syntax: false`) ⇒ still contains `params`;
   (d) `invalid.wgsl`/defaults ⇒ **pin the observed contract**: expected per docs to
   return the input unchanged with `error == false` — write the assertion, run, and
   correct it to whatever actually happens, citing `BUILDING_WITH_WGSLENDER.md:547-558`
   in a comment. Confirm red (`E0432`/`E0425` on `minify`, `MinifyOptions`).
3. **Green.** In `src/lib.rs`:
   ```rust
   #[derive(serde::Serialize, Default, Clone)]
   #[serde(rename_all = "camelCase")]
   pub struct MinifyOptions {
       pub minify_whitespace: Option<bool>,
       pub minify_identifiers: Option<bool>,
       pub minify_syntax: Option<bool>,
       pub tree_shaking: Option<bool>,
       pub mangle_external_bindings: Option<bool>,
       pub preserve_uniform_struct_types: Option<bool>,
       #[serde(skip_serializing_if = "Option::is_none")]
       pub keep_names: Option<Vec<String>>,
       pub sort_declarations: Option<bool>,
       pub scope_local_rename: Option<bool>,
   }
   // (serialize None-skipping for every field: `#[serde(skip_serializing_if = "Option::is_none")]` on all)

   pub fn minify(source: &str) -> Result<String, Error>;                       // minify_c, WGSLENDER_OPT_DEFAULT
   pub fn minify_with(source: &str, options: &MinifyOptions) -> Result<String, Error>; // serde_json → minify_json_c
   ```
   `Error` is a small enum (`Internal`, `InvalidUtf8`) with `Display`. `.error == true`
   maps to `Error::Internal`.
4. `cargo test` → minify rows green. Commit:
   `feat(examples): rust minify wrapper + table-driven tests`

---

## Block 3 — `validate` (red: assertion table)

**Context recap:** `wgslender_validate_c(src, len, flags)` returns
`WgslenderValidateResult { valid, json_ptr, json_len, error_count, warning_count }`;
`json_ptr == NULL` (there is no `error` field) signals internal failure; flags bit 0 =
strict. JSON envelope: `{"valid":…,"diagnostics":[{"severity","message",["code"],
"line","column",…}],"errorCount":…,"warningCount":…}` — camelCase, 1-based positions.
Fixtures from Block 2 exist.

1. **Red.** Table over the not-yet-existing API:
   ```rust
   pub enum Strictness { Default, Strict }   // no boolean parameters — repo convention
   ```
   Rows: (a) demo/Default ⇒ `valid, error_count == 0`; (b) invalid/Default ⇒ `!valid`,
   `error_count >= 1`, first diagnostic has non-empty `code` starting with `'E'`,
   `line >= 1 && column >= 1`, severity == `"error"`; (c) warning/Default ⇒
   `warning_count >= 1 && valid`; (d) warning/Strict ⇒
   `strict.error_count >= default.error_count + default.warning_count` (the same
   invariant the npm suite pins). Confirm compile-red.
2. **Green.** `src/lib.rs`:
   ```rust
   #[derive(serde::Deserialize, Debug)]
   #[serde(rename_all = "camelCase")]
   pub struct Diagnostic { pub severity: String, pub message: String,
                           #[serde(default)] pub code: Option<String>,
                           pub line: u32, pub column: u32 }
   #[derive(Debug)]
   pub struct Validation { pub valid: bool, pub error_count: u32,
                           pub warning_count: u32, pub diagnostics: Vec<Diagnostic> }

   pub fn validate(source: &str, strictness: Strictness) -> Result<Validation, Error>;
   ```
   Parse via an internal `#[serde(rename_all = "camelCase")]` envelope struct with a
   `diagnostics` field; do **not** set `deny_unknown_fields` anywhere (the wire may
   grow keys like `specRef`/`related`/`fix` — tolerance is deliberate).
3. `cargo test` → validate rows green. Commit:
   `feat(examples): rust validate wrapper + diagnostics parsing`

---

## Block 4 — `reflect` (red: assertion table with oracle-pinned numbers)

**Context recap:** `wgslender_reflect_c(src, len)` returns
`WgslenderJsonResult { json_ptr, json_len, error }` holding the v2 reflect envelope —
byte-identical JSON to the npm package's, so key names are camelCase: `bindings[]`
entries carry `group, binding, name, addressSpace, type, layout{size, alignment}, …`;
`structs` maps name → `{size, alignment, fields:[{name, type, offset, size, …}]}`;
`entryPoints[]` carry `{name, stage, workgroupSize: [x,y,z]|null, …}`.

1. **Pin the oracle.** `zig build` then
   `./zig-out/bin/wgslender reflect examples/rust/tests/fixtures/demo.wgsl`. Record
   `structs.Params.size/.alignment` (expected 16 / 8 — confirm), field offsets
   (`resolution@0, time@8, frame@12` — confirm), and the four bindings'
   `addressSpace` values (`uniform`, `storage`, and `handle` ×2 — confirm).
2. **Red.** Table rows against the not-yet-existing `reflect`: (a) `version == 2`;
   (b) `bindings.len() == 4` with the pinned `(group, binding, name, address_space)`
   tuples; (c) uniform binding's `layout.size` equals `structs["Params"].size`;
   (d) `Params` size/alignment/offsets == pinned numbers; (e) exactly one entry point
   `("main", "compute", Some([8, 8, 1]))`; (f) `reflect` on `invalid.wgsl` ⇒ envelope's
   `errors` is non-empty (the call itself still succeeds — reflect degrades, it
   doesn't fail). Confirm compile-red.
3. **Green.** Serde subset (tolerant, no `deny_unknown_fields`):
   ```rust
   #[derive(serde::Deserialize)] #[serde(rename_all = "camelCase")]
   pub struct Reflection { pub version: Option<u32>, pub bindings: Vec<Binding>,
       pub structs: std::collections::HashMap<String, StructLayout>,
       pub entry_points: Vec<EntryPoint>, #[serde(default)] pub errors: Vec<String> }
   #[derive(serde::Deserialize)] #[serde(rename_all = "camelCase")]
   pub struct Binding { pub group: u32, pub binding: u32, pub name: String,
       pub address_space: String, #[serde(rename = "type")] pub ty: String,
       pub layout: Option<Layout> }
   #[derive(serde::Deserialize)] pub struct Layout { pub size: u32, pub alignment: u32 }
   #[derive(serde::Deserialize)] #[serde(rename_all = "camelCase")]
   pub struct StructLayout { pub size: u32, pub alignment: u32, pub fields: Vec<Field> }
   #[derive(serde::Deserialize)] #[serde(rename_all = "camelCase")]
   pub struct Field { pub name: String, #[serde(rename = "type")] pub ty: String,
       pub offset: u32, pub size: u32 }
   #[derive(serde::Deserialize)] #[serde(rename_all = "camelCase")]
   pub struct EntryPoint { pub name: String, pub stage: String,
       pub workgroup_size: Option<[u32; 3]> }

   pub fn reflect(source: &str) -> Result<Reflection, Error>;
   ```
4. `cargo test` → reflect rows green. Commit:
   `feat(examples): rust reflect wrapper with typed serde subset`

---

## Block 5 — Example binaries, runner tests, README, index row

**Context recap:** the wrapper (`version/minify/minify_with/validate/reflect`) is green
under `cargo test`. Cargo builds `examples/*.rs` during `cargo test`, so the binaries
exist at `<target-dir>/debug/examples/<name>` by the time integration tests run.

1. **Red.** Add a runner table to `tests/integration.rs`: for each of
   `minify`, `validate`, `reflect`, spawn
   `<target>/debug/examples/<name>` (target dir = `$CARGO_TARGET_DIR` or
   `<manifest>/target`), assert exit 0 and expected stdout substrings
   (mirror plan 01's Suite A: sizes line + `@compute` for minify; `valid` / `INVALID` /
   an `E`-code / `strict` for validate; `Params` + `16` + `main [compute]` for reflect).
   Red: the three example files don't exist ⇒ spawn fails.
2. **Green.** Write the three examples, each ~40 lines, `include_str!`-ing the shared
   fixtures from `tests/fixtures/`:
   - `examples/minify.rs`: defaults + `keep_names` variant; prints original/minified
     byte counts, % saved, and the minified code.
   - `examples/validate.rs`: iterates the three fixtures, prints
     `<file>: valid` / `<file>: INVALID (E errors, W warnings)` + formatted
     diagnostics; then `warning.wgsl` again with `Strictness::Strict` to show promotion.
   - `examples/reflect.rs`: prints the bindings table
     (`@group(G) @binding(B) name: addressSpace type`), each struct layout with field
     offsets, and each entry point.
3. `cargo test` → whole suite green. Also run each example once by hand
   (`cargo run --example minify` etc.) and eyeball the output.
4. `examples/rust/README.md`: prerequisites (Zig 0.16.0 + Rust stable; `build.rs`
   runs `zig build lib` automatically), the three run commands, `cargo test`, the
   sized-free ownership rule, and the **C-surface minify asymmetry** note (plain text
   out; no size counters/error list — compute sizes yourself, as `examples/minify.rs`
   does).
5. Create-or-append `examples/README.md` row:
   `| rust | Rust over libwgslender.a (FFI) | cd examples/rust && cargo test |`.
6. Final clean-slate check: `cd examples/rust && cargo clean && cargo test` (proves
   `build.rs` rebuilds the archive end-to-end).
7. Commit: `feat(examples): rust example binaries, runner tests, README`

---

## Behavior changes (explicit)

**None.** This plan only adds files under `examples/rust/` plus one `.gitignore` line.
It does not touch `src/`, the header, the ABI, or any wire format.

Candidate follow-ups deliberately **out of scope** (each would be a real change needing
its own decision): a shared-library (`.dylib`/`.so`) build step in `build.zig` for
dynamic linking; a published `wgslender-sys` crate with bindgen against
`include/wgslender.h` (note: the header is hand-written with **no drift test** against
`src/lib.zig`'s exports — worth flagging in any -sys discussion); binding the wider ABI
(lint, compile, stable-id refactors, `minify_and_reflect` which *does* return a full
JSON envelope).

## Definition of done

- [ ] `cargo test` green in `examples/rust/` from a clean clone (only Zig 0.16.0 +
      stable Rust required; `build.rs` handles `zig build lib`).
- [ ] `cargo run --example minify|validate|reflect` each produce the documented output.
- [ ] All buffer frees go through the `LibBuffer` Drop (sized free); `version()` never
      frees; no `unsafe` outside `src/ffi.rs` + `LibBuffer`.
- [ ] Strictness/ownership expressed as named types — zero boolean parameters in the
      public wrapper API.
- [ ] Reflect numbers oracle-pinned; minify parse-error contract empirically pinned.
- [ ] `Cargo.lock` committed; `examples/rust/target/` gitignored; no CI files.
