// Typed surface returned from `activate` on both hosts — reachable via
// `extensions.getExtension('hugodaniel.wgslender-vscode').exports`. The
// integration suite drives the pieces that have no other observable
// handle (the sidebar provider, the status bar item, the option bags the
// palette commands resolve from settings).

import { StatusBarItem } from 'vscode';
import { BaseLanguageClient } from 'vscode-languageclient';

import { ReflectionProvider } from './reflection/provider';

export interface WgslenderApi {
  /** The running language client (in-process WASM on desktop, Worker on web). */
  client: BaseLanguageClient;
  /** The Reflection sidebar's tree data provider. */
  reflection: ReflectionProvider;
  /** The minify-size status bar item. */
  statusBarItem: StatusBarItem;
  /** Option bag `minifyPreview` / `minifySaveAs` pass to the engine. */
  resolveMinifyOptions(): Record<string, unknown>;
  /** Option bag `compile` passes to the engine. */
  resolveCompileOptions(): Record<string, unknown>;
}
