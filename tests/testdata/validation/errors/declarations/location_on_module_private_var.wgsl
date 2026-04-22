// @test: errors/declarations/location-on-module-private-var
// @expect-error E0400 "@location is not valid on module-scope var declarations"
// spec-ref: §11.2 location

@location(0) var<private> x: f32;

@fragment
fn main() -> @location(0) vec4<f32> {
    return vec4<f32>(x);
}
