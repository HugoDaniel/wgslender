// @test: types/shadowing-none
// @expect-valid
// No shadowing: all names are unique

var<private> module_x: f32;
fn helper() -> f32 { return module_x; }

@compute @workgroup_size(1)
fn main() {
    var local_y: f32 = 1.0;
    let local_z = helper();
    module_x = local_y + local_z;
}
