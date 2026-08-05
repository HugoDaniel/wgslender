// A `mat3x3f`: three columns of twelve bytes, sixteen bytes apart. Nothing in
// Rust has that layout, so `wgsl_module!` refuses it by name rather than
// generating a struct that silently disagrees with the GPU.

struct Transform {
    basis: mat3x3f,
}

@group(0) @binding(0) var<uniform> transform: Transform;
@group(0) @binding(1) var<storage, read_write> out: array<f32>;

@compute @workgroup_size(1)
fn main() {
    out[0] = transform.basis[0].x;
}
