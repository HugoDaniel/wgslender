//! What `wgsl_module!` generates.
//!
//! Every number below was read off the library before it was written down: the
//! fixtures were reflected with `wgslender reflect` and the offsets copied from
//! its answer. The generated code asserts the same numbers about itself in a
//! `const _: ()` block, so a mis-mapping fails to *compile* rather than
//! reaching this file — which is the point of generating the proofs. These rows
//! are the second opinion: they check that what was generated is what a caller
//! would want to reach for.
//!
//! Behind the `macros` feature, like the macro they exercise.
#![cfg(feature = "macros")]

use core::mem::{align_of, offset_of, size_of};

use wgslender::BindingSlot;

// The demo fixture: one struct, two bindings, one compute entry point. (A `//`
// comment rather than a doc comment: the module these become is the macro's to
// document, and rustdoc says so.)
wgslender::wgsl_module!(pub demo, "tests/fixtures/demo.wgsl");

// The layout fixture, with the `bytemuck` derives asked for.
wgslender::wgsl_module!(pub layouts, "tests/fixtures/layouts.wgsl", bytemuck = true);

// No visibility at all, which is the other half of the `<vis> <name>` grammar.
wgslender::wgsl_module!(private_demo, "tests/fixtures/demo.wgsl", minify = false);

/// One thing the macro is expected to have generated.
struct Case {
    /// Reported when the row fails.
    name: &'static str,
    /// Reads the generated items; panics with its own message.
    check: fn(),
}

fn cases() -> Vec<Case> {
    let mut cases = constant_cases();
    cases.extend(layout_cases());
    cases.extend(construction_cases());
    cases
}

/// The constants a host program binds against.
fn constant_cases() -> Vec<Case> {
    vec![
        Case {
            name: "the module carries the minified shader",
            check: || {
                assert!(demo::SOURCE.contains("@compute"), "{}", demo::SOURCE);
                assert!(demo::SOURCE.contains("fn main"));
                assert!(demo::SOURCE.len() < 500, "the source is minified");
            },
        },
        Case {
            name: "minify = false reaches the generated source too",
            check: || {
                assert_eq!(private_demo::SOURCE, include_str!("fixtures/demo.wgsl"));
            },
        },
        Case {
            name: "every binding becomes a slot constant",
            check: || {
                assert_eq!(
                    demo::bindings::PARAMS,
                    BindingSlot {
                        group: 0,
                        binding: 0
                    }
                );
                assert_eq!(
                    demo::bindings::DATA,
                    BindingSlot {
                        group: 0,
                        binding: 1
                    }
                );
                assert_eq!(
                    layouts::bindings::INSTANCES,
                    BindingSlot {
                        group: 2,
                        binding: 3
                    },
                    "the numbers come from the shader, not from the order"
                );
            },
        },
        Case {
            name: "every entry point becomes a name constant",
            check: || {
                assert_eq!(demo::ENTRY_MAIN, "main");
                assert_eq!(demo::ENTRY_MAIN_WORKGROUP_SIZE, [8, 8, 1]);
                assert_eq!(layouts::ENTRY_TICK, "tick");
                assert_eq!(layouts::ENTRY_TICK_WORKGROUP_SIZE, [16, 1, 1]);
            },
        },
    ]
}

/// The struct layouts, which are the reason this macro exists.
fn layout_cases() -> Vec<Case> {
    vec![
        Case {
            name: "a struct with tail padding is the size WGSL says",
            check: || {
                assert_eq!(size_of::<demo::Params>(), 16);
                assert_eq!(align_of::<demo::Params>(), 8);
                assert_eq!(offset_of!(demo::Params, resolution), 0);
                assert_eq!(offset_of!(demo::Params, time), 8);
            },
        },
        Case {
            name: "matrices, nested structs and vectors all land where reflect put them",
            check: || {
                assert_eq!(size_of::<layouts::Scene>(), 112);
                assert_eq!(align_of::<layouts::Scene>(), 16);
                assert_eq!(offset_of!(layouts::Scene, view), 0);
                assert_eq!(offset_of!(layouts::Scene, scale), 64);
                assert_eq!(offset_of!(layouts::Scene, material), 80);
                assert_eq!(offset_of!(layouts::Scene, count), 96);
                assert_eq!(offset_of!(layouts::Scene, kind), 100);
                assert_eq!(offset_of!(layouts::Scene, offset), 104);
            },
        },
        Case {
            name: "a vec3 field is three floats in a struct WGSL rounds up to sixteen",
            check: || {
                assert_eq!(size_of::<layouts::Material>(), 16);
                assert_eq!(align_of::<layouts::Material>(), 16);
                assert_eq!(size_of::<[f32; 3]>(), 12, "the field itself is not padded");
                assert_eq!(offset_of!(layouts::Material, strength), 12);
            },
        },
        Case {
            name: "a runtime-sized tail is an offset, not a field",
            check: || {
                assert_eq!(
                    size_of::<layouts::Instances>(),
                    32,
                    "the generated struct is the fixed part"
                );
                assert_eq!(offset_of!(layouts::Instances, weights), 0);
                assert_eq!(offset_of!(layouts::Instances, count), 16);
                assert_eq!(
                    layouts::Instances::ITEMS_OFFSET,
                    32,
                    "where the tail begins, for the caller to write past"
                );
            },
        },
        Case {
            name: "a buffer that is nothing but a tail has a fixed part of nothing",
            check: || {
                assert_eq!(
                    size_of::<layouts::Trail>(),
                    0,
                    "a storage buffer with no header is an ordinary shape, and this is what \
                     it comes to"
                );
                assert_eq!(
                    align_of::<layouts::Trail>(),
                    8,
                    "a `vec2f` element wants 8, and the empty struct still carries it"
                );
                assert_eq!(layouts::Trail::POINTS_OFFSET, 0);
            },
        },
    ]
}

/// Building one, and handing the bytes to something that wants them.
fn construction_cases() -> Vec<Case> {
    vec![
        Case {
            name: "new() sets the fields and zeroes the padding",
            check: || {
                // Compared as bits: these floats were stored and read back, not
                // computed, so anything but the same bits is a real failure.
                let params = demo::Params::new([1920.0, 1080.0], 0.5);
                assert_eq!(
                    params.resolution.map(f32::to_bits),
                    [1920.0f32, 1080.0].map(f32::to_bits)
                );
                assert_eq!(params.time.to_bits(), 0.5f32.to_bits());
                assert_eq!(params._pad0, [0; 4]);
            },
        },
        Case {
            name: "new() is const, so a uniform can be a constant",
            check: || {
                const ORIGIN: demo::Params = demo::Params::new([0.0, 0.0], 0.0);
                assert_eq!(ORIGIN.resolution.map(f32::to_bits), [0, 0]);
            },
        },
        Case {
            name: "a field WGSL allows and Rust reserves is written raw",
            check: || {
                let channels = layouts::Channels::new(1.0, [2.0, 3.0], 4);
                assert_eq!(channels.r#in.to_bits(), 1.0f32.to_bits());
                assert_eq!(channels.r#dyn, 4);
                assert_eq!(
                    offset_of!(layouts::Channels, r#box),
                    8,
                    "the raw name reaches offset_of! too, which is where it would break"
                );
            },
        },
        Case {
            name: "bytemuck = true makes the struct plain old data",
            check: || {
                let scene = layouts::Scene::new(
                    [[0.0; 4]; 4],
                    [[0.0; 2]; 2],
                    layouts::Material::new([1.0, 1.0, 1.0], 2.0),
                    7,
                    -1,
                    [4.0, 3.0],
                );
                let bytes: &[u8] = bytemuck::bytes_of(&scene);
                assert_eq!(bytes.len(), 112, "one buffer write, no serialisation");
                assert_eq!(&bytes[96..100], &7u32.to_ne_bytes());
            },
        },
    ]
}

#[test]
fn generated_module_table() {
    for case in cases() {
        println!("case: {}", case.name);
        (case.check)();
    }
}

/// The macro is not a second minifier: what it generated at compile time is
/// what the library produces now, byte for byte.
///
/// Skipped under miri, which cannot interpret the static library the run-time
/// call reaches.
#[test]
#[cfg(not(miri))]
fn the_generated_source_matches_the_run_time_call() {
    let Ok(at_run_time) = wgslender::minify(include_str!("fixtures/demo.wgsl")) else {
        panic!("minifying the fixture at run time failed")
    };
    assert_eq!(demo::SOURCE, at_run_time);
}
