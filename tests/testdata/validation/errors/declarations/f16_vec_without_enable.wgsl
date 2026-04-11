// @test: errors/declarations/f16-vec-without-enable
// @expect-error E0900 "requires 'enable f16;'"
// vec3<f16> used without enable f16

var<private> v: vec3<f16>;

@compute @workgroup_size(1)
fn main() {}
