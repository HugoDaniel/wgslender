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
//! | embed one as WebAssembly | [`compile`] |
//! | edit one by symbol | [`refactor`] |
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
//! None. Everything above is always available.
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
//! implementation and `wgslender-sys` the raw FFI declarations; both are named
//! separately so that the `unsafe` has somewhere to live, not so that anyone
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
