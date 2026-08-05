//! # wgslender-macros
//!
//! Implementation detail of the [`wgslender`] crate — depend on `wgslender`,
//! which re-exports [`include_wgsl`] behind its default `macros` feature.
//!
//! ## What a compile-time macro buys
//!
//! A shader embedded with `include_str!` is checked when the pipeline is
//! created, which is to say when the program runs, on a machine that may not be
//! the one the mistake was made on. [`include_wgsl`] runs the same validator
//! `cargo build` does — the real wgslender library, linked into the compiler's
//! address space — so a shader with an error in it fails the build, and the
//! bytes that reach the binary are already minified.
//!
//! [`wgslender`]: https://crates.io/crates/wgslender

use proc_macro::TokenStream;
use syn::parse::ParseStream;
use syn::parse_macro_input;

use crate::parse::Embedding;

mod expand;
mod parse;

/// Embed a WGSL file, validated and minified while your crate is compiled.
///
/// Expands to a `&'static str`, so it goes wherever a string literal goes: a
/// `const`, a `static`, an argument to `wgpu`'s `ShaderSource::Wgsl`.
///
/// # Where the path points
///
/// **Relative paths resolve against `CARGO_MANIFEST_DIR`** — the root of the
/// package being compiled — not against the file the macro was written in.
/// That is not a choice: a proc-macro is handed tokens, and on stable Rust it
/// cannot ask which file they came from. A path that starts with the crate root
/// therefore reads the same from every module:
/// `include_wgsl!("shaders/blur.wgsl")`. Absolute paths are taken as they
/// stand.
///
/// The expansion contains an `include_bytes!` of the resolved path that nothing
/// reads, purely so the compiler records the dependency: editing the shader
/// rebuilds whatever embedded it.
///
/// # Options
///
/// Each is `key = value`, after the path, in any order.
///
/// | Key | Value | Default | Meaning |
/// |---|---|---|---|
/// | `minify` | bool | `true` | Minify. `false` embeds the file as written. |
/// | `validate` | bool | `true` | Type-check. `false` embeds a fragment that only makes sense once something concatenates it. |
/// | `strict` | bool | `false` | Treat warnings as errors while validating. |
/// | `keep_names` | `["a", "b"]` | — | Identifiers minification must not rename. |
///
/// Every [`MinifyOptions`](wgslender_core::MinifyOptions) boolean is accepted
/// under its own name too — `minify_whitespace`, `minify_identifiers`,
/// `minify_syntax`, `tree_shaking`, `mangle_external_bindings`,
/// `preserve_uniform_struct_types`, `sort_declarations`, `scope_local_rename` —
/// each overriding one of wgslender's defaults.
///
/// A key that cannot mean anything is an error rather than a silent no-op:
/// `keep_names` next to `minify = false` names something no minifier is going
/// to rename, and saying so is more useful than ignoring it.
///
/// # Compile errors
///
/// The macro fails the build, pointing at the path literal, when the file
/// cannot be read (the message names the absolute path it tried), when the
/// shader does not validate (the message carries each of the library's
/// diagnostics as `file:line:column: severity[code]: message`), or when an
/// option key does not exist (the message lists the ones that do).
///
/// # Examples
///
/// ```
/// const SHADER: &str = wgslender_macros::include_wgsl!("wgsl/example.wgsl");
/// const AS_WRITTEN: &str = wgslender_macros::include_wgsl!("wgsl/example.wgsl", minify = false);
///
/// assert!(SHADER.contains("@compute"));
/// assert!(AS_WRITTEN.starts_with("//"), "unminified, the file's comments are still there");
/// assert!(SHADER.len() < AS_WRITTEN.len() / 2, "got {SHADER}");
/// ```
///
/// Keeping a name the minifier would otherwise rename:
///
/// ```
/// const KEPT: &str = wgslender_macros::include_wgsl!("wgsl/example.wgsl", keep_names = ["data"]);
///
/// assert!(KEPT.contains("data"));
/// ```
///
/// A shader that does not type-check does not compile:
///
/// ```compile_fail
/// const BROKEN: &str = wgslender_macros::include_wgsl!("wgsl/broken.wgsl");
/// ```
///
/// Unless the check is what you asked to skip:
///
/// ```
/// const BROKEN: &str = wgslender_macros::include_wgsl!("wgsl/broken.wgsl", validate = false);
///
/// assert!(BROKEN.contains("scale"));
/// ```
#[proc_macro]
pub fn include_wgsl(input: TokenStream) -> TokenStream {
    embed(input, Embedding::Text)
}

/// Embed a WGSL file compressed, inflating it on first use.
///
/// Expands to a [`CompressedWgsl`], normally a `static`: the shader is
/// validated and minified like [`include_wgsl!`](include_wgsl), then run
/// through DEFLATE, so the binary carries the stream instead of the text. Nothing
/// inflates until something calls `as_str`, and then only once.
///
/// Everything [`include_wgsl!`](include_wgsl) documents — where the path
/// points, the options, what a compile error looks like — holds here too, with
/// two differences:
///
/// - `sort_declarations` and `scope_local_rename` default to **on**. Both exist
///   to make minified text repeat itself, which costs a reader nothing and
///   saves DEFLATE a good deal. Name either one to turn it back off.
/// - The expansion mentions [`CompressedWgsl`] by the path
///   `::wgslender::CompressedWgsl`, so the crate has to be reachable under the
///   name `wgslender` where the macro is written — renaming the dependency in
///   `Cargo.toml` breaks it. [`include_wgsl!`](include_wgsl) expands to a plain
///   literal and has no such requirement.
///
/// The worked example is on the facade's re-export, which is the only place
/// this expansion can compile.
///
/// [`CompressedWgsl`]: wgslender_core::CompressedWgsl
#[cfg(feature = "compress")]
#[proc_macro]
pub fn include_wgsl_compressed(input: TokenStream) -> TokenStream {
    embed(input, Embedding::Compressed)
}

/// Both macros: one pipeline, differing in what it hands back.
fn embed(input: TokenStream, embedding: Embedding) -> TokenStream {
    let parser = |stream: ParseStream| parse::Invocation::parse(stream, embedding);
    let invocation = parse_macro_input!(input with parser);
    expand::expand(&invocation)
        .unwrap_or_else(syn::Error::into_compile_error)
        .into()
}
