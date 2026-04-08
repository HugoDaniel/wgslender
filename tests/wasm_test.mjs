// Quick smoke test for the WASM build
import { readFile } from 'node:fs/promises';

const wasmBytes = await readFile(new URL('../zig-out/bin/wgslender.wasm', import.meta.url));
const { instance } = await WebAssembly.instantiate(wasmBytes);
const { memory, wgslender_alloc, wgslender_dealloc, wgslender_minify, wgslender_version, wgslender_version_len } = instance.exports;

// Test version
const versionLen = wgslender_version_len();
const versionPtr = wgslender_version();
const version = new TextDecoder().decode(new Uint8Array(memory.buffer, versionPtr, versionLen));
console.log(`Version: ${version}`);

// Test minify
const source = `
struct Uniforms {
    transform: mat4x4f,
}

@group(0) @binding(0) var<uniform> uniforms: Uniforms;

fn helper(pos: vec4f) -> vec4f {
    return uniforms.transform * pos;
}

@vertex
fn vertexMain(@location(0) position: vec4f) -> @builtin(position) vec4f {
    return helper(position);
}
`;

const encoder = new TextEncoder();
const sourceBytes = encoder.encode(source);

// Allocate and write source
const srcPtr = wgslender_alloc(sourceBytes.length);
if (!srcPtr) { console.error('alloc failed'); process.exit(1); }
new Uint8Array(memory.buffer, srcPtr, sourceBytes.length).set(sourceBytes);

// Minify with all options: whitespace(1) | identifiers(2) | syntax(4) | tree_shaking(8) = 0xF
const resultPtr = wgslender_minify(srcPtr, sourceBytes.length, 0xF);
wgslender_dealloc(srcPtr, sourceBytes.length);

if (!resultPtr) { console.error('minify failed'); process.exit(1); }

// Read result: [u32 len][u8... code]
const view = new DataView(memory.buffer);
const resultLen = view.getUint32(resultPtr, true);
const result = new TextDecoder().decode(new Uint8Array(memory.buffer, resultPtr + 4, resultLen));
wgslender_dealloc(resultPtr, resultLen + 4);

console.log(`Input:  ${sourceBytes.length} bytes`);
console.log(`Output: ${resultLen} bytes (${((1 - resultLen / sourceBytes.length) * 100).toFixed(1)}% reduction)`);
console.log(`Result: ${result}`);

// Verify output is valid
if (!result.includes('vertexMain') || !result.includes('@vertex')) {
    console.error('ERROR: Entry point not preserved!');
    process.exit(1);
}
if (result.includes('helper') || result.includes('Uniforms')) {
    console.error('ERROR: Names should have been minified!');
    process.exit(1);
}

console.log('WASM test PASSED');
