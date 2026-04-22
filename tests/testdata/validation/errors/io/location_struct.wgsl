// @test: errors/io/location-struct
// @expect-error E0404 "@location requires numeric scalar or numeric vector type"
// spec-ref: §10.2.1 User-defined Inputs and Outputs

struct Inner { a : f32 }

@fragment
fn main() -> @location(0) Inner {
    return Inner(0.0);
}
