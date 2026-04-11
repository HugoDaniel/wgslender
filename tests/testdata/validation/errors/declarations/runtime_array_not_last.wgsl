// @test: errors/declarations/runtime-array-not-last
// @expect-error E0806 "must be the last member"
// Runtime-sized array must be the last struct member

struct Bad {
    data: array<f32>,
    extra: f32,
}

@group(0) @binding(0) var<storage> b: Bad;

@compute @workgroup_size(1)
fn main() {}
