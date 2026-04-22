// @test: errors/io/location-array
// @expect-error E0404 "@location requires numeric scalar or numeric vector type"
// spec-ref: §10.2.1 User-defined Inputs and Outputs

@fragment
fn main() -> @location(0) array<f32, 4> {
    return array<f32, 4>(0.0, 0.0, 0.0, 0.0);
}
