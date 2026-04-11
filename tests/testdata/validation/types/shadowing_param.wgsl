// @test: types/shadowing-param
// @expect-valid
// Shadowing is a warning, not an error — shader is still valid

var<private> x: f32;

fn helper(x: f32) -> f32 {
    return x * 2.0;
}

@compute @workgroup_size(1)
fn main() {
    x = helper(1.0);
}
