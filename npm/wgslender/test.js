#!/usr/bin/env node
/**
 * Node.js test script for wgslender WASM (Zig backend)
 * Run with: node test.js
 */

const path = require('path');
const fs = require('fs');

let passed = 0;
let failed = 0;

function assert(condition, name, detail) {
  if (condition) {
    console.log(`  \u2713 ${name}`);
    passed++;
  } else {
    console.log(`  \u2717 ${name}`);
    if (detail) console.log(`    ${detail}`);
    failed++;
  }
}

function assertThrows(fn, name, expectedType) {
  try {
    fn();
    console.log(`  \u2717 ${name} (did not throw)`);
    failed++;
  } catch (err) {
    if (expectedType && !(err instanceof expectedType)) {
      console.log(`  \u2717 ${name} (wrong error type: ${err.constructor.name})`);
      failed++;
    } else {
      console.log(`  \u2713 ${name}`);
      passed++;
    }
  }
}

async function main() {
  console.log('wgslender WASM Node.js Test Suite\n');

  const wgslender = require('./lib/main.js');
  const {
    initialize, minify, reflect, validate, isInitialized,
    findReferences, rename, renameApply,
    stableIdAtOffset, locateStableId, renameByStableId,
  } = wgslender;

  // =============================================
  // Initialization
  // =============================================
  console.log('--- Initialization ---');

  assert(isInitialized() === false, 'isInitialized() returns false before init');

  assertThrows(() => minify('fn main() {}'), 'minify() before initialize() throws');

  await initialize();
  assert(isInitialized() === true, 'isInitialized() returns true after init');

  // Double init is safe
  await initialize();
  assert(isInitialized() === true, 'Double initialize() is safe (idempotent)');

  console.log('');

  // =============================================
  // Version
  // =============================================
  console.log('--- Version ---');

  // Access version via module object (getter) after init
  const version = wgslender.version;
  assert(typeof version === 'string', 'version is a string');
  assert(/^\d+\.\d+\.\d+/.test(version), `version matches semver format: ${version}`);

  console.log('');

  // =============================================
  // Minify - Happy Path
  // =============================================
  console.log('--- Minify: Happy Path ---');

  {
    const r = minify('const x = 1;\nconst y = 2;', {
      minifyWhitespace: true, minifyIdentifiers: true, minifySyntax: true
    });
    assert(r.code.length < 25 && r.errors.length === 0, 'Basic minification');
  }

  {
    const r = minify('fn foo() { return 1; }', {
      minifyWhitespace: true, minifyIdentifiers: false
    });
    assert(r.code.includes('foo') && r.errors.length === 0, 'Whitespace-only (identifiers preserved)');
  }

  {
    const input = '@group(0) @binding(0) var<uniform> uniforms: f32;\nfn getValue() -> f32 { return uniforms * 2.0; }';
    const r = minify(input, { minifyWhitespace: true, minifyIdentifiers: true });
    assert(r.code.includes('var<uniform> uniforms') && r.errors.length === 0, 'External binding preserved (default)');
  }

  {
    const input = '@group(0) @binding(0) var<uniform> uniforms: f32;\nfn getValue() -> f32 { return uniforms * 2.0; }';
    const r = minify(input, { minifyWhitespace: true, minifyIdentifiers: true, mangleExternalBindings: true });
    assert(!r.code.includes('uniforms') && r.errors.length === 0, 'External binding mangled');
  }

  {
    const input = 'fn used() -> f32 { return 1.0; }\nfn unused() -> f32 { return 2.0; }\n@compute @workgroup_size(1) fn main() { let x = used(); }';
    const r = minify(input, { minifyWhitespace: true, treeShaking: true });
    assert(!r.code.includes('unused') && r.errors.length === 0, 'Tree shaking removes unused code');
  }

  {
    const input = 'fn myHelper() -> f32 { return 1.0; }\nfn other() -> f32 { return myHelper(); }';
    const r = minify(input, { minifyWhitespace: true, minifyIdentifiers: true, keepNames: ['myHelper'] });
    assert(r.code.includes('myHelper') && r.errors.length === 0, 'keepNames preserves specific identifiers');
  }

  {
    const input = `struct MyStruct { x: f32 }
@group(0) @binding(0) var<uniform> u: MyStruct;
@compute @workgroup_size(1) fn main() { let v = u.x; }`;
    const r = minify(input, { minifyWhitespace: true, minifyIdentifiers: true, preserveUniformStructTypes: true });
    assert(r.code.includes('MyStruct') && r.errors.length === 0, 'preserveUniformStructTypes keeps struct type names');
  }

  {
    const input = `struct Uniforms { scale: f32 }
@group(0) @binding(0) var<uniform> uniforms: Uniforms;
fn computeValue(index: u32) -> f32 { return f32(index) * uniforms.scale; }
@compute @workgroup_size(64) fn main(@builtin(global_invocation_id) id: vec3u) { let value = computeValue(id.x); }`;
    const r = minify(input, { minifyWhitespace: true, minifyIdentifiers: true, minifySyntax: true });
    assert(r.errors.length === 0 && r.minifiedSize < r.originalSize, 'Complex shader with size reduction');
  }

  {
    const r = minify('const x = 1;\nconst y = 2;');
    assert(r.minifiedSize < r.originalSize, 'Size reduction verified (minifiedSize < originalSize)');
  }

  {
    const input = '@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0); }';
    const r = minify(input, { minifyWhitespace: true, minifyIdentifiers: true });
    assert(r.code.includes('fn vs(') && r.errors.length === 0, 'Entry point names preserved');
  }

  {
    const r = minify('const x = 1;');
    assert('code' in r && 'errors' in r && 'originalSize' in r && 'minifiedSize' in r,
      'Result has code, errors, originalSize, minifiedSize fields');
  }

  {
    const input = 'fn foo() -> f32 { return 1.0; }\nfn bar() -> f32 { return foo(); }';
    const r = minify(input, { minifyWhitespace: true, minifyIdentifiers: true, sourceMap: true });
    assert(r.sourceMap && typeof r.sourceMap === 'object' && r.sourceMap.version === 3,
      'Source map generation returns sourceMap field');
  }

  console.log('');

  // =============================================
  // Minify - Error/Edge Cases
  // =============================================
  console.log('--- Minify: Error/Edge Cases ---');

  {
    const r = minify('');
    assert(r.errors.length === 0, 'Empty string returns no errors');
  }

  {
    const r = minify('fn { broken }');
    assert(r.errors.length > 0, 'Invalid WGSL populates errors array');
  }

  {
    const r = minify('@@@@!!!###');
    assert(r.errors.length > 0, 'Severely malformed input returns errors, no crash');
  }

  assertThrows(() => minify(null), 'null source throws TypeError', TypeError);
  assertThrows(() => minify(undefined), 'undefined source throws TypeError', TypeError);
  assertThrows(() => minify(42), 'Non-string source (number) throws TypeError', TypeError);

  {
    const r = minify('const x = 1;');
    assert(r.errors.length === 0, 'No options uses defaults (all on)');
  }

  {
    const r = minify('const x = 1;', {});
    assert(r.errors.length === 0, 'Empty options object uses defaults');
  }

  {
    const r = minify('fn foo() -> f32 { return 1.0; }', { keepNames: [] });
    assert(r.errors.length === 0, 'keepNames with empty array: no effect');
  }

  {
    const r = minify('fn foo() -> f32 { return 1.0; }', { keepNames: ['nonexistent'] });
    assert(r.errors.length === 0, 'keepNames with nonexistent names: no error');
  }

  console.log('');

  // =============================================
  // Reflect - Happy Path
  // =============================================
  console.log('--- Reflect: Happy Path ---');

  {
    const input = `struct Inputs { time: f32, resolution: vec2<u32>, brightness: f32 }
@group(0) @binding(0) var<uniform> u: Inputs;`;
    const r = reflect(input);
    assert((r.errors || []).length === 0 && r.bindings.length === 1 &&
      r.bindings[0].group === 0 && r.bindings[0].binding === 0 &&
      r.bindings[0].name === 'u' && r.bindings[0].addressSpace === 'uniform' &&
      r.bindings[0].layout && r.bindings[0].layout.size === 24,
      'Uniform binding extraction (group, binding, name, type, addressSpace, layout)');
  }

  {
    const input = `@group(0) @binding(0) var texSampler: sampler;
@group(0) @binding(1) var texture: texture_2d<f32>;`;
    const r = reflect(input);
    assert((r.errors || []).length === 0 && r.bindings.length === 2, 'Texture/sampler binding detected');
    const sampler = r.bindings.find(b => b.name === 'texSampler');
    assert(sampler && sampler.addressSpace === 'handle' && !sampler.layout,
      'Sampler: addressSpace=handle, no layout');
  }

  {
    const input = `@compute @workgroup_size(8, 8, 1) fn main() {}`;
    const r = reflect(input);
    assert((r.errors || []).length === 0 && r.entryPoints.length === 1 &&
      r.entryPoints[0].stage === 'compute' && r.entryPoints[0].workgroupSize[0] === 8,
      'Entry point detection (stage, workgroupSize)');
  }

  {
    const input = `struct MyStruct { a: f32, b: vec2f }
@group(0) @binding(0) var<uniform> u: MyStruct;`;
    const r = reflect(input);
    assert(r.bindings[0].layout && r.bindings[0].layout.fields &&
      r.bindings[0].layout.fields.length === 2 &&
      r.bindings[0].layout.fields[0].name === 'a',
      'Struct layout (field names, offsets)');
  }

  {
    const input = `@group(0) @binding(0) var<uniform> a: f32;
@group(0) @binding(1) var<uniform> b: f32;
@vertex fn vs() -> @builtin(position) vec4f { return vec4f(a + b); }
@fragment fn fs() -> @location(0) vec4f { return vec4f(1); }`;
    const r = reflect(input);
    assert(r.bindings.length === 2 && r.entryPoints.length === 2,
      'Multiple bindings + entry points');
  }

  console.log('');

  // =============================================
  // Reflect - Error Cases
  // =============================================
  console.log('--- Reflect: Error Cases ---');

  {
    const r = reflect('');
    assert(r.bindings.length === 0 && r.entryPoints.length === 0, 'Empty string: empty bindings/entryPoints');
  }

  {
    const r = reflect('fn { broken }');
    assert((r.errors || []).length > 0, 'Invalid WGSL: errors array populated');
  }

  {
    const r = reflect('fn foo() -> f32 { return 1.0; }');
    assert(r.bindings.length === 0, 'No bindings in source: empty bindings array');
  }

  console.log('');

  // =============================================
  // Validate - Happy Path
  // =============================================
  console.log('--- Validate: Happy Path ---');

  {
    const r = validate('fn foo() -> f32 { return 1.0; }');
    assert(r.valid === true && r.errorCount === 0, 'Valid function: valid=true, errorCount=0');
  }

  {
    const r = validate('@compute @workgroup_size(1) fn main() {}');
    assert(r.valid === true, 'Valid compute shader: valid=true');
  }

  {
    const r = validate('@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0); }');
    assert(r.valid === true, 'Valid vertex shader: valid=true');
  }

  {
    const r = validate('fn foo() -> f32 { return 1.0; }');
    assert(Array.isArray(r.diagnostics), 'Diagnostics array exists');
  }

  console.log('');

  // =============================================
  // Validate - Error Cases
  // =============================================
  console.log('--- Validate: Error Cases ---');

  {
    const r = validate('fn foo() -> f32 { return bar; }');
    assert(r.valid === false && r.errorCount > 0, 'Undefined variable: valid=false');
  }

  {
    const r = validate('fn foo() -> f32 { var x: i32 = 1; return x; }');
    assert(r.valid === false, 'Type mismatch: valid=false');
  }

  {
    const r = validate('fn { broken }');
    assert(r.valid === false, 'Invalid WGSL (parse error): valid=false');
  }

  {
    const r = validate('');
    assert(r.valid === true, 'Empty string: valid=true (no declarations = valid)');
  }

  console.log('');

  // =============================================
  // Validate - Diagnostic Details
  // =============================================
  console.log('--- Validate: Diagnostic Details ---');

  {
    const r = validate('fn foo() -> f32 { return bar; }');
    const diag = r.diagnostics[0];
    assert(diag && diag.severity && diag.message, 'Error diagnostics have severity and message fields');
  }

  {
    const r = validate('fn foo() -> f32 { return bar; }');
    const diag = r.diagnostics[0];
    assert(diag && typeof diag.line === 'number' && diag.line >= 1 &&
      typeof diag.column === 'number' && diag.column >= 1,
      'line and column are present and 1-based');
  }

  {
    const r = validate('fn foo() -> f32 { return bar; }');
    const hasCode = r.diagnostics.some(d => d.code && d.code.length > 0);
    assert(hasCode, 'code field present (e.g. "E0100")');
  }

  console.log('');

  // =============================================
  // Integration
  // =============================================
  console.log('--- Integration ---');

  {
    const source = 'fn helper() -> f32 { return 1.0; }\n@compute @workgroup_size(1) fn main() { let x = helper(); }';
    const minified = minify(source, { minifyWhitespace: true, minifyIdentifiers: true });
    const valid = validate(minified.code);
    assert(valid.valid === true, 'Minify then validate: still valid WGSL');
  }

  {
    const source = `@group(0) @binding(0) var<uniform> u: f32;
@compute @workgroup_size(1) fn main() { let x = u; }`;
    const r1 = reflect(source);
    const minified = minify(source, { minifyWhitespace: true, minifyIdentifiers: true });
    const r2 = reflect(minified.code);
    assert(r1.entryPoints.length === r2.entryPoints.length, 'Minify then reflect: entry point count matches');
    assert(r1.bindings.length === r2.bindings.length, 'Minify then reflect: binding count matches');
  }

  {
    const source = 'fn foo() -> f32 { return 1.0; }\nfn bar() -> f32 { return foo(); }';
    const r1 = minify(source, { minifyWhitespace: true });
    const r2 = minify(r1.code, { minifyWhitespace: true });
    assert(r2.errors.length === 0, 'Minified output can be re-minified (idempotent-ish)');
  }

  console.log('');

  // =============================================
  // Edits: findReferences
  // =============================================
  console.log('--- Edits: findReferences ---');

  {
    const source = `fn helper(x: f32) -> f32 { return x * 2.0; }
fn other(y: f32) -> f32 { return helper(y) + helper(1.0); }
@compute @workgroup_size(1) fn main() { let z = helper(3.0); }`;
    const offset = source.indexOf('helper');
    const r = findReferences(source, offset);
    assert(!r.error, 'no error on valid source');
    assert(r.references.length === 4, `found 4 references (decl + 3 calls), got ${r.references.length}`);
    assert(r.references.filter(x => x.isWrite).length === 1, 'exactly one write (the declaration)');
    for (const ref of r.references) {
      assert(source.slice(ref.start, ref.end) === 'helper', 'range spells helper');
    }
  }

  {
    // include_declaration = false drops the decl site
    const source = 'const PI: f32 = 3.14; fn f(r: f32) -> f32 { return PI * r; }';
    const offset = source.indexOf('PI');
    const withDecl = findReferences(source, offset, true);
    const withoutDecl = findReferences(source, offset, false);
    assert(withDecl.references.length === 2, 'with decl: 2 refs');
    assert(withoutDecl.references.length === 1, 'without decl: 1 ref');
    assert(withoutDecl.references[0].isWrite === false, 'remaining ref is a read');
  }

  {
    // No symbol at offset → empty array, no error.
    const source = 'const x: f32 = 1.0;';
    const r = findReferences(source, 5); // space between `const` and `x`
    assert(r.references.length === 0, 'no symbol: empty references');
    assert(!r.error, 'no error');
  }

  {
    // Type validation
    assertThrows(() => findReferences(123, 0), 'findReferences(non-string) throws', TypeError);
    assertThrows(() => findReferences('x', -1), 'findReferences(negative offset) throws', TypeError);
    assertThrows(() => findReferences('x', 'abc'), 'findReferences(non-numeric offset) throws', TypeError);
  }

  console.log('');

  // =============================================
  // Edits: rename — function, parameter, variable, alias
  // =============================================
  console.log('--- Edits: rename ---');

  {
    const source = `fn helper(x: f32) -> f32 { return x * 2.0; }
fn other(y: f32) -> f32 { return helper(y) + helper(1.0); }
@compute @workgroup_size(1) fn main() { let z = helper(3.0); }`;
    const r = rename(source, source.indexOf('helper'), 'scale');
    assert(!r.error, `rename function: no error, got ${r.error}`);
    assert(r.edits.length === 4, 'rename function: 4 edits');
    for (const e of r.edits) {
      assert(e.newText === 'scale', 'newText is scale');
      assert(source.slice(e.start, e.end) === 'helper', 'range maps to helper');
    }
  }

  {
    // Parameter rename scopes to a single function.
    const source = `fn first(x: f32) -> f32 { return x + 1.0; }
fn second(x: f32) -> f32 { return x * 2.0; }`;
    const offset = source.indexOf('x: f32) -> f32 { return x + 1.0');
    const r = rename(source, offset, 'value');
    assert(r.edits.length === 2, 'parameter rename: 2 edits (decl + 1 use)');
  }

  {
    // Type alias
    const source = 'alias Pixel = vec4f;\nfn shade() -> Pixel { return Pixel(1.0, 0.0, 0.0, 1.0); }';
    const r = rename(source, source.indexOf('Pixel'), 'Color');
    assert(r.edits.length === 3, 'alias rename: 3 edits');
  }

  {
    // Invalid identifier rejected.
    const r = rename('const v: i32 = 0;', 'const v: i32 = 0;'.indexOf('v'), 'fn');
    assert(r.edits.length === 0, 'keyword rename: no edits');
    assert(r.error === 'invalid identifier', 'error message');
  }

  {
    // Symbol not found (cursor on whitespace).
    const source = 'const x: f32 = 1.0;';
    const r = rename(source, 5, 'y');
    assert(r.error === 'symbol not found', 'no-symbol error');
    assert(r.edits.length === 0, 'no edits');
  }

  console.log('');

  // =============================================
  // Edits: renameApply — full loop, rewritten source re-validates and re-minifies
  // =============================================
  console.log('--- Edits: renameApply ---');

  {
    const source = `struct Uniforms { time: f32 }
@group(0) @binding(0) var<uniform> u: Uniforms;
fn get_time(g: Uniforms) -> f32 { return g.time; }
@compute @workgroup_size(1) fn main() { let t = get_time(u); }`;

    const r = renameApply(source, source.indexOf('Uniforms {'), 'Globals');
    assert(r.ok, `renameApply struct: ok, got ${r.error}`);
    assert(r.edits.length === 3, 'struct rename: 3 edits (decl, var type, param type)');
    assert(!r.source.includes('Uniforms'), 'old name gone');
    assert((r.source.match(/Globals/g) || []).length === 3, '3 occurrences of new name');
    // Rewritten source must still validate.
    const v = validate(r.source);
    assert(v.valid, 'rewritten source is valid WGSL');
    // And minify.
    const m = minify(r.source, { minifyWhitespace: true });
    assert(m.errors.length === 0, 'rewritten source minifies without errors');
  }

  {
    // On failure, renameApply echoes original source so callers can use it either way.
    const source = 'const v: i32 = 0;';
    const r = renameApply(source, source.indexOf('v'), 'return');
    assert(r.ok === false, 'rename of keyword fails');
    assert(r.source === source, 'original source echoed on failure');
    assert(r.edits.length === 0, 'no edits on failure');
    assert(r.error === 'invalid identifier');
  }

  {
    // renameApply with valid local-variable rename.
    const source = 'fn compute_total(n: i32) -> i32 { let count = n + 1; return count * 2; }';
    const r = renameApply(source, source.indexOf('count'), 'items');
    assert(r.ok, 'local rename ok');
    assert(r.edits.length === 2, '2 edits: decl + use');
    assert(r.source === 'fn compute_total(n: i32) -> i32 { let items = n + 1; return items * 2; }',
      `unexpected source: ${r.source}`);
  }

  console.log('');

  // =============================================
  // Edits: interaction — iterative rename across multiple rounds
  // =============================================
  console.log('--- Edits: iterative interactions ---');

  {
    // Round 1: rename function. Round 2: rename a variable in the rewritten source.
    let s = `fn step(x: f32) -> f32 { return x + 1.0; }
@compute @workgroup_size(1) fn main() { let a = step(1.0); let b = step(a); }`;

    const r1 = renameApply(s, s.indexOf('step'), 'advance');
    assert(r1.ok, 'round 1 ok');
    s = r1.source;
    assert(s.includes('fn advance(') && !s.includes('step'), 'round 1 applied');

    // Now rename a local `a` in the new source.
    const r2 = renameApply(s, s.indexOf('a = advance'), 'first');
    assert(r2.ok, 'round 2 ok');
    s = r2.source;
    assert(s.includes('let first = advance(1.0)'), 'round 2 applied to let');
    assert(s.includes('advance(first)'), 'round 2 updated the use');
    assert(s.includes('let b = advance(first)'), 'round 2 did not touch b');
    // And the whole thing still validates.
    const v = validate(s);
    assert(v.valid, 'iteratively renamed source still valid');
  }

  console.log('');

  // =============================================
  // StableId: reparse-stable identifiers
  // =============================================
  console.log('--- StableId ---');

  {
    const src1 = `fn compute(x: f32) -> f32 { let y = x + 1.0; return y; }`;
    const off = src1.indexOf('y =');
    const r = stableIdAtOffset(src1, off);
    assert(typeof r.stableId === 'string', 'stableIdAtOffset returns a string for a known offset');
    assert(r.stableId === 'v1:fn:compute/block#0/let:y',
      `stableId shape: got "${r.stableId}"`);

    const loc = locateStableId(src1, r.stableId);
    assert(loc.start === src1.indexOf('y ='), 'locateStableId returns the declaration start');
    assert(loc.end === loc.start + 1, 'locateStableId returns the correct end offset');

    // After an unrelated edit (comment added), the stableId still resolves.
    const src2 = `// a comment\n` + src1;
    const r2 = stableIdAtOffset(src2, src2.indexOf('y ='));
    assert(r2.stableId === r.stableId,
      `stableId is stable across whitespace/comment edits; got "${r2.stableId}"`);

    // Rename by stable ID.
    const ren = renameByStableId(src1, r.stableId, 'result');
    assert(Array.isArray(ren.edits) && ren.edits.length >= 2,
      'renameByStableId produces at least decl + use edits');
    assert(!('error' in ren) || !ren.error, 'renameByStableId succeeds with valid identifier');

    // Stale ID on a shader that deleted the symbol.
    const src3 = `fn compute(x: f32) -> f32 { return x; }`;
    const stale = stableIdAtOffset(src3, 0);
    assert(stale.stableId !== r.stableId, 'different symbol yields different stableId');

    const lostLoc = locateStableId(src3, r.stableId);
    assert(lostLoc.start === null, 'locateStableId returns null for deleted symbol');

    // Invalid version prefix rejected.
    const bad = locateStableId(src1, 'v2:fn:compute');
    assert(bad.start === null, 'unknown version prefix rejected');

    // Reflection surfaces stable IDs.
    const src4 = `@group(0) @binding(0) var<uniform> u: f32;
@compute @workgroup_size(1) fn main() { let v = u; }`;
    const reflected = reflect(src4);
    assert(typeof reflected.bindings[0].stableId === 'string',
      `reflect surfaces stableId on bindings; got: ${JSON.stringify(reflected.bindings[0].stableId)}`);
    assert(reflected.bindings[0].stableId === 'v1:var:u',
      `binding stableId shape: got "${reflected.bindings[0].stableId}"`);
    assert(typeof reflected.entryPoints[0].stableId === 'string',
      'reflect surfaces stableId on entry points');
  }

  console.log('');

  // =============================================
  // Summary
  // =============================================
  console.log(`\n${passed} passed, ${failed} failed`);

  // Show example output
  console.log('\n--- Example Output ---');
  const example = `@group(0) @binding(0) var<uniform> uniforms: f32;
fn getValue() -> f32 { return uniforms * 2.0; }`;

  console.log('Input:');
  console.log(example);

  console.log('\nWith aliasing (default):');
  const r1 = minify(example, { minifyWhitespace: true, minifyIdentifiers: true });
  console.log(r1.code);
  console.log(`(${r1.originalSize} -> ${r1.minifiedSize} bytes)`);

  console.log('\nWith mangleExternalBindings:');
  const r2 = minify(example, { minifyWhitespace: true, minifyIdentifiers: true, mangleExternalBindings: true });
  console.log(r2.code);
  console.log(`(${r2.originalSize} -> ${r2.minifiedSize} bytes)`);

  process.exit(failed > 0 ? 1 : 0);
}

main().catch(err => {
  console.error('Fatal error:', err);
  process.exit(1);
});
