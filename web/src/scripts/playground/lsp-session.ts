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

import type { LspInlayHint, LspPosition } from './insights';

/** `src/MinifySettings.zig` `Mode`. */
export type MinifyMode = 'off' | 'insights' | 'strict';

/** Result of `wgslender.showMinifiedOutput` (`lsp/wire/workspace_commands.zig`). */
export interface MinifiedOutput {
  uri: string;
  minified_text: string;
  byte_count: number;
  gz_count: number;
}

/** A `textDocument/publishDiagnostics` payload, exactly as the server sent it. */
export interface DiagnosticsPayload {
  uri: string;
  diagnostics: unknown[];
}

export interface Session {
  client: LSPClient;
  uri: string;
  /** Add to an `EditorState` to connect that editor to the server. */
  extension: Extension;
  refreshInsights(): void;
  showMinifiedOutput(): Promise<MinifiedOutput>;
  setMinifyMode(mode: MinifyMode): Promise<unknown>;
  /**
   * Inlay hints for `range`. lsp-client has no inlay-hint support, so this is
   * a plain request and `insights.ts` does the rendering.
   *
   * The minify-size lane ignores `range` and always answers whole-document
   * (pinned in `tests/lsp-flow.test.mjs`); the range is sent honestly anyway,
   * so the hints keep arriving if the server ever starts honouring it.
   */
  inlayHints(range: { start: LspPosition; end: LspPosition }): Promise<LspInlayHint[]>;
  /**
   * Listen for this document's diagnostics. Returns an unsubscribe function.
   *
   * The panel wants the server's own payload — codes, spec links and all —
   * and lsp-client's rendering path narrows that to what `@codemirror/lint`
   * needs. Subscribing to the transport alongside lsp-client costs nothing
   * (the transport fans out to every handler) and keeps `formatDiagnostics`
   * working on the shape its tests pin.
   */
  onDiagnostics(listener: (payload: DiagnosticsPayload) => void): () => void;
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
  const transport = createTransport();
  client.connect(transport);
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

    async inlayHints(range) {
      // The server answers `null`, not `[]`, when it has nothing to say.
      const hints = await client.request<unknown, LspInlayHint[] | null>(
        'textDocument/inlayHint',
        { textDocument: { uri }, range },
      );
      return hints ?? [];
    },

    onDiagnostics(listener) {
      const handler = (message: string) => {
        let parsed: { method?: string; params?: DiagnosticsPayload };
        try {
          parsed = JSON.parse(message);
        } catch {
          return; // Not our business: lsp-client owns protocol errors.
        }
        if (parsed.method !== 'textDocument/publishDiagnostics') return;
        if (parsed.params?.uri !== uri) return;

        // The transport dispatches synchronously from inside `send`, which
        // itself runs from a CodeMirror update listener. Deferring keeps
        // panel rendering out of that call stack.
        const payload = parsed.params;
        queueMicrotask(() => listener(payload));
      };

      transport.subscribe(handler);
      return () => transport.unsubscribe(handler);
    },
  };
}
