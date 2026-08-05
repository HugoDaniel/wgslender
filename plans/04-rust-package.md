# Plan 04 — `packages/rust/`: a publishable Cargo workspace for WGSLender

**Creates:** `packages/rust/` — a Cargo workspace holding a real, publishable Rust
package family: raw FFI (`wgslender-sys`), safe API covering the **entire** C ABI
(`wgslender-core`), compile-time proc-macros (`wgslender-macros`), and the user-facing
facade crate (`wgslender`). It lives beside `packages/js-npm/` — the `packages/`
directory was created by commit `29b038e` explicitly "ahead of adding sibling language
packages (per plans/)".

**Motivation (verbatim user report, via miniray):** *"i'm using miniray for rust macros
atm to minify, then compress shaders and include them compressed in binary at compile
time."* That is exactly the headline feature here: `include_wgsl!` /
`include_wgsl_compressed!` proc-macros that validate + minify (+ deflate) WGSL at
compile time and embed the result, plus `wgsl_module!` codegen that turns shader
reflection into typed `#[repr(C)]` Rust structs with compile-time layout proofs.

**Status:** ready to execute. Verified against `main @ 29b038e`, 2026-08-05, macOS
arm64, zig 0.16.0, rustup-managed stable rustc/cargo 1.92.0. (The npm package moved to
`packages/js-npm/` at `29b038e`; this plan was written against that layout.)

**Relationship to plan 02 (`plans/02-rust.md`):** plan 02 builds a small *example*
(`examples/rust/`) with a hand-rolled wrapper over 6 of the 22 ABI functions. This plan
builds the *product*. If you execute 04, plan 02 is superseded: either skip it, or
re-scope its example to consume this workspace via a `path` dependency (a one-session
rewrite; Hugo decides). Do not execute both as written — they'd duplicate the wrapper.

---

## Verified current state (do not re-derive)

Environment (all verified 2026-08-05):

- `rustup` manages the toolchain: `stable-aarch64-apple-darwin` = rustc/cargo **1.92.0**.
  A `rust-toolchain.toml` pin is therefore viable.
- `zig build lib -Doptimize=ReleaseFast -p <prefix>` **works**: installs
  `<prefix>/lib/libwgslender.a` (~7.1 MB ReleaseFast) and `<prefix>/include/wgslender.h`.
  This is the key fact enabling per-crate `OUT_DIR` installs (no `zig-out/lib` clobbering
  when host and cross target builds run concurrently; Zig's global cache is
  concurrency-safe).
- crates.io API returned **404 (name free)** for `wgslender`, `wgslender-sys`,
  `wgslender-macros` on 2026-08-05 (checked with a proper User-Agent; bare curl gets 403).
  `wgslender-core` was not checked — verify before publishing.
- The C ABI (impl `src/lib.zig`, header `include/wgslender.h`) is **stateless**: no
  init/deinit, one internal arena per call, results copied out via page_allocator.
  Documented thread-safe. Every non-NULL result pointer is freed with the **sized** free
  `wgslender_free_c(ptr, len)`. Exception: `wgslender_version_c(&len)` returns a
  **static** pointer — never free. Library version `1.1.0` (`src/root.zig:11`).

### The full ABI surface (22 exports — this plan binds ALL of them)

Result structs (header `include/wgslender.h:47-95`):

```c
typedef struct { const uint8_t *code_ptr; uint32_t code_len; bool error; } WgslenderResult;
typedef struct { bool valid; const uint8_t *json_ptr; uint32_t json_len;
                 uint32_t error_count; uint32_t warning_count; } WgslenderValidateResult;
typedef struct { const uint8_t *json_ptr; uint32_t json_len; bool error; } WgslenderJsonResult;
typedef struct { uint32_t error_count; uint32_t warning_count;
                 const uint8_t *json_ptr; uint32_t json_len; } WgslenderLintResult;
typedef struct { uint32_t error_count; uint32_t warning_count;
                 const uint8_t *fixed_ptr; uint32_t fixed_len;
                 const uint8_t *json_ptr; uint32_t json_len; } WgslenderLintFixResult;
typedef struct { const uint8_t *wasm_ptr; uint32_t wasm_len; uint32_t original_size;
                 const uint8_t *errors_json_ptr; uint32_t errors_json_len; } WgslenderCompileResult;
typedef struct { const uint8_t *json_ptr; uint32_t json_len; bool error; } WgslenderMinifyAndReflectResult;
```

Functions, grouped (header line / `src/lib.zig` line):

| Group | Function | Notes |
|---|---|---|
| core | `wgslender_minify_c(src, len, flags)` h:103/z:256 | plain text out, bitflags frozen (6 bits, `DEFAULT=0x0f`) |
| core | `wgslender_minify_json_c(src, len, opts, opts_len)` h:111/z:274 | plain text out; JSON opts = `wgslender.json` camelCase keys; malformed JSON silently → defaults |
| core | `wgslender_validate_c(src, len, flags)` h:119/z:297 | flags bit 0 = strict; **no error flag** — `json_ptr == NULL` = internal failure |
| core | `wgslender_reflect_c(src, len)` h:127/z:318 | reflect v2 envelope (byte-identical to npm's) |
| core | `wgslender_minify_and_reflect_c(src, len, opts, opts_len)` h:269/z:582 | `{"minify":{...},"reflect":{...}}` — the **only** C path exposing minify sizes + errors |
| lint | `wgslender_lint_c(src, len, config, config_len)` h:279/z:603 | config JSON = top-level `{"extends":[...],"rules":{...},"reportUnusedDisableDirectives":bool}` (verified `src/Config.zig:474-489`, `api_json.zig:610-621`); empty config = zero rules (analysis diagnostics still merged in) |
| lint | `wgslender_lint_fix_c(...)` h:289/z:621 | + `fixed_ptr` rewritten source |
| compile | `wgslender_compile_c(src, len, opts, opts_len)` h:298/z:643 | WGSL → binary `.wasm` shader; opts = same keys as minify_json |
| refactor | `wgslender_find_references_c(src, len, offset, include_decl)` h:138/z:337 | `{"references":[{"start","end","isWrite"}...]}` (+ optional `"error"`) |
| refactor | `wgslender_rename_c(src, len, offset, new_name, nn_len)` h:153/z:354 | `{"edits":[{"start","end","newText"}...]}`; error strings: `"invalid identifier"`, `"symbol not found"`, `"parse error"` |
| refactor | `wgslender_rename_apply_c(...)` h:168/z:372 | `{"ok":bool,"source":"...","edits":[...][,"error"]}` — `source` always present |
| refactor | `wgslender_stable_id_at_offset_c(src, len, offset)` h:182/z:399 | `{"stableId":"v1:fn:main/..."}` or `{"stableId":null[,"error"]}` |
| refactor | `wgslender_locate_stable_id_c(src, len, id, id_len)` h:193/z:415 | `{"start":N,"end":N}` or nulls+error |
| refactor | `wgslender_rename_by_id_c(src, len, id, id_len, new_name, nn_len)` h:202/z:432 | same shape as rename |
| refactor | `wgslender_locate_declaration_c(...)` h:213/z:459 | full declaration byte range |
| refactor | `wgslender_locate_type_c(...)` h:222/z:476 | type-annotation byte range |
| refactor | `wgslender_remove_declaration_by_id_c(...)` h:231/z:493 | edits shape |
| refactor | `wgslender_remove_declaration_apply_by_id_c(...)` h:240/z:533 | apply shape |
| refactor | `wgslender_change_type_by_id_c(..., new_type, nt_len)` h:249/z:510 | edits shape; extra error string `"no type annotation or invalid replacement"` (`api_json.zig:571`) |
| refactor | `wgslender_change_type_apply_by_id_c(...)` h:259/z:554 | apply shape |
| mem | `wgslender_free_c(ptr, len)` h:306/z:665 | **sized** free |
| meta | `wgslender_version_c(&len)` h:312/z:670 | static ptr, never free |

Wire envelopes (single sources of truth, all camelCase, positions 1-based):

- **minify (JSON paths)**: `{"code":"...","errors":[...],"originalSize":N,"minifiedSize":N[,"sourceMap":...]}`
  — but note the plain-C `minify_c`/`minify_json_c` return **raw text**, not this
  envelope; the envelope appears only inside `minify_and_reflect_c`'s `"minify"` key
  (`src/api_json.zig:102-141`).
- **validate**: `{"valid":bool,"diagnostics":[{"severity","message",["code"],"line","column",…}],"errorCount":N,"warningCount":N}`.
- **lint**: an **object** `{"diagnostics":[...],"errorCount":N,"warningCount":N,"fixableCount":N}`
  (`api_json.zig:623-656`; the header comment "JSON diagnostics array" is stale — pin
  empirically and trust the writer).
- **reflect v2**: `{"version":2,"bindings":[…],"uniforms":[…],"storage":[…],"textures":[…],"samplers":[…],"structs":{…},"entryPoints":[…],"overrides":[…],"functions":[…],"aliases":[…][,"errors":[…]]}`.
- Minify options JSON keys: `minifyWhitespace, minifyIdentifiers, minifySyntax,
  treeShaking, mangleExternalBindings, preserveUniformStructTypes, keepNames,
  sortDeclarations, scopeLocalRename`.
- Documented minifier contract: on parse errors, returns the **original source
  unchanged** (repo-root `BUILDING_WITH_WGSLENDER.md:547-558`) — pin empirically.
- Compression synergy: `sortDeclarations` + `scopeLocalRename` exist specifically to
  improve DEFLATE (5–29% gzip savings claim, README) — the compressed macro enables them.

---

## Guidelines binding — `~/llm/mastery/rust/`

This plan follows the Rust mastery guidelines. Read before executing (in this order —
the corpus' own `00-INDEX.md § Reading Order`):

1. `~/llm/mastery/rust/00-INDEX.md` — map + Quick Reference (Edition 2024 feature
   matrix, workspace Cargo.toml anatomy, CI discipline snapshot)
2. `~/llm/mastery/rust/RUST_MASTERY.md` — house style; §§ *Edition 2024 Dialect
   (Overview)*, *Public API Hygiene*, *Rustdoc Conventions*, *Tooling Discipline*,
   *Function Design*, *Naming Conventions*
3. `~/llm/mastery/rust/UNSAFE_AND_FFI.md` — §§ *The // SAFETY: Discipline*, *Edition
   2024 — unsafe extern { … } Blocks (RFC 3484)*, *Putting It Together — A Safe FFI
   Wrapper*, *Miri — The UB Detector*
4. `~/llm/mastery/rust/ERROR_HANDLING.md` — §§ *thiserror — Derive-Based Errors for
   Libraries*, *Library vs Application — The Canonical Split*, *panic vs Result*
5. `~/llm/mastery/rust/CARGO_AND_BUILD.md` — §§ *Workspaces*, *Workspace Inheritance*,
   *Cargo Features*, *Workspace Lints*, *MSRV*, *build.rs — Build Scripts*, *Custom
   Tooling — The xtask Pattern*, *Publishing*, *Cargo.lock — Lockfile Discipline*
6. `~/llm/mastery/rust/MACROS.md` — §§ *Two Worlds, Two Tools*, *Crate Layout*,
   *Spans for Error Reporting*, *Common Pitfalls*, *What You Refuse to Do*
7. `~/llm/mastery/rust/TYPES_TRAITS_GENERICS.md` — §§ *Newtype Pattern*, *Typestate*,
   *Implementing Default*, *Sealed Traits*
8. `~/llm/mastery/rust/TESTING_AND_FUZZING.md` — §§ *The Testing Layer Cake*,
   *Doctests*, *Test Fixtures and Mini-Languages*, *Property-Based Testing — proptest*
9. `~/llm/mastery/rust/ELITE_RUST_PERSONA.md` — condensed persona; re-read when in doubt

### Mandates this plan adopts (with their sources)

- **Edition 2024, non-negotiable** ("New crates **must** be Edition 2024" —
  RUST_MASTERY § Edition 2024 Dialect). Consequences used here: `unsafe extern "C"`
  blocks (RFC 3484 — bare `extern "C" {}` is refused), `unsafe_op_in_unsafe_fn` deny,
  no `static mut`, `resolver = "3"` (MSRV-aware).
- **Workspace discipline**: virtual root manifest, `[workspace.package]`,
  `[workspace.dependencies]`, `[workspace.lints.*]` inherited by every member via
  `[lints] workspace = true` (CARGO_AND_BUILD § Workspace Inheritance / § Workspace
  Lints). Commit `Cargo.lock` ("Modern guidance: always commit").
- **Toolchain pin + MSRV split**: `rust-toolchain.toml` pinning the concrete verified
  channel (`1.92.0`), `rust-version = "1.85"` (Edition 2024 floor) as the declared MSRV
  contract; `clippy.toml` `msrv = "1.85"`. MSRV bump = breaking change
  (CARGO_AND_BUILD § MSRV).
- **Safe-FFI wrapper canon** (UNSAFE_AND_FFI § Putting It Together): raw
  `unsafe extern` decls in `-sys`; owned buffer wrapper holding `NonNull<u8>` with a
  `Drop` that calls the C free; every `unsafe` block carries `// SAFETY:` (one op per
  block); every `unsafe fn` carries `# Safety` docs (`clippy::missing_safety_doc`
  denied); **errors as a typed enum, never leaked codes**.
- **thiserror for the library error type**; never `anyhow` in a public library API
  (ERROR_HANDLING § Library vs Application). Display messages lowercase, no trailing
  period. `#[non_exhaustive]` on every public enum/struct that may grow
  (RUST_MASTERY § Public API Hygiene; NASA rule 8).
- **Two-crate proc-macro pattern is mandatory** ("the macro lives in a
  `proc-macro = true` crate, but downstream users want a *facade* crate" — MACROS
  § Crate Layout); runtime helpers used by expansions live in a normal crate
  (§ *3. Proc-Macro Crate Can't Be a Library*); macro internals re-exported under
  `#[doc(hidden)] __private` conventions; **never `panic!` in a proc-macro** — always
  `syn::Error::new_spanned(user_tokens, msg).to_compile_error()`; absolute
  `::core::...` / `::wgslender::...` paths in generated tokens; syn 2 only.
- **Function design**: `minify()` + `minify_with(options)` split (RUST_MASTERY § Split
  on bool/Option Parameters); config structs over long parameter lists; bools are fine
  as *named struct fields*, refused as positional parameters; `&mut self`-style chaining
  builder for "just configurable" APIs (TYPES_TRAITS_GENERICS § Typestate, Pattern 1).
- **Docs**: every public item gets a doctest (TESTING_AND_FUZZING § Doctests); rustdoc
  section order Summary → Detail → `# Examples` → `# Panics` → `# Errors` → `# Safety`;
  crate-level narrative with `# Quick start` / `# Cargo features` / `# Edition support`;
  intra-doc links; `cargo doc --no-deps -Drustdoc::broken_intra_doc_links` in the gate.
- **Testing**: unit tests at file bottom in `#[cfg(test)] mod tests`; integration in
  `tests/*.rs` (public-API view); shared helpers in `tests/common/mod.rs`; **never
  `#[should_panic]`, never `#[ignore]`** — assert specific `Err` variants
  (`assert_matches!`, stable since 1.83); fixture-pair layout for corpus-style tests;
  property tests for invariants (proptest) with reproducible seeds; test naming
  `<subject>_<condition>_<expected>`, no `test_` prefix.
- **Naming**: acronyms first-letter-only (`WgslShader`, not `WGSLShader`); American
  spelling; suffix-last discipline.
- **Features**: strictly additive; `dep:` prefix for optional deps; documented in a
  `# Cargo features` section of `lib.rs` (CARGO_AND_BUILD § Cargo Features).
- **CI-shaped gates → local `xtask`**: the corpus assumes CI; this repo forbids it
  (`no-ci` house rule). Adaptation sanctioned by CARGO_AND_BUILD § Custom Tooling — The
  xtask Pattern: a zero-dependency `xtask` member runs the same command set locally,
  on demand.

### Honest gaps — decisions this plan makes on its own authority

The corpus does **not** cover the following (verified by exhaustive read); each is a
deliberate decision here, not a citation. Do not invent guideline backing for them:

| Gap | This plan's decision |
|---|---|
| `-sys` crate conventions, `links` key, vendoring, static linking | Follow ecosystem convention: `wgslender-sys` raw-only, `links = "wgslender"`, `cargo:rustc-link-lib=static=wgslender`, build-from-repo-source via `zig build lib` into `OUT_DIR` |
| Sized frees (`free(ptr, len)`) | `LibBuffer` stores `(NonNull<u8>, u32)`; Drop performs the sized free; classed `unsafe fn` per the doc's own `free` example |
| Proc-macros reading files; rebuild tracking | Path resolved relative to **`CARGO_MANIFEST_DIR`** (the only cargo-documented anchor); expansion emits `const _: &[u8] = ::core::include_bytes!(<abs path>);` so rustc re-runs on shader edits (ecosystem-standard trick, uncited) |
| Pointing compile errors *inside* a `.wgsl` file | Anchor `syn::Error` to the path literal's span; render WGSL `file:line:col: message` lines inside the message text (the corpus' span tools can't cross files) |
| trybuild / UI tests | Used anyway (industry standard for proc-macro diagnostics goldens); complemented by on-book ```compile_fail``` doctests |
| `#[non_exhaustive]` + `Default` on options structs | `MinifyOptions` derives `Default` **deliberately deviating** from "don't implement Default for Config structs": here `Default` = "no overrides — wgslender's own defaults apply", mirroring the wire's absent-key semantics; documented on the type |
| docs.rs (no Zig in the sandbox) | `build.rs` early-returns when `DOCS_RS` env is set (no link directives; rustdoc doesn't link); `[package.metadata.docs.rs] all-features = true` |
| Miri vs FFI | All tests calling the Zig lib are `#[cfg(not(miri))]` with the documented justification the corpus requires ("FFI into a C library") |
| cargo-fuzz (needs nightly + continuous fuzzing ethos vs no-CI) | Replaced by bounded proptest no-panic properties (Block 10); a cargo-fuzz target is listed as an optional follow-up, not part of this plan |

## Ground rules (same as plans 01–03)

- **TDD reds first.** "Test fails to compile because the API doesn't exist" is a
  legitimate red; each block states the exact expected red and requires confirming it.
- Tests are table/fixture-driven; a new scenario is a row.
- **No CI.** Entry points: `cargo test`, `cargo xtask check` — local, on-demand.
- One conventional commit per block. Commit `packages/rust/Cargo.lock`.
- No boolean positional parameters in public APIs; named enums
  (`Strictness::{Default, Strict}`, `IncludeDeclaration::{Yes, No}`); buffer ownership
  is a named RAII type.
- Numeric reflect expectations pinned from the CLI oracle
  (`./zig-out/bin/wgslender reflect <file>`), never guessed.
- Repo-wide convention: `u32` for shader-bounded counts/offsets (matches the wire);
  `usize` only for slice indexing.

## Target layout

```
packages/rust/
  Cargo.toml              # virtual workspace: resolver "3", members, workspace.{package,dependencies,lints}
  Cargo.lock              # committed
  rust-toolchain.toml     # channel "1.92.0", components [rustfmt, clippy, rust-src, rust-analyzer]
  rustfmt.toml            # edition 2024, max_width 100, imports_granularity "Crate", group_imports "StdExternalCrate"
  clippy.toml             # msrv "1.85"
  README.md
  wgslender-sys/          # raw FFI. links = "wgslender". build.rs runs zig → OUT_DIR.
    Cargo.toml
    build.rs
    src/lib.rs            # repr(C) structs + one unsafe extern "C" block (all 22 fns)
    tests/smoke.rs
  wgslender-core/         # the entire safe API. All unsafe confined here (buffer.rs + call sites).
    Cargo.toml
    src/{lib.rs, buffer.rs, error.rs, options.rs, minify.rs, validate.rs, lint.rs,
         reflect.rs, refactor.rs, compile.rs, compress.rs}
    tests/{common/mod.rs, fixtures/*.wgsl, minify.rs, validate.rs, lint.rs, reflect.rs,
           refactor.rs, compile.rs, props.rs}
  wgslender-macros/       # proc-macro = true. Depends on wgslender-core (compile-time execution).
    Cargo.toml
    src/{lib.rs, parse.rs, expand.rs, codegen.rs}
  wgslender/              # facade: pub use core::*; feature-gated pub use macros. Docs + examples + macro tests.
    Cargo.toml
    src/lib.rs
    examples/{minify.rs, embed.rs, embed_compressed.rs, reflect_types.rs}
    tests/{fixtures/*.wgsl, macros.rs, module_gen.rs, ui.rs, ui/*.rs, ui/*.stderr}
  xtask/                  # zero-dep local gate: cargo xtask check
    Cargo.toml
    src/main.rs
```

Dependency graph (acyclic; the sqlx-shaped layering the macro requirement forces):

```
wgslender (facade) ──► wgslender-core ──► wgslender-sys ──(build.rs)──► zig build lib
        │                    ▲
        └──► wgslender-macros┘   (macros run the minifier at compile time, on the host)
```

Workspace dependencies: `serde` (derive), `serde_json`, `thiserror` (core);
`syn = "2"` (parse-only features suffice — trim from the default `full`), `quote`,
`proc-macro2` (macros); `miniz_oxide` (core `compress` feature via `dep:`, macros
always); dev: `proptest`, `trybuild`. Versions resolved at execution; all members
share the workspace version `0.1.0` and are published lock-step.

---

## Block 1 — Workspace scaffold + `wgslender-sys` (red: smoke test can't link)

**Context recap:** nothing exists under `packages/rust/`. Zig 0.16.0 on PATH; rustup stable
1.92.0. `zig build lib -Doptimize=ReleaseFast -p <prefix>` installs
`<prefix>/lib/libwgslender.a` + `<prefix>/include/wgslender.h` (verified). The 22
exports and their result structs are tabulated above. `wgslender_version_c` returns a
static pointer (never free); everything else frees via sized `wgslender_free_c`.

1. Scaffold the workspace root exactly per CARGO_AND_BUILD § Workspace Inheritance /
   00-INDEX § Workspace Cargo.toml Anatomy:
   - `packages/rust/Cargo.toml`: `[workspace] resolver = "3"`, explicit member list;
     `[workspace.package]` `version = "0.1.0"`, `edition = "2024"`,
     `rust-version = "1.85"`, `license = "MIT"` (match the repo's LICENSE — check it;
     if the repo has none, stop and ask Hugo), `repository`;
     `[workspace.dependencies]` incl. the local members as `{ path, version }`;
     `[workspace.lints.rust]`: `unsafe_op_in_unsafe_fn = "deny"`,
     `missing_docs = "warn"`, `missing_debug_implementations = "warn"`,
     `unreachable_pub = "warn"`, `unused_must_use = "deny"`;
     `[workspace.lints.clippy]`: `all`/`pedantic` at `priority = -1`, `unwrap_used`,
     `expect_used`, `dbg_macro`, `todo` = warn, `missing_safety_doc = "deny"`.
     (No workspace-wide `unsafe_code = "forbid"` — sys and core legitimately contain
     unsafe; the corpus itself notes forbid can't be scoped around that.)
   - `rust-toolchain.toml` (channel `"1.92.0"`, components rustfmt/clippy/rust-src/
     rust-analyzer, profile minimal), `rustfmt.toml`, `clippy.toml` as in the layout.
   - Append `packages/rust/target/` to the repo root `.gitignore`.
2. **Red.** `wgslender-sys` with `Cargo.toml` (`links = "wgslender"`,
   `[lints] workspace = true`, `build = "build.rs"`) and `tests/smoke.rs` written
   against the not-yet-existing decls: call `wgslender_version_c` (assert semver
   `x.y.z`, currently `1.1.0`) and a `wgslender_minify_c("fn f(){}", DEFAULT)`
   round-trip that checks `!error`, non-empty output, then frees via
   `wgslender_free_c`. All in `unsafe` blocks with `// SAFETY:` comments;
   `#[cfg(not(miri))]` on the test with the documented FFI justification.
   `cargo test -p wgslender-sys` → **expected red:** build fails (no `src/lib.rs` /
   no build.rs → unresolved symbols or missing crate). Confirm.
3. **Green.** `src/lib.rs`: `#![no_std]`-compatible raw layer (just `core`), the seven
   `#[repr(C)]` structs (fields exactly as the header — keep field name `error`; Rust
   `bool` is ABI-compatible with C `_Bool`), and **one Edition-2024 block**:
   ```rust
   unsafe extern "C" {
       pub fn wgslender_minify_c(src: *const u8, len: u32, flags: u32) -> WgslenderResult;
       // … all 22, each with a `# Safety` doc comment stating pointer/length contracts
       pub fn wgslender_free_c(ptr: *mut u8, len: u32);
       pub fn wgslender_version_c(len: *mut u32) -> *const u8;
   }
   ```
   Every fn stays `unsafe` (they all have pointer preconditions — per
   UNSAFE_AND_FFI's own `free`/`strlen` classification). Flag constants
   (`OPT_MINIFY_WHITESPACE` … `OPT_DEFAULT = 0x0f`, `OPT_STRICT = 1`) as `pub const u32`.
4. `build.rs` (the load-bearing piece — no guideline covers this; design is ours):
   ```text
   1. If WGSLENDER_LIB_DIR is set: emit link-search to it + link-lib static=wgslender,
      rerun-if-env-changed, and return (prebuilt escape hatch; also the cross-compile
      fallback).
   2. If DOCS_RS is set: return with no directives (docs.rs has no Zig; rustdoc
      doesn't link).
   3. Locate the repo root: CARGO_MANIFEST_DIR/../../.. (packages/rust/wgslender-sys → repo root).
      Assert build.zig exists there; if not, panic with an actionable message
      (published-crate builds need the vendoring step — see Block 10 — or
      WGSLENDER_LIB_DIR).
   4. Map cargo TARGET → zig -Dtarget via a small table (aarch64-apple-darwin →
      aarch64-macos, x86_64-apple-darwin → x86_64-macos, {x86_64,aarch64}-unknown-linux-gnu
      → {arch}-linux-gnu, x86_64-pc-windows-msvc → x86_64-windows-msvc). TARGET == HOST →
      omit -Dtarget (native). Unknown target → panic naming WGSLENDER_LIB_DIR as the
      escape hatch.
   5. Run: zig build lib -Doptimize=ReleaseFast -p $OUT_DIR (per-crate prefix ⇒ host and
      target builds never clobber each other; Zig's cache handles concurrency). On
      failure: panic with "install Zig 0.16.0 (zigup 0.16.0) or set WGSLENDER_LIB_DIR".
   6. Emit: rustc-link-search=native=$OUT_DIR/lib, rustc-link-lib=static=wgslender,
      rerun-if-changed on <root>/src, <root>/include/wgslender.h, <root>/build.zig,
      <root>/build.zig.zon (cargo tracks directories recursively), and
      rerun-if-env-changed for WGSLENDER_LIB_DIR.
   ```
5. `cargo test -p wgslender-sys` → green (proves the whole link chain). Also run
   `cargo clippy -p wgslender-sys --all-targets -- -D warnings` and `cargo fmt`.
6. Commit: `feat(rust): cargo workspace scaffold + wgslender-sys FFI crate`

---

## Block 2 — `wgslender-core`: buffer, error, version, minify (red: compile-error table)

**Context recap:** `wgslender-sys` links and passes its smoke test. Minify C surface:
`minify_c(src, len, flags)` / `minify_json_c(src, len, opts, opts_len)` → `WgslenderResult
{ code_ptr, code_len, error }` holding **plain minified WGSL text**. Flags frozen
(`DEFAULT = 0x0f`); JSON opts keys are the nine camelCase `wgslender.json` keys;
malformed opts JSON silently degrades to defaults; parse errors return the input
unchanged (contract to pin empirically). All buffers sized-freed; version is static.

1. Crate skeleton `wgslender-core` (deps: `wgslender-sys`, `serde`, `serde_json`,
   `thiserror`; `[lints] workspace = true`). Crate docs state: "implementation detail
   of the `wgslender` crate — depend on `wgslender`, not on this".
2. **Red.** `tests/minify.rs` — fixtures first: `tests/fixtures/{demo,invalid,warning}.wgsl`
   (same family as plans 01/02, self-contained):
   - `demo.wgsl`: `struct Params { resolution: vec2f, time: f32, frame: u32 }` +
     `@group(0) @binding(0) var<uniform> params: Params;` +
     `@group(0) @binding(1) var<storage, read_write> data: array<vec4f>;` +
     `@group(1) @binding(0) var tex: texture_2d<f32>;` +
     `@group(1) @binding(1) var samp: sampler;` + `fn luminance(c: vec3f) -> f32` +
     `@compute @workgroup_size(8, 8, 1) fn main(@builtin(global_invocation_id) id: vec3u)`
     using all of the above.
   - `invalid.wgsl`: `fn main() -> f32 { return undeclared_variable; }`
   - `warning.wgsl`: storage buffer + `@compute @workgroup_size(64)` entry calling
     `workgroupBarrier()` inside `if (i < 32u)` (non-uniform ⇒ warning).
   Sanity-check all three against the CLI (`zig build` →
   `./zig-out/bin/wgslender validate <f>`).
   Then a table `struct Case { name, source, options: Option<MinifyOptions>, check: fn(&str, &str) }`
   with rows: (a) demo/defaults ⇒ smaller than original, contains `@compute` + `fn main`;
   (b) demo + `keep_names(["luminance"])` ⇒ contains `luminance` while row (a)'s output
   must not; (c) demo + whitespace-only (identifiers+syntax off) ⇒ still contains
   `params`; (d) invalid/defaults ⇒ pin the parse-error contract (expected: input
   returned unchanged, `Ok`); (e) `minify("")` ⇒ pin empirically. **Expected red:**
   `E0432` on `wgslender_core::{minify, minify_with, MinifyOptions}`. Confirm.
3. **Green.** Implementation, signatures first:
   - `src/buffer.rs` (private): the canonical FFI-wrapper shape (UNSAFE_AND_FFI
     § Putting It Together):
     ```rust
     /// Bytes owned by libwgslender; freed with the library's sized free on Drop.
     pub(crate) struct LibBuffer { ptr: NonNull<u8>, len: u32 }
     impl LibBuffer {
         /// # Safety: (ptr, len) must come from a wgslender result struct, unfreed.
         pub(crate) unsafe fn adopt(ptr: *const u8, len: u32) -> Option<Self>;
         pub(crate) fn as_bytes(&self) -> &[u8];
         pub(crate) fn into_string(self) -> Result<String, Error>; // copy, then Drop frees
     }
     impl Drop for LibBuffer { /* SAFETY: sized free with the adopted (ptr, len) */ }
     ```
     No `Send`/`Sync` impls — it never escapes a call. One unsafe op per block, each
     with `// SAFETY:`.
   - `src/error.rs`:
     ```rust
     #[derive(Debug, thiserror::Error)]
     #[non_exhaustive]
     pub enum Error {
         #[error("wgslender internal error")] Internal,
         #[error("library returned invalid UTF-8")] InvalidUtf8(#[from] core::str::Utf8Error),
         #[error("unexpected wire format: {0}")] Wire(#[from] serde_json::Error),
         #[error("source exceeds u32 length limit ({0} bytes)")] SourceTooLarge(usize),
         #[error("shader failed to compile")] Compile(Vec<Diagnostic>),   // Block 4
         #[error(transparent)] Refactor(#[from] RefactorError),           // Block 5
     }
     ```
     (Add variants only in their blocks; `#[non_exhaustive]` makes that non-breaking.)
   - `src/options.rs`: `MinifyOptions` — `#[derive(Debug, Clone, Default, serde::Serialize)]`,
     `#[serde(rename_all = "camelCase")]`, `#[non_exhaustive]`, nine `Option` fields
     each `skip_serializing_if = "Option::is_none"`, plus `mut self`-chaining setters
     (`.minify_whitespace(bool)`, `.keep_names(impl IntoIterator<Item = impl Into<String>>)`,
     …, each `#[must_use]`). Doc on the type: `Default` == no overrides == `{}` options
     JSON (deliberate deviation from the no-Default-for-config opinion, reason stated).
     `#[non_exhaustive]` forbids downstream struct literals ⇒ the setters are the API.
   - `src/minify.rs`: `pub fn minify(source: &str) -> Result<String, Error>` (flags
     `DEFAULT`) and `pub fn minify_with(source: &str, options: &MinifyOptions) ->
     Result<String, Error>` (serde_json → `minify_json_c`). Both `#[must_use]`, both
     with doctests. Length guard → `SourceTooLarge`.
   - `src/lib.rs`: `pub fn version() -> &'static str` (static ptr — deliberately
     **not** a `LibBuffer`; that's the point of the named ownership type), re-exports.
4. `cargo test -p wgslender-core` → green. Doctests count (`cargo test --doc`).
5. Commit: `feat(rust): wgslender-core minify API over sized-free RAII buffer`

---

## Block 3 — validate + lint + lint_fix (red: assertion tables)

**Context recap:** core crate exists with `LibBuffer`/`Error`/`MinifyOptions`.
C surface: `validate_c(src, len, flags)` → `{ valid, json_ptr, json_len, error_count,
warning_count }`, `json_ptr == NULL` = internal failure (no error flag), flags bit 0 =
strict. Envelope `{"valid","diagnostics":[{"severity","message",["code"],"line","column",…}],
"errorCount","warningCount"}`. `lint_c(src, len, config, config_len)` /
`lint_fix_c(...)`: config JSON `{"extends":["@wgslender/recommended",…],
"rules":{"id":"error"|"warn"|"off"|["warn",{...}]},"reportUnusedDisableDirectives":bool}`;
result JSON object `{"diagnostics":[...],"errorCount","warningCount","fixableCount"}`;
lint_fix adds `fixed_ptr` (rewritten source). Empty config = zero rules. Packs:
`@wgslender/{recommended,style,performance,portability,minify,strict}`
(`src/lint/configs.zig`). Fixtures demo/invalid/warning exist.

1. **Red.** `tests/validate.rs` table rows: (a) demo/`Strictness::Default` ⇒ valid,
   0 errors; (b) invalid/Default ⇒ `!valid`, ≥1 error, first diagnostic has code
   starting `'E'`, `line >= 1 && column >= 1`, severity `Severity::Error`;
   (c) warning/Default ⇒ `warning_count >= 1 && valid`; (d) warning/Strict ⇒
   `strict.error_count >= default.error_count + default.warning_count` (the npm-pinned
   promotion invariant). `tests/lint.rs` rows: (e) demo + empty `LintConfig` ⇒ 0/0
   counts; (f) demo + `recommended` pack ⇒ runs clean or pins observed counts
   (empirical); (g) a fixture with an unused variable + `{"rules":{"no-unused-vars":"warn"}}`
   ⇒ ≥1 warning with that rule's code; (h) `lint_fix` on a fixable fixture ⇒
   `fixed_source != original` and re-linting the fixed source lowers `fixable_count`
   (derive the fixable fixture from `./zig-out/bin/wgslender lint --fix` experiments —
   oracle-pin). **Expected red:** unresolved `validate`, `Strictness`, `lint`,
   `LintConfig`. Confirm.
2. **Green.**
   - Shared `src/validate.rs` types: `Severity` — `#[non_exhaustive]`
     `#[derive(serde::Deserialize, Debug, Clone, Copy, PartialEq, Eq)]`
     `#[serde(rename_all = "lowercase")]` enum `{ Error, Warning, Info, Hint,
     #[serde(other)] Unknown }` (tolerant — the wire may grow);
     `Diagnostic { severity, message, code: Option<String>, line: u32, column: u32 }`
     tolerant camelCase serde (no `deny_unknown_fields` anywhere — the wire grows keys);
     `Validation { valid, error_count, warning_count, diagnostics }`;
     `pub enum Strictness { Default, Strict }`;
     `pub fn validate(source: &str, strictness: Strictness) -> Result<Validation, Error>`.
   - `src/lint.rs`: `LintConfig` — `#[non_exhaustive]`, `Default` (= empty config),
     chaining setters `.extend(Pack)` / `.rule(id, RuleSetting)` /
     `.report_unused_disable_directives()`; `Pack` — `#[non_exhaustive]` enum for the
     six packs, `Display` → `"@wgslender/recommended"` etc.; `RuleSetting` —
     `Off | Warn | Error | WarnWith(serde_json::Value) | ErrorWith(serde_json::Value)`
     serialized to the wire's string-or-tuple form. `LintReport { error_count,
     warning_count, fixable_count, diagnostics }`;
     `pub fn lint(source: &str, config: &LintConfig) -> Result<LintReport, Error>`;
     `pub fn lint_fix(source: &str, config: &LintConfig) -> Result<LintFixOutcome, Error>`
     with `LintFixOutcome { fixed_source: String, report: LintReport }`.
3. `cargo test -p wgslender-core` green; doctests on every new public item.
4. Commit: `feat(rust): validate + lint + lint_fix with typed diagnostics`

---

## Block 4 — reflect (typed) + minify_and_reflect + compile (red: oracle-pinned table)

**Context recap:** `reflect_c(src, len)` → `WgslenderJsonResult` holding the v2
envelope (camelCase; `bindings[]` entries carry `group, binding, name, addressSpace,
type, layout{size, alignment}`; `structs` maps name → `{size, alignment,
fields:[{name, type, offset, size}]}`; `entryPoints[]` carry `{name, stage,
workgroupSize}`; top-level `errors[]` optional — reflect degrades, it doesn't fail).
`minify_and_reflect_c(src, len, opts, opts_len)` → `{"minify":{"code","errors",
"originalSize","minifiedSize"},"reflect":{...}}` — the only C path with minify sizes.
`compile_c(src, len, opts, opts_len)` → `{ wasm_ptr, wasm_len, original_size,
errors_json_ptr, errors_json_len }`; opts = minify JSON keys; the wasm is a
self-contained BPE-decoder module (`generate()` export). Fixtures exist.

1. **Pin the oracle.** `zig build` →
   `./zig-out/bin/wgslender reflect wgslender-core/tests/fixtures/demo.wgsl` (path via
   repo root). Record: `structs.Params.{size,alignment}` (expected 16/8 — confirm),
   field offsets (`resolution@0, time@8, frame@12` — confirm), the four bindings'
   `(group, binding, name, addressSpace)` tuples (`uniform`, `storage`, `handle`×2 —
   confirm), entry point `("main", "compute", [8,8,1])`.
2. **Red.** `tests/reflect.rs` rows: (a) `version == 2`; (b) 4 bindings with pinned
   tuples; (c) uniform binding `layout.size == structs["Params"].size`; (d) pinned
   Params numbers; (e) one entry point as pinned; (f) reflect(invalid) ⇒ `Ok` with
   non-empty `errors`. `tests/compile.rs` rows: (g) compile(demo) ⇒ wasm starts with
   `b"\0asm"`, `original_size > 0`, no errors; (h) compile(invalid) ⇒
   `Err(Error::Compile(diags))` with ≥1 diagnostic **or** pinned observed shape (run
   once, pin what actually happens — the struct has no error flag, so the mapping
   decision is: non-empty errors JSON ⇒ `Err`). (i) `minify_and_reflect(demo, &opts)`
   ⇒ `minify.code` non-empty, `minify.original_size > minify.minified_size`,
   `reflect.version == 2`. **Expected red:** unresolved imports. Confirm.
3. **Green.** `src/reflect.rs` — tolerant serde subset (same shape as plan 02 Block 4,
   plus the extra arrays as `#[serde(default)] Vec<serde_json::Value>` escape hatches
   for `uniforms/storage/textures/samplers/overrides/functions/aliases` — full typing
   of those views is a follow-up, the raw JSON is still reachable via
   `reflect_json()`): `Reflection`, `Binding`, `Layout`, `StructLayout`, `Field`,
   `EntryPoint` (all `Debug + Clone`, `#[non_exhaustive]` where growable).
   `pub fn reflect(source: &str) -> Result<Reflection, Error>` and
   `pub fn reflect_json(source: &str) -> Result<String, Error>` (raw envelope for
   forward-compat consumers). `src/minify.rs` gains
   `pub fn minify_and_reflect(source: &str, options: &MinifyOptions) ->
   Result<MinifiedShader, Error>` with
   `MinifiedShader { code, original_size: u32, minified_size: u32, reflection }`.
   `src/compile.rs`: `pub fn compile(source: &str, options: &MinifyOptions) ->
   Result<CompiledShader, Error>`, `CompiledShader { wasm: Vec<u8>, original_size: u32 }`
   (+ doctest documenting the JS-side `generate()` usage as `no_run` text).
4. Green; commit: `feat(rust): typed reflect, minify_and_reflect, binary compile`

---

## Block 5 — the refactor family, all 12 functions (red: assertion table)

**Context recap:** twelve stable-id/refactor exports (table in the header section
above; JSON shapes quoted there). Error strings on the wire: `"invalid identifier"`,
`"symbol not found"`, `"parse error"`, `"no type annotation or invalid replacement"`.
`rename_apply`-family envelope: `{"ok":bool,"source":"...","edits":[...][,"error"]}` —
`source` always present (original on failure). Offsets are UTF-8 byte offsets, u32.

1. **Red.** `tests/refactor.rs` — one fixture with known byte offsets (compute them in
   the test from `source.find("params")` etc., don't hardcode magic numbers). Rows:
   (a) `find_references(demo, offset_of("luminance" decl), IncludeDeclaration::Yes)` ⇒
   n ≥ 2 references, exactly one more than with `::No`; (b) `rename` at the same
   offset to `"lum"` ⇒ edits non-empty, applying them (via the returned
   `rename_apply`) yields source containing `fn lum(`; (c) `rename` to `"fn"`
   (keyword) ⇒ `Err(Error::Refactor(RefactorError::InvalidIdentifier))`; (d) `rename`
   at offset 0 of a comment-only file ⇒ `SymbolNotFound`; (e) `stable_id_at_offset` ⇒
   `Some(StableId)` whose string starts with `"v1:"`; (f) `locate_stable_id` on that
   id ⇒ range that slices to the symbol name; `locate_declaration` ⇒ wider range
   containing it; (g) `change_type_by_id` on a `let x: f32` fixture to `"vec2f"` ⇒
   edit slices replace the annotation; `_apply` variant returns rewritten source;
   (h) `remove_declaration_apply_by_id` on the helper fn ⇒ source no longer contains
   it and still validates. **Expected red:** unresolved module. Confirm.
2. **Green.** `src/refactor.rs`:
   ```rust
   #[derive(Debug, Clone, PartialEq, Eq)] pub struct StableId(String);      // newtype (Display, AsRef<str>, FromStr)
   #[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Deserialize)]
   pub struct ByteRange { pub start: u32, pub end: u32 }
   #[derive(Debug, Clone, serde::Deserialize)] #[serde(rename_all = "camelCase")]
   pub struct Edit { pub start: u32, pub end: u32, pub new_text: String }
   #[derive(Debug, Clone, serde::Deserialize)] #[serde(rename_all = "camelCase")]
   pub struct Reference { pub start: u32, pub end: u32, pub is_write: bool }
   #[derive(Debug)] pub struct Applied { pub source: String, pub edits: Vec<Edit> }
   pub enum IncludeDeclaration { Yes, No }
   #[derive(Debug, thiserror::Error)] #[non_exhaustive]
   pub enum RefactorError {
       #[error("invalid identifier")] InvalidIdentifier,
       #[error("symbol not found")] SymbolNotFound,
       #[error("parse error")] ParseError,
       #[error("no type annotation or invalid replacement")] NoTypeAnnotation,
       #[error("{0}")] Other(String),      // forward-compat for new wire strings
   }
   pub fn find_references(source: &str, offset: u32, decl: IncludeDeclaration) -> Result<Vec<Reference>, Error>;
   pub fn rename(source: &str, offset: u32, new_name: &str) -> Result<Vec<Edit>, Error>;
   pub fn rename_apply(source: &str, offset: u32, new_name: &str) -> Result<Applied, Error>;
   pub fn stable_id_at_offset(source: &str, offset: u32) -> Result<Option<StableId>, Error>;
   pub fn locate_stable_id(source: &str, id: &StableId) -> Result<Option<ByteRange>, Error>;
   pub fn locate_declaration(source: &str, id: &StableId) -> Result<Option<ByteRange>, Error>;
   pub fn locate_type(source: &str, id: &StableId) -> Result<Option<ByteRange>, Error>;
   pub fn rename_by_id(source: &str, id: &StableId, new_name: &str) -> Result<Vec<Edit>, Error>;
   pub fn remove_declaration(source: &str, id: &StableId) -> Result<Vec<Edit>, Error>;
   pub fn remove_declaration_apply(source: &str, id: &StableId) -> Result<Applied, Error>;
   pub fn change_type(source: &str, id: &StableId, new_type: &str) -> Result<Vec<Edit>, Error>;
   pub fn change_type_apply(source: &str, id: &StableId, new_type: &str) -> Result<Applied, Error>;
   ```
   Wire `"error"` strings map to `RefactorError` by exact match, unknown → `Other`.
   The un-resolving locate/stable-id cases (`{"stableId":null}` / `{"start":null}`
   without an `error` key) map to `Ok(None)`, not errors.
3. Green; doctests (one worked rename example on a 3-line shader). Commit:
   `feat(rust): full stable-id refactor API (12 functions)`

---

## Block 6 — facade crate, xtask gate, documentation pass

**Context recap:** `wgslender-core` now covers the whole ABI (minify, validate, lint,
reflect, compile, refactor, version). MACROS.md mandates a facade crate; the corpus'
CI command set must become a local gate (no-CI repo); docs standards: crate-level
narrative with Quick start / Cargo features / Edition support, doctest per public item,
intra-doc links, `-Drustdoc::broken_intra_doc_links`.

1. **Red.** `wgslender/tests/` — a re-export smoke test: `use wgslender::{minify,
   validate, reflect, refactor::StableId, Strictness};` + one call each. Red: crate
   doesn't exist. Confirm (`cargo test -p wgslender`).
2. **Green.** `wgslender/src/lib.rs`: `pub use wgslender_core::*;` (+ module
   re-exports so paths read `wgslender::refactor::rename`), crate-level `//!`
   narrative (Quick start with a compute-shader minify example; Cargo features
   section; Edition support: "Requires Edition 2024 consumers' toolchain ≥ 1.85");
   `examples/minify.rs` and `examples/reflect_types.rs` (runnable,
   `cargo run -p wgslender --example minify`).
3. `xtask/` member (zero deps, `std::process` only — NASA rule 10):
   `cargo xtask check` runs, in order, failing fast:
   `cargo fmt --all --check` → `cargo clippy --workspace --all-targets -- -D warnings`
   → `cargo test --workspace` → `cargo test --workspace --doc` →
   `cargo doc --workspace --no-deps` with
   `RUSTDOCFLAGS="-D rustdoc::broken_intra_doc_links"`. Optional subcommands:
   `cargo xtask msrv` (`cargo +1.85 check --workspace` — requires that toolchain
   installed, print skip-hint otherwise), `cargo xtask deny` (runs `cargo deny check`
   only if installed). Workspace `[workspace.metadata]` alias documented in
   `packages/rust/README.md`; add `[alias] xtask = "run -p xtask --"` in `packages/rust/.cargo/config.toml`.
4. Run the full gate; fix everything it flags (missing docs are real work here — every
   public item in core gets its doc + doctest now if any block missed one).
5. `packages/rust/README.md`: what each crate is, the dependency graph, prerequisites
   (Zig 0.16.0 + rustup), `WGSLENDER_LIB_DIR`/`DOCS_RS` behavior, the gate command,
   and the sized-free ownership contract.
6. Commit: `feat(rust): wgslender facade crate + xtask local gate + docs pass`

---

## Block 7 — `wgslender-macros`: `include_wgsl!` (red: trybuild + integration)

**Context recap:** facade + core are green. MACROS.md rules in force: proc-macro crate
exports only macros; errors via `syn::Error::new_spanned(...).to_compile_error()`,
anchored to the user's tokens, never `panic!`; absolute `::wgslender::...` paths in
expansions; syn 2, parse-only features. File reading from proc-macros is off-book:
resolution is **relative to `CARGO_MANIFEST_DIR`** (documented loudly), rebuild
tracking via an emitted `const _: &[u8] = ::core::include_bytes!(<abs path>);`.
Macro tests live in the **facade** crate (proc-macro crates can't host integration
tests). The macro runs core's minify/validate at compile time (host build of the Zig
lib — cargo handles the host-target split; both zig builds land in separate OUT_DIRs).

1. Crate skeleton: `wgslender-macros` with `[lib] proc-macro = true`, deps
   `syn = { version = "2", default-features = false, features = ["parsing", "proc-macro", "printing"] }`
   (trim — we parse only literals/idents; verify the minimal set compiles, widen only
   as needed), `quote`, `proc-macro2`, `wgslender-core`, `serde_json`. Facade gains
   `wgslender-macros` behind feature `macros`, **default on**
   (`default = ["macros"]`, `macros = ["dep:wgslender-macros"]`), and re-exports:
   `#[cfg(feature = "macros")] pub use wgslender_macros::include_wgsl;`.
2. **Red (two layers).**
   - Integration (`wgslender/tests/macros.rs`):
     `const SHADER: &str = wgslender::include_wgsl!("tests/fixtures/demo.wgsl");`
     rows: output shorter than `include_str!` of the same file; contains `@compute`;
     `keep_names` variant `include_wgsl!("tests/fixtures/demo.wgsl", keep_names = ["luminance"])`
     contains `luminance`; `minify = false` variant equals validated-but-unminified
     source (pin observed). Red: unresolved macro.
   - UI goldens (`wgslender/tests/ui.rs` + `tests/ui/*.rs`): trybuild
     `compile_fail` cases: (a) missing file ⇒ error message contains the resolved
     absolute path and "relative to CARGO_MANIFEST_DIR"; (b) `invalid.wgsl` ⇒ message
     contains `E0xxx`-style code, `invalid.wgsl:1:...` rendered file:line:col, and the
     WGSL diagnostic text; (c) unknown option key ⇒ names the key and lists valid ones.
     Red: same unresolved macro (trybuild `pass` cases fail too). Confirm.
3. **Green.** `src/parse.rs`: syn parse of `("path" [, key = value]*)` — keys:
   `minify` (bool, default true), `validate` (bool, default true — `false` skips
   validation for intentionally-partial snippets), `strict` (bool → validation
   strictness), `keep_names = [<str>...]`, plus passthrough minify keys
   (`minify_identifiers`, `minify_whitespace`, `minify_syntax`, `tree_shaking`,
   `mangle_external_bindings`, `sort_declarations`, `scope_local_rename`) building a
   `wgslender_core::MinifyOptions`. `src/expand.rs`: resolve path (manifest-relative;
   error lists the tried absolute path), read file, `validate(...)` — on errors,
   `syn::Error` on the path literal whose message embeds each diagnostic as
   `<file>:<line>:<col>: <severity> <code>: <message>` lines; then
   `minify_with(...)`; expand to
   `{ const _: &[u8] = ::core::include_bytes!("<abs>"); "<minified>" }`.
   Entry point shape: `expand(input).unwrap_or_else(|e| e.to_compile_error()).into()`.
4. Green: `cargo test -p wgslender` (integration + trybuild; `TRYBUILD=overwrite` to
   bless goldens first run, then re-run clean). Doc the macro (facade re-export carries
   the docs; include a ```compile_fail``` doctest for the invalid-WGSL case — the
   on-book compile-failure mechanism).
5. Commit: `feat(rust): include_wgsl! compile-time validate+minify macro`

---

## Block 8 — compressed embedding: `CompressedWgsl` + `include_wgsl_compressed!`

**Context recap:** this is the miniray user story — minify, **compress**, embed
compressed, decompress lazily at runtime. `include_wgsl!` exists (Block 7 mechanics:
manifest-relative path, include_bytes tracking, syn::Error diagnostics). Compression:
DEFLATE via `miniz_oxide` (pure Rust). wgslender's `sortDeclarations` +
`scopeLocalRename` exist to make minified text more compressible — the compressed
macro turns them on by default (overridable via the same passthrough keys).

1. **Red.**
   - Core (`wgslender-core/tests/` new rows, feature-gated `#[cfg(feature = "compress")]`):
     `CompressedWgsl::__from_parts(deflate_bytes, text_len)` round-trips: `as_str()`
     equals the original text; second call returns the same `&str` (cached).
   - Facade (`wgslender/tests/macros.rs` rows, `compress` feature):
     `static SHADER: wgslender::CompressedWgsl =
     wgslender::include_wgsl_compressed!("tests/fixtures/demo.wgsl");` —
     `SHADER.as_str()` == `include_wgsl!("tests/fixtures/demo.wgsl", sort_declarations = true, scope_local_rename = true)`
     output; `SHADER.compressed_len() < SHADER.len()` (pin: deflate must win on the
     demo fixture; if it doesn't, the fixture is too small — grow it, don't weaken the
     assertion). Red: unresolved type/macro. Confirm
     (`cargo test -p wgslender --features compress`).
2. **Green.**
   - Core `src/compress.rs` (feature `compress = ["dep:miniz_oxide"]`):
     ```rust
     /// Minified WGSL stored DEFLATE-compressed; inflated lazily, once.
     pub struct CompressedWgsl {
         deflate: &'static [u8],
         text_len: u32,
         cache: std::sync::OnceLock<String>,
     }
     impl CompressedWgsl {
         #[doc(hidden)] pub const fn __from_parts(deflate: &'static [u8], text_len: u32) -> Self;
         pub fn as_str(&self) -> &str;          // get_or_init: inflate; expect("invariant: macro-produced stream")
         pub fn len(&self) -> usize;            // decompressed length, without inflating
         pub fn is_empty(&self) -> bool;
         pub fn compressed_len(&self) -> usize;
     }
     ```
     `Debug` impl (sizes only). `# Panics` doc: corrupt stream (impossible for
     macro-produced data). `__from_parts` is `#[doc(hidden)]` per the MACROS.md
     `__private` convention — the macro is the only intended constructor.
   - Macros: `include_wgsl_compressed!` — same pipeline as `include_wgsl!` but
     defaults `sort_declarations`/`scope_local_rename` to on, compresses with
     `miniz_oxide::deflate::compress_to_vec(text, 10)`, expands to
     `{ const _: &[u8] = ::core::include_bytes!("<abs>");
        ::wgslender::CompressedWgsl::__from_parts(&[<bytes>], <len>) }`.
     Facade re-exports it under `compress = ["wgslender-core/compress"]` + `macros`.
   - Note in both macro docs: generated code names the facade path `::wgslender::…` —
     renaming the dependency breaks expansion (known limitation, documented).
3. `examples/embed_compressed.rs` — the miniray story end-to-end: static compressed
   shader, print original/minified/compressed byte counts and the inflated source
   (doubles as the README snippet).
4. Green (`cargo test -p wgslender --all-features`); commit:
   `feat(rust): compressed shader embedding (CompressedWgsl + include_wgsl_compressed!)`

---

## Block 9 — `wgsl_module!`: reflection-driven codegen with layout proofs

**Context recap:** reflect (Block 4) yields struct layouts (size/alignment/field
offsets, WGSL §6.2.10 rules) and binding tables. This block generates Rust from them
at compile time. Scope discipline: v1 supports scalars (`f32,u32,i32`), `vecN` of
them, `mat2x2f`/`mat4x4f` (column stride == column size), nested structs,
fixed-size arrays whose stride == element size; **everything else is a clean
compile error naming the field and why** (bail-don't-guess). f16 shaders are out
(reflect supports them, `[f16; N]` mapping is a follow-up).

1. **Red.**
   - Integration (`wgslender/tests/module_gen.rs`):
     `wgslender::wgsl_module!(pub demo, "tests/fixtures/demo.wgsl");` then rows:
     `demo::SOURCE` contains `@compute`; `demo::bindings::PARAMS` is `(0, 0)` (typed —
     see below); `size_of::<demo::Params>() == 16`;
     `align_of::<demo::Params>() == 8`; `offset_of!(demo::Params, resolution) == 0`,
     `(…, time) == 8`, `(…, frame) == 12` (all oracle-pinned in Block 4);
     `demo::ENTRY_MAIN == "main"`; `demo::ENTRY_MAIN_WORKGROUP_SIZE == [8, 8, 1]`.
   - UI goldens: a fixture with `field: mat3x3f` ⇒ compile error naming the field and
     "column stride ≠ column size — unsupported in generated structs (v1)"; a fixture
     with `array<vec3f, 4>` ⇒ analogous stride error. Red: unresolved macro. Confirm.
2. **Green.** Macros `src/codegen.rs`:
   - Syntax `wgsl_module!(<vis> <ident>, "<path>" [, options])` (same option keys as
     `include_wgsl!`, plus `bytemuck` (bool) to add
     `#[derive(::bytemuck::Pod, ::bytemuck::Zeroable)]` — requires the *user* to
     depend on bytemuck; explicit padding fields keep Pod derivable).
   - Pipeline: validate → reflect (on the **original** source — names come from it) →
     minify → emit module:
     ```rust
     pub mod demo {
         pub const SOURCE: &str = "<minified>";
         pub mod bindings { pub const PARAMS: ::wgslender::BindingSlot = ::wgslender::BindingSlot { group: 0, binding: 0 }; … }
         #[repr(C, align(8))] #[derive(Clone, Copy, Debug)]
         pub struct Params { pub resolution: [f32; 2], pub time: f32, pub frame: u32 }
         impl Params { pub const fn new(resolution: [f32; 2], time: f32, frame: u32) -> Self { … } }
         const _: () = { /* assert! size, align, offset_of for every field — the expansion proves its own layout */ };
         pub const ENTRY_MAIN: &str = "main";
         pub const ENTRY_MAIN_WORKGROUP_SIZE: [u32; 3] = [8, 8, 1];
     }
     ```
     Gaps between reflect offsets become explicit `pub _padN: [u8; K]` fields (zeroed
     by `new()`; keeps `Pod` derivable — no implicit padding). Runtime-sized trailing
     arrays: field omitted, `pub const <FIELD>_OFFSET: u32` emitted instead, doc
     comment forwarded. `BindingSlot { pub group: u32, pub binding: u32 }` is a new
     const-constructible core type (`Debug, Clone, Copy, PartialEq, Eq`).
     Struct/field name collisions with Rust keywords ⇒ clean compile error (v1).
   - The `const _: ()` layout assertions are the load-bearing safety net: if the
     generator mis-maps a type, **the user's build fails**, never a silent GPU bug.
3. Green (`cargo test -p wgslender --all-features`); `cargo expand`-inspect one
   module by hand and eyeball it. Commit:
   `feat(rust): wgsl_module! reflection codegen with compile-time layout proofs`

---

## Block 10 — hardening, publishing readiness, index update

**Context recap:** all four crates + xtask are green under `cargo xtask check`.
Remaining: property tests, package metadata, docs.rs config, the vendoring question,
README/index wiring, and the final clean-slate verification.

1. **Red → green, properties** (`wgslender-core/tests/props.rs`, proptest, bounded
   cases, default persistence for reproducible seeds): (a) no-panic totality —
   `minify`/`validate`/`reflect`/`lint` over arbitrary `\n`-and-ASCII strings up to
   4 KiB return `Ok`/`Err` without panicking (the FFI boundary is total); (b) minify
   idempotence on the *valid* fixture corpus — `minify(minify(demo)) == minify(demo)`
   (pin: if this fails it's a finding to report upstream, assert current behavior with
   a `// FIXME` per house rule, don't delete the test); (c) valid-input preservation —
   `validate(minify(demo))` stays valid.
2. Package metadata for all four publishable crates: `description`, `keywords`
   (`wgsl`, `webgpu`, `minifier`, `shader`, `wgpu`), `categories`
   (`compression`, `game-development`, `wasm`), `readme`, `repository`;
   `[package.metadata.docs.rs] all-features = true` on the facade;
   `include = [...]` lists on every crate (explicit — never ship fixtures/target).
   `CHANGELOG.md` seeded at `0.1.0`.
3. **The vendoring decision (explicitly deferred, sketched):** a crates.io-published
   `wgslender-sys` cannot reach `../../src` — publishing requires vendoring the Zig
   sources (`src/`, `include/`, `build.zig`, `build.zig.zon`) into the crate at
   package time (an `xtask vendor` copying them + a build.rs branch preferring the
   vendored tree) **and** requires Zig ≥ 0.16.0 on every consumer machine — or,
   alternatively, shipping prebuilt static libs per target (its own can of worms).
   This plan makes the workspace publish-*ready* but does **not** publish; record the
   two options in `packages/rust/README.md § Publishing` and stop there. Names were free
   2026-08-05; re-verify (including `wgslender-core`) before any publish. Publish
   order when it happens: sys → core → macros → facade, lock-step versions.
4. Docs final pass: facade crate-level narrative gets the miniray story as the lead
   example (`include_wgsl_compressed!` + wgpu `create_shader_module` sketch as
   `no_run`); `packages/rust/README.md` gains the full feature table and the gate/MSRV
   commands.
5. Index + repo wiring: add the `packages/rust/` row to the repo root `README.md` embeddings
   section (if one exists — check; otherwise skip). (`plans/README.md` was already
   updated when this plan was written.)
6. Final clean-slate verification: `cd packages/rust && cargo clean && cargo xtask check`
   (proves build.rs rebuilds the Zig lib from zero), plus
   `cargo test -p wgslender --no-default-features` and `--all-features`
   (feature-combination discipline, CARGO_AND_BUILD § Rules for Feature Design #6).
7. Commit: `feat(rust): hardening, package metadata, publish-readiness docs`
   (+ separate `docs(plans): wire plan 04 into the index` if README edits feel
   unrelated).

---

## Behavior changes (explicit)

**None to any existing surface.** This plan only adds files under `packages/rust/`
and `plans/`, plus one `.gitignore` line and (Block 10) index rows in READMEs. It does not
touch `src/`, the header, the C ABI, the npm package, or any wire format. Publishing
to crates.io is explicitly **out of scope** (prepared, not performed). Two
soft-surface notes for reviewers:

- The facade's **default feature set includes `macros`** — a deliberate DevX choice
  (the compile-time macro *is* the headline use case); minimal consumers use
  `default-features = false`.
- `wgslender-sys/build.rs` invokes `zig build lib` with `-p $OUT_DIR` — it never
  writes to the repo's `zig-out/`, so it cannot interfere with the Zig workflows.

## Definition of done

- [ ] `cd packages/rust && cargo xtask check` green from a clean clone (fmt, clippy `-D
      warnings`, tests, doctests, doc build with intra-doc-link denial) with only
      Zig 0.16.0 + rustup stable installed.
- [ ] All **22** ABI functions reachable through typed safe APIs; zero `unsafe`
      outside `wgslender-sys` and `wgslender-core`'s buffer/call-site modules; every
      `unsafe` block has `// SAFETY:`; every `unsafe fn` has `# Safety`.
- [ ] `include_wgsl!` fails compilation on invalid WGSL with file:line:col diagnostics
      anchored to the path literal (trybuild goldens pin the rendering).
- [ ] `include_wgsl_compressed!` round-trips byte-identically to the equivalent
      `include_wgsl!` output and embeds fewer bytes than it (assertion, not vibes).
- [ ] `wgsl_module!` expansions carry their own `const _: ()` layout proofs;
      unsupported types are compile errors naming the field, never silent mis-layouts.
- [ ] Reflect/layout numbers oracle-pinned; minify parse-error and empty-input
      contracts empirically pinned; lint envelope pinned against `api_json.zig` (the
      header comment is stale).
- [ ] No boolean positional parameters; `Strictness`/`IncludeDeclaration` enums;
      ownership in `LibBuffer`/`CompressedWgsl` named types.
- [ ] Every public item documented with a doctest; crate narrative has Quick start /
      Cargo features / Edition support; `#[non_exhaustive]` + `#[must_use]` per the
      hygiene mandates.
- [ ] `Cargo.lock`, `rust-toolchain.toml`, `rustfmt.toml`, `clippy.toml` committed;
      `packages/rust/target/` gitignored; **no CI files anywhere**.
- [ ] `plans/README.md` updated (04 row + 02 supersession note).
