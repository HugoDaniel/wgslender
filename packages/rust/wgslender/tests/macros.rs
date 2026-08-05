//! What `include_wgsl!` puts in the binary.
//!
//! Every constant below was produced by the real library while this file was
//! being compiled — the macro reads the fixture, validates it and minifies it
//! at expansion time, so a row here is asserting about work that has already
//! happened. That is also why a failure can show up as a *compile* error rather
//! than a failing assertion: the goldens under `tests/ui/` cover that half.
//!
//! The whole file is behind the `macros` feature, which is on by default: with
//! it off there is no macro to have opinions about.
#![cfg(feature = "macros")]

/// The file the macro reads, as the compiler would read it.
const SOURCE: &str = include_str!("fixtures/demo.wgsl");

/// Default options: validated, then minified the way [`wgslender::minify`]
/// would.
const MINIFIED: &str = wgslender::include_wgsl!("tests/fixtures/demo.wgsl");

/// The helper survives, because it was named.
const KEPT: &str = wgslender::include_wgsl!("tests/fixtures/demo.wgsl", keep_names = ["luminance"]);

/// Checked, but embedded as written.
const VERBATIM: &str = wgslender::include_wgsl!("tests/fixtures/demo.wgsl", minify = false);

/// A shader that does not type-check, embedded anyway: `validate = false` is
/// the escape hatch for a fragment that only makes sense once something
/// concatenates it.
const UNCHECKED: &str = wgslender::include_wgsl!("tests/fixtures/invalid.wgsl", validate = false);

/// Warnings are warnings under the default strictness, so this compiles.
const WARNS: &str = wgslender::include_wgsl!("tests/fixtures/warning.wgsl");

/// One thing the macro is expected to have done.
struct Case {
    /// Reported when the row fails.
    name: &'static str,
    /// Reads the constants above; panics with its own message.
    check: fn(),
}

fn cases() -> Vec<Case> {
    vec![
        Case {
            name: "defaults shrink the file",
            check: || {
                assert!(
                    MINIFIED.len() < SOURCE.len(),
                    "expected fewer than {} bytes, got {}",
                    SOURCE.len(),
                    MINIFIED.len()
                );
            },
        },
        Case {
            name: "the entry point survives",
            check: || {
                assert!(
                    MINIFIED.contains("@compute"),
                    "stage attribute must survive"
                );
                assert!(MINIFIED.contains("fn main"), "entry point keeps its name");
            },
        },
        Case {
            name: "defaults rename the helper",
            check: || {
                assert!(
                    !MINIFIED.contains("luminance"),
                    "an unnamed helper is renamed: {MINIFIED}"
                );
            },
        },
        Case {
            name: "keep_names keeps the helper",
            check: || {
                assert!(
                    KEPT.contains("luminance"),
                    "the named helper must survive: {KEPT}"
                );
                assert!(KEPT.len() < SOURCE.len(), "keeping a name still minifies");
            },
        },
        Case {
            name: "minify = false embeds the file as written",
            check: || assert_eq!(VERBATIM, SOURCE),
        },
        Case {
            name: "validate = false embeds a shader that does not type-check",
            check: || {
                assert!(
                    UNCHECKED.contains("undeclared_variable"),
                    "the unresolved name is passed through: {UNCHECKED}"
                );
            },
        },
        Case {
            name: "a warning is not a compile error",
            check: || assert!(WARNS.contains("@compute"), "got {WARNS}"),
        },
    ]
}

#[test]
fn embedding_table() {
    for case in cases() {
        println!("case: {}", case.name);
        (case.check)();
    }
}

/// The macro is not a second minifier: what it embedded at compile time is what
/// the library produces now, byte for byte.
///
/// Skipped under miri, which cannot interpret the static library the run-time
/// call reaches.
#[test]
#[cfg(not(miri))]
fn compile_time_output_matches_the_run_time_call() {
    let Ok(at_run_time) = wgslender::minify(SOURCE) else {
        panic!("minifying the fixture at run time failed")
    };
    assert_eq!(MINIFIED, at_run_time);

    let options = wgslender::MinifyOptions::default().keep_names(["luminance"]);
    let Ok(kept_at_run_time) = wgslender::minify_with(SOURCE, &options) else {
        panic!("minifying with keep_names at run time failed")
    };
    assert_eq!(KEPT, kept_at_run_time);
}

/// The point of a `&'static str`: it goes wherever a string literal goes.
#[test]
fn the_expansion_is_usable_wherever_a_literal_is() {
    static IN_A_STATIC: &str = wgslender::include_wgsl!("tests/fixtures/demo.wgsl");
    let in_a_body: &str = wgslender::include_wgsl!("tests/fixtures/demo.wgsl");

    assert_eq!(IN_A_STATIC, MINIFIED);
    assert_eq!(in_a_body, MINIFIED);
}
