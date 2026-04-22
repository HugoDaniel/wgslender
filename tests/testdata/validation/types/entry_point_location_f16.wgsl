// @test: types/entry-point-location-f16
// @expect-valid
// spec-ref: §10.2.1 User-defined Inputs and Outputs (f16 is a numeric scalar)

enable f16;

struct Outputs {
    @location(0) a : vec4<f16>,
}

@fragment
fn main() -> Outputs {
    return Outputs(vec4<f16>(0.0h));
}
