//! What a compressed shader promises: the same text back, once, and fewer
//! bytes in the binary than the text would have taken.
//!
//! Nothing here reaches the C library — deflating and inflating are pure Rust —
//! so unlike the rest of this suite these rows are not skipped under miri.
//!
//! The whole file is behind the `compress` feature: with it off there is no
//! type to have opinions about.
#![cfg(feature = "compress")]

mod common;

use wgslender_core::CompressedWgsl;

/// A blob the way an expansion makes one: text deflated while the embedding
/// crate compiles, handed over with the length it inflates back to.
///
/// The leak stands in for the `'static` a real expansion gets for free, where
/// the bytes are a literal in the binary and nothing ever frees them.
fn embedded(text: &str) -> CompressedWgsl {
    let Ok(text_len) = u32::try_from(text.len()) else {
        panic!("the fixture is longer than the u32 the format stores")
    };
    CompressedWgsl::__from_parts(Vec::leak(CompressedWgsl::__deflate(text)), text_len)
}

/// One promise about a blob built from `text`.
struct Case {
    /// Reported when the row fails.
    name: &'static str,
    /// Compressed, then handed to `check` along with itself.
    text: &'static str,
    /// Receives `(text, blob)`, where `blob` is freshly built and untouched.
    check: fn(&str, &CompressedWgsl),
}

fn cases() -> Vec<Case> {
    vec![
        Case {
            name: "a shader round-trips through the format",
            text: common::DEMO,
            check: |text, blob| assert_eq!(blob.as_str(), text),
        },
        Case {
            name: "the text is inflated once and kept",
            text: common::DEMO,
            check: |_, blob| {
                let first = blob.as_str();
                let second = blob.as_str();
                assert!(
                    std::ptr::eq(first.as_ptr(), second.as_ptr()),
                    "the second call inflated a second copy"
                );
            },
        },
        Case {
            name: "the length is known before anything inflates",
            text: common::DEMO,
            check: |text, blob| {
                assert_eq!(blob.len(), text.len());
                assert!(
                    format!("{blob:?}").contains("inflated: false"),
                    "asking for the length must not inflate: {blob:?}"
                );
                let _ = blob.as_str();
                assert!(
                    format!("{blob:?}").contains("inflated: true"),
                    "reading the text must inflate it: {blob:?}"
                );
            },
        },
        Case {
            name: "deflate wins on a real shader",
            text: common::DEMO,
            check: |text, blob| {
                assert!(
                    blob.compressed_len() < blob.len(),
                    "{} compressed bytes for {} bytes of text — if a shader this \
                     size no longer compresses, grow the fixture rather than this \
                     assertion",
                    blob.compressed_len(),
                    text.len(),
                );
            },
        },
        Case {
            name: "debug reports sizes, not the shader",
            text: common::DEMO,
            check: |_, blob| {
                let rendered = format!("{blob:?}");
                assert!(
                    !rendered.contains("@compute"),
                    "the whole shader ended up in the debug output: {rendered}"
                );
            },
        },
        Case {
            name: "nothing is a valid shader too",
            text: "",
            check: |_, blob| {
                assert!(blob.is_empty());
                assert_eq!(blob.len(), 0);
                assert_eq!(blob.as_str(), "");
            },
        },
    ]
}

#[test]
fn compressed_embedding_table() {
    for case in cases() {
        println!("case: {}", case.name);
        (case.check)(case.text, &embedded(case.text));
    }
}

/// A `static` is where an embedded shader actually lives, and getting there
/// takes a `const fn` constructor and a `Sync` type — neither of which a test
/// that only ever builds locals would notice losing.
#[test]
fn a_blob_can_be_a_static() {
    // `__deflate` cannot run in a `static` initialiser, so this is the stream
    // it would have produced, written out: one final fixed-Huffman block
    // containing nothing but the end-of-block symbol.
    static EMPTY: CompressedWgsl = CompressedWgsl::__from_parts(&[0x03, 0x00], 0);

    assert!(EMPTY.is_empty());
    std::thread::scope(|scope| {
        scope.spawn(|| assert_eq!(EMPTY.as_str(), ""));
    });
}
