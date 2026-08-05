// The shader this crate's own examples embed.
//
// A proc-macro crate cannot host integration tests, and a documentation example
// that embeds a file needs that file to sit under this package — so it lives
// here rather than in the `wgslender` crate's fixtures.

@group(0) @binding(0) var<storage, read_write> data: array<f32>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
    data[id.x] = data[id.x] * 2.0;
}
