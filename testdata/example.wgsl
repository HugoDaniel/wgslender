// Example WGSL shader for testing minification
// This is a simple vertex + fragment shader pair

struct VertexInput {
    @location(0) position: vec3f,
    @location(1) color: vec3f,
    @location(2) texcoord: vec2f,
}

struct VertexOutput {
    @builtin(position) position: vec4f,
    @location(0) color: vec3f,
    @location(1) texcoord: vec2f,
}

struct Uniforms {
    modelViewProjection: mat4x4f,
    time: f32,
}

@group(0) @binding(0) var<uniform> uniforms: Uniforms;
@group(0) @binding(1) var texSampler: sampler;
@group(0) @binding(2) var texture: texture_2d<f32>;

@vertex
fn vertexMain(input: VertexInput) -> VertexOutput {
    var output: VertexOutput;

    // Apply model-view-projection transform
    let worldPosition = vec4f(input.position, 1.0);
    output.position = uniforms.modelViewProjection * worldPosition;

    // Pass through color and texture coordinates
    output.color = input.color;
    output.texcoord = input.texcoord;

    return output;
}

@fragment
fn fragmentMain(input: VertexOutput) -> @location(0) vec4f {
    // Sample texture
    let texColor = textureSample(texture, texSampler, input.texcoord);

    // Combine with vertex color
    let finalColor = texColor.rgb * input.color;

    // Apply simple time-based animation
    let brightness = 0.5 + 0.5 * sin(uniforms.time);

    return vec4f(finalColor * brightness, texColor.a);
}

// Compute shader example
struct ComputeInput {
    data: array<f32>,
}

@group(0) @binding(0) var<storage, read_write> computeData: ComputeInput;

@compute @workgroup_size(64)
fn computeMain(@builtin(global_invocation_id) id: vec3u) {
    let index = id.x;
    if (index < arrayLength(&computeData.data)) {
        computeData.data[index] = computeData.data[index] * 2.0;
    }
}
