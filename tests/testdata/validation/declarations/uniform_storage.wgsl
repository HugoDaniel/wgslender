// @test: declarations/uniform-storage
// @expect-valid
// @spec-ref: 6.3 "Resource Variables"
// Uniform and storage buffer declarations

struct Uniforms {
    modelMatrix : mat4x4<f32>,
    viewMatrix : mat4x4<f32>,
    projMatrix : mat4x4<f32>,
    time : f32,
}

struct Particle {
    position : vec3<f32>,
    velocity : vec3<f32>,
}

struct ParticleBuffer {
    particles : array<Particle>,
}

@group(0) @binding(0) var<uniform> uniforms : Uniforms;
@group(0) @binding(1) var<storage, read> inputBuffer : ParticleBuffer;
@group(0) @binding(2) var<storage, read_write> outputBuffer : ParticleBuffer;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id : vec3<u32>) {
    let idx = id.x;
    var p = inputBuffer.particles[idx];
    p.position = p.position + p.velocity * uniforms.time;
    outputBuffer.particles[idx] = p;
}
