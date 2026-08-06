//! Which rules run, what the counts actually count, and what an autofix does.
//!
//! ```text
//! cargo run -p wgslender --example lint
//! ```
//!
//! Four sections. Each one is a place where the numbers, read on their own,
//! say something untrue: the packs disagree about the same shader, a
//! misspelled rule id changes nothing and says nothing, rule options are
//! reachable only through one door, and the report `lint_fix` returns is about
//! the source you handed it rather than the one it gives back.

use core::str::FromStr as _;

use wgslender::{
    Error, LintConfig, LintReport, Pack, RuleSetting, Severity, Strictness, Value, lint, lint_fix,
    validate,
};

/// A shader with two things wrong with it: a cast that casts `u32` to `u32`,
/// and a statement after `return`.
const LINTY: &str = "\
@group(0) @binding(0) var<storage, read_write> counters: array<u32>;

@compute @workgroup_size(64)
fn main(@builtin(local_invocation_index) i: u32) {
    let doubled = u32(i * 2u);
    counters[i] = doubled;
    return;
    counters[i] = 0u;
}
";

/// Three parameters — under the `max-params` default of eight, over a
/// configured two.
const THREE_PARAMS: &str = "\
fn luminance(r: f32, g: f32, b: f32) -> f32 {
    return r * 0.299 + g * 0.587 + b * 0.114;
}

@compute @workgroup_size(1)
fn main() {
    let luma = luminance(0.2, 0.4, 0.6);
}
";

/// Every pack, in the order the library lists them.
const PACKS: &[Pack] = &[
    Pack::Recommended,
    Pack::Style,
    Pack::Performance,
    Pack::Portability,
    Pack::Minify,
    Pack::Strict,
];

fn main() -> Result<(), Error> {
    packs()?;
    overrides()?;
    rule_options()?;
    fixing()
}

/// The same shader through all six packs.
fn packs() -> Result<(), Error> {
    heading("1. the packs disagree, and the counts are not a total");

    println!(
        "{:<24}{:>8}{:>10}{:>9}{:>14}",
        "pack", "errors", "warnings", "fixable", "diagnostics"
    );
    for &pack in PACKS {
        let report = lint(LINTY, &LintConfig::default().extend(pack))?;
        println!(
            "{:<24}{:>8}{:>10}{:>9}{:>14}",
            pack.as_str(),
            report.error_count,
            report.warning_count,
            report.fixable_count,
            report.diagnostics.len(),
        );
    }

    println!("\nwhat @wgslender/recommended actually said:");
    print_diagnostics(&lint(
        LINTY,
        &LintConfig::default().extend(Pack::Recommended),
    )?);

    println!("\nand what @wgslender/minify said, for the third row of it:");
    print_diagnostics(&lint(LINTY, &LintConfig::default().extend(Pack::Minify))?);

    println!(
        "\nThe first two of each are the validator's, and every pack reports them:\n\
         linting type-checks first, and a rule set cannot opt out of that. Only\n\
         recommended and strict add the linter's own W0201 and W0210, which is why\n\
         three packs show two diagnostics beside a warning_count of zero —\n\
         warning_count counts lint warnings, not diagnostics. The minify pack's own\n\
         finding is a hint, and hints are in neither count either: that pack has\n\
         three diagnostics and two zeroes."
    );
    Ok(())
}

/// Two overrides that work and one that quietly does not.
fn overrides() -> Result<(), Error> {
    heading("2. overrides, including the one that does nothing");

    let baseline = LintConfig::default().extend(Pack::Recommended);
    let cases = [
        ("recommended, untouched", baseline.clone()),
        (
            "no-redundant-casts -> Off",
            baseline
                .clone()
                .rule("no-redundant-casts", RuleSetting::Off),
        ),
        (
            "no-unreachable -> Error",
            baseline.clone().rule("no-unreachable", RuleSetting::Error),
        ),
        (
            "no-unreachable-code -> Error",
            baseline.rule("no-unreachable-code", RuleSetting::Error),
        ),
    ];

    println!("{:<32}{:>8}{:>10}", "config", "errors", "warnings");
    for (label, config) in cases {
        let report = lint(LINTY, &config)?;
        println!(
            "{label:<32}{:>8}{:>10}",
            report.error_count, report.warning_count
        );
    }

    println!(
        "\nThe last row is the same as the first. `no-unreachable-code` is not a rule\n\
         id — the rule is `no-unreachable` — and an id nothing answers to is dropped\n\
         without a word. A rule you believe you configured and a rule that never\n\
         fires look identical from here, so the ids are worth checking against\n\
         src/lint/rules/*.zig rather than against memory."
    );
    Ok(())
}

/// `RuleSetting::WarnWith`, and the one way to build the `Value` it needs.
fn rule_options() -> Result<(), Error> {
    heading("3. rule options, and the only door into them");

    // `wgslender::Value` is `serde_json::Value` re-exported — but `serde_json`
    // itself is not a dependency you inherit by depending on `wgslender`, so
    // `json!` and `Map` are both out of reach. `FromStr` is what remains, and
    // it is enough: rule options are small objects.
    let two_params = Value::from_str(r#"{"max":2}"#)?;

    let plain = LintConfig::default().rule("max-params", RuleSetting::Warn);
    let configured = LintConfig::default().rule("max-params", RuleSetting::WarnWith(two_params));

    println!("max-params at its default of 8:");
    print_diagnostics(&lint(THREE_PARAMS, &plain)?);
    println!("  (nothing — three parameters is under eight)\n");

    println!("max-params with {{\"max\":2}}:");
    print_diagnostics(&lint(THREE_PARAMS, &configured)?);

    println!(
        "\nThe number in that message came out of the object, which is how you can\n\
         tell the options arrived. Not every rule reads them — no-magic-numbers\n\
         hard-codes its allowlist today — and a rule that ignores what you passed\n\
         it goes as quiet as a misspelled id."
    );
    Ok(())
}

/// `lint_fix`, and whose source its report describes.
fn fixing() -> Result<(), Error> {
    heading("4. lint_fix, and whose report it is");

    let config = LintConfig::default().extend(Pack::Recommended);
    let outcome = lint_fix(LINTY, &config)?;

    println!("the one line that changed:");
    for (before, after) in LINTY
        .lines()
        .zip(outcome.fixed_source.lines())
        .filter(|(before, after)| before != after)
    {
        println!("  -{before}");
        println!("  +{after}");
    }

    let after = lint(&outcome.fixed_source, &config)?;
    println!("\n{:<28}{:>10}{:>9}", "", "warnings", "fixable");
    println!(
        "{:<28}{:>10}{:>9}",
        "the report it returned", outcome.report.warning_count, outcome.report.fixable_count
    );
    println!(
        "{:<28}{:>10}{:>9}",
        "linting the fixed source", after.warning_count, after.fixable_count
    );

    println!(
        "\nThe returned report describes the source as handed in — it is the report\n\
         that decided what to fix, not a report on the result. The warning that\n\
         survives is the unreachable statement, which has no autofix: deleting code\n\
         is not a rewrite a linter should make on its own."
    );

    // An autofix that emitted invalid WGSL would be the failure worth catching,
    // so the example checks rather than assumes — and asserts, because the gate
    // runs this and a printed `false` would sail past it.
    let verdict = validate(&outcome.fixed_source, Strictness::Default)?;
    assert!(verdict.valid, "an autofix produced invalid WGSL");
    println!(
        "\nthe fixed source still validates: {} ({} errors)",
        verdict.valid, verdict.error_count
    );
    Ok(())
}

/// `severity code line:column message`, for every diagnostic in a report.
fn print_diagnostics(report: &LintReport) {
    for diagnostic in &report.diagnostics {
        let position = format!("{}:{}", diagnostic.line, diagnostic.column);
        println!(
            "  {:<9}{:<7}{position:<7}{}",
            grade(diagnostic.severity),
            // The validator's parse errors carry no code; the rules all do.
            diagnostic.code.as_deref().unwrap_or("-"),
            diagnostic.message,
        );
    }
}

/// The word this example prints for a severity.
///
/// The wildcard is the arm that matters: `Severity` is `#[non_exhaustive]`, so
/// a severity a newer library reports arrives as `Unknown` rather than failing
/// the report, and this is where a program decides what to do about it.
fn grade(severity: Severity) -> &'static str {
    match severity {
        Severity::Error => "error",
        Severity::Warning => "warning",
        Severity::Info => "info",
        Severity::Note => "note",
        Severity::Hint => "hint",
        _ => "unknown",
    }
}

/// A section rule, so four sections of output read as four sections.
fn heading(title: &str) {
    println!("\n{title}");
    println!("{}", "-".repeat(title.len()));
}
