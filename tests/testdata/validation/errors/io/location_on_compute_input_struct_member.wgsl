// @test: errors/io/location-on-compute-input-struct-member
// @expect-error E0400 "compute shaders cannot have user-defined inputs"
// spec-ref: §10.2.1 User-defined Inputs and Outputs

struct CIn {
    @location(0) x : f32,
}

@compute @workgroup_size(1)
fn main(input : CIn) {
    let _ = input.x;
}
