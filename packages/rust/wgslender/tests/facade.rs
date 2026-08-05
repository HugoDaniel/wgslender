//! The facade's whole job is that these paths resolve.
//!
//! `wgslender-core` already holds the behavioral suites, so a row here calls
//! the library only far enough to prove the answer came from it rather than
//! from a stub. What the row really pins is the *spelling* —
//! `wgslender::minify`, `wgslender::refactor::rename`, `wgslender::Strictness`
//! — because that spelling is the crate's entire contract.
//!
//! Every test that calls the library is skipped under miri: it reaches a static
//! library compiled from Zig, which miri cannot interpret.

use wgslender::refactor::{
    Applied, ByteRange, Edit, IncludeDeclaration, RefactorError, Reference, StableId,
};
use wgslender::{
    AccessMode, AddressSpace, Binding, CompiledShader, Diagnostic, EntryPoint, Error, Field,
    LintConfig, LintFixOutcome, LintReport, MinifiedShader, MinifyOptions, Pack, Reflection,
    RuleSetting, Severity, ShaderStage, Strictness, StructLayout, Validation, Value, compile, lint,
    lint_fix, minify, minify_and_reflect, minify_with, reflect, reflect_json, validate, version,
};

/// Small enough that the expectations stay obvious, complete enough that every
/// family below has something to answer about.
const SHADER: &str = "\
struct Params {
    scale: f32,
}

@group(0) @binding(0) var<uniform> params: Params;

@compute @workgroup_size(1)
fn main() {
    let scaled = params.scale * 2.0;
}
";

/// One path through the facade, called for real.
struct Probe {
    /// The path exactly as a user writes it. Reported when the row fails.
    path: &'static str,
    /// Calls it, and panics with its own message on anything unexpected.
    call: fn(),
}

fn probes() -> Vec<Probe> {
    let mut probes = minify_probes();
    probes.extend(analysis_probes());
    probes.extend(refactor_probes());
    probes
}

fn minify_probes() -> Vec<Probe> {
    vec![
        Probe {
            path: "wgslender::minify",
            call: || {
                let Ok(minified) = minify(SHADER) else {
                    panic!("minify failed on the fixture")
                };
                assert!(minified.len() < SHADER.len());
            },
        },
        Probe {
            path: "wgslender::minify_with",
            call: || {
                let options = MinifyOptions::default().keep_names(["main"]);
                let Ok(minified) = minify_with(SHADER, &options) else {
                    panic!("minify_with failed on the fixture")
                };
                assert!(minified.contains("main"), "the kept name survived");
            },
        },
        Probe {
            path: "wgslender::minify_and_reflect",
            call: || {
                let Ok(shader) = minify_and_reflect(SHADER, &MinifyOptions::default()) else {
                    panic!("minify_and_reflect failed on the fixture")
                };
                assert_eq!(shader.original_size as usize, SHADER.len());
                assert_eq!(shader.reflection.bindings.len(), 1);
            },
        },
        Probe {
            path: "wgslender::compile",
            call: || {
                let Ok(compiled) = compile(SHADER, &MinifyOptions::default()) else {
                    panic!("compile failed on the fixture")
                };
                assert_eq!(
                    compiled.wasm.get(..4),
                    Some(b"\0asm".as_slice()),
                    "a wasm module starts with its magic number"
                );
            },
        },
    ]
}

fn analysis_probes() -> Vec<Probe> {
    vec![
        Probe {
            path: "wgslender::validate",
            call: || {
                let Ok(validation) = validate(SHADER, Strictness::Default) else {
                    panic!("validate failed on the fixture")
                };
                assert!(validation.valid, "{:?}", validation.diagnostics);
            },
        },
        Probe {
            path: "wgslender::lint",
            call: || {
                let config = LintConfig::default().extend(Pack::Recommended);
                let Ok(report) = lint(SHADER, &config) else {
                    panic!("lint failed on the fixture")
                };
                assert_eq!(report.error_count, 0, "{:?}", report.diagnostics);
            },
        },
        Probe {
            path: "wgslender::lint_fix",
            call: || {
                let config = LintConfig::default().extend(Pack::Recommended);
                let Ok(outcome) = lint_fix(SHADER, &config) else {
                    panic!("lint_fix failed on the fixture")
                };
                assert!(!outcome.fixed_source.is_empty());
            },
        },
        Probe {
            path: "wgslender::reflect",
            call: || {
                let Ok(reflection) = reflect(SHADER) else {
                    panic!("reflect failed on the fixture")
                };
                assert_eq!(reflection.version, 2);
                assert_eq!(reflection.bindings.len(), 1);
            },
        },
        Probe {
            path: "wgslender::reflect_json",
            call: || {
                let Ok(json) = reflect_json(SHADER) else {
                    panic!("reflect_json failed on the fixture")
                };
                assert!(json.contains("\"bindings\""));
            },
        },
        Probe {
            path: "wgslender::version",
            call: || {
                assert_eq!(version().split('.').count(), 3);
            },
        },
    ]
}

fn refactor_probes() -> Vec<Probe> {
    vec![
        Probe {
            path: "wgslender::refactor::find_references",
            call: || {
                let offset = offset_of(SHADER, "params:");
                let Ok(references) =
                    wgslender::refactor::find_references(SHADER, offset, IncludeDeclaration::Yes)
                else {
                    panic!("find_references failed on the fixture")
                };
                assert_eq!(references.len(), 2, "the declaration and the one read");
            },
        },
        Probe {
            path: "wgslender::refactor::rename",
            call: || {
                let offset = offset_of(SHADER, "params:");
                let Ok(edits) = wgslender::refactor::rename(SHADER, offset, "uniforms") else {
                    panic!("rename failed on the fixture")
                };
                assert_eq!(edits.len(), 2);
            },
        },
        Probe {
            path: "wgslender::refactor::stable_id_at_offset",
            call: || {
                let offset = offset_of(SHADER, "params:");
                let Ok(Some(id)) = wgslender::refactor::stable_id_at_offset(SHADER, offset) else {
                    panic!("no stable id at the declaration of params")
                };
                let Ok(Some(range)) = wgslender::refactor::locate_stable_id(SHADER, &id) else {
                    panic!("the id the library just handed out did not resolve")
                };
                assert_eq!(&SHADER[range.start as usize..range.end as usize], "params");
            },
        },
    ]
}

/// The byte offset where `needle` starts in `source`.
fn offset_of(source: &str, needle: &str) -> u32 {
    let Some(offset) = source.find(needle) else {
        panic!("the fixture must contain {needle:?}")
    };
    let Ok(offset) = u32::try_from(offset) else {
        panic!("the fixture is far too small for this to overflow")
    };
    offset
}

#[test]
#[cfg(not(miri))]
fn every_facade_path_resolves_and_answers() {
    for probe in probes() {
        println!("path: {}", probe.path);
        (probe.call)();
    }
}

/// The re-exported type surface, named in one place.
///
/// Nothing reads these fields: the struct exists so that a type dropped from
/// the facade fails the *build*, which a runtime assertion could never do.
#[allow(dead_code)]
struct Surface {
    minified: MinifiedShader,
    compiled: CompiledShader,
    options: MinifyOptions,
    validation: Validation,
    diagnostic: Diagnostic,
    severity: Severity,
    strictness: Strictness,
    lint_config: LintConfig,
    lint_report: LintReport,
    lint_fix_outcome: LintFixOutcome,
    pack: Pack,
    rule_setting: RuleSetting,
    value: Value,
    reflection: Reflection,
    binding: Binding,
    entry_point: EntryPoint,
    field: Field,
    struct_layout: StructLayout,
    shader_stage: ShaderStage,
    address_space: AddressSpace,
    access_mode: AccessMode,
    error: Error,
    stable_id: StableId,
    byte_range: ByteRange,
    edit: Edit,
    reference: Reference,
    applied: Applied,
    include_declaration: IncludeDeclaration,
    refactor_error: RefactorError,
}

/// The facade re-exports; it does not redefine.
///
/// Assigning across the two crate names only compiles if each pair is one type,
/// which is what keeps a well-meaning wrapper from being introduced here later.
#[test]
fn a_facade_type_is_the_implementation_crate_type() {
    let strictness: Strictness = wgslender_core::Strictness::Strict;
    let options: MinifyOptions = wgslender_core::MinifyOptions::default();
    let pack: Pack = wgslender_core::Pack::Recommended;
    let id: StableId = wgslender_core::refactor::StableId::new("v1:fn:main");

    assert_eq!(strictness, Strictness::Strict);
    assert_eq!(format!("{pack}"), "@wgslender/recommended");
    assert_eq!(id.as_str(), "v1:fn:main");
    assert!(format!("{options:?}").starts_with("MinifyOptions"));
}
