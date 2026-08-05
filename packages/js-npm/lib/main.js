/**
 * wgslender - WGSL Minifier for WebGPU Shaders (Node.js CJS Build)
 *
 * Usage:
 *   const { initialize, minify } = require('wgslender')
 *   await initialize()
 *   const result = minify(source, { minifyWhitespace: true })
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { createWrapper } = require('./_core.cjs');

async function loadWasm(options) {
  let wasmModule = options.wasmModule;
  if (!wasmModule) {
    let wasmURL = options.wasmURL;
    if (!wasmURL) {
      try {
        wasmURL = require.resolve('wgslender/wgslender.wasm');
      } catch {
        wasmURL = path.join(__dirname, '..', 'wgslender.wasm');
      }
    }
    const wasmPath = wasmURL instanceof URL ? wasmURL.pathname : wasmURL;
    const wasmBuffer = fs.readFileSync(wasmPath);
    wasmModule = await WebAssembly.compile(wasmBuffer);
  }
  const instance = await WebAssembly.instantiate(wasmModule, {});
  return instance.exports;
}

module.exports = createWrapper({ loadWasm });
