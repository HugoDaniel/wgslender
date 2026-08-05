//! Compiling a shader to a self-expanding WebAssembly module.

use core::fmt;

use wgslender_sys::wgslender_compile_c;

use crate::buffer::{LibBuffer, checked_len, take_json};
use crate::error::Error;
use crate::options::MinifyOptions;
use crate::validate::Diagnostic;

/// A shader compiled to a WebAssembly module that regenerates it.
///
/// The module has no imports and two exports: `memory`, and a
/// `generate() -> i32` that writes the minified WGSL to offset 0 and returns
/// its length. It is a compressed shader, not a compiled pipeline — the WGSL
/// still goes to `createShaderModule` on the other side.
#[derive(Clone)]
#[non_exhaustive]
pub struct CompiledShader {
    /// The module, ready for `WebAssembly.instantiate`.
    pub wasm: Vec<u8>,
    /// The size in bytes of the WGSL that was handed in.
    ///
    /// Not the size of the text the module expands to, which is smaller: it is
    /// minified. Compare against `wasm.len()` for what compiling bought.
    pub original_size: u32,
}

/// Prints the module's size rather than its bytes, which no reader wants.
impl fmt::Debug for CompiledShader {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CompiledShader")
            .field("wasm", &format_args!("<{} bytes>", self.wasm.len()))
            .field("original_size", &self.original_size)
            .finish()
    }
}

/// Compile a shader to a WebAssembly module that regenerates it at runtime.
///
/// The module carries the shader minified and byte-pair encoded, with a ~110
/// byte decoder. The `options` are the minification options applied before
/// encoding; declaration sorting and scope-local renaming are always on here,
/// because they compress better.
///
/// # Errors
///
/// [`Error::Compile`] if the shader does not parse — the compiler produces
/// diagnostics and no module. A shader that parses but does not type-check
/// compiles: the compiler never type-checks, so [`validate`](crate::validate)
/// separately if you need to know. Also [`Error::SourceTooLarge`] if the source
/// or the serialized options do not fit in a `u32`, [`Error::Internal`] if the
/// library could not allocate, and [`Error::Wire`] if the diagnostics are not
/// the JSON this crate expects.
///
/// # Examples
///
/// ```
/// use wgslender_core::{MinifyOptions, compile};
///
/// let source = "@compute @workgroup_size(1)\nfn main() {}\n";
/// let compiled = compile(source, &MinifyOptions::default())?;
///
/// assert!(compiled.wasm.starts_with(b"\0asm"));
/// assert_eq!(compiled.original_size as usize, source.len());
/// # Ok::<(), wgslender_core::Error>(())
/// ```
///
/// On the other side of the wire, the module hands back the WGSL:
///
/// ```javascript
/// const { instance } = await WebAssembly.instantiate(wasm);
/// const length = instance.exports.generate();
/// const wgsl = new TextDecoder().decode(
///     new Uint8Array(instance.exports.memory.buffer, 0, length),
/// );
/// device.createShaderModule({ code: wgsl });
/// ```
pub fn compile(source: &str, options: &MinifyOptions) -> Result<CompiledShader, Error> {
    let source_len = checked_len(source)?;
    let options = serde_json::to_string(options)?;
    let options_len = checked_len(&options)?;
    // SAFETY: `source` and `options` are each valid for reads of their own
    // length for the whole call, and the library only reads through them.
    let result =
        unsafe { wgslender_compile_c(source.as_ptr(), source_len, options.as_ptr(), options_len) };

    // Adopt the module before anything can fail, so that unreadable diagnostics
    // still free it.
    // SAFETY: `wasm_ptr`/`wasm_len` are the pair the call just returned, and
    // this is the first and only adoption of them.
    let wasm = unsafe { LibBuffer::adopt(result.wasm_ptr, result.wasm_len) };
    // SAFETY: `errors_json_ptr`/`errors_json_len` are a different buffer from
    // the same result, likewise adopted exactly once.
    let diagnostics: Vec<Diagnostic> =
        unsafe { take_json(result.errors_json_ptr, result.errors_json_len) }?;

    if !diagnostics.is_empty() {
        return Err(Error::Compile(diagnostics));
    }
    let Some(wasm) = wasm else {
        return Err(Error::Internal);
    };
    Ok(CompiledShader {
        wasm: wasm.into_bytes(),
        original_size: result.original_size,
    })
}
