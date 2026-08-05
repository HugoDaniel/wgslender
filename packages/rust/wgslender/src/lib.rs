//! # wgslender
//!
//! WGSL shader tooling for Rust: [`minify`], [`validate`], [`lint`],
//! [`reflect`], [`compile`] to a binary shader module, and [`refactor`] by
//! stable symbol id — the whole [wgslender] C library behind one safe API.
//!
//! ## Quick start
//!
//! ```
//! let source = "\
//! @group(0) @binding(0) var<storage, read_write> data: array<f32>;
//!
//! @compute @workgroup_size(64)
//! fn main(@builtin(global_invocation_id) id: vec3u) {
//!     data[id.x] = data[id.x] * 2.0;
//! }
//! ";
//!
//! // A shader the library accepts …
//! let checked = wgslender::validate(source, wgslender::Strictness::Default)?;
//! assert!(checked.valid);
//!
//! // … shrinks, while the binding a host program binds against keeps its name.
//! let minified = wgslender::minify(source)?;
//! assert!(minified.len() < source.len());
//! assert!(minified.contains("data"));
//!
//! // What the pipeline needs is in the reflection, not in the text.
//! let reflection = wgslender::reflect(source)?;
//! assert_eq!(reflection.bindings[0].name, "data");
//! assert_eq!(reflection.entry_points[0].workgroup_size, Some([64, 1, 1]));
//! # Ok::<(), wgslender::Error>(())
//! ```
//!
//! ## What is here
//!
//! | To | Call |
//! |---|---|
//! | shrink a shader | [`minify`], [`minify_with`], [`minify_and_reflect`] |
//! | check one | [`validate`], [`lint`], [`lint_fix`] |
//! | describe one | [`reflect`], [`reflect_json`] |
//! | embed one in the binary | `include_wgsl!`, or `include_wgsl_compressed!` to store it deflated |
//! | generate Rust from one | `wgsl_module!` |
//! | embed one as WebAssembly | [`compile`] |
//! | edit one by symbol | [`refactor`] |
//!
//! ## Compile-time embedding
//!
//! `include_wgsl!` does the validating and the minifying while `cargo build`
//! runs, so a shader with a mistake in it fails the build rather than the
//! pipeline, and the bytes in the binary are the small ones. Its own page has
//! the worked example, the option table, and the one surprising rule: paths are
//! relative to the crate root, not to the file the macro is written in.
//!
//! `include_wgsl_compressed!`, behind the `compress` feature, goes one step
//! further: the binary carries a deflate stream, and a `CompressedWgsl`
//! inflates it on first use — once, or never, if nothing ever creates the
//! pipeline. On this crate's own demo fixture that is 968 bytes of source
//! stored as 274. `cargo run --features compress --example embed_compressed`
//! prints the three numbers.
//!
//! ## Generated Rust
//!
//! `wgsl_module!` goes further still: it reflects the shader at compile time
//! and generates the module a host program binds against — the slot of every
//! resource, and a `#[repr(C)]` struct per buffer with the shader's padding
//! made explicit, so the whole thing can be written to the GPU as bytes. Each
//! struct carries a `const _: ()` proof of its own size, alignment and field
//! offsets, which means a mis-mapping is a failed build rather than a wrong
//! pixel. `cargo run --example wgsl_module` prints one.
//!
//! ## What counts as an error
//!
//! A shader the library rejects is not a Rust `Err`. [`validate`] answers
//! `Ok(Validation)` whose `valid` is false, and [`lint`] an `Ok(LintReport)`
//! full of diagnostics — the shader failing *is* the answer. [`Error`] is for
//! the call itself going wrong, plus the two deliberate exceptions
//! [`Error::Compile`] and [`Error::Refactor`], both documented on the variant.
//!
//! ## Cargo features
//!
//! | Feature | Default | What it adds |
//! |---|---|---|
//! | `macros` | on | [`include_wgsl!`](include_wgsl) and [`wgsl_module!`](wgsl_module), and with them a proc-macro dependency that runs the library at compile time. |
//! | `compress` | off | `CompressedWgsl`, and — if `macros` is also on — `include_wgsl_compressed!`. Pulls in `miniz_oxide` for DEFLATE. |
//!
//! Turning `macros` off (`default-features = false`) leaves every function
//! above intact; it only removes the macros and the crates behind them.
//!
//! ## Edition support
//!
//! Edition 2024, so consumers need rustc 1.85 or newer. Building also runs
//! `zig build lib` against the wgslender sources, which needs Zig 0.16.0 —
//! unless `WGSLENDER_LIB_DIR` points at a prebuilt `libwgslender.a`. See
//! `packages/rust/README.md` in the repository for both paths.
//!
//! ## Crates
//!
//! This is the crate to depend on. [`wgslender-core`](wgslender_core) holds the
//! implementation, `wgslender-sys` the raw FFI declarations and
//! `wgslender-macros` the proc-macro; they are named separately so that the
//! `unsafe` and the proc-macro each have somewhere to live, not so that anyone
//! has to reach for them.
//!
//! [wgslender]: https://github.com/HugoDaniel/wgslender

/// Everything the implementation crate makes public, under this crate's name.
///
/// A glob rather than a written-out list, deliberately: the facade exists to
/// give the API a stable name, and re-exporting item by item would let the two
/// surfaces drift. It carries [`wgslender_core::refactor`] along with the flat
/// items, so that module reads as `wgslender::refactor`.
pub use wgslender_core::*;

/// Embed a WGSL file, validated and minified at compile time.
///
/// Named here rather than written here: the macro has to live in a crate of its
/// own, because a `proc-macro = true` crate can export nothing but macros. Its
/// full documentation comes with it, below.
///
/// # Examples
///
/// ```
/// // Any path relative to your own crate root. This one is this crate's own
/// // test fixture, because a doctest has to point somewhere real.
/// const SHADER: &str = wgslender::include_wgsl!("tests/fixtures/demo.wgsl");
///
/// assert!(SHADER.contains("@compute"));
/// assert!(SHADER.len() < 500);
/// ```
#[cfg(feature = "macros")]
pub use wgslender_macros::include_wgsl;

/// Embed a WGSL file compressed, inflating it on first use.
///
/// The same compile-time pipeline as [`include_wgsl!`](include_wgsl), storing
/// DEFLATE-compressed bytes instead of text. Needs the `compress` feature,
/// which is off by default. Its full documentation comes with it, below.
///
/// # Examples
///
/// ```
/// // A `static`, because the constructor is `const` and nothing inflates until
/// // something asks.
/// static SHADER: wgslender::CompressedWgsl =
///     wgslender::include_wgsl_compressed!("tests/fixtures/demo.wgsl");
///
/// assert!(SHADER.compressed_len() < SHADER.len(), "the binary carries the smaller half");
/// assert!(SHADER.as_str().contains("@compute"));
/// ```
#[cfg(all(feature = "macros", feature = "compress"))]
pub use wgslender_macros::include_wgsl_compressed;

/// Generate a Rust module from what a WGSL file declares.
///
/// The shader, the slot of every resource, a `#[repr(C)]` struct for every
/// buffer it takes, and the name of every entry point — worked out at compile
/// time by the same library [`reflect`] calls, and each struct carrying a proof
/// of its own layout. Its full documentation comes with it, below.
///
/// # Examples
///
/// ```
/// // Any path relative to your own crate root. This one is this crate's own
/// // test fixture, because a macro that reads files has to read a real one.
/// wgslender::wgsl_module!(pub demo, "tests/fixtures/demo.wgsl");
///
/// // What a pipeline is built from.
/// assert!(demo::SOURCE.contains("@compute"));
/// assert_eq!(demo::ENTRY_MAIN, "main");
/// assert_eq!(demo::ENTRY_MAIN_WORKGROUP_SIZE, [8, 8, 1]);
/// assert_eq!(demo::bindings::PARAMS, wgslender::BindingSlot { group: 0, binding: 0 });
///
/// // What the uniform buffer holds, laid out as the GPU will read it.
/// let params = demo::Params::new([1920.0, 1080.0], 0.5);
/// assert_eq!(size_of_val(&params), 16);
/// assert_eq!(params.resolution, [1920.0, 1080.0]);
/// ```
#[cfg(feature = "macros")]
pub use wgslender_macros::wgsl_module;
