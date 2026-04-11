// @test: errors/calls/vec-constructor-type-mismatch
// @expect-error E0209 "cannot convert"
// AbstractFloat literals cannot implicitly convert to i32 in vec constructor

@fragment
fn main() {
    let a = vec3i(0.9, 0.8, 0.7);
}
