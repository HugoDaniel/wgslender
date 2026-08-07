// Smoke tests for the wgslender VS Code extension. Exercises the
// LSP wiring (diagnostics arrive on a known-broken shader), go-to
// navigation (definition / declaration / type definition / references
// across structs, vars, and functions), plus the two highest-value
// palette commands (reflect, minifyPreview).

import * as assert from 'assert';

import {
  commands,
  languages,
  Hover,
  Location,
  LocationLink,
  MarkdownString,
  Position,
  SymbolInformation,
  SymbolKind,
  Uri,
  window,
  workspace,
} from 'vscode';

const BROKEN_SHADER = `@vertex fn main() -> @builtin(position) vec4f {
  let badness =;
  return vec4f(0.0);
}
`;

const VALID_SHADER = `@group(0) @binding(0) var<uniform> u: vec4f;
@compute @workgroup_size(1) fn main() {}
`;

// One line, so the hover position is an index rather than arithmetic.
const HOVER_SHADER = `@compute @workgroup_size(1) fn main() { let a = sin(1.0); }
`;

async function openInMemoryWgsl(content: string): Promise<Uri> {
  const doc = await workspace.openTextDocument({ language: 'wgsl', content });
  await window.showTextDocument(doc);
  return doc.uri;
}

async function waitFor<T>(
  predicate: () => T | undefined | Promise<T | undefined>,
  timeoutMs: number,
): Promise<T> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const value = await predicate();
    if (value !== undefined) return value;
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`waitFor timed out after ${timeoutMs} ms`);
}

/** The markdown behind the first hover at `position`, once one arrives. */
async function hoverMarkdownAt(uri: Uri, position: Position): Promise<string> {
  return waitFor(async () => {
    const hovers = await commands.executeCommand<Hover[]>(
      'vscode.executeHoverProvider',
      uri,
      position,
    );
    const content = hovers?.[0]?.contents?.[0];
    if (content === undefined) return undefined;
    return typeof content === 'string' ? content : (content as MarkdownString).value;
  }, 10_000);
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

  test('hover fences its WGSL, so VS Code renders the type parameters', async () => {
    // VS Code renders MarkupContent{kind:"markdown"} as markdown, which parses
    // an unfenced `vecN<f32>` as an HTML tag and drops the type parameter. The
    // fence also matches this extension's own language id, so the signature
    // gets highlighted by the grammar in syntaxes/.
    const uri = await openInMemoryWgsl(HOVER_SHADER);
    const value = await hoverMarkdownAt(uri, new Position(0, HOVER_SHADER.indexOf('sin(')));

    assert.match(value, /^```wgsl\n/, 'hover should open with a wgsl fence');
    assert.ok(value.includes('vecN<f32>'), `type parameter was lost: ${value}`);

    // Prose lives outside the fence, so it must be escaped instead.
    const [, fence, prose] = value.split('```');
    assert.match(fence, /fn sin/);
    assert.ok(!prose.includes('<'), `unescaped '<' in hover prose: ${prose}`);
  });

  // One declaration of each kind the user navigates to: a struct, a
  // module-scope var, a function, and a local let.
  const NAV_SHADER = `struct Particle { pos: vec4f, vel: vec4f }
@group(0) @binding(0) var<storage, read_write> particles: array<Particle>;
fn integrate(p: Particle) -> Particle { return p; }
@compute @workgroup_size(64) fn main() {
  let p = particles[0];
  particles[0] = integrate(p);
}
`;

  /** Position of the first occurrence of `needle` in NAV_SHADER. */
  function navPosition(needle: string): Position {
    const index = NAV_SHADER.indexOf(needle);
    assert.ok(index >= 0, `needle not found in NAV_SHADER: ${needle}`);
    const before = NAV_SHADER.slice(0, index);
    const line = before.split('\n').length - 1;
    const character = index - (before.lastIndexOf('\n') + 1);
    return new Position(line, character);
  }

  /** First target range from a definition-family provider, once one arrives. */
  async function navigateFrom(command: string, uri: Uri, position: Position) {
    const results = await waitFor(async () => {
      const locations = await commands.executeCommand<(Location | LocationLink)[]>(
        command,
        uri,
        position,
      );
      return locations && locations.length > 0 ? locations : undefined;
    }, 10_000);
    const first = results[0];
    return 'targetRange' in first
      ? { uri: first.targetUri, range: first.targetRange }
      : { uri: first.uri, range: first.range };
  }

  test('go to definition: module var usage jumps to its declaration', async () => {
    const uri = await openInMemoryWgsl(NAV_SHADER);
    const target = await navigateFrom(
      'vscode.executeDefinitionProvider',
      uri,
      navPosition('particles[0] ='),
    );
    assert.strictEqual(target.uri.toString(), uri.toString());
    const declared = navPosition('particles: array');
    assert.strictEqual(target.range.start.line, declared.line);
    assert.strictEqual(target.range.start.character, declared.character);
  });

  test('go to definition: function call jumps to fn declaration', async () => {
    const uri = await openInMemoryWgsl(NAV_SHADER);
    const target = await navigateFrom(
      'vscode.executeDefinitionProvider',
      uri,
      navPosition('integrate(p)'),
    );
    const declared = navPosition('integrate(p: Particle)');
    assert.strictEqual(target.range.start.line, declared.line);
    assert.strictEqual(target.range.start.character, declared.character);
  });

  test('go to definition: struct type reference jumps to struct declaration', async () => {
    const uri = await openInMemoryWgsl(NAV_SHADER);
    const target = await navigateFrom(
      'vscode.executeDefinitionProvider',
      uri,
      navPosition('Particle>'),
    );
    const declared = navPosition('Particle {');
    assert.strictEqual(target.range.start.line, declared.line);
    assert.strictEqual(target.range.start.character, declared.character);
  });

  test('go to declaration answers like go to definition', async () => {
    const uri = await openInMemoryWgsl(NAV_SHADER);
    const target = await navigateFrom(
      'vscode.executeDeclarationProvider',
      uri,
      navPosition('particles[0] ='),
    );
    const declared = navPosition('particles: array');
    assert.strictEqual(target.range.start.line, declared.line);
    assert.strictEqual(target.range.start.character, declared.character);
  });

  test('go to type definition: value of struct type jumps to the struct', async () => {
    const uri = await openInMemoryWgsl(NAV_SHADER);
    const target = await navigateFrom(
      'vscode.executeTypeDefinitionProvider',
      uri,
      navPosition('p);'),
    );
    const declared = navPosition('Particle {');
    assert.strictEqual(target.range.start.line, declared.line);
    assert.strictEqual(target.range.start.character, declared.character);
  });

  test('find references: function has its declaration and call site', async () => {
    const uri = await openInMemoryWgsl(NAV_SHADER);
    const references = await waitFor(async () => {
      const locations = await commands.executeCommand<Location[]>(
        'vscode.executeReferenceProvider',
        uri,
        navPosition('integrate(p)'),
      );
      return locations && locations.length >= 2 ? locations : undefined;
    }, 10_000);
    const lines = references.map((l) => l.range.start.line).sort((a, b) => a - b);
    assert.deepStrictEqual(lines, [
      navPosition('integrate(p: Particle)').line,
      navPosition('integrate(p)').line,
    ]);
  });

  test('workspace symbol search finds declarations across open documents', async () => {
    const uri = await openInMemoryWgsl(NAV_SHADER);
    const symbols = await waitFor(async () => {
      const found = await commands.executeCommand<SymbolInformation[]>(
        'vscode.executeWorkspaceSymbolProvider',
        'integrate',
      );
      return found && found.length > 0 ? found : undefined;
    }, 10_000);
    const integrate = symbols.find((s) => s.name === 'integrate');
    assert.ok(integrate, `expected an "integrate" symbol, got: ${symbols.map((s) => s.name).join(', ')}`);
    assert.strictEqual(integrate.kind, SymbolKind.Function);
    assert.strictEqual(integrate.location.uri.toString(), uri.toString());
    assert.strictEqual(integrate.location.range.start.line, navPosition('integrate(p: Particle)').line);
  });

  test('workspace symbol search matches fields with their container', async () => {
    await openInMemoryWgsl(NAV_SHADER);
    const symbols = await waitFor(async () => {
      const found = await commands.executeCommand<SymbolInformation[]>(
        'vscode.executeWorkspaceSymbolProvider',
        'vel',
      );
      return found && found.length > 0 ? found : undefined;
    }, 10_000);
    const vel = symbols.find((s) => s.name === 'vel');
    assert.ok(vel, `expected a "vel" symbol, got: ${symbols.map((s) => s.name).join(', ')}`);
    assert.strictEqual(vel.containerName, 'Particle');
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
