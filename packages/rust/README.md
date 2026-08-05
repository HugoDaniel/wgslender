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

There is no separate `--doc` step: `cargo test --workspace` already runs the
doctests, and a second pass would only run them twice.

Each feature configuration is walked because an optional feature nothing ever
compiles is an optional feature that has quietly stopped working — and the two
ends of the matrix are where that shows up: everything on, and nothing on.

The test step includes the macros' UI goldens, which pin what the compiler
prints when `include_wgsl!` or `wgsl_module!` refuses. trybuild runs those by compiling a
generated package under `target/tests/trybuild/`, so they cost a cargo build of
their own. Regenerate them, then read the diff, with:

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

## Examples

```sh
cargo run -p wgslender --example minify         # what shrank, and by how much
cargo run -p wgslender --example reflect_types  # bindings, struct layouts, entry points
cargo run -p wgslender --example wgsl_module    # a generated module's layout
cargo run -p wgslender --features compress --example embed_compressed
```

## Not here yet

Nothing here is published to crates.io; see `plans/04-rust-package.md` for what
that would take.
