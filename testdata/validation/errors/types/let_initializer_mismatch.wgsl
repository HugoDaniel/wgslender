// @test: errors/types/let-initializer-mismatch
// @expect-error E0200 "cannot initialize"
// Let initializer must match declared type

@fragment
fn main() {
    let x : i32 = true;  // Error: can't assign bool to i32
}
