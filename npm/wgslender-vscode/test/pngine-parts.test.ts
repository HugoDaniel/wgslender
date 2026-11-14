// Unit lane for the desktop extension's pngine virtual documents.
//
// This file is deliberately pure Node: it imports no `vscode` module and
// never touches the @vscode/test-electron lane. Run it with:
//
//   node --test test/pngine-parts.test.ts
//
// The URI shape is pinned here and re-pinned by the Zig codec test
// (`tests/pngine_virtual_test.zig`), so the two implementations cannot drift.

import assert from 'node:assert/strict';
import test from 'node:test';

import {
  PnginePartProvider,
  PNGINE_PART_SCHEME,
  decodePnginePartUri,
  encodePnginePartUri,
} from '../src/pngine-parts.ts';

const HASH = 'f'.repeat(64);

test('URI codec round-trips path, index and hash', () => {
  const programPath = '/ws/pro%2Fgram dir/\u0161.sjon';
  const uri = encodePnginePartUri(programPath, 7, HASH);

  assert.equal(
    uri,
    'wgslender-pngine://part/%2Fws%2Fpro%252Fgram%20dir%2F%C5%A1.sjon/7/' + HASH,
  );
  // A literal `%2F` must survive exactly one round trip, not become '/'.
  assert.ok(uri.includes('%252F'));
  assert.ok(!uri.includes('\u0161'));

  assert.deepEqual(decodePnginePartUri(uri), {
    programPath,
    partIndex: 7,
    contentHash: HASH,
  });
});

test('URI codec escapes every non-unreserved byte exactly once', () => {
  const uri = encodePnginePartUri('/ws/a!b?c#d~e.sjon', 0, HASH);
  const encodedPath = uri.slice(
    `${PNGINE_PART_SCHEME}://part/`.length,
    uri.indexOf('/', `${PNGINE_PART_SCHEME}://part/`.length),
  );
  assert.equal(encodedPath, '%2Fws%2Fa%21b%3Fc%23d~e.sjon');
  assert.equal(decodePnginePartUri(uri).programPath, '/ws/a!b?c#d~e.sjon');
});

test('URI codec rejects malformed or ambiguous spellings', () => {
  const bad = [
    'file:///ws/program.sjon',
    'wgslender-pngine://part/',
    'wgslender-pngine://part/%2Fws%2Fprogram.sjon',
    'wgslender-pngine://part/%2Fws%2Fprogram.sjon/not-a-number/' + HASH,
    'wgslender-pngine://part/%2Fws%2Fprogram.sjon/-1/' + HASH,
    'wgslender-pngine://part/%2Fws%2Fprogram.sjon/2/not-a-hash',
    'wgslender-pngine://part/%2Fws%2Fprogram.sjon/2/' + HASH + '00',
    'wgslender-pngine://part/ws/program.sjon/2/' + HASH,
    'wgslender-pngine://part/%2Fws%2Fprogram.sjon/2/' + HASH + '/extra',
    'wgslender-pngine://part/%ZZ/2/' + HASH,
    'wgslender-pngine://part//2/' + HASH,
    'wgslender-pngine://other/%2Fws%2Fprogram.sjon/2/' + HASH,
  ];
  for (const uri of bad) {
    assert.throws(() => decodePnginePartUri(uri), /invalid pngine part URI/);
  }

  assert.throws(() => encodePnginePartUri('relative/path.sjon', 0, HASH), /invalid pngine part URI/);
  assert.throws(() => encodePnginePartUri('/ws/program.sjon', -1, HASH), /invalid pngine part URI/);
  assert.throws(() => encodePnginePartUri('/ws/program.sjon', 0, 'ABC'), /invalid pngine part URI/);
});

test('provider caches author text per URI', async () => {
  const calls: string[] = [];
  const provider = new PnginePartProvider(async (uri) => {
    calls.push(uri);
    return { text: 'fn inline_value() -> f32 { return 1.0; }', languageId: 'wgsl' };
  });
  const uri = encodePnginePartUri('/ws/program.sjon', 1, HASH);

  assert.equal(await provider.provideTextDocumentContent(uri), 'fn inline_value() -> f32 { return 1.0; }');
  assert.equal(await provider.provideTextDocumentContent(uri), 'fn inline_value() -> f32 { return 1.0; }');
  assert.deepEqual(calls, [uri]);
});

test('invalidation clears only the changed program and emits onDidChange', async () => {
  let version = 1;
  const provider = new PnginePartProvider(async () => ({
    text: `fn inline_value() -> f32 { return ${version}.0; }`,
    languageId: 'wgsl',
  }));
  const uriA = encodePnginePartUri('/ws/a.sjon', 1, HASH);
  const uriB = encodePnginePartUri('/ws/b.sjon', 1, HASH);
  const changed: string[] = [];
  provider.onDidChange((uri) => changed.push(uri));

  await provider.provideTextDocumentContent(uriA);
  await provider.provideTextDocumentContent(uriB);
  version = 2;

  assert.deepEqual(provider.invalidate('/ws/a.sjon'), [uriA]);
  assert.deepEqual(changed, [uriA]);
  assert.equal(await provider.provideTextDocumentContent(uriA), 'fn inline_value() -> f32 { return 2.0; }');
  // B was not named by the changed program, so its cached text survives.
  assert.equal(await provider.provideTextDocumentContent(uriB), 'fn inline_value() -> f32 { return 1.0; }');

  assert.deepEqual(provider.invalidate(), [uriA, uriB]);
  assert.equal(provider.cacheSize, 0);
});

test('a failed fetch is never cached and a later retry refetches', async () => {
  let calls = 0;
  const provider = new PnginePartProvider(async () => {
    calls += 1;
    if (calls === 1) throw new Error('stale part');
    return { text: 'fn inline_value() -> f32 { return 3.0; }', languageId: 'wgsl' };
  });
  const uri = encodePnginePartUri('/ws/program.sjon', 2, HASH);

  await assert.rejects(() => provider.provideTextDocumentContent(uri), /stale part/);
  assert.equal(provider.cacheSize, 0);
  assert.equal(await provider.provideTextDocumentContent(uri), 'fn inline_value() -> f32 { return 3.0; }');
  assert.equal(calls, 2);
});

test('provider rejects a non-WGSL language id and caches nothing', async () => {
  const provider = new PnginePartProvider(async () => ({ text: 'fn x() {}', languageId: 'plaintext' }));
  const uri = encodePnginePartUri('/ws/program.sjon', 0, HASH);

  await assert.rejects(() => provider.provideTextDocumentContent(uri), /language/i);
  assert.equal(provider.cacheSize, 0);
});
