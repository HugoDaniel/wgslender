// @test: errors/declarations/opaque-in-struct
// @expect-error E0805 "opaque type"
// Textures and samplers cannot appear in structs

struct Material {
    tex: texture_2d<f32>,
}

@compute @workgroup_size(1)
fn main() {}
