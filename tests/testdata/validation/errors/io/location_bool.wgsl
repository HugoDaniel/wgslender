// @test: errors/io/location-bool
// @expect-error E0404 "@location requires numeric scalar or numeric vector type"
// spec-ref: §10.2.1 User-defined Inputs and Outputs

@fragment
fn main() -> @location(0) bool {
    return true;
}
