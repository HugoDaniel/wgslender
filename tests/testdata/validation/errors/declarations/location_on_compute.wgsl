// @test: errors/declarations/location-on-compute
// @expect-error E0400 "compute shaders cannot have user-defined inputs"
// Compute shaders cannot have @location I/O

@compute @workgroup_size(1)
fn main(@location(0) x: f32) {}
