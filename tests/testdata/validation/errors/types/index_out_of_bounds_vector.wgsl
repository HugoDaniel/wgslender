// @test: errors/types/index-out-of-bounds-vector
// @expect-error E0211 "out of bounds"
// Vector index out of bounds

var<private> v: vec3f;

@compute @workgroup_size(1)
fn main() {
    v[3] = 1.0;
}
