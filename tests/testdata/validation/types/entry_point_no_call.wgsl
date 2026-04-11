// @test: types/entry-point-no-call
// @expect-valid
// Entry points exist but are not called from other functions

fn helper() -> f32 { return 1.0; }

@compute @workgroup_size(1)
fn main() {
    let x = helper();
}
