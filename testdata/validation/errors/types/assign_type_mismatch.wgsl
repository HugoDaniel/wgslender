// @test: errors/types/assign-type-mismatch
// @expect-error E0200 "cannot assign"
// Type mismatch: assigning f32 to i32 variable

@fragment
fn main() {
    var x : i32;
    x = 1.5;  // Error: can't assign f32 to i32
}
