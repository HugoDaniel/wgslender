//! Reflection, as a table. A new scenario is a row.
//!
//! Every number here was read off the library first — `structs.Params` is 16
//! bytes aligned to 8 with fields at 0/8/12 because that is what wgslender
//! computes for the demo fixture, not because the test decided so.
//!
//! Every test is skipped under miri: they call into a static library compiled
//! from Zig, which miri cannot interpret.

mod common;

use wgslender_core::{AccessMode, AddressSpace, Reflection, ShaderStage, reflect, reflect_json};

/// One reflection scenario.
struct Case {
    /// Reported when the row fails.
    name: &'static str,
    /// WGSL handed to the reflector.
    source: &'static str,
    /// Receives the parsed reflection.
    check: fn(&Reflection),
}

fn cases() -> Vec<Case> {
    let mut cases = binding_cases();
    cases.extend(layout_cases());
    cases.extend(entry_point_cases());
    cases.extend(degenerate_cases());
    cases
}

/// The four binding kinds and how they are described.
fn binding_cases() -> Vec<Case> {
    vec![
        Case {
            name: "every binding is reported with its group, slot and space",
            source: common::DEMO,
            check: |reflection| {
                assert_eq!(reflection.version, 2);
                assert!(reflection.errors.is_empty(), "{:?}", reflection.errors);
                let found: Vec<_> = reflection
                    .bindings
                    .iter()
                    .map(|b| (b.group, b.binding, b.name.as_str(), b.address_space))
                    .collect();
                assert_eq!(
                    found,
                    vec![
                        (0, 0, "params", AddressSpace::Uniform),
                        (0, 1, "data", AddressSpace::Storage),
                        (1, 0, "tex", AddressSpace::Handle),
                        (1, 1, "samp", AddressSpace::Handle),
                    ]
                );
            },
        },
        Case {
            name: "only a buffer binding carries an access mode and a layout",
            source: common::DEMO,
            check: |reflection| {
                let modes: Vec<_> = reflection
                    .bindings
                    .iter()
                    .map(|b| (b.name.as_str(), b.access_mode, b.layout.is_some()))
                    .collect();
                assert_eq!(
                    modes,
                    vec![
                        ("params", None, true),
                        ("data", Some(AccessMode::ReadWrite), false),
                        ("tex", None, false),
                        ("samp", None, false),
                    ],
                    "a runtime-sized array has no layout, and a uniform has no access mode"
                );
            },
        },
        Case {
            name: "reflecting alone maps every name to itself",
            source: common::DEMO,
            check: |reflection| {
                for binding in &reflection.bindings {
                    assert_eq!(
                        binding.name, binding.name_mapped,
                        "nothing was renamed, so the mapping is the identity"
                    );
                    assert_eq!(binding.ty, binding.ty_mapped);
                }
            },
        },
    ]
}

/// What a struct costs in memory.
fn layout_cases() -> Vec<Case> {
    vec![
        Case {
            name: "the uniform binding's layout is the struct's own",
            source: common::DEMO,
            check: |reflection| {
                let Some(params) = reflection.bindings.first() else {
                    panic!("expected the uniform binding first")
                };
                let Some(layout) = params.layout.as_ref() else {
                    panic!("a uniform buffer must carry its layout")
                };
                let Some(declared) = reflection.structs.get("Params") else {
                    panic!("expected a Params entry in structs")
                };
                assert_eq!(layout.size, declared.size);
                assert_eq!(layout.alignment, declared.alignment);
                assert_eq!(layout.fields.len(), declared.fields.len());
            },
        },
        Case {
            name: "Params lays out as WGSL says it must",
            source: common::DEMO,
            check: |reflection| {
                let Some(params) = reflection.structs.get("Params") else {
                    panic!("expected a Params entry in structs")
                };
                assert_eq!(params.size, 16);
                assert_eq!(params.alignment, 8);
                let fields: Vec<_> = params
                    .fields
                    .iter()
                    .map(|f| (f.name.as_str(), f.ty.as_str(), f.offset, f.size))
                    .collect();
                assert_eq!(
                    fields,
                    vec![
                        ("resolution", "vec2f", 0, 8),
                        ("time", "f32", 8, 4),
                        ("frame", "u32", 12, 4),
                    ]
                );
            },
        },
    ]
}

/// What a pipeline can be built around.
fn entry_point_cases() -> Vec<Case> {
    vec![
        Case {
            name: "the compute entry point carries its workgroup size",
            source: common::DEMO,
            check: |reflection| {
                let entry_points: Vec<_> = reflection
                    .entry_points
                    .iter()
                    .map(|e| (e.name.as_str(), e.stage, e.workgroup_size))
                    .collect();
                assert_eq!(
                    entry_points,
                    vec![("main", ShaderStage::Compute, Some([8, 8, 1]))]
                );
            },
        },
        Case {
            name: "a vertex/fragment pair has no workgroup size",
            source: common::RENDER,
            check: |reflection| {
                let entry_points: Vec<_> = reflection
                    .entry_points
                    .iter()
                    .map(|e| (e.name.as_str(), e.stage, e.workgroup_size))
                    .collect();
                assert_eq!(
                    entry_points,
                    vec![
                        ("vs_main", ShaderStage::Vertex, None),
                        ("fs_main", ShaderStage::Fragment, None),
                    ]
                );
            },
        },
    ]
}

/// Sources that give the reflector nothing, or nothing it can parse.
fn degenerate_cases() -> Vec<Case> {
    vec![
        Case {
            name: "a semantically invalid shader still reflects cleanly",
            source: common::INVALID,
            check: |reflection| {
                assert!(
                    reflection.errors.is_empty(),
                    "reflection does not type-check, so an undeclared name is not its \
                     problem: {:?}",
                    reflection.errors
                );
                assert!(reflection.bindings.is_empty());
                assert!(reflection.entry_points.is_empty(), "no stage attribute");
            },
        },
        Case {
            name: "an unparseable shader reports the parse errors and reflects nothing",
            source: common::UNPARSEABLE,
            check: |reflection| {
                assert!(
                    !reflection.errors.is_empty(),
                    "the parser's complaints are the reflection's errors"
                );
                assert!(reflection.bindings.is_empty());
                assert!(reflection.structs.is_empty());
                assert!(reflection.entry_points.is_empty());
            },
        },
        Case {
            name: "an empty shader reflects to an empty envelope",
            source: "",
            check: |reflection| {
                assert_eq!(reflection.version, 2);
                assert!(reflection.errors.is_empty());
                assert!(reflection.bindings.is_empty());
                assert!(reflection.structs.is_empty());
                assert!(reflection.entry_points.is_empty());
            },
        },
    ]
}

#[test]
#[cfg(not(miri))]
fn reflection_table() {
    for case in cases() {
        println!("case: {}", case.name);
        let reflection = match reflect(case.source) {
            Ok(reflection) => reflection,
            Err(err) => panic!("{}: reflect failed: {err}", case.name),
        };
        (case.check)(&reflection);
    }
}

/// The typed view is a subset. Everything it leaves out is still reachable as
/// the raw envelope, which is the whole reason `reflect_json` exists.
#[test]
#[cfg(not(miri))]
fn reflect_json_carries_the_keys_the_typed_view_omits() {
    let Ok(json) = reflect_json(common::DEMO) else {
        panic!("reflect_json failed on the demo fixture")
    };
    for key in ["functions", "aliases", "overrides", "textures", "stableId"] {
        assert!(
            json.contains(key),
            "the raw envelope must still carry {key:?}"
        );
    }
}
