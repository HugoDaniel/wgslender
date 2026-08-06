// Exercises the four binding kinds, a struct, a helper function and one
// compute entry point — the shape the reflect tests pin numbers against.

struct Params {
    resolution: vec2f,
    time: f32,
    frame: u32,
}

@group(0) @binding(0) var<uniform> params: Params;
@group(0) @binding(1) var<storage, read_write> data: array<vec4f>;
@group(1) @binding(0) var tex: texture_2d<f32>;
@group(1) @binding(1) var samp: sampler;

fn luminance(color: vec3f) -> f32 {
    return dot(color, vec3f(0.2126, 0.7152, 0.0722));
}

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) id: vec3u) {
    let uv = vec2f(id.xy) / params.resolution;
    let sampled = textureSampleLevel(tex, samp, uv, 0.0);
    let lum = luminance(sampled.rgb);
    let index = id.y * u32(params.resolution.x) + id.x;
    data[index] = vec4f(lum, lum, lum, params.time * f32(params.frame));
}
