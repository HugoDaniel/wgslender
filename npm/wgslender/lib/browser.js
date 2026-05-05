/**
 * wgslender - WGSL Minifier for WebGPU Shaders (Browser Build)
 *
 * Bundled via the npm package's "browser" / default conditions. Consumed
 * by browser bundlers (webpack, esbuild, rollup, vite, browserify) which
 * inline the required ./_core.cjs along with this shim.
 *
 * Usage:
 *   import { initialize, minify } from 'wgslender'
 *   await initialize({ wasmURL: '/wgslender.wasm' })
 *   const result = minify(source, { minifyWhitespace: true })
 */

'use strict';

const { createWrapper } = require('./_core.cjs');

async function loadWasm(options) {
  if (!options.wasmURL && !options.wasmModule) {
    throw new Error('Must provide either wasmURL or wasmModule');
  }

  if (options.wasmModule) {
    const instance = await WebAssembly.instantiate(options.wasmModule, {});
    return instance.exports;
  }

  const url = options.wasmURL instanceof URL ? options.wasmURL.href : options.wasmURL;

  if (typeof WebAssembly.instantiateStreaming === 'function') {
    try {
      const response = await fetch(url);
      if (!response.ok) {
        throw new Error('Failed to fetch ' + url + ': ' + response.status);
      }
      const result = await WebAssembly.instantiateStreaming(response, {});
      return result.instance.exports;
    } catch (err) {
      // Fall back to arrayBuffer if streaming fails (e.g., wrong MIME type)
      if (err.message && err.message.includes('MIME')) {
        const response = await fetch(url);
        const bytes = await response.arrayBuffer();
        const result = await WebAssembly.instantiate(bytes, {});
        return result.instance.exports;
      }
      throw err;
    }
  }

  // Fallback for older browsers
  const response = await fetch(url);
  const bytes = await response.arrayBuffer();
  const result = await WebAssembly.instantiate(bytes, {});
  return result.instance.exports;
}

module.exports = createWrapper({ loadWasm });
