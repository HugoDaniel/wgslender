# Plan — `web/`: a playground page that runs the toolkit in the browser

**Creates:** one new Starlight page (`/playground/`) hosting an interactive WGSL
editor, one Astro island component wrapping CodeMirror 6, a set of framework-free
playground modules, and a `node --test` suite that drives both WASM packages
headlessly. The page showcases, live and offline: LSP features (diagnostics,
hover, completion, go-to-definition, rename, signature help, minify-insight
inlay hints), minification with options and byte stats, validation, and
reflection JSON.

**Motivation:** the landing page (`web/`) currently *claims* five capabilities
in its CardGrid (`web/src/content/docs/index.mdx:23-38`) and demonstrates none.
Every capability already runs in the browser — `packages/js-npm/wgslender.wasm`
and `npm/wgslender-lsp/wgslender-lsp.wasm` are checked in and wrapped — so the
only missing piece is a page that connects them to an editor. The reference
experience is miniray's playground (`~/Dev/miniray/web/`): two panels, live
debounced minification, option pills, a stats bar, one screen, no framework.
This plan is that experience, upgraded from `<textarea>` to a real editor
because wgslender — unlike miniray — has a language server to show off.

**Status:** ready to execute — nothing below has landed. Verify with
`git log --oneline -- web/` before starting; the last commit touching `web/`
should predate this plan (the starter scaffold).

Every fact below was verified against the worktree on 2026-08-06. File:line
references are evidence, not decoration — re-check them only if HEAD has moved
past the commits that produced them.

---

## Verified current state (do not re-derive)

### `web/` is an untouched Starlight starter

Full inventory (excluding lockfile): `astro.config.mjs` (title "My Docs",
starter sidebar), `package.json` (astro `^7.0.2`, `@astrojs/starlight`
`^0.41.6`, sharp; pnpm, `pnpm-workspace.yaml` allows esbuild+sharp builds),
`src/content/docs/index.mdx` (splash hero + capability CardGrid, actions still
point at the Starlight example guide), `src/content/docs/guides/example.md`,
`src/content/docs/reference/example.md`, `src/content.config.ts`, `tsconfig.json`,
`public/favicon.svg`, `src/assets/houston.webp`, `AGENTS.md`.

`web/AGENTS.md` rule: start the dev server with `astro dev --background`,
manage with `astro dev stop|status|logs`. Follow it in every block.

### The two packages exist on disk and are NOT on the npm registry

Confirmed earlier this session: `wgslender` 1.1.0 (`packages/js-npm/`) and
`wgslender-lsp` 1.1.0 (`npm/wgslender-lsp/`) are unpublished. **Therefore the
web package must depend on them via `file:` protocol** — from `web/`:

```json
"wgslender": "file:../packages/js-npm",
"wgslender-lsp": "file:../npm/wgslender-lsp"
```

Both packages ship their `.wasm` beside the JS (confirmed present on disk).

### `wgslender` (minifier package) browser API surface

From `packages/js-npm/lib/main.d.ts` and the exports map
(`packages/js-npm/package.json:14-31`):

- `initialize({ wasmURL?, wasmModule? }): Promise<void>` — must run first.
- `minify(source, opts?) → { code, errors[], originalSize, minifiedSize }`
  with options `minifyWhitespace | minifyIdentifiers | minifySyntax |
  mangleExternalBindings | treeShaking | keepNames | sortDeclarations |
  scopeLocalRename | …` (`main.d.ts:1-105`).
- `validate(source, opts?)`, `lint(source, opts?)`, `reflect(source) →
  ReflectResult` (v2: `bindings`, `uniforms`, `storage`, `textures`,
  `samplers`, `structs`, `entryPoints`, `overrides`, `functions`, `aliases`),
  plus `compile`, refactor helpers, `getVersion` (`main.d.ts:498-875`).
- Browser ESM entry: `esm/browser.js`; the raw wasm is importable as the
  `wgslender/wasm` subpath (`"./wasm": "./wgslender.wasm"`).
- In Node, `import { initialize, minify } from 'wgslender'` works with no
  arguments — the package's own tests run under plain `node` (`npm test`).

### `wgslender-lsp` API surface

From `npm/wgslender-lsp/index.mjs` + `index.d.ts`:

- `initialize({ wasmURL?, wasmModule? })` — default resolves
  `./wgslender-lsp.wasm` next to the module **via `fetch`**, which fails on
  `file:` URLs in Node. Node callers pass `wasmModule` compiled from
  `fs.readFile` instead (resolve the bytes via
  `createRequire(import.meta.url).resolve('wgslender-lsp/wasm')`).
- `sendMessage(json: string): string[]` — synchronous in-process JSON-RPC;
  the return array carries responses AND server-initiated notifications.
- `createTransport(): { send, subscribe, unsubscribe }` — explicitly
  "Compatible with @codemirror/lsp-client Transport" (`index.d.ts:8-13`);
  README's own integration sketch is `README.md:452-466`.

### What the WASM LSP actually serves

Dispatch table at `lsp/wasm.zig:100-133`: `initialize`, `shutdown`, document
sync (`didOpen/didChange/didClose/didSave`), `workspace/didChangeConfiguration`,
`textDocument/` `codeAction`, `hover`, `definition`, `references`,
`documentHighlight`, `rename`, `prepareRename`, `completion`, `signatureHelp`,
`documentSymbol`, `foldingRange`, `typeDefinition`, `inlayHint`, `codeLens`,
`formatting`, `semanticTokens/full`, `selectionRange`, `prepareCallHierarchy`,
`diagnostic` (pull), `workspace/executeCommand`, and three custom requests:
`wgslender/reflect`, `wgslender/recomputeMinifyInsights`,
`wgslender/constInventory`.

Two flow facts that shape the design:

1. **Diagnostics are pushed synchronously.** `handleDidOpen` and
   `handleDidChange` call `emitDiagnostics` inline
   (`lsp/wasm/document_sync.zig:35`), so every `didOpen`/`didChange` batch
   returned by `sendMessage` already contains the
   `textDocument/publishDiagnostics` notification. There is no server-side
   debounce in the WASM build (`lsp/Debouncer.zig` header: "WASM debounces
   JS-side") — pacing is the client's job.
2. **Settings arrive by round-trip, not by push.** `didChangeConfiguration`
   only triggers a server→client `workspace/configuration` request for the
   `wgslender` section (`lsp/wasm/lifecycle.zig:47-65`), and only if the
   client advertised `workspace.configuration` in `initialize`. The client
   must answer that request with a `wgslender.json`-shaped object
   (`lsp/Handler.zig:56-60` — same schema, e.g.
   `{ "lsp": { "minifyMode": "insights" } }`). This is how the playground
   turns on minify-insight inlay hints.

`wgslender/reflect` takes `{ textDocument: { uri }, format?: "v1"|"v2",
pretty?: bool }` (`lsp/wasm/workspace_commands.zig:37-60`). The playground
does not need it — it calls `reflect()` on the minifier wasm it already
loaded — but it is the fallback if Block 3 ever wants reflection without
that wasm.

### What to take from miniray, and what not to

`~/Dev/miniray/web/src/components/miniray-minifier/` +
`~/Dev/miniray/web/src/main.js`:

- **Take:** the shape. Two-panel grid collapsing to one column under 768px;
  300 ms input debounce; option pills (`label` + checkbox,
  `:has(input:checked)` highlight); preset `<select>`; stats bar
  ("Original / Minified / Savings %"); copy button with a 1.5 s "Copied!"
  flash; error block with `white-space: pre-wrap`; loading state until wasm
  arrives; a default shader in the editor on load so the page demos itself.
- **Take:** the state discipline — one plain state object, pure render from
  state, event handlers mutate then re-render.
- **Leave:** boreDOM (wgslender's page has Astro), the `<textarea>` editor
  (CodeMirror replaces it — an LSP demo needs a real editor), the Go wasm
  polling loop, and miniray's custom `--color-*` tokens (Starlight already
  ships a theme; use `--sl-*` variables so dark/light mode is free).

### Known traps, written down before they bite

- **Vite + `file:` deps:** pnpm symlinks the two packages from outside
  `web/`; Vite's dev-server fs allow-list may refuse to serve the linked
  `.wasm`. Fix lives in `web/astro.config.mjs`:
  `vite: { server: { fs: { allow: ['..'] } } }` — apply only if the probe in
  Block 1 actually hits the error. Likewise add the two packages to
  `vite.optimizeDeps.exclude` if prebundling breaks `import.meta.url`-relative
  wasm resolution.
- **Stale wasm binaries:** the checked-in `.wasm` files predate whatever has
  landed on `main` since they were built. Block 1 rebuilds both
  (`zig build wasm -Doptimize=ReleaseSafe`, `zig build lsp-wasm
  -Doptimize=ReleaseSafe`) and copies them into the package dirs, exactly as
  `packages/js-npm/package.json:58` (`prepublishOnly`) does. If bytes change,
  commit that separately — see Behavior changes.
- **`@codemirror/lsp-client` is young (0.x).** Its capability coverage
  (push-diagnostics rendering, inlay hints, semantic tokens) must be probed
  at execution time, not assumed. Every LSP feature in this plan therefore
  has a written fallback that uses only `createTransport`'s `subscribe` (raw
  message tap) or `sendMessage` (direct request) — both of which are
  wgslender-lsp API and cannot be broken by the client library.
- **WGSL syntax highlighting has no official CodeMirror package.** The
  deterministic baseline is a small `StreamLanguage.define` mode written in
  this repo (keyword lists sourced from `src/Lexer.zig` — remember `private`,
  `uniform`, `storage`, `read_write` are *not* reserved words). Semantic
  tokens from the LSP are an enhancement on top, not the baseline, so the
  editor colors code even before wasm finishes loading.

---

## Ground rules

- **No UI framework.** One `.astro` component, plain TypeScript modules,
  CodeMirror 6 as the only editor dependency. This mirrors miniray's
  minimalism and keeps the island small.
- **Style = Starlight's tokens.** Scoped styles in the component using
  `--sl-color-*`, `--sl-font-*` custom properties only. No new palette, no
  global CSS file. The page must look native next to every other Starlight
  page in both themes.
- **Logic lives outside the DOM.** Everything testable under Node —
  LSP message flow, minify/reflect panel models, debounce policy, stats
  math — goes in `web/src/scripts/playground/` as pure modules. The `.astro`
  `<script>` is wiring only. This is what makes TDD possible for a web page.
- **TDD, reds first, Node-shaped.** Each block's tests are written and
  observed failing before the implementation. The gate is
  `cd web && pnpm test` (`node --test tests/`) plus `pnpm build`
  (`astro build` — catches SSR/import/resolution errors that Node tests
  can't). Browser behavior is verified by hand against
  `astro dev --background` at the end of each block. **No CI** — the gate is
  local and on-demand, deliberately.
- **Probe, don't trust.** `@codemirror/lsp-client`'s abilities, Vite's
  handling of `?url` wasm imports, and exact package versions are confirmed
  by running them, and divergences get recorded in this file's Status
  section, following `docs/plans/rust-examples.md`'s convention.
- Conventional commits, one block ≈ one commit (Block 1 may be two: deps vs
  rebuilt wasm).

### Out of scope

- Publishing any package (separate, undecided — see session notes).
- The binary-shader `compile` demo — the page's copy may *mention*
  `npx wgslender shader.wgsl`, but a compile-to-wasm playground panel is a
  follow-up plan.
- A WebGPU canvas preview of the shader. This page demos the *toolchain*,
  not shader art; compute.toys already exists.
- Multi-file workspaces, call hierarchy UI, code lens UI, folding UI —
  the LSP serves them, the playground doesn't surface them (yet).
- Touching the site's title/branding/sidebar beyond adding the playground
  entry and fixing the hero's dead starter links.

---

## Target layout

```
web/
  package.json                 # + file: deps, codemirror deps, "test" script
  astro.config.mjs             # + sidebar entry; vite.fs.allow only if probed necessary
  tests/
    lsp-flow.test.mjs          # Block 1: headless LSP session over sendMessage
    panels.test.mjs            # Block 3: minify/reflect/diagnostic panel models
  src/
    components/
      PlaygroundEditor.astro   # Block 2–4: markup + scoped styles + wiring script
    scripts/playground/
      sample-shader.ts         # Block 1: the default shader (shared by tests + UI)
      wgsl-language.ts         # Block 2: StreamLanguage WGSL mode
      lsp-client.ts            # Block 2: transport + client + config round-trip
      panels.ts                # Block 3: pure panel-model builders (testable)
      wasm.ts                  # Block 2: init both wasms via ?url imports
    content/docs/
      playground.mdx           # Block 2: the page (grows through Block 5)
```

---

## Block 1 — packages wired, wasm fresh, headless LSP session green

*Fresh-session context: `web/` is a pristine Starlight starter using pnpm; the
two local packages (`../packages/js-npm`, `../npm/wgslender-lsp`, both 1.1.0,
unpublished) each contain a checked-in `.wasm`. Everything you need to know
about their APIs is in "Verified current state" above.*

**Red.** Add `"test": "node --test tests/"` to `web/package.json` and write
`web/tests/lsp-flow.test.mjs` first. It must:

1. `import { initialize, sendMessage } from 'wgslender-lsp'` and
   `import { initialize as initMinifier, minify, reflect } from 'wgslender'`.
2. Initialize the LSP with a `wasmModule` compiled from
   `createRequire(import.meta.url).resolve('wgslender-lsp/wasm')` bytes
   (the `fetch(file:)` trap above).
3. Run a full session: `initialize` (advertise
   `capabilities.workspace.configuration: true`) → `initialized` → `didOpen`
   with the sample shader → **assert the returned batch contains a
   `publishDiagnostics` for the file with a `W`-code on the dead helper** →
   `didChange` introducing `uniforms.tim` → assert an `E`-code appears →
   `textDocument/hover` over `uniforms` returns contents.
4. Assert `minify(sample)` shrinks the shader and drops the dead helper from
   `code`, and `reflect(sample)` reports the uniform + storage bindings and
   the fragment entry point.

Also create `web/src/scripts/playground/sample-shader.ts` now — the tests and
the UI must share one shader. It needs, by construction: a uniform struct
(reflection layout), a storage binding (reflect subsets), a used helper
function (hover/definition targets), an *unused* helper (lint W-code +
visible tree-shaking in the minify panel), and a fragment entry point.
Adapt miniray's default shader (`~/Dev/miniray/web/src/main.js`, `initialState.input`)
by adding the storage binding and the dead function.

Run `pnpm test`: every test fails on unresolvable imports. That is the red.

**Green.**

1. Rebuild both wasms from the current tree and copy into the packages —
   `zig build wasm -Doptimize=ReleaseSafe && cp zig-out/bin/wgslender.wasm
   packages/js-npm/` and `zig build lsp-wasm -Doptimize=ReleaseSafe &&
   cp zig-out/bin/wgslender-lsp.wasm npm/wgslender-lsp/` (from the repo
   root). If `git status` shows changed bytes, commit the wasm refresh as its
   own commit before the deps commit.
2. Add the two `file:` dependencies plus editor deps to `web/package.json`:
   `codemirror` (^6), `@codemirror/language`, `@codemirror/lint`,
   `@codemirror/lsp-client` (version: whatever `pnpm add` resolves — record
   it here), and run `pnpm install`.
3. `pnpm test` until green. Expect to discover the exact diagnostic codes
   here (dead helper is likely `W0001` unused-symbol from
   `@wgslender/recommended`); pin whatever the server actually says, the way
   `tests/lint_rules_test.zig` pins codes with `hasCodeContaining`.

**Gate:** `cd web && pnpm test` green; `pnpm build` still green (no source
changes yet, this just proves deps didn't break the build).

---

## Block 2 — the editor island: CodeMirror + WGSL mode + live diagnostics

*Fresh-session context: Block 1 landed `file:` deps on `wgslender` +
`wgslender-lsp`, codemirror deps, a green `tests/lsp-flow.test.mjs`, and
`sample-shader.ts`. The LSP pushes `publishDiagnostics` inside every
`didOpen`/`didChange` `sendMessage` batch; settings arrive via a
`workspace/configuration` round-trip (see "Verified current state"). Dev
server: `astro dev --background` per `web/AGENTS.md`.*

Create, in order:

1. `src/scripts/playground/wgsl-language.ts` — `StreamLanguage.define` mode:
   keywords/types/builtins lifted from `src/Lexer.zig` keyword tables (do not
   invent the lists; `private`/`uniform`/`storage`/`read_write` are address
   space/access words, not reserved), `//` and nesting `/* */` comments
   (WGSL comments nest — the mode must count depth), numeric literals,
   `@attributes`.
2. `src/scripts/playground/wasm.ts` — one `initPlayground()` that imports
   both wasm URLs (`import wgslWasmUrl from 'wgslender/wasm?url'`, same for
   `wgslender-lsp/wasm`) and runs both `initialize({ wasmURL })` calls in
   parallel. **Probe:** if Vite chokes on `?url` across the `file:` symlink,
   fall back to copying the two `.wasm` into `web/public/` via an
   `astro:build`/predev script — record which path won.
3. `src/scripts/playground/lsp-client.ts` — wraps
   `createTransport()` + `LSPClient` + `languageServerExtensions()` per
   `README.md:452-466`. Two jobs beyond the sketch: answer the server's
   `workspace/configuration` request (return `[{}]` for now; Block 4 fills
   it), and expose a `subscribe` tap that forwards every
   `publishDiagnostics` payload to a callback — that tap is the
   client-library-proof path to the diagnostics panel, and the fallback
   renderer (via `@codemirror/lint` `setDiagnostics`) if the probe shows
   lsp-client doesn't render pushed diagnostics itself.
4. `src/components/PlaygroundEditor.astro` — markup: loading note, editor
   pane, empty right pane (Block 3), miniray's grid geometry
   (`1fr 1fr`, one column under 768 px); scoped styles on `--sl-*` tokens;
   `<script>` that mounts CodeMirror (basic setup + WGSL mode + LSP
   extensions) with the sample shader.
5. `src/content/docs/playground.mdx` — frontmatter `title: Playground`,
   `tableOfContents: false`; imports and renders `<PlaygroundEditor />`; one
   sentence of copy ("Everything on this page runs in your browser — no
   server."). Add `{ label: 'Playground', slug: 'playground' }` to the
   sidebar in `astro.config.mjs`.

**Verification (browser, by hand):** typing `uniforms.tim` squiggles with the
E-code within ~a keystroke's debounce; hovering `uniforms` shows type info;
`Ctrl-Space` after `uniforms.` completes struct fields; the dead helper
carries a warning squiggle on load. Both color themes look native.

**Gate:** `pnpm test` (Block 1 suite still green) + `pnpm build`.

---

## Block 3 — the working panels: minify, reflect, diagnostics

*Fresh-session context: Blocks 1–2 landed the editor island with live LSP
diagnostics on `/playground/`. The minifier wasm is already initialized by
`wasm.ts` but nothing calls `minify`/`reflect` yet. miniray's playground
(`~/Dev/miniray/web/`) is the UX reference: options pills, stats bar, copy
button, 300 ms debounce.*

**Red.** `web/tests/panels.test.mjs` against a new pure module
`src/scripts/playground/panels.ts`:

- `buildMinifyModel(source, opts)` → `{ code, stats: { original, minified,
  savedPct }, errors }` — assert real numbers from the real wasm on the
  sample shader; assert `mangleExternalBindings: false` keeps `uniforms` in
  the output and toggling identifiers off keeps `computeColor`.
- `buildReflectModel(source)` → grouped rows (uniforms / storage / textures /
  samplers, entry points with stage + workgroup size, struct layouts with
  offset/size) — assert the sample's uniform struct fields and offsets.
- `formatDiagnostic(d)` → `"E0xxx line:col message"` rows sorted
  errors-first — feed it a captured `publishDiagnostics` payload.

**Green.** Implement `panels.ts` (pure — Node-testable), then wire the right
pane in `PlaygroundEditor.astro` as three **Starlight-native tabs** — use the
existing `Tabs`/`TabItem` components from `@astrojs/starlight/components` if
they accept island content cleanly, else three plain buttons styled with
`--sl-*` tokens (record which):

- **Minified** — read-only output (a second minimal CodeMirror with the WGSL
  mode, `EditorState.readOnly`), miniray's stats bar and copy button, and
  the option pills: Whitespace / Identifiers / Syntax / Mangle bindings /
  Tree shaking. Recompute on option change and on a 300 ms debounce of
  editor changes (one shared debounce with the LSP `didChange` pacing).
- **Reflection** — the `buildReflectModel` tables; monospace, plus a
  "raw JSON" `<details>`.
- **Diagnostics** — the formatted list; clicking a row moves the editor
  cursor to the range (this is DOM wiring, thin by design).

**Gate:** `pnpm test` green (both suites) + `pnpm build` + hand check:
toggling "Tree shaking" makes the dead helper reappear in the minified
output, and the stats bar tracks it.

---

## Block 4 — the LSP showpieces: insights inlay hints, rename, format

*Fresh-session context: `/playground/` now has a working editor + three
panels. The LSP serves `inlayHint`, `rename`/`prepareRename`, `formatting`,
`signatureHelp` (`lsp/wasm.zig:100-133`). Minify-insight hints require
config `{ "lsp": { "minifyMode": "insights" } }` delivered as the response to
the server's `workspace/configuration` request (`lsp/wasm/lifecycle.zig:47-65`,
schema note at `lsp/Handler.zig:56-60`).*

1. Extend `tests/lsp-flow.test.mjs` first (red): after answering the config
   request with `{ lsp: { minifyMode: "insights" } }`, a
   `textDocument/inlayHint` request over the whole document returns hints
   whose labels carry byte counts; a `textDocument/rename` of `computeColor`
   returns a WorkspaceEdit touching every reference; `textDocument/formatting`
   returns edits on a deliberately misindented document.
2. Wire config: `lsp-client.ts`'s configuration answer becomes a small
   settings store; the UI adds one toggle pill — "Minify insights" — that
   flips `minifyMode` between `"off"` and `"insights"` and pokes the server
   (`workspace/didChangeConfiguration` triggers its re-fetch).
3. **Probe** `@codemirror/lsp-client` for inlay-hint support. If absent:
   request `textDocument/inlayHint` through `sendMessage` after each
   debounced change and render as CodeMirror inline decorations (a small,
   self-contained ViewPlugin). Rename and format: prefer the client
   library's commands; fallbacks are `prepareRename`/`rename` via
   `sendMessage` + applying the WorkspaceEdit as a CodeMirror transaction,
   and a "Format" button doing the same with `formatting` edits.
4. Page copy on `/playground/` gains a one-line "try this" list: hover a
   builtin, rename a function (F2), toggle Minify insights and watch
   per-declaration byte estimates appear.

**Gate:** `pnpm test` + `pnpm build` + hand check of all three features in
the browser, both themes.

---

## Block 5 — page truth pass and the full gate

*Fresh-session context: the playground is functionally complete on
`/playground/`. What's left is making the rest of the site point at it and
making the docs stop lying.*

1. `index.mdx`: hero action #1 becomes "Try the playground" → `/playground/`
   (replacing the dead "Example Guide" starter link); the CardGrid keeps its
   copy but the minifier/validator/LSP cards gain links into the playground.
   Leave the commented-out starter cards; delete the "Read the Starlight
   docs" action or point it at the GitHub repo — pick one, record it.
2. `web/README.md`: replace the starter README's structure section with the
   real one (playground modules, test command, the `file:` dependency note
   and its consequence: `pnpm install` must run *after* the packages exist
   on disk — true in every fresh clone).
3. `web/AGENTS.md`: append the two commands agents will need:
   `pnpm test` (Node suites) and the wasm-refresh pair from Block 1, with
   the rule that a wire-affecting Zig change requires rebuilding both wasms
   before trusting playground behavior (the npm-wasm staleness rule).
4. Full gate, in order: `cd web && pnpm test && pnpm build`, then
   `zig build test` from the repo root (`-j1` if the corpus suites run) to
   prove the wasm rebuild in Block 1 didn't ride on a broken tree, then a
   final hand pass over `/playground/` with `astro dev --background`.
5. Update this plan's **Status** to executed, with the commit list and every
   probe outcome (lsp-client version + which fallbacks were needed, `?url`
   vs `public/` wasm serving, Tabs vs buttons), following the
   `rust-examples.md` convention.

---

## Behavior changes (explicit)

- **None to the Zig library, CLI, native LSP, or any package's JS API.**
  The playground only consumes published surfaces.
- **The checked-in wasm binaries may change bytes** (Block 1 refresh). That
  changes what the unpublished npm packages would ship. It lands as its own
  commit so it can be reverted independently of the web work.
- `web/package.json` gains runtime dependencies (codemirror family) and two
  `file:` links — a fresh clone must build nothing, but `pnpm install` in
  `web/` now depends on the sibling package dirs existing.
- `astro.config.mjs` may gain a `vite.server.fs.allow` entry (dev-server
  only; no effect on builds).

## Definition of done

- [ ] `/playground/` renders inside the Starlight shell, both themes, mobile
      column collapse included, with zero custom color values (only `--sl-*`).
- [ ] Editor: WGSL highlighting (nested comments included), live diagnostics
      with codes, hover, completion, go-to-definition, rename, formatting.
- [ ] Panels: minified output with option pills + stats + copy; reflection
      tables + raw JSON; clickable diagnostics list.
- [ ] Minify-insights inlay hints toggle on and show per-declaration bytes.
- [ ] `cd web && pnpm test` — headless LSP session + panel models, green.
- [ ] `cd web && pnpm build` — green.
- [ ] Both wasm binaries rebuilt from the tree that shipped them, committed.
- [ ] `index.mdx` hero links to the playground; no starter links remain.
- [ ] This file's Status records commits + probe outcomes.
