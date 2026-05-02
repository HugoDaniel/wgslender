// Lazy-loaded singleton over the wgslender npm package.
//
// The minify/compile commands need the non-LSP wgslender.wasm from
// dist/. We load it on first command invocation (not at activate()) so
// the extension stays cold-start cheap for users who never reach for
// the toolchain commands.
//
// Both the desktop and web hosts call the same code path: read the
// wasm via workspace.fs (works for all VS Code hosts), pre-compile
// into a WebAssembly.Module, then pass it through to
// wgslender.initialize({ wasmModule }). This avoids the package's own
// wasmURL fallbacks (which use require.resolve on desktop and fetch on
// web — both are awkward in a bundled VSIX).

import { ExtensionContext, Uri, workspace } from 'vscode';

import * as wgslender from 'wgslender';

let initPromise: Promise<typeof wgslender> | undefined;

export async function getWgslenderEngine(context: ExtensionContext): Promise<typeof wgslender> {
  if (!initPromise) {
    initPromise = (async () => {
      const wasmUri = Uri.joinPath(context.extensionUri, 'dist', 'wgslender.wasm');
      const wasmBytes = await workspace.fs.readFile(wasmUri);
      const wasmModule = await WebAssembly.compile(wasmBytes as BufferSource);
      await wgslender.initialize({ wasmModule });
      return wgslender;
    })();
  }
  return initPromise;
}
