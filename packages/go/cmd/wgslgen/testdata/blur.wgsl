// A one-dimensional blur, kept small so that the files generated from it stay
// readable in testdata/golden.

struct Params {
    radius: f32,
    strength: f32,
}

@group(0) @binding(0) var<uniform> params: Params;
@group(0) @binding(1) var<storage, read_write> pixels: array<f32>;

fn luminance(x: f32) -> f32 {
    return x * params.strength;
}

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    let i = id.x;
    pixels[i] = luminance(pixels[i]) * params.radius;
}
