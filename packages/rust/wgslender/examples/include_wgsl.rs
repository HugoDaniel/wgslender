//! A shader checked and shrunk while this example was compiled.
//!
//! ```text
//! cargo run -p wgslender --example include_wgsl
//! ```
//!
//! Every constant below is a `&'static str` the macro produced during `cargo
//! build`, which is the whole argument for it: the shader is validated on the
//! machine that made the mistake rather than on the one that runs the program,
//! and the bytes in the binary are already the small ones.
//!
//! The other thing to take from here is the path rule. This file lives in
//! `wgslender/examples/`, and the paths it writes start at `tests/` — because
//! **a relative path resolves against the crate root, not against the file the
//! macro is written in**. That is not a preference: a proc-macro is handed
//! tokens, and on stable Rust it cannot ask which file they came from.

use wgslender::{include_wgsl, version};

/// The file as written, embedded by the standard library: no check, no
/// shrinking, and nothing said about it until something creates a pipeline.
const AS_WRITTEN: &str = include_str!("../tests/fixtures/demo.wgsl");

/// The same file, validated and minified at compile time. A `const`, because
/// the expansion is a string literal and goes wherever one goes.
const EMBEDDED: &str = include_wgsl!("tests/fixtures/demo.wgsl");

/// Checked but not shrunk — the option to reach for when something else is
/// going to read the text, or when a diff of it has to stay legible.
const CHECKED_ONLY: &str = include_wgsl!("tests/fixtures/demo.wgsl", minify = false);

/// Shrunk, except for one name a host program is going to look for.
const KEEPING_A_NAME: &str = include_wgsl!("tests/fixtures/demo.wgsl", keep_names = ["luminance"]);

fn main() {
    what_arrives();
    options();
    mistakes();

    // Which library did all of that: the version of the Zig sources this
    // binary was linked against, not the version of the crate.
    println!("\nlibwgslender {}", version());
}

/// The three constants, and the one difference between two of them that is not
/// a difference in size.
fn what_arrives() {
    heading("1. the same file, three ways");

    for (label, text) in [
        ("include_str!", AS_WRITTEN),
        ("include_wgsl!(minify = false)", CHECKED_ONLY),
        ("include_wgsl!", EMBEDDED),
    ] {
        println!("{label:<32}{:>6} bytes", text.len());
    }

    println!(
        "\nThe first two are byte-identical: {}.",
        AS_WRITTEN == CHECKED_ONLY
    );
    println!(
        "\nSo the middle row buys nothing you can measure here, and everything you\n\
         cannot: the file went through the validator on the way in. What the third\n\
         row went through as well is the minifier, and that is what the binary\n\
         carries:\n\
         \n\
         {EMBEDDED}"
    );

    println!(
        "\nThe expansion also contains an `include_bytes!` of the resolved path that\n\
         nothing reads, so that the compiler records the dependency: editing\n\
         `tests/fixtures/demo.wgsl` rebuilds this example."
    );
}

/// One option, and what makes an option list worth having.
fn options() {
    heading("2. options");

    println!(
        "{:<49}{:>4} bytes   luminance survives: {}",
        "include_wgsl!(path)",
        EMBEDDED.len(),
        EMBEDDED.contains("luminance"),
    );
    println!(
        "{:<49}{:>4} bytes   luminance survives: {}",
        "include_wgsl!(path, keep_names = [\"luminance\"])",
        KEEPING_A_NAME.len(),
        KEEPING_A_NAME.contains("luminance"),
    );

    println!(
        "\nThe full table is on the macro's own page: `minify`, `validate`, `strict`,\n\
         `keep_names`, and every `MinifyOptions` boolean under its own name. Two of\n\
         them together can be nonsense rather than merely redundant, and the macro\n\
         says so instead of picking one — `keep_names` beside `minify = false` names\n\
         something no minifier is going to rename, and fails the build:\n\
         \n\
         \x20   error: `keep_names` has no effect together with `minify = false`\n\
         \n\
         which is a mistake found while the option was being written rather than a\n\
         name that quietly did not survive."
    );
}

/// What a shader with something wrong with it does to the build.
fn mistakes() {
    heading("3. a mistake is a failed build");

    println!(
        "A shader that does not validate stops `cargo build`, carrying the library's\n\
         own diagnostic — position, code and message — up into the Rust error and\n\
         pointing at the path literal that named it:\n\
         \n\
         \x20   error: blur.wgsl is not valid WGSL\n\
         \x20          blur.wgsl:6:13: error[E0100]:\n\
         \x20              use of undeclared identifier 'undeclared_variable'\n\
         \x20    --> src/pipeline.rs:7:22\n\
         \n\
         That is the shape of it, with the paths shortened and one line wrapped to\n\
         fit; the real one, against this crate's own broken fixture, is pinned byte\n\
         for byte in `wgslender/tests/ui/invalid_wgsl.stderr`.\n\
         \n\
         `strict = true` promotes warnings to the same treatment, and\n\
         `validate = false` opts out entirely — which is what a shader fragment\n\
         needs, since a file that only makes sense once something concatenates it\n\
         cannot be type-checked on its own."
    );
}

/// A section rule, so three sections of output read as three sections.
fn heading(title: &str) {
    println!("\n{title}");
    println!("{}", "-".repeat(title.chars().count()));
}
