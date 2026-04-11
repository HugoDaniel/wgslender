// @test: types/pointer-param-valid
// @expect-valid
// Pointer parameter with function address space

fn set_value(p: ptr<function, f32>) {
    *p = 42.0;
}

@compute @workgroup_size(1)
fn main() {
    var x: f32 = 0.0;
    set_value(&x);
}
