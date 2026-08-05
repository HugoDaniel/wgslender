//! What a shader declares: its bindings, its struct layouts, its entry points.

use std::collections::BTreeMap;

use serde::Deserialize;
use wgslender_sys::wgslender_reflect_c;

use crate::buffer::{LibBuffer, checked_len, take_json};
use crate::error::Error;
use crate::wire_enum::wire_enum;

wire_enum! {
    /// Where a resource lives.
    pub enum AddressSpace: "an address space" {
        /// A uniform buffer.
        Uniform => "uniform",
        /// A storage buffer.
        Storage => "storage",
        /// An opaque handle — a texture or a sampler.
        Handle => "handle",
        /// Module-scope state, private to one invocation.
        Private => "private",
        /// Memory shared by a workgroup.
        Workgroup => "workgroup",
        /// A function's own locals.
        Function => "function",
        _ => Unknown => "unknown",
    }
}

wire_enum! {
    /// How a shader may touch a storage buffer.
    pub enum AccessMode: "an access mode" {
        /// Read-only.
        Read => "read",
        /// Write-only.
        Write => "write",
        /// Both.
        ReadWrite => "read_write",
        _ => Unknown => "unknown",
    }
}

wire_enum! {
    /// The pipeline stage an entry point runs in.
    pub enum ShaderStage: "a shader stage" {
        /// `@vertex`.
        Vertex => "vertex",
        /// `@fragment`.
        Fragment => "fragment",
        /// `@compute`.
        Compute => "compute",
        _ => Unknown => "unknown",
    }
}

/// One `@group`/`@binding` resource.
///
/// `name` is what the shader source calls it and `name_mapped` is what it is
/// called in the code that came back — the two differ only when the reflection
/// came from [`minify_and_reflect`](crate::minify_and_reflect), which is the
/// reason that call exists.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct Binding {
    /// The `@group` index.
    pub group: u32,
    /// The `@binding` index.
    pub binding: u32,
    /// The variable's name in the source.
    pub name: String,
    /// The variable's name after renaming.
    pub name_mapped: String,
    /// Which address space the variable is declared in.
    pub address_space: AddressSpace,
    /// The declared access mode, which only storage buffers carry.
    #[serde(default)]
    pub access_mode: Option<AccessMode>,
    /// The type as written, e.g. `Params` or `array<vec4f>`.
    #[serde(rename = "type")]
    pub ty: String,
    /// The type's name after renaming.
    #[serde(rename = "typeMapped")]
    pub ty_mapped: String,
    /// The host-shareable memory layout, for the buffer bindings that have one.
    ///
    /// Absent for textures and samplers, which are opaque, and for buffers
    /// whose size is not known until runtime.
    #[serde(default)]
    pub layout: Option<StructLayout>,
}

/// How a struct is laid out in memory, per WGSL's host-shareable rules.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct StructLayout {
    /// Size in bytes, including the tail padding.
    pub size: u32,
    /// The alignment the whole struct requires.
    pub alignment: u32,
    /// The members, in declaration order.
    pub fields: Vec<Field>,
}

/// One member of a struct, placed.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct Field {
    /// The member's name in the source.
    pub name: String,
    /// The member's name after renaming.
    pub name_mapped: String,
    /// The type as written.
    #[serde(rename = "type")]
    pub ty: String,
    /// The type's name after renaming.
    #[serde(rename = "typeMapped")]
    pub ty_mapped: String,
    /// Byte offset from the start of the struct.
    pub offset: u32,
    /// Size in bytes, excluding any padding that follows.
    pub size: u32,
    /// The alignment this member requires.
    pub alignment: u32,
}

/// A function a pipeline can be built around.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct EntryPoint {
    /// The function's name in the source.
    pub name: String,
    /// The stage its attribute names.
    pub stage: ShaderStage,
    /// The `@workgroup_size`, which only a compute entry point carries.
    #[serde(default)]
    pub workgroup_size: Option<[u32; 3]>,
}

/// Everything [`reflect`] could work out about a shader.
///
/// This is a typed view of part of wgslender's reflection envelope: the
/// bindings, the struct layouts and the entry points. The envelope also carries
/// the call graph, aliases, overrides and per-kind views of the bindings, which
/// this crate does not type yet — reach them through [`reflect_json`].
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct Reflection {
    /// The envelope's schema version, currently 2.
    pub version: u32,
    /// Every `@group`/`@binding` resource, in declaration order.
    pub bindings: Vec<Binding>,
    /// Every host-shareable struct, by the name it was declared under.
    pub structs: BTreeMap<String, StructLayout>,
    /// Every entry point, in declaration order.
    pub entry_points: Vec<EntryPoint>,
    /// Parse errors, when the source did not parse.
    ///
    /// Reflection degrades rather than failing: an unparseable shader comes
    /// back as an empty reflection carrying the parser's complaints. A shader
    /// that parses but does not type-check reflects cleanly and leaves this
    /// empty — reflection never type-checks.
    #[serde(default)]
    pub errors: Vec<String>,
}

/// Work out what a shader declares.
///
/// Reflection is not validation: a shader that parses reflects successfully
/// however little sense it makes. See [`Reflection::errors`].
///
/// # Errors
///
/// [`Error::SourceTooLarge`] if the source does not fit in a `u32`;
/// [`Error::Internal`] if the library could not allocate its result;
/// [`Error::Wire`] if the envelope is not the JSON this crate expects.
///
/// # Examples
///
/// ```
/// use wgslender_core::{AddressSpace, reflect};
///
/// let source = "@group(0) @binding(0) var<uniform> scale: f32;\n\
///               @group(0) @binding(1) var<storage, read_write> out: array<f32>;\n\
///               @compute @workgroup_size(64)\n\
///               fn main(@builtin(local_invocation_index) i: u32) { out[i] = scale; }";
/// let reflection = reflect(source)?;
///
/// let binding = &reflection.bindings[0];
/// assert_eq!((binding.group, binding.binding), (0, 0));
/// assert_eq!(binding.address_space, AddressSpace::Uniform);
/// assert_eq!(reflection.entry_points[0].workgroup_size, Some([64, 1, 1]));
/// # Ok::<(), wgslender_core::Error>(())
/// ```
pub fn reflect(source: &str) -> Result<Reflection, Error> {
    let result = reflect_raw(source)?;
    // SAFETY: `json_ptr`/`json_len` are the pair the call just returned, and
    // this is the first and only adoption of them.
    unsafe { take_json(result.json_ptr, result.json_len) }
}

/// Reflect a shader and hand back the envelope as it arrived.
///
/// [`Reflection`] types the part of the envelope this crate has an opinion
/// about. This is everything else: source spans, stable ids, the call graph,
/// per-kind binding views, aliases and overrides.
///
/// # Errors
///
/// As [`reflect`], minus [`Error::Wire`] — nothing is parsed.
///
/// # Examples
///
/// ```
/// let json = wgslender_core::reflect_json("@compute @workgroup_size(1) fn main() {}")?;
/// assert!(json.starts_with(r#"{"version":2"#));
/// # Ok::<(), wgslender_core::Error>(())
/// ```
pub fn reflect_json(source: &str) -> Result<String, Error> {
    let result = reflect_raw(source)?;
    // SAFETY: `json_ptr`/`json_len` are the pair the call just returned, and
    // this is the first and only adoption of them.
    let buffer = unsafe { LibBuffer::adopt(result.json_ptr, result.json_len) };
    let Some(buffer) = buffer else {
        return Err(Error::Internal);
    };
    buffer.into_string()
}

/// The FFI call both entry points share. The caller owns the returned buffer.
fn reflect_raw(source: &str) -> Result<wgslender_sys::WgslenderJsonResult, Error> {
    let source_len = checked_len(source)?;
    // SAFETY: `source` is valid for reads of `source_len` bytes for the whole
    // call, and the library only reads through the pointer.
    Ok(unsafe { wgslender_reflect_c(source.as_ptr(), source_len) })
}

#[cfg(test)]
mod tests {
    use super::{AccessMode, AddressSpace, ShaderStage};

    #[test]
    fn known_spellings_round_trip() {
        assert_eq!(AddressSpace::Uniform.as_str(), "uniform");
        assert_eq!(AccessMode::ReadWrite.as_str(), "read_write");
        assert_eq!(ShaderStage::Compute.to_string(), "compute");
    }

    #[test]
    fn an_unrecognised_spelling_does_not_fail_the_parse() {
        let Ok(space) = serde_json::from_str::<AddressSpace>(r#""storage_buffer_v2""#) else {
            panic!("an unknown address space must still parse")
        };
        assert_eq!(space, AddressSpace::Unknown);
    }
}
