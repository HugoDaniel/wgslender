/**
 * wgslender - WGSL Minifier for WebGPU Shaders (Node.js ESM Build)
 *
 * Usage:
 *   import { initialize, minify } from 'wgslender'
 *   await initialize()
 *   const result = minify(source, { minifyWhitespace: true })
 */

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

import core from '../lib/_core.cjs';
const { createWrapper } = core;

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

async function loadWasm(options) {
  let wasmModule = options.wasmModule;
  if (!wasmModule) {
    let wasmURL = options.wasmURL;
    if (!wasmURL) wasmURL = path.join(__dirname, '..', 'wgslender.wasm');
    const wasmPath = wasmURL instanceof URL ? wasmURL.pathname : wasmURL;
    const wasmBuffer = fs.readFileSync(wasmPath);
    wasmModule = await WebAssembly.compile(wasmBuffer);
  }
  const instance = await WebAssembly.instantiate(wasmModule, {});
  return instance.exports;
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

// `version` is a getter on `wgslender`. ESM `export const` snapshots
// values at evaluation time, so wrap in a thenable-string surrogate
// (matches the previous esm/node.mjs behavior).
export const version = {
  toString: () => wgslender.version,
  valueOf: () => wgslender.version,
};

export default wgslender;
