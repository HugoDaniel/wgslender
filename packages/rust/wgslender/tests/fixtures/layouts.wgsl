// Everything `wgsl_module!` knows how to put in a Rust struct: a matrix, a
// small matrix whose columns pack tight, a nested struct, the three scalars,
// and a vector that leaves a hole behind it.
//
// The storage buffer is the other half of the story — a tightly packed array, a
// header field, and a runtime-sized tail that has no Rust field and gets an
// offset constant instead. It lives in `storage` because a uniform buffer may
// not hold an array of stride 4.

struct Material {
    tint: vec3f,
    strength: f32,
}

struct Scene {
    view: mat4x4f,
    scale: mat2x2f,
    material: Material,
    count: u32,
    kind: i32,
    offset: vec2f,
}

struct Instances {
    weights: array<f32, 4>,
    count: u32,
    items: array<vec4f>,
}

// Nothing but a runtime-sized array: the ordinary shape of a storage buffer
// with no header, and a struct whose fixed part is zero bytes long.
struct Trail {
    points: array<vec2f>,
}

// Three field names that are ordinary in WGSL and reserved in Rust. Nothing
// binds this one: a struct the shader merely declares is still a struct the
// host may want to describe, and reflection reports it either way.
struct Channels {
    in: f32,
    box: vec2f,
    dyn: u32,
}

@group(0) @binding(0) var<uniform> scene: Scene;
@group(2) @binding(3) var<storage, read_write> instances: Instances;
@group(2) @binding(4) var<storage, read> trail: Trail;

@compute @workgroup_size(16)
fn tick(@builtin(global_invocation_id) id: vec3u) {
    let index = id.x;
    if index >= instances.count {
        return;
    }
    let placed = scene.view * vec4f(scene.material.tint * instances.weights[0], 1.0);
    instances.items[index] = placed * scene.material.strength + vec4f(trail.points[index], 0.0, 0.0);
}
