// @test: errors/types/var-initializer-mismatch
// @expect-error E0200 "cannot initialize"
// Var initializer must match declared type

@fragment
fn main() {
    var x : f32 = 42u;  // Error: can't initialize f32 with u32
}
