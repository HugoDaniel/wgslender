// Smoke tests for the wgslender VS Code extension. Exercises the
// LSP wiring (diagnostics arrive on a known-broken shader) plus the
// two highest-value palette commands (reflect, minifyPreview).

import * as assert from 'assert';

import { commands, languages, Uri, window, workspace } from 'vscode';

const BROKEN_SHADER = `@vertex fn main() -> @builtin(position) vec4f {
  let badness =;
  return vec4f(0.0);
}
`;

const VALID_SHADER = `@group(0) @binding(0) var<uniform> u: vec4f;
@compute @workgroup_size(1) fn main() {}
`;

async function openInMemoryWgsl(content: string): Promise<Uri> {
  const doc = await workspace.openTextDocument({ language: 'wgsl', content });
  await window.showTextDocument(doc);
  return doc.uri;
}

async function waitFor<T>(predicate: () => T | undefined, timeoutMs: number): Promise<T> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const value = predicate();
    if (value !== undefined) return value;
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`waitFor timed out after ${timeoutMs} ms`);
}

suite('wgslender VS Code extension', () => {
  suiteSetup(async () => {
    // Activation kicks in on the first .wgsl document.
    await openInMemoryWgsl(VALID_SHADER);
  });

  test('LSP delivers diagnostics for a syntax error', async () => {
    const uri = await openInMemoryWgsl(BROKEN_SHADER);
    const diagnostics = await waitFor(() => {
      const list = languages.getDiagnostics(uri);
      return list.length > 0 ? list : undefined;
    }, 10_000);
    assert.ok(diagnostics.length >= 1, 'at least one diagnostic should be reported');
  });

  test('wgslender.reflect opens a JSON document with entryPoints', async () => {
    await openInMemoryWgsl(VALID_SHADER);
    const before = workspace.textDocuments.filter((d) => d.languageId === 'json').length;
    await commands.executeCommand('wgslender.reflect');
    const jsonDoc = await waitFor(() => {
      const json = workspace.textDocuments.find(
        (d) => d.languageId === 'json' && d.getText().includes('"entryPoints"'),
      );
      return json;
    }, 10_000);
    assert.ok(jsonDoc, 'expected a json document with an entryPoints key');
    assert.ok(workspace.textDocuments.filter((d) => d.languageId === 'json').length >= before);
  });

  test('wgslender.minifyPreview opens a wgslender-minified document', async () => {
    await openInMemoryWgsl(VALID_SHADER);
    await commands.executeCommand('wgslender.minifyPreview');
    const doc = await waitFor(() => {
      return workspace.textDocuments.find((d) => d.uri.scheme === 'wgslender-minified');
    }, 10_000);
    assert.ok(doc, 'expected a wgslender-minified document to exist');
    assert.ok(doc.getText().length < VALID_SHADER.length, 'minified text should be shorter than source');
  });
});
