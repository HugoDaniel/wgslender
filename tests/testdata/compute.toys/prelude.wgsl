// compute.toys prelude - these are provided by the platform
// This file is for testing that the minifier preserves prelude names

alias int = i32;
alias uint = u32;
alias float = f32;
alias int2 = vec2<i32>;
alias int3 = vec3<i32>;
alias int4 = vec4<i32>;
alias uint2 = vec2<u32>;
alias uint3 = vec3<u32>;
alias uint4 = vec4<u32>;
alias float2 = vec2<f32>;
alias float3 = vec3<f32>;
alias float4 = vec4<f32>;
alias bool2 = vec2<bool>;
alias bool3 = vec3<bool>;
alias bool4 = vec4<bool>;
alias float2x2 = mat2x2<f32>;
alias float2x3 = mat2x3<f32>;
alias float2x4 = mat2x4<f32>;
alias float3x2 = mat3x2<f32>;
alias float3x3 = mat3x3<f32>;
alias float3x4 = mat3x4<f32>;
alias float4x2 = mat4x2<f32>;
alias float4x3 = mat4x3<f32>;
alias float4x4 = mat4x4<f32>;

struct Time {
    elapsed: f32,
    delta: f32,
    frame: u32
}

struct Mouse {
    pos: vec2i,
    zoom: f32,
    click: i32,
    start: vec2i,
    delta: vec2i
}

struct DispatchInfo {
    id: u32
}

struct Custom {
    _dummy: f32
}

@group(0) @binding(2) var<uniform> time: Time;
@group(0) @binding(3) var<uniform> mouse: Mouse;
@group(0) @binding(4) var<uniform> _keyboard: array<vec4<u32>,2>;
@group(0) @binding(5) var<uniform> custom: Custom;
@group(0) @binding(6) var<uniform> dispatch: DispatchInfo;
@group(0) @binding(7) var screen: texture_storage_2d<rgba16float,write>;
@group(0) @binding(8) var pass_in: texture_2d_array<f32>;
@group(0) @binding(9) var pass_out: texture_storage_2d_array<rgba16float,write>;
@group(0) @binding(10) var channel0: texture_2d<f32>;
@group(0) @binding(11) var channel1: texture_2d<f32>;
@group(0) @binding(12) var nearest: sampler;
@group(0) @binding(13) var bilinear: sampler;
@group(0) @binding(14) var trilinear: sampler;
@group(0) @binding(15) var nearest_repeat: sampler;
@group(0) @binding(16) var bilinear_repeat: sampler;
@group(0) @binding(17) var trilinear_repeat: sampler;

fn keyDown(keycode: uint) -> bool {
    return ((_keyboard[keycode / 128u][(keycode % 128u) / 32u] >> (keycode % 32u)) & 1u) == 1u;
}

fn assert(index: int, success: bool) {
    if (!success) {
        // atomicAdd(&_assert_counts[index], 1u);
    }
}

fn passStore(pass_index: int, coord: int2, value: float4) {
    textureStore(pass_out, coord, pass_index, value);
}

fn passLoad(pass_index: int, coord: int2, lod: int) -> float4 {
    return textureLoad(pass_in, coord, pass_index, lod);
}

fn passSampleLevelBilinearRepeat(pass_index: int, uv: float2, lod: float) -> float4 {
    return textureSampleLevel(pass_in, bilinear, fract(uv), pass_index, lod);
}

// Example shader using prelude
@compute @workgroup_size(16, 16)
fn main_image(@builtin(global_invocation_id) id: vec3u) {
    let screen_size = textureDimensions(screen);
    if (id.x >= screen_size.x || id.y >= screen_size.y) { return; }

    let uv = vec2f(f32(id.x), f32(id.y)) / vec2f(f32(screen_size.x), f32(screen_size.y));
    let col = vec3f(uv.x, uv.y, sin(time.elapsed));

    textureStore(screen, id.xy, vec4f(col, 1.0));
}
