// A vertex/fragment pair: two entry points that carry no workgroup size, which
// is what the reflect tests pin the non-compute stages against.

struct VertexOut {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
}

@vertex
fn vs_main(@builtin(vertex_index) index: u32) -> VertexOut {
    let x = f32(i32(index) - 1);
    let y = f32(i32(index & 1u) * 2 - 1);
    var out: VertexOut;
    out.position = vec4f(x, y, 0.0, 1.0);
    out.uv = vec2f(x, y) * 0.5 + vec2f(0.5);
    return out;
}

@fragment
fn fs_main(vertex: VertexOut) -> @location(0) vec4f {
    return vec4f(vertex.uv, 0.0, 1.0);
}
