// Web (browser) entry point for the wgslender VS Code extension.
//
// Spawns a Web Worker that hosts the wgslender-lsp WASM module and wires
// it to the LanguageClient. The Worker is required in the browser host
// because the synchronous WASM pump would otherwise block the UI thread.

import { ExtensionContext, Uri } from 'vscode';
import { LanguageClient, LanguageClientOptions } from 'vscode-languageclient/browser';

import { WgslenderApi } from './api';
import { buildClientOptions } from './client-options';
import { registerCompileCommands, compileOptionsFromConfig } from './commands/compile';
import { registerLspCommands } from './commands/lsp';
import { registerMinifyCommands, minifyOptionsFromConfig } from './commands/minify';
import { registerFixOnSave } from './fix-on-save';
import { registerReflectionView } from './reflection';
import { registerMinifyStatusBar } from './status-bar';

let client: LanguageClient | undefined;

export async function activate(context: ExtensionContext): Promise<WgslenderApi> {
  const workerUri = Uri.joinPath(context.extensionUri, 'dist', 'server.js');
  const worker = new Worker(workerUri.toString(true));

  const clientOptions: LanguageClientOptions = buildClientOptions();

  client = new LanguageClient('wgslender', 'wgslender Language Server', clientOptions, worker);
  await client.start();

  const reflection = registerReflectionView(client);
  const statusBar = registerMinifyStatusBar(context);
  context.subscriptions.push(
    ...registerLspCommands(client),
    ...registerMinifyCommands(context),
    ...registerCompileCommands(context),
    registerFixOnSave(context),
    ...reflection.disposables,
    ...statusBar.disposables,
  );

  return {
    client,
    reflection: reflection.provider,
    statusBarItem: statusBar.item,
    resolveMinifyOptions: minifyOptionsFromConfig,
    resolveCompileOptions: compileOptionsFromConfig,
  };
}

export async function deactivate(): Promise<void> {
  await client?.stop();
  client = undefined;
}
