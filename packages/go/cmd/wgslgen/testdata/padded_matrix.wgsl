// A `mat3x3f`: three columns of twelve bytes, sixteen bytes apart. A Go array's
// stride is its element size, so no Go type has that layout — a column type
// would have to claim four rows. -module gives the field padding and an offset
// constant rather than a type that disagrees with the GPU.

struct Transform {
    basis: mat3x3f,
}

@group(0) @binding(0) var<uniform> transform: Transform;
@group(0) @binding(1) var<storage, read_write> out: array<f32>;

@compute @workgroup_size(1)
fn main() {
    out[0] = transform.basis[0].x;
}
