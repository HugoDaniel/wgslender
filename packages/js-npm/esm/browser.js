/**
 * wgslender - WGSL Minifier for WebGPU Shaders (Browser ESM Build)
 *
 * Usage:
 *   import { initialize, minify } from 'wgslender'
 *   await initialize({ wasmURL: '/wgslender.wasm' })
 *   const result = minify(source, { minifyWhitespace: true })
 */

import core from '../lib/_core.cjs';
const { createWrapper } = core;

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
        throw new Error(`Failed to fetch ${url}: ${response.status}`);
      }
      const result = await WebAssembly.instantiateStreaming(response, {});
      return result.instance.exports;
    } catch (err) {
      if (err.message && err.message.includes('MIME')) {
        const response = await fetch(url);
        const bytes = await response.arrayBuffer();
        const result = await WebAssembly.instantiate(bytes, {});
        return result.instance.exports;
      }
      throw err;
    }
  }

  const response = await fetch(url);
  const bytes = await response.arrayBuffer();
  const result = await WebAssembly.instantiate(bytes, {});
  return result.instance.exports;
}

const wgslender = createWrapper({ loadWasm });

export const initialize = wgslender.initialize;
export const minify = wgslender.minify;
export const compile = wgslender.compile;
export const reflect = wgslender.reflect;
export const minifyAndReflect = wgslender.minifyAndReflect;
export const getBindGroups = wgslender.getBindGroups;
export const validate = wgslender.validate;
export const lint = wgslender.lint;
export const lintAndFix = wgslender.lintAndFix;
export const findReferences = wgslender.findReferences;
export const rename = wgslender.rename;
export const renameApply = wgslender.renameApply;
export const stableIdAtOffset = wgslender.stableIdAtOffset;
export const locateStableId = wgslender.locateStableId;
export const locateDeclaration = wgslender.locateDeclaration;
export const locateType = wgslender.locateType;
export const renameByStableId = wgslender.renameByStableId;
export const removeDeclarationByStableId = wgslender.removeDeclarationByStableId;
export const removeDeclarationApplyByStableId = wgslender.removeDeclarationApplyByStableId;
export const changeTypeByStableId = wgslender.changeTypeByStableId;
export const changeTypeApplyByStableId = wgslender.changeTypeApplyByStableId;
export const isInitialized = wgslender.isInitialized;
export const getVersion = wgslender.getVersion;

// `version` is a getter on `wgslender`. ESM `export const` snapshots
// values at evaluation time, so wrap in a thenable-string surrogate
// (matches the previous esm/browser.js behavior).
export const version = {
  toString: () => wgslender.version,
  valueOf: () => wgslender.version,
};

export default wgslender;
