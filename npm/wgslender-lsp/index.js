// wgslender-lsp — WASM-based WGSL Language Server (CommonJS)

'use strict';

const fs = require('fs');
const path = require('path');

const _encoder = new TextEncoder();
const _decoder = new TextDecoder();

let _wasm = null;
let _initPromise = null;

async function initialize(options) {
  options = options || {};
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
      wasmURL = path.join(__dirname, 'wgslender-lsp.wasm');
    }
    const wasmPath = wasmURL instanceof URL ? wasmURL.pathname : wasmURL;
    const wasmBuffer = fs.readFileSync(wasmPath);
    wasmModule = await WebAssembly.compile(wasmBuffer);
  }
  const instance = await WebAssembly.instantiate(wasmModule, {});
  _wasm = instance.exports;
}

function isInitialized() {
  return _wasm !== null;
}

function sendMessage(json) {
  if (!_wasm) throw new Error('wgslender-lsp not initialized. Call initialize() first.');

  const encoded = _encoder.encode(json);
  const ptr = _wasm.wgslender_lsp_alloc(encoded.length);
  if (!ptr) throw new Error('WASM allocation failed');
  new Uint8Array(_wasm.memory.buffer, ptr, encoded.length).set(encoded);
  _wasm.wgslender_lsp_send(ptr, encoded.length);

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

function createTransport() {
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

module.exports = { initialize, isInitialized, sendMessage, createTransport };
