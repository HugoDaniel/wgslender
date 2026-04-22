// @test: errors/io/location-atomic
// @expect-error E0404 "@location requires numeric scalar or numeric vector type"
// spec-ref: §10.2.1 User-defined Inputs and Outputs

struct Inputs {
    @location(0) x : atomic<u32>,
}

@fragment
fn main(in : Inputs) -> @location(0) vec4<f32> {
    return vec4<f32>(0.0);
}
