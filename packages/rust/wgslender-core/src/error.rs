//! The crate's error type.

/// Everything a wgslender call can fail with.
///
/// The enum is `#[non_exhaustive]`: later releases add variants for the
/// operations this one does not cover yet, and that must not be a breaking
/// change.
#[derive(Debug, thiserror::Error)]
#[non_exhaustive]
pub enum Error {
    /// The library returned no result and no explanation.
    ///
    /// In practice this means an allocation failed inside libwgslender: the C
    /// ABI reports every other failure as diagnostics, not as a missing buffer.
    #[error("wgslender internal error")]
    Internal,

    /// A buffer the library returned was not valid UTF-8.
    #[error("library returned invalid UTF-8")]
    InvalidUtf8(#[from] core::str::Utf8Error),

    /// A JSON payload did not have the shape this version of the crate expects.
    #[error("unexpected wire format: {0}")]
    Wire(#[from] serde_json::Error),

    /// The input is longer than the C ABI's `u32` length fields can describe.
    #[error("source exceeds u32 length limit ({0} bytes)")]
    SourceTooLarge(usize),
}
