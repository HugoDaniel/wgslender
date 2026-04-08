// @test: errors/types/return-type-mismatch
// @expect-error E0200 "cannot return"
// Return type must match function declaration

fn foo() -> i32 {
    return 1.5;  // Error: returning f32 when i32 expected
}

@fragment
fn main() {
    foo();
}
