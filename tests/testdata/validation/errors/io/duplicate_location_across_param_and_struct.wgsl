// @test: errors/io/duplicate-location-across-param-and-struct
// @expect-error E0602 "duplicate input @location(0)"
// spec-ref: §10.2.1 User-defined Inputs and Outputs

struct Inputs {
    @location(0) a : f32,
}

@fragment
fn main(@location(0) b : f32, in : Inputs) -> @location(0) vec4<f32> {
    return vec4<f32>(0.0);
}
