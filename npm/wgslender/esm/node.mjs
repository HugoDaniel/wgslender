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

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

let _initialized = false;
let _initPromise = null;
let _wasm = null;

const _encoder = new TextEncoder();
const _decoder = new TextDecoder();

/**
 * Initialize the WASM module.
 * @param {Object} [options]
 * @param {string} [options.wasmURL] - Path to wgslender.wasm
 * @param {WebAssembly.Module} [options.wasmModule] - Pre-compiled module
 * @returns {Promise<void>}
 */
export async function initialize(options) {
  if (_initialized) {
    return;
  }
  if (_initPromise) {
    return _initPromise;
  }

  options = options || {};
  _initPromise = _doInitialize(options);

  try {
    await _initPromise;
    _initialized = true;
  } catch (err) {
    _initPromise = null;
    throw err;
  }
}

async function _doInitialize(options) {
  let wasmModule = options.wasmModule;

  if (!wasmModule) {
    let wasmURL = options.wasmURL;
    if (!wasmURL) {
      wasmURL = path.join(__dirname, '..', 'wgslender.wasm');
    }
    const wasmPath = wasmURL instanceof URL ? wasmURL.pathname : wasmURL;
    const wasmBuffer = fs.readFileSync(wasmPath);
    wasmModule = await WebAssembly.compile(wasmBuffer);
  }

  const instance = await WebAssembly.instantiate(wasmModule, {});
  _wasm = instance.exports;
}

function _writeString(s) {
  const encoded = _encoder.encode(s);
  if (encoded.length === 0) {
    const ptr = _wasm.wgslender_alloc(1);
    if (!ptr) throw new Error('WASM allocation failed');
    return { ptr, len: 0, allocLen: 1 };
  }
  const ptr = _wasm.wgslender_alloc(encoded.length);
  if (!ptr) throw new Error('WASM allocation failed');
  new Uint8Array(_wasm.memory.buffer, ptr, encoded.length).set(encoded);
  return { ptr, len: encoded.length, allocLen: encoded.length };
}

function _readResultJson(ptr) {
  const view = new DataView(_wasm.memory.buffer);
  const jsonLen = view.getUint32(ptr, true);
  const json = _decoder.decode(new Uint8Array(_wasm.memory.buffer, ptr + 4, jsonLen));
  _wasm.wgslender_dealloc(ptr, jsonLen + 4);
  return JSON.parse(json);
}

/**
 * Minify WGSL source code.
 * @param {string} source - WGSL source code
 * @param {Object} [options] - Minification options
 * @returns {Object} Result with code, errors, originalSize, minifiedSize
 */
export function minify(source, options) {
  if (!_initialized) {
    throw new Error('wgslender not initialized. Call initialize() first.');
  }

  if (typeof source !== 'string') {
    throw new TypeError('source must be a string');
  }

  const opts = Object.assign({
    minifyWhitespace: true,
    minifyIdentifiers: true,
    minifySyntax: true,
    treeShaking: true,
    mangleExternalBindings: false,
    preserveUniformStructTypes: false,
  }, options);

  const src = _writeString(source);
  const optsJson = _writeString(JSON.stringify(opts));

  const resultPtr = _wasm.wgslender_minify_json(src.ptr, src.len, optsJson.ptr, optsJson.len);
  _wasm.wgslender_dealloc(src.ptr, src.allocLen);
  _wasm.wgslender_dealloc(optsJson.ptr, optsJson.allocLen);

  if (!resultPtr) {
    throw new Error('Minification failed: WASM returned null');
  }

  return _readResultJson(resultPtr);
}

/**
 * Reflect WGSL source to extract binding and struct information.
 * @param {string} source - WGSL source code
 * @returns {Object} Reflection result with bindings, structs, entryPoints, and errors
 */
export function reflect(source) {
  if (!_initialized) {
    throw new Error('wgslender not initialized. Call initialize() first.');
  }

  if (typeof source !== 'string') {
    throw new TypeError('source must be a string');
  }

  const src = _writeString(source);
  const resultPtr = _wasm.wgslender_reflect(src.ptr, src.len);
  _wasm.wgslender_dealloc(src.ptr, src.allocLen);

  if (!resultPtr) {
    throw new Error('Reflection failed: WASM returned null');
  }

  return _readResultJson(resultPtr);
}

/**
 * Validate WGSL source code.
 * @param {string} source - WGSL source code
 * @param {Object} [options] - Validation options
 * @returns {Object} Validation result with valid, diagnostics, errorCount, warningCount
 */
export function validate(source, options) {
  if (!_initialized) {
    throw new Error('wgslender not initialized. Call initialize() first.');
  }

  if (typeof source !== 'string') {
    throw new TypeError('source must be a string');
  }

  const src = _writeString(source);
  const resultPtr = _wasm.wgslender_validate(src.ptr, src.len);
  _wasm.wgslender_dealloc(src.ptr, src.allocLen);

  if (!resultPtr) {
    throw new Error('Validation failed: WASM returned null');
  }

  const view = new DataView(_wasm.memory.buffer);
  const valid = view.getUint32(resultPtr, true) === 1;
  const errorCount = view.getUint32(resultPtr + 4, true);
  const jsonLen = view.getUint32(resultPtr + 8, true);
  const diagnostics = JSON.parse(
    _decoder.decode(new Uint8Array(_wasm.memory.buffer, resultPtr + 12, jsonLen))
  );
  _wasm.wgslender_dealloc(resultPtr, 12 + jsonLen);

  let warningCount = 0;
  for (const d of diagnostics) {
    if (d.severity === 'warning') warningCount++;
  }

  return { valid, diagnostics, errorCount, warningCount };
}

/**
 * Check if initialized.
 * @returns {boolean}
 */
export function isInitialized() {
  return _initialized;
}

/**
 * Get version.
 * @returns {string}
 */
function getVersion() {
  if (!_initialized) {
    return 'unknown';
  }
  const len = _wasm.wgslender_version_len();
  const ptr = _wasm.wgslender_version();
  return _decoder.decode(new Uint8Array(_wasm.memory.buffer, ptr, len));
}

export const version = { toString: getVersion, valueOf: getVersion };

export default { initialize, minify, reflect, validate, isInitialized, version };
