//! Linting, as a table. A new scenario is a row.
//!
//! Every expectation is pinned against the C library itself rather than
//! guessed — including the two counterintuitive ones: an empty config enables
//! no rules at all, and `warning_count` counts only the *lint* warnings even
//! though the diagnostics array also carries the validator's.
//!
//! Every test is skipped under miri: they call into a static library compiled
//! from Zig, which miri cannot interpret.

mod common;

use wgslender_core::{
    LintConfig, LintReport, Pack, RuleSetting, Strictness, lint, lint_fix, validate,
};

/// One lint scenario.
struct Case {
    /// Reported when the row fails.
    name: &'static str,
    /// WGSL handed to the linter.
    source: &'static str,
    /// Which packs and rules are switched on.
    config: LintConfig,
    /// Receives the parsed report.
    check: fn(&LintReport),
}

fn cases() -> Vec<Case> {
    let mut cases = rule_selection_cases();
    cases.extend(counting_cases());
    cases.extend(directive_cases());
    cases
}

/// Which rules a config turns on.
fn rule_selection_cases() -> Vec<Case> {
    vec![
        Case {
            name: "empty config runs no rules at all",
            source: common::UNUSED,
            config: LintConfig::default(),
            check: |report| {
                assert_eq!(report.error_count, 0);
                assert_eq!(report.warning_count, 0);
                assert_eq!(report.fixable_count, 0);
                assert!(
                    report.diagnostics.is_empty(),
                    "a clean shader with no rules enabled has nothing to say"
                );
            },
        },
        Case {
            name: "demo passes the recommended pack",
            source: common::DEMO,
            config: LintConfig::default().extend(Pack::Recommended),
            check: |report| {
                assert_eq!(report.error_count, 0);
                assert_eq!(report.warning_count, 0);
                assert_eq!(report.fixable_count, 0);
                assert!(report.diagnostics.is_empty());
            },
        },
        Case {
            name: "a single enabled rule finds the unused helper",
            source: common::UNUSED,
            config: LintConfig::default().rule("no-unused-vars", RuleSetting::Warn),
            check: |report| {
                assert_eq!(report.warning_count, 1, "one unused declaration");
                let Some(first) = report.diagnostics.first() else {
                    panic!("expected a diagnostic for the unused helper")
                };
                assert_eq!(first.code.as_deref(), Some("W0001"));
                assert!(
                    first.message.contains("unused_helper"),
                    "the message names the symbol: {}",
                    first.message
                );
            },
        },
        Case {
            name: "a rule raised to error is counted as an error",
            source: common::UNUSED,
            config: LintConfig::default().rule("no-unused-vars", RuleSetting::Error),
            check: |report| {
                assert_eq!(report.error_count, 1);
                assert_eq!(report.warning_count, 0);
            },
        },
        Case {
            name: "per-rule options reach the wire",
            source: common::UNUSED,
            config: LintConfig::default().rule(
                "no-unused-vars",
                RuleSetting::WarnWith(serde_json::json!({})),
            ),
            check: |report| assert_eq!(report.warning_count, 1),
        },
        Case {
            name: "an unknown rule id is silently ignored",
            source: common::UNUSED,
            config: LintConfig::default().rule("no-such-rule", RuleSetting::Error),
            check: |report| {
                assert_eq!(report.error_count, 0, "a typo disables the rule silently");
                assert!(report.diagnostics.is_empty());
            },
        },
    ]
}

/// What the three counts on a report actually cover.
fn counting_cases() -> Vec<Case> {
    vec![
        Case {
            name: "validator errors are counted even with no rules enabled",
            source: common::INVALID,
            config: LintConfig::default(),
            check: |report| {
                assert_eq!(report.error_count, 1, "the undeclared identifier counts");
                assert_eq!(report.diagnostics.len(), 1);
            },
        },
        Case {
            name: "validator warnings appear as diagnostics but are not counted",
            source: common::WARNING,
            config: LintConfig::default(),
            check: |report| {
                assert_eq!(
                    report.diagnostics.len(),
                    2,
                    "the validator's two warnings still reach the array"
                );
                assert_eq!(
                    report.warning_count, 0,
                    "warning_count is lint-only — the asymmetry is the library's, \
                     pinned here so a change to it is visible"
                );
            },
        },
        Case {
            name: "the recommended pack adds its own warnings on top",
            source: common::WARNING,
            config: LintConfig::default().extend(Pack::Recommended),
            check: |report| {
                assert_eq!(report.diagnostics.len(), 4, "two validator, two lint");
                assert_eq!(report.warning_count, 2, "the two lint ones");
                assert_eq!(report.fixable_count, 1, "the redundant cast is fixable");
            },
        },
    ]
}

/// `wgslender-disable` comments in the source.
fn directive_cases() -> Vec<Case> {
    vec![
        Case {
            name: "a disable comment silences the rule it names",
            source: common::UNUSED_WITH_DIRECTIVE,
            config: LintConfig::default().rule("no-unused-vars", RuleSetting::Warn),
            check: |report| {
                assert_eq!(report.warning_count, 0);
                assert!(report.diagnostics.is_empty());
            },
        },
        Case {
            name: "an unused disable directive is reported when asked for",
            source: common::DEAD_DIRECTIVE,
            config: LintConfig::default()
                .extend(Pack::Recommended)
                .report_unused_disable_directives(true),
            check: |report| {
                assert!(
                    report
                        .diagnostics
                        .iter()
                        .any(|d| d.code.as_deref() == Some("W0209")),
                    "the directive is dead once the rule is off: {:?}",
                    report.diagnostics
                );
            },
        },
    ]
}

#[test]
#[cfg(not(miri))]
fn lint_table() {
    for case in cases() {
        println!("case: {}", case.name);
        let report = match lint(case.source, &case.config) {
            Ok(report) => report,
            Err(err) => panic!("{}: lint failed: {err}", case.name),
        };
        (case.check)(&report);
    }
}

/// `lint_fix` rewrites the source, and its report describes what the *original*
/// looked like — so re-linting the rewritten source is the only way to see the
/// effect. The final assertion is the load-bearing one: an autofix that
/// produces invalid WGSL is worse than no autofix at all.
#[test]
#[cfg(not(miri))]
fn lint_fix_rewrites_the_source_and_the_result_still_validates() {
    let config = LintConfig::default().extend(Pack::Recommended);

    let Ok(outcome) = lint_fix(common::WARNING, &config) else {
        panic!("lint_fix failed on the warning fixture")
    };
    assert_ne!(outcome.fixed_source, common::WARNING, "a fix was applied");
    assert_eq!(
        outcome.report.fixable_count, 1,
        "the report covers the source as it was handed in"
    );

    let Ok(after) = lint(&outcome.fixed_source, &config) else {
        panic!("re-linting the fixed source failed")
    };
    assert!(
        after.fixable_count < outcome.report.fixable_count,
        "fixing must consume the fixable diagnostics"
    );

    let Ok(report) = validate(&outcome.fixed_source, Strictness::Default) else {
        panic!("validating the fixed source failed")
    };
    assert!(
        report.valid,
        "an autofix must not produce invalid WGSL: {:?}",
        report.diagnostics
    );
}

/// Nothing to fix means nothing changes.
#[test]
#[cfg(not(miri))]
fn lint_fix_leaves_a_clean_shader_untouched() {
    let config = LintConfig::default().extend(Pack::Recommended);
    let Ok(outcome) = lint_fix(common::DEMO, &config) else {
        panic!("lint_fix failed on the demo fixture")
    };
    assert_eq!(outcome.fixed_source, common::DEMO);
    assert_eq!(outcome.report.fixable_count, 0);
}
