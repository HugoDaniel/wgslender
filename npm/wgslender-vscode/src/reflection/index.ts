// Wires the wgslenderReflection sidebar view + its companion commands.

import {
  Disposable,
  TextEditor,
  commands,
  window,
  workspace,
} from 'vscode';
import { BaseLanguageClient } from 'vscode-languageclient';

import { ReflectionProvider } from './provider';

const REFRESH_DEBOUNCE_MS = 250;

export interface ReflectionView {
  disposables: Disposable[];
  provider: ReflectionProvider;
}

export function registerReflectionView(client: BaseLanguageClient): ReflectionView {
  const provider = new ReflectionProvider(client);
  const view = window.createTreeView('wgslenderReflection', {
    treeDataProvider: provider,
    showCollapseAll: true,
  });

  let pendingRefresh: NodeJS.Timeout | undefined;
  const scheduleRefresh = (editor: TextEditor | undefined) => {
    if (pendingRefresh) clearTimeout(pendingRefresh);
    pendingRefresh = setTimeout(() => {
      pendingRefresh = undefined;
      const uri = editor && editor.document.languageId === 'wgsl'
        ? editor.document.uri.toString()
        : undefined;
      const version = workspace.getConfiguration('wgslender').get<'v1' | 'v2'>('reflect.version', 'v2');
      provider.refresh(uri, version);
    }, REFRESH_DEBOUNCE_MS);
  };

  scheduleRefresh(window.activeTextEditor);

  const disposables: Disposable[] = [
    view,
    provider,
    window.onDidChangeActiveTextEditor((e) => scheduleRefresh(e)),
    workspace.onDidSaveTextDocument((doc) => {
      if (doc.languageId !== 'wgsl') return;
      const editor = window.activeTextEditor;
      if (editor && editor.document.uri.toString() === doc.uri.toString()) {
        scheduleRefresh(editor);
      }
    }),
    commands.registerCommand('wgslender.refreshReflection', () =>
      scheduleRefresh(window.activeTextEditor),
    ),
    commands.registerCommand('wgslender.showReflectionPanel', async () => {
      await commands.executeCommand('workbench.view.extension.wgslender');
      await commands.executeCommand('wgslenderReflection.focus');
    }),
    new Disposable(() => {
      if (pendingRefresh) clearTimeout(pendingRefresh);
    }),
  ];
  return { disposables, provider };
}
