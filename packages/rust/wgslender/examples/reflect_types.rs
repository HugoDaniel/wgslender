//! What a host program needs to know about a shader, without parsing it: the
//! binding table, the memory layout of every struct it declares, and the entry
//! points a pipeline is built around.
//!
//! ```text
//! cargo run -p wgslender --example reflect_types
//! ```

use core::str::FromStr as _;

use wgslender::{Error, Value, reflect, reflect_json};

/// Two uniform blocks with different alignment stories, and two entry points.
const SHADER: &str = "\
struct Camera {
    view_projection: mat4x4f,
    position: vec3f,
    exposure: f32,
}

struct Material {
    tint: vec4f,
    roughness: f32,
    metallic: f32,
}

@group(0) @binding(0) var<uniform> camera: Camera;
@group(1) @binding(0) var<uniform> material: Material;

@vertex
fn vs_main(@location(0) position: vec3f) -> @builtin(position) vec4f {
    return camera.view_projection * vec4f(position, 1.0);
}

@fragment
fn fs_main() -> @location(0) vec4f {
    return material.tint * camera.exposure;
}
";

fn main() -> Result<(), Error> {
    let reflection = reflect(SHADER)?;

    println!("bindings:");
    for binding in &reflection.bindings {
        println!(
            "  @group({}) @binding({}) {}: {} ({})",
            binding.group, binding.binding, binding.name, binding.ty, binding.address_space,
        );
    }

    // Sizes, alignments and offsets follow WGSL's own layout rules (§6.2.10),
    // which is what makes them safe to mirror in a `#[repr(C)]` Rust struct.
    println!("\nstruct layouts:");
    for (name, layout) in &reflection.structs {
        println!(
            "  {name}: {} bytes, aligned to {}",
            layout.size, layout.alignment,
        );
        for field in &layout.fields {
            println!(
                "    +{:<3} {:<16} {:<10} {} bytes",
                field.offset, field.name, field.ty, field.size,
            );
        }
    }

    println!("\nentry points:");
    for entry_point in &reflection.entry_points {
        match entry_point.workgroup_size {
            Some([x, y, z]) => println!(
                "  {} ({}) @workgroup_size({x}, {y}, {z})",
                entry_point.name, entry_point.stage
            ),
            None => println!("  {} ({})", entry_point.name, entry_point.stage),
        }
    }

    the_untyped_answer()
}

/// The same call, unparsed — for the three fields the structs above do not
/// carry.
fn the_untyped_answer() -> Result<(), Error> {
    let envelope = reflect_json(SHADER)?;

    // `wgslender::Value` is `serde_json::Value` under this crate's name, which
    // is what makes the envelope readable without taking on serde yourself.
    let parsed = Value::from_str(&envelope)?;
    println!(
        "\nreflect_json: {} bytes, envelope version {}",
        envelope.len(),
        parsed
            .get("version")
            .map_or_else(|| "absent".to_owned(), ToString::to_string),
    );

    let first = parsed.get("bindings").and_then(|bindings| bindings.get(0));
    for field in ["name", "nameOffset", "stableId", "declSpan"] {
        let value = first.and_then(|binding| binding.get(field));
        println!(
            "  {field:<12}{}",
            value.map_or_else(|| "absent".to_owned(), ToString::to_string),
        );
    }

    println!(
        "\nNone of the last three are on the typed `Binding`, which is the reason\n\
         `reflect_json` exists. The `stableId` is the interesting one: it is exactly\n\
         what `refactor::StableId::new` takes, so it is the bridge between the two\n\
         halves of this API — reflection says what is in the shader and where, and\n\
         refactor edits the thing that id names. `cargo run --example refactor`\n\
         reaches the same symbol from the other end.\n\
         \n\
         Prefer the typed call for everything it covers. This one hands back a wire\n\
         format, and a wire format is versioned — hence the `version` field."
    );
    Ok(())
}
