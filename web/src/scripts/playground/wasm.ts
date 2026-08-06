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
    // Astro rewrites `import.meta.env.BASE_URL` at build time; the `?.` keeps
    // this module importable from a plain Node process too.
    const base = import.meta.env?.BASE_URL ?? '/';
    const url = (name: string) => new URL(name, new URL(base, location.origin)).href;

    started = {
      lsp: initLsp({ wasmURL: url('wgslender-lsp.wasm') }),
      minifier: initMinifier({ wasmURL: url('wgslender.wasm') }),
    };
  }
  return started;
}
