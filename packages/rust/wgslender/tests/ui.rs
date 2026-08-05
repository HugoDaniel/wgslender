//! What the compiler prints when `include_wgsl!` refuses.
//!
//! A macro that reads files and type-checks shaders can fail in ways the caller
//! has to act on — a path that resolves somewhere unexpected, a shader with an
//! error in it, an option key that does not exist. The message *is* the feature
//! in those cases, so it is pinned as a golden rather than described in prose.
//!
//! Goldens live beside each case as `tests/ui/<case>.stderr`. Regenerate them
//! with `TRYBUILD=overwrite cargo test -p wgslender --test ui`, then read the
//! diff: an unexplained change there is the bug this suite exists to catch.
//!
//! Behind the `macros` feature, like the macro these cases exercise.
#![cfg(feature = "macros")]

/// Skipped under miri: trybuild shells out to cargo.
#[test]
#[cfg(not(miri))]
fn ui() {
    let cases = trybuild::TestCases::new();

    cases.pass("tests/ui/embeds.rs");

    cases.compile_fail("tests/ui/missing_file.rs");
    cases.compile_fail("tests/ui/invalid_wgsl.rs");
    cases.compile_fail("tests/ui/unknown_option.rs");
    cases.compile_fail("tests/ui/contradiction.rs");
    cases.compile_fail("tests/ui/strict_warning.rs");

    cases.compile_fail("tests/ui/module_padded_matrix.rs");
    cases.compile_fail("tests/ui/module_padded_array.rs");
    cases.compile_fail("tests/ui/module_bytemuck_elsewhere.rs");
}
