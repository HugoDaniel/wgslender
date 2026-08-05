//! Properties: what has to hold for *every* input, not for the chosen ones.
//!
//! The other suites in this directory pin exact answers on fixtures. These ask
//! a weaker question of a far larger set of inputs, and the two catch different
//! things: a table catches a wrong answer, a property catches an answer that
//! stops existing — a panic on the far side of `extern "C"`, or a minifier
//! whose own output the validator will not take back.
//!
//! A failing case is written to `props.proptest-regressions` beside this file
//! and replayed first on the next run, so a rare seed is found once and then
//! kept. Commit it when one appears.
//!
//! Every test here calls the static library compiled from Zig, which miri
//! cannot interpret, so the file is skipped under it entirely.
#![cfg(not(miri))]

mod common;

use proptest::prelude::*;
use wgslender_core::{
    LintConfig, MinifyOptions, Pack, Strictness, lint, minify, minify_with, reflect, validate,
};

/// The fixtures that are valid WGSL, each named for the failure message.
const VALID: &[(&str, &str)] = &[
    ("demo", common::DEMO),
    ("render", common::RENDER),
    ("warning", common::WARNING),
    ("unused", common::UNUSED),
];

/// Printable ASCII and newlines, up to 4 KiB.
///
/// Built from characters rather than a regex so that the newline is common
/// enough to matter: a lexer that only ever sees one line is a lexer whose
/// line counting is never exercised.
fn arbitrary_text() -> impl Strategy<Value = String> {
    let character = prop_oneof![
        9 => proptest::char::range(' ', '~'),
        1 => Just('\n'),
    ];
    proptest::collection::vec(character, 0..4096)
        .prop_map(|characters| characters.into_iter().collect())
}

/// Pieces of real WGSL, drawn at random and joined.
///
/// Arbitrary ASCII nearly always dies at the first token, which tests the
/// lexer and nothing behind it. This gets into the parser — unbalanced braces,
/// a struct that never ends, an attribute on nothing — which is where there is
/// something to fall over.
const FRAGMENTS: &[&str] = &[
    "@group(0) @binding(0)",
    "@group(1) @binding(7)",
    "var<storage, read_write>",
    "var<uniform>",
    "var<private>",
    "struct S {",
    "field: vec3f,",
    "}",
    "fn helper(",
    "x: f32",
    ") -> f32 {",
    "@compute @workgroup_size(64)",
    "@vertex",
    "@builtin(position)",
    "let value =",
    "var accumulator =",
    "return",
    ";",
    "{",
    "}",
    "(",
    ")",
    "data[id.x]",
    "*",
    "+",
    "2.0",
    "0x1p+2",
    "4294967296",
    "u32",
    "array<f32, 4>",
    "array<f32>",
    "ptr<function, f32>",
    "atomic<u32>",
    "mat4x4f",
    "if condition {",
    "} else {",
    "loop {",
    "break;",
    "continue;",
    "discard;",
    "// a line comment\n",
    "/* a /* nested */ comment */",
    "alias T =",
    "const_assert",
    "enable f16;",
    "diagnostic(off, derivative_uniformity);",
    "😀",
];

/// A soup of [`FRAGMENTS`], occasionally deep enough to be a real shader.
fn wgsl_soup() -> impl Strategy<Value = String> {
    proptest::collection::vec(proptest::sample::select(FRAGMENTS), 0..64)
        .prop_map(|parts| parts.join(" "))
}

/// A point in the option space, over the eight flags that change the output.
fn options() -> impl Strategy<Value = MinifyOptions> {
    proptest::array::uniform8(any::<bool>()).prop_map(|flags| {
        let [
            whitespace,
            identifiers,
            syntax,
            shaking,
            mangle,
            preserve,
            sorting,
            scoped,
        ] = flags;
        MinifyOptions::default()
            .minify_whitespace(whitespace)
            .minify_identifiers(identifiers)
            .minify_syntax(syntax)
            .tree_shaking(shaking)
            .mangle_external_bindings(mangle)
            .preserve_uniform_struct_types(preserve)
            .sort_declarations(sorting)
            .scope_local_rename(scoped)
    })
}

/// Calls every entry point and discards every answer.
///
/// Not "answers correctly": `Ok` and `Err` are both fine here, and a shader the
/// library rejects is an `Ok` carrying the rejection. What is not fine is the
/// process going away, which is what a panic across the FFI boundary would do.
fn survives(source: &str) {
    let _ = minify(source);
    let _ = validate(source, Strictness::Default);
    let _ = validate(source, Strictness::Strict);
    let _ = reflect(source);
    let _ = lint(source, &LintConfig::default().extend(Pack::Recommended));
}

proptest! {
    // Bounded on purpose: this suite runs on demand next to everything else,
    // and a gate nobody waits for is a gate nobody runs.
    #![proptest_config(ProptestConfig { cases: 256, ..ProptestConfig::default() })]

    /// Text that is not WGSL is still an input, and every call is total.
    #[test]
    fn arbitrary_text_is_answered(source in arbitrary_text()) {
        survives(&source);
    }

    /// The same, for input shaped enough to reach the parser.
    #[test]
    fn wgsl_shaped_text_is_answered(source in wgsl_soup()) {
        survives(&source);
    }

    /// Minifying twice is minifying once.
    ///
    /// The second pass is handed text that is already as short as this option
    /// set makes it, so anything it changes is the minifier disagreeing with
    /// itself — a rename that depends on the names it just chose, say.
    #[test]
    fn minification_is_idempotent(
        (name, source) in proptest::sample::select(VALID),
        options in options(),
    ) {
        let Ok(once) = minify_with(source, &options) else {
            return Err(TestCaseError::fail(format!("minifying {name} failed")));
        };
        let Ok(twice) = minify_with(&once, &options) else {
            return Err(TestCaseError::fail(format!("re-minifying {name} failed")));
        };
        // Arguments spelled out rather than captured: these macros build their
        // message with `concat!`, and `format_args!` will not reach into the
        // surrounding scope from an expanded string.
        prop_assert_eq!(&once, &twice, "{} did not settle after one pass", name);
    }

    /// What the minifier writes, the validator takes back.
    ///
    /// The one property that would matter at run time rather than at build
    /// time: a shader that stops validating after minification is a pipeline
    /// that fails to create.
    #[test]
    fn minified_shaders_still_validate(
        (name, source) in proptest::sample::select(VALID),
        options in options(),
    ) {
        let Ok(minified) = minify_with(source, &options) else {
            return Err(TestCaseError::fail(format!("minifying {name} failed")));
        };
        let Ok(validation) = validate(&minified, Strictness::Default) else {
            return Err(TestCaseError::fail(format!("validating minified {name} failed")));
        };
        prop_assert!(
            validation.valid,
            "minified {} stopped validating: {:?}",
            name,
            validation.diagnostics
        );
    }
}
