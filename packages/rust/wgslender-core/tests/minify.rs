//! Minification behaviour, as a table. A new scenario is a row.
//!
//! Every expectation here is pinned against the C library itself rather than
//! guessed: the interesting cases (empty input, unparseable input, semantically
//! invalid input) were probed through `wgslender-sys` before being written down.
//!
//! Every test is skipped under miri: they call into a static library compiled
//! from Zig, which miri cannot interpret.

mod common;

use wgslender_core::{MinifyOptions, minify, minify_with};

/// One minification scenario.
struct Case {
    /// Reported when the row fails.
    name: &'static str,
    /// WGSL handed to the minifier.
    source: &'static str,
    /// `None` runs [`minify`]; `Some` runs [`minify_with`].
    options: Option<MinifyOptions>,
    /// Receives `(source, minified)`.
    check: fn(&str, &str),
}

fn cases() -> Vec<Case> {
    vec![
        Case {
            name: "demo/defaults shrinks the source and keeps the entry point",
            source: common::DEMO,
            options: None,
            check: |source, minified| {
                assert!(
                    minified.len() < source.len(),
                    "expected fewer than {} bytes, got {}",
                    source.len(),
                    minified.len()
                );
                assert!(
                    minified.contains("@compute"),
                    "stage attribute must survive"
                );
                assert!(
                    minified.contains("fn main"),
                    "entry point must keep its name"
                );
                assert!(
                    !minified.contains("luminance"),
                    "helper functions are renamed by default"
                );
            },
        },
        Case {
            name: "demo/keep_names preserves the named helper",
            source: common::DEMO,
            options: Some(MinifyOptions::default().keep_names(["luminance"])),
            check: |source, minified| {
                assert!(
                    minified.contains("luminance"),
                    "kept name must survive renaming"
                );
                assert!(
                    minified.len() < source.len(),
                    "keeping one name must not defeat minification"
                );
            },
        },
        Case {
            name: "demo/whitespace-only leaves every identifier alone",
            source: common::DEMO,
            options: Some(
                MinifyOptions::default()
                    .minify_whitespace(true)
                    .minify_identifiers(false)
                    .minify_syntax(false)
                    .tree_shaking(false),
            ),
            check: |source, minified| {
                for name in ["params", "Params", "luminance", "resolution"] {
                    assert!(minified.contains(name), "{name} must survive");
                }
                assert!(minified.len() < source.len(), "whitespace must still go");
            },
        },
        Case {
            name: "semantically invalid source is minified anyway",
            source: common::INVALID,
            options: None,
            check: |source, minified| {
                assert!(
                    minified.contains("undeclared_variable"),
                    "the unresolved name is passed through untouched"
                );
                assert!(
                    minified.len() < source.len(),
                    "minification is not aborted by semantic errors"
                );
            },
        },
        Case {
            name: "unparseable source is returned unchanged",
            source: common::UNPARSEABLE,
            options: None,
            check: |source, minified| assert_eq!(minified, source),
        },
        Case {
            name: "empty source minifies to empty output",
            source: "",
            options: None,
            check: |_, minified| assert!(minified.is_empty(), "got {minified:?}"),
        },
        Case {
            name: "comment-only source minifies away entirely",
            source: "// nothing but a comment\n",
            options: None,
            check: |_, minified| assert!(minified.is_empty(), "got {minified:?}"),
        },
    ]
}

#[test]
#[cfg(not(miri))]
fn minification_table() {
    for case in cases() {
        println!("case: {}", case.name);
        let outcome = match &case.options {
            None => minify(case.source),
            Some(options) => minify_with(case.source, options),
        };
        let minified = match outcome {
            Ok(minified) => minified,
            Err(err) => panic!("{}: minification failed: {err}", case.name),
        };
        (case.check)(case.source, &minified);
    }
}

/// The whole reason [`MinifyOptions`] derives `Default`: an empty option set is
/// not "everything off", it is "wgslender's own defaults apply".
#[test]
#[cfg(not(miri))]
fn default_options_match_the_default_flags() {
    let Ok(via_flags) = minify(common::DEMO) else {
        panic!("minify failed on the demo fixture")
    };
    let Ok(via_json) = minify_with(common::DEMO, &MinifyOptions::default()) else {
        panic!("minify_with failed on the demo fixture")
    };
    assert_eq!(via_flags, via_json);
}
