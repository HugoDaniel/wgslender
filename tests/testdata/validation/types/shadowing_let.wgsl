// @test: types/shadowing-let
// @expect-valid
// Local let shadows module-scope name (warning only)

var<private> value: f32;

@compute @workgroup_size(1)
fn main() {
    let value: f32 = 42.0;
}
