// @test: types/struct-basic
// @expect-valid
// @spec-ref: 5.3 "Structure Types"
// Basic struct with various member types

struct Vertex {
    position : vec3<f32>,
    normal : vec3<f32>,
    uv : vec2<f32>,
}

struct Material {
    color : vec4<f32>,
    roughness : f32,
    metallic : f32,
}

struct Light {
    position : vec3<f32>,
    intensity : f32,
    color : vec3<f32>,
}

@fragment
fn main() {
    var v : Vertex;
    var m : Material;
    var l : Light;
    v.position = vec3<f32>(0.0, 1.0, 0.0);
    m.color = vec4<f32>(1.0);
    l.intensity = 1.0;
}
