@fragment
fn fs_main() -> @location(0) vec4<f32> {
  return vec4<f32>(clock_scene(), clock_vec(), clock_frag(), clock_post());
}
