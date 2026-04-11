// @test: errors/declarations/non-constructible-param
// @expect-error E0203 "non-constructible type"
// Function parameters must be constructible, pointer, texture, or sampler

fn process(data: array<f32>) {}

@compute @workgroup_size(1)
fn main() {}
