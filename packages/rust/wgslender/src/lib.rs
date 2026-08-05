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
//! | embed one in the binary | `include_wgsl!`, with the default `macros` feature |
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
//! | `macros` | on | [`include_wgsl!`](include_wgsl), and with it a proc-macro dependency that runs the library at compile time. |
//!
//! Turning `macros` off (`default-features = false`) leaves every function
//! above intact; it only removes the macro and the crates behind it.
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
