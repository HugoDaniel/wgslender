// Quick smoke test for the WASM build
import { readFile } from 'node:fs/promises';

const wasmBytes = await readFile(new URL('../zig-out/bin/wgslender.wasm', import.meta.url));
const { instance } = await WebAssembly.instantiate(wasmBytes);
const {
    memory,
    wgslender_alloc,
    wgslender_dealloc,
    wgslender_minify,
    wgslender_version,
    wgslender_version_len,
    wgslender_find_references,
    wgslender_rename,
    wgslender_rename_apply,
} = instance.exports;

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function writeString(s) {
    const bytes = encoder.encode(s);
    if (bytes.length === 0) {
        const p = wgslender_alloc(1);
        if (!p) throw new Error('alloc failed');
        return { ptr: p, len: 0, allocLen: 1 };
    }
    const p = wgslender_alloc(bytes.length);
    if (!p) throw new Error('alloc failed');
    new Uint8Array(memory.buffer, p, bytes.length).set(bytes);
    return { ptr: p, len: bytes.length, allocLen: bytes.length };
}

function readPackedJson(ptr) {
    const view = new DataView(memory.buffer);
    const jsonLen = view.getUint32(ptr, true);
    const json = decoder.decode(new Uint8Array(memory.buffer, ptr + 4, jsonLen));
    wgslender_dealloc(ptr, jsonLen + 4);
    return JSON.parse(json);
}

function byteOffset(source, needle) {
    // Source is ASCII in these tests, so string indexOf == byte offset.
    const i = source.indexOf(needle);
    if (i < 0) throw new Error(`needle ${JSON.stringify(needle)} not found`);
    return i;
}

// Test version
const versionLen = wgslender_version_len();
const versionPtr = wgslender_version();
const version = decoder.decode(new Uint8Array(memory.buffer, versionPtr, versionLen));
console.log(`Version: ${version}`);

function assert(cond, msg) {
    if (!cond) { console.error('ASSERTION FAILED:', msg); process.exit(1); }
}

// =========================================================================
// minify smoke test
// =========================================================================

{
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
    const src = writeString(source);
    const resultPtr = wgslender_minify(src.ptr, src.len, 0xF);
    wgslender_dealloc(src.ptr, src.allocLen);
    assert(resultPtr, 'minify returned null');

    const view = new DataView(memory.buffer);
    const resultLen = view.getUint32(resultPtr, true);
    const result = decoder.decode(new Uint8Array(memory.buffer, resultPtr + 4, resultLen));
    wgslender_dealloc(resultPtr, resultLen + 4);

    console.log(`minify: ${src.len} -> ${resultLen} bytes (${((1 - resultLen / src.len) * 100).toFixed(1)}% reduction)`);
    assert(result.includes('vertexMain') && result.includes('@vertex'), 'entry point not preserved');
    assert(!result.includes('helper') && !result.includes('Uniforms'), 'names should have been minified');
    console.log('  minify PASS');
}

// =========================================================================
// findReferences — function used in three call sites
// =========================================================================

{
    const source = `fn helper(x: f32) -> f32 { return x * 2.0; }
fn other(y: f32) -> f32 { return helper(y) + helper(1.0); }
@compute @workgroup_size(1) fn main() { let z = helper(3.0); }`;

    const offset = byteOffset(source, 'helper'); // on the declaration
    const src = writeString(source);
    const ptr = wgslender_find_references(src.ptr, src.len, offset, 1);
    wgslender_dealloc(src.ptr, src.allocLen);
    assert(ptr, 'find_references returned null');

    const res = readPackedJson(ptr);
    assert(!res.error, `find_references error: ${res.error}`);
    assert(res.references.length === 4, `expected 4 references, got ${res.references.length}`);
    // Declaration site is a write.
    assert(res.references.some(r => r.isWrite), 'no write (declaration) reference');
    // Every range must spell "helper" in source.
    for (const r of res.references) {
        assert(source.slice(r.start, r.end) === 'helper',
            `range ${r.start}..${r.end} is ${JSON.stringify(source.slice(r.start, r.end))}`);
    }
    console.log('  findReferences PASS');
}

// =========================================================================
// rename — function
// =========================================================================

{
    const source = `fn helper(x: f32) -> f32 { return x * 2.0; }
fn other(y: f32) -> f32 { return helper(y) + helper(1.0); }
@compute @workgroup_size(1) fn main() { let z = helper(3.0); }`;

    const offset = byteOffset(source, 'helper');
    const src = writeString(source);
    const name = writeString('scale');
    const ptr = wgslender_rename(src.ptr, src.len, offset, name.ptr, name.len);
    wgslender_dealloc(src.ptr, src.allocLen);
    wgslender_dealloc(name.ptr, name.allocLen);
    assert(ptr, 'rename returned null');

    const res = readPackedJson(ptr);
    assert(!res.error, `rename error: ${res.error}`);
    assert(res.edits.length === 4, `expected 4 edits, got ${res.edits.length}`);
    for (const e of res.edits) {
        assert(e.newText === 'scale', `newText=${e.newText}`);
        assert(source.slice(e.start, e.end) === 'helper', `range maps to ${source.slice(e.start, e.end)}`);
    }
    console.log('  rename (function) PASS');
}

// =========================================================================
// renameApply — parameter, verify rewritten source re-minifies
// =========================================================================

{
    const source = `fn first(x: f32) -> f32 { return x + 1.0; }
fn second(x: f32) -> f32 { return x * 2.0; }
@compute @workgroup_size(1) fn main() { let r = first(1.0) + second(2.0); }`;

    // Cursor on `x` in first's parameter list.
    const offset = byteOffset(source, 'x: f32) -> f32 { return x + 1.0');
    const src = writeString(source);
    const name = writeString('value');
    const ptr = wgslender_rename_apply(src.ptr, src.len, offset, name.ptr, name.len);
    wgslender_dealloc(src.ptr, src.allocLen);
    wgslender_dealloc(name.ptr, name.allocLen);
    assert(ptr, 'rename_apply returned null');

    const res = readPackedJson(ptr);
    assert(res.ok, `rename_apply failed: ${res.error}`);
    assert(res.edits.length === 2, `expected 2 edits, got ${res.edits.length}`);
    assert(res.source.includes('fn first(value: f32)'), 'first parameter not renamed');
    assert(res.source.includes('return value + 1.0'), 'first body not renamed');
    assert(res.source.includes('fn second(x: f32)'), 'second parameter was incorrectly renamed');
    assert(res.source.includes('return x * 2.0'), 'second body was incorrectly renamed');

    // Rewritten source must still minify.
    const src2 = writeString(res.source);
    const mptr = wgslender_minify(src2.ptr, src2.len, 0xF);
    wgslender_dealloc(src2.ptr, src2.allocLen);
    assert(mptr, 'minify of renamed source returned null');
    const view = new DataView(memory.buffer);
    const mlen = view.getUint32(mptr, true);
    wgslender_dealloc(mptr, mlen + 4);
    assert(mlen > 0, 'minify produced empty output');
    console.log('  renameApply (parameter) PASS');
}

// =========================================================================
// rename — variable
// =========================================================================

{
    const source = `@group(0) @binding(0) var<storage, read_write> things: array<i32, 4>;
@compute @workgroup_size(1) fn main() { things[0] = things[1] + 1; }`;

    const offset = byteOffset(source, 'things: array');
    const src = writeString(source);
    const name = writeString('items');
    const ptr = wgslender_rename_apply(src.ptr, src.len, offset, name.ptr, name.len);
    wgslender_dealloc(src.ptr, src.allocLen);
    wgslender_dealloc(name.ptr, name.allocLen);
    assert(ptr, 'rename_apply returned null');

    const res = readPackedJson(ptr);
    assert(res.ok, `rename_apply failed: ${res.error}`);
    // 1 decl + 2 uses = 3 edits.
    assert(res.edits.length === 3, `expected 3 edits, got ${res.edits.length}`);
    assert(!res.source.includes('things'), 'old name still present');
    assert(res.source.match(/items/g).length === 3, 'expected 3 occurrences of new name');
    console.log('  rename (variable) PASS');
}

// =========================================================================
// rename — error paths
// =========================================================================

{
    const source = 'const x: f32 = 1.0;';

    // Invalid identifier (keyword).
    {
        const src = writeString(source);
        const name = writeString('fn');
        const ptr = wgslender_rename(src.ptr, src.len, byteOffset(source, 'x'), name.ptr, name.len);
        wgslender_dealloc(src.ptr, src.allocLen);
        wgslender_dealloc(name.ptr, name.allocLen);
        const res = readPackedJson(ptr);
        assert(res.edits.length === 0, 'keyword rename should produce no edits');
        assert(res.error === 'invalid identifier', `expected invalid-identifier error, got ${res.error}`);
    }

    // Symbol not found (offset in whitespace).
    {
        const src = writeString(source);
        const name = writeString('y');
        const ptr = wgslender_rename(src.ptr, src.len, 5, name.ptr, name.len); // space between `const` and `x`
        wgslender_dealloc(src.ptr, src.allocLen);
        wgslender_dealloc(name.ptr, name.allocLen);
        const res = readPackedJson(ptr);
        assert(res.edits.length === 0, 'no-symbol rename should produce no edits');
        assert(res.error === 'symbol not found', `expected symbol-not-found error, got ${res.error}`);
    }

    // rename_apply on failure returns ok:false, original source.
    {
        const src = writeString(source);
        const name = writeString('fn');
        const ptr = wgslender_rename_apply(src.ptr, src.len, byteOffset(source, 'x'), name.ptr, name.len);
        wgslender_dealloc(src.ptr, src.allocLen);
        wgslender_dealloc(name.ptr, name.allocLen);
        const res = readPackedJson(ptr);
        assert(res.ok === false, 'rename_apply should report ok:false on invalid identifier');
        assert(res.source === source, 'failed rename_apply should echo original source');
        assert(res.error === 'invalid identifier');
    }

    console.log('  rename error paths PASS');
}

console.log('WASM test PASSED');
