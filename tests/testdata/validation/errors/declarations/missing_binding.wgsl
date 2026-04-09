// @test: errors/declarations/missing-binding
// @expect-error E0803 "binding"
// Storage/uniform vars require @group and @binding

@group(0) var<storage> buf : array<f32>;  // Error: missing @binding

@fragment
fn main() {
    let x = buf[0];
}
