/**
 * Boots the two wasm modules the playground runs on.
 *
 * They are kept deliberately separate. `wgslender-lsp.wasm` (~870 KB) is
 * everything positional — diagnostics, hover, completion, definition, rename,
 * inlay hints — and the editor cannot do its job without it.
 * `wgslender.wasm` (~750 KB) is the library API — `minify`, `reflect`,
 * `lint` — which only the output panels need. Returning one promise each
 * means the editor comes up as soon as the language server is ready instead
 * of waiting on 1.6 MB of downloads.
 *
 * The files are served from `public/`, put there by `scripts/sync-wasm.mjs`.
 */
import { initialize as initMinifier } from 'wgslender';
import { initialize as initLsp } from 'wgslender-lsp';

export interface PlaygroundWasm {
  /** Resolves when `wgslender-lsp` can answer requests. */
  lsp: Promise<void>;
  /** Resolves when `minify` / `reflect` / `lint` can be called. */
  minifier: Promise<void>;
}

let started: PlaygroundWasm | null = null;

/**
 * Start both downloads. Idempotent: later calls join the first one's
 * promises, so every module can ask for what it needs without coordinating.
 */
export function initPlayground(): PlaygroundWasm {
  if (!started) {
    // Vite rewrites `import.meta.env.BASE_URL` at build time; the `?.` keeps
    // this module importable from a plain Node process too.
    const base = import.meta.env?.BASE_URL ?? '/';
    const url = (name: string) => new URL(name, new URL(base, location.origin)).href;

    started = {
      lsp: compile(url('wgslender-lsp.wasm')).then((wasmModule) => initLsp({ wasmModule })),
      minifier: compile(url('wgslender.wasm')).then((wasmModule) => initMinifier({ wasmModule })),
    };
  }
  return started;
}

/**
 * Fetch and compile one binary, streaming it when the host lets us.
 *
 * `WebAssembly.compileStreaming` refuses anything not served as
 * `application/wasm`, and a plain static host serves `.wasm` as
 * `application/octet-stream` — hugodaniel.com, where this page is published,
 * does exactly that. `wgslender` retries through a buffer when it sees a MIME
 * error; `wgslender-lsp` calls `compileStreaming` and lets the rejection
 * through, so on such a host the language server never starts and the editor
 * arrives with no diagnostics, no hover and no rename. Choosing off the
 * response header keeps both on the streaming path wherever the type is right
 * and works everywhere else, which is the difference between this page being
 * portable and being correct only on a server we control.
 */
async function compile(url: string): Promise<WebAssembly.Module> {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${url} → HTTP ${response.status}`);
  if (response.headers.get('content-type')?.startsWith('application/wasm')) {
    return WebAssembly.compileStreaming(response);
  }
  return WebAssembly.compile(await response.arrayBuffer());
}
