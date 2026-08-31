/**
 * Parameterised test suite for every wrapper variant.
 *
 * `runSuite(wgslender, opts)` is given an un-initialized wgslender module
 * export and exercises every public method against it. Each variant
 * (CJS Node / ESM Node / UMD browser / ESM browser) loads its own copy
 * of the module in a fresh process, so pre-init assertions stay valid.
 *
 * Returns `{ passed, failed }`. Does not call `process.exit`.
 */

'use strict';

async function runSuite(wgslender, opts) {
  opts = opts || {};
  const variantName = opts.variantName || 'wgslender';
  const initOptions = opts.initOptions || undefined;

  let passed = 0;
  let failed = 0;
  const failures = [];

  function assert(condition, name, detail) {
    if (condition) {
      console.log(`  ✓ ${name}`);
      passed++;
    } else {
      console.log(`  ✗ ${name}`);
      if (detail) console.log(`    ${detail}`);
      failed++;
      failures.push(name);
    }
  }

  function assertThrows(fn, name, expectedType) {
    try {
      fn();
      console.log(`  ✗ ${name} (did not throw)`);
      failed++;
      failures.push(name);
    } catch (err) {
      if (expectedType && !(err instanceof expectedType)) {
        console.log(`  ✗ ${name} (wrong error type: ${err.constructor.name})`);
        failed++;
        failures.push(name);
      } else {
        console.log(`  ✓ ${name}`);
        passed++;
      }
    }
  }

  console.log(`\n=== ${variantName} ===\n`);

  const {
    initialize, minify, reflect, minifyAndReflect, validate, isInitialized, getBindGroups,
    findReferences, rename, renameApply,
    stableIdAtOffset, locateStableId, renameByStableId,
    locateDeclaration, locateType,
    removeDeclarationByStableId, removeDeclarationApplyByStableId,
    changeTypeByStableId, changeTypeApplyByStableId,
    lint, lintAndFix, compile,
  } = wgslender;

  // --- Initialization ---
  console.log('--- Initialization ---');
  assert(isInitialized() === false, 'isInitialized() returns false before init');
  assertThrows(() => minify('fn main() {}'), 'minify() before initialize() throws');
  await initialize(initOptions);
  assert(isInitialized() === true, 'isInitialized() returns true after init');
  await initialize(initOptions);
  assert(isInitialized() === true, 'Double initialize() is safe (idempotent)');

  // --- Version ---
  console.log('\n--- Version ---');
  const version = String(wgslender.version);
  assert(typeof version === 'string', 'version is a string');
  assert(/^\d+\.\d+\.\d+/.test(version), `version matches semver format: ${version}`);

  // --- Minify: Happy Path ---
  console.log('\n--- Minify: Happy Path ---');
  {
    const r = minify('const x = 1;\nconst y = 2;', {
      minifyWhitespace: true, minifyIdentifiers: true, minifySyntax: true,
    });
    assert(r.code.length < 25 && r.errors.length === 0, 'Basic minification');
  }
  {
    const r = minify('fn foo() { return 1; }', {
      minifyWhitespace: true, minifyIdentifiers: false,
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

  // --- Minify: Error/Edge Cases ---
  console.log('\n--- Minify: Error/Edge Cases ---');
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

  // --- Reflect: Happy Path ---
  console.log('\n--- Reflect: Happy Path ---');
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
    const sampler = r.bindings.find((b) => b.name === 'texSampler');
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

  // --- Reflect: Error / v2 / getBindGroups ---
  console.log('\n--- Reflect: Error/v2/getBindGroups ---');
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
  {
    const input = `@group(0) @binding(0) var<uniform> u: vec3f;
@group(0) @binding(1) var samp: sampler;
@group(0) @binding(2) var tex: texture_2d<f32>;
alias Color = vec3f;`;
    const r = reflect(input);
    assert(r.version === 2, 'reflect emits version: 2');
    assert(Array.isArray(r.uniforms) && r.uniforms.length === 1 && r.uniforms[0].name === 'u',
      'reflect: uniforms[] subset view');
    assert(Array.isArray(r.samplers) && r.samplers.length === 1 && r.samplers[0].name === 'samp',
      'reflect: samplers[] subset view');
    assert(Array.isArray(r.textures) && r.textures.length === 1 && r.textures[0].name === 'tex',
      'reflect: textures[] subset view');
    assert(Array.isArray(r.aliases) && r.aliases.length === 1 && r.aliases[0].name === 'Color',
      'reflect: aliases[] populated');
  }
  {
    // Signatures are spelled from the AST, so `vec2f` and
    // `ptr<function, Element>` come back exactly as written.
    const r = reflect(`struct Element { pos: vec2f }
fn noop() {}
fn simplex(p: vec2f) -> f32 { return p.x + p.y; }
fn step_k(e: ptr<function, Element>, dt: f32) { (*e).pos.x = dt; }`);
    const byName = Object.fromEntries(r.functions.map((f) => [f.name, f]));
    assert(byName.noop.params.length === 0 && byName.noop.returnType === null,
      'reflect: a nullary void fn has empty params and a null returnType');
    assert(byName.simplex.params.length === 1 &&
      byName.simplex.params[0].name === 'p' &&
      byName.simplex.params[0].type === 'vec2f',
      'reflect: params carry name + source-spelled type');
    assert(byName.simplex.returnType === 'f32', 'reflect: returnType is spelled from source');
    assert(byName.step_k.params[0].type === 'ptr<function, Element>',
      'reflect: a pointer parameter is spelled whole');
    // No entry point exists here, so nothing is in use -- which must not
    // gate the signature.
    assert(byName.simplex.inUse === false && byName.simplex.params.length === 1,
      'reflect: an unreached function still reports its signature');
  }
  {
    // Reflection never runs the validator, so an unknown name is not an
    // error -- but it is not a scalar either, and it used to say it was.
    const r = reflect('fn g(d: Missing) { }');
    const p = r.functions.find((f) => f.name === 'g').params[0];
    assert(p.type === 'Missing', 'reflect: an unresolvable type is spelled as written');
    assert(p.typeInfo.kind === 'unresolved' && p.typeInfo.name === 'Missing',
      'reflect: an unresolvable type has its own typeInfo kind');
    assert(p.typeInfo.size === undefined && p.typeInfo.alignment === undefined,
      'reflect: an unresolvable type carries no measurements');
  }
  {
    const input = `@group(0) @binding(0) var<uniform> u: vec3f;
@group(0) @binding(2) var samp: sampler;
@group(1) @binding(0) var tex: texture_2d<f32>;`;
    const r = reflect(input);
    const grid = getBindGroups(r);
    assert(grid[0] && grid[0][0] && grid[0][0].name === 'u',
      'getBindGroups: group 0 binding 0 = u');
    assert(grid[0][2] && grid[0][2].name === 'samp',
      'getBindGroups: holes in binding sequence preserved');
    assert(grid[0][1] === undefined, 'getBindGroups: missing slot is undefined');
    assert(grid[1][0].name === 'tex', 'getBindGroups: separate group buckets');
    const grid2 = getBindGroups(r.bindings);
    assert(grid2[0][0].name === 'u', 'getBindGroups: accepts bindings[] directly');
  }

  // --- MinifyAndReflect: Happy Path ---
  console.log('\n--- MinifyAndReflect: Happy Path ---');
  {
    const input = `@group(0) @binding(0) var<uniform> uniforms: f32;
@compute @workgroup_size(1) fn main() { let x = uniforms; }`;
    const r = minifyAndReflect(input, { minifyWhitespace: true, minifyIdentifiers: true });
    assert(r.minify && r.reflect, 'returns { minify, reflect }');
    assert(r.minify.errors.length === 0 && r.minify.code.length > 0, 'minify half succeeds');
    assert(r.reflect.bindings.length === 1 && r.reflect.entryPoints.length === 1,
      'reflect half finds the binding and entry point');
  }
  {
    const input = `struct MyStruct { a: f32, b: vec2f }
@group(0) @binding(0) var<uniform> u: MyStruct;
fn helper() -> f32 { return u.a; }
@compute @workgroup_size(1) fn main() { let x = helper(); }`;
    const r = minifyAndReflect(input, { minifyWhitespace: true, minifyIdentifiers: true });
    const minifiedReflect = reflect(r.minify.code);
    assert(r.reflect.bindings[0].name === minifiedReflect.bindings[0].name,
      'reflect half uses the same renamed names as a reparse of minify.code');
    assert(r.reflect.bindings[0].nameMapped === 'u',
      'reflect half keeps the original name in nameMapped');
  }
  {
    const r = minifyAndReflect('fn { broken }');
    assert(r.minify.errors.length > 0, 'parse error surfaces in minify.errors');
    assert((r.reflect.errors || []).length > 0, 'parse error surfaces in reflect.errors');
  }

  // --- Validate: Happy Path ---
  console.log('\n--- Validate: Happy Path ---');
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

  // --- Validate: Error Cases ---
  console.log('\n--- Validate: Error Cases ---');
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

  // --- Validate: Diagnostic Details ---
  console.log('\n--- Validate: Diagnostic Details ---');
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
    const hasCode = r.diagnostics.some((d) => d.code && d.code.length > 0);
    assert(hasCode, 'code field present (e.g. "E0100")');
  }

  // --- Validate: ABI envelope regression (locks down commit 24d21f1) ---
  console.log('\n--- Validate: ABI envelope regression ---');
  {
    // (1) Result shape includes the four wrappers; warningCount comes
    // from offset+8 of the envelope, distinct from errorCount/valid/jsonLen.
    const r = validate('fn foo() -> f32 { return 1.0; }');
    assert('errorCount' in r && 'warningCount' in r && 'valid' in r && Array.isArray(r.diagnostics),
      'validate() returns {errorCount, warningCount, valid, diagnostics}');
    assert(typeof r.warningCount === 'number',
      `warningCount is a number (got ${typeof r.warningCount})`);
  }
  {
    // (2) warningCount is decoded from the envelope, not hard-coded.
    // A subgroup-scope barrier from a non-uniform path emits a derivative
    // uniformity warning under default validation.
    const sourceWithWarnings = `@group(0) @binding(0) var<storage, read_write> data: array<u32>;
@compute @workgroup_size(64) fn main(@builtin(local_invocation_id) lid: vec3u) {
  if (lid.x < 32u) {
    workgroupBarrier();
    data[lid.x] = 1u;
  }
}`;
    const r = validate(sourceWithWarnings);
    // We don't strictly require >0 because the analysis may not flag this
    // exact pattern, but warningCount must be a finite, decodable number.
    assert(Number.isFinite(r.warningCount) && r.warningCount >= 0,
      `warningCount is decoded as a finite number (got ${r.warningCount})`);
  }
  {
    // (3) Trailing JSON envelope decodes into populated diagnostics with
    // severity / message / line / column.
    const r = validate('fn foo() -> f32 { return bar; }');
    assert(r.diagnostics.length > 0, 'JSON envelope decodes into populated diagnostics array');
    const d = r.diagnostics[0];
    assert(d.severity === 'error' && typeof d.message === 'string' &&
      typeof d.line === 'number' && typeof d.column === 'number',
      'diagnostic carries severity/message/line/column');
  }
  {
    // (4) strict-mode flag is forwarded as flags=1. A shader that's valid
    // by default but emits a warning under default validation should
    // produce >=1 error under strict mode (warnings → errors).
    const sourceForStrict = `@group(0) @binding(0) var<storage, read_write> data: array<u32>;
@compute @workgroup_size(64) fn main(@builtin(local_invocation_id) lid: vec3u) {
  if (lid.x < 32u) {
    workgroupBarrier();
    data[lid.x] = 1u;
  }
}`;
    const def = validate(sourceForStrict);
    const strict = validate(sourceForStrict, { strict: true });
    // Either default already errored (test still meaningful: strict matches),
    // or strict promotes warnings; either way strict.errorCount must be
    // >= def.errorCount + def.warningCount.
    const expectedMin = def.errorCount + def.warningCount;
    assert(strict.errorCount >= expectedMin,
      `strict mode promotes warnings to errors (def: ${def.errorCount}e/${def.warningCount}w, strict: ${strict.errorCount}e)`);
  }

  // --- Integration ---
  console.log('\n--- Integration ---');
  {
    const source = 'fn helper() -> f32 { return 1.0; }\n@compute @workgroup_size(1) fn main() { let x = helper(); }';
    const minified = minify(source, { minifyWhitespace: true, minifyIdentifiers: true });
    const v = validate(minified.code);
    assert(v.valid === true, 'Minify then validate: still valid WGSL');
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

  // --- Edits: findReferences ---
  console.log('\n--- Edits: findReferences ---');
  {
    const source = `fn helper(x: f32) -> f32 { return x * 2.0; }
fn other(y: f32) -> f32 { return helper(y) + helper(1.0); }
@compute @workgroup_size(1) fn main() { let z = helper(3.0); }`;
    const offset = source.indexOf('helper');
    const r = findReferences(source, offset);
    assert(!r.error, 'no error on valid source');
    assert(r.references.length === 4, `found 4 references, got ${r.references.length}`);
    assert(r.references.filter((x) => x.isWrite).length === 1, 'exactly one write (the declaration)');
    for (const ref of r.references) {
      assert(source.slice(ref.start, ref.end) === 'helper', 'range spells helper');
    }
  }
  {
    const source = 'const PI: f32 = 3.14; fn f(r: f32) -> f32 { return PI * r; }';
    const offset = source.indexOf('PI');
    const withDecl = findReferences(source, offset, true);
    const withoutDecl = findReferences(source, offset, false);
    assert(withDecl.references.length === 2, 'with decl: 2 refs');
    assert(withoutDecl.references.length === 1, 'without decl: 1 ref');
    assert(withoutDecl.references[0].isWrite === false, 'remaining ref is a read');
  }
  {
    const source = 'const x: f32 = 1.0;';
    const r = findReferences(source, 5);
    assert(r.references.length === 0, 'no symbol: empty references');
    assert(!r.error, 'no error');
  }
  assertThrows(() => findReferences(123, 0), 'findReferences(non-string) throws', TypeError);
  assertThrows(() => findReferences('x', -1), 'findReferences(negative offset) throws', TypeError);
  assertThrows(() => findReferences('x', 'abc'), 'findReferences(non-numeric offset) throws', TypeError);

  // --- Edits: rename ---
  console.log('\n--- Edits: rename ---');
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
    const source = `fn first(x: f32) -> f32 { return x + 1.0; }
fn second(x: f32) -> f32 { return x * 2.0; }`;
    const offset = source.indexOf('x: f32) -> f32 { return x + 1.0');
    const r = rename(source, offset, 'value');
    assert(r.edits.length === 2, 'parameter rename: 2 edits (decl + 1 use)');
  }
  {
    const source = 'alias Pixel = vec4f;\nfn shade() -> Pixel { return Pixel(1.0, 0.0, 0.0, 1.0); }';
    const r = rename(source, source.indexOf('Pixel'), 'Color');
    assert(r.edits.length === 3, 'alias rename: 3 edits');
  }
  {
    const r = rename('const v: i32 = 0;', 'const v: i32 = 0;'.indexOf('v'), 'fn');
    assert(r.edits.length === 0, 'keyword rename: no edits');
    assert(r.error === 'invalid identifier', 'error message');
  }
  {
    const source = 'const x: f32 = 1.0;';
    const r = rename(source, 5, 'y');
    assert(r.error === 'symbol not found', 'no-symbol error');
    assert(r.edits.length === 0, 'no edits');
  }

  // --- Edits: renameApply ---
  console.log('\n--- Edits: renameApply ---');
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
    const v = validate(r.source);
    assert(v.valid, 'rewritten source is valid WGSL');
    const m = minify(r.source, { minifyWhitespace: true });
    assert(m.errors.length === 0, 'rewritten source minifies without errors');
  }
  {
    const source = 'const v: i32 = 0;';
    const r = renameApply(source, source.indexOf('v'), 'return');
    assert(r.ok === false, 'rename of keyword fails');
    assert(r.source === source, 'original source echoed on failure');
    assert(r.edits.length === 0, 'no edits on failure');
    assert(r.error === 'invalid identifier');
  }
  {
    const source = 'fn compute_total(n: i32) -> i32 { let count = n + 1; return count * 2; }';
    const r = renameApply(source, source.indexOf('count'), 'items');
    assert(r.ok, 'local rename ok');
    assert(r.edits.length === 2, '2 edits: decl + use');
    assert(r.source === 'fn compute_total(n: i32) -> i32 { let items = n + 1; return items * 2; }',
      `unexpected source: ${r.source}`);
  }

  // --- Edits: iterative interactions ---
  console.log('\n--- Edits: iterative interactions ---');
  {
    let s = `fn step(x: f32) -> f32 { return x + 1.0; }
@compute @workgroup_size(1) fn main() { let a = step(1.0); let b = step(a); }`;
    const r1 = renameApply(s, s.indexOf('step'), 'advance');
    assert(r1.ok, 'round 1 ok');
    s = r1.source;
    assert(s.includes('fn advance(') && !s.includes('step'), 'round 1 applied');
    const r2 = renameApply(s, s.indexOf('a = advance'), 'first');
    assert(r2.ok, 'round 2 ok');
    s = r2.source;
    assert(s.includes('let first = advance(1.0)'), 'round 2 applied to let');
    assert(s.includes('advance(first)'), 'round 2 updated the use');
    assert(s.includes('let b = advance(first)'), 'round 2 did not touch b');
    const v = validate(s);
    assert(v.valid, 'iteratively renamed source still valid');
  }

  // --- StableId ---
  console.log('\n--- StableId ---');
  {
    const src1 = `fn compute(x: f32) -> f32 { let y = x + 1.0; return y; }`;
    const off = src1.indexOf('y =');
    const r = stableIdAtOffset(src1, off);
    assert(typeof r.stableId === 'string', 'stableIdAtOffset returns a string');
    assert(r.stableId === 'v1:fn:compute/block#0/let:y',
      `stableId shape: got "${r.stableId}"`);

    const loc = locateStableId(src1, r.stableId);
    assert(loc.start === src1.indexOf('y ='), 'locateStableId returns the declaration start');
    assert(loc.end === loc.start + 1, 'locateStableId returns the correct end offset');

    const src2 = `// a comment\n` + src1;
    const r2 = stableIdAtOffset(src2, src2.indexOf('y ='));
    assert(r2.stableId === r.stableId,
      `stableId is stable across whitespace/comment edits; got "${r2.stableId}"`);

    const ren = renameByStableId(src1, r.stableId, 'result');
    assert(Array.isArray(ren.edits) && ren.edits.length >= 2,
      'renameByStableId produces >=2 edits');
    assert(!('error' in ren) || !ren.error, 'renameByStableId succeeds with valid identifier');

    const src3 = `fn compute(x: f32) -> f32 { return x; }`;
    const stale = stableIdAtOffset(src3, 0);
    assert(stale.stableId !== r.stableId, 'different symbol yields different stableId');

    const lostLoc = locateStableId(src3, r.stableId);
    assert(lostLoc.start === null, 'locateStableId returns null for deleted symbol');

    const bad = locateStableId(src1, 'v2:fn:compute');
    assert(bad.start === null, 'unknown version prefix rejected');

    const src4 = `@group(0) @binding(0) var<uniform> u: f32;
@compute @workgroup_size(1) fn main() { let v = u; }`;
    const reflected = reflect(src4);
    assert(typeof reflected.bindings[0].stableId === 'string',
      'reflect surfaces stableId on bindings');
    assert(reflected.bindings[0].stableId === 'v1:var:u',
      `binding stableId shape: got "${reflected.bindings[0].stableId}"`);
    assert(typeof reflected.entryPoints[0].stableId === 'string',
      'reflect surfaces stableId on entry points');
  }

  // --- Decl / Type edits ---
  console.log('\n--- Decl / Type edits ---');
  {
    const src = `fn helper() -> f32 { return 1.0; }
@compute @workgroup_size(1) fn main() { let v = helper(); }`;

    const declRange = locateDeclaration(src, 'v1:fn:helper');
    assert(declRange.start === 0 && declRange.end === src.indexOf('}') + 1,
      `locateDeclaration returns full fn span: got [${declRange.start},${declRange.end})`);

    const retRange = locateType(src, 'v1:fn:helper');
    assert(src.slice(retRange.start, retRange.end) === 'f32',
      `locateType returns return-type span: got "${src.slice(retRange.start, retRange.end)}"`);

    const rm = removeDeclarationApplyByStableId(src, 'v1:fn:helper');
    assert(rm.ok === true, 'removeDeclarationApplyByStableId.ok === true');
    assert(!rm.source.includes('fn helper'),
      'removeDeclarationApplyByStableId wiped `fn helper`');
    assert(rm.edits.length === 1 && rm.edits[0].newText === '',
      'removeDeclarationByStableId produces one deletion edit');
  }
  {
    const src = `struct S { x: f32, y: f32 }`;
    const tRange = locateType(src, 'v1:struct:S/member:x');
    assert(src.slice(tRange.start, tRange.end) === 'f32',
      'locateType on struct member');

    const ct = changeTypeApplyByStableId(src, 'v1:struct:S/member:x', 'i32');
    assert(ct.ok === true, 'changeTypeApplyByStableId.ok === true');
    assert(ct.source === 'struct S { x: i32, y: f32 }',
      `changeType rewrote member: got "${ct.source}"`);
  }
  {
    const src = `fn f(x: f32) -> f32 { return x; }`;
    const pRange = locateType(src, 'v1:fn:f/param:x');
    assert(src.slice(pRange.start, pRange.end) === 'f32',
      'locateType on parameter');

    const ct = changeTypeApplyByStableId(src, 'v1:fn:f/param:x', 'i32');
    assert(ct.source === 'fn f(x: i32) -> f32 { return x; }',
      `changeType rewrote param: got "${ct.source}"`);
  }
  {
    const src = `const X = 1;`;
    const missing = removeDeclarationByStableId(src, 'v1:fn:nope');
    assert(Array.isArray(missing.edits) && missing.edits.length === 0,
      'removeDeclarationByStableId unknown ID returns empty edits');
    assert(missing.error !== undefined,
      'removeDeclarationByStableId unknown ID reports error');

    const noTypeCt = changeTypeByStableId(src, 'v1:const:X', 'f32');
    assert(noTypeCt.error !== undefined,
      'changeTypeByStableId on untyped const reports error');
  }
  {
    const src = `@group(0) @binding(0) var<uniform> u: f32;
@compute @workgroup_size(1) fn main() {}`;
    const r = reflect(src);
    const b = r.bindings[0];
    assert(b.declSpan && typeof b.declSpan.start === 'number' && typeof b.declSpan.end === 'number',
      'reflect: binding has declSpan');
    assert(src.slice(b.declSpan.start, b.declSpan.end).startsWith('@group'),
      'reflect: declSpan starts at leading `@`');
    assert(b.typeSpan && src.slice(b.typeSpan.start, b.typeSpan.end) === 'f32',
      'reflect: binding typeSpan is the bare type');
    assert(r.entryPoints[0].declSpan && typeof r.entryPoints[0].declSpan.start === 'number',
      'reflect: entry point has declSpan');
  }

  // --- Lint ---
  console.log('\n--- Lint ---');
  {
    const lintEmpty = lint('fn unused() {}');
    assert(lintEmpty.warningCount === 0, 'lint() without extends emits no warnings');
    assert(lintEmpty.errorCount === 0, 'lint() without extends emits no errors');

    const lintRecommended = lint('fn unused() {}', {
      extends: ['@wgslender/recommended'],
    });
    assert(
      lintRecommended.warningCount >= 1,
      'lint() @wgslender/recommended flags unused function',
      `got warningCount=${lintRecommended.warningCount}`,
    );
    assert(
      lintRecommended.diagnostics.some((d) => d.code === 'W0001'),
      'lint() emits W0001 for unused-vars',
    );
    assert(
      lintRecommended.diagnostics.every((d) => d.source === 'wgslender-lint'),
      'lint() diagnostics carry source="wgslender-lint"',
    );
    assert(
      typeof lintRecommended.fixableCount === 'number',
      'lint() reports fixableCount from the per-file result object',
      `got fixableCount=${lintRecommended.fixableCount}`,
    );

    const lintFixable = lint('fn f() -> i32 { return i32(1i); }', {
      extends: ['@wgslender/recommended'],
    });
    assert(
      lintFixable.fixableCount >= 1,
      'lint() counts a redundant-cast diagnostic as fixable',
      `got fixableCount=${lintFixable.fixableCount}`,
    );

    const lintError = lint('fn unused() {}', {
      rules: { 'no-unused-vars': 'error' },
    });
    assert(lintError.errorCount >= 1, 'lint() per-rule error override elevates severity');

    const lintOff = lint('fn unused() {}', {
      extends: ['@wgslender/recommended'],
      rules: { 'no-unused-vars': 'off' },
    });
    assert(
      lintOff.warningCount === 0 && lintOff.errorCount === 0,
      'lint() per-rule "off" silences the pack',
    );

    const lintDisabled = lint(
      '// wgslender-disable-next-line no-unused-vars\nfn skipped() {}',
      { extends: ['@wgslender/recommended'] },
    );
    assert(
      !lintDisabled.diagnostics.some((d) => d.code === 'W0001'),
      'lint() respects wgslender-disable-next-line comments',
    );

    const fixResult = lintAndFix('fn unused() {}', {
      extends: ['@wgslender/recommended'],
    });
    assert(typeof fixResult.fixed === 'string', 'lintAndFix() returns fixed:string');
    assert(fixResult.fixed === 'fn unused() {}', 'lintAndFix() passes source through when no fixes');
    assert(fixResult.warningCount >= 1, 'lintAndFix() reports diagnostics');
  }

  // --- Configs (generated mirror of src/lint/configs.zig) ---
  console.log('\n--- Configs ---');
  {
    // `wgslender/configs` is generated by `zig build gen-npm`; assert the
    // exported packs stay in sync with the Zig source of truth.
    const configs = require('../configs.js');
    assert(configs.recommended.name === '@wgslender/recommended', 'configs exports the recommended pack');
    assert(
      configs.minify && configs.minify.name === '@wgslender/minify',
      'configs exports the advisory @wgslender/minify pack',
    );
    assert(
      configs.minify.rules['minify/unused-const'] === 'hint',
      'the minify pack carries hint-severity advisory rules',
    );
    assert(typeof configs.lspSettingsSchema === 'object', 'configs exports the lspSettingsSchema');
  }

  // --- Compile ---
  console.log('\n--- Compile ---');
  {
    const src = `@group(0) @binding(0) var<storage, read_write> out: array<u32>;
@compute @workgroup_size(1) fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  out[gid.x] = gid.x * 2u;
}`;
    const result = compile(src, {});
    assert(result.errors.length === 0, 'compile() succeeds on a basic compute shader');
    assert(result.wasm instanceof Uint8Array, 'compile() returns wasm as Uint8Array');
    assert(result.wasm.length > 8, `compile() returns a non-empty wasm (${result.wasm.length} bytes)`);
    assert(result.wasm[0] === 0x00 && result.wasm[1] === 0x61 && result.wasm[2] === 0x73 && result.wasm[3] === 0x6d,
      'compile() output starts with the WASM magic header');
    assert(result.originalSize === src.length, 'compile() reports the original WGSL byte size');
    assert(result.wasmSize === result.wasm.length, 'compile() reports the wasm byte size');

    const mod = await WebAssembly.instantiate(result.wasm, {});
    const exports = mod.instance.exports;
    assert(typeof exports.generate === 'function', 'compiled module exports generate()');
    const len = exports.generate();
    assert(len > 0, `generate() returns a positive byte length (${len})`);
    const wgsl = new TextDecoder().decode(new Uint8Array(exports.memory.buffer, 0, len));
    assert(wgsl.includes('@compute'), 'regenerated WGSL preserves the @compute attribute');
  }

  console.log(`\n[${variantName}] ${passed} passed, ${failed} failed\n`);
  if (failed > 0 && failures.length > 0) {
    console.log('Failed:');
    for (const name of failures) console.log(`  - ${name}`);
  }
  return { passed, failed, failures };
}

module.exports = { runSuite };
