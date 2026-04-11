// @test: errors/declarations/nested-runtime-array-struct
// @expect-error E0806 "cannot be nested"
// Struct containing runtime-sized array cannot be nested in another struct

struct Inner {
    data: array<f32>,
}

struct Outer {
    @size(64) inner: Inner,
}

@group(0) @binding(0) var<storage> buf: Outer;

@compute @workgroup_size(1)
fn main() {}
