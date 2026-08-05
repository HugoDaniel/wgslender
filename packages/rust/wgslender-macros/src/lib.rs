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
use syn::parse_macro_input;

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
    let invocation = parse_macro_input!(input as parse::Invocation);
    expand::expand(&invocation)
        .unwrap_or_else(syn::Error::into_compile_error)
        .into()
}
