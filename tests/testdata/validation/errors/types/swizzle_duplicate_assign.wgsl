// @test: errors/types/swizzle-duplicate-assign
// @expect-error E0210 "duplicate components"
// Write target cannot have duplicate swizzle components

var<private> v: vec3f;

@compute @workgroup_size(1)
fn main() {
    v.xx = vec2f(1.0, 2.0);
}
