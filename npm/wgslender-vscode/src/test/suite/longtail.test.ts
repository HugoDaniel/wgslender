// Long-tail, abuse, and devx-flow coverage for the wgslender extension.
//
// Groups:
//   * input long tail — empty / unicode / CRLF / lone-surrogate / huge /
//     single-line shaders and rapid incremental edits, all through the
//     real LanguageClient;
//   * command guards — every palette command against the wrong editor,
//     broken sources, and live preview refresh;
//   * settings flows — rules overrides, diagnostics toggle, minify-mode
//     inlay hints, format.enable, validate.strict, lint.fixOnSave;
//   * feature providers — formatting, semantic tokens, symbols, folding,
//     selection ranges, completion, signature help, code actions, rename,
//     call hierarchy;
//   * exposed API — reflection sidebar provider, status bar, resolved
//     command option bags.

import * as assert from 'assert';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';

import {
  CallHierarchyIncomingCall,
  CallHierarchyItem,
  CodeAction,
  CompletionList,
  ConfigurationTarget,
  Diagnostic,
  DiagnosticSeverity,
  DocumentSymbol,
  FoldingRange,
  Hover,
  InlayHint,
  Location,
  Position,
  Range,
  SelectionRange,
  SemanticTokens,
  SignatureHelp,
  StatusBarItem,
  TextDocument,
  TextEdit,
  TreeItemCollapsibleState,
  Uri,
  ViewColumn,
  WorkspaceEdit,
  commands,
  extensions,
  languages,
  window,
  workspace,
} from 'vscode';

// Structural mirror of src/api.ts (rootDir keeps us from importing it).
interface WgslenderApiLite {
  reflection: {
    refresh(uri: string | undefined, version: 'v1' | 'v2'): Promise<void>;
    getChildren(element?: unknown): unknown;
  };
  statusBarItem: StatusBarItem;
  resolveMinifyOptions(): Record<string, unknown>;
  resolveCompileOptions(): Record<string, unknown>;
}

const CLEAN_SHADER = `@group(0) @binding(0) var<uniform> u: vec4f;
@compute @workgroup_size(1) fn main() { _ = u; }
`;

const BROKEN_SHADER = `@vertex fn main() -> @builtin(position) vec4f {
  let badness =;
  return vec4f(0.0);
}
`;

const UNUSED_SHADER = `@compute @workgroup_size(1) fn main() { let unused = 1.0; }
`;

const FIXABLE_SHADER = `@compute @workgroup_size(1) fn main() { let a = f32(1.5f); _ = a; }
`;

async function openWgsl(content: string): Promise<TextDocument> {
  const doc = await workspace.openTextDocument({ language: 'wgsl', content });
  await window.showTextDocument(doc);
  return doc;
}

async function waitFor<T>(
  predicate: () => T | undefined | Promise<T | undefined>,
  timeoutMs: number,
  what = 'condition',
): Promise<T> {
  const start = Date.now();
  for (;;) {
    const value = await predicate();
    if (value !== undefined) return value;
    if (Date.now() - start >= timeoutMs) {
      throw new Error(`timed out after ${timeoutMs} ms waiting for ${what}`);
    }
    await new Promise((r) => setTimeout(r, 100));
  }
}

async function waitForDiagnostics(uri: Uri, timeoutMs = 10_000): Promise<Diagnostic[]> {
  return waitFor(
    () => {
      const list = languages.getDiagnostics(uri);
      return list.length > 0 ? list : undefined;
    },
    timeoutMs,
    `diagnostics on ${uri.toString()}`,
  );
}

async function waitForNoDiagnostics(uri: Uri, timeoutMs = 10_000): Promise<void> {
  await waitFor(
    () => (languages.getDiagnostics(uri).length === 0 ? true : undefined),
    timeoutMs,
    `empty diagnostics on ${uri.toString()}`,
  );
}

/** Diagnostic.code may be a string or a `{value, target}` pair (the client
 * builds the pair whenever the server attaches a codeDescription URL). */
function codeOf(diagnostic: Diagnostic): string {
  const code = diagnostic.code;
  if (code && typeof code === 'object') return String(code.value);
  return String(code);
}

function getApi(): WgslenderApiLite {
  const ext = extensions.getExtension('hugodaniel.wgslender-vscode');
  assert.ok(ext, 'extension not found');
  assert.ok(ext.isActive, 'extension not active');
  return ext.exports as WgslenderApiLite;
}

function cfg() {
  return workspace.getConfiguration('wgslender');
}

async function resetConfig(...keys: string[]): Promise<void> {
  for (const key of keys) {
    await cfg().update(key, undefined, ConfigurationTarget.Global);
  }
}

suite('input long tail', () => {
  suiteSetup(async () => {
    await openWgsl(CLEAN_SHADER);
  });

  test('empty document produces no diagnostics and clean hovers', async () => {
    const doc = await openWgsl('');
    // A hover round-trip proves the server processed didOpen.
    const hovers = await commands.executeCommand<Hover[]>(
      'vscode.executeHoverProvider',
      doc.uri,
      new Position(0, 0),
    );
    assert.ok(!hovers || hovers.length === 0);
    assert.strictEqual(languages.getDiagnostics(doc.uri).length, 0);
  });

  test('comments-only document with nested block comments is clean', async () => {
    const doc = await openWgsl('/* outer /* nested */ still-outer */\n// line\n');
    const hovers = await commands.executeCommand<Hover[]>(
      'vscode.executeHoverProvider',
      doc.uri,
      new Position(0, 3),
    );
    assert.ok(!hovers || hovers.length === 0);
    assert.strictEqual(languages.getDiagnostics(doc.uri).length, 0);
  });

  test('diagnostic positions are UTF-16 correct past astral characters', async () => {
    const doc = await openWgsl('const α = 🚀;\n');
    const diagnostics = await waitForDiagnostics(doc.uri);
    // '🚀' starts at UTF-16 unit 10 ('const ' 6 + 'α' 1 + ' = ' 3). A
    // byte-based mapping would land at 11.
    assert.ok(
      diagnostics.some((d) => d.range.start.line === 0 && d.range.start.character === 10),
      `no diagnostic at {0,10}: ${diagnostics.map((d) => `{${d.range.start.line},${d.range.start.character}}`).join(' ')}`,
    );
  });

  test('CRLF line endings keep diagnostics on the right line', async () => {
    const doc = await openWgsl('@compute @workgroup_size(1) fn main() {\r\n  let bad =;\r\n}\r\n');
    const diagnostics = await waitForDiagnostics(doc.uri);
    assert.ok(
      diagnostics.some((d) => d.range.start.line === 1),
      `expected a diagnostic on line 1: ${diagnostics.map((d) => d.range.start.line).join(',')}`,
    );
  });

  test('a lone surrogate does not break document sync', async () => {
    const doc = await openWgsl(BROKEN_SHADER);
    await waitForDiagnostics(doc.uri);

    // Insert an unpaired high surrogate — JSON.stringify escapes it as
    // \uD800, which a strict JSON parser rejects. If the server drops
    // that didChange it goes permanently stale.
    const editor = await window.showTextDocument(doc);
    const inserted = await editor.edit((eb) => eb.insert(new Position(0, 0), '// \uD800\n'));
    assert.ok(inserted);

    // Now fix the shader; the server must track the edit and drain the
    // error diagnostics.
    const replaced = await editor.edit((eb) =>
      eb.replace(new Range(new Position(0, 0), new Position(doc.lineCount, 0)), CLEAN_SHADER),
    );
    assert.ok(replaced);
    await waitForNoDiagnostics(doc.uri);
  });

  test('large many-function shader stays responsive', async function () {
    this.timeout(30_000);
    let src = '';
    for (let i = 0; i < 300; i++) {
      src += `fn f${i}(x: f32) -> f32 { return x * ${i}.5; }\n`;
    }
    src += '@compute @workgroup_size(1) fn main() { _ = f299(f0(1.0)); }\n';
    const doc = await openWgsl(src);

    const locations = await waitFor(
      async () => {
        const found = await commands.executeCommand<Location[]>(
          'vscode.executeDefinitionProvider',
          doc.uri,
          new Position(300, src.split('\n')[300].indexOf('f299')),
        );
        return found && found.length > 0 ? found : undefined;
      },
      15_000,
      'definition in large shader',
    );
    assert.strictEqual(locations[0].range.start.line, 299);
  });

  test('one very long line stays responsive', async () => {
    const stmts = Array.from({ length: 900 }, (_, i) => `let x${i} = ${i}.0; _ = x${i};`).join(' ');
    const src = `@compute @workgroup_size(1) fn main() { ${stmts} }\n`;
    const doc = await openWgsl(src);
    const hover = await waitFor(
      async () => {
        const hovers = await commands.executeCommand<Hover[]>(
          'vscode.executeHoverProvider',
          doc.uri,
          new Position(0, src.lastIndexOf('x899')),
        );
        return hovers && hovers.length > 0 ? hovers : undefined;
      },
      15_000,
      'hover at end of long line',
    );
    assert.ok(hover.length > 0);
  });

  test('rapid incremental edits converge to the final state', async function () {
    this.timeout(30_000);
    const doc = await openWgsl(CLEAN_SHADER);
    const editor = await window.showTextDocument(doc);

    // Hammer the incremental path: grow and shrink a comment char by char.
    for (let i = 0; i < 25; i++) {
      const ok = await editor.edit((eb) => eb.insert(new Position(0, 0), '/'.repeat(1 + (i % 3))));
      assert.ok(ok, `edit ${i} failed`);
    }
    // Break it, then restore the clean text wholesale.
    await editor.edit((eb) => eb.insert(new Position(1, 0), 'garbage tokens here\n'));
    await waitForDiagnostics(doc.uri, 15_000);
    await editor.edit((eb) =>
      eb.replace(new Range(new Position(0, 0), new Position(doc.lineCount, 0)), CLEAN_SHADER),
    );
    await waitForNoDiagnostics(doc.uri, 15_000);
  });

  test('phony assignment keeps resources live and clean', async () => {
    const doc = await openWgsl(CLEAN_SHADER);
    // A hover round-trip, then assert zero diagnostics: `_ = u;` must
    // neither warn (W0003 unused binding) nor error.
    await commands.executeCommand<Hover[]>(
      'vscode.executeHoverProvider',
      doc.uri,
      new Position(1, 0),
    );
    assert.strictEqual(languages.getDiagnostics(doc.uri).length, 0);
  });
});

suite('command guards', () => {
  const GATED_COMMANDS = [
    'wgslender.minifyPreview',
    'wgslender.minifySaveAs',
    'wgslender.compile',
    'wgslender.reflect',
    'wgslender.recomputeMinifyInsights',
  ];

  test('gated commands are inert on a non-wgsl editor', async function () {
    this.timeout(30_000);
    const doc = await workspace.openTextDocument({ language: 'plaintext', content: 'not a shader' });
    await window.showTextDocument(doc);

    const previewsBefore = workspace.textDocuments.filter((d) => d.uri.scheme === 'wgslender-minified').length;
    const jsonBefore = workspace.textDocuments.filter((d) => d.languageId === 'json').length;
    for (const command of GATED_COMMANDS) {
      await commands.executeCommand(command);
    }
    assert.strictEqual(
      workspace.textDocuments.filter((d) => d.uri.scheme === 'wgslender-minified').length,
      previewsBefore,
    );
    assert.strictEqual(workspace.textDocuments.filter((d) => d.languageId === 'json').length, jsonBefore);
  });

  test('minifyPreview on a broken shader shows the error banner', async () => {
    await openWgsl(BROKEN_SHADER);
    await commands.executeCommand('wgslender.minifyPreview');
    const preview = await waitFor(
      () =>
        workspace.textDocuments.find(
          (d) => d.uri.scheme === 'wgslender-minified' && d.getText().startsWith('//'),
        ),
      10_000,
      'error-banner preview',
    );
    assert.ok(preview.getText().startsWith('// '), preview.getText().slice(0, 80));
  });

  test('minify preview refreshes when the source changes', async function () {
    this.timeout(30_000);
    const doc = await openWgsl(CLEAN_SHADER);
    await commands.executeCommand('wgslender.minifyPreview');
    await waitFor(
      () =>
        workspace.textDocuments.find(
          (d) => d.uri.scheme === 'wgslender-minified' && d.getText().includes('workgroup_size(1)'),
        ),
      10_000,
      'initial preview content',
    );

    // Re-show the source pinned in column one — the preview opened
    // `preview: true` beside and holds focus, and opening the source into
    // that column would replace (and close) the preview tab.
    const editor = await window.showTextDocument(doc, { viewColumn: ViewColumn.One });
    const ok = await editor.edit((eb) =>
      eb.replace(
        new Range(new Position(0, 0), new Position(doc.lineCount, 0)),
        CLEAN_SHADER.replace('@workgroup_size(1)', '@workgroup_size(2)'),
      ),
    );
    assert.ok(ok);
    // Re-find the preview each poll rather than holding one reference —
    // a closed document reference would freeze at its last content.
    await waitFor(
      () =>
        workspace.textDocuments.some(
          (d) => d.uri.scheme === 'wgslender-minified' && d.getText().includes('workgroup_size(2)'),
        )
          ? true
          : undefined,
      10_000,
      'preview refresh',
    );
  });

  test('minifySaveAs and compile resolve without hanging on a broken shader', async () => {
    await openWgsl(BROKEN_SHADER);
    await commands.executeCommand('wgslender.minifySaveAs');
    await commands.executeCommand('wgslender.compile');
  });

  test('reflect resolves on a broken shader', async () => {
    await openWgsl(BROKEN_SHADER);
    await commands.executeCommand('wgslender.reflect');
  });

  test('toggleMinifyMode cycles the setting off → insights → strict → off', async () => {
    try {
      assert.strictEqual(cfg().get('lsp.minifyMode', 'off'), 'off');
      await commands.executeCommand('wgslender.toggleMinifyMode');
      assert.strictEqual(cfg().get('lsp.minifyMode'), 'insights');
      await commands.executeCommand('wgslender.toggleMinifyMode');
      assert.strictEqual(cfg().get('lsp.minifyMode'), 'strict');
      await commands.executeCommand('wgslender.toggleMinifyMode');
      assert.strictEqual(cfg().get('lsp.minifyMode'), 'off');
    } finally {
      await resetConfig('lsp.minifyMode');
    }
  });
});

suite('settings flows', () => {
  suiteTeardown(async () => {
    await resetConfig(
      'rules',
      'lsp.diagnostics.enabled',
      'lsp.minifyMode',
      'format.enable',
      'validate.strict',
      'lint.fixOnSave',
    );
  });

  test('rule overrides apply live without reopening the document', async function () {
    this.timeout(30_000);
    try {
      const doc = await openWgsl(UNUSED_SHADER);
      const diagnostics = await waitForDiagnostics(doc.uri);
      assert.ok(
        diagnostics.some((d) => codeOf(d) === 'W0001'),
        `expected W0001, got: ${diagnostics.map((d) => codeOf(d)).join(',')}`,
      );

      await cfg().update('rules', { 'no-unused-vars': 'off' }, ConfigurationTarget.Global);
      // The disappearance rides workspace/diagnostic/refresh → client
      // re-pull, and the client's pull scheduler can back off under the
      // test host's load — give it more room than the appearance waits.
      await waitFor(
        () =>
          languages.getDiagnostics(doc.uri).some((d) => codeOf(d) === 'W0001')
            ? undefined
            : true,
        20_000,
        'W0001 to disappear after rules override',
      );
    } finally {
      await resetConfig('rules');
    }
  });

  test('disabling diagnostics clears them; re-enabling restores them', async function () {
    this.timeout(30_000);
    try {
      const doc = await openWgsl(BROKEN_SHADER);
      await waitForDiagnostics(doc.uri);

      await cfg().update('lsp.diagnostics.enabled', false, ConfigurationTarget.Global);
      await waitForNoDiagnostics(doc.uri);

      await cfg().update('lsp.diagnostics.enabled', true, ConfigurationTarget.Global);
      await waitForDiagnostics(doc.uri);
    } finally {
      await resetConfig('lsp.diagnostics.enabled');
    }
  });

  test('minify insights mode gates size inlay hints', async function () {
    this.timeout(30_000);
    // Type-echo hints (`f32` on let/return types) exist in every mode;
    // only the byte-size labels are gated by the minify mode.
    const isSizeHint = (h: InlayHint) =>
      /\d+\s?(B|KB)\b/.test(typeof h.label === 'string' ? h.label : h.label.map((p) => p.value).join(''));
    try {
      const doc = await openWgsl('@compute @workgroup_size(1) fn main() { let a = 1.0; _ = a; }\n');
      const fullRange = new Range(new Position(0, 0), new Position(doc.lineCount, 0));

      const before = await commands.executeCommand<InlayHint[]>(
        'vscode.executeInlayHintProvider',
        doc.uri,
        fullRange,
      );
      assert.strictEqual((before ?? []).filter(isSizeHint).length, 0, 'no size hints while mode is off');

      await cfg().update('lsp.minifyMode', 'insights', ConfigurationTarget.Global);
      await waitFor(
        async () => {
          const hints = await commands.executeCommand<InlayHint[]>(
            'vscode.executeInlayHintProvider',
            doc.uri,
            fullRange,
          );
          return hints && hints.filter(isSizeHint).length > 0 ? hints : undefined;
        },
        10_000,
        'size inlay hints in insights mode',
      );
    } finally {
      await resetConfig('lsp.minifyMode');
    }
  });

  test('type-annotation inlay hints are opt-in', async function () {
    this.timeout(30_000);
    try {
      const doc = await openWgsl('@compute @workgroup_size(1) fn main() { let a = 1.0; _ = a; }\n');
      const fullRange = new Range(new Position(0, 0), new Position(doc.lineCount, 0));

      const before = await commands.executeCommand<InlayHint[]>(
        'vscode.executeInlayHintProvider',
        doc.uri,
        fullRange,
      );
      assert.strictEqual((before ?? []).length, 0, 'no inlay hints by default');

      await cfg().update('lsp.inlayHints.typeAnnotations', true, ConfigurationTarget.Global);
      await waitFor(
        async () => {
          const hints = await commands.executeCommand<InlayHint[]>(
            'vscode.executeInlayHintProvider',
            doc.uri,
            fullRange,
          );
          return hints && hints.length > 0 ? hints : undefined;
        },
        10_000,
        'type hints after enabling typeAnnotations',
      );
    } finally {
      await resetConfig('lsp.inlayHints.typeAnnotations');
    }
  });

  test('format.enable=false disables document formatting', async function () {
    this.timeout(30_000);
    try {
      const doc = await openWgsl('@compute @workgroup_size(1)\nfn main(){let a=1.0;_=a;}\n');

      const enabled = await waitFor(
        async () => {
          const edits = await commands.executeCommand<TextEdit[]>(
            'vscode.executeFormatDocumentProvider',
            doc.uri,
            { tabSize: 2, insertSpaces: true },
          );
          return edits && edits.length > 0 ? edits : undefined;
        },
        10_000,
        'formatting edits while enabled',
      );
      assert.ok(enabled.length > 0);

      await cfg().update('format.enable', false, ConfigurationTarget.Global);
      const disabled = await commands.executeCommand<TextEdit[]>(
        'vscode.executeFormatDocumentProvider',
        doc.uri,
        { tabSize: 2, insertSpaces: true },
      );
      assert.ok(!disabled || disabled.length === 0, 'formatting should be disabled');
    } finally {
      await resetConfig('format.enable');
    }
  });

  test('validate.strict escalates warnings to errors', async function () {
    this.timeout(30_000);
    try {
      const doc = await openWgsl(UNUSED_SHADER);
      const relaxed = await waitForDiagnostics(doc.uri);
      const warning = relaxed.find((d) => codeOf(d) === 'W0001');
      assert.ok(warning && warning.severity === DiagnosticSeverity.Warning);

      await cfg().update('validate.strict', true, ConfigurationTarget.Global);
      await waitFor(
        () => {
          const now = languages.getDiagnostics(doc.uri).find((d) => codeOf(d) === 'W0001');
          return now && now.severity === DiagnosticSeverity.Error ? true : undefined;
        },
        10_000,
        'W0001 escalated to error under validate.strict',
      );
    } finally {
      await resetConfig('validate.strict');
    }
  });

  test('lint.fixOnSave applies autofixes when saving', async function () {
    this.timeout(30_000);
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wgslender-fixsave-'));
    const file = path.join(dir, 'fix.wgsl');
    fs.writeFileSync(file, FIXABLE_SHADER);
    try {
      const doc = await workspace.openTextDocument(Uri.file(file));
      const editor = await window.showTextDocument(doc);
      await cfg().update('lint.fixOnSave', true, ConfigurationTarget.Global);

      // Dirty the buffer without touching the fixable statement.
      const ok = await editor.edit((eb) => eb.insert(new Position(doc.lineCount, 0), '// dirty\n'));
      assert.ok(ok);
      const saved = await doc.save();
      assert.ok(saved, 'save failed');
      assert.ok(
        doc.getText().includes('let a = 1.5f;'),
        `autofix not applied on save: ${doc.getText().split('\n')[0]}`,
      );
    } finally {
      await resetConfig('lint.fixOnSave');
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
});

suite('feature providers', () => {
  const NAV_SHADER = `struct Particle { pos: vec4f, vel: vec4f }
@group(0) @binding(0) var<storage, read_write> particles: array<Particle>;
fn integrate(p: Particle) -> Particle { return p; }
@compute @workgroup_size(64) fn main() {
  let p = particles[0];
  particles[0] = integrate(p);
}
`;

  function pos(doc: TextDocument, needle: string): Position {
    const index = doc.getText().indexOf(needle);
    assert.ok(index >= 0, `needle not found: ${needle}`);
    return doc.positionAt(index);
  }

  test('formatting preserves unreachable declarations and literal spelling', async () => {
    const doc = await openWgsl(
      'fn helper_unused(x: f32) -> f32 { return x * 2.0; }\n@compute @workgroup_size(1) fn main() { let a = 1.0; _ = a; }\n',
    );
    const edits = await waitFor(
      async () => {
        const e = await commands.executeCommand<TextEdit[]>(
          'vscode.executeFormatDocumentProvider',
          doc.uri,
          { tabSize: 4, insertSpaces: true },
        );
        return e && e.length > 0 ? e : undefined;
      },
      10_000,
      'formatting edits',
    );
    // VS Code minimizes provider edits into a diff, so newText fragments
    // alone prove nothing — apply them and inspect the resulting text.
    const we = new WorkspaceEdit();
    we.set(doc.uri, edits);
    assert.ok(await workspace.applyEdit(we), 'applyEdit failed');
    const formatted = doc.getText();
    assert.ok(formatted.includes('helper_unused'), `formatting must not tree-shake: ${JSON.stringify(formatted)}`);
    assert.ok(formatted.includes('1.0'), `formatting must not respell literals: ${JSON.stringify(formatted)}`);
  });

  test('semantic tokens cover the document', async () => {
    const doc = await openWgsl(NAV_SHADER);
    const tokens = await waitFor(
      async () => {
        const t = await commands.executeCommand<SemanticTokens>(
          'vscode.provideDocumentSemanticTokens',
          doc.uri,
        );
        return t && t.data.length > 0 ? t : undefined;
      },
      10_000,
      'semantic tokens',
    );
    assert.ok(tokens.data.length >= 5 * 5, 'expected a non-trivial token stream');
  });

  test('document symbols, folding ranges, and selection ranges answer', async () => {
    const doc = await openWgsl(NAV_SHADER);
    const symbols = await waitFor(
      async () => {
        const s = await commands.executeCommand<DocumentSymbol[]>(
          'vscode.executeDocumentSymbolProvider',
          doc.uri,
        );
        return s && s.length > 0 ? s : undefined;
      },
      10_000,
      'document symbols',
    );
    const names = symbols.map((s) => s.name);
    assert.ok(names.includes('Particle') && names.includes('integrate'), names.join(','));

    const folds = await commands.executeCommand<FoldingRange[]>(
      'vscode.executeFoldingRangeProvider',
      doc.uri,
    );
    assert.ok(folds && folds.length >= 1, 'expected folding ranges');

    const selections = await commands.executeCommand<SelectionRange[]>(
      'vscode.executeSelectionRangeProvider',
      doc.uri,
      [pos(doc, 'particles[0] =')],
    );
    assert.ok(selections && selections.length === 1);
    assert.ok(selections[0].parent, 'selection range should nest');
  });

  test('completion works in mid-typing (unparseable) code', async () => {
    const doc = await openWgsl('@compute @workgroup_size(1) fn main() { let v = ve }\n');
    const list = await waitFor(
      async () => {
        const l = await commands.executeCommand<CompletionList>(
          'vscode.executeCompletionItemProvider',
          doc.uri,
          pos(doc, 've }').translate(0, 2),
        );
        return l && l.items.length > 0 ? l : undefined;
      },
      10_000,
      'completion items',
    );
    assert.ok(list.items.length > 0);
  });

  test('signature help answers inside a builtin call', async () => {
    const doc = await openWgsl('@compute @workgroup_size(1) fn main() { let a = sin(1.0); _ = a; }\n');
    const help = await waitFor(
      async () => {
        const h = await commands.executeCommand<SignatureHelp>(
          'vscode.executeSignatureHelpProvider',
          doc.uri,
          pos(doc, '1.0);'),
        );
        return h && h.signatures.length > 0 ? h : undefined;
      },
      10_000,
      'signature help',
    );
    assert.match(help.signatures[0].label, /sin/);
  });

  test('code actions offer quickfixes for unused symbols and typos', async () => {
    const doc = await openWgsl(UNUSED_SHADER);
    const diagnostics = await waitForDiagnostics(doc.uri);
    const w1 = diagnostics.find((d) => codeOf(d) === 'W0001');
    assert.ok(w1, 'expected W0001');
    const actions = await waitFor(
      async () => {
        const a = await commands.executeCommand<CodeAction[]>(
          'vscode.executeCodeActionProvider',
          doc.uri,
          w1.range,
        );
        return a && a.length > 0 ? a : undefined;
      },
      10_000,
      'quickfix actions',
    );
    assert.ok(
      actions.some((a) => /Remove unused|Rename to/.test(a.title)),
      actions.map((a) => a.title).join(','),
    );
  });

  test('fixable lint rules offer the same autofix lint --fix applies', async () => {
    const doc = await openWgsl(FIXABLE_SHADER);
    const diagnostics = await waitForDiagnostics(doc.uri);
    const w201 = diagnostics.find((d) => codeOf(d) === 'W0201');
    assert.ok(w201, `expected W0201, got: ${diagnostics.map((d) => codeOf(d)).join(',')}`);
    const actions = await waitFor(
      async () => {
        const a = await commands.executeCommand<CodeAction[]>(
          'vscode.executeCodeActionProvider',
          doc.uri,
          w201.range,
        );
        return a && a.some((x) => /autofix/i.test(x.title)) ? a : undefined;
      },
      10_000,
      'lint autofix action',
    );
    const fix = actions.find((a) => /autofix/i.test(a.title))!;
    assert.ok(fix.edit, 'autofix action should carry a workspace edit');
    assert.ok(await workspace.applyEdit(fix.edit), 'applyEdit failed');
    assert.ok(
      doc.getText().includes('let a = 1.5f;'),
      `autofix should remove the redundant cast: ${doc.getText().split('\n')[0]}`,
    );
  });

  test('rename returns a multi-site edit; renaming a builtin cannot kill the server', async () => {
    const doc = await openWgsl(NAV_SHADER);
    const edit = await waitFor(
      async () => {
        const e = await commands.executeCommand<WorkspaceEdit>(
          'vscode.executeDocumentRenameProvider',
          doc.uri,
          pos(doc, 'integrate(p)'),
          'step',
        );
        return e && e.size > 0 ? e : undefined;
      },
      10_000,
      'rename edit',
    );
    const edits = edit.get(doc.uri);
    assert.ok(edits.length >= 2, `expected declaration + call site, got ${edits.length}`);

    // Abuse: renaming a builtin must fail gracefully, not wedge the client.
    const doc2 = await openWgsl('@compute @workgroup_size(1) fn main() { let a = sin(1.0); _ = a; }\n');
    try {
      await commands.executeCommand<WorkspaceEdit>(
        'vscode.executeDocumentRenameProvider',
        doc2.uri,
        pos(doc2, 'sin('),
        'cos',
      );
    } catch {
      // A rejection is an acceptable answer; a hang or crash is not.
    }
    const hovers = await commands.executeCommand<Hover[]>(
      'vscode.executeHoverProvider',
      doc2.uri,
      pos(doc2, 'sin('),
    );
    assert.ok(hovers && hovers.length > 0, 'server should still answer after builtin rename');
  });

  test('call hierarchy resolves incoming calls', async () => {
    const doc = await openWgsl(NAV_SHADER);
    const items = await waitFor(
      async () => {
        const i = await commands.executeCommand<CallHierarchyItem[]>(
          'vscode.prepareCallHierarchy',
          doc.uri,
          pos(doc, 'integrate(p: Particle)'),
        );
        return i && i.length > 0 ? i : undefined;
      },
      10_000,
      'call hierarchy item',
    );
    const incoming = await commands.executeCommand<CallHierarchyIncomingCall[]>(
      'vscode.provideIncomingCalls',
      items[0],
    );
    assert.ok(incoming && incoming.length >= 1, 'main should call integrate');
    assert.strictEqual(incoming[0].from.name, 'main');
  });
});

suite('exposed API surfaces', () => {
  interface TreeNodeLite {
    label?: string | { label: string };
    collapsibleState?: TreeItemCollapsibleState;
  }

  function labelOf(node: TreeNodeLite): string {
    return typeof node.label === 'string' ? node.label : node.label?.label ?? '';
  }

  test('reflection sidebar renders entry points, not an error group', async function () {
    this.timeout(30_000);
    const api = getApi();
    const doc = await openWgsl(CLEAN_SHADER);
    await api.reflection.refresh(doc.uri.toString(), 'v2');
    const roots = (await api.reflection.getChildren()) as TreeNodeLite[];
    const labels = roots.map(labelOf);
    assert.ok(
      labels.some((l) => l.startsWith('Entry Points')),
      `expected an Entry Points group, got: ${labels.join(' | ')}`,
    );
    assert.ok(
      !labels.some((l) => l.startsWith('Errors')),
      `unexpected error group: ${labels.join(' | ')}`,
    );
  });

  test('status bar picks up a minify-mode change without an editor switch', async function () {
    this.timeout(30_000);
    const api = getApi();
    try {
      await openWgsl(CLEAN_SHADER);
      api.statusBarItem.text = '';
      await cfg().update('lsp.minifyMode', 'insights', ConfigurationTarget.Global);
      await waitFor(
        () => (api.statusBarItem.text.includes('min:') ? true : undefined),
        10_000,
        'status bar to show the minified size',
      );
    } finally {
      await resetConfig('lsp.minifyMode');
    }
  });

  test('compile options default to compression-friendly settings', () => {
    const api = getApi();
    const compile = api.resolveCompileOptions();
    // The compile subcommand of the CLI always sorts + scope-renames; the
    // command must match unless the user explicitly opted out.
    assert.strictEqual(compile.sortDeclarations, true, 'sortDeclarations should default to true for compile');
    assert.strictEqual(compile.scopeLocalRename, true, 'scopeLocalRename should default to true for compile');
    // The preview/save-as family keeps the conservative defaults.
    const minify = api.resolveMinifyOptions();
    assert.strictEqual(minify.sortDeclarations, false);
    assert.strictEqual(minify.scopeLocalRename, false);
  });
});
