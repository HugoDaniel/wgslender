// @test: errors/declarations/missing-group
// @expect-error E0803 "group"
// Storage/uniform vars require @group and @binding

@binding(0) var<storage> buf : array<f32>;  // Error: missing @group

@fragment
fn main() {
    let x = buf[0];
}
