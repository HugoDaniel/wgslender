/**
 * wgslender - WGSL Minifier for WebGPU Shaders (Browser Build)
 *
 * Usage:
 *   import { initialize, minify } from 'wgslender'
 *   await initialize({ wasmURL: '/wgslender.wasm' })
 *   const result = minify(source, { minifyWhitespace: true })
 */

(function (root, factory) {
  if (typeof define === 'function' && define.amd) {
    define([], factory);
  } else if (typeof module === 'object' && module.exports) {
    module.exports = factory();
  } else {
    root.wgslender = factory();
  }
}(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

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
  async function initialize(options) {
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
          throw new Error('Failed to fetch ' + url + ': ' + response.status);
        }
        const result = await WebAssembly.instantiateStreaming(response, {});
        _wasm = result.instance.exports;
        return;
      } catch (err) {
        // Fall back to arrayBuffer if streaming fails (e.g., wrong MIME type)
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

    // Fallback for older browsers
    const response = await fetch(url);
    const bytes = await response.arrayBuffer();
    const result = await WebAssembly.instantiate(bytes, {});
    _wasm = result.instance.exports;
  }

  function _writeString(s) {
    var encoded = _encoder.encode(s);
    if (encoded.length === 0) {
      var ptr = _wasm.wgslender_alloc(1);
      if (!ptr) throw new Error('WASM allocation failed');
      return { ptr: ptr, len: 0, allocLen: 1 };
    }
    var ptr = _wasm.wgslender_alloc(encoded.length);
    if (!ptr) throw new Error('WASM allocation failed');
    new Uint8Array(_wasm.memory.buffer, ptr, encoded.length).set(encoded);
    return { ptr: ptr, len: encoded.length, allocLen: encoded.length };
  }

  function _readResultJson(ptr) {
    var view = new DataView(_wasm.memory.buffer);
    var jsonLen = view.getUint32(ptr, true);
    var json = _decoder.decode(new Uint8Array(_wasm.memory.buffer, ptr + 4, jsonLen));
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

    var opts = Object.assign({
      minifyWhitespace: true,
      minifyIdentifiers: true,
      minifySyntax: true,
      treeShaking: true,
      mangleExternalBindings: false,
      preserveUniformStructTypes: false,
    }, options);

    var src = _writeString(source);
    var optsJson = _writeString(JSON.stringify(opts));

    var resultPtr = _wasm.wgslender_minify_json(src.ptr, src.len, optsJson.ptr, optsJson.len);
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

    var src = _writeString(source);
    var resultPtr = _wasm.wgslender_reflect(src.ptr, src.len);
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
  function validate(source, options) {
    if (!_initialized) {
      throw new Error('wgslender not initialized. Call initialize() first.');
    }

    if (typeof source !== 'string') {
      throw new TypeError('source must be a string');
    }

    var src = _writeString(source);
    var resultPtr = _wasm.wgslender_validate(src.ptr, src.len);
    _wasm.wgslender_dealloc(src.ptr, src.allocLen);

    if (!resultPtr) {
      throw new Error('Validation failed: WASM returned null');
    }

    var view = new DataView(_wasm.memory.buffer);
    var valid = view.getUint32(resultPtr, true) === 1;
    var errorCount = view.getUint32(resultPtr + 4, true);
    var jsonLen = view.getUint32(resultPtr + 8, true);
    var diagnostics = JSON.parse(
      _decoder.decode(new Uint8Array(_wasm.memory.buffer, resultPtr + 12, jsonLen))
    );
    _wasm.wgslender_dealloc(resultPtr, 12 + jsonLen);

    var warningCount = 0;
    for (var i = 0; i < diagnostics.length; i++) {
      if (diagnostics[i].severity === 'warning') warningCount++;
    }

    return { valid: valid, diagnostics: diagnostics, errorCount: errorCount, warningCount: warningCount };
  }

  /**
   * Find all references to the symbol under `offset`.
   */
  function findReferences(source, offset, includeDeclaration) {
    if (!_initialized) throw new Error('wgslender not initialized. Call initialize() first.');
    if (typeof source !== 'string') throw new TypeError('source must be a string');
    if (!Number.isFinite(offset) || offset < 0) throw new TypeError('offset must be a non-negative number');
    var includeDecl = includeDeclaration !== false;
    var src = _writeString(source);
    var resultPtr = _wasm.wgslender_find_references(src.ptr, src.len, offset >>> 0, includeDecl ? 1 : 0);
    _wasm.wgslender_dealloc(src.ptr, src.allocLen);
    if (!resultPtr) throw new Error('findReferences failed: WASM returned null');
    return _readResultJson(resultPtr);
  }

  /**
   * Compute text edits to rename the symbol at `offset` to `newName`.
   */
  function rename(source, offset, newName) {
    if (!_initialized) throw new Error('wgslender not initialized. Call initialize() first.');
    if (typeof source !== 'string') throw new TypeError('source must be a string');
    if (typeof newName !== 'string') throw new TypeError('newName must be a string');
    if (!Number.isFinite(offset) || offset < 0) throw new TypeError('offset must be a non-negative number');
    var src = _writeString(source);
    var name = _writeString(newName);
    var resultPtr = _wasm.wgslender_rename(src.ptr, src.len, offset >>> 0, name.ptr, name.len);
    _wasm.wgslender_dealloc(src.ptr, src.allocLen);
    _wasm.wgslender_dealloc(name.ptr, name.allocLen);
    if (!resultPtr) throw new Error('rename failed: WASM returned null');
    return _readResultJson(resultPtr);
  }

  /**
   * Rename-and-apply: returns rewritten source and edits.
   */
  function renameApply(source, offset, newName) {
    if (!_initialized) throw new Error('wgslender not initialized. Call initialize() first.');
    if (typeof source !== 'string') throw new TypeError('source must be a string');
    if (typeof newName !== 'string') throw new TypeError('newName must be a string');
    if (!Number.isFinite(offset) || offset < 0) throw new TypeError('offset must be a non-negative number');
    var src = _writeString(source);
    var name = _writeString(newName);
    var resultPtr = _wasm.wgslender_rename_apply(src.ptr, src.len, offset >>> 0, name.ptr, name.len);
    _wasm.wgslender_dealloc(src.ptr, src.allocLen);
    _wasm.wgslender_dealloc(name.ptr, name.allocLen);
    if (!resultPtr) throw new Error('renameApply failed: WASM returned null');
    return _readResultJson(resultPtr);
  }

  /**
   * Reparse-stable ID for the symbol under `offset`.
   */
  function stableIdAtOffset(source, offset) {
    if (!_initialized) throw new Error('wgslender not initialized. Call initialize() first.');
    if (typeof source !== 'string') throw new TypeError('source must be a string');
    if (!Number.isFinite(offset) || offset < 0) throw new TypeError('offset must be a non-negative number');
    var src = _writeString(source);
    var resultPtr = _wasm.wgslender_stable_id_at_offset(src.ptr, src.len, offset >>> 0);
    _wasm.wgslender_dealloc(src.ptr, src.allocLen);
    if (!resultPtr) throw new Error('stableIdAtOffset failed: WASM returned null');
    return _readResultJson(resultPtr);
  }

  /**
   * Resolve a stable ID to its declaration byte range.
   */
  function locateStableId(source, stableId) {
    if (!_initialized) throw new Error('wgslender not initialized. Call initialize() first.');
    if (typeof source !== 'string') throw new TypeError('source must be a string');
    if (typeof stableId !== 'string') throw new TypeError('stableId must be a string');
    var src = _writeString(source);
    var id = _writeString(stableId);
    var resultPtr = _wasm.wgslender_locate_stable_id(src.ptr, src.len, id.ptr, id.len);
    _wasm.wgslender_dealloc(src.ptr, src.allocLen);
    _wasm.wgslender_dealloc(id.ptr, id.allocLen);
    if (!resultPtr) throw new Error('locateStableId failed: WASM returned null');
    return _readResultJson(resultPtr);
  }

  /**
   * Rename a symbol identified by stable ID.
   */
  function renameByStableId(source, stableId, newName) {
    if (!_initialized) throw new Error('wgslender not initialized. Call initialize() first.');
    if (typeof source !== 'string') throw new TypeError('source must be a string');
    if (typeof stableId !== 'string') throw new TypeError('stableId must be a string');
    if (typeof newName !== 'string') throw new TypeError('newName must be a string');
    var src = _writeString(source);
    var id = _writeString(stableId);
    var name = _writeString(newName);
    var resultPtr = _wasm.wgslender_rename_by_id(
      src.ptr, src.len,
      id.ptr, id.len,
      name.ptr, name.len
    );
    _wasm.wgslender_dealloc(src.ptr, src.allocLen);
    _wasm.wgslender_dealloc(id.ptr, id.allocLen);
    _wasm.wgslender_dealloc(name.ptr, name.allocLen);
    if (!resultPtr) throw new Error('renameByStableId failed: WASM returned null');
    return _readResultJson(resultPtr);
  }

  /**
   * Resolve a stable ID to the full declaration span.
   */
  function locateDeclaration(source, stableId) {
    if (!_initialized) throw new Error('wgslender not initialized. Call initialize() first.');
    if (typeof source !== 'string') throw new TypeError('source must be a string');
    if (typeof stableId !== 'string') throw new TypeError('stableId must be a string');
    var src = _writeString(source);
    var id = _writeString(stableId);
    var resultPtr = _wasm.wgslender_locate_declaration(src.ptr, src.len, id.ptr, id.len);
    _wasm.wgslender_dealloc(src.ptr, src.allocLen);
    _wasm.wgslender_dealloc(id.ptr, id.allocLen);
    if (!resultPtr) throw new Error('locateDeclaration failed: WASM returned null');
    return _readResultJson(resultPtr);
  }

  /**
   * Resolve a stable ID to the type-annotation span.
   */
  function locateType(source, stableId) {
    if (!_initialized) throw new Error('wgslender not initialized. Call initialize() first.');
    if (typeof source !== 'string') throw new TypeError('source must be a string');
    if (typeof stableId !== 'string') throw new TypeError('stableId must be a string');
    var src = _writeString(source);
    var id = _writeString(stableId);
    var resultPtr = _wasm.wgslender_locate_type(src.ptr, src.len, id.ptr, id.len);
    _wasm.wgslender_dealloc(src.ptr, src.allocLen);
    _wasm.wgslender_dealloc(id.ptr, id.allocLen);
    if (!resultPtr) throw new Error('locateType failed: WASM returned null');
    return _readResultJson(resultPtr);
  }

  /** Remove a whole declaration by stable ID. */
  function removeDeclarationByStableId(source, stableId) {
    if (!_initialized) throw new Error('wgslender not initialized. Call initialize() first.');
    if (typeof source !== 'string') throw new TypeError('source must be a string');
    if (typeof stableId !== 'string') throw new TypeError('stableId must be a string');
    var src = _writeString(source);
    var id = _writeString(stableId);
    var resultPtr = _wasm.wgslender_remove_declaration_by_id(src.ptr, src.len, id.ptr, id.len);
    _wasm.wgslender_dealloc(src.ptr, src.allocLen);
    _wasm.wgslender_dealloc(id.ptr, id.allocLen);
    if (!resultPtr) throw new Error('removeDeclarationByStableId failed: WASM returned null');
    return _readResultJson(resultPtr);
  }

  /** Remove-and-apply by stable ID. */
  function removeDeclarationApplyByStableId(source, stableId) {
    if (!_initialized) throw new Error('wgslender not initialized. Call initialize() first.');
    if (typeof source !== 'string') throw new TypeError('source must be a string');
    if (typeof stableId !== 'string') throw new TypeError('stableId must be a string');
    var src = _writeString(source);
    var id = _writeString(stableId);
    var resultPtr = _wasm.wgslender_remove_declaration_apply_by_id(src.ptr, src.len, id.ptr, id.len);
    _wasm.wgslender_dealloc(src.ptr, src.allocLen);
    _wasm.wgslender_dealloc(id.ptr, id.allocLen);
    if (!resultPtr) throw new Error('removeDeclarationApplyByStableId failed: WASM returned null');
    return _readResultJson(resultPtr);
  }

  /** Change the type annotation of a symbol identified by stable ID. */
  function changeTypeByStableId(source, stableId, newType) {
    if (!_initialized) throw new Error('wgslender not initialized. Call initialize() first.');
    if (typeof source !== 'string') throw new TypeError('source must be a string');
    if (typeof stableId !== 'string') throw new TypeError('stableId must be a string');
    if (typeof newType !== 'string') throw new TypeError('newType must be a string');
    var src = _writeString(source);
    var id = _writeString(stableId);
    var t = _writeString(newType);
    var resultPtr = _wasm.wgslender_change_type_by_id(
      src.ptr, src.len,
      id.ptr, id.len,
      t.ptr, t.len
    );
    _wasm.wgslender_dealloc(src.ptr, src.allocLen);
    _wasm.wgslender_dealloc(id.ptr, id.allocLen);
    _wasm.wgslender_dealloc(t.ptr, t.allocLen);
    if (!resultPtr) throw new Error('changeTypeByStableId failed: WASM returned null');
    return _readResultJson(resultPtr);
  }

  /** Change-type-and-apply by stable ID. */
  function changeTypeApplyByStableId(source, stableId, newType) {
    if (!_initialized) throw new Error('wgslender not initialized. Call initialize() first.');
    if (typeof source !== 'string') throw new TypeError('source must be a string');
    if (typeof stableId !== 'string') throw new TypeError('stableId must be a string');
    if (typeof newType !== 'string') throw new TypeError('newType must be a string');
    var src = _writeString(source);
    var id = _writeString(stableId);
    var t = _writeString(newType);
    var resultPtr = _wasm.wgslender_change_type_apply_by_id(
      src.ptr, src.len,
      id.ptr, id.len,
      t.ptr, t.len
    );
    _wasm.wgslender_dealloc(src.ptr, src.allocLen);
    _wasm.wgslender_dealloc(id.ptr, id.allocLen);
    _wasm.wgslender_dealloc(t.ptr, t.allocLen);
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
    var len = _wasm.wgslender_version_len();
    var ptr = _wasm.wgslender_version();
    return _decoder.decode(new Uint8Array(_wasm.memory.buffer, ptr, len));
  }

  return {
    initialize: initialize,
    minify: minify,
    reflect: reflect,
    validate: validate,
    findReferences: findReferences,
    rename: rename,
    renameApply: renameApply,
    stableIdAtOffset: stableIdAtOffset,
    locateStableId: locateStableId,
    locateDeclaration: locateDeclaration,
    locateType: locateType,
    renameByStableId: renameByStableId,
    removeDeclarationByStableId: removeDeclarationByStableId,
    removeDeclarationApplyByStableId: removeDeclarationApplyByStableId,
    changeTypeByStableId: changeTypeByStableId,
    changeTypeApplyByStableId: changeTypeApplyByStableId,
    isInitialized: isInitialized,
    get version() { return getVersion(); }
  };
}));
