# npm wrapper factory refactor

## Context

The npm package at `npm/wgslender/` ships four wrapper files (Node CJS, Node ESM, Browser ESM, Browser UMD) that duplicate ~2,000 lines of WASM-glue logic. Recent commit `24d21f1` had to patch the same `validate()` decoder offsets in three of them — the kind of drift that re-emerges every time the WASM ABI changes.

Worse, the duplication isn't even consistent. Current per-wrapper method counts (verified in this checkout):

| File | Methods | Missing vs `lib/main.js` |
|---|---:|---|
| `lib/main.js` | 22 | — (full surface) |
| `lib/browser.js` | 20 | `lint`, `lintAndFix` |
| `esm/node.mjs` | 20 | `lint`, `lintAndFix` |
| `esm/browser.js` | 11 | `lint`, `lintAndFix`, plus all 9 stableId/locate/byStableId edit APIs (`stableIdAtOffset`, `locateStableId`, `locateDeclaration`, `locateType`, `renameByStableId`, `removeDeclarationByStableId`, `removeDeclarationApplyByStableId`, `changeTypeByStableId`, `changeTypeApplyByStableId`) |

Tests only exercise `lib/main.js`, so the gaps and drift go unnoticed.

Goal: extract a single shared core with a thin env-specific shim per entry. Eliminate the drift hazard at its root (one envelope decoder), close the browser feature gap, and add cross-variant tests so the parity is enforced going forward.

## Approach: pure factory, CJS-authored core, no codegen

One core module under `npm/wgslender/lib/_core.cjs` exports `createWrapper({ loadWasm })`. Each entry file becomes a thin shim that supplies env-specific glue and re-exports the API. ABI offsets (5 envelope shapes, ~14 numbers) are hand-written once in core — generating them from `src/wasm.zig` would be more build glue than the duplication it removes.

CJS authoring is required: the existing `require('wgslender')` consumers must stay synchronous. ESM shims must use **default-import + destructure** rather than relying on Node's CJS named-export inference — the inference works on Node 24 but is fragile on the older Node versions in `engines.node >=16`:

```js
// esm/node.mjs and esm/browser.js
import core from '../lib/_core.cjs';
const { createWrapper } = core;
```

Browser bundlers consume the shims, never `_core.cjs` directly.

## File layout after refactor

```
npm/wgslender/
  lib/
    _core.cjs          NEW  ~450 LOC — full API, all envelope decode, init guards
    main.js            ~25 LOC — CJS shim: fs + require.resolve loader
    browser.js         ~40 LOC — UMD shim: fetch + instantiateStreaming loader
    main.d.ts          unchanged (already describes full API)
  esm/
    node.mjs           ~25 LOC — ESM shim: fs + fileURLToPath loader
    browser.js         ~30 LOC — ESM shim: fetch + instantiateStreaming loader
  test/
    _suite.cjs         NEW — parameterized assertions, exports runSuite(wgslender)
    node-cjs.cjs       NEW — runs suite against lib/main.js
    node-esm.mjs       NEW — runs suite against esm/node.mjs
    browser-shim.cjs   NEW — runs suite against both browser entries via Node fetch polyfill
  test.js              kept as a thin wrapper that runs all 4 (or replaced by npm test script)
```

`package.json` `exports` map stays bit-for-bit identical. Public API surface preserved. `lib/main.d.ts` already covers the full API — no `.d.ts` changes.

## Factory shape

`createWrapper({ loadWasm })` closes over private state (`{ initialized, initPromise, wasm }`) and returns:
- `initialize(options)` — calls `loadWasm(options)`, stores `instance.exports`, dedupes via `_initPromise`
- `isInitialized()`, `version` getter
- All 22 API methods (`minify`, `validate`, `reflect`, `compile`, `lint`, `lintAndFix`, `findReferences`, `rename`, `renameApply`, `stableIdAtOffset`, `locateStableId`, `renameByStableId`, `locateDeclaration`, `locateType`, `removeDeclarationByStableId`, `removeDeclarationApplyByStableId`, `changeTypeByStableId`, `changeTypeApplyByStableId`, `getBindGroups`)

Each shim:
1. Defines `loadWasm(options)` returning `Promise<WebAssembly.Instance['exports']>`.
2. Calls `createWrapper({ loadWasm })`.
3. Re-exports every named export.

State lives in factory closure (per-instantiation), not module globals — Node's CJS/ESM loader caches each shim separately, so the existing single-instance behavior per shim is preserved.

## Envelope shapes (single source of truth in `_core.cjs`)

Currently mirrored in 4 JS files; defined Zig-side in `src/wasm.zig` `pack*` functions (lines 46–86):

| Result | Layout |
|---|---|
| generic JSON | `[u32 json_len@0][json@4]` |
| `validate` | `[u32 valid@0, errors@4, warnings@8, json_len@12][json@16]` |
| `compile` | `[u32 wasm_len@0, original@4, errors_len@8][wasm@12][errors@12+wasm_len]` |
| `lint` | `[u32 errors@0, warnings@4, json_len@8][json@12]` |
| `lintAndFix` | `[u32 fixed_len@0, errors@4, warnings@8, json_len@12][fixed@16][json@16+fixed_len]` |

A regression test asserts each decoded shape against a fixture (see Testing). The `validate` envelope drift in commit `24d21f1` is the canonical case to lock down — see the explicit assertion list below.

## Critical files to modify

- `npm/wgslender/lib/main.js` — collapse to shim
- `npm/wgslender/esm/node.mjs` — collapse to shim
- `npm/wgslender/esm/browser.js` — collapse to shim, gains 13 methods
- `npm/wgslender/lib/browser.js` — collapse to shim, gains 13 methods
- `npm/wgslender/test.js` — split into parameterized suite + 3 runners
- `npm/wgslender/package.json` — bump version `1.0.0 → 1.1.0`, add `scripts.test`

## Files to create

- `npm/wgslender/lib/_core.cjs` — factory
- `npm/wgslender/test/_suite.cjs` — shared assertions
- `npm/wgslender/test/node-cjs.cjs`
- `npm/wgslender/test/node-esm.mjs`
- `npm/wgslender/test/browser-shim.cjs`

## Out of scope

- `npm/wgslender-lsp/` (index.js, index.mjs) — small, structurally different, no drift signal. Revisit if it grows.
- Generated ABI manifest from `src/wasm.zig` — not worth the build glue for 14 offset numbers.
- Real browser smoke test (Playwright/puppeteer) — Node-side fetch polyfill catches the actual drift hazard (envelope decode); fetch/streaming-instantiate paths are exercised by the polyfill.

## Migration order (4 commits)

The parity test suite lands **with the factory**, not after — so commits 2 and 3 each get immediate coverage on the variant they convert.

1. **Add `_core.cjs` + parameterised test harness; refactor `lib/main.js` into shim.** Establishes the factory contract. Add `test/_suite.cjs` (extracted from `test.js`) and `test/node-cjs.cjs` runner; wire `npm test` to run it. Existing `node test.js` invocations continue to work.
2. **Refactor `esm/node.mjs` into shim; add `test/node-esm.mjs` runner.** Adds `lint` + `lintAndFix` to Node ESM consumers (2 new methods). `npm test` now runs CJS + ESM runners — drift on this conversion is caught immediately.
3. **Refactor `esm/browser.js` and `lib/browser.js` into shims; add `test/browser-shim.cjs` runner.** `lib/browser.js` gains `lint`/`lintAndFix` (2 methods); `esm/browser.js` gains all 11 missing methods. Bump `package.json` to `1.1.0` in this commit — this is a feature add, not a fix. `npm test` now covers all 4 variants.
4. **(Optional) Polish: remove now-redundant `test.js`, tighten CI invocation.** Pure cleanup; no behavior change.

## Testing & verification

After commit 1: `node npm/wgslender/test.js` continues to pass (existing 685-line suite).

After commit 4, `npm test` from `npm/wgslender/` runs:
- `node test/node-cjs.cjs` — `require('../lib/main.js')` → `runSuite(wgslender)`
- `node test/node-esm.mjs` — `await import('../esm/node.mjs')` → `runSuite(wgslender)`
- `node test/browser-shim.cjs` — polyfills `globalThis.fetch` to read `wgslender.wasm` from disk, then loads both `esm/browser.js` (via dynamic `import()`) and `lib/browser.js` (eval'd UMD), runs suite against each.

Browser-shim runner exercises every API method, every envelope decoder, and the `wasmModule` pre-compiled init path. It can't exercise real browser fetch semantics, but those aren't where drift originates.

### Mandatory `validate` regression assertions (every variant)

The suite must include these assertions for `validate()` against each of the 4 wrappers — they directly target both halves of the `24d21f1` fix:

1. `validate(source)` returns an object with `errorCount`, `warningCount`, `valid`, `diagnostics` — and `warningCount` is correctly read from offset+8 of the envelope (not zero, not the JSON length, not undefined).
2. `validate(sourceWithWarnings)` produces `warningCount > 0` for a fixture known to emit warnings (e.g. a shader using a deprecated builtin), proving the field is decoded, not hard-coded.
3. `validate(source)` parses the trailing JSON envelope into a populated `diagnostics` array whose entries carry `severity`, `message`, and a `range` — proves the `[u32 json_len@12][json@16]` decode is intact.
4. `validate(source, { strict: true })` triggers strict-mode validation (the JS layer must pass `flags = 1` to `wgslender_validate`); assert that a fixture which is valid under default mode produces ≥1 error under `{ strict: true }`. Catches shims that drop the options arg or hard-code `flags=0`.

End-to-end check before merging commit 4:
1. `zig build wasm` to ensure `wgslender.wasm` is current.
2. `cd npm/wgslender && npm test` — all 3 runners pass.
3. `npm pack --dry-run` — verify `files` array still matches (shouldn't change; `lib/`, `esm/` already covered; `test/` excluded).
4. Spot-check `package.json` `exports` map — every entry resolves to an existing file.

## LOC impact

Before: 685 + 496 + 349 + 528 = **2,058 lines** across the 4 wrappers.
After: ~450 (core) + ~120 (4 shims) = **~570 lines**. All 4 wrappers reach full parity with `lib/main.js`: `lib/browser.js` and `esm/node.mjs` each gain 2 methods (`lint`, `lintAndFix`); `esm/browser.js` gains 11. ~72% LOC reduction.
