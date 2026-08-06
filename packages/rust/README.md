# wgslender for Rust

A cargo workspace wrapping the wgslender C library: minify, validate, lint,
reflect, compile and refactor WGSL from Rust.

```rust
let minified = wgslender::minify(source)?;
let reflection = wgslender::reflect(source)?;
```

## Crates

| Crate | What it is |
|---|---|
| `wgslender` | **The crate to depend on.** A facade: it re-exports `wgslender-core` under a stable name and holds the examples. |
| `wgslender-core` | The safe API over the entire C ABI. Every `unsafe` block in the wrapper lives here. |
| `wgslender-macros` | The proc-macros. A `proc-macro = true` crate can export nothing else, which is the only reason it is separate. |
| `wgslender-sys` | Raw FFI declarations, plus the build script that builds and links `libwgslender.a`. |
| `xtask` | The local gate (below). Zero dependencies, never published. |

```
wgslender ──┬──► wgslender-core ──► wgslender-sys ──(build.rs)──► zig build lib
            │         └──► miniz_oxide (feature `compress`)
            └──► wgslender-macros ──► wgslender-core (at compile time)
```

Compression lives in `wgslender-core` rather than in the macro that uses it:
the writer and the reader of a format that drift apart are a bug nobody sees
until a shader inflates to nonsense, and in one file they cannot.

## Cargo features

| Feature | Default | What it adds |
|---|---|---|
| `macros` | on | `include_wgsl!` and `wgsl_module!`, and the proc-macro crate behind them. |
| `compress` | off | `CompressedWgsl`, plus `include_wgsl_compressed!` when `macros` is on too. Pulls in `miniz_oxide`. |

## Compile-time embedding

```rust
const SHADER: &str = wgslender::include_wgsl!("shaders/blur.wgsl");
```

The macro validates and minifies while `cargo build` runs — it links the same
library everything else here does, into the compiler's address space — so a
shader with an error in it fails the build, and the bytes in the binary are the
minified ones.

**Its paths are relative to `CARGO_MANIFEST_DIR`, the root of the package being
compiled, not to the file the macro was written in.** A proc-macro is handed
tokens and cannot ask on stable Rust which file they came from, so the package
root is the only anchor there is. The expansion carries an `include_bytes!` of
the resolved path that nothing reads, so that editing a shader rebuilds whatever
embedded it.

### Compressed

```rust
static SHADER: wgslender::CompressedWgsl =
    wgslender::include_wgsl_compressed!("shaders/blur.wgsl");

device.create_shader_module(wgpu::ShaderModuleDescriptor {
    source: wgpu::ShaderSource::Wgsl(SHADER.as_str().into()),
    label: None,
});
```

Same pipeline, with DEFLATE at the end: the binary carries the compressed
stream, and `as_str` inflates it on first use — once, or never. The demo fixture
in `wgslender/tests/fixtures/` goes 968 bytes of source → 412 minified → **274
stored**; `cargo run -p wgslender --features compress --example embed_compressed`
prints those numbers and the shader.

Two differences from `include_wgsl!`:

- `sort_declarations` and `scope_local_rename` default to **on**. Both exist to
  make minified text repeat itself, which is worth nothing to a reader and a
  good deal to DEFLATE. Name either to turn it back off.
- The expansion says `::wgslender::CompressedWgsl`, so the crate has to be
  reachable under the name `wgslender` where the macro is written. Renaming the
  dependency in `Cargo.toml` breaks it. `include_wgsl!` expands to a literal and
  has no such requirement.

## Generated Rust

```rust
wgslender::wgsl_module!(pub scene, "shaders/scene.wgsl");

let uniforms = scene::Scene::new(view, projection, 1);
queue.write_buffer(&buffer, 0, bytemuck::bytes_of(&uniforms));
```

`wgsl_module!` reflects the shader while `cargo build` runs and generates what a
host program binds against: `SOURCE` (validated and minified), a
`bindings::NAME` slot per resource, `ENTRY_NAME` and `ENTRY_NAME_WORKGROUP_SIZE`
per entry point, and a `#[repr(C)]` struct per host-shareable struct with the
shader's own alignment.

**The gaps WGSL's layout leaves become explicit `_padN` fields**, so a generated
struct has no padding the caller cannot account for and can go to the GPU as
bytes. `bytemuck = true` puts `#[derive(Pod, Zeroable)]` on them, which needs
your crate to depend on `bytemuck` with its `derive` feature.

**Each struct proves its own layout.** Beside every one, the expansion emits a
`const _: ()` block asserting its size, alignment and every field offset against
what wgslender computed from the shader — so a mistake in the mapping fails the
build of the crate that asked for it, rather than drawing the wrong thing.

What it refuses, by name and with the numbers, rather than guessing: a field
whose layout no Rust type has. A `mat3x3f` is three twelve-byte columns sixteen
bytes apart, and `[[f32; 3]; 3]` is not that; `array<vec3f, N>` is the same
story. Mapped as of v1: `f32`, `u32`, `i32`, vectors and matrices of them,
fixed-size arrays whose stride is their element size, nested structs, and
`atomic` of any of those. A runtime-sized array becomes an associated constant —
`Instances::ITEMS_OFFSET` — because how many elements follow is the host's
business at run time.

Like `include_wgsl_compressed!`, the expansion names `::wgslender::BindingSlot`,
so renaming the dependency in `Cargo.toml` breaks it.

`cargo run -p wgslender --example wgsl_module` prints a generated module's
layout.

## Prerequisites

- **rustup.** `rust-toolchain.toml` pins the toolchain to 1.92.0 and rustup
  installs it on first use.
- **Zig 0.16.0** on `PATH` (`zigup 0.16.0`), because `wgslender-sys` builds the
  static library from this repository's Zig sources. Not needed if you point
  `WGSLENDER_LIB_DIR` at a prebuilt one.

## How the C library gets built

`wgslender-sys/build.rs` resolves, in order:

1. **`WGSLENDER_LIB_DIR`** — link the `libwgslender.a` already in that
   directory and do nothing else. The escape hatch for prebuilt libraries and
   for targets the Zig triple mapping does not know.
2. **`DOCS_RS`** — emit nothing. The docs.rs sandbox has no Zig, and rustdoc
   does not link.
3. Otherwise run `zig build lib -Doptimize=ReleaseFast -p $OUT_DIR` against the
   repository this workspace lives in. The install prefix is the crate's own
   `OUT_DIR`, so host and cross builds never collide — and the repository's
   `zig-out/` is never written to, which keeps this out of the way of the Zig
   workflows.

## Memory

Every buffer the C ABI returns is freed with a **sized** free,
`wgslender_free_c(ptr, len)`. That ownership is a private `LibBuffer` whose
`Drop` performs the free; the public API only ever hands out owned `String`s
and `Vec`s copied out of it, so there is nothing for a caller to release. The
one exception is `wgslender_version_c`, which returns a pointer into static
storage that must **never** be freed — a different rule, so a different code
path.

## The gate

This repository runs no CI, so the command set a CI job would run is a local
task, invoked on demand:

```sh
cd packages/rust
cargo xtask check
```

It runs, stopping at the first failure:

| Step | Command |
|---|---|
| formatting | `cargo fmt --all -- --check` |
| lints | `cargo clippy --workspace --all-targets -- -D warnings` |
| lints, every feature | the same with `--all-features` |
| tests and doctests | `cargo test --workspace` |
| tests and doctests, every feature | `cargo test --workspace --all-features` |
| no features at all | `cargo check --workspace --all-targets --no-default-features` |
| documentation | `cargo doc --workspace --no-deps --all-features` with `RUSTDOCFLAGS="-D rustdoc::broken_intra_doc_links -D rustdoc::private_intra_doc_links"` |
| examples | `cargo run -p wgslender --example …`, once for each of the ten |

There is no separate `--doc` step: `cargo test --workspace` already runs the
doctests, and a second pass would only run them twice.

The examples go last because they are the slowest step and the least likely to
fail. They also prove something the steps above cannot: `--all-targets` builds
every example, which says only that they compile. This one **runs** them, and
holds each to a non-zero-exit-and-non-empty-output bar — an example that
panicked on its first line, or that printed nothing at all, used to pass the
gate. It is also where a new example is caught: the step compares
`wgslender/examples/` against the table listing them and fails on anything
unlisted, so an example cannot be added and then quietly never run.
`cargo xtask examples` runs that step alone.

Each feature configuration is walked because an optional feature nothing ever
compiles is an optional feature that has quietly stopped working — and the two
ends of the matrix are where that shows up: everything on, and nothing on.

The test step includes two suites that cost more than the rest.

`wgslender-core/tests/props.rs` asks proptest for inputs nobody would have
thought to write down: that no string panics on the way through the FFI
boundary, that minifying twice is minifying once, and that what the minifier
writes the validator takes back — the last two across the whole option space
rather than one setting of it. A failing case is recorded in
`wgslender-core/tests/props.proptest-regressions` and replayed first from then
on, so a seed found once is a seed kept. That file belongs in a commit; it is
absent because nothing has failed.

The macros' UI goldens pin what the compiler prints when `include_wgsl!` or
`wgsl_module!` refuses. trybuild runs those by compiling a generated package
under `target/tests/trybuild/`, so they cost a cargo build of their own.
Regenerate them, then read the diff, with:

```sh
TRYBUILD=overwrite cargo test -p wgslender --test ui
```

Two optional tasks need a tool that may not be installed. Each prints how to
install it and exits **non-zero** rather than reporting a pass, because a check
that did not run has not passed:

```sh
cargo xtask msrv    # rustup run 1.85.0 cargo check --workspace --all-targets
cargo xtask deny    # cargo deny check
```

## MSRV

1.85, the Edition 2024 floor, declared as `rust-version` and checked by
`cargo xtask msrv`. Raising it is a breaking change.

`rust-toolchain.toml` pins the *development* toolchain to 1.92.0, which is a
different promise: the version this workspace is worked on with, not the oldest
one it compiles under. Both are checked, because only checking the first would
let the second rot.

## Changelog

[CHANGELOG.md](CHANGELOG.md), one file for all four crates: they carry the same
version number and are released together, so a changelog each would be four
copies of one list.

## Examples

Ten of them, one per thing the library does. At run time:

```sh
cargo run -p wgslender --example minify          # what shrank, and by how much
cargo run -p wgslender --example minify_options  # what each option costs
cargo run -p wgslender --example validate        # accepted, and accepted-but-strict
cargo run -p wgslender --example lint            # packs, overrides, autofixes
cargo run -p wgslender --example reflect_types   # bindings, layouts, entry points
cargo run -p wgslender --example refactor        # find, rename and edit by symbol
cargo run -p wgslender --example compile         # a shader as a wasm module
```

And while the binary is being built:

```sh
cargo run -p wgslender --example include_wgsl    # embedding at compile time
cargo run -p wgslender --example wgsl_module     # a generated module's layout
cargo run -p wgslender --features compress --example embed_compressed
```

`cargo xtask examples` runs all ten, and is the last step of the gate above.

## Publishing

Nothing here is on crates.io. The workspace is publish-*ready* — metadata,
`include` lists, docs.rs configuration and a changelog are all in place — and
one thing stands in the way, which is a decision rather than a step.

**`wgslender-sys/build.rs` reaches `../../..` for the Zig sources.** That path
exists in this repository and in no `.crate` tarball, so a published
`wgslender-sys` would fail its first build with the message the script already
prints: *expected the wgslender sources at … but found no build.zig there*.
There are two ways out, and they trade different things away:

1. **Vendor the Zig sources into the crate at package time.** An `xtask vendor`
   copies them in and `build.rs` prefers the vendored tree when it finds one.
   Measured: `zig build lib` needs `src/`, `include/`, `build.zig`,
   `build.zig.zon` **and** `external/lsp-kit/` — the last because the LSP step's
   `b.lazyDependency` is a *path* dependency, which Zig opens while it is
   configuring even though nothing asks for it. Without it the build stops at
   `unable to open '…/external/lsp-kit'`. That is ~3.3 MB of sources, well
   inside the 10 MB crate limit. The cost is that **every consumer needs Zig
   0.16.0 on `PATH`** — a Rust crate that will not build on a machine with a
   Rust toolchain on it, which is a real thing to ask.
2. **Ship prebuilt static libraries per target.** No Zig on the consumer's
   machine, and a different can of worms: a `.crate` per platform or a fat
   archive, glibc versions, and a supply chain in which the bytes people link
   are not the bytes they can read.

Until one is chosen, `WGSLENDER_LIB_DIR` is the supported way to build against
a library you produced yourself.

The names `wgslender`, `wgslender-sys` and `wgslender-macros` were free on
crates.io on 2026-08-05; `wgslender-core` was never checked. **Re-verify all
four immediately before publishing** — a name that was free is not a name that
is reserved. Publish order, versions in lock-step: `wgslender-sys` →
`wgslender-core` → `wgslender-macros` → `wgslender`.

`cargo package -p <crate> --no-verify --list` prints what a tarball would
carry. `--no-verify` because the verification build is exactly the step that
cannot work yet. Note that only `wgslender-sys` can be *packaged* today: the
other three carry `path` + `version` dependencies, and cargo rewrites those to
registry dependencies while packaging, so it goes looking for a
`wgslender-core` that is not there yet. That is the same constraint as the
publish order, met one step earlier.
