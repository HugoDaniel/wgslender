// Commands backed entirely by the language server.
//
// These three palette entries dispatch via the existing wgslender-lsp
// transport — no local WASM loading required. They were declared in
// package.json since v0.1.0 but never registered until now.
//
// Two namespaces meet in this file and must not be confused. `wgslender.*`
// are *our* VS Code command ids, contributed in package.json and bound to
// keybindings and menus. `wgslender.server.*` are the language server's
// `workspace/executeCommand` ids. They were the same strings once, and
// vscode-languageclient registers a VS Code command for every id the server
// advertises — so registerCommand below threw "command already exists" and
// took the rest of `activate` with it.

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
  /**
   * The reflection, as a structured value — not a string. The handler
   * renders JSON text, but both transports put it on the wire as a nested
   * object (`lsp/wire/workspace_commands.zig::appendReflectResult` embeds it
   * verbatim; the lsp-kit path parses it first), so it arrives here parsed.
   * Declaring it `string` made this command open a document containing
   * "[object Object]".
   */
  json: unknown;
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
    // No `pretty`: the server's formatting cannot survive a round trip
    // through a structured `json` field, so the indentation is ours to add.
    result = await client.sendRequest<ReflectResult>('wgslender/reflect', {
      textDocument: { uri: editor.document.uri.toString() },
      format: version,
    });
  } catch (err) {
    window.showErrorMessage(`wgslender: reflect failed — ${formatError(err)}`);
    return;
  }

  const doc = await workspace.openTextDocument({
    language: 'json',
    content: typeof result.json === 'string' ? result.json : JSON.stringify(result.json, null, 2),
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
      command: 'wgslender.server.toggleMinifyMode',
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
