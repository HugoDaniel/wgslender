// LSP Worker — runs wgslender-lsp.wasm in a Web Worker (browser host).
//
// The Worker bridges JSON-RPC messages posted from the main thread (by
// vscode-languageclient/browser's BrowserMessageReader/Writer, which
// communicate via raw `postMessage(message)` calls where `message` is the
// already-parsed JSON-RPC object) to wgslender-lsp's synchronous
// sendMessage(json) -> string[] pump.

import * as lsp from 'wgslender-lsp';

declare const self: DedicatedWorkerGlobalScope;

type Pending = MessageEvent;
const queue: Pending[] = [];
let ready = false;

self.addEventListener('message', (event: MessageEvent) => {
  if (!ready) {
    queue.push(event);
    return;
  }
  dispatch(event.data);
});

function dispatch(msg: unknown): void {
  const responses = lsp.sendMessage(JSON.stringify(msg));
  for (const json of responses) {
    self.postMessage(JSON.parse(json));
  }
}

async function main(): Promise<void> {
  const wasmURL = new URL('./wgslender-lsp.wasm', self.location.href);
  await lsp.initialize({ wasmURL });
  ready = true;
  while (queue.length > 0) {
    const event = queue.shift()!;
    dispatch(event.data);
  }
}

void main();
