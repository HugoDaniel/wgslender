// @test: errors/types/index-out-of-bounds-vec4
// @expect-error E0211 "out of bounds"
// vec4 indexed at [4] (valid range is 0-3)

var<private> v: vec4f;

@compute @workgroup_size(1)
fn main() {
    v[4] = 1.0;
}
