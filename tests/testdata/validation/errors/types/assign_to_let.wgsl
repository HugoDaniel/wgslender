// @test: errors/types/assign-to-let
// @expect-error E0210 "cannot assign to 'let'"
// Assignment to immutable let binding

@compute @workgroup_size(1)
fn main() {
    let x = 1;
    x = 2;
}
