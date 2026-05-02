/**
 * wgslender - WGSL Minifier for WebGPU Shaders (Node.js Build)
 *
 * Usage:
 *   const { initialize, minify } = require('wgslender')
 *   await initialize()
 *   const result = minify(source, { minifyWhitespace: true })
 */

'use strict';

const fs = require('fs');
const path = require('path');

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
async function initialize(options) {
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
  _wasm = instance.exports;
}

function _writeString(s) {
  const encoded = _encoder.encode(s);
  if (encoded.length === 0) {
    // Allocate 1 byte so we get a valid pointer, but pass len=0
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
function minify(source, options) {
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
  // Re-read buffer after WASM call (may have grown)
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
function reflect(source) {
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
 * Compile WGSL source to a binary `.wasm` shader.
 * @param {string} source - WGSL source code
 * @param {Object} [options] - Forwarded as JSON to the minifier (same shape
 *   as `minify()` options). The compile pipeline always runs the minifier
 *   pass; pass `{}` for defaults.
 * @returns {{wasm: Uint8Array, originalSize: number, wasmSize: number, errors: Array<{message: string}>}}
 */
function compile(source, options) {
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
 * Validate WGSL source code.
 * @param {string} source - WGSL source code
 * @param {Object} [options] - Validation options (currently unused in Zig backend)
 * @returns {Object} Validation result with valid, diagnostics, errorCount, warningCount
 */
function validate(source, options) {
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

  // Read [u32 valid][u32 error_count][u32 json_len][json]
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
 * Lint WGSL source with a rule-pack config.
 * @param {string} source - WGSL source code
 * @param {Object} [options] - Lint config
 * @param {string[]} [options.extends] - Shareable config names, e.g. ['@wgslender/recommended']
 * @param {Object<string, string|[string, Object]>} [options.rules] - Per-rule overrides.
 *   Value is either a severity string ('off'|'warn'|'error') or a `[severity, optionsObj]` tuple.
 * @param {boolean} [options.reportUnusedDisableDirectives=false]
 * @returns {{diagnostics: Array, errorCount: number, warningCount: number}}
 */
function lint(source, options) {
  if (!_initialized) throw new Error('wgslender not initialized. Call initialize() first.');
  if (typeof source !== 'string') throw new TypeError('source must be a string');

  const config = _buildLintConfig(options);
  const src = _writeString(source);
  const cfg = _writeString(config);
  const resultPtr = _wasm.wgslender_lint(src.ptr, src.len, cfg.ptr, cfg.len);
  _wasm.wgslender_dealloc(src.ptr, src.allocLen);
  _wasm.wgslender_dealloc(cfg.ptr, cfg.allocLen);
  if (!resultPtr) throw new Error('Lint failed: WASM returned null');

  const view = new DataView(_wasm.memory.buffer);
  const errorCount = view.getUint32(resultPtr, true);
  const warningCount = view.getUint32(resultPtr + 4, true);
  const jsonLen = view.getUint32(resultPtr + 8, true);
  const diagnostics = JSON.parse(
    _decoder.decode(new Uint8Array(_wasm.memory.buffer, resultPtr + 12, jsonLen))
  );
  _wasm.wgslender_dealloc(resultPtr, 12 + jsonLen);

  return { diagnostics, errorCount, warningCount };
}

/**
 * Lint and apply autofixes in a single call.
 * @param {string} source - WGSL source code
 * @param {Object} [options] - Lint config (same shape as lint())
 * @returns {{fixed: string, diagnostics: Array, errorCount: number, warningCount: number}}
 */
function lintAndFix(source, options) {
  if (!_initialized) throw new Error('wgslender not initialized. Call initialize() first.');
  if (typeof source !== 'string') throw new TypeError('source must be a string');

  const config = _buildLintConfig(options);
  const src = _writeString(source);
  const cfg = _writeString(config);
  const resultPtr = _wasm.wgslender_lint_fix(src.ptr, src.len, cfg.ptr, cfg.len);
  _wasm.wgslender_dealloc(src.ptr, src.allocLen);
  _wasm.wgslender_dealloc(cfg.ptr, cfg.allocLen);
  if (!resultPtr) throw new Error('Lint fix failed: WASM returned null');

  const view = new DataView(_wasm.memory.buffer);
  const fixedLen = view.getUint32(resultPtr, true);
  const errorCount = view.getUint32(resultPtr + 4, true);
  const warningCount = view.getUint32(resultPtr + 8, true);
  const jsonLen = view.getUint32(resultPtr + 12, true);
  const fixed = _decoder.decode(
    new Uint8Array(_wasm.memory.buffer, resultPtr + 16, fixedLen)
  );
  const diagnostics = JSON.parse(
    _decoder.decode(new Uint8Array(_wasm.memory.buffer, resultPtr + 16 + fixedLen, jsonLen))
  );
  _wasm.wgslender_dealloc(resultPtr, 16 + fixedLen + jsonLen);

  return { fixed, diagnostics, errorCount, warningCount };
}

function _buildLintConfig(options) {
  if (!options) return '';
  const out = {};
  if (options.extends) out.extends = options.extends;
  if (options.rules) out.rules = options.rules;
  if (options.reportUnusedDisableDirectives)
    out.reportUnusedDisableDirectives = true;
  return JSON.stringify(out);
}

/**
 * Find all references to the symbol under `offset` (byte offset in `source`).
 * @param {string} source - WGSL source code
 * @param {number} offset - Byte offset where to resolve the symbol
 * @param {boolean} [includeDeclaration=true] - Whether to include the declaration site
 * @returns {{references: Array<{start:number,end:number,isWrite:boolean}>, error?: string}}
 */
function findReferences(source, offset, includeDeclaration) {
  if (!_initialized) {
    throw new Error('wgslender not initialized. Call initialize() first.');
  }
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
 * Compute text edits to rename the symbol under `offset` to `newName`.
 * Returns `{edits: []}` with a populated `error` field on failure.
 * @param {string} source - WGSL source code
 * @param {number} offset - Byte offset where to resolve the symbol
 * @param {string} newName - The new identifier name
 * @returns {{edits: Array<{start:number,end:number,newText:string}>, error?: string}}
 */
function rename(source, offset, newName) {
  if (!_initialized) {
    throw new Error('wgslender not initialized. Call initialize() first.');
  }
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
 * Rename-and-apply: produces the rewritten source plus the edits.
 * `source` is always present in the result (original text on failure).
 * @param {string} source - WGSL source code
 * @param {number} offset - Byte offset where to resolve the symbol
 * @param {string} newName - The new identifier name
 * @returns {{ok: boolean, source: string, edits: Array, error?: string}}
 */
function renameApply(source, offset, newName) {
  if (!_initialized) {
    throw new Error('wgslender not initialized. Call initialize() first.');
  }
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
 * Compute the reparse-stable ID for the symbol under `offset`.
 * @param {string} source - WGSL source code
 * @param {number} offset - Byte offset
 * @returns {{stableId: string|null, error?: string}}
 */
function stableIdAtOffset(source, offset) {
  if (!_initialized) {
    throw new Error('wgslender not initialized. Call initialize() first.');
  }
  if (typeof source !== 'string') throw new TypeError('source must be a string');
  if (!Number.isFinite(offset) || offset < 0) throw new TypeError('offset must be a non-negative number');

  const src = _writeString(source);
  const resultPtr = _wasm.wgslender_stable_id_at_offset(src.ptr, src.len, offset >>> 0);
  _wasm.wgslender_dealloc(src.ptr, src.allocLen);

  if (!resultPtr) throw new Error('stableIdAtOffset failed: WASM returned null');
  return _readResultJson(resultPtr);
}

/**
 * Resolve a stable ID to the declaration byte range in `source`.
 * @param {string} source - WGSL source code
 * @param {string} stableId - Stable identifier as returned by stableIdAtOffset
 * @returns {{start: number|null, end: number|null, error?: string}}
 */
function locateStableId(source, stableId) {
  if (!_initialized) {
    throw new Error('wgslender not initialized. Call initialize() first.');
  }
  if (typeof source !== 'string') throw new TypeError('source must be a string');
  if (typeof stableId !== 'string') throw new TypeError('stableId must be a string');

  const src = _writeString(source);
  const id = _writeString(stableId);
  const resultPtr = _wasm.wgslender_locate_stable_id(src.ptr, src.len, id.ptr, id.len);
  _wasm.wgslender_dealloc(src.ptr, src.allocLen);
  _wasm.wgslender_dealloc(id.ptr, id.allocLen);

  if (!resultPtr) throw new Error('locateStableId failed: WASM returned null');
  return _readResultJson(resultPtr);
}

/**
 * Rename the symbol identified by stable ID. Same shape as `rename`.
 * @param {string} source - WGSL source code
 * @param {string} stableId - Stable identifier
 * @param {string} newName - The new identifier name
 * @returns {{edits: Array<{start:number,end:number,newText:string}>, error?: string}}
 */
function renameByStableId(source, stableId, newName) {
  if (!_initialized) {
    throw new Error('wgslender not initialized. Call initialize() first.');
  }
  if (typeof source !== 'string') throw new TypeError('source must be a string');
  if (typeof stableId !== 'string') throw new TypeError('stableId must be a string');
  if (typeof newName !== 'string') throw new TypeError('newName must be a string');

  const src = _writeString(source);
  const id = _writeString(stableId);
  const name = _writeString(newName);
  const resultPtr = _wasm.wgslender_rename_by_id(
    src.ptr, src.len,
    id.ptr, id.len,
    name.ptr, name.len,
  );
  _wasm.wgslender_dealloc(src.ptr, src.allocLen);
  _wasm.wgslender_dealloc(id.ptr, id.allocLen);
  _wasm.wgslender_dealloc(name.ptr, name.allocLen);

  if (!resultPtr) throw new Error('renameByStableId failed: WASM returned null');
  return _readResultJson(resultPtr);
}

/**
 * Resolve a stable ID to the full declaration span (attributes through `;`/`}`).
 * @param {string} source - WGSL source code
 * @param {string} stableId - Stable identifier
 * @returns {{start: number|null, end: number|null, error?: string}}
 */
function locateDeclaration(source, stableId) {
  if (!_initialized) {
    throw new Error('wgslender not initialized. Call initialize() first.');
  }
  if (typeof source !== 'string') throw new TypeError('source must be a string');
  if (typeof stableId !== 'string') throw new TypeError('stableId must be a string');

  const src = _writeString(source);
  const id = _writeString(stableId);
  const resultPtr = _wasm.wgslender_locate_declaration(src.ptr, src.len, id.ptr, id.len);
  _wasm.wgslender_dealloc(src.ptr, src.allocLen);
  _wasm.wgslender_dealloc(id.ptr, id.allocLen);

  if (!resultPtr) throw new Error('locateDeclaration failed: WASM returned null');
  return _readResultJson(resultPtr);
}

/**
 * Resolve a stable ID to the type-annotation span (struct members,
 * parameters, return types, explicit `: T` on var/const/let/override).
 * @param {string} source - WGSL source code
 * @param {string} stableId - Stable identifier
 * @returns {{start: number|null, end: number|null, error?: string}}
 */
function locateType(source, stableId) {
  if (!_initialized) {
    throw new Error('wgslender not initialized. Call initialize() first.');
  }
  if (typeof source !== 'string') throw new TypeError('source must be a string');
  if (typeof stableId !== 'string') throw new TypeError('stableId must be a string');

  const src = _writeString(source);
  const id = _writeString(stableId);
  const resultPtr = _wasm.wgslender_locate_type(src.ptr, src.len, id.ptr, id.len);
  _wasm.wgslender_dealloc(src.ptr, src.allocLen);
  _wasm.wgslender_dealloc(id.ptr, id.allocLen);

  if (!resultPtr) throw new Error('locateType failed: WASM returned null');
  return _readResultJson(resultPtr);
}

/**
 * Remove a whole declaration by stable ID. Returns a list of edits
 * deleting the full syntactic span.
 * @param {string} source
 * @param {string} stableId
 * @returns {{edits: Array<{start:number,end:number,newText:string}>, error?: string}}
 */
function removeDeclarationByStableId(source, stableId) {
  if (!_initialized) {
    throw new Error('wgslender not initialized. Call initialize() first.');
  }
  if (typeof source !== 'string') throw new TypeError('source must be a string');
  if (typeof stableId !== 'string') throw new TypeError('stableId must be a string');

  const src = _writeString(source);
  const id = _writeString(stableId);
  const resultPtr = _wasm.wgslender_remove_declaration_by_id(src.ptr, src.len, id.ptr, id.len);
  _wasm.wgslender_dealloc(src.ptr, src.allocLen);
  _wasm.wgslender_dealloc(id.ptr, id.allocLen);

  if (!resultPtr) throw new Error('removeDeclarationByStableId failed: WASM returned null');
  return _readResultJson(resultPtr);
}

/**
 * Remove-and-apply by stable ID. Returns the rewritten source plus edits.
 * @param {string} source
 * @param {string} stableId
 * @returns {{ok: boolean, source: string, edits: Array<{start:number,end:number,newText:string}>, error?: string}}
 */
function removeDeclarationApplyByStableId(source, stableId) {
  if (!_initialized) {
    throw new Error('wgslender not initialized. Call initialize() first.');
  }
  if (typeof source !== 'string') throw new TypeError('source must be a string');
  if (typeof stableId !== 'string') throw new TypeError('stableId must be a string');

  const src = _writeString(source);
  const id = _writeString(stableId);
  const resultPtr = _wasm.wgslender_remove_declaration_apply_by_id(src.ptr, src.len, id.ptr, id.len);
  _wasm.wgslender_dealloc(src.ptr, src.allocLen);
  _wasm.wgslender_dealloc(id.ptr, id.allocLen);

  if (!resultPtr) throw new Error('removeDeclarationApplyByStableId failed: WASM returned null');
  return _readResultJson(resultPtr);
}

/**
 * Change the type annotation of the symbol identified by stable ID.
 * Works for struct members, parameters, return types, and
 * var/const/let/override with an explicit `: T`.
 * @param {string} source
 * @param {string} stableId
 * @param {string} newType - Replacement WGSL type (e.g. `"vec3<f32>"`)
 * @returns {{edits: Array<{start:number,end:number,newText:string}>, error?: string}}
 */
function changeTypeByStableId(source, stableId, newType) {
  if (!_initialized) {
    throw new Error('wgslender not initialized. Call initialize() first.');
  }
  if (typeof source !== 'string') throw new TypeError('source must be a string');
  if (typeof stableId !== 'string') throw new TypeError('stableId must be a string');
  if (typeof newType !== 'string') throw new TypeError('newType must be a string');

  const src = _writeString(source);
  const id = _writeString(stableId);
  const type_ = _writeString(newType);
  const resultPtr = _wasm.wgslender_change_type_by_id(
    src.ptr, src.len,
    id.ptr, id.len,
    type_.ptr, type_.len,
  );
  _wasm.wgslender_dealloc(src.ptr, src.allocLen);
  _wasm.wgslender_dealloc(id.ptr, id.allocLen);
  _wasm.wgslender_dealloc(type_.ptr, type_.allocLen);

  if (!resultPtr) throw new Error('changeTypeByStableId failed: WASM returned null');
  return _readResultJson(resultPtr);
}

/**
 * Change-type-and-apply by stable ID.
 * @param {string} source
 * @param {string} stableId
 * @param {string} newType
 * @returns {{ok: boolean, source: string, edits: Array<{start:number,end:number,newText:string}>, error?: string}}
 */
function changeTypeApplyByStableId(source, stableId, newType) {
  if (!_initialized) {
    throw new Error('wgslender not initialized. Call initialize() first.');
  }
  if (typeof source !== 'string') throw new TypeError('source must be a string');
  if (typeof stableId !== 'string') throw new TypeError('stableId must be a string');
  if (typeof newType !== 'string') throw new TypeError('newType must be a string');

  const src = _writeString(source);
  const id = _writeString(stableId);
  const type_ = _writeString(newType);
  const resultPtr = _wasm.wgslender_change_type_apply_by_id(
    src.ptr, src.len,
    id.ptr, id.len,
    type_.ptr, type_.len,
  );
  _wasm.wgslender_dealloc(src.ptr, src.allocLen);
  _wasm.wgslender_dealloc(id.ptr, id.allocLen);
  _wasm.wgslender_dealloc(type_.ptr, type_.allocLen);

  if (!resultPtr) throw new Error('changeTypeApplyByStableId failed: WASM returned null');
  return _readResultJson(resultPtr);
}

/**
 * Check if initialized.
 * @returns {boolean}
 */
function isInitialized() {
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

function getBindGroups(bindingsOrResult) {
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

module.exports = {
  initialize,
  minify,
  compile,
  reflect,
  getBindGroups,
  validate,
  lint,
  lintAndFix,
  findReferences,
  rename,
  renameApply,
  stableIdAtOffset,
  locateStableId,
  locateDeclaration,
  locateType,
  renameByStableId,
  removeDeclarationByStableId,
  removeDeclarationApplyByStableId,
  changeTypeByStableId,
  changeTypeApplyByStableId,
  isInitialized,
  get version() { return getVersion(); }
};
