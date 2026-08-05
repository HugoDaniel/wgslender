//! A shader turned into Rust while this example was compiled: the source, the
//! slots, and a struct per buffer that is already laid out the way the GPU will
//! read it.
//!
//! ```text
//! cargo run -p wgslender --example wgsl_module
//! ```
//!
//! Everything printed below was worked out by `cargo build`, not at run time.
//! A real program spends the same constants on `create_bind_group_layout` and
//! writes `bytemuck::bytes_of(&scene)` straight into a buffer — no serialising,
//! no matching offsets by hand against the shader.

use core::mem::offset_of;

wgslender::wgsl_module!(pub scene, "tests/fixtures/layouts.wgsl");

fn main() {
    println!("shader     {} bytes, minified", scene::SOURCE.len());
    println!(
        "entry      {} @workgroup_size{:?}",
        scene::ENTRY_TICK,
        scene::ENTRY_TICK_WORKGROUP_SIZE,
    );
    println!(
        "uniform    @group({}) @binding({})",
        scene::bindings::SCENE.group,
        scene::bindings::SCENE.binding,
    );
    println!(
        "storage    @group({}) @binding({})",
        scene::bindings::INSTANCES.group,
        scene::bindings::INSTANCES.binding,
    );
    println!();

    // The uniform block, built the way a frame would build it. `new` takes the
    // shader's fields; the padding between them is the shader's business.
    let uniforms = scene::Scene::new(
        IDENTITY,
        [[1.0, 0.0], [0.0, 1.0]],
        scene::Material::new([0.9, 0.8, 0.7], 1.5),
        1,
        0,
        [1920.0, 1080.0],
    );
    println!("Scene      {} bytes to upload", size_of_val(&uniforms));
    for (field, at) in [
        ("view", offset_of!(scene::Scene, view)),
        ("scale", offset_of!(scene::Scene, scale)),
        ("material", offset_of!(scene::Scene, material)),
        ("count", offset_of!(scene::Scene, count)),
        ("kind", offset_of!(scene::Scene, kind)),
        ("offset", offset_of!(scene::Scene, offset)),
    ] {
        println!("           {field:<9} at byte {at:>3}");
    }
    println!("           count reads back as {}", uniforms.count);
    println!();

    // The storage buffer's header is a struct; its tail is not, because how many
    // elements follow is not known until the host allocates the buffer.
    println!(
        "Instances  {} bytes of header, then as many `items` as you allocate, \
         from byte {}",
        size_of::<scene::Instances>(),
        scene::Instances::ITEMS_OFFSET,
    );
}

/// A 4×4 identity, spelled the way the generated field is typed: four columns.
const IDENTITY: [[f32; 4]; 4] = [
    [1.0, 0.0, 0.0, 0.0],
    [0.0, 1.0, 0.0, 0.0],
    [0.0, 0.0, 1.0, 0.0],
    [0.0, 0.0, 0.0, 1.0],
];
