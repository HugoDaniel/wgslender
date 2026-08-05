//! Minification.

use wgslender_sys::{WGSLENDER_OPT_DEFAULT, wgslender_minify_c, wgslender_minify_json_c};

use crate::buffer::{checked_len, take_text};
use crate::error::Error;
use crate::options::MinifyOptions;

/// Minify WGSL with wgslender's default options.
///
/// Whitespace, identifiers, syntax and tree shaking are all on; external
/// `@group`/`@binding` names are left alone so a host program's bindings keep
/// working. Use [`minify_with`] to change any of that.
///
/// Source that does not parse is returned unchanged rather than rejected —
/// wgslender's documented contract. Source that parses but fails semantic
/// analysis *is* minified: the minifier does not type-check, so validate
/// separately if you need to know.
///
/// # Errors
///
/// [`Error::SourceTooLarge`] if the source exceeds `u32::MAX` bytes;
/// [`Error::Internal`] if the library could not allocate the result;
/// [`Error::InvalidUtf8`] if it produced bytes that are not UTF-8.
///
/// # Examples
///
/// ```
/// let minified = wgslender_core::minify("@compute @workgroup_size(1)\nfn main() {}\n")?;
/// assert_eq!(minified, "@compute @workgroup_size(1) fn main(){}");
/// # Ok::<(), wgslender_core::Error>(())
/// ```
pub fn minify(source: &str) -> Result<String, Error> {
    let source_len = checked_len(source)?;
    // SAFETY: `source` is valid for reads of `source_len` bytes for the whole
    // call, which is the function's only precondition.
    let result = unsafe { wgslender_minify_c(source.as_ptr(), source_len, WGSLENDER_OPT_DEFAULT) };
    take_text(result)
}

/// Minify WGSL with explicit options.
///
/// Options are overrides: whatever [`MinifyOptions`] leaves unset keeps
/// wgslender's own default, so passing `&MinifyOptions::default()` is the same
/// as calling [`minify`].
///
/// # Errors
///
/// [`Error::SourceTooLarge`] if the source exceeds `u32::MAX` bytes;
/// [`Error::Wire`] if the options cannot be serialized; [`Error::Internal`] if
/// the library could not allocate the result; [`Error::InvalidUtf8`] if it
/// produced bytes that are not UTF-8.
///
/// # Examples
///
/// ```
/// use wgslender_core::{MinifyOptions, minify_with};
///
/// let source = "@compute @workgroup_size(1)\nfn main() {}\n";
/// let options = MinifyOptions::default().minify_identifiers(false);
/// let minified = minify_with(source, &options)?;
/// assert!(minified.contains("fn main"));
/// # Ok::<(), wgslender_core::Error>(())
/// ```
pub fn minify_with(source: &str, options: &MinifyOptions) -> Result<String, Error> {
    let source_len = checked_len(source)?;
    let options = serde_json::to_string(options)?;
    let options_len = checked_len(&options)?;
    // SAFETY: `source` and `options` are each valid for reads of their own
    // length for the whole call; the callee borrows neither beyond it.
    let result = unsafe {
        wgslender_minify_json_c(source.as_ptr(), source_len, options.as_ptr(), options_len)
    };
    take_text(result)
}
