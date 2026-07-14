/**
 * wgslender shared WASM-glue core.
 *
 * `createWrapper({ loadWasm })` returns a public API object closing over
 * private init/wasm state. Each entry shim (CJS Node, ESM Node, UMD
 * browser, ESM browser) supplies its own `loadWasm(options)` that returns
 * `Promise<WebAssembly.Instance['exports']>` and re-exports the result.
 *
 * Single source of truth for the WASM ABI envelope decoders — kept in
 * sync with `pack*` functions in `src/wasm.zig`.
 */

'use strict';

function createWrapper({ loadWasm }) {
  let _initialized = false;
  let _initPromise = null;
  let _wasm = null;

  const _encoder = new TextEncoder();
  const _decoder = new TextDecoder();

  async function initialize(options) {
    if (_initialized) return;
    if (_initPromise) return _initPromise;

    _initPromise = (async () => {
      _wasm = await loadWasm(options || {});
    })();

    try {
      await _initPromise;
      _initialized = true;
    } catch (err) {
      _initPromise = null;
      throw err;
    }
  }

  function _ensureInit() {
    if (!_initialized) {
      throw new Error('wgslender not initialized. Call initialize() first.');
    }
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

  function minify(source, options) {
    _ensureInit();
    if (typeof source !== 'string') throw new TypeError('source must be a string');

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

    if (!resultPtr) throw new Error('Minification failed: WASM returned null');
    return _readResultJson(resultPtr);
  }

  function reflect(source) {
    _ensureInit();
    if (typeof source !== 'string') throw new TypeError('source must be a string');

    const src = _writeString(source);
    const resultPtr = _wasm.wgslender_reflect(src.ptr, src.len);
    _wasm.wgslender_dealloc(src.ptr, src.allocLen);

    if (!resultPtr) throw new Error('Reflection failed: WASM returned null');
    return _readResultJson(resultPtr);
  }

  function compile(source, options) {
    _ensureInit();
    if (typeof source !== 'string') throw new TypeError('source must be a string');

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

    // [u32 wasm_len][u32 original_size][u32 errors_len][wasm bytes][errors json]
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

  function validate(source, options) {
    _ensureInit();
    if (typeof source !== 'string') throw new TypeError('source must be a string');

    const flags = options && options.strict ? 1 : 0;
    const src = _writeString(source);
    const resultPtr = _wasm.wgslender_validate(src.ptr, src.len, flags);
    _wasm.wgslender_dealloc(src.ptr, src.allocLen);

    if (!resultPtr) throw new Error('Validation failed: WASM returned null');

    // [u32 valid][u32 error_count][u32 warning_count][u32 json_len][json]
    const view = new DataView(_wasm.memory.buffer);
    const valid = view.getUint32(resultPtr, true) === 1;
    const errorCount = view.getUint32(resultPtr + 4, true);
    const warningCount = view.getUint32(resultPtr + 8, true);
    const jsonLen = view.getUint32(resultPtr + 12, true);
    const wrapped = JSON.parse(
      _decoder.decode(new Uint8Array(_wasm.memory.buffer, resultPtr + 16, jsonLen))
    );
    _wasm.wgslender_dealloc(resultPtr, 16 + jsonLen);

    return { valid, diagnostics: wrapped.diagnostics, errorCount, warningCount };
  }

  function _buildLintConfig(options) {
    if (!options) return '';
    const out = {};
    if (options.extends) out.extends = options.extends;
    if (options.rules) out.rules = options.rules;
    if (options.reportUnusedDisableDirectives) out.reportUnusedDisableDirectives = true;
    return JSON.stringify(out);
  }

  function lint(source, options) {
    _ensureInit();
    if (typeof source !== 'string') throw new TypeError('source must be a string');

    const config = _buildLintConfig(options);
    const src = _writeString(source);
    const cfg = _writeString(config);
    const resultPtr = _wasm.wgslender_lint(src.ptr, src.len, cfg.ptr, cfg.len);
    _wasm.wgslender_dealloc(src.ptr, src.allocLen);
    _wasm.wgslender_dealloc(cfg.ptr, cfg.allocLen);
    if (!resultPtr) throw new Error('Lint failed: WASM returned null');

    // [u32 error_count][u32 warning_count][u32 json_len][json]
    // The JSON payload is the per-file lint result object
    // { diagnostics, errorCount, warningCount, fixableCount }. errorCount /
    // warningCount are also on the struct (authoritative for the C ABI);
    // fixableCount rides only in the JSON.
    const view = new DataView(_wasm.memory.buffer);
    const errorCount = view.getUint32(resultPtr, true);
    const warningCount = view.getUint32(resultPtr + 4, true);
    const jsonLen = view.getUint32(resultPtr + 8, true);
    const parsed = JSON.parse(
      _decoder.decode(new Uint8Array(_wasm.memory.buffer, resultPtr + 12, jsonLen))
    );
    _wasm.wgslender_dealloc(resultPtr, 12 + jsonLen);

    return {
      diagnostics: parsed.diagnostics,
      errorCount,
      warningCount,
      fixableCount: parsed.fixableCount,
    };
  }

  function lintAndFix(source, options) {
    _ensureInit();
    if (typeof source !== 'string') throw new TypeError('source must be a string');

    const config = _buildLintConfig(options);
    const src = _writeString(source);
    const cfg = _writeString(config);
    const resultPtr = _wasm.wgslender_lint_fix(src.ptr, src.len, cfg.ptr, cfg.len);
    _wasm.wgslender_dealloc(src.ptr, src.allocLen);
    _wasm.wgslender_dealloc(cfg.ptr, cfg.allocLen);
    if (!resultPtr) throw new Error('Lint fix failed: WASM returned null');

    // [u32 fixed_len][u32 error_count][u32 warning_count][u32 json_len][fixed][json]
    const view = new DataView(_wasm.memory.buffer);
    const fixedLen = view.getUint32(resultPtr, true);
    const errorCount = view.getUint32(resultPtr + 4, true);
    const warningCount = view.getUint32(resultPtr + 8, true);
    const jsonLen = view.getUint32(resultPtr + 12, true);
    const fixed = _decoder.decode(
      new Uint8Array(_wasm.memory.buffer, resultPtr + 16, fixedLen)
    );
    const parsed = JSON.parse(
      _decoder.decode(new Uint8Array(_wasm.memory.buffer, resultPtr + 16 + fixedLen, jsonLen))
    );
    _wasm.wgslender_dealloc(resultPtr, 16 + fixedLen + jsonLen);

    return {
      fixed,
      diagnostics: parsed.diagnostics,
      errorCount,
      warningCount,
      fixableCount: parsed.fixableCount,
    };
  }

  function findReferences(source, offset, includeDeclaration) {
    _ensureInit();
    if (typeof source !== 'string') throw new TypeError('source must be a string');
    if (!Number.isFinite(offset) || offset < 0) {
      throw new TypeError('offset must be a non-negative number');
    }
    const includeDecl = includeDeclaration !== false;
    const src = _writeString(source);
    const resultPtr = _wasm.wgslender_find_references(src.ptr, src.len, offset >>> 0, includeDecl ? 1 : 0);
    _wasm.wgslender_dealloc(src.ptr, src.allocLen);
    if (!resultPtr) throw new Error('findReferences failed: WASM returned null');
    return _readResultJson(resultPtr);
  }

  function rename(source, offset, newName) {
    _ensureInit();
    if (typeof source !== 'string') throw new TypeError('source must be a string');
    if (typeof newName !== 'string') throw new TypeError('newName must be a string');
    if (!Number.isFinite(offset) || offset < 0) {
      throw new TypeError('offset must be a non-negative number');
    }
    const src = _writeString(source);
    const name = _writeString(newName);
    const resultPtr = _wasm.wgslender_rename(src.ptr, src.len, offset >>> 0, name.ptr, name.len);
    _wasm.wgslender_dealloc(src.ptr, src.allocLen);
    _wasm.wgslender_dealloc(name.ptr, name.allocLen);
    if (!resultPtr) throw new Error('rename failed: WASM returned null');
    return _readResultJson(resultPtr);
  }

  function renameApply(source, offset, newName) {
    _ensureInit();
    if (typeof source !== 'string') throw new TypeError('source must be a string');
    if (typeof newName !== 'string') throw new TypeError('newName must be a string');
    if (!Number.isFinite(offset) || offset < 0) {
      throw new TypeError('offset must be a non-negative number');
    }
    const src = _writeString(source);
    const name = _writeString(newName);
    const resultPtr = _wasm.wgslender_rename_apply(src.ptr, src.len, offset >>> 0, name.ptr, name.len);
    _wasm.wgslender_dealloc(src.ptr, src.allocLen);
    _wasm.wgslender_dealloc(name.ptr, name.allocLen);
    if (!resultPtr) throw new Error('renameApply failed: WASM returned null');
    return _readResultJson(resultPtr);
  }

  function stableIdAtOffset(source, offset) {
    _ensureInit();
    if (typeof source !== 'string') throw new TypeError('source must be a string');
    if (!Number.isFinite(offset) || offset < 0) {
      throw new TypeError('offset must be a non-negative number');
    }
    const src = _writeString(source);
    const resultPtr = _wasm.wgslender_stable_id_at_offset(src.ptr, src.len, offset >>> 0);
    _wasm.wgslender_dealloc(src.ptr, src.allocLen);
    if (!resultPtr) throw new Error('stableIdAtOffset failed: WASM returned null');
    return _readResultJson(resultPtr);
  }

  function locateStableId(source, stableId) {
    _ensureInit();
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

  function renameByStableId(source, stableId, newName) {
    _ensureInit();
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

  function locateDeclaration(source, stableId) {
    _ensureInit();
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

  function locateType(source, stableId) {
    _ensureInit();
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

  function removeDeclarationByStableId(source, stableId) {
    _ensureInit();
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

  function removeDeclarationApplyByStableId(source, stableId) {
    _ensureInit();
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

  function changeTypeByStableId(source, stableId, newType) {
    _ensureInit();
    if (typeof source !== 'string') throw new TypeError('source must be a string');
    if (typeof stableId !== 'string') throw new TypeError('stableId must be a string');
    if (typeof newType !== 'string') throw new TypeError('newType must be a string');
    const src = _writeString(source);
    const id = _writeString(stableId);
    const t = _writeString(newType);
    const resultPtr = _wasm.wgslender_change_type_by_id(
      src.ptr, src.len,
      id.ptr, id.len,
      t.ptr, t.len,
    );
    _wasm.wgslender_dealloc(src.ptr, src.allocLen);
    _wasm.wgslender_dealloc(id.ptr, id.allocLen);
    _wasm.wgslender_dealloc(t.ptr, t.allocLen);
    if (!resultPtr) throw new Error('changeTypeByStableId failed: WASM returned null');
    return _readResultJson(resultPtr);
  }

  function changeTypeApplyByStableId(source, stableId, newType) {
    _ensureInit();
    if (typeof source !== 'string') throw new TypeError('source must be a string');
    if (typeof stableId !== 'string') throw new TypeError('stableId must be a string');
    if (typeof newType !== 'string') throw new TypeError('newType must be a string');
    const src = _writeString(source);
    const id = _writeString(stableId);
    const t = _writeString(newType);
    const resultPtr = _wasm.wgslender_change_type_apply_by_id(
      src.ptr, src.len,
      id.ptr, id.len,
      t.ptr, t.len,
    );
    _wasm.wgslender_dealloc(src.ptr, src.allocLen);
    _wasm.wgslender_dealloc(id.ptr, id.allocLen);
    _wasm.wgslender_dealloc(t.ptr, t.allocLen);
    if (!resultPtr) throw new Error('changeTypeApplyByStableId failed: WASM returned null');
    return _readResultJson(resultPtr);
  }

  function isInitialized() {
    return _initialized;
  }

  function getVersion() {
    if (!_initialized) return 'unknown';
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

  return {
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
    getVersion,
    get version() { return getVersion(); },
  };
}

module.exports = { createWrapper };
