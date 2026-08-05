//! Binary shader compilation, as a table. A new scenario is a row.
//!
//! What counts as a failure here was pinned against the library: a shader that
//! parses always compiles, even when it makes no semantic sense, because the
//! compiler never type-checks. Only a parse error yields no module.
//!
//! Every test is skipped under miri: they call into a static library compiled
//! from Zig, which miri cannot interpret.

mod common;

use wgslender_core::{CompiledShader, Error, MinifyOptions, compile};

/// The four bytes every WebAssembly module starts with.
const WASM_MAGIC: &[u8] = b"\0asm";

/// One compilation scenario.
struct Case {
    /// Reported when the row fails.
    name: &'static str,
    /// WGSL handed to the compiler.
    source: &'static str,
    /// Receives `(source, outcome)`.
    check: fn(&str, Result<CompiledShader, Error>),
}

fn cases() -> Vec<Case> {
    vec![
        Case {
            name: "the demo shader compiles to a smaller wasm module",
            source: common::DEMO,
            check: |source, outcome| {
                let Ok(compiled) = outcome else {
                    panic!("the demo fixture must compile")
                };
                assert!(compiled.wasm.starts_with(WASM_MAGIC), "not a wasm module");
                assert_eq!(
                    compiled.original_size as usize,
                    source.len(),
                    "original_size is the size of the input, not of the module"
                );
                assert!(
                    compiled.wasm.len() < source.len(),
                    "a {}-byte shader compiled to {} bytes",
                    source.len(),
                    compiled.wasm.len()
                );
            },
        },
        Case {
            name: "a vertex/fragment pair compiles too",
            source: common::RENDER,
            check: |_, outcome| {
                let Ok(compiled) = outcome else {
                    panic!("the render fixture must compile")
                };
                assert!(compiled.wasm.starts_with(WASM_MAGIC));
            },
        },
        Case {
            name: "a semantically invalid shader still compiles",
            source: common::INVALID,
            check: |_, outcome| {
                let Ok(compiled) = outcome else {
                    panic!(
                        "the compiler does not type-check, so an undeclared name \
                         must not stop it"
                    )
                };
                assert!(compiled.wasm.starts_with(WASM_MAGIC));
            },
        },
        Case {
            name: "an empty shader compiles to a module that expands to nothing",
            source: "",
            check: |_, outcome| {
                let Ok(compiled) = outcome else {
                    panic!("an empty shader is still a shader")
                };
                assert!(compiled.wasm.starts_with(WASM_MAGIC));
                assert_eq!(compiled.original_size, 0);
            },
        },
        Case {
            name: "an unparseable shader yields diagnostics instead of a module",
            source: common::UNPARSEABLE,
            check: |_, outcome| {
                let Err(Error::Compile(diagnostics)) = outcome else {
                    panic!("expected a compile error, got {outcome:?}")
                };
                let Some(first) = diagnostics.first() else {
                    panic!("a compile error must say what went wrong")
                };
                assert!(first.line >= 1 && first.column >= 1, "{first:?}");
                assert!(!first.message.is_empty());
            },
        },
    ]
}

#[test]
#[cfg(not(miri))]
fn compilation_table() {
    for case in cases() {
        println!("case: {}", case.name);
        (case.check)(case.source, compile(case.source, &MinifyOptions::default()));
    }
}

/// The options are not decoration: they change the text the module expands to,
/// and so the module itself.
#[test]
#[cfg(not(miri))]
fn options_change_the_generated_module() {
    let Ok(default) = compile(common::DEMO, &MinifyOptions::default()) else {
        panic!("the demo fixture must compile")
    };
    let verbose = MinifyOptions::default().minify_identifiers(false);
    let Ok(unrenamed) = compile(common::DEMO, &verbose) else {
        panic!("the demo fixture must compile with identifiers kept")
    };
    assert_ne!(default.wasm, unrenamed.wasm);
    assert!(
        default.wasm.len() < unrenamed.wasm.len(),
        "renaming identifiers must produce the smaller module"
    );
    assert_eq!(
        default.original_size, unrenamed.original_size,
        "the input did not change"
    );
}
