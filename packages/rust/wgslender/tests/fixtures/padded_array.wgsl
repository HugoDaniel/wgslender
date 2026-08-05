// An `array<vec3f, 4>`: four elements of twelve bytes, sixteen bytes apart.
// The same refusal as `padded_matrix.wgsl`, reached through the array rule.

struct Points {
    at: array<vec3f, 4>,
}

@group(0) @binding(0) var<uniform> points: Points;
@group(0) @binding(1) var<storage, read_write> out: array<f32>;

@compute @workgroup_size(1)
fn main() {
    out[0] = points.at[0].x;
}
