// Right-side status-bar item showing the minified byte size of the
// active .wgsl document. Click cycles wgslender.lsp.minifyMode through
// off → insights → strict via the existing toggle command (Phase 2).

import {
  Disposable,
  ExtensionContext,
  StatusBarAlignment,
  StatusBarItem,
  TextDocument,
  TextEditor,
  window,
  workspace,
} from 'vscode';

import { minifyOptionsFromConfig } from './commands/minify';
import { getWgslenderEngine } from './wgslender-engine';

const RECOMPUTE_DEBOUNCE_MS = 250;

type MinifyMode = 'off' | 'insights' | 'strict';

export interface MinifyStatusBar {
  disposables: Disposable[];
  item: StatusBarItem;
}

export function registerMinifyStatusBar(context: ExtensionContext): MinifyStatusBar {
  const item = window.createStatusBarItem(StatusBarAlignment.Right, 100);
  item.command = 'wgslender.toggleMinifyMode';
  item.tooltip = 'wgslender: toggle minify insights mode';

  const cache = new Map<string, { version: number; text: string; tooltip: string }>();
  let pending: NodeJS.Timeout | undefined;
  let lastRunToken = 0;

  const update = (editor: TextEditor | undefined): void => {
    const mode = workspace.getConfiguration('wgslender').get<MinifyMode>('lsp.minifyMode', 'off');
    if (!editor || editor.document.languageId !== 'wgsl' || mode === 'off') {
      item.hide();
      return;
    }
    const cached = cache.get(editor.document.uri.toString());
    if (cached && cached.version === editor.document.version) {
      item.text = cached.text;
      item.tooltip = cached.tooltip;
      item.show();
      return;
    }
    item.text = '$(loading~spin) wgslender';
    item.tooltip = 'wgslender: computing minified size…';
    item.show();
    void runRecompute(editor.document);
  };

  const runRecompute = async (doc: TextDocument): Promise<void> => {
    const token = ++lastRunToken;
    try {
      const engine = await getWgslenderEngine(context);
      // Same option bag as Save Minified As, so the size shown here is
      // the size that command would write.
      const result = engine.minify(doc.getText(), minifyOptionsFromConfig());
      if (token !== lastRunToken) return;
      const text = formatSize(result.originalSize, result.minifiedSize);
      const tooltip = `wgslender: ${result.originalSize} B → ${result.minifiedSize} B`;
      cache.set(doc.uri.toString(), { version: doc.version, text, tooltip });

      const active = window.activeTextEditor;
      if (active && active.document.uri.toString() === doc.uri.toString()) {
        item.text = text;
        item.tooltip = tooltip;
        item.show();
      }
    } catch (err) {
      if (token !== lastRunToken) return;
      const active = window.activeTextEditor;
      if (active && active.document.uri.toString() === doc.uri.toString()) {
        item.text = '$(warning) wgslender';
        item.tooltip = `wgslender: ${err instanceof Error ? err.message : String(err)}`;
        item.show();
      }
    }
  };

  const schedule = (editor: TextEditor | undefined): void => {
    if (pending) clearTimeout(pending);
    pending = setTimeout(() => {
      pending = undefined;
      update(editor);
    }, RECOMPUTE_DEBOUNCE_MS);
  };

  schedule(window.activeTextEditor);

  const disposables: Disposable[] = [
    item,
    window.onDidChangeActiveTextEditor((e) => schedule(e)),
    workspace.onDidSaveTextDocument((doc) => {
      const editor = window.activeTextEditor;
      if (!editor || editor.document.uri.toString() !== doc.uri.toString()) return;
      cache.delete(doc.uri.toString());
      schedule(editor);
    }),
    workspace.onDidChangeConfiguration((e) => {
      // The whole section: `lsp.minifyMode` decides visibility, and any
      // `minify*` knob shifts the computed size. (`wgslender.minify` is
      // not a real section — matching it left the item stale until the
      // next editor switch.)
      if (e.affectsConfiguration('wgslender')) {
        cache.clear();
        schedule(window.activeTextEditor);
      }
    }),
    new Disposable(() => {
      if (pending) clearTimeout(pending);
    }),
  ];
  return { disposables, item };
}

function formatSize(originalSize: number, minifiedSize: number): string {
  const ratio = originalSize > 0 ? Math.round((1 - minifiedSize / originalSize) * 100) : 0;
  return `$(zap) min: ${humanBytes(minifiedSize)} (-${ratio}%)`;
}

function humanBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  const kb = n / 1024;
  if (kb < 1024) return `${kb.toFixed(kb < 10 ? 1 : 0)} KB`;
  return `${(kb / 1024).toFixed(2)} MB`;
}
