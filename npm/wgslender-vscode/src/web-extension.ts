// Web (browser) entry point for the wgslender VS Code extension.
//
// Spawns a Web Worker that hosts the wgslender-lsp WASM module and wires
// it to the LanguageClient. The Worker is required in the browser host
// because the synchronous WASM pump would otherwise block the UI thread.

import { ExtensionContext, Uri, workspace } from 'vscode';
import { LanguageClient, LanguageClientOptions } from 'vscode-languageclient/browser';

let client: LanguageClient | undefined;

export async function activate(context: ExtensionContext): Promise<void> {
  const workerUri = Uri.joinPath(context.extensionUri, 'dist', 'server.js');
  const worker = new Worker(workerUri.toString(true));

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ language: 'wgsl' }],
    synchronize: {
      configurationSection: 'wgslender',
    },
    initializationOptions: workspace.getConfiguration('wgslender'),
  };

  client = new LanguageClient('wgslender', 'wgslender Language Server', clientOptions, worker);
  await client.start();
}

export async function deactivate(): Promise<void> {
  await client?.stop();
  client = undefined;
}
