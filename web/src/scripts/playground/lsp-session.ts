/**
 * The bridge between CodeMirror and `wgslender-lsp.wasm`.
 *
 * `@codemirror/lsp-client` already covers the standard half of LSP —
 * completion, hover, formatting, rename, signature help, jump-to-definition,
 * find-references and push-diagnostic rendering all arrive with
 * `languageServerExtensions()`, so none of that is reimplemented here.
 *
 * What this module adds is the wgslender-specific half:
 *
 * - `refreshInsights()`. The server's edit hot path publishes *cheap*
 *   diagnostics only (validator + general lint), and explicitly defers the
 *   minify-lint and size-estimator pass to the client — the WASM build has no
 *   debounce of its own. Sending `wgslender/recomputeMinifyInsights` once
 *   typing settles is the client's half of that contract; skip it and minify
 *   diagnostics simply never appear.
 * - `showMinifiedOutput()`. Returns the server's own gzip count, which is
 *   where the stats bar's compressed number comes from — no JS gzip needed.
 * - `setMinifyMode()`. lsp-client advertises no `workspace` capabilities, so
 *   the server never asks for configuration; `workspace/executeCommand` is
 *   the only route to flipping the mode that gates minify-size inlay hints.
 *
 * Deliberately *not* debounced here: one timer drives the whole page (panels,
 * insights and this notification together), so it lives at the call site.
 */
import { LSPClient, languageServerExtensions } from '@codemirror/lsp-client';
import type { Extension } from '@codemirror/state';
import { createTransport } from 'wgslender-lsp';

/** `src/MinifySettings.zig` `Mode`. */
export type MinifyMode = 'off' | 'insights' | 'strict';

/** Result of `wgslender.showMinifiedOutput` (`lsp/wire/workspace_commands.zig`). */
export interface MinifiedOutput {
  uri: string;
  minified_text: string;
  byte_count: number;
  gz_count: number;
}

export interface Session {
  client: LSPClient;
  uri: string;
  /** Add to an `EditorState` to connect that editor to the server. */
  extension: Extension;
  refreshInsights(): void;
  showMinifiedOutput(): Promise<MinifiedOutput>;
  setMinifyMode(mode: MinifyMode): Promise<unknown>;
}

function executeCommand<T>(client: LSPClient, command: string, args: unknown[]): Promise<T> {
  return client.request('workspace/executeCommand', { command, arguments: args });
}

/**
 * Connect to the in-tab language server and open `uri`. Resolves once the
 * initialize handshake is done, so callers can build an editor immediately.
 */
export async function createSession(uri: string): Promise<Session> {
  const client = new LSPClient({ extensions: languageServerExtensions() });
  client.connect(createTransport());
  await client.initializing;

  return {
    client,
    uri,
    // lsp-client would derive this from `Language.name` anyway; passing it
    // keeps the editor's language config and the server's view in step even
    // if a future extension reorders the language stack.
    extension: client.plugin(uri, 'wgsl'),

    refreshInsights() {
      client.notification('wgslender/recomputeMinifyInsights', { textDocument: { uri } });
    },

    showMinifiedOutput() {
      return executeCommand<MinifiedOutput>(client, 'wgslender.showMinifiedOutput', [uri]);
    },

    setMinifyMode(mode) {
      return executeCommand(client, 'wgslender.setMinifyMode', [mode]);
    },
  };
}
