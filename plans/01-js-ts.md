# Plan 01 — JS/TS example: using WGSLender from JavaScript/TypeScript

**Creates:** `examples/js-ts/` — a small, self-contained npm project that consumes the
real `packages/js-npm` package (via a `file:` dependency) from **TypeScript**, with three
runnable subexamples (**minify**, **validate**, **reflect**) and a `node:test` suite
that proves each one works.

**Status:** ready to execute. Verified against `main @ 017cb1d`, 2026-08-05, macOS arm64,
node v26.6.0 / npm 11.18.0, zig 0.16.0.

---

## Verified current state (do not re-derive)

- The npm package lives at `packages/js-npm/` (version `1.1.0`), with the WASM artifact
  **committed** at `packages/js-npm/wgslender.wasm`. `cd packages/js-npm && npm test` is
  green today (175 passed × 4 wrapper variants).
- Public API (all return **parsed JS objects**, never JSON strings):
  - `initialize(options?) => Promise<void>` — in Node, no options needed (the node
    wrappers locate the wasm themselves). Idempotent.
  - `minify(source, options?) => { code, errors, originalSize, minifiedSize, sourceMap? }`
    — defaults applied by the wrapper: `minifyWhitespace/minifyIdentifiers/minifySyntax/treeShaking: true`,
    `mangleExternalBindings/preserveUniformStructTypes: false`. Other options:
    `keepNames: string[]`, `sortDeclarations`, `scopeLocalRename`, `sourceMap`, `sourceMapSources`.
  - `validate(source, options?) => { valid, diagnostics, errorCount, warningCount }`
    — diagnostics entries: `{ severity, code?, message, line, column, … }` (1-based positions).
  - `reflect(source) => ReflectResult` — v2 envelope: `{ version: 2, bindings, uniforms,
    storage, textures, samplers, structs, entryPoints, overrides, functions, aliases, errors? }`.
  - `getBindGroups(reflectResultOrBindings) => Record<group, Record<binding, BindingInfo>>` — pure JS.
  - Plus lint/compile/refactor functions not covered by this plan.
- Package `exports` map (`packages/js-npm/package.json:14-31`): `.` has `browser`/`node`/`default`
  conditions (node → `import: ./esm/node.mjs`, `require: ./lib/main.js`); subpaths
  `./configs` (has a `types` condition) and `./wasm`. Top-level `"types": "lib/main.d.ts"`.
- **Known typing defects in `packages/js-npm/lib/main.d.ts`** (found by code inspection,
  confirmed at the cited lines):
  1. `initialize(options: InitializeOptions)` declares the parameter **required**
     (`main.d.ts:481`) while the implementation treats it as optional
     (`lib/_core.cjs:28`, `options || {}`). So `await initialize()` is a **type error** today.
  2. `ValidateOptions` (`main.d.ts:409-422`) declares `strictMode?: boolean` and
     `diagnosticFilters?`, but the implementation reads `options.strict`
     (`lib/_core.cjs:143`) and never forwards `diagnosticFilters` (the WASM ABI only
     takes a single flags u32 — `src/wasm.zig:142-149`). So the **typed** name is a
     runtime no-op and the **working** name (`strict`) is untyped.
  3. `getVersion()` exists at runtime (`lib/_core.cjs:471`) but is absent from `main.d.ts`.
  4. `exports["."]` has **no `types` condition** — under `moduleResolution: "nodenext"`,
     TS resolves `wgslender` → `./esm/node.mjs` and may fail to find declarations
     (no `node.d.mts` exists). Whether this errors depends on the TS version — Block 0
     tests it empirically.
- WASM freshness rule: the examples run against the **committed**
  `packages/js-npm/wgslender.wasm`. If Zig-side wire formats changed since it was built,
  refresh it first: `zig build wasm && cp zig-out/bin/wgslender.wasm packages/js-npm/wgslender.wasm`
  (then re-run `cd packages/js-npm && npm test`).

## Ground rules

- TDD reds-first: each block writes/extends the failing test first, runs it, confirms the
  exact red stated, then implements to green. Tests are table-driven — a new case is a row.
- No CI. All commands are local (`npm test` inside `examples/js-ts/`).
- One conventional, atomic commit per block (messages given per block). Do not commit
  unrelated working-tree changes.
- Exact numeric expectations (struct sizes/offsets) are pinned from the CLI oracle:
  `zig build && ./zig-out/bin/wgslender reflect <file>` — never guessed.

## Target layout

```
examples/js-ts/
  package.json          private; deps: wgslender file:../../packages/js-npm; devDeps: typescript, @types/node
  .npmrc                package-lock=false
  tsconfig.json         nodenext + strict, src/ → dist/
  shaders/
    demo.wgsl           uniform struct + storage buffer + texture/sampler + compute entry point
    invalid.wgsl        undeclared identifier
    warning.wgsl        workgroupBarrier in non-uniform control flow (yields a warning; error under strict)
  src/
    minify.mts          subexample 1
    validate.mts        subexample 2
    reflect.mts         subexample 3
  test/
    examples.test.mjs   node:test — script-runner table + direct-API tables
  README.md
```

---

## Block 0 — Scaffold + make the package typing honest (red: `tsc --noEmit` fails)

**Context recap:** `examples/js-ts/` does not exist. `main.d.ts` has the four defects
listed above; two of them (`initialize()` no-arg, `{ strict: true }`) make correct
runtime code fail the type-check, which blocks a TypeScript example.

1. Create the scaffold:
   - `examples/js-ts/package.json`:
     ```json
     {
       "name": "wgslender-example-js-ts",
       "private": true,
       "type": "module",
       "scripts": {
         "build": "tsc",
         "pretest": "npm run build",
         "test": "node --test test/"
       },
       "dependencies": { "wgslender": "file:../../packages/js-npm" },
       "devDependencies": { "typescript": "^5.6", "@types/node": "^26" }
     }
     ```
   - `examples/js-ts/.npmrc` containing `package-lock=false`.
   - `examples/js-ts/tsconfig.json`:
     ```json
     {
       "compilerOptions": {
         "module": "nodenext",
         "moduleResolution": "nodenext",
         "target": "es2022",
         "strict": true,
         "outDir": "dist",
         "rootDir": "src",
         "skipLibCheck": false
       },
       "include": ["src"]
     }
     ```
   - Append to the repo root `.gitignore`:
     ```
     examples/js-ts/node_modules/
     examples/js-ts/dist/
     ```
   - `cd examples/js-ts && npm install` (creates a `node_modules/wgslender` symlink).
2. **Red.** Write a minimal `src/minify.mts` that exercises the two known-defective
   spots plus the module resolution itself:
   ```ts
   import { initialize, minify, validate } from 'wgslender';
   await initialize();                                  // d.ts says options is required
   console.log(minify('fn main() {}').code);
   console.log(validate('fn main() {}', { strict: true }).valid);  // d.ts only knows strictMode
   ```
   Run `npx tsc --noEmit`. Expected red — at minimum:
   - `TS2554 Expected 1 arguments, but got 0` on `initialize()`.
   - `TS2353`/`TS2345` (unknown property `strict`) on the validate options.
   - Possibly `TS7016` (no declaration file for `esm/node.mjs`) — depends on TS version;
     note which reds actually appeared.
3. **Green — fix the package typings** (edit `packages/js-npm/`):
   - `lib/main.d.ts`: make it `initialize(options?: InitializeOptions)`.
   - `lib/main.d.ts` `ValidateOptions`: add `strict?: boolean` ("enables strict mode:
     warnings are treated as errors"); annotate the existing `strictMode` and
     `diagnosticFilters` with `@deprecated Not implemented — has no runtime effect;
     use \`strict\` (strictMode) / the lint API (diagnosticFilters).` Do **not** delete
     them (that would break existing consumers' compiles).
   - `lib/main.d.ts`: add `export function getVersion(): string;`.
   - Only if step 2 produced TS7016: add a `types` condition **first** inside
     `exports["."]` in `packages/js-npm/package.json`:
     `"types": "./lib/main.d.ts"` (before `browser`/`node`/`default`).
4. Verify: `npx tsc --noEmit` is clean; `cd ../../packages/js-npm && npm test` still
   175×4 green; `npm pack --dry-run` still lists the same files.
5. Commit (two atomic commits):
   - `fix(npm): align main.d.ts with runtime API (optional initialize, strict, getVersion)`
   - `chore(examples): scaffold examples/js-ts TypeScript project`

**Behavior change callout:** Block 0 changes the package's **published type surface**
(`.d.ts` + possibly `package.json` exports metadata). Zero runtime change — `_core.cjs`
is untouched. See "Behavior changes" at the end.

---

## Block 1 — Fixtures + failing test harness (red: example scripts missing)

**Context recap:** `examples/js-ts/` scaffold exists and type-checks (Block 0).
Scripts `npm run build` (tsc → `dist/`) and `npm test` (`node --test test/`) are wired.
The three example scripts do not exist yet — this block creates the fixtures and the
full test suite, which must **fail** on the missing scripts.

1. Write the fixtures:
   - `shaders/demo.wgsl`:
     ```wgsl
     struct Params {
       resolution: vec2f,
       time: f32,
       frame: u32,
     }

     @group(0) @binding(0) var<uniform> params: Params;
     @group(0) @binding(1) var<storage, read_write> data: array<vec4f>;
     @group(1) @binding(0) var tex: texture_2d<f32>;
     @group(1) @binding(1) var samp: sampler;

     fn luminance(c: vec3f) -> f32 {
       return dot(c, vec3f(0.2126, 0.7152, 0.0722));
     }

     @compute @workgroup_size(8, 8, 1)
     fn main(@builtin(global_invocation_id) gid: vec3u) {
       let idx = gid.y * u32(params.resolution.x) + gid.x;
       let c = textureLoad(tex, vec2i(gid.xy), 0);
       data[idx] = vec4f(vec3f(luminance(c.rgb)), params.time);
     }
     ```
   - `shaders/invalid.wgsl`:
     ```wgsl
     fn main() -> f32 {
       return undeclared_variable;
     }
     ```
   - `shaders/warning.wgsl`:
     ```wgsl
     @group(0) @binding(0) var<storage, read_write> buf: array<u32>;

     @compute @workgroup_size(64)
     fn main(@builtin(local_invocation_index) i: u32) {
       if (i < 32u) {
         workgroupBarrier();
       }
       buf[i] = i;
     }
     ```
   Sanity-check all three against the CLI first: `zig build`, then
   `./zig-out/bin/wgslender validate examples/js-ts/shaders/demo.wgsl` must pass,
   `invalid.wgsl` must fail with an undeclared-identifier error, `warning.wgsl` must
   produce ≥1 warning and 0 errors (adjust the fixture if not — then update the plan's
   expectations to what the oracle says).
2. **Pin the reflect oracle numbers.** Run
   `./zig-out/bin/wgslender reflect examples/js-ts/shaders/demo.wgsl` and record:
   `structs.Params.size` / `.alignment` (expected 16 / 8 — confirm), the field offsets
   (`resolution@0`, `time@8`, `frame@12` — confirm), and the binding `addressSpace`
   strings (`uniform`, `storage`, `handle` for texture/sampler — confirm). Use the
   **observed** values in the test table below.
3. **Red.** Write `test/examples.test.mjs` with two suites:
   - **Suite A — example scripts run.** Table-driven over the three scripts:
     ```js
     const cases = [
       { script: 'dist/minify.mjs',   expect: [/original\s+\d+\s+bytes/i, /minified/i, /@compute/] },
       { script: 'dist/validate.mjs', expect: [/demo\.wgsl: valid/i, /invalid\.wgsl: INVALID/i, /E\d{4}/, /strict/i] },
       { script: 'dist/reflect.mjs',  expect: [/group\(0\).*binding\(0\).*params/i, /Params.*16/, /entry.*main.*compute/i] },
     ];
     ```
     Each case: `execFile(process.execPath, [script], { cwd: exampleRoot })`, assert
     exit code 0 and every `expect` pattern matches stdout.
   - **Suite B — direct API assertions.** `import 'wgslender'`, `initialize()` once in
     `before()`, then table-driven cases:
     - minify: `{ name, source, options, assert(result) }` rows — (a) demo shrinks:
       `minifiedSize < originalSize`, `errors.length === 0`, code contains `@compute`
       and `fn main` (entry names preserved by default); (b) external binding name
       `params` survives with default options; (c) `keepNames: ['luminance']` keeps
       `luminance` in the output while plain default minify removes it; (d) invalid
       source ⇒ `errors.length > 0`.
     - validate: (a) demo ⇒ `valid === true`, `errorCount === 0`; (b) invalid ⇒
       `valid === false`, `errorCount >= 1`, first diagnostic has non-empty `code`,
       `line >= 1`, `column >= 1`; (c) warning fixture default ⇒ `warningCount >= 1`;
       (d) strict: `validate(warnSrc, { strict: true }).errorCount >=
       def.errorCount + def.warningCount` (same invariant the package suite pins).
     - reflect: (a) `version === 2`; (b) 4 bindings with the pinned
       group/binding/addressSpace values; (c) `structs.Params` size/alignment/field
       offsets equal to the oracle numbers from step 2; (d) one entry point
       `{ name: 'main', stage: 'compute', workgroupSize: [8, 8, 1] }`;
       (e) `getBindGroups(result)[0][1].name === 'data'`.
   - Run `npm test`. **Expected red:** Suite A fails with `ENOENT`/non-zero exit on all
     three missing `dist/*.mjs`; Suite B should be **green already** (it tests the
     package, which works). Confirm exactly that split — if Suite B has reds, stop and
     investigate (wasm staleness is the first suspect; see freshness rule above).
4. Commit: `test(examples): add js-ts fixtures and failing example-script suite`
   *(committing a known-red suite is intentional — the next three blocks turn it green
   one script at a time).*

---

## Block 2 — `src/minify.mts` (green: minify row)

**Context recap:** `examples/js-ts/` has fixtures + a red Suite A row expecting
`dist/minify.mjs` to print original/minified byte counts and the minified code.
`npm run build` compiles `src/*.mts` → `dist/*.mjs`.

Replace the Block 0 smoke content of `src/minify.mts` with the real subexample:

1. Read `shaders/demo.wgsl` (path-resolve relative to the script:
   `new URL('../shaders/demo.wgsl', import.meta.url)`).
2. `await initialize();` then three calls, printing a short labelled report to stdout:
   - defaults — print `original <n> bytes`, `minified <n> bytes`, the % saved, and the
     minified code;
   - `{ keepNames: ['luminance'] }` — print that `luminance` survived;
   - `{ minifyWhitespace: true, minifyIdentifiers: false, minifySyntax: false }` —
     whitespace-only variant, print its size.
3. Non-zero exit + message on `result.errors.length > 0`.
4. `npm test` → minify row green (validate/reflect rows still red). Confirm.
5. Commit: `feat(examples): js-ts minify subexample`

## Block 3 — `src/validate.mts` (green: validate row)

**Context recap:** Suite A expects `dist/validate.mjs` to print, for the three fixtures:
`demo.wgsl: valid`, `invalid.wgsl: INVALID` plus each diagnostic as
`<severity> <code> <line>:<column> <message>`, and a strict-mode section for
`warning.wgsl` showing warnings being promoted (`{ strict: true }` — note it is
`strict`, not the deprecated `strictMode`).

1. Iterate a table `[demo.wgsl, invalid.wgsl, warning.wgsl]`, run `validate()` on each,
   print `<file>: valid` or `<file>: INVALID (<errorCount> errors, <warningCount> warnings)`
   followed by formatted diagnostics.
2. Then re-validate `warning.wgsl` with `{ strict: true }` and print both counts to
   show the promotion.
3. Exit code: 0 (the script demonstrates validation; it is not a gate — say so in a
   comment).
4. `npm test` → validate row green. Commit: `feat(examples): js-ts validate subexample`

## Block 4 — `src/reflect.mts` (green: reflect row, suite fully green)

**Context recap:** Suite A expects `dist/reflect.mjs` to print the bind-group table,
`Params` struct layout (size 16 — oracle-pinned), and the entry point line.

1. `reflect(demoSource)`, then print:
   - a bindings table via `getBindGroups()`: `@group(G) @binding(B) <name>:
     <addressSpace> <type>` per row;
   - each struct in `structs`: name, size, alignment, then one line per field
     (`<offset>  <name>: <type> (size <n>)`);
   - each entry point: `entry <name> [<stage>] workgroup_size=<x>,<y>,<z>`.
2. Non-zero exit if `errors` is non-empty.
3. `npm test` → **entire suite green** (Suite A 3/3 + Suite B). Confirm and paste the
   summary line into the commit body.
4. Commit: `feat(examples): js-ts reflect subexample`

## Block 5 — README + index row + final verification

1. `examples/js-ts/README.md`: what it demonstrates, prerequisites (node ≥ 20;
   `npm install` inside the folder), the three run commands
   (`node dist/minify.mjs` etc. after `npm run build`), `npm test`, and the WASM
   freshness note (rebuild command) from the top of this plan.
2. Create-or-append `examples/README.md` with a row:
   `| js-ts | TypeScript + npm package (WASM) | cd examples/js-ts && npm install && npm test |`.
3. Final verification from a clean slate:
   `rm -rf examples/js-ts/node_modules examples/js-ts/dist && cd examples/js-ts && npm install && npm test`
   → all green. Also re-run `cd packages/js-npm && npm test` once more (the d.ts edits
   from Block 0 must not have drifted anything).
4. Commit: `docs(examples): js-ts README + examples index`

---

## Behavior changes (explicit — per repo feedback convention)

| Change | Kind | Runtime effect |
|---|---|---|
| `main.d.ts`: `initialize` param optional; `ValidateOptions.strict` added; `strictMode`/`diagnosticFilters` marked `@deprecated`; `getVersion` declared | Published **type surface** of the npm package | None |
| `package.json` `exports["."]` gains a `types` condition (only if Block 0's red shows TS7016) | Package resolution metadata | None at runtime; fixes `nodenext` TS consumers |

Explicitly **not** done (candidate follow-ups, each a real behavior change requiring
its own decision): making `strictMode` work at runtime (aliasing it to `strict` in
`_core.cjs`), implementing `diagnosticFilters`, fixing the README's stale
`sourceMap?: string` claim (it is an object), and typing the ESM `version` surrogate
honestly.

## Definition of done

- [ ] `examples/js-ts/` exists with the layout above; `node_modules/` + `dist/` gitignored.
- [ ] `npx tsc --noEmit` clean under `strict` + `nodenext` — the TS example compiles
      against the **fixed** package types with zero `any`-casts or `@ts-ignore`.
- [ ] `npm test` green: 3 script-runner cases + all direct-API table cases.
- [ ] `cd packages/js-npm && npm test` still 175×4 green.
- [ ] Reflect expectations pinned from the CLI oracle, not guessed.
- [ ] All commits atomic + conventional; no CI files added.
