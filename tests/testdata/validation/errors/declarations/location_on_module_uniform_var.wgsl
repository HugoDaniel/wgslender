// @test: errors/declarations/location-on-module-uniform-var
// @expect-error E0400 "@location is not valid on module-scope var declarations"
// spec-ref: §11.2 location — must fire alongside valid @group/@binding

@group(0) @binding(0) @location(0) var<uniform> u: vec4<f32>;

@fragment
fn main() -> @location(0) vec4<f32> {
    return u;
}
