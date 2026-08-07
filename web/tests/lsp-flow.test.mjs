// A full wgslender-lsp session, driven headlessly over `sendMessage` — no
// CodeMirror, no DOM. This pins the wire behaviour the playground's editor
// island depends on: pushed diagnostics, hover, go-to-definition, and the
// `wgslender.server.showMinifiedOutput` command that feeds the stats bar's gzip
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

/** A `range` covering every line of `text` — what an inlay-hint request wants. */
function wholeDocument(text) {
  const lines = text.split('\n');
  return {
    start: { line: 0, character: 0 },
    end: { line: lines.length - 1, character: lines.at(-1).length },
  };
}

/** Inlay hints for the whole sample. The server returns `null` for none. */
function inlayHints(range = wholeDocument(sampleShader)) {
  const { result } = request('textDocument/inlayHint', {
    textDocument: { uri: sampleUri },
    range,
  });
  return result ?? [];
}

/**
 * Minify-size hints are indistinguishable from type hints by `kind` — the
 * wire maps both to LSP `InlayHintKind.Type` (1), see
 * `lsp/wire/editing.zig::inlayHintKindCode`. Their tooltip is the only
 * marker on the wire, so that is what the playground filters on too.
 */
const isMinifyHint = (hint) => hint.tooltip?.startsWith('approximate minified byte size');

const setMinifyMode = (mode) =>
  request('workspace/executeCommand', {
    command: 'wgslender.server.setMinifyMode',
    arguments: [mode],
  });

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
  // Namespaced under `wgslender.server.` because a client may turn each of
  // these into a command of its own — vscode-languageclient does — and an id
  // the editor extension also registers aborts its activation.
  assert.deepEqual(result.capabilities.executeCommandProvider.commands, [
    'wgslender.server.setMinifyMode',
    'wgslender.server.toggleMinifyMode',
    'wgslender.server.recomputeMinifyInsights',
    'wgslender.server.showMinifiedOutput',
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

/** The `value` of a hover response, whichever shape the server used. */
function hoverAt(needle) {
  const { result } = request('textDocument/hover', {
    textDocument: { uri: sampleUri },
    position: positionOf(sampleShader, needle),
  });
  return typeof result.contents === 'string' ? result.contents : result.contents.value;
}

test('hover over a uniform reports its type', () => {
  assert.match(hoverAt('camera.time'), /Camera/);
});

test('hover fences its WGSL, so type parameters survive the renderer', () => {
  // The server answers with MarkupContent{kind:"markdown"}, and an unfenced
  // `vecN<f32>` is parsed as an HTML tag by every markdown client — the
  // playground rendered sin's constraint as "T is f32, f16, vecN, or vecN",
  // the brackets present in the DOM as elements and invisible on screen.
  const text = hoverAt('sin(uv.x');
  assert.match(text, /^```wgsl\n/);
  assert.match(text, /vecN<f32>/);

  // Everything with a bracket is inside the fence; the prose after it is
  // escaped rather than fenced.
  const [, fence, prose] = text.split('```');
  assert.match(fence, /fn sin/);
  assert.doesNotMatch(prose, /</);
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
    command: 'wgslender.server.showMinifiedOutput',
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

// ---------------------------------------------------------------------------
// Block 4: minify-size inlay hints, rename, formatting.
//
// These pin server behaviour that already exists — the playground's job is to
// surface it, and these assertions are what `insights.ts` is written against.
// ---------------------------------------------------------------------------

/** Line index of the `}` that closes the block opened at `needle`. */
function closingBraceLineAfter(needle) {
  const lines = sampleShader.split('\n');
  let line = positionOf(sampleShader, needle).line;
  while (line < lines.length && lines[line] !== '}') line++;
  return line;
}

test('with minify mode off, no size hints — but type hints still arrive', () => {
  const hints = inlayHints();

  assert.deepEqual(hints.filter(isMinifyHint), [], 'mode `off` gates the whole lane');
  assert.ok(
    hints.some((h) => h.label === 'f32'),
    'ordinary type hints are unaffected by the minify mode',
  );
});

test('setMinifyMode insights brings back one size hint per live declaration', () => {
  assert.equal(setMinifyMode('insights').result, null, 'a void command resolves with null');

  const minifyHints = inlayHints().filter(isMinifyHint);

  // Every label is a byte delta, and every hint discloses that it is an
  // estimate — the tooltip is the disclosure the server promises.
  for (const hint of minifyHints) {
    assert.match(hint.label, /^-\d+(\.\d)? ?[KM]?B$/, `unexpected label ${hint.label}`);
    assert.match(hint.tooltip, /approximate/);
  }

  // The module total sits at the very top of the document.
  const total = minifyHints.filter((h) => h.position.line === 0 && h.position.character === 0);
  assert.equal(total.length, 1, 'exactly one module-total hint');
  const bytesOf = (hint) => Number(hint.label.match(/-(\d+)/)[1]);
  assert.ok(
    minifyHints.every((h) => h === total[0] || bytesOf(h) < bytesOf(total[0])),
    'the module total is the largest saving on the page',
  );

  // Function hints land on the closing brace; declaration hints on the `;`.
  const lines = minifyHints.map((h) => h.position.line);
  for (const fn of ['fn wave', 'fn vs_main', 'fn fs_main']) {
    assert.ok(lines.includes(closingBraceLineAfter(fn)), `no size hint closing ${fn}`);
  }
  assert.ok(
    lines.includes(positionOf(sampleShader, 'override particle_scale').line),
    'the override is measured too',
  );

  // `unused_helper` gets no hint at all. That is not an oversight: the
  // estimator walks live declarations only (`MinifyEstimator` filters through
  // `Dce.isDeclarationLive`), and a tree-shaken function contributes nothing
  // to the minified output. Its silence *is* the insight.
  assert.ok(
    !lines.includes(closingBraceLineAfter('fn unused_helper')),
    'dead code has no size to report',
  );
});

test('minify hints ignore the requested range', () => {
  // Type hints honour the range; the minify lane is emitted whole-document
  // regardless. `insights.ts` leans on this — it asks for one range and gets
  // every hint, so there is no viewport bookkeeping to get wrong.
  const narrow = inlayHints({
    start: { line: 0, character: 0 },
    end: { line: 1, character: 0 },
  });

  assert.equal(narrow.filter(isMinifyHint).length, inlayHints().filter(isMinifyHint).length);
  assert.ok(
    narrow.filter((h) => !isMinifyHint(h)).length < inlayHints().filter((h) => !isMinifyHint(h)).length,
    'type hints, by contrast, are range-filtered',
  );
});

test('strict mode adds minify lints to the published diagnostics', () => {
  const { messages } = setMinifyMode('strict');

  // The command republishes diagnostics for every open document, so the
  // Diagnostics panel updates at the same moment the hints do.
  const codes = codesIn(diagnosticsIn(messages));
  assert.ok(
    codes.some((c) => c.startsWith('M')),
    `expected an M-code minify lint, got ${codes}`,
  );
  assert.ok(codes.includes('W0001'), 'the ordinary lints survive the mode change');
});

test('setMinifyMode off removes the size hints again', () => {
  setMinifyMode('off');
  assert.deepEqual(inlayHints().filter(isMinifyHint), []);

  const codes = codesIn(diagnosticsIn(setMinifyMode('off').messages));
  assert.deepEqual(codes, ['W0001'], 'and takes the M-codes with it');
});

test('rename rewrites the declaration and every call site', () => {
  const declaration = positionOf(sampleShader, 'wave(uv : vec2');
  const { result } = request('textDocument/rename', {
    textDocument: { uri: sampleUri },
    position: declaration,
    newName: 'ripple',
  });

  const edits = result.changes[sampleUri];
  assert.deepEqual(
    edits.map((e) => [e.range.start.line, e.range.start.character, e.newText]),
    [
      [declaration.line, declaration.character, 'ripple'],
      [
        positionOf(sampleShader, 'wave(uv, camera.time)').line,
        positionOf(sampleShader, 'wave(uv, camera.time)').character,
        'ripple',
      ],
    ],
    'declaration first, then the call in fs_main',
  );

  // Renaming from the call site produces the same edit set.
  const fromCall = request('textDocument/rename', {
    textDocument: { uri: sampleUri },
    position: positionOf(sampleShader, 'wave(uv, camera.time)'),
    newName: 'ripple',
  });
  assert.deepEqual(fromCall.result, result);
});

test('rename needs the cursor on the identifier itself', () => {
  // `positionOf(…, 'fn wave')` points at the `f` of `fn`, which is a keyword,
  // not a symbol — the server answers `null` rather than guessing. Worth
  // pinning: it is the difference between F2 working and silently doing
  // nothing, and it is why the page copy says to click the name.
  const { result } = request('textDocument/rename', {
    textDocument: { uri: sampleUri },
    position: positionOf(sampleShader, 'fn wave'),
    newName: 'ripple',
  });

  assert.equal(result, null);
});

test('formatting re-indents — and rewrites far more than whitespace', () => {
  const misindented = sampleShader
    .replace('fn wave(', '        fn wave(')
    .replace('  return sin(', 'return sin(');
  replaceDocument(4, misindented);

  const { result } = request('textDocument/formatting', {
    textDocument: { uri: sampleUri },
    options: { tabSize: 2, insertSpaces: true },
  });

  assert.equal(result.length, 1, 'one edit replacing the whole document');
  const formatted = result[0].newText;
  assert.match(formatted, /^fn wave\(uv: vec2<f32>, t: f32\) -> f32 \{$/m, 'indentation fixed');
  assert.match(formatted, /^ {4}return sin/m);

  // `computeFormatting` runs the *whole minifier* with only whitespace and
  // identifier minification switched off, so "format document" also:
  assert.doesNotMatch(formatted, /\/\//, 'strips every comment');
  assert.doesNotMatch(formatted, /unused_helper/, 'tree-shakes dead code');
  assert.match(formatted, /= 1\.;/, 'and rewrites literals (`1.0` became `1.`)');

  // This is destructive enough that the playground does not offer a format
  // button — see the note in PlaygroundEditor.astro. The assertions above are
  // here to catch the day it changes, in either direction.

  replaceDocument(5, sampleShader);
});
