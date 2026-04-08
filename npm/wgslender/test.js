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
  const { initialize, minify, reflect, validate, isInitialized } = wgslender;

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
