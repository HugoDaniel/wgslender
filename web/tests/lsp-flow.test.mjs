// A full wgslender-lsp session, driven headlessly over `sendMessage` — no
// CodeMirror, no DOM. This pins the wire behaviour the playground's editor
// island depends on: pushed diagnostics, hover, go-to-definition, and the
// `wgslender.showMinifiedOutput` command that feeds the stats bar's gzip
// column. The minifier package's `minify`/`reflect` are checked here too,
// since the panels read them directly.
//
// Node cannot `fetch` a `file:` URL, so the LSP wasm is compiled from bytes
// resolved through the package's `./wasm` export.

import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';

import { initialize as initLsp, sendMessage } from 'wgslender-lsp';
import { initialize as initMinifier, minify, reflect } from 'wgslender';

import { sampleShader, sampleUri, positionOf } from '../src/scripts/playground/sample-shader.ts';

const require = createRequire(import.meta.url);

let nextId = 0;

/** Send a request and return `{ result, error, messages }`. */
function request(method, params) {
  const id = ++nextId;
  const messages = sendMessage(JSON.stringify({ jsonrpc: '2.0', id, method, params })).map((m) =>
    JSON.parse(m),
  );
  const response = messages.find((m) => m.id === id);
  return { result: response?.result, error: response?.error, messages };
}

/** Send a notification and return every message the server pushed back. */
function notify(method, params) {
  return sendMessage(JSON.stringify({ jsonrpc: '2.0', method, params })).map((m) => JSON.parse(m));
}

/** Diagnostics from the last `publishDiagnostics` for `uri` in a batch. */
function diagnosticsIn(messages, uri = sampleUri) {
  const published = messages.filter(
    (m) => m.method === 'textDocument/publishDiagnostics' && m.params?.uri === uri,
  );
  assert.ok(published.length > 0, 'batch carried no publishDiagnostics');
  return published.at(-1).params.diagnostics;
}

const codesIn = (diagnostics) => diagnostics.map((d) => d.code);

/**
 * Sizes reported by the toolkit are UTF-8 bytes, not JS string units — and
 * the sample's comments contain an em dash, so the two differ. The stats bar
 * has to do the same conversion.
 */
const byteLength = (text) => new TextEncoder().encode(text).length;

/** Replace the whole document (the non-ranged `didChange` form). */
function replaceDocument(version, text) {
  return notify('textDocument/didChange', {
    textDocument: { uri: sampleUri, version },
    contentChanges: [{ text }],
  });
}

before(async () => {
  const lspWasm = await readFile(require.resolve('wgslender-lsp/wasm'));
  await initLsp({ wasmModule: await WebAssembly.compile(lspWasm) });
  await initMinifier();
});

test('initialize advertises the capabilities the playground relies on', () => {
  const { result } = request('initialize', {
    processId: null,
    clientInfo: { name: 'wgslender-playground-tests' },
    rootUri: null,
    capabilities: {},
  });

  assert.equal(result.capabilities.positionEncoding, 'utf-16');
  assert.equal(result.capabilities.textDocumentSync.change, 2);
  assert.equal(result.capabilities.hoverProvider, true);
  assert.equal(result.capabilities.inlayHintProvider, true);
  assert.deepEqual(result.capabilities.executeCommandProvider.commands, [
    'wgslender.setMinifyMode',
    'wgslender.toggleMinifyMode',
    'wgslender.recomputeMinifyInsights',
  ]);

  notify('initialized', {});
});

test('didOpen pushes diagnostics in the same batch', () => {
  const messages = notify('textDocument/didOpen', {
    textDocument: { uri: sampleUri, languageId: 'wgsl', version: 1, text: sampleShader },
  });

  const diagnostics = diagnosticsIn(messages);
  assert.deepEqual(codesIn(diagnostics), ['W0001']);
  assert.match(diagnostics[0].message, /unused_helper/);
  assert.equal(
    diagnostics[0].range.start.line,
    positionOf(sampleShader, 'unused_helper').line,
    'W0001 lands on the declaration',
  );
});

test('a bad member access raises E0206, and reverting clears it', () => {
  const broken = sampleShader.replace('camera.time', 'camera.tim');
  const afterBreak = diagnosticsIn(replaceDocument(2, broken));
  assert.ok(codesIn(afterBreak).includes('E0206'), `expected E0206, got ${codesIn(afterBreak)}`);

  const afterFix = diagnosticsIn(replaceDocument(3, sampleShader));
  assert.deepEqual(codesIn(afterFix), ['W0001']);
});

test('hover over a uniform reports its type', () => {
  const { result } = request('textDocument/hover', {
    textDocument: { uri: sampleUri },
    position: positionOf(sampleShader, 'camera.time'),
  });

  const text = typeof result.contents === 'string' ? result.contents : result.contents.value;
  assert.match(text, /Camera/);
});

test('go-to-definition on a call lands on the declaration', () => {
  const { result } = request('textDocument/definition', {
    textDocument: { uri: sampleUri },
    position: positionOf(sampleShader, 'wave(uv, camera.time)'),
  });

  const location = Array.isArray(result) ? result[0] : result;
  assert.equal(location.uri, sampleUri);
  assert.equal(location.range.start.line, positionOf(sampleShader, 'fn wave').line);
});

test('showMinifiedOutput returns text plus byte and gzip counts', () => {
  const { result } = request('workspace/executeCommand', {
    command: 'wgslender.showMinifiedOutput',
    arguments: [sampleUri],
  });

  assert.equal(result.uri, sampleUri);
  assert.match(result.minified_text, /fn fs_main/);
  assert.ok(
    result.byte_count < byteLength(sampleShader),
    'minified output is smaller than the source',
  );
  assert.ok(
    result.gz_count < result.byte_count,
    `gzip (${result.gz_count}) should beat raw (${result.byte_count})`,
  );
});

test('minify shrinks the sample and tree-shakes the unused helper', () => {
  const result = minify(sampleShader);

  assert.deepEqual(result.errors, []);
  assert.equal(result.originalSize, byteLength(sampleShader));
  assert.ok(result.minifiedSize < result.originalSize);
  assert.doesNotMatch(result.code, /unused_helper/);
  assert.match(result.code, /camera/, 'external bindings keep their names by default');
  assert.match(result.code, /fn vs_main/, 'entry points keep their names');

  // Without tree shaking the helper survives — under a renamed identifier, so
  // match its body rather than its name.
  const kept = minify(sampleShader, { treeShaking: false });
  assert.match(kept.code, /return (\w+)\*\1\*\1;/, 'the dead helper survives without tree shaking');
  assert.ok(kept.minifiedSize > result.minifiedSize);
});

test('reflect reports every binding, the override, and both entry points', () => {
  const info = reflect(sampleShader);

  assert.equal(info.version, 2);
  assert.deepEqual(
    info.bindings.map((b) => [b.name, b.group, b.binding, b.addressSpace]),
    [
      ['camera', 0, 0, 'uniform'],
      ['particles', 0, 1, 'storage'],
      ['noise_tex', 0, 2, 'handle'],
      ['noise_smp', 0, 3, 'handle'],
    ],
  );

  const camera = info.bindings[0];
  assert.equal(camera.layout.size, 80);
  assert.deepEqual(
    camera.layout.fields.map((f) => [f.name, f.offset, f.size]),
    [
      ['view_proj', 0, 64],
      ['eye', 64, 12],
      ['time', 76, 4],
    ],
    'vec3 padding is what makes the reflection panel worth showing',
  );

  assert.deepEqual(
    info.entryPoints.map((e) => [e.name, e.stage]),
    [
      ['vs_main', 'vertex'],
      ['fs_main', 'fragment'],
    ],
  );
  assert.deepEqual(
    info.entryPoints.find((e) => e.name === 'fs_main').resources.sort(),
    ['camera', 'noise_smp', 'noise_tex'],
  );
  assert.deepEqual(
    info.overrides.map((o) => o.name),
    ['particle_scale'],
  );
});
