//! Reflection, as a table. A new scenario is a row.
//!
//! Every number here was read off the library first — `structs.Params` is 16
//! bytes aligned to 8 with fields at 0/8/12 because that is what wgslender
//! computes for the demo fixture, not because the test decided so.
//!
//! Every test is skipped under miri: they call into a static library compiled
//! from Zig, which miri cannot interpret.

mod common;

use wgslender_core::{
    AccessMode, AddressSpace, Binding, BindingSlot, Reflection, ShaderStage, TypeInfo, reflect,
    reflect_json,
};

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
    cases.extend(type_info_cases());
    cases.extend(composite_type_info_cases());
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
            name: "a binding hands out the slot it is bound to",
            source: common::DEMO,
            check: |reflection| {
                let slots: Vec<BindingSlot> =
                    reflection.bindings.iter().map(Binding::slot).collect();
                assert_eq!(
                    slots,
                    vec![
                        BindingSlot {
                            group: 0,
                            binding: 0
                        },
                        BindingSlot {
                            group: 0,
                            binding: 1
                        },
                        BindingSlot {
                            group: 1,
                            binding: 0
                        },
                        BindingSlot {
                            group: 1,
                            binding: 1
                        },
                    ],
                    "the pair a host program binds against, as one value"
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

/// A field's type, structured — what a code generator reads instead of parsing
/// `f.ty` back into a type.
///
/// The shader below is never compiled by anything: reflection parses, it does
/// not type-check, so a struct nothing binds still reports its layout.
const SHAPES: &str = "\
struct Material {
    tint: vec3f,
    strength: f32,
}

struct Frame {
    view: mat4x4f,
    material: Material,
    weights: array<f32, 4>,
    counter: atomic<u32>,
    tail: array<vec4f>,
}
";

/// The field of `Frame` by that name, or a panic naming what was there instead.
fn shape(reflection: &Reflection, field: &str) -> TypeInfo {
    let Some(frame) = reflection.structs.get("Frame") else {
        panic!("expected a Frame entry in structs")
    };
    let Some(found) = frame.fields.iter().find(|f| f.name == field) else {
        panic!("no field {field:?} in Frame")
    };
    let Some(info) = found.type_info.clone() else {
        panic!("field {field:?} came back without a type")
    };
    info
}

fn type_info_cases() -> Vec<Case> {
    vec![
        Case {
            name: "a scalar names itself",
            source: common::DEMO,
            check: |reflection| {
                let Some(params) = reflection.structs.get("Params") else {
                    panic!("expected a Params entry in structs")
                };
                let Some(time) = params.fields.iter().find(|f| f.name == "time") else {
                    panic!("no time field")
                };
                let Some(TypeInfo::Scalar {
                    name,
                    size,
                    alignment,
                }) = time.type_info.as_ref()
                else {
                    panic!("expected a scalar, got {:?}", time.type_info)
                };
                assert_eq!((name.as_str(), *size, *alignment), ("f32", 4, 4));
            },
        },
        Case {
            name: "a vector carries its width and its component type",
            source: common::DEMO,
            check: |reflection| {
                let Some(params) = reflection.structs.get("Params") else {
                    panic!("expected a Params entry in structs")
                };
                let Some(resolution) = params.fields.iter().find(|f| f.name == "resolution") else {
                    panic!("no resolution field")
                };
                let Some(TypeInfo::Vec {
                    width,
                    format,
                    size,
                    alignment,
                }) = resolution.type_info.as_ref()
                else {
                    panic!("expected a vector, got {:?}", resolution.type_info)
                };
                assert_eq!((*width, *size, *alignment), (2, 8, 8));
                assert!(
                    matches!(format.as_ref(), TypeInfo::Scalar { name, .. } if name == "f32"),
                    "got {format:?}"
                );
            },
        },
    ]
}

/// The kinds that are made of other kinds.
fn composite_type_info_cases() -> Vec<Case> {
    vec![
        Case {
            name: "a matrix carries the distance between its columns",
            source: SHAPES,
            check: |reflection| {
                let TypeInfo::Mat {
                    cols,
                    rows,
                    size,
                    alignment,
                    stride,
                    ..
                } = shape(reflection, "view")
                else {
                    panic!("expected a matrix")
                };
                assert_eq!((cols, rows), (4, 4));
                assert_eq!((size, alignment, stride), (64, 16, 16));
            },
        },
        Case {
            name: "a nested struct is a reference to a layout in the map",
            source: SHAPES,
            check: |reflection| {
                let TypeInfo::Struct {
                    name,
                    size,
                    alignment,
                } = shape(reflection, "material")
                else {
                    panic!("expected a struct reference")
                };
                assert_eq!((name.as_str(), size, alignment), ("Material", 16, 16));
                assert!(
                    reflection.structs.contains_key("Material"),
                    "the name is a key in structs, which is what makes it a reference"
                );
            },
        },
        Case {
            name: "a fixed-size array knows how many, a runtime-sized one does not",
            source: SHAPES,
            check: |reflection| {
                let TypeInfo::Array {
                    count,
                    size,
                    stride,
                    ..
                } = shape(reflection, "weights")
                else {
                    panic!("expected an array")
                };
                assert_eq!((count, size, stride), (Some(4), Some(16), 4));

                let TypeInfo::Array {
                    count,
                    size,
                    stride,
                    ..
                } = shape(reflection, "tail")
                else {
                    panic!("expected an array")
                };
                assert_eq!(
                    (count, size, stride),
                    (None, None, 16),
                    "how long the tail is, is the host's business at run time"
                );
            },
        },
        Case {
            name: "an atomic wraps the type it makes atomic",
            source: SHAPES,
            check: |reflection| {
                let TypeInfo::Atomic {
                    format,
                    size,
                    alignment,
                } = shape(reflection, "counter")
                else {
                    panic!("expected an atomic")
                };
                assert_eq!((size, alignment), (4, 4));
                assert!(
                    matches!(format.as_ref(), TypeInfo::Scalar { name, .. } if name == "u32"),
                    "got {format:?}"
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

/// A function's declared signature reaches the raw envelope too. Types are
/// spelled from the AST, so `vec2f` and `ptr<function, Element>` come back
/// exactly as written rather than resolved or elided.
#[test]
#[cfg(not(miri))]
fn reflect_json_reports_function_signatures() {
    let source = "struct Element { pos: vec2f }\n\
                  fn simplex(p: vec2f) -> f32 { return p.x + p.y; }\n\
                  fn step_k(e: ptr<function, Element>, dt: f32) { (*e).pos.x = dt; }\n";
    let Ok(json) = reflect_json(source) else {
        panic!("reflect_json failed on a kernel fragment")
    };
    for fragment in [
        r#""params":[{"name":"p","type":"vec2f""#,
        r#""returnType":"f32""#,
        r#""type":"ptr<function, Element>""#,
    ] {
        assert!(json.contains(fragment), "expected {fragment:?} in {json}");
    }
}

/// A name reflection cannot map to anything is reported as its own kind
/// rather than as a scalar of size zero. This crate does not type that kind —
/// it does not type pointers or handles either — so what matters here is that
/// the typed view still *deserializes*: `TypeInfo` is `#[serde(other)]`, so an
/// unfamiliar tag becomes [`TypeInfo::Unknown`] instead of failing the whole
/// reflection, which is what a stricter enum would have started doing.
#[test]
#[cfg(not(miri))]
fn an_unresolvable_type_does_not_break_the_typed_view() {
    let source = "struct S { m: Missing }\n\
                  @group(0) @binding(0) var<uniform> u: S;\n\
                  @compute @workgroup_size(1) fn e() { _ = u; }\n";

    let Ok(json) = reflect_json(source) else {
        panic!("reflect_json failed on an unresolvable member type")
    };
    assert!(
        json.contains(r#""kind":"unresolved","name":"Missing""#),
        "expected an unresolved typeInfo in {json}"
    );

    let Ok(reflection) = reflect(source) else {
        panic!("the typed view rejected an unresolvable type")
    };
    let field = &reflection.structs["S"].fields[0];
    assert_eq!(field.ty, "Missing", "the spelling survives as written");
    assert!(
        matches!(field.type_info, Some(TypeInfo::Unknown)),
        "an unresolved kind degrades to Unknown, not an error: {:?}",
        field.type_info,
    );
}
