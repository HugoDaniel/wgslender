#!/usr/bin/env node
/**
 * CLI test battery for wgslender npm package.
 *
 * Tests every CLI flag and subcommand with real WGSL shaders.
 * Run with: node test-cli.js
 */

const { execSync, execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');

const CLI = path.join(__dirname, 'bin', 'wgslender');
const TESTDATA = path.join(__dirname, '..', '..', 'tests', 'testdata');
const EXAMPLE = path.join(TESTDATA, 'example.wgsl');
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'wgslender-cli-test-'));

let passed = 0;
let failed = 0;

function run(args, opts = {}) {
  const input = opts.stdin || undefined;
  try {
    const result = execFileSync(process.execPath, [CLI, ...args], {
      input,
      encoding: 'utf8',
      timeout: 15000,
      env: { ...process.env, NODE_NO_WARNINGS: '1' },
    });
    return { stdout: result, stderr: '', exitCode: 0 };
  } catch (err) {
    return {
      stdout: (err.stdout || '').toString(),
      stderr: (err.stderr || '').toString(),
      exitCode: err.status,
    };
  }
}

function assert(ok, name, detail) {
  if (ok) {
    console.log(`  \u2713 ${name}`);
    passed++;
  } else {
    console.log(`  \u2717 ${name}`);
    if (detail) console.log(`    ${detail}`);
    failed++;
  }
}

// =============================================
// Test fixtures
// =============================================

const SIMPLE_SHADER = `struct Uniforms { time: f32 }
@group(0) @binding(0) var<uniform> uniforms: Uniforms;
fn helper(t: f32) -> f32 { return sin(t) * 0.5 + 0.5; }
@fragment fn main() -> @location(0) vec4f {
    let brightness = helper(uniforms.time);
    return vec4f(brightness, brightness, brightness, 1.0);
}
`;

const COMPUTE_SHADER = `struct Data { values: array<f32> }
@group(0) @binding(0) var<storage, read_write> data: Data;
fn unused_fn() -> f32 { return 42.0; }
@compute @workgroup_size(64) fn main(@builtin(global_invocation_id) id: vec3u) {
    let i = id.x;
    if (i < arrayLength(&data.values)) {
        data.values[i] = data.values[i] * 2.0;
    }
}
`;

const INVALID_SHADER = `fn foo() -> f32 { return bar; }`;

const MULTI_BINDING = `@group(0) @binding(0) var<uniform> a: f32;
@group(0) @binding(1) var mySampler: sampler;
@group(0) @binding(2) var myTexture: texture_2d<f32>;
@fragment fn main() -> @location(0) vec4f {
    return textureSample(myTexture, mySampler, vec2f(a));
}
`;

// Write fixtures to temp files
const simpleFile = path.join(TMP, 'simple.wgsl');
const computeFile = path.join(TMP, 'compute.wgsl');
const invalidFile = path.join(TMP, 'invalid.wgsl');
const multiFile = path.join(TMP, 'multi.wgsl');
fs.writeFileSync(simpleFile, SIMPLE_SHADER);
fs.writeFileSync(computeFile, COMPUTE_SHADER);
fs.writeFileSync(invalidFile, INVALID_SHADER);
fs.writeFileSync(multiFile, MULTI_BINDING);

// =============================================
// Help & Version
// =============================================
console.log('--- Help & Version ---');

{
  const r = run(['--help']);
  assert(r.exitCode === 0, '--help exits 0');
  assert(r.stdout.includes('Usage: wgslender'), '--help shows usage');
  assert(r.stdout.includes('--source-map'), '--help lists --source-map');
  assert(r.stdout.includes('--no-tree-shaking'), '--help lists --no-tree-shaking');
  assert(r.stdout.includes('validate'), '--help lists validate subcommand');
}

{
  const r = run(['-h']);
  assert(r.exitCode === 0, '-h is alias for --help');
}

{
  const r = run(['--version']);
  assert(r.exitCode === 0, '--version exits 0');
  assert(/wgslender \d+\.\d+\.\d+/.test(r.stdout), `--version shows version: ${r.stdout.trim()}`);
}

{
  const r = run(['-v']);
  assert(r.exitCode === 0, '-v is alias for --version');
}

// =============================================
// Basic minification
// =============================================
console.log('\n--- Basic Minification ---');

{
  const r = run([simpleFile]);
  assert(r.exitCode === 0, 'Minify file exits 0');
  assert(r.stdout.length < SIMPLE_SHADER.length, `Output smaller than input (${r.stdout.length} < ${SIMPLE_SHADER.length})`);
  assert(r.stdout.includes('fn main('), 'Entry point name preserved');
  assert(!r.stdout.includes('// '), 'Comments removed');
}

{
  const r = run([], { stdin: SIMPLE_SHADER });
  assert(r.exitCode === 0, 'Minify from stdin exits 0');
  assert(r.stdout.length < SIMPLE_SHADER.length, 'Stdin: output smaller than input');
}

{
  const outFile = path.join(TMP, 'out.wgsl');
  const r = run(['-o', outFile, simpleFile]);
  assert(r.exitCode === 0, '-o writes output file');
  assert(fs.existsSync(outFile), '-o file exists');
  const content = fs.readFileSync(outFile, 'utf8');
  assert(content.length < SIMPLE_SHADER.length, '-o file is minified');
  assert(content.includes('fn main('), '-o file has entry point');
}

{
  const outFile = path.join(TMP, 'out2.wgsl');
  const r = run(['--output', outFile, simpleFile]);
  assert(r.exitCode === 0, '--output is alias for -o');
  assert(fs.existsSync(outFile), '--output file exists');
}

// Test with the real example.wgsl if available
if (fs.existsSync(EXAMPLE)) {
  const r = run([EXAMPLE]);
  assert(r.exitCode === 0, 'Minify testdata/example.wgsl exits 0');
  const original = fs.readFileSync(EXAMPLE, 'utf8');
  assert(r.stdout.length < original.length, `example.wgsl: ${r.stdout.length} < ${original.length} bytes`);
}

// =============================================
// --no-mangle
// =============================================
console.log('\n--- --no-mangle ---');

{
  const r = run(['--no-mangle', simpleFile]);
  assert(r.exitCode === 0, '--no-mangle exits 0');
  assert(r.stdout.includes('helper'), '--no-mangle preserves function name "helper"');
  assert(r.stdout.includes('brightness'), '--no-mangle preserves variable name "brightness"');
}

{
  // Without --no-mangle, identifiers are shortened
  const r = run([simpleFile]);
  assert(!r.stdout.includes('helper'), 'Default: "helper" is renamed');
  assert(!r.stdout.includes('brightness'), 'Default: "brightness" is renamed');
}

// =============================================
// --no-whitespace
// =============================================
console.log('\n--- --no-whitespace ---');

{
  const r = run(['--no-whitespace', '--no-mangle', simpleFile]);
  assert(r.exitCode === 0, '--no-whitespace exits 0');
  // With no whitespace minification, the output should retain some formatting
  assert(r.stdout.includes('\n'), '--no-whitespace retains newlines');
}

{
  // Default: whitespace is removed, everything on fewer lines
  const rDefault = run([simpleFile]);
  const rNoWs = run(['--no-whitespace', simpleFile]);
  assert(rNoWs.stdout.length > rDefault.stdout.length,
    `--no-whitespace output larger (${rNoWs.stdout.length} > ${rDefault.stdout.length})`);
}

// =============================================
// --no-tree-shaking
// =============================================
console.log('\n--- --no-tree-shaking ---');

{
  const r = run(['--no-tree-shaking', '--no-mangle', computeFile]);
  assert(r.exitCode === 0, '--no-tree-shaking exits 0');
  assert(r.stdout.includes('unused_fn'), '--no-tree-shaking keeps unused function');
}

{
  // Default: tree shaking removes unused code
  const r = run(['--no-mangle', computeFile]);
  assert(!r.stdout.includes('unused_fn'), 'Default: tree shaking removes unused_fn');
}

// =============================================
// --mangle-external-bindings
// =============================================
console.log('\n--- --mangle-external-bindings ---');

{
  const rDefault = run([simpleFile]);
  assert(rDefault.stdout.includes('uniforms'), 'Default: "uniforms" binding name preserved');
}

{
  const r = run(['--mangle-external-bindings', simpleFile]);
  assert(r.exitCode === 0, '--mangle-external-bindings exits 0');
  assert(!r.stdout.includes('uniforms'), '--mangle-external-bindings renames binding');
}

// =============================================
// --preserve-uniform-struct-types
// =============================================
console.log('\n--- --preserve-uniform-struct-types ---');

{
  // Default: struct type name may be renamed
  const rDefault = run([simpleFile]);
  // The struct name "Uniforms" should be renamed by default
  const defaultHasUniforms = rDefault.stdout.includes('Uniforms');

  const r = run(['--preserve-uniform-struct-types', simpleFile]);
  assert(r.exitCode === 0, '--preserve-uniform-struct-types exits 0');
  assert(r.stdout.includes('Uniforms'), '--preserve-uniform-struct-types keeps "Uniforms" struct name');
  // Only meaningful if default renames it
  if (!defaultHasUniforms) {
    assert(true, 'Confirmed: default renames struct, flag preserves it');
  }
}

// =============================================
// --keep-names
// =============================================
console.log('\n--- --keep-names ---');

{
  const r = run(['--keep-names', 'helper', simpleFile]);
  assert(r.exitCode === 0, '--keep-names exits 0');
  assert(r.stdout.includes('helper'), '--keep-names preserves "helper"');
}

{
  const r = run(['--keep-names', 'helper,uniforms', simpleFile]);
  assert(r.stdout.includes('helper'), '--keep-names comma-separated: preserves "helper"');
  assert(r.stdout.includes('uniforms'), '--keep-names comma-separated: preserves "uniforms"');
}

{
  // Without keep-names, helper is renamed
  const r = run([simpleFile]);
  assert(!r.stdout.includes('helper'), 'Default: "helper" is renamed');
}

// =============================================
// --config
// =============================================
console.log('\n--- --config ---');

{
  const configFile = path.join(TMP, 'config.json');
  fs.writeFileSync(configFile, JSON.stringify({
    minifyWhitespace: true,
    minifyIdentifiers: false,
    keepNames: ['helper']
  }));
  const r = run(['--config', configFile, simpleFile]);
  assert(r.exitCode === 0, '--config exits 0');
  assert(r.stdout.includes('helper'), '--config with minifyIdentifiers=false preserves names');
}

{
  const configFile = path.join(TMP, 'config2.json');
  fs.writeFileSync(configFile, JSON.stringify({
    mangleExternalBindings: true,
    treeShaking: false,
  }));
  const r = run(['--config', configFile, '--no-mangle', computeFile]);
  assert(r.stdout.includes('unused_fn'), '--config treeShaking=false keeps unused code');
}

// =============================================
// --source-map
// =============================================
console.log('\n--- --source-map ---');

{
  const outFile = path.join(TMP, 'sourcemap.min.wgsl');
  const r = run(['--source-map', '-o', outFile, simpleFile]);
  assert(r.exitCode === 0, '--source-map exits 0');

  const mapFile = outFile + '.map';
  assert(fs.existsSync(mapFile), '--source-map creates .map file');

  if (fs.existsSync(mapFile)) {
    const map = JSON.parse(fs.readFileSync(mapFile, 'utf8'));
    assert(map.version === 3, 'Source map has version 3');
    assert(typeof map.mappings === 'string', 'Source map has mappings field');
    assert(Array.isArray(map.sources), 'Source map has sources array');
  }
}

// =============================================
// --source-map-inline
// =============================================
console.log('\n--- --source-map-inline ---');

{
  const outFile = path.join(TMP, 'inline.min.wgsl');
  const r = run(['--source-map-inline', '-o', outFile, simpleFile]);
  assert(r.exitCode === 0, '--source-map-inline exits 0');

  const content = fs.readFileSync(outFile, 'utf8');
  assert(content.includes('//# sourceMappingURL=data:application/json;base64,'),
    '--source-map-inline embeds data URI comment');

  // Decode and verify the inline source map
  const match = content.match(/\/\/# sourceMappingURL=data:application\/json;base64,(.+)/);
  if (match) {
    const map = JSON.parse(Buffer.from(match[1], 'base64').toString());
    assert(map.version === 3, 'Inline source map has version 3');
    assert(typeof map.mappings === 'string', 'Inline source map has mappings');
  }
}

{
  // Without -o, inline source map goes to stdout
  const r = run(['--source-map-inline', simpleFile]);
  assert(r.exitCode === 0, '--source-map-inline to stdout exits 0');
  assert(r.stdout.includes('//# sourceMappingURL=data:application/json;base64,'),
    '--source-map-inline to stdout includes data URI');
}

// =============================================
// --source-map-sources
// =============================================
console.log('\n--- --source-map-sources ---');

{
  const outFile = path.join(TMP, 'withsources.min.wgsl');
  const r = run(['--source-map', '--source-map-sources', '-o', outFile, simpleFile]);
  assert(r.exitCode === 0, '--source-map-sources exits 0');

  const mapFile = outFile + '.map';
  if (fs.existsSync(mapFile)) {
    const map = JSON.parse(fs.readFileSync(mapFile, 'utf8'));
    assert(Array.isArray(map.sourcesContent) && map.sourcesContent.length > 0,
      '--source-map-sources includes sourcesContent');
    if (map.sourcesContent && map.sourcesContent[0]) {
      assert(map.sourcesContent[0].includes('struct Uniforms'),
        'sourcesContent contains original source');
    }
  }
}

// =============================================
// validate subcommand
// =============================================
console.log('\n--- validate subcommand ---');

{
  const r = run(['validate', '--help']);
  assert(r.exitCode === 0, 'validate --help exits 0');
  assert(r.stdout.includes('Validate WGSL'), 'validate --help shows description');
}

{
  const r = run(['validate', simpleFile]);
  assert(r.exitCode === 0, 'validate valid shader exits 0');
  assert(r.stdout.trim() === 'valid', 'validate valid shader prints "valid"');
}

{
  const r = run(['validate', invalidFile]);
  assert(r.exitCode === 1, 'validate invalid shader exits 1');
  assert(r.stdout.includes('invalid'), 'validate invalid shader prints "invalid"');
  assert(r.stderr.includes('error'), 'validate invalid shader has error on stderr');
}

{
  const r = run(['validate', '--json', simpleFile]);
  assert(r.exitCode === 0, 'validate --json exits 0');
  const result = JSON.parse(r.stdout);
  assert(result.valid === true, 'validate --json: valid=true');
  assert(Array.isArray(result.diagnostics), 'validate --json: has diagnostics array');
  assert(typeof result.errorCount === 'number', 'validate --json: has errorCount');
}

{
  const r = run(['validate', '--json', invalidFile]);
  assert(r.exitCode === 1, 'validate --json invalid exits 1');
  const result = JSON.parse(r.stdout);
  assert(result.valid === false, 'validate --json invalid: valid=false');
  assert(result.errorCount > 0, 'validate --json invalid: errorCount > 0');
  assert(result.diagnostics.length > 0, 'validate --json invalid: has diagnostics');
  const diag = result.diagnostics[0];
  assert(diag.severity === 'error', 'validate --json: diagnostic has severity');
  assert(typeof diag.message === 'string', 'validate --json: diagnostic has message');
}

{
  // Validate from stdin
  const r = run(['validate'], { stdin: SIMPLE_SHADER });
  assert(r.exitCode === 0, 'validate from stdin exits 0');
  assert(r.stdout.trim() === 'valid', 'validate from stdin: valid');
}

// =============================================
// reflect subcommand
// =============================================
console.log('\n--- reflect subcommand ---');

{
  const r = run(['reflect', '--help']);
  assert(r.exitCode === 0, 'reflect --help exits 0');
  assert(r.stdout.includes('Extract binding'), 'reflect --help shows description');
}

{
  const r = run(['reflect', multiFile]);
  assert(r.exitCode === 0, 'reflect exits 0');
  const result = JSON.parse(r.stdout);
  assert(result.bindings.length === 3, 'reflect: found 3 bindings');
  assert(result.entryPoints.length === 1, 'reflect: found 1 entry point');
  assert(result.entryPoints[0].stage === 'fragment', 'reflect: entry point is fragment');
  const uniform = result.bindings.find(b => b.name === 'a');
  assert(uniform && uniform.group === 0 && uniform.binding === 0, 'reflect: uniform binding at group=0, binding=0');
}

{
  const r = run(['reflect', '--compact', multiFile]);
  assert(r.exitCode === 0, 'reflect --compact exits 0');
  // Compact output should be a single line
  assert(!r.stdout.includes('\n  '), 'reflect --compact: no pretty-printing');
}

{
  const outFile = path.join(TMP, 'reflect-out.json');
  const r = run(['reflect', '-o', outFile, multiFile]);
  assert(r.exitCode === 0, 'reflect -o exits 0');
  assert(fs.existsSync(outFile), 'reflect -o creates output file');
  const result = JSON.parse(fs.readFileSync(outFile, 'utf8'));
  assert(result.bindings.length === 3, 'reflect -o: file has correct data');
}

{
  // Reflect from stdin
  const r = run(['reflect'], { stdin: MULTI_BINDING });
  assert(r.exitCode === 0, 'reflect from stdin exits 0');
  const result = JSON.parse(r.stdout);
  assert(result.bindings.length === 3, 'reflect from stdin: found 3 bindings');
}

{
  // Reflect compute shader (workgroup size)
  const r = run(['reflect', computeFile]);
  const result = JSON.parse(r.stdout);
  assert(result.entryPoints.length === 1, 'reflect compute: found 1 entry point');
  assert(result.entryPoints[0].stage === 'compute', 'reflect compute: stage=compute');
  assert(result.entryPoints[0].workgroupSize[0] === 64, 'reflect compute: workgroupSize[0]=64');
}

// =============================================
// Flag combinations
// =============================================
console.log('\n--- Flag Combinations ---');

{
  const r = run(['--no-mangle', '--no-whitespace', simpleFile]);
  assert(r.exitCode === 0, '--no-mangle + --no-whitespace exits 0');
  assert(r.stdout.includes('helper'), 'Combo: identifiers preserved');
  assert(r.stdout.includes('\n'), 'Combo: whitespace preserved');
}

{
  const r = run(['--no-tree-shaking', '--mangle-external-bindings', computeFile]);
  assert(r.exitCode === 0, '--no-tree-shaking + --mangle-external-bindings exits 0');
  // unused_fn should still exist (no tree shaking) but identifiers are mangled
  // External binding 'data' should be renamed
  assert(!r.stdout.includes('var<storage,read_write> data') &&
         !r.stdout.includes('var<storage, read_write> data'),
    'Combo: external binding mangled');
}

{
  const r = run(['--keep-names', 'helper', '--no-tree-shaking', '--preserve-uniform-struct-types', simpleFile]);
  assert(r.exitCode === 0, 'Multiple flags combined exits 0');
  assert(r.stdout.includes('helper'), 'Combo: keep-names works with other flags');
  assert(r.stdout.includes('Uniforms'), 'Combo: preserve-uniform-struct-types works');
}

// =============================================
// Config auto-discovery
// =============================================
console.log('\n--- Config Auto-Discovery ---');

{
  // Config in same dir as input file
  const dir = fs.mkdtempSync(path.join(TMP, 'cfg-same-'));
  fs.writeFileSync(path.join(dir, 'wgslender.json'), JSON.stringify({ minifyIdentifiers: false }));
  fs.writeFileSync(path.join(dir, 'shader.wgsl'), SIMPLE_SHADER);
  const r = run([path.join(dir, 'shader.wgsl')]);
  assert(r.exitCode === 0, 'Config same dir: exits 0');
  assert(r.stdout.includes('helper'), 'Config same dir: auto-discovered config disables mangling');
}

{
  // Config in parent dir
  const dir = fs.mkdtempSync(path.join(TMP, 'cfg-parent-'));
  const sub = path.join(dir, 'sub');
  fs.mkdirSync(sub);
  fs.writeFileSync(path.join(dir, 'wgslender.json'), JSON.stringify({ minifyIdentifiers: false }));
  fs.writeFileSync(path.join(sub, 'shader.wgsl'), SIMPLE_SHADER);
  const r = run([path.join(sub, 'shader.wgsl')]);
  assert(r.exitCode === 0, 'Config parent dir: exits 0');
  assert(r.stdout.includes('helper'), 'Config parent dir: found config in parent');
}

{
  // Config in grandparent dir
  const dir = fs.mkdtempSync(path.join(TMP, 'cfg-gp-'));
  const sub = path.join(dir, 'a', 'b');
  fs.mkdirSync(sub, { recursive: true });
  fs.writeFileSync(path.join(dir, '.wgslenderrc'), JSON.stringify({ treeShaking: false }));
  fs.writeFileSync(path.join(sub, 'shader.wgsl'), COMPUTE_SHADER);
  const r = run(['--no-mangle', path.join(sub, 'shader.wgsl')]);
  assert(r.exitCode === 0, 'Config grandparent: exits 0');
  assert(r.stdout.includes('unused_fn'), 'Config grandparent: .wgslenderrc treeShaking=false works');
}

{
  // No config anywhere → defaults (identifiers renamed)
  const dir = fs.mkdtempSync(path.join(TMP, 'cfg-none-'));
  fs.writeFileSync(path.join(dir, 'shader.wgsl'), SIMPLE_SHADER);
  const r = run([path.join(dir, 'shader.wgsl')]);
  assert(r.exitCode === 0, 'No config: exits 0');
  assert(!r.stdout.includes('helper'), 'No config: default mangling renames helper');
}

{
  // Priority: wgslender.json beats .wgslenderrc in same dir
  const dir = fs.mkdtempSync(path.join(TMP, 'cfg-prio1-'));
  fs.writeFileSync(path.join(dir, 'wgslender.json'), JSON.stringify({ minifyIdentifiers: false }));
  fs.writeFileSync(path.join(dir, '.wgslenderrc'), JSON.stringify({ minifyIdentifiers: true }));
  fs.writeFileSync(path.join(dir, 'shader.wgsl'), SIMPLE_SHADER);
  const r = run([path.join(dir, 'shader.wgsl')]);
  assert(r.stdout.includes('helper'), 'Priority: wgslender.json wins over .wgslenderrc');
}

{
  // Priority: .wgslenderrc beats .wgslenderrc.json in same dir
  const dir = fs.mkdtempSync(path.join(TMP, 'cfg-prio2-'));
  fs.writeFileSync(path.join(dir, '.wgslenderrc'), JSON.stringify({ minifyIdentifiers: false }));
  fs.writeFileSync(path.join(dir, '.wgslenderrc.json'), JSON.stringify({ minifyIdentifiers: true }));
  fs.writeFileSync(path.join(dir, 'shader.wgsl'), SIMPLE_SHADER);
  const r = run([path.join(dir, 'shader.wgsl')]);
  assert(r.stdout.includes('helper'), 'Priority: .wgslenderrc wins over .wgslenderrc.json');
}

{
  // --config explicit path ignores auto-discovery
  const dir = fs.mkdtempSync(path.join(TMP, 'cfg-explicit-'));
  fs.writeFileSync(path.join(dir, 'wgslender.json'), JSON.stringify({ minifyIdentifiers: false }));
  const explicitConfig = path.join(dir, 'custom.json');
  fs.writeFileSync(explicitConfig, JSON.stringify({ minifyIdentifiers: true }));
  fs.writeFileSync(path.join(dir, 'shader.wgsl'), SIMPLE_SHADER);
  const r = run(['--config', explicitConfig, path.join(dir, 'shader.wgsl')]);
  assert(!r.stdout.includes('helper'), '--config explicit: uses explicit config, not auto-discovered');
}

{
  // --no-config skips auto-discovery
  const dir = fs.mkdtempSync(path.join(TMP, 'cfg-noconfig-'));
  fs.writeFileSync(path.join(dir, 'wgslender.json'), JSON.stringify({ minifyIdentifiers: false }));
  fs.writeFileSync(path.join(dir, 'shader.wgsl'), SIMPLE_SHADER);
  const r = run(['--no-config', path.join(dir, 'shader.wgsl')]);
  assert(!r.stdout.includes('helper'), '--no-config: ignores config in same dir');
}

{
  // CLI --no-mangle overrides config minifyIdentifiers: true
  const dir = fs.mkdtempSync(path.join(TMP, 'cfg-override1-'));
  fs.writeFileSync(path.join(dir, 'wgslender.json'), JSON.stringify({ minifyIdentifiers: true }));
  fs.writeFileSync(path.join(dir, 'shader.wgsl'), SIMPLE_SHADER);
  const r = run(['--no-mangle', path.join(dir, 'shader.wgsl')]);
  assert(r.stdout.includes('helper'), 'CLI override: --no-mangle wins over config minifyIdentifiers=true');
}

{
  // CLI --keep-names + config keepNames merge
  const dir = fs.mkdtempSync(path.join(TMP, 'cfg-merge-'));
  fs.writeFileSync(path.join(dir, 'wgslender.json'), JSON.stringify({ keepNames: ['brightness'] }));
  fs.writeFileSync(path.join(dir, 'shader.wgsl'), SIMPLE_SHADER);
  const r = run(['--keep-names', 'helper', path.join(dir, 'shader.wgsl')]);
  assert(r.stdout.includes('helper'), 'keepNames merge: CLI name preserved');
  assert(r.stdout.includes('brightness'), 'keepNames merge: config name preserved');
}

{
  // Stdin input → walks from cwd (no config in tmp → defaults apply)
  const dir = fs.mkdtempSync(path.join(TMP, 'cfg-stdin-'));
  fs.writeFileSync(path.join(dir, 'wgslender.json'), JSON.stringify({ minifyIdentifiers: false }));
  // Run with cwd set to dir so auto-discovery finds the config
  try {
    const result = execFileSync(process.execPath, [CLI], {
      input: SIMPLE_SHADER,
      encoding: 'utf8',
      timeout: 15000,
      cwd: dir,
      env: { ...process.env, NODE_NO_WARNINGS: '1' },
    });
    assert(result.includes('helper'), 'Stdin: auto-discovery from cwd finds config');
  } catch (err) {
    assert(false, 'Stdin: auto-discovery from cwd finds config', err.message);
  }
}

{
  // Config with preserveUniformStructTypes
  const dir = fs.mkdtempSync(path.join(TMP, 'cfg-preserve-'));
  fs.writeFileSync(path.join(dir, 'wgslender.json'), JSON.stringify({ preserveUniformStructTypes: true }));
  fs.writeFileSync(path.join(dir, 'shader.wgsl'), SIMPLE_SHADER);
  const r = run([path.join(dir, 'shader.wgsl')]);
  assert(r.stdout.includes('Uniforms'), 'Config preserveUniformStructTypes: struct name kept');
}

{
  // Config with treeShaking: false
  const dir = fs.mkdtempSync(path.join(TMP, 'cfg-tree-'));
  fs.writeFileSync(path.join(dir, 'wgslender.json'), JSON.stringify({ treeShaking: false }));
  fs.writeFileSync(path.join(dir, 'shader.wgsl'), COMPUTE_SHADER);
  const r = run(['--no-mangle', path.join(dir, 'shader.wgsl')]);
  assert(r.stdout.includes('unused_fn'), 'Config treeShaking=false: unused code preserved');
}

{
  // --no-config + --config → --config wins (explicit takes precedence over skip)
  const dir = fs.mkdtempSync(path.join(TMP, 'cfg-noconfig-explicit-'));
  const explicitConfig = path.join(dir, 'custom.json');
  fs.writeFileSync(explicitConfig, JSON.stringify({ minifyIdentifiers: false }));
  fs.writeFileSync(path.join(dir, 'shader.wgsl'), SIMPLE_SHADER);
  const r = run(['--no-config', '--config', explicitConfig, path.join(dir, 'shader.wgsl')]);
  assert(r.stdout.includes('helper'), '--no-config + --config: explicit config wins');
}

{
  // Help text includes --no-config
  const r = run(['--help']);
  assert(r.stdout.includes('--no-config'), 'Help: lists --no-config flag');
  assert(r.stdout.includes('wgslender.json'), 'Help: mentions config file names');
}

// =============================================
// Error cases
// =============================================
console.log('\n--- Error Cases ---');

{
  const r = run([path.join(TMP, 'nonexistent.wgsl')]);
  assert(r.exitCode !== 0, 'Nonexistent file exits non-zero');
}

{
  const badConfig = path.join(TMP, 'bad-config.json');
  fs.writeFileSync(badConfig, 'not json!!!');
  const r = run(['--config', badConfig, simpleFile]);
  assert(r.exitCode !== 0, 'Bad config file exits non-zero');
  assert(r.stderr.includes('Error loading config'), 'Bad config shows error message');
}

{
  const r = run(['--unknown-flag', simpleFile]);
  assert(r.exitCode !== 0, 'Unknown flag exits non-zero');
}

// =============================================
// Summary
// =============================================
console.log(`\n${passed} passed, ${failed} failed\n`);

// Cleanup
fs.rmSync(TMP, { recursive: true, force: true });

process.exit(failed > 0 ? 1 : 0);
