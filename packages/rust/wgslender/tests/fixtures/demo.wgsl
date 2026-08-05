// The shader `include_wgsl!` is pointed at, in tests and in UI goldens.
//
// It carries a `luminance` helper the default minifier renames away, which is
// what the `keep_names` row has something to hold on to. This crate keeps its
// own copy rather than sharing wgslender-core's: a manifest-relative macro path
// cannot reach outside the package, and a published package carries only what
// lives under it.

struct Params {
    resolution: vec2f,
    time: f32,
}

@group(0) @binding(0) var<uniform> params: Params;
@group(0) @binding(1) var<storage, read_write> data: array<vec4f>;

fn luminance(color: vec3f) -> f32 {
    return dot(color, vec3f(0.2126, 0.7152, 0.0722));
}

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) id: vec3u) {
    let uv = vec2f(id.xy) / params.resolution;
    let lum = luminance(vec3f(uv, params.time));
    let index = id.y * u32(params.resolution.x) + id.x;
    data[index] = vec4f(lum, lum, lum, 1.0);
}
