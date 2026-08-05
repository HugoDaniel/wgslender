//! The stable-id refactor family, as tables. A new scenario is a row.
//!
//! Every expectation here was pinned against the C library before it was
//! written down: all twelve entry points were probed through `wgslender-sys`
//! first. Three of the shapes that came back are not what the API's shape
//! suggests, and each of those has a row of its own — `change_type` accepting a
//! replacement that is not a type, `remove_declaration` leaving call sites
//! dangling, and the locate family reporting "not found" as an answer rather
//! than as a failure.
//!
//! Offsets are UTF-8 byte offsets, so every one of them is computed from the
//! fixture with [`str::find`] rather than written out as a number.
//!
//! Every test is skipped under miri: they call into a static library compiled
//! from Zig, which miri cannot interpret.

mod common;

use wgslender_core::refactor::{
    Applied, ByteRange, Edit, IncludeDeclaration, RefactorError, StableId, change_type,
    change_type_apply, find_references, locate_declaration, locate_stable_id, locate_type,
    remove_declaration, remove_declaration_apply, rename, rename_apply, rename_by_id,
    stable_id_at_offset,
};
use wgslender_core::{Error, Strictness, validate};

/// A `let` carrying an explicit type annotation, which is what `change_type`
/// needs and the demo fixture's every binding lacks.
const ANNOTATED: &str = "@compute @workgroup_size(1)\nfn main() {\n    let x: f32 = 1.0;\n}\n";

/// The byte offset at which `needle` starts.
fn offset_of(source: &str, needle: &str) -> u32 {
    let Some(index) = source.find(needle) else {
        panic!("fixture does not contain {needle:?}")
    };
    let Ok(offset) = u32::try_from(index) else {
        panic!("offset of {needle:?} does not fit in a u32")
    };
    offset
}

/// The stable ID of the symbol `needle` starts at.
fn id_of(source: &str, needle: &str) -> StableId {
    match stable_id_at_offset(source, offset_of(source, needle)) {
        Ok(Some(id)) => id,
        Ok(None) => panic!("no symbol at {needle:?}"),
        Err(err) => panic!("stable_id_at_offset({needle:?}) failed: {err}"),
    }
}

/// The text a byte range covers.
fn slice(source: &str, range: ByteRange) -> &str {
    &source[range.start as usize..range.end as usize]
}

/// Assert that an operation failed for the stated reason.
fn assert_refactor_error<T: core::fmt::Debug>(outcome: Result<T, Error>, expected: &RefactorError) {
    match outcome {
        Err(Error::Refactor(actual)) => assert_eq!(&actual, expected),
        Err(other) => panic!("expected {expected:?}, got a different error: {other}"),
        Ok(value) => panic!("expected {expected:?}, got {value:?}"),
    }
}

/// One scenario for a call that returns edits without applying them.
struct EditCase {
    /// Reported when the row fails.
    name: &'static str,
    /// WGSL the row operates on.
    source: &'static str,
    /// Performs the row's refactor.
    call: fn(&str) -> Result<Vec<Edit>, Error>,
    /// Receives `(source, outcome)`.
    check: fn(&str, Result<Vec<Edit>, Error>),
}

fn rename_cases() -> Vec<EditCase> {
    vec![
        EditCase {
            name: "rename/edits the declaration and every use",
            source: common::DEMO,
            call: |source| rename(source, offset_of(source, "luminance(color"), "lum"),
            check: |source, outcome| {
                let Ok(edits) = outcome else {
                    panic!("rename failed on the demo fixture")
                };
                assert_eq!(edits.len(), 2, "one declaration, one call site");
                for edit in &edits {
                    assert_eq!(edit.new_text, "lum");
                    let range = ByteRange {
                        start: edit.start,
                        end: edit.end,
                    };
                    assert_eq!(slice(source, range), "luminance");
                }
            },
        },
        EditCase {
            name: "rename/a keyword is not a valid new name",
            source: common::DEMO,
            call: |source| rename(source, offset_of(source, "luminance(color"), "fn"),
            check: |_, outcome| assert_refactor_error(outcome, &RefactorError::InvalidIdentifier),
        },
        EditCase {
            name: "rename/nothing under the offset",
            source: "// just a comment\n",
            call: |source| rename(source, 0, "x"),
            check: |_, outcome| assert_refactor_error(outcome, &RefactorError::SymbolNotFound),
        },
        EditCase {
            name: "rename_by_id/reaches the same symbol as the offset form",
            source: common::DEMO,
            call: |source| rename_by_id(source, &id_of(source, "luminance(color"), "lum"),
            check: |source, outcome| {
                let (Ok(by_id), Ok(by_offset)) = (
                    outcome,
                    rename(source, offset_of(source, "luminance(color"), "lum"),
                ) else {
                    panic!("both rename forms must succeed on the demo fixture")
                };
                assert_eq!(by_id, by_offset, "an ID and an offset name one symbol");
            },
        },
    ]
}

fn type_and_removal_cases() -> Vec<EditCase> {
    vec![
        EditCase {
            name: "change_type/replaces the annotation and nothing else",
            source: ANNOTATED,
            call: |source| change_type(source, &id_of(source, "x: f32"), "vec2f"),
            check: |source, outcome| {
                let Ok(edits) = outcome else {
                    panic!("change_type failed on an annotated let")
                };
                let [edit] = edits.as_slice() else {
                    panic!("expected exactly one edit, got {edits:?}")
                };
                assert_eq!(edit.new_text, "vec2f");
                let range = ByteRange {
                    start: edit.start,
                    end: edit.end,
                };
                assert_eq!(slice(source, range), "f32", "the annotation alone");
            },
        },
        EditCase {
            name: "change_type/a symbol that has no annotation to replace",
            source: ANNOTATED,
            call: |source| change_type(source, &id_of(source, "main()"), "vec2f"),
            check: |_, outcome| assert_refactor_error(outcome, &RefactorError::NoTypeAnnotation),
        },
        EditCase {
            // Pinned because it is surprising: the replacement is spliced in
            // verbatim, so producing valid WGSL is the caller's job.
            name: "change_type/does not check that the replacement is a type",
            source: ANNOTATED,
            call: |source| change_type(source, &id_of(source, "x: f32"), "not a type"),
            check: |_, outcome| {
                let Ok(edits) = outcome else {
                    panic!("change_type rejected a replacement it is documented to accept")
                };
                let [edit] = edits.as_slice() else {
                    panic!("expected exactly one edit, got {edits:?}")
                };
                assert_eq!(edit.new_text, "not a type");
            },
        },
        EditCase {
            name: "remove_declaration/covers the whole declaration",
            source: common::DEMO,
            call: |source| remove_declaration(source, &id_of(source, "luminance(color")),
            check: |source, outcome| {
                let Ok(edits) = outcome else {
                    panic!("remove_declaration failed on the demo fixture")
                };
                let [edit] = edits.as_slice() else {
                    panic!("expected exactly one edit, got {edits:?}")
                };
                assert!(edit.new_text.is_empty(), "a removal inserts nothing");
                let range = ByteRange {
                    start: edit.start,
                    end: edit.end,
                };
                let removed = slice(source, range);
                assert!(removed.starts_with("fn luminance("), "got {removed:?}");
                assert!(removed.ends_with('}'), "got {removed:?}");
            },
        },
        EditCase {
            name: "remove_declaration/an ID nothing declares",
            source: common::DEMO,
            call: |source| remove_declaration(source, &StableId::new("v1:fn:no_such_helper")),
            check: |_, outcome| assert_refactor_error(outcome, &RefactorError::SymbolNotFound),
        },
    ]
}

#[test]
#[cfg(not(miri))]
fn edit_table() {
    for case in rename_cases().into_iter().chain(type_and_removal_cases()) {
        println!("case: {}", case.name);
        (case.check)(case.source, (case.call)(case.source));
    }
}

/// One scenario for a call that returns the rewritten source.
struct AppliedCase {
    /// Reported when the row fails.
    name: &'static str,
    /// WGSL the row operates on.
    source: &'static str,
    /// Performs the row's refactor.
    call: fn(&str) -> Result<Applied, Error>,
    /// Receives `(source, outcome)`.
    check: fn(&str, Result<Applied, Error>),
}

fn applied_cases() -> Vec<AppliedCase> {
    vec![
        AppliedCase {
            name: "rename_apply/rewrites both sites",
            source: common::DEMO,
            call: |source| rename_apply(source, offset_of(source, "luminance(color"), "lum"),
            check: |_, outcome| {
                let Ok(applied) = outcome else {
                    panic!("rename_apply failed on the demo fixture")
                };
                assert!(applied.source.contains("fn lum("), "declaration renamed");
                assert!(applied.source.contains("= lum("), "call site renamed");
                assert!(!applied.source.contains("luminance"), "no site left behind");
                assert_eq!(applied.edits.len(), 2);
            },
        },
        AppliedCase {
            // The wire hands the original source back on failure; the caller
            // already has it, so the wrapper reports the reason instead.
            name: "rename_apply/a rejected new name is an error, not a no-op",
            source: common::DEMO,
            call: |source| rename_apply(source, offset_of(source, "luminance(color"), "fn"),
            check: |_, outcome| assert_refactor_error(outcome, &RefactorError::InvalidIdentifier),
        },
        AppliedCase {
            name: "change_type_apply/rewrites the annotation",
            source: ANNOTATED,
            call: |source| change_type_apply(source, &id_of(source, "x: f32"), "vec2f"),
            check: |_, outcome| {
                let Ok(applied) = outcome else {
                    panic!("change_type_apply failed on an annotated let")
                };
                assert!(
                    applied.source.contains("let x: vec2f = 1.0;"),
                    "{applied:?}"
                );
            },
        },
        AppliedCase {
            // Pinned because it is the opposite of what the name suggests: the
            // declaration goes, the calls to it stay, and the result no longer
            // validates.
            name: "remove_declaration_apply/leaves the call sites dangling",
            source: common::DEMO,
            call: |source| remove_declaration_apply(source, &id_of(source, "luminance(color")),
            check: |_, outcome| {
                let Ok(applied) = outcome else {
                    panic!("remove_declaration_apply failed on the demo fixture")
                };
                assert!(
                    !applied.source.contains("fn luminance("),
                    "declaration gone"
                );
                assert!(applied.source.contains("luminance(sampled"), "call kept");
                let Ok(validation) = validate(&applied.source, Strictness::Default) else {
                    panic!("validating the rewritten source failed")
                };
                assert!(!validation.valid, "the dangling call is a semantic error");
            },
        },
    ]
}

#[test]
#[cfg(not(miri))]
fn applied_table() {
    for case in applied_cases() {
        println!("case: {}", case.name);
        (case.check)(case.source, (case.call)(case.source));
    }
}

/// One scenario for the three calls that resolve an ID to a byte range.
struct LocateCase {
    /// Reported when the row fails.
    name: &'static str,
    /// WGSL the row operates on.
    source: &'static str,
    /// Resolves the row's range.
    call: fn(&str) -> Result<Option<ByteRange>, Error>,
    /// Receives `(source, range)`.
    check: fn(&str, Option<ByteRange>),
}

fn locate_cases() -> Vec<LocateCase> {
    vec![
        LocateCase {
            name: "locate_stable_id/the name alone",
            source: common::DEMO,
            call: |source| locate_stable_id(source, &id_of(source, "luminance(color")),
            check: |source, range| {
                let Some(range) = range else {
                    panic!("the ID came from this source")
                };
                assert_eq!(slice(source, range), "luminance");
            },
        },
        LocateCase {
            name: "locate_declaration/the whole declaration",
            source: common::DEMO,
            call: |source| locate_declaration(source, &id_of(source, "luminance(color")),
            check: |source, range| {
                let Some(range) = range else {
                    panic!("the ID came from this source")
                };
                let text = slice(source, range);
                assert!(text.starts_with("fn luminance("), "got {text:?}");
                assert!(text.contains("return dot("), "the body is included");
                assert!(text.ends_with('}'), "got {text:?}");
            },
        },
        LocateCase {
            name: "locate_type/a function's return type",
            source: common::DEMO,
            call: |source| locate_type(source, &id_of(source, "luminance(color")),
            check: |source, range| {
                let Some(range) = range else {
                    panic!("luminance returns f32")
                };
                assert_eq!(slice(source, range), "f32");
            },
        },
        LocateCase {
            name: "locate_declaration/a local let",
            source: ANNOTATED,
            call: |source| locate_declaration(source, &id_of(source, "x: f32")),
            check: |source, range| {
                let Some(range) = range else {
                    panic!("the ID came from this source")
                };
                assert_eq!(slice(source, range), "let x: f32 = 1.0;");
            },
        },
        LocateCase {
            // Not an error: the question was answerable, and the answer is no.
            name: "locate_type/a symbol with nothing to point at",
            source: ANNOTATED,
            call: |source| locate_type(source, &id_of(source, "main()")),
            check: |_, range| assert_eq!(range, None, "main declares no return type"),
        },
        LocateCase {
            name: "locate_stable_id/an ID this source does not contain",
            source: common::DEMO,
            call: |source| locate_stable_id(source, &StableId::new("v1:fn:no_such_helper")),
            check: |_, range| assert_eq!(range, None),
        },
    ]
}

#[test]
#[cfg(not(miri))]
fn locate_table() {
    for case in locate_cases() {
        println!("case: {}", case.name);
        let Ok(range) = (case.call)(case.source) else {
            panic!("{}: locating failed", case.name)
        };
        (case.check)(case.source, range);
    }
}

/// The one flag `find_references` takes, and the only thing it changes.
#[test]
#[cfg(not(miri))]
fn find_references_counts_the_declaration_only_when_asked() {
    let offset = offset_of(common::DEMO, "luminance(color");
    let (Ok(with), Ok(without)) = (
        find_references(common::DEMO, offset, IncludeDeclaration::Yes),
        find_references(common::DEMO, offset, IncludeDeclaration::No),
    ) else {
        panic!("find_references failed on the demo fixture")
    };

    assert_eq!(with.len(), without.len() + 1, "exactly the declaration");
    assert!(!without.is_empty(), "luminance is called at least once");
    let Some(declaration) = with.first() else {
        panic!("the declaration sorts first")
    };
    assert!(declaration.is_write, "a declaration writes the name");
    assert_eq!(
        &common::DEMO[declaration.start as usize..declaration.end as usize],
        "luminance"
    );
}

/// Unlike the rest of the family, an offset that names nothing is an answer
/// here — no references — rather than a failure.
#[test]
#[cfg(not(miri))]
fn find_references_is_empty_where_there_is_no_symbol() {
    for (label, source, offset) in [
        ("leading comment", common::DEMO, 0),
        ("past the end", common::DEMO, u32::MAX),
        ("not WGSL at all", "!!!", 0),
        ("empty source", "", 0),
    ] {
        let Ok(references) = find_references(source, offset, IncludeDeclaration::Yes) else {
            panic!("{label}: find_references reported a failure")
        };
        assert!(references.is_empty(), "{label}: got {references:?}");
    }
}

/// The demo fixture's header comment carries an em dash, so a character offset
/// and a byte offset disagree from line two onwards. The ABI wants bytes.
#[test]
#[cfg(not(miri))]
fn offsets_are_utf8_byte_offsets() {
    let byte_offset = offset_of(common::DEMO, "luminance(color");
    let Some(char_offset) = common::DEMO
        .char_indices()
        .position(|(index, _)| index == byte_offset as usize)
    else {
        panic!("the byte offset must fall on a character boundary")
    };
    assert_ne!(
        byte_offset as usize, char_offset,
        "the fixture must contain a multi-byte character before this point, \
         or the test proves nothing"
    );

    let Ok(references) = find_references(common::DEMO, byte_offset, IncludeDeclaration::Yes) else {
        panic!("find_references failed on the demo fixture")
    };
    let Some(declaration) = references.first() else {
        panic!("expected the declaration")
    };
    assert_eq!(declaration.start, byte_offset, "byte offsets, not char");
}

/// A stable ID names a symbol, not a position: every mention resolves to one.
#[test]
#[cfg(not(miri))]
fn a_stable_id_is_the_same_from_the_declaration_and_from_a_use() {
    let from_declaration = id_of(common::DEMO, "luminance(color");
    let from_use = id_of(common::DEMO, "luminance(sampled");
    assert_eq!(from_declaration, from_use);
    assert!(
        from_declaration.as_str().starts_with("v1:"),
        "got {from_declaration}"
    );
}

/// The point of the whole family: an ID taken before an edit still resolves
/// after one, which a byte offset would not.
#[test]
#[cfg(not(miri))]
fn a_stable_id_survives_an_unrelated_edit() {
    let id = id_of(common::DEMO, "luminance(color");
    let Ok(edited) = rename_apply(common::DEMO, offset_of(common::DEMO, "params: Params"), "p")
    else {
        panic!("renaming the uniform failed")
    };
    assert!(edited.source.contains("var<uniform> p: Params"), "renamed");

    let Ok(Some(range)) = locate_stable_id(&edited.source, &id) else {
        panic!("the ID must still resolve after an edit elsewhere")
    };
    assert_eq!(slice(&edited.source, range), "luminance");
}

/// `None` is the answer for "no symbol here", the same way it is for the
/// locate family.
#[test]
#[cfg(not(miri))]
fn stable_id_at_offset_is_none_where_there_is_no_symbol() {
    for (label, source, offset) in [
        ("leading comment", common::DEMO, 0),
        ("not WGSL at all", "!!!", 0),
        ("empty source", "", 0),
    ] {
        let Ok(id) = stable_id_at_offset(source, offset) else {
            panic!("{label}: stable_id_at_offset reported a failure")
        };
        assert_eq!(id, None, "{label}");
    }
}
