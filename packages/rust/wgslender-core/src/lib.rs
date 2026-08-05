//! # wgslender-core
//!
//! Implementation detail of the [`wgslender`] crate — depend on `wgslender`,
//! not on this. The facade re-exports everything here under a stable name; this
//! crate's own surface may change between releases.
//!
//! ## Quick start
//!
//! ```
//! let minified = wgslender_core::minify("@compute @workgroup_size(1)\nfn main() {}\n")?;
//! assert!(minified.len() < 40);
//! # Ok::<(), wgslender_core::Error>(())
//! ```
//!
//! ## What this crate is
//!
//! A safe wrapper over the wgslender C ABI, which
//! [`wgslender-sys`](wgslender_sys) declares. Every `unsafe` block in the
//! wrapper lives here, in the private `buffer` module and at the call sites
//! that hand raw pointers to the library; nothing in the public API can be
//! misused into undefined behavior.
//!
//! The C ABI is stateless — no handle to open, no global to initialise, one
//! arena per call — so these are plain functions rather than methods on a
//! context object.
//!
//! ## What counts as an error
//!
//! A shader the library rejects is not a Rust `Err`. [`validate`] hands back an
//! `Ok(Validation)` whose `valid` is false, and [`lint`] an `Ok(LintReport)`
//! full of diagnostics — the shader failing is the answer, not a failure to
//! answer. [`minify`] and [`reflect`] go further and degrade: an unparseable
//! shader comes back unchanged, or as an empty reflection carrying the parse
//! errors. [`Error`] is otherwise for the call itself going wrong: an
//! allocation the library could not make, a payload that is not the JSON this
//! crate expects, a source too long for the ABI's `u32` lengths.
//!
//! [`compile`] is the exception, and deliberately so: a shader that does not
//! parse yields [`Error::Compile`], because the alternative is handing back an
//! empty module that a caller would embed by mistake.
//!
//! The [`refactor`] module draws the line somewhere else again, because its
//! failures are about the *request*: renaming a symbol that is not there, or to
//! a name WGSL will not accept, yields [`Error::Refactor`]. Its questions —
//! "where is this symbol", "does this ID still resolve" — answer `Ok(None)`.
//!
//! ## Memory
//!
//! Results come back as buffers the library allocated and the caller must
//! release with a *sized* free. That ownership is a private `LibBuffer` type
//! whose `Drop` performs the free; the public API only ever hands out owned
//! `String`s copied out of it. The one exception is
//! [`version`], which returns a pointer into static storage that must never be
//! freed — a different ownership rule, so a different code path.
//!
//! [`wgslender`]: https://crates.io/crates/wgslender

mod buffer;
mod compile;
mod error;
mod lint;
mod minify;
mod options;
pub mod refactor;
mod reflect;
mod validate;
mod wire_enum;

pub use crate::compile::{CompiledShader, compile};
pub use crate::error::Error;
pub use crate::lint::{
    LintConfig, LintFixOutcome, LintReport, Pack, RuleSetting, Value, lint, lint_fix,
};
pub use crate::minify::{MinifiedShader, minify, minify_and_reflect, minify_with};
pub use crate::options::MinifyOptions;
pub use crate::reflect::{
    AccessMode, AddressSpace, Binding, EntryPoint, Field, Reflection, ShaderStage, StructLayout,
    reflect, reflect_json,
};
pub use crate::validate::{Diagnostic, Severity, Strictness, Validation, validate};

/// The version of the linked wgslender library, as `major.minor.patch`.
///
/// # Panics
///
/// If the library's version string is not UTF-8. It is an ASCII literal
/// compiled into the same library this crate links, so that cannot happen
/// without the link having gone wrong.
///
/// # Examples
///
/// ```
/// let version = wgslender_core::version();
/// assert_eq!(version.split('.').count(), 3);
/// ```
#[must_use]
pub fn version() -> &'static str {
    let mut len: u32 = 0;
    // SAFETY: `len` is a live, aligned, initialised `u32`, and the callee only
    // writes the version's length through it.
    let ptr = unsafe { wgslender_sys::wgslender_version_c(&raw mut len) };
    // SAFETY: the returned pointer is the library's static version string of
    // exactly `len` bytes. Static storage means it stays readable for the rest
    // of the program, so a `'static` slice is sound — and it must not be freed,
    // which is why this does not go through `LibBuffer`.
    let bytes = unsafe { core::slice::from_raw_parts(ptr, len as usize) };
    match core::str::from_utf8(bytes) {
        Ok(version) => version,
        Err(_) => unreachable!("libwgslender's version is an ASCII literal"),
    }
}

#[cfg(test)]
mod tests {
    use super::version;

    /// Skipped under miri: it calls into a static library compiled from Zig,
    /// which miri cannot interpret.
    #[test]
    #[cfg(not(miri))]
    fn version_is_a_three_part_number() {
        let version = version();
        let parts: Vec<&str> = version.split('.').collect();
        assert_eq!(
            parts.len(),
            3,
            "expected a three-part version, got {version:?}"
        );
        for part in parts {
            assert!(
                !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit()),
                "non-numeric component in version {version:?}"
            );
        }
    }
}
