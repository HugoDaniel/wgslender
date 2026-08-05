//! Semantic validation, as a table. A new scenario is a row.
//!
//! Every expectation is pinned against the C library itself rather than
//! guessed: each fixture was run through `wgslender-sys` before its numbers
//! were written down.
//!
//! Every test is skipped under miri: they call into a static library compiled
//! from Zig, which miri cannot interpret.

mod common;

use wgslender_core::{Severity, Strictness, Validation, validate};

/// One validation scenario.
struct Case {
    /// Reported when the row fails.
    name: &'static str,
    /// WGSL handed to the validator.
    source: &'static str,
    /// Whether warnings are promoted to errors.
    strictness: Strictness,
    /// Receives the parsed report.
    check: fn(&Validation),
}

fn cases() -> Vec<Case> {
    vec![
        Case {
            name: "demo/default is clean",
            source: common::DEMO,
            strictness: Strictness::Default,
            check: |report| {
                assert!(report.valid, "demo fixture must validate");
                assert_eq!(report.error_count, 0);
                assert_eq!(report.warning_count, 0);
                assert!(report.diagnostics.is_empty());
            },
        },
        Case {
            name: "invalid/default reports a located, coded error",
            source: common::INVALID,
            strictness: Strictness::Default,
            check: |report| {
                assert!(!report.valid);
                assert!(report.error_count >= 1, "got {}", report.error_count);
                let Some(first) = report.diagnostics.first() else {
                    panic!("an invalid shader must produce a diagnostic")
                };
                assert_eq!(first.severity, Severity::Error);
                let Some(code) = first.code.as_deref() else {
                    panic!("a semantic error carries a code")
                };
                assert!(code.starts_with('E'), "error codes start with E: {code}");
                assert!(first.line >= 1, "lines are 1-based");
                assert!(first.column >= 1, "columns are 1-based");
                assert!(
                    first.message.contains("undeclared_variable"),
                    "the message names the offending symbol: {}",
                    first.message
                );
            },
        },
        Case {
            name: "warning/default stays valid",
            source: common::WARNING,
            strictness: Strictness::Default,
            check: |report| {
                assert!(report.valid, "warnings alone do not invalidate a shader");
                assert_eq!(report.error_count, 0);
                assert!(report.warning_count >= 1, "got {}", report.warning_count);
                assert!(
                    report
                        .diagnostics
                        .iter()
                        .all(|d| d.severity == Severity::Warning)
                );
            },
        },
        Case {
            name: "warning/strict turns every warning into an error",
            source: common::WARNING,
            strictness: Strictness::Strict,
            check: |report| {
                assert!(!report.valid, "strict mode rejects warnings");
                assert_eq!(report.warning_count, 0, "nothing stays a warning");
                assert!(
                    report
                        .diagnostics
                        .iter()
                        .all(|d| d.severity == Severity::Error)
                );
            },
        },
        Case {
            name: "unparseable source reports parse errors, some without a code",
            source: common::UNPARSEABLE,
            strictness: Strictness::Default,
            check: |report| {
                assert!(!report.valid);
                assert!(report.error_count >= 1);
                assert!(
                    report.diagnostics.iter().any(|d| d.code.is_none()),
                    "some parse errors carry no code — that is why `code` is optional"
                );
            },
        },
        Case {
            name: "empty source is valid",
            source: "",
            strictness: Strictness::Default,
            check: |report| {
                assert!(report.valid);
                assert_eq!(report.error_count, 0);
                assert_eq!(report.warning_count, 0);
            },
        },
    ]
}

#[test]
#[cfg(not(miri))]
fn validation_table() {
    for case in cases() {
        println!("case: {}", case.name);
        let report = match validate(case.source, case.strictness) {
            Ok(report) => report,
            Err(err) => panic!("{}: validation failed: {err}", case.name),
        };
        (case.check)(&report);
    }
}

/// Strict mode may only ever move diagnostics from the warning column to the
/// error column — never drop them. The npm suite pins the same invariant.
#[test]
#[cfg(not(miri))]
fn strict_promotes_warnings_without_losing_any() {
    let Ok(lenient) = validate(common::WARNING, Strictness::Default) else {
        panic!("validation failed on the warning fixture")
    };
    let Ok(strict) = validate(common::WARNING, Strictness::Strict) else {
        panic!("strict validation failed on the warning fixture")
    };

    assert!(lenient.warning_count >= 1, "fixture must produce warnings");
    assert!(strict.error_count >= lenient.error_count + lenient.warning_count);
    assert_eq!(strict.diagnostics.len(), lenient.diagnostics.len());
}
