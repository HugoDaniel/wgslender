// wgslender-lsp — WASM-based WGSL Language Server
//
// Provides a Transport-compatible interface for @codemirror/lsp-client.
// All LSP communication happens synchronously in-process via WASM calls.

const _encoder = new TextEncoder();
const _decoder = new TextDecoder();

let _wasm = null;
let _initPromise = null;

/**
 * Initialize the WASM module.
 * @param {Object} [options]
 * @param {WebAssembly.Module} [options.wasmModule] - Pre-compiled WASM module
 * @param {string|URL} [options.wasmURL] - URL to the .wasm file
 */
export async function initialize(options = {}) {
  if (_wasm) return;
  if (_initPromise) return _initPromise;
  _initPromise = _doInitialize(options);
  await _initPromise;
}

async function _doInitialize(options) {
  let wasmModule = options.wasmModule;
  if (!wasmModule) {
    let wasmURL = options.wasmURL;
    if (!wasmURL) {
      // Try to resolve relative to this module
      wasmURL = new URL('./wgslender-lsp.wasm', import.meta.url);
    }
    const response = await fetch(wasmURL);
    wasmModule = await WebAssembly.compileStreaming(response);
  }
  const instance = await WebAssembly.instantiate(wasmModule, {});
  _wasm = instance.exports;
}

/**
 * Check if the WASM module is initialized.
 */
export function isInitialized() {
  return _wasm !== null;
}

/**
 * Send a JSON-RPC message to the WASM LSP server and return any responses.
 * @param {string} json - JSON-RPC message string
 * @returns {string[]} Array of JSON-RPC response/notification strings
 */
export function sendMessage(json) {
  if (!_wasm) throw new Error('wgslender-lsp not initialized. Call initialize() first.');

  const encoded = _encoder.encode(json);
  const ptr = _wasm.wgslender_lsp_alloc(encoded.length);
  if (!ptr) throw new Error('WASM allocation failed');
  new Uint8Array(_wasm.memory.buffer, ptr, encoded.length).set(encoded);
  _wasm.wgslender_lsp_send(ptr, encoded.length);

  // Collect all outgoing messages.
  const responses = [];
  while (true) {
    const rptr = _wasm.wgslender_lsp_recv();
    if (!rptr) break;
    const view = new DataView(_wasm.memory.buffer);
    const len = view.getUint32(rptr, true);
    const msg = _decoder.decode(new Uint8Array(_wasm.memory.buffer, rptr + 4, len));
    _wasm.wgslender_lsp_dealloc(rptr, len + 4);
    responses.push(msg);
  }
  return responses;
}

/**
 * Create a Transport compatible with @codemirror/lsp-client.
 *
 * Usage:
 *   import { initialize, createTransport } from 'wgslender-lsp';
 *   import { LSPClient, languageServerExtensions } from '@codemirror/lsp-client';
 *
 *   await initialize();
 *   const transport = createTransport();
 *   const client = new LSPClient({ extensions: languageServerExtensions() });
 *   client.connect(transport);
 *
 * @returns {{ send: Function, subscribe: Function, unsubscribe: Function }}
 */
export function createTransport() {
  if (!_wasm) throw new Error('wgslender-lsp not initialized. Call initialize() first.');

  let handlers = [];

  return {
    send(message) {
      const responses = sendMessage(message);
      for (const msg of responses) {
        for (const h of handlers) {
          h(msg);
        }
      }
    },
    subscribe(handler) {
      handlers.push(handler);
    },
    unsubscribe(handler) {
      handlers = handlers.filter(h => h !== handler);
    },
  };
}

export default { initialize, isInitialized, sendMessage, createTransport };
