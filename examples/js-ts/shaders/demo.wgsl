// Exercises every reflection category the example prints: a uniform struct
// with mixed field alignment, a storage buffer, a texture/sampler pair in a
// second bind group, a private helper the minifier is free to rename, and a
// compute entry point with an explicit workgroup size.

struct Params {
  resolution: vec2f,
  time: f32,
  frame: u32,
}

@group(0) @binding(0) var<uniform> params: Params;
@group(0) @binding(1) var<storage, read_write> data: array<vec4f>;
@group(1) @binding(0) var tex: texture_2d<f32>;
@group(1) @binding(1) var samp: sampler;

fn luminance(c: vec3f) -> f32 {
  return dot(c, vec3f(0.2126, 0.7152, 0.0722));
}

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) gid: vec3u) {
  let idx = gid.y * u32(params.resolution.x) + gid.x;
  let c = textureLoad(tex, vec2i(gid.xy), 0);
  data[idx] = vec4f(vec3f(luminance(c.rgb)), params.time);
}
