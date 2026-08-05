//! Semantic validation, and the diagnostic types the linter shares with it.

use core::fmt;

use serde::{Deserialize, Deserializer};
use wgslender_sys::{WGSLENDER_OPT_STRICT, wgslender_validate_c};

use crate::buffer::{checked_len, take_json};
use crate::error::Error;

/// How serious a [`Diagnostic`] is.
///
/// `Unknown` catches severities added to the library after this crate was
/// built, so a newer libwgslender cannot turn a diagnostic into a parse
/// failure.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum Severity {
    /// The shader is rejected.
    Error,
    /// Legal, but almost certainly not what the author meant.
    Warning,
    /// Neutral commentary.
    Info,
    /// Extra context attached to another diagnostic.
    Note,
    /// A suggestion an editor can act on.
    Hint,
    /// A severity this crate does not know about.
    Unknown,
}

impl Severity {
    /// The wire spelling, or `"unknown"`.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Error => "error",
            Self::Warning => "warning",
            Self::Info => "info",
            Self::Note => "note",
            Self::Hint => "hint",
            Self::Unknown => "unknown",
        }
    }
}

impl fmt::Display for Severity {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

// Hand-written rather than derived: serde's `#[serde(other)]` catch-all is
// only available to internally and adjacently tagged enums, and this one is
// deserialized from a bare string.
impl<'de> Deserialize<'de> for Severity {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct Visitor;

        impl serde::de::Visitor<'_> for Visitor {
            type Value = Severity;

            fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str("a diagnostic severity")
            }

            fn visit_str<E: serde::de::Error>(self, value: &str) -> Result<Severity, E> {
                Ok(match value {
                    "error" => Severity::Error,
                    "warning" => Severity::Warning,
                    "info" => Severity::Info,
                    "note" => Severity::Note,
                    "hint" => Severity::Hint,
                    _ => Severity::Unknown,
                })
            }
        }

        deserializer.deserialize_str(Visitor)
    }
}

/// One thing the library has to say about a shader.
///
/// Positions are 1-based, matching what every editor and compiler prints.
#[derive(Debug, Clone, Deserialize)]
#[non_exhaustive]
pub struct Diagnostic {
    /// How serious it is.
    pub severity: Severity,
    /// Human-readable text, without a position prefix.
    pub message: String,
    /// The stable code, such as `E0100` or `W0201`. Parse errors often have
    /// none.
    #[serde(default)]
    pub code: Option<String>,
    /// 1-based line of the first offending byte.
    pub line: u32,
    /// 1-based column of the first offending byte.
    pub column: u32,
}

/// What [`validate`] found.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct Validation {
    /// Whether the shader is accepted. False whenever `error_count` is
    /// non-zero.
    pub valid: bool,
    /// Number of error-severity diagnostics.
    pub error_count: u32,
    /// Number of warning-severity diagnostics.
    pub warning_count: u32,
    /// Every diagnostic, in source order.
    pub diagnostics: Vec<Diagnostic>,
}

/// Whether warnings are tolerated.
///
/// A named choice rather than a `bool` argument, so the call site says which
/// mode it means.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Strictness {
    /// Warnings stay warnings, and a shader with only warnings is valid.
    Default,
    /// Every warning becomes an error, so any diagnostic at all rejects the
    /// shader.
    Strict,
}

impl Strictness {
    /// The C ABI flag word for this mode.
    fn flags(self) -> u32 {
        match self {
            Self::Default => 0,
            Self::Strict => WGSLENDER_OPT_STRICT,
        }
    }
}

/// Type-check a WGSL shader.
///
/// A shader that fails validation is **not** a Rust `Err`: it comes back as
/// `Ok` with `valid == false` and the diagnostics that explain why. The error
/// type is reserved for the FFI call itself going wrong.
///
/// # Errors
///
/// [`Error::SourceTooLarge`] if the source does not fit in a `u32`;
/// [`Error::Internal`] if the library could not allocate its report;
/// [`Error::Wire`] if the report is not the JSON this crate expects.
///
/// # Examples
///
/// ```
/// use wgslender_core::{Severity, Strictness, validate};
///
/// let report = validate("fn main() { return missing; }", Strictness::Default)?;
/// assert!(!report.valid);
/// assert_eq!(report.diagnostics[0].severity, Severity::Error);
/// # Ok::<(), wgslender_core::Error>(())
/// ```
///
/// Strict mode rejects a shader that only has warnings:
///
/// ```
/// use wgslender_core::{Strictness, validate};
///
/// let source = "@compute @workgroup_size(1)\nfn main() { return; let x = 1u; }";
/// assert!(validate(source, Strictness::Default)?.valid);
/// assert!(!validate(source, Strictness::Strict)?.valid);
/// # Ok::<(), wgslender_core::Error>(())
/// ```
pub fn validate(source: &str, strictness: Strictness) -> Result<Validation, Error> {
    let source_len = checked_len(source)?;
    // SAFETY: `source` is valid for reads of `source_len` bytes for the whole
    // call, and the library only reads through the pointer.
    let result = unsafe { wgslender_validate_c(source.as_ptr(), source_len, strictness.flags()) };
    // SAFETY: `json_ptr`/`json_len` are the pair the call just returned, and
    // this is the first and only adoption of them.
    unsafe { take_json(result.json_ptr, result.json_len) }
}

#[cfg(test)]
mod tests {
    use super::Severity;

    #[test]
    fn known_severities_round_trip() {
        for (wire, expected) in [
            ("error", Severity::Error),
            ("warning", Severity::Warning),
            ("info", Severity::Info),
            ("note", Severity::Note),
            ("hint", Severity::Hint),
        ] {
            let json = format!("\"{wire}\"");
            let parsed: Severity = match serde_json::from_str(&json) {
                Ok(parsed) => parsed,
                Err(err) => panic!("{wire} did not parse: {err}"),
            };
            assert_eq!(parsed, expected);
            assert_eq!(parsed.as_str(), wire);
        }
    }

    #[test]
    fn an_unrecognised_severity_does_not_fail_the_parse() {
        let parsed: Severity = match serde_json::from_str("\"catastrophe\"") {
            Ok(parsed) => parsed,
            Err(err) => panic!("a new severity must not break deserialization: {err}"),
        };
        assert_eq!(parsed, Severity::Unknown);
    }
}
