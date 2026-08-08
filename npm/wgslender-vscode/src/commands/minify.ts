// wgslender.minifyPreview / wgslender.minifySaveAs — palette commands
// driven directly by the wgslender package (no LSP roundtrip).

import {
  Disposable,
  EventEmitter,
  ExtensionContext,
  TextDocument,
  TextDocumentContentProvider,
  Uri,
  ViewColumn,
  commands,
  window,
  workspace,
} from 'vscode';

import { getWgslenderEngine } from '../wgslender-engine';

const PREVIEW_SCHEME = 'wgslender-minified';

interface PreviewState {
  sourceUri: Uri;
  source: string;
}

class MinifiedPreviewProvider implements TextDocumentContentProvider {
  private readonly _onDidChange = new EventEmitter<Uri>();
  readonly onDidChange = this._onDidChange.event;
  private readonly cache = new Map<string, PreviewState>();

  constructor(private readonly context: ExtensionContext) {}

  setSource(previewUri: Uri, sourceUri: Uri, source: string): void {
    this.cache.set(previewUri.toString(), { sourceUri, source });
    this._onDidChange.fire(previewUri);
  }

  refreshFor(sourceUri: Uri): Uri[] {
    const refreshed: Uri[] = [];
    for (const [key, state] of this.cache) {
      if (state.sourceUri.toString() === sourceUri.toString()) {
        const previewUri = Uri.parse(key);
        this._onDidChange.fire(previewUri);
        refreshed.push(previewUri);
      }
    }
    return refreshed;
  }

  forget(previewUri: Uri): void {
    this.cache.delete(previewUri.toString());
  }

  async provideTextDocumentContent(uri: Uri): Promise<string> {
    const state = this.cache.get(uri.toString());
    if (!state) return `// no preview state for ${uri.toString()}\n`;

    const sourceDoc = workspace.textDocuments.find(
      (d) => d.uri.toString() === state.sourceUri.toString(),
    );
    const source = sourceDoc ? sourceDoc.getText() : state.source;
    state.source = source;

    const engine = await getWgslenderEngine(this.context);
    const result = engine.minify(source, minifyOptionsFromConfig());
    if (result.errors.length > 0) {
      const lines = result.errors.map((e) => `// ${e.message}`).join('\n');
      return `${lines}\n${result.code}`;
    }
    return result.code;
  }

  dispose(): void {
    this._onDidChange.dispose();
    this.cache.clear();
  }
}

export function registerMinifyCommands(context: ExtensionContext): Disposable[] {
  const provider = new MinifiedPreviewProvider(context);

  const disposables: Disposable[] = [
    workspace.registerTextDocumentContentProvider(PREVIEW_SCHEME, provider),
    provider,
    commands.registerCommand('wgslender.minifyPreview', () => runMinifyPreview(provider)),
    commands.registerCommand('wgslender.minifySaveAs', () => runMinifySaveAs(context)),
    workspace.onDidChangeTextDocument((e) => {
      if (e.document.languageId !== 'wgsl') return;
      provider.refreshFor(e.document.uri);
    }),
    workspace.onDidCloseTextDocument((doc) => {
      if (doc.uri.scheme === PREVIEW_SCHEME) provider.forget(doc.uri);
    }),
  ];

  return disposables;
}

async function runMinifyPreview(provider: MinifiedPreviewProvider): Promise<void> {
  const editor = window.activeTextEditor;
  if (!editor || editor.document.languageId !== 'wgsl') {
    window.showInformationMessage('wgslender: open a .wgsl document first.');
    return;
  }

  const sourceUri = editor.document.uri;
  const previewUri = previewUriFor(sourceUri);
  provider.setSource(previewUri, sourceUri, editor.document.getText());

  let doc: TextDocument;
  try {
    doc = await workspace.openTextDocument(previewUri);
  } catch (err) {
    window.showErrorMessage(`wgslender: minify preview failed — ${formatError(err)}`);
    return;
  }
  await window.showTextDocument(doc, { preview: true, viewColumn: ViewColumn.Beside });
}

async function runMinifySaveAs(context: ExtensionContext): Promise<void> {
  const editor = window.activeTextEditor;
  if (!editor || editor.document.languageId !== 'wgsl') {
    window.showInformationMessage('wgslender: open a .wgsl document first.');
    return;
  }

  let result: { code: string; errors: { message: string }[] };
  try {
    const engine = await getWgslenderEngine(context);
    result = engine.minify(editor.document.getText(), minifyOptionsFromConfig());
  } catch (err) {
    window.showErrorMessage(`wgslender: minify failed — ${formatError(err)}`);
    return;
  }

  if (result.errors.length > 0) {
    window.showErrorMessage(`wgslender: ${result.errors[0].message}`);
    return;
  }

  const defaultUri = editor.document.uri.with({
    path: editor.document.uri.path.replace(/\.wgsl$/, '.min.wgsl'),
  });
  const saveUri = await window.showSaveDialog({
    defaultUri,
    filters: { 'WGSL': ['wgsl'] },
  });
  if (!saveUri) return;

  await workspace.fs.writeFile(saveUri, new TextEncoder().encode(result.code));
  window.setStatusBarMessage(`wgslender: wrote ${saveUri.fsPath}`, 3000);
}

function previewUriFor(sourceUri: Uri): Uri {
  return Uri.parse(
    `${PREVIEW_SCHEME}:${sourceUri.path.replace(/\.wgsl$/, '.min.wgsl')}?source=${encodeURIComponent(sourceUri.toString())}`,
  );
}

export function minifyOptionsFromConfig(): Record<string, unknown> {
  const cfg = workspace.getConfiguration('wgslender');
  return {
    minifyWhitespace: cfg.get<boolean>('minifyWhitespace', true),
    minifyIdentifiers: cfg.get<boolean>('minifyIdentifiers', true),
    minifySyntax: cfg.get<boolean>('minifySyntax', true),
    treeShaking: cfg.get<boolean>('treeShaking', true),
    preserveUniformStructTypes: cfg.get<boolean>('preserveUniformStructTypes', false),
    mangleExternalBindings: cfg.get<boolean>('mangleExternalBindings', false),
    sortDeclarations: cfg.get<boolean>('sortDeclarations', false),
    scopeLocalRename: cfg.get<boolean>('scopeLocalRename', false),
    keepNames: cfg.get<string[]>('keepNames', []),
  };
}

function formatError(err: unknown): string {
  if (err instanceof Error) return err.message;
  return String(err);
}
