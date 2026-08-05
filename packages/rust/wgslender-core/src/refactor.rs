//! Renaming, locating and removing declarations.
//!
//! Two ways to name the symbol you mean. A **byte offset** is what an editor
//! has — the cursor — and [`find_references`], [`rename`] and [`rename_apply`]
//! take one. A [`StableId`] is what a program has: an opaque, reparse-stable
//! name for a symbol, obtained once with [`stable_id_at_offset`] and still
//! valid after edits elsewhere in the file have moved every offset. Everything
//! else here takes an ID.
//!
//! Each mutating call comes in two forms: one that returns the [`Edit`]s so a
//! caller can apply them to its own buffer, and an `_apply` form that returns
//! the rewritten source. They do the same work; pick by what you already hold.
//!
//! Offsets and ranges are UTF-8 **byte** offsets into the source, which is what
//! Rust's own string slicing wants. An editor working in UTF-16 code units must
//! convert.

use core::fmt;
use core::str::FromStr;

use serde::Deserialize;
use wgslender_sys::{
    WgslenderJsonResult, wgslender_change_type_apply_by_id_c, wgslender_change_type_by_id_c,
    wgslender_find_references_c, wgslender_locate_declaration_c, wgslender_locate_stable_id_c,
    wgslender_locate_type_c, wgslender_remove_declaration_apply_by_id_c,
    wgslender_remove_declaration_by_id_c, wgslender_rename_apply_c, wgslender_rename_by_id_c,
    wgslender_rename_c, wgslender_stable_id_at_offset_c,
};

use crate::buffer::{checked_len, take_json};
use crate::error::Error;

/// A reparse-stable name for one symbol, such as `v1:fn:main/block#0/let:x`.
///
/// Opaque: the spelling is the library's business and may change between
/// versions, so treat it as a token to hand back rather than a path to parse.
/// It stays valid across edits that do not touch the symbol's own declaration,
/// which is the whole reason to hold one instead of a byte offset.
///
/// # Examples
///
/// ```
/// use wgslender_core::refactor::{locate_stable_id, stable_id_at_offset};
///
/// let source = "@compute @workgroup_size(1)\nfn main() { let x = 1.0; }\n";
/// let offset = u32::try_from(source.find("main").unwrap_or_default())?;
///
/// let Some(id) = stable_id_at_offset(source, offset)? else {
///     panic!("there is a function here")
/// };
/// assert!(id.as_str().starts_with("v1:"));
///
/// // The same ID resolves back to where it came from.
/// let Some(range) = locate_stable_id(source, &id)? else {
///     panic!("the ID came from this source")
/// };
/// assert_eq!(&source[range.start as usize..range.end as usize], "main");
/// # Ok::<(), Box<dyn std::error::Error>>(())
/// ```
#[derive(Debug, Clone, PartialEq, Eq, Hash, Deserialize)]
#[serde(transparent)]
pub struct StableId(String);

impl StableId {
    /// Wrap a string the library produced earlier.
    ///
    /// Any string is accepted: whether it names a symbol is a question for
    /// [`locate_stable_id`], which answers `Ok(None)` when it does not.
    ///
    /// # Examples
    ///
    /// ```
    /// use wgslender_core::refactor::{StableId, locate_stable_id};
    ///
    /// let source = "@compute @workgroup_size(1)\nfn main() {}\n";
    /// let stored = StableId::new("v1:fn:main");
    /// assert!(locate_stable_id(source, &stored)?.is_some());
    ///
    /// // Accepted, and then not found — the two are different questions.
    /// let nonsense = StableId::new("not an id at all");
    /// assert!(locate_stable_id(source, &nonsense)?.is_none());
    /// # Ok::<(), wgslender_core::Error>(())
    /// ```
    pub fn new(id: impl Into<String>) -> Self {
        Self(id.into())
    }

    /// The ID as the library spells it.
    ///
    /// # Examples
    ///
    /// ```
    /// use wgslender_core::refactor::StableId;
    ///
    /// let id = StableId::new("v1:var:params");
    /// assert_eq!(id.as_str(), "v1:var:params");
    /// assert_eq!(id.to_string(), id.as_str(), "Display spells it the same way");
    /// ```
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for StableId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl AsRef<str> for StableId {
    fn as_ref(&self) -> &str {
        &self.0
    }
}

impl FromStr for StableId {
    /// Parsing cannot fail — an ID is opaque, so there is no syntax to reject.
    type Err = core::convert::Infallible;

    fn from_str(id: &str) -> Result<Self, Self::Err> {
        Ok(Self::new(id))
    }
}

/// A half-open range of UTF-8 byte offsets, `source[start..end]`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ByteRange {
    /// First byte of the range.
    pub start: u32,
    /// One past the last byte.
    pub end: u32,
}

/// A replacement of `source[start..end]` with `new_text`.
///
/// Edits within one result never overlap, and are ordered by `start`. Apply
/// them back to front if you are splicing them into a buffer yourself, or let
/// the `_apply` form of the call do it.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct Edit {
    /// First byte replaced.
    pub start: u32,
    /// One past the last byte replaced.
    pub end: u32,
    /// What goes in its place; empty for a deletion.
    pub new_text: String,
}

/// One mention of a symbol.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct Reference {
    /// First byte of the name.
    pub start: u32,
    /// One past the last byte of the name.
    pub end: u32,
    /// Whether this mention writes the symbol rather than reading it. A
    /// declaration counts as a write.
    pub is_write: bool,
}

/// A rewritten source, and the edits that produced it.
#[derive(Debug, Clone)]
#[non_exhaustive]
pub struct Applied {
    /// The source with every edit applied.
    pub source: String,
    /// The edits that were applied, against the *original* offsets.
    pub edits: Vec<Edit>,
}

/// Whether [`find_references`] counts the declaration as a reference.
///
/// A named pair rather than a `bool`, so that call sites read as what they ask
/// for instead of as `true`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IncludeDeclaration {
    /// Count the declaration.
    Yes,
    /// Report only the uses.
    No,
}

impl IncludeDeclaration {
    /// The `0`/`1` the C ABI takes.
    fn as_flag(self) -> u32 {
        match self {
            Self::Yes => 1,
            Self::No => 0,
        }
    }
}

/// Why a refactor could not be performed.
///
/// These are failures to answer, not findings about the shader: unlike
/// [`validate`](crate::validate), which reports a broken shader as a successful
/// analysis, there is no edit list that usefully means "you asked for something
/// impossible".
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[non_exhaustive]
pub enum RefactorError {
    /// The new name is not a WGSL identifier — a keyword, or not an identifier
    /// at all.
    #[error("invalid identifier")]
    InvalidIdentifier,

    /// Nothing is declared at that offset, or under that ID.
    #[error("symbol not found")]
    SymbolNotFound,

    /// The source could not be parsed far enough to work on.
    #[error("parse error")]
    ParseError,

    /// The symbol carries no type annotation to replace, or the replacement was
    /// empty. See [`change_type`] for what is *not* checked.
    #[error("no type annotation or invalid replacement")]
    NoTypeAnnotation,

    /// The symbol exists but is not something a declaration can be removed for.
    #[error("not a removable declaration")]
    NotRemovable,

    /// The symbol's stable ID would exceed the library's length limit.
    #[error("stable ID too long")]
    IdTooLong,

    /// A reason this version of the crate does not know by name.
    #[error("{0}")]
    Other(String),
}

impl RefactorError {
    /// The library's own wording for the failure.
    ///
    /// Unknown strings become [`Other`](RefactorError::Other) rather than an
    /// error, so a library that grows a new reason does not break this one.
    fn from_wire(text: &str) -> Self {
        match text {
            "invalid identifier" => Self::InvalidIdentifier,
            "symbol not found" => Self::SymbolNotFound,
            "parse error" => Self::ParseError,
            "no type annotation or invalid replacement" => Self::NoTypeAnnotation,
            "not a removable declaration" => Self::NotRemovable,
            "id too long" => Self::IdTooLong,
            other => Self::Other(other.to_owned()),
        }
    }
}

/// The wire's word for "the question was answerable and the answer is no",
/// which the locate family reports in the same field it reports failures in.
const NOT_FOUND: &str = "not found";

/// `{"edits":[...][,"error":"..."]}`
#[derive(Deserialize)]
struct EditsEnvelope {
    edits: Vec<Edit>,
    #[serde(default)]
    error: Option<String>,
}

impl EditsEnvelope {
    fn into_edits(self) -> Result<Vec<Edit>, Error> {
        match self.error {
            Some(error) => Err(Error::Refactor(RefactorError::from_wire(&error))),
            None => Ok(self.edits),
        }
    }
}

/// `{"ok":bool,"source":"...","edits":[...][,"error":"..."]}`
///
/// The failure form carries the *original* source back, which the caller
/// already holds, so only the reason survives into the `Err`.
#[derive(Deserialize)]
struct AppliedEnvelope {
    ok: bool,
    source: String,
    edits: Vec<Edit>,
    #[serde(default)]
    error: Option<String>,
}

impl AppliedEnvelope {
    fn into_applied(self) -> Result<Applied, Error> {
        if self.ok {
            return Ok(Applied {
                source: self.source,
                edits: self.edits,
            });
        }
        let reason = self.error.as_deref().unwrap_or_default();
        Err(Error::Refactor(RefactorError::from_wire(reason)))
    }
}

/// `{"references":[...][,"error":"..."]}`
#[derive(Deserialize)]
struct ReferencesEnvelope {
    references: Vec<Reference>,
    #[serde(default)]
    error: Option<String>,
}

/// `{"start":N,"end":N}` or `{"start":null,"end":null,"error":"..."}`
#[derive(Deserialize)]
struct RangeEnvelope {
    start: Option<u32>,
    end: Option<u32>,
    #[serde(default)]
    error: Option<String>,
}

impl RangeEnvelope {
    fn into_range(self) -> Result<Option<ByteRange>, Error> {
        if let (Some(start), Some(end)) = (self.start, self.end) {
            return Ok(Some(ByteRange { start, end }));
        }
        match self.error.as_deref() {
            // Distinguished by name rather than by the null range, so that a
            // real failure cannot be mistaken for an absence.
            None | Some(NOT_FOUND) => Ok(None),
            Some(error) => Err(Error::Refactor(RefactorError::from_wire(error))),
        }
    }
}

/// `{"stableId":"..."} `or `{"stableId":null[,"error":"..."]}`
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StableIdEnvelope {
    stable_id: Option<StableId>,
    #[serde(default)]
    error: Option<String>,
}

impl StableIdEnvelope {
    fn into_id(self) -> Result<Option<StableId>, Error> {
        match (self.stable_id, self.error) {
            (Some(id), _) => Ok(Some(id)),
            // Unlike the locate family, absence here is a bare null with no
            // error beside it.
            (None, None) => Ok(None),
            (None, Some(error)) => Err(Error::Refactor(RefactorError::from_wire(&error))),
        }
    }
}

/// Parse a refactor result, releasing the library's buffer either way.
///
/// # Safety
///
/// `result` must be a freshly returned `WgslenderJsonResult` whose buffer has
/// not been adopted anywhere else.
unsafe fn take<T: serde::de::DeserializeOwned>(result: WgslenderJsonResult) -> Result<T, Error> {
    // SAFETY: forwarded verbatim from this function's own contract.
    unsafe { take_json(result.json_ptr, result.json_len) }
}

/// Every mention of the symbol at `offset`.
///
/// An offset that names no symbol is not an error here — it is an empty result.
/// That makes this the one call in the module a cursor can be pointed at
/// blindly, which is what an editor highlighting the word under the caret
/// needs.
///
/// # Errors
///
/// [`Error::SourceTooLarge`] if the source does not fit in a `u32`;
/// [`Error::Internal`] if the library could not allocate; [`Error::Wire`] if
/// the payload is not the JSON this crate expects; [`Error::Refactor`] if the
/// library reported a reason it could not answer.
///
/// # Examples
///
/// ```
/// use wgslender_core::refactor::{IncludeDeclaration, find_references};
///
/// let source = "fn helper() {}\n@compute @workgroup_size(1)\nfn main() { helper(); }\n";
/// let offset = u32::try_from(source.find("helper").unwrap_or_default())?;
///
/// let with = find_references(source, offset, IncludeDeclaration::Yes)?;
/// let without = find_references(source, offset, IncludeDeclaration::No)?;
/// assert_eq!(with.len(), 2);
/// assert_eq!(without.len(), 1);
/// assert!(with[0].is_write, "the declaration writes the name");
/// # Ok::<(), Box<dyn std::error::Error>>(())
/// ```
pub fn find_references(
    source: &str,
    offset: u32,
    declaration: IncludeDeclaration,
) -> Result<Vec<Reference>, Error> {
    let source_len = checked_len(source)?;
    // SAFETY: `source` is valid for reads of `source_len` bytes for the whole
    // call, which is the function's only precondition.
    let result = unsafe {
        wgslender_find_references_c(source.as_ptr(), source_len, offset, declaration.as_flag())
    };
    // SAFETY: the result was just returned and is adopted exactly once.
    let envelope: ReferencesEnvelope = unsafe { take(result) }?;
    match envelope.error {
        Some(error) => Err(Error::Refactor(RefactorError::from_wire(&error))),
        None => Ok(envelope.references),
    }
}

/// The edits that rename the symbol at `offset` to `new_name`.
///
/// # Errors
///
/// [`Error::Refactor`] with [`RefactorError::InvalidIdentifier`] if `new_name`
/// is not a WGSL identifier, or [`RefactorError::SymbolNotFound`] if nothing is
/// declared at `offset`. Also the transport errors listed on
/// [`find_references`].
///
/// # Examples
///
/// ```
/// use wgslender_core::refactor::rename;
///
/// let source = "fn helper() {}\n@compute @workgroup_size(1)\nfn main() { helper(); }\n";
/// let offset = u32::try_from(source.find("helper").unwrap_or_default())?;
///
/// let edits = rename(source, offset, "shade")?;
/// assert_eq!(edits.len(), 2, "the declaration and the call");
/// assert!(edits.iter().all(|edit| edit.new_text == "shade"));
/// # Ok::<(), Box<dyn std::error::Error>>(())
/// ```
pub fn rename(source: &str, offset: u32, new_name: &str) -> Result<Vec<Edit>, Error> {
    let source_len = checked_len(source)?;
    let name_len = checked_len(new_name)?;
    // SAFETY: `source` and `new_name` are each valid for reads of their own
    // length for the whole call, and the library only reads through them.
    let result = unsafe {
        wgslender_rename_c(
            source.as_ptr(),
            source_len,
            offset,
            new_name.as_ptr(),
            name_len,
        )
    };
    // SAFETY: the result was just returned and is adopted exactly once.
    let envelope: EditsEnvelope = unsafe { take(result) }?;
    envelope.into_edits()
}

/// Rename the symbol at `offset` and return the rewritten source.
///
/// # Errors
///
/// The same as [`rename`].
///
/// # Examples
///
/// ```
/// use wgslender_core::refactor::rename_apply;
///
/// let source = "fn helper() {}\n@compute @workgroup_size(1)\nfn main() { helper(); }\n";
/// let offset = u32::try_from(source.find("helper").unwrap_or_default())?;
///
/// let applied = rename_apply(source, offset, "shade")?;
/// assert!(applied.source.contains("fn shade()"));
/// assert!(applied.source.contains("shade();"));
/// # Ok::<(), Box<dyn std::error::Error>>(())
/// ```
pub fn rename_apply(source: &str, offset: u32, new_name: &str) -> Result<Applied, Error> {
    let source_len = checked_len(source)?;
    let name_len = checked_len(new_name)?;
    // SAFETY: `source` and `new_name` are each valid for reads of their own
    // length for the whole call, and the library only reads through them.
    let result = unsafe {
        wgslender_rename_apply_c(
            source.as_ptr(),
            source_len,
            offset,
            new_name.as_ptr(),
            name_len,
        )
    };
    // SAFETY: the result was just returned and is adopted exactly once.
    let envelope: AppliedEnvelope = unsafe { take(result) }?;
    envelope.into_applied()
}

/// The stable ID of the symbol at `offset`, if there is one.
///
/// `Ok(None)` means the offset lands on whitespace, a comment, a keyword or
/// anything else that is not a symbol — a question with an answer, not a
/// failure. Struct fields have no ID of their own.
///
/// # Errors
///
/// The transport errors listed on [`find_references`], plus
/// [`RefactorError::IdTooLong`] for a symbol nested past the library's limit.
///
/// # Examples
///
/// ```
/// use wgslender_core::refactor::stable_id_at_offset;
///
/// let source = "@compute @workgroup_size(1)\nfn main() { let x = 1.0; }\n";
/// let offset = u32::try_from(source.find("main").unwrap_or_default())?;
///
/// let id = stable_id_at_offset(source, offset)?;
/// assert_eq!(id.map(|id| id.to_string()), Some("v1:fn:main".to_owned()));
/// assert_eq!(stable_id_at_offset(source, 0)?, None, "an attribute is not a symbol");
/// # Ok::<(), Box<dyn std::error::Error>>(())
/// ```
pub fn stable_id_at_offset(source: &str, offset: u32) -> Result<Option<StableId>, Error> {
    let source_len = checked_len(source)?;
    // SAFETY: `source` is valid for reads of `source_len` bytes for the whole
    // call, which is the function's only precondition.
    let result = unsafe { wgslender_stable_id_at_offset_c(source.as_ptr(), source_len, offset) };
    // SAFETY: the result was just returned and is adopted exactly once.
    let envelope: StableIdEnvelope = unsafe { take(result) }?;
    envelope.into_id()
}

/// Where the symbol's *name* is written, if this source still declares it.
///
/// `Ok(None)` for an ID this source does not contain — after a large enough
/// edit, or against a different file.
///
/// # Errors
///
/// The transport errors listed on [`find_references`].
///
/// # Examples
///
/// ```
/// use wgslender_core::refactor::{StableId, locate_stable_id};
///
/// let source = "@compute @workgroup_size(1)\nfn main() {}\n";
/// let Some(range) = locate_stable_id(source, &StableId::new("v1:fn:main"))? else {
///     panic!("this source declares main")
/// };
/// assert_eq!(&source[range.start as usize..range.end as usize], "main");
///
/// let absent = StableId::new("v1:fn:nowhere");
/// assert_eq!(locate_stable_id(source, &absent)?, None);
/// # Ok::<(), Box<dyn std::error::Error>>(())
/// ```
pub fn locate_stable_id(source: &str, id: &StableId) -> Result<Option<ByteRange>, Error> {
    locate_with(wgslender_locate_stable_id_c, source, id)
}

/// Where the symbol's whole declaration is written, name and body included.
///
/// # Errors
///
/// The transport errors listed on [`find_references`].
///
/// # Examples
///
/// ```
/// use wgslender_core::refactor::{StableId, locate_declaration};
///
/// let source = "fn helper() -> f32 { return 1.0; }\n";
/// let Some(range) = locate_declaration(source, &StableId::new("v1:fn:helper"))? else {
///     panic!("this source declares helper")
/// };
/// let text = &source[range.start as usize..range.end as usize];
/// assert!(text.starts_with("fn helper()") && text.ends_with('}'));
/// # Ok::<(), Box<dyn std::error::Error>>(())
/// ```
pub fn locate_declaration(source: &str, id: &StableId) -> Result<Option<ByteRange>, Error> {
    locate_with(wgslender_locate_declaration_c, source, id)
}

/// Where the symbol's type annotation is written.
///
/// For a function that is the return type. `Ok(None)` when the symbol has no
/// annotation to point at — an inferred `let`, or a function returning nothing.
///
/// # Errors
///
/// The transport errors listed on [`find_references`].
///
/// # Examples
///
/// ```
/// use wgslender_core::refactor::{StableId, locate_type};
///
/// let source = "fn helper() -> f32 { return 1.0; }\n";
/// let Some(range) = locate_type(source, &StableId::new("v1:fn:helper"))? else {
///     panic!("helper returns f32")
/// };
/// assert_eq!(&source[range.start as usize..range.end as usize], "f32");
/// # Ok::<(), Box<dyn std::error::Error>>(())
/// ```
pub fn locate_type(source: &str, id: &StableId) -> Result<Option<ByteRange>, Error> {
    locate_with(wgslender_locate_type_c, source, id)
}

/// The three locate calls differ only in which C entry point they ask.
fn locate_with(
    locate: unsafe extern "C" fn(*const u8, u32, *const u8, u32) -> WgslenderJsonResult,
    source: &str,
    id: &StableId,
) -> Result<Option<ByteRange>, Error> {
    let source_len = checked_len(source)?;
    let id_len = checked_len(id.as_str())?;
    // SAFETY: `source` and the ID are each valid for reads of their own length
    // for the whole call, and the library only reads through them.
    let result = unsafe { locate(source.as_ptr(), source_len, id.as_str().as_ptr(), id_len) };
    // SAFETY: the result was just returned and is adopted exactly once.
    let envelope: RangeEnvelope = unsafe { take(result) }?;
    envelope.into_range()
}

/// The edits that rename the symbol `id` names to `new_name`.
///
/// The by-ID counterpart of [`rename`], and the one to use when the offset you
/// started from may have moved.
///
/// # Errors
///
/// The same as [`rename`].
///
/// # Examples
///
/// ```
/// use wgslender_core::refactor::{StableId, rename_by_id};
///
/// let source = "fn helper() {}\n@compute @workgroup_size(1)\nfn main() { helper(); }\n";
/// let edits = rename_by_id(source, &StableId::new("v1:fn:helper"), "shade")?;
/// assert_eq!(edits.len(), 2);
/// # Ok::<(), Box<dyn std::error::Error>>(())
/// ```
pub fn rename_by_id(source: &str, id: &StableId, new_name: &str) -> Result<Vec<Edit>, Error> {
    let source_len = checked_len(source)?;
    let id_len = checked_len(id.as_str())?;
    let name_len = checked_len(new_name)?;
    // SAFETY: source, ID and new name are each valid for reads of their own
    // length for the whole call, and the library only reads through them.
    let result = unsafe {
        wgslender_rename_by_id_c(
            source.as_ptr(),
            source_len,
            id.as_str().as_ptr(),
            id_len,
            new_name.as_ptr(),
            name_len,
        )
    };
    // SAFETY: the result was just returned and is adopted exactly once.
    let envelope: EditsEnvelope = unsafe { take(result) }?;
    envelope.into_edits()
}

/// The edit that deletes the declaration `id` names.
///
/// Only the declaration: every call to it stays where it was, so a source that
/// used the symbol stops validating. Removing a symbol safely means checking
/// [`find_references`] first, or [`validate`](crate::validate) after.
///
/// # Errors
///
/// [`Error::Refactor`] with [`RefactorError::SymbolNotFound`] if nothing is
/// declared under `id`, or [`RefactorError::NotRemovable`] if it is not a
/// declaration that can be deleted. Also the transport errors listed on
/// [`find_references`].
///
/// # Examples
///
/// ```
/// use wgslender_core::refactor::{StableId, remove_declaration};
///
/// let source = "fn unused() {}\n@compute @workgroup_size(1)\nfn main() {}\n";
/// let edits = remove_declaration(source, &StableId::new("v1:fn:unused"))?;
/// assert_eq!(edits.len(), 1);
/// assert!(edits[0].new_text.is_empty(), "a removal inserts nothing");
/// # Ok::<(), Box<dyn std::error::Error>>(())
/// ```
pub fn remove_declaration(source: &str, id: &StableId) -> Result<Vec<Edit>, Error> {
    let source_len = checked_len(source)?;
    let id_len = checked_len(id.as_str())?;
    // SAFETY: `source` and the ID are each valid for reads of their own length
    // for the whole call, and the library only reads through them.
    let result = unsafe {
        wgslender_remove_declaration_by_id_c(
            source.as_ptr(),
            source_len,
            id.as_str().as_ptr(),
            id_len,
        )
    };
    // SAFETY: the result was just returned and is adopted exactly once.
    let envelope: EditsEnvelope = unsafe { take(result) }?;
    envelope.into_edits()
}

/// Delete the declaration `id` names and return the rewritten source.
///
/// Carries the same caveat as [`remove_declaration`]: call sites are left
/// behind.
///
/// # Errors
///
/// The same as [`remove_declaration`].
///
/// # Examples
///
/// ```
/// use wgslender_core::refactor::{StableId, remove_declaration_apply};
///
/// let source = "fn unused() {}\n@compute @workgroup_size(1)\nfn main() {}\n";
/// let applied = remove_declaration_apply(source, &StableId::new("v1:fn:unused"))?;
/// assert!(!applied.source.contains("unused"));
/// assert!(applied.source.contains("fn main()"));
/// # Ok::<(), Box<dyn std::error::Error>>(())
/// ```
pub fn remove_declaration_apply(source: &str, id: &StableId) -> Result<Applied, Error> {
    let source_len = checked_len(source)?;
    let id_len = checked_len(id.as_str())?;
    // SAFETY: `source` and the ID are each valid for reads of their own length
    // for the whole call, and the library only reads through them.
    let result = unsafe {
        wgslender_remove_declaration_apply_by_id_c(
            source.as_ptr(),
            source_len,
            id.as_str().as_ptr(),
            id_len,
        )
    };
    // SAFETY: the result was just returned and is adopted exactly once.
    let envelope: AppliedEnvelope = unsafe { take(result) }?;
    envelope.into_applied()
}

/// The edit that replaces the type annotation of the symbol `id` names.
///
/// `new_type` is spliced in verbatim: the library checks that there is an
/// annotation to replace and that the replacement is not empty, and nothing
/// else. `"not a type"` produces an edit as readily as `"vec2f"` does, so
/// [`validate`](crate::validate) the result if it came from anywhere but your
/// own code.
///
/// # Errors
///
/// [`Error::Refactor`] with [`RefactorError::NoTypeAnnotation`] if the symbol
/// has no annotation or `new_type` is empty, or
/// [`RefactorError::SymbolNotFound`] if nothing is declared under `id`. Also
/// the transport errors listed on [`find_references`].
///
/// # Examples
///
/// ```
/// use wgslender_core::refactor::{StableId, change_type};
///
/// let source = "fn helper() -> f32 { return 1.0; }\n";
/// let edits = change_type(source, &StableId::new("v1:fn:helper"), "f16")?;
/// assert_eq!(edits.len(), 1);
/// assert_eq!(edits[0].new_text, "f16");
/// # Ok::<(), Box<dyn std::error::Error>>(())
/// ```
pub fn change_type(source: &str, id: &StableId, new_type: &str) -> Result<Vec<Edit>, Error> {
    let source_len = checked_len(source)?;
    let id_len = checked_len(id.as_str())?;
    let type_len = checked_len(new_type)?;
    // SAFETY: source, ID and new type are each valid for reads of their own
    // length for the whole call, and the library only reads through them.
    let result = unsafe {
        wgslender_change_type_by_id_c(
            source.as_ptr(),
            source_len,
            id.as_str().as_ptr(),
            id_len,
            new_type.as_ptr(),
            type_len,
        )
    };
    // SAFETY: the result was just returned and is adopted exactly once.
    let envelope: EditsEnvelope = unsafe { take(result) }?;
    envelope.into_edits()
}

/// Replace the type annotation of the symbol `id` names, returning the
/// rewritten source.
///
/// Carries the same caveat as [`change_type`]: the replacement is not checked.
///
/// # Errors
///
/// The same as [`change_type`].
///
/// # Examples
///
/// ```
/// use wgslender_core::refactor::{StableId, change_type_apply};
///
/// let source = "fn helper() -> f32 { return 1.0; }\n";
/// let applied = change_type_apply(source, &StableId::new("v1:fn:helper"), "f16")?;
/// assert!(applied.source.starts_with("fn helper() -> f16"));
/// # Ok::<(), Box<dyn std::error::Error>>(())
/// ```
pub fn change_type_apply(source: &str, id: &StableId, new_type: &str) -> Result<Applied, Error> {
    let source_len = checked_len(source)?;
    let id_len = checked_len(id.as_str())?;
    let type_len = checked_len(new_type)?;
    // SAFETY: source, ID and new type are each valid for reads of their own
    // length for the whole call, and the library only reads through them.
    let result = unsafe {
        wgslender_change_type_apply_by_id_c(
            source.as_ptr(),
            source_len,
            id.as_str().as_ptr(),
            id_len,
            new_type.as_ptr(),
            type_len,
        )
    };
    // SAFETY: the result was just returned and is adopted exactly once.
    let envelope: AppliedEnvelope = unsafe { take(result) }?;
    envelope.into_applied()
}

#[cfg(test)]
mod tests {
    use super::{RefactorError, StableId};

    /// The wire strings, every one of them, mapped by hand. Two of these
    /// (`not a removable declaration`, `id too long`) are branches in the
    /// library that the integration tests cannot provoke, so this table is the
    /// only thing holding them.
    #[test]
    fn every_wire_reason_maps_to_its_variant() {
        let cases = [
            ("invalid identifier", RefactorError::InvalidIdentifier),
            ("symbol not found", RefactorError::SymbolNotFound),
            ("parse error", RefactorError::ParseError),
            (
                "no type annotation or invalid replacement",
                RefactorError::NoTypeAnnotation,
            ),
            ("not a removable declaration", RefactorError::NotRemovable),
            ("id too long", RefactorError::IdTooLong),
        ];
        for (wire, expected) in cases {
            assert_eq!(RefactorError::from_wire(wire), expected, "{wire:?}");
        }
    }

    /// A reason from a newer library must not be dropped, and must not panic.
    #[test]
    fn an_unrecognised_reason_is_carried_through() {
        let error = RefactorError::from_wire("something new");
        assert_eq!(error, RefactorError::Other("something new".to_owned()));
        assert_eq!(error.to_string(), "something new");
    }

    /// An ID is opaque, so every string is an acceptable one to hand back.
    #[test]
    fn a_stable_id_round_trips_through_its_string() {
        let id: StableId = match "v1:fn:main/block#0/let:x".parse() {
            Ok(id) => id,
            Err(never) => match never {},
        };
        assert_eq!(id.as_str(), "v1:fn:main/block#0/let:x");
        assert_eq!(id.to_string(), id.as_str());
        assert_eq!(StableId::new(id.as_str()), id);
    }
}
