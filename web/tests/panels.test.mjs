// The three output panels, tested as pure data — no DOM, no CodeMirror.
//
// `panels.ts` is the whole of the right-hand pane's logic: what `minify`
// produces under each pill, what `reflect` says about a shader, and how a
// `publishDiagnostics` payload becomes sorted rows. Everything the browser
// adds on top is markup, so this file is where the panels are actually
// pinned.
//
// The reflection assertions use real numbers from the layout engine on
// purpose — struct field offsets are the reflection panel's entire reason to
// exist, and a test that only checked "some fields came back" would not
// notice the engine getting §6.2.10 padding wrong.

import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';

import { initialize as initLsp, sendMessage } from 'wgslender-lsp';
import { initialize as initMinifier, reflect } from 'wgslender';

import { sampleShader, sampleUri } from '../src/scripts/playground/sample-shader.ts';
import {
  buildMinifyModel,
  buildReflectModel,
  formatDiagnostics,
  minifyOptions,
  defaultMinifyOptions,
} from '../src/scripts/playground/panels.ts';

const require = createRequire(import.meta.url);

/** A `publishDiagnostics` payload captured from a real server session. */
let mixedPayload;

before(async () => {
  await initMinifier();

  const lspWasm = await readFile(require.resolve('wgslender-lsp/wasm'));
  await initLsp({ wasmModule: await WebAssembly.compile(lspWasm) });

  let id = 0;
  const send = (message) => sendMessage(JSON.stringify(message)).map((m) => JSON.parse(m));
  send({ jsonrpc: '2.0', id: ++id, method: 'initialize', params: { processId: null, rootUri: null, capabilities: {} } });
  send({ jsonrpc: '2.0', method: 'initialized', params: {} });

  // Two broken member accesses plus the sample's own unused helper, so the
  // capture carries several errors *and* a warning — the input the sort has
  // to put in order.
  const broken = sampleShader
    .replace('camera.time', 'camera.tim')
    .replace('particles[i].pos', 'particles[i].po');

  const messages = send({
    jsonrpc: '2.0',
    method: 'textDocument/didOpen',
    params: { textDocument: { uri: sampleUri, languageId: 'wgsl', version: 1, text: broken } },
  });
  mixedPayload = messages.find((m) => m.method === 'textDocument/publishDiagnostics')?.params;
  assert.ok(mixedPayload, 'the server published no diagnostics to capture');
});

// ---------------------------------------------------------------- minify ---

test('the option pills cover exactly the flags the panel offers', () => {
  assert.deepEqual(
    minifyOptions.map((o) => o.key),
    [
      'minifyWhitespace',
      'minifyIdentifiers',
      'minifySyntax',
      'mangleExternalBindings',
      'treeShaking',
      'sortDeclarations',
      'scopeLocalRename',
    ],
  );

  // The pills must open showing what `minify(source)` does with no options,
  // or the panel misreports the library's stock behaviour.
  assert.deepEqual(defaultMinifyOptions(), {
    minifyWhitespace: true,
    minifyIdentifiers: true,
    minifySyntax: true,
    mangleExternalBindings: false,
    treeShaking: true,
    sortDeclarations: false,
    scopeLocalRename: false,
  });

  for (const option of minifyOptions) {
    assert.ok(option.label, `${option.key} needs a label`);
    assert.ok(option.help, `${option.key} needs a description`);
  }
});

test('the default model shrinks the sample and tree-shakes the dead helper', () => {
  const model = buildMinifyModel(sampleShader);

  assert.deepEqual(model.errors, []);
  assert.doesNotMatch(model.code, /unused_helper/);
  assert.ok(model.stats.minified < model.stats.original);

  // Sizes are UTF-8 bytes: the sample's comments contain an em dash, so a
  // `.length` here would disagree with the toolkit.
  assert.equal(model.stats.original, new TextEncoder().encode(sampleShader).length);
  assert.equal(
    model.stats.savedPct,
    Math.round((1 - model.stats.minified / model.stats.original) * 1000) / 10,
  );
  assert.ok(model.stats.savedPct > 40, `expected a real saving, got ${model.stats.savedPct}%`);
});

test('turning tree shaking off brings the dead helper back', () => {
  const shaken = buildMinifyModel(sampleShader);
  const kept = buildMinifyModel(sampleShader, { treeShaking: false });

  // The helper survives under a renamed identifier, so match its body.
  assert.match(kept.code, /return (\w+)\*\1\*\1;/);
  assert.ok(kept.stats.minified > shaken.stats.minified);
});

test('external bindings keep their names unless the pill says otherwise', () => {
  assert.match(buildMinifyModel(sampleShader).code, /camera/);
  assert.doesNotMatch(buildMinifyModel(sampleShader, { mangleExternalBindings: true }).code, /camera/);
});

test('turning identifier renaming off keeps the called helper readable', () => {
  const readable = buildMinifyModel(sampleShader, { minifyIdentifiers: false });
  const renamed = buildMinifyModel(sampleShader);

  assert.match(readable.code, /fn wave\(/);
  assert.match(readable.code, /frag/, 'parameters keep their names too');
  assert.match(readable.code, /struct Camera/, 'so do user types');

  // The contrast is the point: the same helper loses its name by default.
  assert.doesNotMatch(renamed.code, /fn wave\(/);
  assert.ok(readable.stats.minified > renamed.stats.minified);

  // Tree shaking is a separate pill: the dead helper goes either way.
  assert.doesNotMatch(readable.code, /unused_helper/);
});

test('sort + scope-local rename changes the bytes but not the interface', () => {
  const plain = buildMinifyModel(sampleShader);
  const packed = buildMinifyModel(sampleShader, { sortDeclarations: true, scopeLocalRename: true });

  assert.notEqual(packed.code, plain.code, 'the compression-friendly pills should reorder output');

  // What a consumer binds against must survive the reshuffle. Compare the
  // reflected interface, not the JSON: `sortDeclarations` moves declarations,
  // so source offsets legitimately differ.
  const interfaceOf = (code) =>
    reflect(code)
      .bindings.map((b) => [b.group, b.binding, b.name, b.type].join('/'))
      .sort();
  assert.deepEqual(interfaceOf(packed.code), interfaceOf(plain.code));
});

test('a source that will not parse reports errors instead of throwing', () => {
  const model = buildMinifyModel('fn oops( {');

  assert.ok(model.errors.length > 0);
  assert.ok(
    model.errors.every((message) => typeof message === 'string' && message.length > 0),
    `expected plain messages, got ${JSON.stringify(model.errors)}`,
  );
  assert.equal(model.stats.savedPct, 0);
});

test('an empty document does not divide by zero', () => {
  const model = buildMinifyModel('');
  assert.equal(model.stats.original, 0);
  assert.equal(model.stats.savedPct, 0);
});

// --------------------------------------------------------------- reflect ---

test('bindings are grouped by kind, with group and binding numbers', () => {
  const model = buildReflectModel(sampleShader);

  assert.deepEqual(
    model.bindingGroups.map((g) => g.title),
    ['Uniforms', 'Storage', 'Textures', 'Samplers'],
  );
  assert.deepEqual(
    model.bindingGroups.map((g) => g.rows.map((r) => [r.name, r.group, r.binding, r.type])),
    [
      [['camera', 0, 0, 'Camera']],
      [['particles', 0, 1, 'array<Particle>']],
      [['noise_tex', 0, 2, 'texture_2d<f32>']],
      [['noise_smp', 0, 3, 'sampler']],
    ],
  );

  // The storage buffer's access mode is part of its binding-layout identity.
  assert.equal(model.bindingGroups[1].rows[0].access, 'read');

  // The detail column is what makes the table worth reading: a size for
  // buffers, a stride for arrays, the sample type for textures.
  assert.deepEqual(
    model.bindingGroups.map((g) => g.rows.map((r) => r.detail)),
    [['80 B, align 16'], ['stride 32 B, runtime-sized'], ['sampled f32'], ['non-comparison']],
  );
});

test('the grouping agrees with the engine’s own subset views', () => {
  // `panels.ts` derives the four groups from `bindings[]` rather than reading
  // the v2 `uniforms`/`storage`/`textures`/`samplers` arrays, so that it also
  // works against v1 output. This pins the two classifications together: if
  // the engine ever reclassifies a binding, this fails rather than the panel
  // quietly disagreeing with `reflect --json`.
  const model = buildReflectModel(sampleShader);
  const info = reflect(sampleShader);
  const names = (rows) => rows.map((r) => r.name).sort();

  assert.deepEqual(names(model.bindingGroups[0].rows), info.uniforms.map((b) => b.name).sort());
  assert.deepEqual(names(model.bindingGroups[1].rows), info.storage.map((b) => b.name).sort());
  assert.deepEqual(names(model.bindingGroups[2].rows), info.textures.map((b) => b.name).sort());
  assert.deepEqual(names(model.bindingGroups[3].rows), info.samplers.map((b) => b.name).sort());
});

test('struct rows carry the §6.2.10 offsets that justify the panel', () => {
  const model = buildReflectModel(sampleShader);

  // Sorted by name for a stable rendering order — `reflect` returns structs
  // keyed by name, and object key order is not source order.
  assert.deepEqual(
    model.structs.map((s) => s.name),
    ['Camera', 'Particle'],
  );

  const camera = model.structs[0];
  assert.equal(camera.size, 80);
  assert.equal(camera.alignment, 16);
  assert.deepEqual(
    camera.fields.map((f) => [f.name, f.type, f.offset, f.size, f.alignment]),
    [
      ['view_proj', 'mat4x4<f32>', 0, 64, 16],
      ['eye', 'vec3<f32>', 64, 12, 16],
      // `time` sits at 76, not 72: a vec3 occupies 12 bytes but aligns to 16.
      ['time', 'f32', 76, 4, 4],
    ],
  );
});

test('entry points report their stage, and compute reports its workgroup size', () => {
  const model = buildReflectModel(sampleShader);

  assert.deepEqual(
    model.entryPoints.map((e) => [e.name, e.stage, e.workgroupSize]),
    [
      ['vs_main', 'vertex', ''],
      ['fs_main', 'fragment', ''],
    ],
  );
  assert.deepEqual(model.entryPoints[1].resources, ['camera', 'noise_smp', 'noise_tex']);

  const compute = buildReflectModel('@compute @workgroup_size(8, 4, 1) fn cs() {}');
  assert.deepEqual(
    compute.entryPoints.map((e) => [e.name, e.stage, e.workgroupSize]),
    [['cs', 'compute', '8×4×1']],
  );
});

test('overrides are reported with their id, type and default', () => {
  const model = buildReflectModel(sampleShader);

  assert.deepEqual(
    model.overrides.map((o) => [o.name, o.id, o.type, o.default]),
    [['particle_scale', '', 'f32', '1.0']],
  );

  const withId = buildReflectModel('@id(7) override gain : f32 = 2.0;');
  assert.deepEqual(
    withId.overrides.map((o) => [o.name, o.id]),
    [['gain', '7']],
  );
});

test('an unparseable shader reports errors and empty tables', () => {
  const model = buildReflectModel('fn oops( {');

  assert.ok(model.errors.length > 0);
  assert.deepEqual(model.bindingGroups, []);
  assert.deepEqual(model.structs, []);
});

test('the raw payload is kept for the JSON disclosure', () => {
  const model = buildReflectModel(sampleShader);
  assert.equal(model.raw.version, 2);
  assert.equal(model.raw.bindings.length, 4);
});

// ----------------------------------------------------------- diagnostics ---

test('diagnostic rows map every field the panel renders', () => {
  const rows = formatDiagnostics(mixedPayload);

  assert.ok(rows.length >= 3, `expected errors and a warning, got ${rows.length} rows`);

  const warning = rows.find((r) => r.severity === 'warning');
  assert.equal(warning.code, 'W0001');
  assert.match(warning.message, /unused_helper/);

  const source = mixedPayload.diagnostics.find((d) => d.code === 'W0001');
  // Displayed positions are 1-based; `position` stays the raw LSP one so the
  // click handler can hand it straight to the editor.
  assert.equal(warning.line, source.range.start.line + 1);
  assert.equal(warning.col, source.range.start.character + 1);
  assert.deepEqual(warning.position, source.range.start);

  const error = rows.find((r) => r.severity === 'error');
  assert.equal(error.code, 'E0206');
});

test('rows are sorted errors first, then by position', () => {
  // Feed the captured payload back in reversed: the sort has to restore the
  // order regardless of how the server happened to emit it.
  const forwards = formatDiagnostics(mixedPayload);
  const backwards = formatDiagnostics({
    ...mixedPayload,
    diagnostics: [...mixedPayload.diagnostics].reverse(),
  });
  assert.deepEqual(backwards, forwards);

  const rank = { error: 0, warning: 1, info: 2, hint: 3 };
  let previous = null;
  for (const row of forwards) {
    if (previous) {
      const ordered =
        rank[previous.severity] < rank[row.severity] ||
        (previous.severity === row.severity &&
          (previous.line < row.line || (previous.line === row.line && previous.col <= row.col)));
      assert.ok(ordered, `${JSON.stringify(previous)} should not precede ${JSON.stringify(row)}`);
    }
    previous = row;
  }

  assert.equal(forwards[0].severity, 'error');
  assert.equal(forwards.at(-1).severity, 'warning');
});

test('a clean document and a missing payload both yield no rows', () => {
  assert.deepEqual(formatDiagnostics({ uri: sampleUri, diagnostics: [] }), []);
  assert.deepEqual(formatDiagnostics(undefined), []);
  assert.deepEqual(formatDiagnostics({ uri: sampleUri }), []);
});
