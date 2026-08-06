/**
 * The document the playground opens with, and the fixture every test in
 * `web/tests/` runs against. It is written to give each panel something to
 * say:
 *
 * - `Camera` has a `vec3` followed by an `f32`, so the reflection panel shows
 *   real §6.2.10 padding (size 80, `time` at offset 76).
 * - `particles` is a storage array of a second struct, so bindings span more
 *   than one address space.
 * - `particle_scale` is an `override`, which reflection reports separately
 *   and attributes to `vs_main`.
 * - `noise_tex` / `noise_smp` are sampled, so they show up as handle bindings
 *   without tripping the unused-binding rule.
 * - `wave` is called (hover, go-to-definition, rename targets); the linter
 *   reports `unused_helper` as W0001 and tree shaking drops it from the
 *   minified output.
 *
 * Verified with `wgslender validate` (clean) and `wgslender lint` (exactly
 * one W0001) — keep it that way, or the tests' assertions stop meaning what
 * they say.
 */
export const sampleShader = `// A small particle shader — every panel on this page has something to say
// about it. Edit freely: the language server re-checks as you type.

struct Camera {
  view_proj : mat4x4<f32>,
  eye       : vec3<f32>,
  time      : f32,
}

struct Particle {
  pos  : vec2<f32>,
  vel  : vec2<f32>,
  tint : vec4<f32>,
}

override particle_scale : f32 = 1.0;

@group(0) @binding(0) var<uniform> camera : Camera;
@group(0) @binding(1) var<storage, read> particles : array<Particle>;
@group(0) @binding(2) var noise_tex : texture_2d<f32>;
@group(0) @binding(3) var noise_smp : sampler;

fn wave(uv : vec2<f32>, t : f32) -> f32 {
  return sin(uv.x * 8.0 + t) * cos(uv.y * 8.0 - t) * 0.5 + 0.5;
}

// Nothing calls this one: the linter reports it, and tree shaking drops it
// from the minified output.
fn unused_helper(x : f32) -> f32 {
  return x * x * x;
}

@vertex
fn vs_main(@builtin(vertex_index) i : u32) -> @builtin(position) vec4<f32> {
  let p = particles[i].pos * particle_scale;
  return camera.view_proj * vec4<f32>(p, 0.0, 1.0);
}

@fragment
fn fs_main(@builtin(position) frag : vec4<f32>) -> @location(0) vec4<f32> {
  let uv = frag.xy / 512.0;
  let n = textureSample(noise_tex, noise_smp, uv).r;
  let w = wave(uv, camera.time);
  return vec4<f32>(vec3<f32>(w * n), 1.0);
}
`;

/** URI the playground opens `sampleShader` under. */
export const sampleUri = 'file:///playground/shader.wgsl';

/**
 * Line/character (LSP `Position`, utf-16 units) of the `n`-th occurrence of
 * `needle` in `text`. Used by tests and by panel wiring to point at a symbol
 * without hard-coding coordinates that drift whenever the sample is edited.
 */
export function positionOf(
  text: string,
  needle: string,
  occurrence = 1,
): { line: number; character: number } {
  let index = -1;
  for (let i = 0; i < occurrence; i++) {
    index = text.indexOf(needle, index + 1);
    if (index < 0) throw new Error(`not found (occurrence ${i + 1}): ${needle}`);
  }
  const before = text.slice(0, index);
  const lastBreak = before.lastIndexOf('\n');
  return { line: before.split('\n').length - 1, character: index - lastBreak - 1 };
}
