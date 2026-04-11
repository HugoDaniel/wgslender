// @test: errors/calls/must-use-dot
// @expect-error E0212 "must be used"
// dot() return value discarded

@compute @workgroup_size(1)
fn main() {
    let v = vec3f(1.0, 2.0, 3.0);
    dot(v, v);
}
