import { defineConfig, type Plugin } from 'vite';

/**
 * Drop the second copy of `wgslender-lsp.wasm` that Vite emits into `assets/`.
 *
 * `wgslender-lsp` picks a default wasm location with
 * `new URL('./wgslender-lsp.wasm', import.meta.url)` on the branch it takes
 * when the caller supplies neither a module nor a URL. Vite resolves that
 * literal at build time, so it emits a hashed 900 KB copy of the binary and
 * rewrites the URL to match — on a branch `initPlayground` never reaches,
 * because it always hands over a module it compiled itself. Nothing fetches
 * those bytes; the ones the page loads are `public/wgslender-lsp.wasm`, put
 * there by `scripts/sync-wasm.mjs`.
 *
 * The invariant this rests on — that the default branch stays unreachable —
 * is held up by `pnpm smoke`: reach it and the language server fails to boot,
 * taking every diagnostic, hover and rename check in the suite down with it.
 */
function dropDuplicateLspWasm(): Plugin {
  return {
    name: 'drop-duplicate-lsp-wasm',
    apply: 'build',
    generateBundle(_options, bundle) {
      for (const name of Object.keys(bundle)) {
        if (bundle[name].type === 'asset' && /(^|\/)wgslender-lsp-[^/]*\.wasm$/.test(name)) {
          delete bundle[name];
        }
      }
    },
  };
}

// Port 4324 is pinned here rather than passed on the command line: `pnpm
// smoke` and `web/CLAUDE.md` both hard-code it, and `pnpm dev`/`pnpm start`/
// `pnpm preview` all need to agree without repeating the flag.
//
// `base` is deliberately left at `/`. The site is also published under
// https://hugodaniel.com/pages/wgslender/, and that path is a fact about the
// blog rather than about this app, so it is passed in from there —
// `make wgslender` in hugodaniel.com builds with `--base=/pages/wgslender/`.
export default defineConfig({
	plugins: [dropDuplicateLspWasm()],
	server: { port: 4324, strictPort: true },
	preview: { port: 4324, strictPort: true },
});
