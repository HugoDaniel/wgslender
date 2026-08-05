//! Doing the work the expansion stands for: read, check, minify, embed.

use std::env;
use std::fmt::Write as _;
use std::fs;
use std::path::{Path, PathBuf};

use proc_macro2::TokenStream;
use quote::quote;
use syn::LitStr;
#[cfg(feature = "compress")]
use wgslender_core::CompressedWgsl;
use wgslender_core::{Diagnostic, Error, Validation, minify_with, validate};

use crate::parse::{Checking, Embedding, Invocation, Minification};

/// The whole macro, as an expression.
pub(crate) fn expand(invocation: &Invocation) -> syn::Result<TokenStream> {
    let absolute = resolve(&invocation.path)?;
    let source = read(&invocation.path, &absolute)?;
    check(invocation, &source)?;
    let text = embed(invocation, &source)?;
    let tracked = tracking_path(&invocation.path, &absolute)?;
    let value = match invocation.embedding {
        Embedding::Text => quote! { #text },
        #[cfg(feature = "compress")]
        Embedding::Compressed => compressed(&invocation.path, &text)?,
    };

    Ok(quote! {
        {
            // Nothing reads this constant. It exists so that the compiler
            // records a dependency on the shader, and editing the shader
            // rebuilds whatever embedded it.
            const _: &[u8] = ::core::include_bytes!(#tracked);
            #value
        }
    })
}

/// The text as the two parts `CompressedWgsl` puts back together.
///
/// The type is named `::wgslender::…`, the facade's path, because that is where
/// the expansion lands and this crate's own name means nothing there. Renaming
/// the `wgslender` dependency therefore breaks this expansion — the documented
/// limitation of embedding compressed.
#[cfg(feature = "compress")]
fn compressed(path: &LitStr, text: &str) -> syn::Result<TokenStream> {
    let Ok(text_len) = u32::try_from(text.len()) else {
        return Err(syn::Error::new_spanned(
            path,
            format!(
                "this shader comes to {} bytes, and a compressed embedding \
                 records the inflated length in a u32 — {} at most",
                text.len(),
                u32::MAX,
            ),
        ));
    };
    let deflate = proc_macro2::Literal::byte_string(&CompressedWgsl::__deflate(text));
    Ok(quote! {
        ::wgslender::CompressedWgsl::__from_parts(#deflate, #text_len)
    })
}

/// Where the path in the invocation points.
///
/// Relative paths resolve against `CARGO_MANIFEST_DIR` — the root of the
/// package being compiled — because that is the only anchor a proc-macro has:
/// the expansion knows which crate asked, not which file. An absolute path is
/// taken as it stands.
fn resolve(path: &LitStr) -> syn::Result<PathBuf> {
    let Ok(manifest_dir) = env::var("CARGO_MANIFEST_DIR") else {
        return Err(syn::Error::new_spanned(
            path,
            "CARGO_MANIFEST_DIR is not set, so there is nothing to resolve this path against; \
             this macro needs to be expanded by a build cargo drives",
        ));
    };
    Ok(Path::new(&manifest_dir).join(path.value()))
}

/// The file's text, or an error that says where the macro looked.
fn read(path: &LitStr, absolute: &Path) -> syn::Result<String> {
    fs::read_to_string(absolute).map_err(|err| {
        syn::Error::new_spanned(
            path,
            format!(
                "cannot read {}: {err}\n\
                 a relative path is resolved against CARGO_MANIFEST_DIR, the root of the package \
                 being compiled — not against the file this macro was written in",
                absolute.display(),
            ),
        )
    })
}

/// Type-checks the shader, unless the invocation asked not to.
fn check(invocation: &Invocation, source: &str) -> syn::Result<()> {
    let Checking::Validate = invocation.checking else {
        return Ok(());
    };
    let report = validate(source, invocation.strictness)
        .map_err(|err| library_failed(&invocation.path, "validate", &err))?;
    if report.valid {
        return Ok(());
    }
    Err(syn::Error::new_spanned(
        &invocation.path,
        rejection(&invocation.path.value(), &report),
    ))
}

/// The text to embed: minified, or the file as written.
fn embed(invocation: &Invocation, source: &str) -> syn::Result<String> {
    match invocation.minification {
        Minification::Verbatim => Ok(source.to_owned()),
        Minification::Minify => minify_with(source, &invocation.options)
            .map_err(|err| library_failed(&invocation.path, "minify", &err)),
    }
}

/// The absolute path as a string, for `include_bytes!`.
fn tracking_path(path: &LitStr, absolute: &Path) -> syn::Result<String> {
    match absolute.to_str() {
        Some(tracked) => Ok(tracked.to_owned()),
        None => Err(syn::Error::new_spanned(
            path,
            format!(
                "{} is not valid UTF-8, so it cannot be written into the expansion",
                absolute.display(),
            ),
        )),
    }
}

/// The library's verdict, rendered the way a compiler renders one.
///
/// Every diagnostic is listed, not only the errors: under
/// `strict = true` it is the warnings that reject the shader, and a report that
/// hid them would be explaining nothing.
fn rejection(path: &str, report: &Validation) -> String {
    let mut message = format!("{path} is not valid WGSL");
    for diagnostic in &report.diagnostics {
        // Writing into a String cannot fail, and there is no error to handle.
        let _ = write!(message, "\n{}", render(path, diagnostic));
    }
    message
}

/// One diagnostic as `file:line:column: severity[code]: message`.
fn render(path: &str, diagnostic: &Diagnostic) -> String {
    let code = match &diagnostic.code {
        Some(code) => format!("[{code}]"),
        None => String::new(),
    };
    format!(
        "{path}:{line}:{column}: {severity}{code}: {message}",
        line = diagnostic.line,
        column = diagnostic.column,
        severity = diagnostic.severity,
        message = diagnostic.message,
    )
}

/// The call into the library went wrong, which is not the shader's fault.
fn library_failed(path: &LitStr, what: &str, err: &Error) -> syn::Error {
    syn::Error::new_spanned(path, format!("could not {what} this shader: {err}"))
}

#[cfg(test)]
mod tests {
    use quote::quote;
    use syn::parse::{ParseStream, Parser as _};

    use super::expand;
    use crate::parse::{Embedding, Invocation};

    fn expanded(invocation: proc_macro2::TokenStream) -> String {
        let parser = |stream: ParseStream| Invocation::parse(stream, Embedding::Text);
        let invocation = match parser.parse2(invocation) {
            Ok(invocation) => invocation,
            Err(err) => panic!("the invocation did not parse: {err}"),
        };
        match expand(&invocation) {
            Ok(tokens) => tokens.to_string(),
            Err(err) => panic!("the invocation did not expand: {err}"),
        }
    }

    /// The `include_bytes!` is the only thing tying the compilation to the
    /// shader. Nothing reads it, nothing fails without it, and a build that
    /// stopped noticing edited shaders would look exactly like a working one —
    /// so it is pinned here rather than left to be noticed.
    #[test]
    #[cfg(not(miri))]
    fn the_expansion_tracks_the_file_it_read() {
        let tokens = expanded(quote! { "wgsl/example.wgsl" });
        assert!(
            tokens.contains("include_bytes"),
            "no rebuild tracking in: {tokens}"
        );
        assert!(
            tokens.contains("wgsl/example.wgsl"),
            "the tracked path is not the one that was read: {tokens}"
        );
    }

    /// The path resolves against this package, so a shader that is here is
    /// found from anywhere the macro is written.
    #[test]
    #[cfg(not(miri))]
    fn a_relative_path_resolves_against_the_manifest_directory() {
        let tokens = expanded(quote! { "wgsl/example.wgsl" });
        assert!(
            tokens.contains(env!("CARGO_MANIFEST_DIR")),
            "the tracked path is not absolute: {tokens}"
        );
    }
}
