// Desktop (Node) entry point for the wgslender VS Code extension.
//
// Loads the wgslender-lsp WASM module in-process, exposes its synchronous
// JSON-RPC pump as a MessageReader/MessageWriter pair, and starts the
// LanguageClient against it. No child process, no Worker — the whole LSP
// runs in the extension host.

import { ExtensionContext, Uri, workspace } from 'vscode';
import { LanguageClient, LanguageClientOptions, ServerOptions } from 'vscode-languageclient/node';

import { WgslenderApi } from './api';
import { buildClientOptions } from './client-options';
import { registerCompileCommands, compileOptionsFromConfig } from './commands/compile';
import { registerLspCommands } from './commands/lsp';
import { registerMinifyCommands, minifyOptionsFromConfig } from './commands/minify';
import { registerFixOnSave } from './fix-on-save';
import { registerReflectionView } from './reflection';
import { registerMinifyStatusBar } from './status-bar';
import { createInProcessTransports } from './transport';

let client: LanguageClient | undefined;

export async function activate(context: ExtensionContext): Promise<WgslenderApi> {
  const wasmUri = Uri.joinPath(context.extensionUri, 'dist', 'wgslender-lsp.wasm');
  const wasmBytes = await workspace.fs.readFile(wasmUri);
  const wasmModule = await WebAssembly.compile(wasmBytes as BufferSource);

  const lsp = await import('wgslender-lsp');
  await lsp.initialize({ wasmModule });

  const serverOptions: ServerOptions = async () => createInProcessTransports(lsp.sendMessage);

  const clientOptions: LanguageClientOptions = buildClientOptions();

  client = new LanguageClient('wgslender', 'wgslender Language Server', serverOptions, clientOptions);
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
