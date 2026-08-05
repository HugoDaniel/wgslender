//! Minification.

use serde::Deserialize;
use wgslender_sys::{
    WGSLENDER_OPT_DEFAULT, wgslender_minify_and_reflect_c, wgslender_minify_c,
    wgslender_minify_json_c,
};

use crate::buffer::{checked_len, take_json, take_text};
use crate::error::Error;
use crate::options::MinifyOptions;
use crate::reflect::Reflection;

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

/// A minified shader, with what it cost and what it declares.
#[derive(Debug, Clone)]
#[non_exhaustive]
pub struct MinifiedShader {
    /// The minified WGSL.
    pub code: String,
    /// The size in bytes of the source that was handed in.
    pub original_size: u32,
    /// The size in bytes of `code`.
    pub minified_size: u32,
    /// Parse errors, when the source did not parse.
    ///
    /// Minification degrades rather than failing: an unparseable shader comes
    /// back unchanged in `code`, carrying the parser's complaints here. The
    /// same complaints also reach [`Reflection::errors`].
    pub errors: Vec<String>,
    /// What the shader declares, named as the *minified* code names it.
    pub reflection: Reflection,
}

/// Minify a shader and reflect the result in one call.
///
/// This is the only entry point that reports the sizes, and the only way to
/// learn what minification renamed things to: the reflection's `name_mapped`
/// and `ty_mapped` describe `code`, while `name` and `ty` still describe the
/// source. Reflecting the source separately could not tell you how the two line
/// up.
///
/// # Errors
///
/// [`Error::SourceTooLarge`] if the source or the serialized options do not fit
/// in a `u32`; [`Error::Internal`] if the library could not allocate its
/// result; [`Error::Wire`] if the envelope is not the JSON this crate expects.
///
/// # Examples
///
/// ```
/// use wgslender_core::{MinifyOptions, minify_and_reflect};
///
/// let source = "@group(0) @binding(0) var<storage, read_write> out: array<f32>;\n\
///               @compute @workgroup_size(1)\n\
///               fn main() { out[0] = 1.0; }\n";
/// let shader = minify_and_reflect(source, &MinifyOptions::default())?;
///
/// assert!(shader.minified_size < shader.original_size);
/// assert_eq!(shader.minified_size as usize, shader.code.len());
/// assert_eq!(shader.reflection.bindings[0].name, "out");
/// # Ok::<(), wgslender_core::Error>(())
/// ```
pub fn minify_and_reflect(source: &str, options: &MinifyOptions) -> Result<MinifiedShader, Error> {
    let source_len = checked_len(source)?;
    let options = serde_json::to_string(options)?;
    let options_len = checked_len(&options)?;
    // SAFETY: `source` and `options` are each valid for reads of their own
    // length for the whole call; the callee borrows neither beyond it.
    let result = unsafe {
        wgslender_minify_and_reflect_c(source.as_ptr(), source_len, options.as_ptr(), options_len)
    };
    // SAFETY: `json_ptr`/`json_len` are the pair the call just returned, and
    // this is the first and only adoption of them.
    let envelope: Envelope = unsafe { take_json(result.json_ptr, result.json_len) }?;
    Ok(MinifiedShader {
        code: envelope.minify.code,
        original_size: envelope.minify.original_size,
        minified_size: envelope.minify.minified_size,
        errors: envelope
            .minify
            .errors
            .into_iter()
            .map(|error| error.message)
            .collect(),
        reflection: envelope.reflect,
    })
}

/// The two-part envelope this one call returns, which no other call does.
#[derive(Deserialize)]
struct Envelope {
    minify: MinifyHalf,
    reflect: Reflection,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MinifyHalf {
    code: String,
    /// Objects here, bare strings on the reflect half of the same envelope.
    /// The asymmetry is the library's; [`MinifiedShader`] presents one shape.
    #[serde(default)]
    errors: Vec<WireMessage>,
    original_size: u32,
    minified_size: u32,
}

#[derive(Deserialize)]
struct WireMessage {
    message: String,
}
