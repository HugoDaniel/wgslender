//! Shader text stored DEFLATE-compressed, inflated on first use.
//!
//! Both halves of the format live in this file — [`CompressedWgsl::__deflate`]
//! writes it, [`CompressedWgsl::as_str`] reads it back — because a writer and a
//! reader in different crates can drift apart about a format, and these two
//! cannot. The writer's only caller is `include_wgsl_compressed!`, which runs
//! it while the embedding crate is compiled.

use std::fmt;
use std::sync::OnceLock;

/// The DEFLATE level the writer uses: `miniz_oxide`'s maximum.
///
/// A shader is compressed once, while the crate embedding it is built, and
/// inflated at most once per process — there is nothing on the other side of
/// the trade to spend a worse ratio on.
const LEVEL: u8 = 10;

/// Minified WGSL kept compressed in the binary, inflated lazily and once.
///
/// Built by `include_wgsl_compressed!`, which deflates the shader at compile
/// time; the constructor is `const`, so the result is normally a `static`. The
/// text costs nothing until something asks for it, and asking twice inflates
/// once.
///
/// # Examples
///
/// ```
/// # use wgslender_core::CompressedWgsl;
/// // What the macro writes out, spelled by hand: an empty deflate stream.
/// static SHADER: CompressedWgsl = CompressedWgsl::__from_parts(&[0x03, 0x00], 0);
///
/// assert!(SHADER.is_empty());
/// assert_eq!(SHADER.as_str(), "");
/// ```
pub struct CompressedWgsl {
    /// The deflate stream, which in a real embedding is a literal in the binary.
    deflate: &'static [u8],
    /// What it inflates to, so [`CompressedWgsl::len`] can answer without
    /// inflating — and so inflation can check it got what it was promised.
    text_len: u32,
    /// The text, once anything has asked for it.
    cache: OnceLock<String>,
}

impl CompressedWgsl {
    /// Compresses shader text the way the reader below expects to find it.
    ///
    /// Hidden because it is half of a private protocol between this type and
    /// the macro that builds one: it is public only because the macro's
    /// expansion is compiled in someone else's crate.
    #[doc(hidden)]
    #[must_use]
    pub fn __deflate(text: &str) -> Vec<u8> {
        miniz_oxide::deflate::compress_to_vec(text.as_bytes(), LEVEL)
    }

    /// Rebuilds a shader from the two things [`Self::__deflate`] leaves behind:
    /// the stream, and the length it inflates to.
    ///
    /// Hidden for the same reason, and `const` because an embedded shader is a
    /// `static`.
    #[doc(hidden)]
    #[must_use]
    pub const fn __from_parts(deflate: &'static [u8], text_len: u32) -> Self {
        Self {
            deflate,
            text_len,
            cache: OnceLock::new(),
        }
    }

    /// The shader text, inflating it if this is the first time anyone asked.
    ///
    /// # Panics
    ///
    /// If the stored bytes are not a deflate stream of exactly `text_len` bytes
    /// of UTF-8. Both halves of that are written by the same macro invocation
    /// that stored them, so it cannot happen to data this crate produced — it
    /// would mean the binary itself is damaged.
    #[must_use]
    pub fn as_str(&self) -> &str {
        self.cache.get_or_init(|| self.inflate()).as_str()
    }

    /// How many bytes the shader is, without inflating it.
    #[must_use]
    pub fn len(&self) -> usize {
        self.text_len as usize
    }

    /// Whether the shader is empty, without inflating it.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.text_len == 0
    }

    /// How many bytes it occupies compressed — what embedding it actually cost.
    #[must_use]
    pub fn compressed_len(&self) -> usize {
        self.deflate.len()
    }

    /// The stream, checked against the length that came with it.
    fn inflate(&self) -> String {
        let limit = self.len();
        let inflated = miniz_oxide::inflate::decompress_to_vec_with_limit(self.deflate, limit);
        let Ok(bytes) = inflated else {
            panic!(
                "the embedded shader is not a deflate stream of {limit} bytes; \
                 the binary that carries it is damaged"
            )
        };
        assert!(
            bytes.len() == limit,
            "the embedded shader inflated to {} bytes, not the {limit} it was \
             stored as; the binary that carries it is damaged",
            bytes.len(),
        );
        match String::from_utf8(bytes) {
            Ok(text) => text,
            Err(err) => panic!(
                "the embedded shader did not inflate to UTF-8 ({}); the binary \
                 that carries it is damaged",
                err.utf8_error(),
            ),
        }
    }
}

/// Sizes and whether the text has been inflated yet — never the shader itself,
/// which is both large and, at the moment of asking, possibly not there.
///
/// The elided fields are the two the sizes are derived from, so
/// `finish_non_exhaustive` here is a summary rather than an omission.
impl fmt::Debug for CompressedWgsl {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CompressedWgsl")
            .field("compressed_len", &self.compressed_len())
            .field("len", &self.len())
            .field("inflated", &self.cache.get().is_some())
            .finish_non_exhaustive()
    }
}
