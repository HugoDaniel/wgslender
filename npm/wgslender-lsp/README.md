# wgslender-lsp

The [wgslender](https://www.npmjs.com/package/wgslender) WGSL language server,
compiled to WebAssembly and driven in-process — no child process, no stdio, no
server to install. Diagnostics, completion, hover, go-to-definition, rename,
formatting, semantic tokens, inlay hints, code actions and lint quickfixes for
[WGSL](https://www.w3.org/TR/WGSL/), in a browser or in Node.

```sh
npm install wgslender-lsp
```

## Use it with CodeMirror

`createTransport()` returns exactly the shape
[`@codemirror/lsp-client`](https://www.npmjs.com/package/@codemirror/lsp-client)
expects, so the two connect directly:

```js
import { initialize, createTransport } from "wgslender-lsp";
import { LSPClient, languageServerSupport } from "@codemirror/lsp-client";

await initialize({ wasmURL: "/wgslender-lsp.wasm" });

const client = new LSPClient().connect(createTransport());
const extensions = languageServerSupport(client, "file:///shader.wgsl", "wgsl");
```

## Or speak JSON-RPC yourself

`sendMessage` takes one JSON-RPC message and returns the messages the server
produced — an array, because a single request can yield a response plus the
notifications that go with it (published diagnostics, for one).

```js
import { initialize, sendMessage } from "wgslender-lsp";

await initialize();

sendMessage(JSON.stringify({
  jsonrpc: "2.0", id: 1, method: "initialize",
  params: { processId: null, rootUri: null, capabilities: {} },
}));

sendMessage(JSON.stringify({
  jsonrpc: "2.0", method: "textDocument/didOpen",
  params: { textDocument: {
    uri: "file:///shader.wgsl", languageId: "wgsl", version: 1,
    text: "@compute @workgroup_size(1) fn main() { let x: f32 = nope; }",
  } },
}));
// -> a textDocument/publishDiagnostics notification carrying E0100
```

## API

| Export | What it does |
|---|---|
| `initialize(options?)` | Loads the WASM module. Must resolve before anything else. |
| `isInitialized()` | Whether it has. |
| `sendMessage(json)` | One JSON-RPC message in, the resulting messages out, as an array of strings. |
| `createTransport()` | A `{ send, subscribe, unsubscribe }` transport for `@codemirror/lsp-client`. |

`initialize` takes either `wasmURL` (a string or `URL`) or `wasmModule` (an
already-compiled `WebAssembly.Module`). With neither, it resolves the `.wasm`
sitting beside this package and loads it the way the environment allows —
read from disk under Node, fetched over http(s) in a browser. In the browser
that default only works if your bundler rewrites
`new URL('./wgslender-lsp.wasm', import.meta.url)` into a real asset URL;
pass `wasmURL` explicitly if it does not.

The file is also a subpath export, `wgslender-lsp/wasm`, for bundlers that
turn an asset import into a URL.

## Where the rest of it lives

This package is the language server alone. Minification, validation, linting,
reflection and the binary-shader compiler are in
[`wgslender`](https://www.npmjs.com/package/wgslender); the CLI, the editor
extension and the Zig, Rust and Go bindings are in the
[repository](https://github.com/HugoDaniel/wgslender).

CC0-1.0.
