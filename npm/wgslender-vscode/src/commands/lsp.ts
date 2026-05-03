// Commands backed entirely by the language server.
//
// These three palette entries dispatch via the existing wgslender-lsp
// transport — no local WASM loading required. They were declared in
// package.json since v0.1.0 but never registered until now.

import {
  Disposable,
  ViewColumn,
  commands,
  window,
  workspace,
} from 'vscode';
import { BaseLanguageClient } from 'vscode-languageclient';

interface ReflectResult {
  uri: string;
  version: 1 | 2;
  json: string;
}

type MinifyMode = 'off' | 'insights' | 'strict';

const MODE_CYCLE: Record<MinifyMode, MinifyMode> = {
  off: 'insights',
  insights: 'strict',
  strict: 'off',
};

export function registerLspCommands(client: BaseLanguageClient): Disposable[] {
  return [
    commands.registerCommand('wgslender.reflect', () => runReflect(client)),
    commands.registerCommand('wgslender.toggleMinifyMode', () => toggleMinifyMode(client)),
    commands.registerCommand('wgslender.recomputeMinifyInsights', () =>
      recomputeMinifyInsights(client),
    ),
  ];
}

async function runReflect(client: BaseLanguageClient): Promise<void> {
  const editor = window.activeTextEditor;
  if (!editor || editor.document.languageId !== 'wgsl') {
    window.showInformationMessage('wgslender: open a .wgsl document first.');
    return;
  }

  const config = workspace.getConfiguration('wgslender');
  const version = config.get<'v1' | 'v2'>('reflect.version', 'v2');

  let result: ReflectResult;
  try {
    result = await client.sendRequest<ReflectResult>('wgslender/reflect', {
      textDocument: { uri: editor.document.uri.toString() },
      format: version,
      pretty: true,
    });
  } catch (err) {
    window.showErrorMessage(`wgslender: reflect failed — ${formatError(err)}`);
    return;
  }

  const doc = await workspace.openTextDocument({
    language: 'json',
    content: result.json,
  });
  await window.showTextDocument(doc, { preview: true, viewColumn: ViewColumn.Beside });
}

async function toggleMinifyMode(client: BaseLanguageClient): Promise<void> {
  const config = workspace.getConfiguration('wgslender');
  const current = config.get<MinifyMode>('lsp.minifyMode', 'off');
  const next = MODE_CYCLE[current];

  // Server cycles its own copy via executeCommand. We update the user-
  // scoped setting too, so the value the user sees in Settings UI moves.
  try {
    await client.sendRequest('workspace/executeCommand', {
      command: 'wgslender.toggleMinifyMode',
      arguments: [],
    });
  } catch (err) {
    window.showErrorMessage(`wgslender: toggle failed — ${formatError(err)}`);
    return;
  }

  await config.update('lsp.minifyMode', next, true);
  window.setStatusBarMessage(`wgslender: minify mode → ${next}`, 2000);
}

async function recomputeMinifyInsights(client: BaseLanguageClient): Promise<void> {
  const editor = window.activeTextEditor;
  if (!editor || editor.document.languageId !== 'wgsl') {
    window.showInformationMessage('wgslender: open a .wgsl document first.');
    return;
  }

  // The WASM transport accepts this as a notification (raw string match
  // in lsp/wasm.zig), bypassing executeCommand. The native transport
  // doesn't currently route this name, but the desktop extension also
  // uses the WASM build so the notification path is fine for both hosts.
  await client.sendNotification('wgslender/recomputeMinifyInsights', {
    textDocument: { uri: editor.document.uri.toString() },
  });
}

function formatError(err: unknown): string {
  if (err instanceof Error) return err.message;
  return String(err);
}
