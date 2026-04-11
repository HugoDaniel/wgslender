// @test: errors/types/assign-to-param
// @expect-error E0210 "cannot assign to parameter"
// Assignment to function parameter

fn helper(x: f32) -> f32 {
    x = 2.0;
    return x;
}

@compute @workgroup_size(1)
fn main() { let _ = helper(1.0); }
