#!/usr/bin/env node
/**
 * Browser-variant test runner.
 *
 * Polyfills `globalThis.fetch` so the browser shims' fetch +
 * `WebAssembly.instantiateStreaming` paths can read `wgslender.wasm`
 * from disk. Runs the shared suite against:
 *   1. lib/browser.js  (CJS / UMD shim consumed by browser bundlers)
 *   2. esm/browser.js  (ESM browser shim)
 *
 * Each variant gets a fresh module instance (fresh closure state) so
 * pre-init assertions in the suite stay valid. The fetch polyfill
 * exercises every envelope decoder via the same WASM bytes used in
 * production.
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { runSuite } = require('./_suite.cjs');

const wasmPath = path.join(__dirname, '..', 'wgslender.wasm');
const wasmBytes = fs.readFileSync(wasmPath);

// `WebAssembly.instantiateStreaming` requires a Response with a
// MIME-type header of `application/wasm`. Provide a minimal Response-
// like object backed by the on-disk bytes.
function fakeResponse(url) {
  const ab = wasmBytes.buffer.slice(
    wasmBytes.byteOffset,
    wasmBytes.byteOffset + wasmBytes.byteLength,
  );
  return {
    ok: true,
    status: 200,
    url,
    headers: { get: (k) => (k.toLowerCase() === 'content-type' ? 'application/wasm' : null) },
    arrayBuffer: async () => ab,
  };
}

// Override unconditionally: Node 18+ ships a built-in `fetch` (undici)
// that rejects file:// URLs. The browser shims always go through fetch,
// so route every call through the on-disk wasm bytes.
globalThis.fetch = async (url) => fakeResponse(String(url));

// `WebAssembly.instantiateStreaming` in Node 18+ accepts a Response-like
// thenable; in older Node it's undefined and the shim falls back to the
// arrayBuffer path. Force the arrayBuffer fallback to keep behaviour
// identical across Node versions.
const origStreaming = WebAssembly.instantiateStreaming;
WebAssembly.instantiateStreaming = async (responseOrPromise, imports) => {
  const response = await responseOrPromise;
  const bytes = await response.arrayBuffer();
  return WebAssembly.instantiate(bytes, imports);
};

async function main() {
  let totalFailed = 0;

  // --- Variant 1: lib/browser.js (CJS bundler shim) ---
  // require()-cache is keyed by absolute path; clear so the suite's
  // pre-init assertions run against a fresh module instance.
  const browserCjsPath = require.resolve('../lib/browser.js');
  delete require.cache[browserCjsPath];
  const browserCjs = require(browserCjsPath);
  const r1 = await runSuite(browserCjs, {
    variantName: 'browser-cjs (lib/browser.js)',
    initOptions: { wasmURL: 'file://' + wasmPath },
  });
  totalFailed += r1.failed;

  // --- Variant 2: esm/browser.js (ESM browser shim) ---
  // Dynamic import yields a fresh ES module instance per process.
  const browserEsmUrl = new URL('../esm/browser.js', `file://${__filename}`);
  const browserEsm = await import(browserEsmUrl.href);
  const r2 = await runSuite(browserEsm, {
    variantName: 'browser-esm (esm/browser.js)',
    initOptions: { wasmURL: 'file://' + wasmPath },
  });
  totalFailed += r2.failed;

  // Restore for cleanliness.
  if (origStreaming) WebAssembly.instantiateStreaming = origStreaming;

  process.exit(totalFailed > 0 ? 1 : 0);
}

main().catch((err) => {
  console.error('Fatal error:', err);
  process.exit(1);
});
