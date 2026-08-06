// The WGSL syntax mode, driven the way CodeMirror drives it: one
// `StringStream` per line, one parser state carried across the whole
// document. That carry is the point — WGSL block comments *nest*, so the
// state has to hold a depth counter, and a mode that gets this wrong looks
// fine on every single-line test and falls apart on the first `/* /* */ */`.
//
// Assertions are on the token strings the parser returns, not on the tags
// they resolve to, so this suite stays independent of @lezer/highlight's
// tag machinery.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { StringStream } from '@codemirror/language';

import { wgslStreamParser, wgslLanguage } from '../src/scripts/playground/wgsl-language.ts';
import { sampleShader } from '../src/scripts/playground/sample-shader.ts';

/**
 * Tokenize a whole document, mirroring `StreamLanguage.readToken`: reset
 * `start` before each call, tolerate a few zero-length returns, then give up
 * rather than spin. Returns `[text, style]` pairs, whitespace dropped.
 */
function tokenize(source) {
  const state = wgslStreamParser.startState(2);
  const tokens = [];
  for (const line of source.split('\n')) {
    const stream = new StringStream(line, 2, 2);
    while (!stream.eol()) {
      stream.start = stream.pos;
      let style = null;
      for (let i = 0; stream.pos === stream.start; i++) {
        style = wgslStreamParser.token(stream, state);
        if (i >= 10) throw new Error(`stalled at ${JSON.stringify(line.slice(stream.pos, stream.pos + 24))}`);
      }
      if (style) tokens.push([line.slice(stream.start, stream.pos), style]);
    }
  }
  return tokens;
}

/** Style of the first token whose text is exactly `text`. */
const styleOf = (tokens, text) => tokens.find(([t]) => t === text)?.[1];

/** Every token carrying `style`, concatenated — for spans like comments. */
const textOf = (tokens, style) =>
  tokens
    .filter(([, s]) => s === style)
    .map(([t]) => t)
    .join('');

test('the language is named wgsl, so lsp-client derives the right languageID', () => {
  assert.equal(wgslStreamParser.name, 'wgsl');
  assert.equal(wgslLanguage.name, 'wgsl');
});

test('keywords, address-space words and attributes are distinct', () => {
  const tokens = tokenize('@group(0) @binding(1) var<storage, read> particles : array<Particle>;');

  assert.equal(styleOf(tokens, 'var'), 'keyword');
  assert.equal(styleOf(tokens, '@group'), 'attributeName');
  assert.equal(styleOf(tokens, '@binding'), 'attributeName');
  assert.equal(styleOf(tokens, 'array'), 'typeName');
  assert.equal(styleOf(tokens, 'particles'), 'variableName');
  assert.equal(styleOf(tokens, 'Particle'), 'variableName');

  // `storage` and `read` are address-space / access words, not reserved
  // words: WGSL lets them be ordinary identifiers elsewhere, so they get
  // their own class rather than riding along with the real keywords.
  assert.equal(styleOf(tokens, 'storage'), 'modifier');
  assert.equal(styleOf(tokens, 'read'), 'modifier');

  for (const word of ['fn', 'struct', 'override', 'let', 'const', 'return', 'if', 'loop']) {
    assert.equal(styleOf(tokenize(`${word} `), word), 'keyword', word);
  }
  for (const word of ['private', 'workgroup', 'uniform', 'read_write', 'write']) {
    assert.equal(styleOf(tokenize(`var<${word}>`), word), 'modifier', word);
  }
});

test('block comments nest, unlike C', () => {
  const tokens = tokenize('/* outer /* inner */ still outer */ fn after() {}');

  assert.equal(
    textOf(tokens, 'comment'),
    '/* outer /* inner */ still outer */',
    'the first */ closes the inner comment only',
  );
  assert.equal(styleOf(tokens, 'fn'), 'keyword', 'code resumes after the outer */');
});

test('a nested block comment carries its depth across lines', () => {
  const tokens = tokenize(['/* one', '  /* two */', '  still commented', '*/', 'let x = 1;'].join('\n'));

  const codeStarts = tokens.findIndex(([text]) => text === 'let');
  assert.notEqual(codeStarts, -1, 'the comment must end');
  assert.ok(
    tokens.slice(0, codeStarts).every(([, style]) => style === 'comment'),
    'everything before `let` is inside the comment',
  );
  assert.equal(styleOf(tokens, 'let'), 'keyword');
});

test('line comments end at the newline', () => {
  const tokens = tokenize('// fn struct /* not a block\nfn real() {}');

  assert.equal(textOf(tokens, 'comment'), '// fn struct /* not a block');
  assert.equal(styleOf(tokens, 'fn'), 'keyword');
  assert.equal(styleOf(tokens, 'real'), 'variableName.function');
});

test('numeric literals keep their suffixes', () => {
  for (const literal of ['1', '1.0', '.5', '8u', '3i', '1.5f', '2.0h', '1e-3', '6.02e23', '0x1f', '0xffu']) {
    assert.equal(styleOf(tokenize(`let x = ${literal};`), literal), 'number', literal);
  }
});

test('builtin calls, user calls and member accesses are distinguishable', () => {
  const tokens = tokenize('let n = textureSample(noise_tex, noise_smp, uv).r;');
  assert.equal(styleOf(tokens, 'textureSample'), 'variableName.standard');
  assert.equal(styleOf(tokens, 'noise_tex'), 'variableName');
  assert.equal(styleOf(tokens, 'r'), 'propertyName');

  const call = tokenize('let w = wave(uv, camera.time);');
  assert.equal(styleOf(call, 'wave'), 'variableName.function');
  assert.equal(styleOf(call, 'camera'), 'variableName');
  assert.equal(styleOf(call, 'time'), 'propertyName');

  assert.equal(styleOf(tokenize('let b = true;'), 'true'), 'bool');
});

test('predeclared types are typeName', () => {
  for (const type of ['f32', 'i32', 'u32', 'bool', 'vec2', 'vec4f', 'mat4x4', 'atomic', 'ptr', 'sampler', 'texture_2d']) {
    assert.equal(styleOf(tokenize(`var x : ${type};`), type), 'typeName', type);
  }
});

test('the sample shader tokenizes end to end', () => {
  const tokens = tokenize(sampleShader);

  assert.equal(styleOf(tokens, 'struct'), 'keyword');
  assert.equal(styleOf(tokens, 'override'), 'keyword');
  assert.equal(styleOf(tokens, '@vertex'), 'attributeName');
  assert.equal(styleOf(tokens, '@builtin'), 'attributeName');
  assert.equal(styleOf(tokens, 'mat4x4'), 'typeName');
  assert.equal(styleOf(tokens, 'textureSample'), 'variableName.standard');
  assert.equal(styleOf(tokens, 'wave'), 'variableName.function');
  assert.ok(textOf(tokens, 'comment').startsWith('// A small particle shader'));
});
