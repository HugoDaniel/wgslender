// The shader `wgsl_module!`'s own tests generate a module from.
//
// It carries what `example.wgsl` deliberately does not: a struct with a hole in
// it. `Params` is twelve bytes of fields in a sixteen-byte block, so a
// generated struct has to end in explicit padding — which is the part of the
// expansion most worth pinning.

struct Params {
    resolution: vec2f,
    time: f32,
}

@group(0) @binding(0) var<uniform> params: Params;
@group(0) @binding(1) var<storage, read_write> data: array<f32>;

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) id: vec3u) {
    data[id.x] = params.time / params.resolution.x;
}
