//! Shrink a shader, and show what shrank.
//!
//! ```text
//! cargo run -p wgslender --example minify
//! ```

use wgslender::{Error, MinifyOptions, minify_and_reflect};

/// A particle update pass: one uniform block, one storage buffer, one helper.
const SHADER: &str = "\
struct Params {
    resolution: vec2f,
    time: f32,
    frame: u32,
}

@group(0) @binding(0) var<uniform> params: Params;
@group(0) @binding(1) var<storage, read_write> positions: array<vec4f>;

fn wrap(value: f32, limit: f32) -> f32 {
    return value - limit * floor(value / limit);
}

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
    let index = id.x;
    let position = positions[index];
    let speed = 40.0 + f32(index % 8u) * 5.0;
    let x = wrap(position.x + speed * params.time, params.resolution.x);
    let y = wrap(position.y + speed * 0.5 * params.time, params.resolution.y);
    positions[index] = vec4f(x, y, position.z, position.w);
}
";

fn main() -> Result<(), Error> {
    // `minify_and_reflect` is the one call that reports sizes, so the numbers
    // below are the library's rather than this example's.
    let shader = minify_and_reflect(SHADER, &MinifyOptions::default())?;
    let saved = shader.original_size - shader.minified_size;

    println!(
        "{} bytes -> {} bytes ({saved} saved, {}%)\n",
        shader.original_size,
        shader.minified_size,
        saved * 100 / shader.original_size,
    );
    println!("{}\n", shader.code);

    // Locals and the helper were renamed; the names a host program binds
    // against were not, which is why this list reads as the identity.
    println!("bindings, as declared -> as emitted:");
    for binding in &shader.reflection.bindings {
        println!(
            "  @group({}) @binding({}) {} -> {}",
            binding.group, binding.binding, binding.name, binding.name_mapped,
        );
    }

    Ok(())
}
