//! What the library has to say about a shader — and what it means by invalid.
//!
//! ```text
//! cargo run -p wgslender --example validate
//! ```
//!
//! A shader the library rejects is **not** a Rust `Err`. All three calls below
//! return `Ok`; the verdict is the `valid` field inside it. `Err` is kept for
//! the call itself going wrong — an allocation the library could not make, a
//! source too long for the ABI's lengths. A program that checks shaders
//! therefore branches on the answer rather than `?`-ing its way past it.
//!
//! The first two runs are the same shader under the two settings of
//! `Strictness`, and they disagree about it.

use wgslender::{Error, Severity, Strictness, Validation, validate};

/// Valid WGSL the library still has something to say about: the statement after
/// `return` can never run.
const UNREACHABLE: &str = "\
// Every line of this runs except the last one.
@group(0) @binding(0) var<storage, read_write> counters: array<u32>;

@compute @workgroup_size(64)
fn main(@builtin(local_invocation_index) i: u32) {
    counters[i] = i;
    return;
    counters[i] = 0u;
}
";

/// WGSL that parses and then fails to type-check: `undeclared_variable` is
/// declared nowhere.
const UNDECLARED: &str = "\
// Parses fine. The name in it does not resolve to anything.
@compute @workgroup_size(1)
fn main() {
    let x = undeclared_variable;
}
";

fn main() -> Result<(), Error> {
    // The same source twice. `Strictness` is an enum rather than a `bool`
    // argument so that this pair of lines says which mode it means.
    report(
        "unreachable code, default",
        &validate(UNREACHABLE, Strictness::Default)?,
    );
    report(
        "unreachable code, strict",
        &validate(UNREACHABLE, Strictness::Strict)?,
    );
    report(
        "an undeclared identifier",
        &validate(UNDECLARED, Strictness::Default)?,
    );

    println!(
        "The first two listings hold the same code at the same position.\n\
         Strictness grades a finding; it does not change what was found."
    );

    Ok(())
}

/// One verdict, and the diagnostics behind it.
fn report(label: &str, validation: &Validation) {
    let verdict = if validation.valid {
        "accepted"
    } else {
        "rejected"
    };

    println!(
        "{label:<28}{verdict:<10}{}, {}",
        plural(validation.error_count, "error"),
        plural(validation.warning_count, "warning"),
    );

    for diagnostic in &validation.diagnostics {
        // Positions are 1-based, so they can be read straight into an editor.
        let position = format!("{}:{}", diagnostic.line, diagnostic.column);
        println!(
            "  {:<9}{:<7}{position:<7}{}",
            grade(diagnostic.severity),
            // Parse errors often carry no code; everything the validator
            // itself reports does.
            diagnostic.code.as_deref().unwrap_or("-"),
            diagnostic.message,
        );
    }

    println!();
}

/// The word this example prints for a severity.
///
/// A `match` rather than the `Display` the type already has, because of the
/// last arm: `Severity` is `#[non_exhaustive]`, and a severity this crate has
/// never heard of arrives as `Unknown` rather than failing the whole report.
/// Somewhere a program has to decide what to do with that, and this is where.
/// Printing it is enough here; a build script would want it to be fatal.
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

/// `1 error`, `2 errors` — a report that says "1 errors" reads as a bug in the
/// report.
fn plural(count: u32, noun: &str) -> String {
    if count == 1 {
        format!("{count} {noun}")
    } else {
        format!("{count} {noun}s")
    }
}
