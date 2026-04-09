// Test case: trailing comma in function parameters
// WGSL spec allows trailing commas in parameter lists

@vertex
fn vs_main(
  @builtin(vertex_index) vertexIndex: u32,
  @location(0) position: vec4f,
) -> @builtin(position) vec4f {
  return position;
}
