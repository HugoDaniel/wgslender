//! What a host program needs to know about a shader, without parsing it: the
//! binding table, the memory layout of every struct it declares, and the entry
//! points a pipeline is built around.
//!
//! ```text
//! cargo run -p wgslender --example reflect_types
//! ```

use wgslender::{Error, reflect};

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

    Ok(())
}
