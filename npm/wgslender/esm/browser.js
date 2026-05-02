/**
 * wgslender - WGSL Minifier for WebGPU Shaders (Browser ESM Build)
 *
 * Usage:
 *   import { initialize, minify } from 'wgslender'
 *   await initialize({ wasmURL: '/wgslender.wasm' })
 *   const result = minify(source, { minifyWhitespace: true })
 */

let _initialized = false;
let _initPromise = null;
let _wasm = null;

const _encoder = new TextEncoder();
const _decoder = new TextDecoder();

/**
 * Initialize the WASM module.
 * @param {Object} options
 * @param {string|URL} [options.wasmURL] - URL to wgslender.wasm
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
  const wasmURL = options.wasmURL;
  const wasmModule = options.wasmModule;

  if (!wasmURL && !wasmModule) {
    throw new Error('Must provide either wasmURL or wasmModule');
  }

  _initPromise = _doInitialize(wasmURL, wasmModule);

  try {
    await _initPromise;
    _initialized = true;
  } catch (err) {
    _initPromise = null;
    throw err;
  }
}

async function _doInitialize(wasmURL, wasmModule) {
  if (wasmModule) {
    const instance = await WebAssembly.instantiate(wasmModule, {});
    _wasm = instance.exports;
    return;
  }

  const url = wasmURL instanceof URL ? wasmURL.href : wasmURL;

  if (typeof WebAssembly.instantiateStreaming === 'function') {
    try {
      const response = await fetch(url);
      if (!response.ok) {
        throw new Error(`Failed to fetch ${url}: ${response.status}`);
      }
      const result = await WebAssembly.instantiateStreaming(response, {});
      _wasm = result.instance.exports;
      return;
    } catch (err) {
      if (err.message && err.message.includes('MIME')) {
        const response = await fetch(url);
        const bytes = await response.arrayBuffer();
        const result = await WebAssembly.instantiate(bytes, {});
        _wasm = result.instance.exports;
        return;
      }
      throw err;
    }
  }

  const response = await fetch(url);
  const bytes = await response.arrayBuffer();
  const result = await WebAssembly.instantiate(bytes, {});
  _wasm = result.instance.exports;
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
 * Compile WGSL source to a binary `.wasm` shader.
 * @param {string} source - WGSL source code
 * @param {Object} [options] - Forwarded to the minifier pass.
 * @returns {{wasm: Uint8Array, originalSize: number, wasmSize: number, errors: Array<{message: string}>}}
 */
export function compile(source, options) {
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
    sortDeclarations: true,
    scopeLocalRename: true,
  }, options);

  const src = _writeString(source);
  const optsJson = _writeString(JSON.stringify(opts));
  const resultPtr = _wasm.wgslender_compile(src.ptr, src.len, optsJson.ptr, optsJson.len);
  _wasm.wgslender_dealloc(src.ptr, src.allocLen);
  _wasm.wgslender_dealloc(optsJson.ptr, optsJson.allocLen);

  if (!resultPtr) throw new Error('Compile failed: WASM returned null');

  const view = new DataView(_wasm.memory.buffer);
  const wasmLen = view.getUint32(resultPtr, true);
  const originalSize = view.getUint32(resultPtr + 4, true);
  const errorsLen = view.getUint32(resultPtr + 8, true);
  const wasm = new Uint8Array(
    new Uint8Array(_wasm.memory.buffer, resultPtr + 12, wasmLen)
  );
  const errors = JSON.parse(
    _decoder.decode(new Uint8Array(_wasm.memory.buffer, resultPtr + 12 + wasmLen, errorsLen))
  );
  _wasm.wgslender_dealloc(resultPtr, 12 + wasmLen + errorsLen);

  return { wasm, originalSize, wasmSize: wasmLen, errors };
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
 * Find all references to the symbol under `offset`.
 */
export function findReferences(source, offset, includeDeclaration) {
  if (!_initialized) throw new Error('wgslender not initialized. Call initialize() first.');
  if (typeof source !== 'string') throw new TypeError('source must be a string');
  if (!Number.isFinite(offset) || offset < 0) throw new TypeError('offset must be a non-negative number');
  const includeDecl = includeDeclaration !== false;
  const src = _writeString(source);
  const resultPtr = _wasm.wgslender_find_references(src.ptr, src.len, offset >>> 0, includeDecl ? 1 : 0);
  _wasm.wgslender_dealloc(src.ptr, src.allocLen);
  if (!resultPtr) throw new Error('findReferences failed: WASM returned null');
  return _readResultJson(resultPtr);
}

/**
 * Compute text edits to rename the symbol at `offset` to `newName`.
 */
export function rename(source, offset, newName) {
  if (!_initialized) throw new Error('wgslender not initialized. Call initialize() first.');
  if (typeof source !== 'string') throw new TypeError('source must be a string');
  if (typeof newName !== 'string') throw new TypeError('newName must be a string');
  if (!Number.isFinite(offset) || offset < 0) throw new TypeError('offset must be a non-negative number');
  const src = _writeString(source);
  const name = _writeString(newName);
  const resultPtr = _wasm.wgslender_rename(src.ptr, src.len, offset >>> 0, name.ptr, name.len);
  _wasm.wgslender_dealloc(src.ptr, src.allocLen);
  _wasm.wgslender_dealloc(name.ptr, name.allocLen);
  if (!resultPtr) throw new Error('rename failed: WASM returned null');
  return _readResultJson(resultPtr);
}

/**
 * Rename-and-apply: returns rewritten source and edits.
 */
export function renameApply(source, offset, newName) {
  if (!_initialized) throw new Error('wgslender not initialized. Call initialize() first.');
  if (typeof source !== 'string') throw new TypeError('source must be a string');
  if (typeof newName !== 'string') throw new TypeError('newName must be a string');
  if (!Number.isFinite(offset) || offset < 0) throw new TypeError('offset must be a non-negative number');
  const src = _writeString(source);
  const name = _writeString(newName);
  const resultPtr = _wasm.wgslender_rename_apply(src.ptr, src.len, offset >>> 0, name.ptr, name.len);
  _wasm.wgslender_dealloc(src.ptr, src.allocLen);
  _wasm.wgslender_dealloc(name.ptr, name.allocLen);
  if (!resultPtr) throw new Error('renameApply failed: WASM returned null');
  return _readResultJson(resultPtr);
}

/**
 * Check if initialized.
 * @returns {boolean}
 */
export function isInitialized() {
  return _initialized;
}

function getVersion() {
  if (!_initialized) {
    return 'unknown';
  }
  const len = _wasm.wgslender_version_len();
  const ptr = _wasm.wgslender_version();
  return _decoder.decode(new Uint8Array(_wasm.memory.buffer, ptr, len));
}

export const version = { toString: getVersion, valueOf: getVersion };

/**
 * Pivot a `ReflectResult.bindings[]` array into a `[group][binding]`
 * grid keyed by integer `@group(g)` / `@binding(b)`. Holes (gaps in
 * the binding number sequence) are left undefined; consumers that
 * treat the result like a dense WebGPU bind-group layout should
 * iterate with `Object.entries` rather than `for (let i ...)`.
 *
 * Pure helper — no WASM dependency. Accepts either `BindingInfo[]`
 * directly or a full `ReflectResult` (in which case `bindings[]` is
 * the source).
 *
 * @param {Object|Array} bindingsOrResult `ReflectResult` or `bindings[]`
 * @returns {Record<number, Record<number, Object>>}
 */
export function getBindGroups(bindingsOrResult) {
  const bindings = Array.isArray(bindingsOrResult)
    ? bindingsOrResult
    : (bindingsOrResult && bindingsOrResult.bindings) || [];
  const out = {};
  for (const b of bindings) {
    if (!out[b.group]) out[b.group] = {};
    out[b.group][b.binding] = b;
  }
  return out;
}

export default { initialize, minify, compile, reflect, validate, findReferences, rename, renameApply, isInitialized, version, getBindGroups };
