// @test: errors/types/pointer-to-pointer
// @expect-error E0200 "pointer element type must not be a pointer"
// WGSL does not allow pointers to pointers

fn foo(p: ptr<function, ptr<function, f32> >) {
}

@compute @workgroup_size(1)
fn main() {
}
