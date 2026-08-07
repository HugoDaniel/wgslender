// `insights.ts` is the one LSP feature the playground implements itself:
// `@codemirror/lsp-client` has no inlay-hint support, so turning the server's
// minify-size hints into CodeMirror decorations is ours.
//
// The hints here are captured from a live server rather than hand-written,
// because the two things most likely to break — the order they arrive in and
// the way they mark themselves as minify hints — are exactly the things a
// hand-written fixture would quietly get right.
//
// `EditorState` and `Decoration` are DOM-free; only `EditorView` needs a
// browser. That is what makes this testable in Node at all.

import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';

import { EditorState } from '@codemirror/state';
import { initialize as initLsp, sendMessage } from 'wgslender-lsp';

import { sampleShader, sampleUri, positionOf } from '../src/scripts/playground/sample-shader.ts';
import {
  isMinifySizeHint,
  hintLabel,
  offsetOfPosition,
  minifyHintDecorations,
} from '../src/scripts/playground/insights.ts';

const require = createRequire(import.meta.url);

let nextId = 0;
const request = (method, params) => {
  const id = ++nextId;
  const messages = sendMessage(JSON.stringify({ jsonrpc: '2.0', id, method, params })).map((m) =>
    JSON.parse(m),
  );
  return messages.find((m) => m.id === id)?.result;
};
const notify = (method, params) =>
  sendMessage(JSON.stringify({ jsonrpc: '2.0', method, params })).map((m) => JSON.parse(m));

/** Every hint the server reports for the sample, in the order it sends them. */
let hints;
/** The sample as a CodeMirror document. */
let doc;

before(async () => {
  await initLsp({
    wasmModule: await WebAssembly.compile(await readFile(require.resolve('wgslender-lsp/wasm'))),
  });
  request('initialize', { processId: null, rootUri: null, capabilities: {} });
  notify('initialized', {});
  notify('textDocument/didOpen', {
    textDocument: { uri: sampleUri, languageId: 'wgsl', version: 1, text: sampleShader },
  });
  request('workspace/executeCommand', {
    command: 'wgslender.setMinifyMode',
    arguments: ['insights'],
  });

  const lines = sampleShader.split('\n');
  hints = request('textDocument/inlayHint', {
    textDocument: { uri: sampleUri },
    range: {
      start: { line: 0, character: 0 },
      end: { line: lines.length - 1, character: lines.at(-1).length },
    },
  });
  doc = EditorState.create({ doc: sampleShader }).doc;
});

test('the captured hints are the mixed bag the server really sends', () => {
  // Guards the rest of the file: if this stops being a mix of type hints and
  // minify hints in unsorted order, the tests below stop testing anything.
  assert.ok(hints.length > 30, `only ${hints.length} hints`);
  assert.ok(hints.some(isMinifySizeHint) && hints.some((h) => !isMinifySizeHint(h)));

  const positions = hints.map((h) => h.position.line);
  assert.notDeepEqual(positions, [...positions].sort((a, b) => a - b), 'hints arrive unsorted');
});

test('minify hints are told apart from type hints', () => {
  const minify = hints.filter(isMinifySizeHint);

  assert.equal(minify.length, 11, 'one module total plus one per live declaration');
  for (const hint of minify) assert.match(hintLabel(hint), /^-\d/);

  // Type hints have no tooltip, and one of them is a *composite* label — an
  // array of parts with a jump-to-definition location. `hintLabel` has to
  // flatten those, and `isMinifySizeHint` must not mistake one for a minify
  // hint just because its label is not a plain string.
  const composite = hints.find((h) => Array.isArray(h.label));
  assert.ok(composite, 'the sample has a struct-typed let, whose hint is composite');
  assert.equal(hintLabel(composite), 'Particle');
  assert.equal(isMinifySizeHint(composite), false);
});

test('LSP positions map to document offsets', () => {
  assert.equal(offsetOfPosition(doc, { line: 0, character: 0 }), 0);

  const wave = positionOf(sampleShader, 'wave(uv : vec2');
  assert.equal(
    doc.sliceString(offsetOfPosition(doc, wave), offsetOfPosition(doc, wave) + 4),
    'wave',
  );

  // Hints are requested on a debounce, so they can land against a document
  // that has already shrunk underneath them. Clamping beats throwing.
  assert.equal(offsetOfPosition(doc, { line: 9999, character: 0 }), doc.length);
  assert.equal(offsetOfPosition(doc, { line: 0, character: 9999 }), doc.line(1).to);
});

test('decorations are built for the minify hints only, in document order', () => {
  const decorations = minifyHintDecorations(doc, hints);

  assert.equal(decorations.size, 11, 'type hints are not decorated');

  const placed = [];
  const cursor = decorations.iter();
  while (cursor.value) {
    placed.push({
      from: cursor.from,
      label: cursor.value.spec.widget.label,
      block: cursor.value.spec.widget.block,
    });
    cursor.next();
  }

  // `Decoration.set` throws on unsorted input, and the server's order is not
  // sorted — so this is the assertion that catches forgetting to sort.
  assert.deepEqual(
    placed.map((p) => p.from),
    [...placed.map((p) => p.from)].sort((a, b) => a - b),
  );

  // The module total goes first, at the very start of the document — and is
  // the only block widget. Inline at offset 0 it would render inside line 1,
  // in front of its first character, reading as a note on the comment there.
  assert.equal(placed[0].from, 0);
  assert.match(placed[0].label, /^-\d+ B$/);
  assert.equal(placed[0].block, true);
  assert.deepEqual(
    placed.slice(1).map((p) => p.block),
    placed.slice(1).map(() => false),
  );

  // And a function's hint sits at its closing brace.
  const lines = sampleShader.split('\n');
  let brace = positionOf(sampleShader, 'fn wave').line;
  while (lines[brace] !== '}') brace++;
  const braceOffset = doc.line(brace + 1).from + 1;
  assert.ok(
    placed.some((p) => p.from === braceOffset),
    `no decoration at wave's closing brace (offset ${braceOffset})`,
  );
});

test('every widget carries the server tooltip verbatim', () => {
  const cursor = minifyHintDecorations(doc, hints).iter();
  while (cursor.value) {
    const { widget } = cursor.value.spec;
    const source = hints.find((h) => hintLabel(h) === widget.label && isMinifySizeHint(h));
    assert.equal(widget.tooltip, source.tooltip, 'the "approximate" disclosure must survive');
    cursor.next();
  }
});

test('two identical hint sets produce equal widgets', () => {
  // `eq` decides whether CodeMirror redraws. Getting it wrong means the hints
  // flicker on every debounce tick even when nothing changed.
  const first = minifyHintDecorations(doc, hints).iter();
  const second = minifyHintDecorations(doc, hints).iter();

  let compared = 0;
  while (first.value) {
    assert.ok(first.value.spec.widget.eq(second.value.spec.widget));
    compared++;
    first.next();
    second.next();
  }
  assert.equal(compared, 11);
});

test('an empty hint list clears the decorations', () => {
  assert.equal(minifyHintDecorations(doc, []).size, 0);
  assert.equal(minifyHintDecorations(doc, hints.filter((h) => !isMinifySizeHint(h))).size, 0);
});
