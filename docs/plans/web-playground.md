# Plan — `web/`: a playground page that runs the toolkit in the browser

**Creates:** one Starlight page (`/playground/`) hosting a CodeMirror 6 editor
wired to `wgslender-lsp.wasm`, three result panels driven by `wgslender.wasm`,
a handful of framework-free TypeScript modules, and a `node --test` suite that
drives both wasm builds headlessly. The page demonstrates, live and offline:
validation + lint diagnostics, hover / completion / go-to-definition / rename /
format / signature help, minify-insight inlay hints, option-driven minification
with byte **and gzip** stats, and reflection JSON.

**Motivation:** `web/src/content/docs/index.mdx:23-38` claims five capabilities
and demonstrates none, and its hero still links to the Starlight starter guide.
Every capability already runs in a browser — both wasm builds are checked in and
wrapped. The reference experience is miniray's playground (`~/Dev/miniray/web/`):
two panels, live debounced minification, option pills, a stats bar, one screen,
no framework. This is that, upgraded from `<textarea>` to a real editor, because
wgslender — unlike miniray — has a language server to show off.

**Status:** Blocks 1-4 executed 2026-08-06/07 — `cb313d7` wasm refresh,
`37a25e4` deps + tests, `283771a` the editor island, `d18ae43` the browser
smoke check, `e20ab6e` two npm type-declaration fixes, `8e8752b` the panel
models, `09b3a74` the panel UI, `e7ae464` the inlay-hint/rename/format wire
tests, `dba5c76` the Starlight rhythm fix, `c49a6f1` minify insights,
`afa04ac` the page copy. Block 5 pending. Outcomes worth carrying
forward:

- Installed versions: `@codemirror/lsp-client` 6.2.5, `codemirror` 6.0.2,
  `@codemirror/{state 6.7.1, view 6.43.8, language 6.12.4, lint 6.9.7,
  autocomplete 6.20.3}`. Both `file:` packages sit in `dependencies` (they are
  imported by client code), not `devDependencies`.
- The checked-in LSP wasm **was** stale (889,523 → 891,897 bytes);
  `packages/js-npm/wgslender.wasm` rebuilt byte-identical.
- Every predicted code held: `W0001` on the unused helper from `didOpen`,
  `E0206` on a bad member access, clearing on revert.
  `wgslender.showMinifiedOutput` returns `gz_count` well under `byte_count`.
- **Sizes are UTF-8 bytes, not JS string units.** The sample's comments contain
  an em dash, so `minify().originalSize !== source.length`. The stats bar must
  use `new TextEncoder().encode(src).length`.
- Without tree shaking the dead helper survives under a *renamed* identifier
  (`fn o(a:f32)->f32{return a*a*a;}`) — assert on its body, not its name.
- A fresh worktree has an empty `external/lsp-kit` (submodule); `zig build`
  panics with "unable to find module 'lsp'" until it is rsync'd in from the
  main checkout.
- `pnpm build` was **already failing** on the starter `index.mdx`, which used
  an HTML comment (`<!-- -->`) that MDX rejects. Converted to `{/* */}` in
  Block 1 so the gate means something.

From Block 2:

- pnpm 10.31 **does** run `pre`/`post` scripts (the `enable-pre-post-scripts`
  default flipped back), so the planned `predev`/`prebuild` hooks work as
  written. Verified by probe, not assumed.
- `template: splash` instead of the planned bare `tableOfContents: false`.
  Starlight's content column is 45rem with a sidebar and 67.5rem without
  (`components/Page.astro:57`, `html:not([data-has-sidebar])`), and two panes
  do not fit in 45rem. The sidebar entry still lists the page.
- Two files beyond the target layout: `editor-theme.ts` (CodeMirror builds its
  DOM at runtime, so Astro's scoped styles cannot reach it — it needs
  `EditorView.theme()`, and that is presentation, not syntax) and
  `scripts/smoke.mjs`. `@lezer/highlight` became a direct dependency because
  the theme imports `tags` from it.
- `syntaxHighlighting(style)` without `fallback` outranks the one `basicSetup`
  installs — they land in different facets (`language/dist/index.js:1734`), so
  no `Prec` juggling is needed.
- **`refreshInsights()` is not debounced inside `lsp-session.ts`.** Block 3
  wants one timer driving panels + insights + this notification; two debounce
  points would stack. The caller owns the timer.
- The editor pane must not scroll. CodeMirror owns its own scroller, and a
  second one on the wrapper offsets every coordinate `scrollIntoView`, hover
  and click resolve against. Found by the smoke check, fixed in `283771a`.
- **Hover is wired but was not observed in a browser.** The server answers
  `textDocument/hover` at both declarations and uses (probed directly), and
  `hoverTooltips()` is in the same `languageServerExtensions()` array that
  produced working completions and diagnostics — but synthetic CDP mouse
  events never satisfied CodeMirror's `posAtCoords` bounds check, so no
  tooltip could be provoked headlessly. Worth ten seconds of a human's time
  before Block 5 signs off.

From Block 3:

- **Both themes are now confirmed** by screenshot (the Block 2 caveat above is
  closed). Everything is `--sl-*` tokens, so light and dark follow the toggle
  with no JS. Hover remains the one unobserved item.
- Starlight's `<Tabs>` won over hand-rolled buttons. `processPanels`
  (`user-components/rehype-tabs.ts`) only rewrites `<starlight-tab-item>`
  wrappers and `SKIP`s their children, so island markup and Astro's scoped
  class both survive `Astro.slots.render()`. Two rules are needed to host them
  in a fixed-height pane — see the next two bullets, both of which shipped
  broken until the page was looked at.
- **`display: flex` on `[role=tabpanel]` silently disables `hidden`.** The UA
  stylesheet implements `hidden` as `display: none`; any `display` rule of
  yours outranks it, and all three panels stack. Needs an explicit
  `[role='tabpanel'][hidden] { display: none }`.
- **An `overflow-x: auto` box has no min-content height**, so as a flex child
  it shrinks to nothing. The reflection tables all collapsed while the
  headings between them still rendered. Only the minify tab is a flex column
  (its editor must absorb leftover height); the table panels stay block-level
  and simply scroll.
- Both bugs were invisible to the smoke check, which asserted on
  `textContent` — present in the DOM, zero pixels on screen. It now measures
  `getBoundingClientRect()` for panel visibility and table rows. **Assert
  layout, not presence**; and screenshot the page, because neither bug
  survived one look at it.
- **The gzip column is computed client-side with `CompressionStream`**, not
  read from `wgslender.showMinifiedOutput` as this plan assumed. That command
  takes only a URI, so it minifies with the *server's* settings; the moment a
  pill is toggled its number would describe different bytes than the ones on
  screen. `showMinifiedOutput()` stays on the `Session` (Block 1 pins it) but
  nothing calls it now.
- Diagnostics reach the panel through a second `transport.subscribe` handler.
  The transport fans out to every handler, so this costs nothing and hands
  `formatDiagnostics` the exact payload its tests pin, rather than the
  narrowed shape lsp-client passes to `@codemirror/lint`.
- Two `packages/js-npm/lib/main.d.ts` declarations did not match the wire
  (`e20ab6e`), both found by writing TypeScript against them: `TypeInfo`'s
  texture variant is flat (`{kind, dim, texKind, …}`), not
  `{kind, texture: {...}}` — reading `typeInfo.texture.dim` throws — and
  `MinifyError.line`/`.column` are never emitted, since `writeMinifyJson`
  serializes only `message`. Populating them would be a wire change; left as a
  decision.
- `pnpm`'s `file:` dependencies are **copies in the virtual store**, not links.
  Editing `packages/js-npm` does nothing for `web/` until `pnpm install` runs
  again.
- `minifyIdentifiers` and `treeShaking` are independent: the dead helper is
  dropped either way. A test asserting it survives with renaming off is wrong.

Facts below were verified against the worktree and against the actual npm
tarball of `@codemirror/lsp-client` on 2026-08-06. File:line references are
evidence, not decoration.

---

## Verified current state (do not re-derive)

### `web/` is an untouched Starlight starter

`astro.config.mjs` (title `'My Docs'`, social link → withastro/starlight,
starter sidebar), `package.json` (astro `^7.0.2`, `@astrojs/starlight`
`^0.41.6`, sharp; pnpm, `pnpm-workspace.yaml` has only an `allowBuilds` block),
`src/content/docs/{index.mdx,guides/example.md,reference/example.md}`,
`src/content.config.ts`, `tsconfig.json`, `public/favicon.svg`,
`src/assets/houston.webp`, `.gitignore`, `README.md` (starter text),
`AGENTS.md`. **`web/CLAUDE.md` is a symlink to `web/AGENTS.md`** — edit the
one file. Its rule: start the dev server with `astro dev --background`, manage
with `astro dev stop|status|logs`.

Local node is **v26.7.0**: `node --test <dir>` is broken there, use a glob
(`node --test 'tests/*.test.mjs'`) — same trap hit by `examples/js-ts`.

### The two packages are on disk, not on the registry

`wgslender` 1.1.0 (`packages/js-npm/`, ships `wgslender.wasm`, 767 KB) and
`wgslender-lsp` 1.1.0 (`npm/wgslender-lsp/`, ships `wgslender-lsp.wasm`,
890 KB) are unpublished, so `web/package.json` must use `file:` deps:

```json
"wgslender": "file:../packages/js-npm",
"wgslender-lsp": "file:../npm/wgslender-lsp"
```

Both expose the binary as a `./wasm` export condition
(`packages/js-npm/package.json` `"./wasm": "./wgslender.wasm"`, same shape in
`npm/wgslender-lsp/package.json`), so `createRequire(import.meta.url)
.resolve('wgslender/wasm')` yields a real path in Node.

`wgslender-lsp.initialize()` with no arguments resolves its wasm **via
`fetch`**, which fails on `file:` URLs under Node — Node callers must pass
`wasmModule` compiled from `fs.readFile` bytes.

### `@codemirror/lsp-client` is 6.2.5 — stable, and its surface is known

Verified by unpacking the tarball. It exports `LSPClient`, `LSPPlugin`,
`languageServerSupport(client, uri, languageID)`,
`languageServerExtensions()` = `[serverCompletion(), hoverTooltips(),
keymap.of([...formatKeymap, ...renameKeymap, ...jumpToDefinitionKeymap,
...findReferencesKeymap]), signatureHelp(), serverDiagnostics()]`, plus the
individual commands (`formatDocument`, `renameSymbol`, `jumpToDefinition`,
`jumpToTypeDefinition`, `findReferences`, `showSignatureHelp`) and
`client.request(method, params)` / `client.notification(method, params)` for
anything custom. Its `Transport` type is exactly `{send, subscribe,
unsubscribe}` — the shape `wgslender-lsp`'s `createTransport()` returns.

Four consequences that shape this plan:

1. **Push diagnostics are handled for us.** `serverDiagnostics()` registers a
   `textDocument/publishDiagnostics` notification handler that dispatches
   `setDiagnostics` into the view. It drops a payload whose `params.version`
   mismatches the client's file version — our server never emits `version`
   (`lsp/wasm/diagnostics.zig:52-57`), so the check is a no-op. No fallback
   renderer needed.
2. **No inlay hints, no semantic tokens, no code lens.** Those are ours to
   write, over `client.request(...)`. The minify-insight hints — the flagship
   demo — were always going to be custom anyway.
3. **It does not advertise `workspace.configuration`** (default capabilities
   cover completion, hover, formatting, rename, signatureHelp, definition,
   declaration, implementation, typeDefinition, references, diagnostic,
   window.showMessage — nothing under `workspace`). Our server only sends the
   `workspace/configuration` request when the client advertised it
   (`lsp/wasm/lifecycle.zig:47-49`), so it never asks and nothing hangs — but
   it also means **settings cannot be pushed through lsp-client's config path**.
   Use the executeCommand route instead (below).
4. **Synchronous responses are safe.** `requestInner` pushes the pending
   request onto `this.requests` *before* calling `transport.send`, and
   `createTransport().send()` fans the `sendMessage()` return array out to
   subscribers inline (`npm/wgslender-lsp/index.mjs:95-102`). A response that
   arrives during `send` still finds its request.

`codemirror` (the meta-package with `basicSetup`) is 6.0.2.

### What the WASM LSP serves

Dispatch table, `lsp/wasm.zig:99-134`: `initialize`, `initialized`,
`shutdown`, `exit`, `textDocument/did{Open,Change,Close,Save}`,
`workspace/didChangeConfiguration`, `textDocument/` `codeAction`, `hover`,
`definition`, `references`, `documentHighlight`, `rename`, `prepareRename`,
`completion`, `signatureHelp`, `documentSymbol`, `foldingRange`,
`typeDefinition`, `inlayHint`, `codeLens`, `formatting`,
`semanticTokens/full`, `selectionRange`, `prepareCallHierarchy`,
`callHierarchy/{incoming,outgoing}Calls`, `diagnostic` (pull),
`workspace/executeCommand`, and three custom methods: `wgslender/reflect`,
`wgslender/constInventory`, `wgslender/recomputeMinifyInsights`.

Advertised capabilities (`lsp/Handler.zig:152-154`): `textDocumentSync.change
= 2` (**incremental** — lsp-client sends ranged changes, and the WASM handler
accepts both ranged and full-text forms, `lsp/wasm/document_sync.zig:47-66`),
`positionEncoding = "utf-16"` (matches CodeMirror's JS-string offsets
natively), and `executeCommandProvider.commands = ["wgslender.setMinifyMode",
"wgslender.toggleMinifyMode", "wgslender.recomputeMinifyInsights"]`.

Four flow facts that shape the design:

1. **Diagnostics are pushed synchronously.** `handleDidOpen` /
   `handleDidChange` call the emitters inline
   (`lsp/wasm/document_sync.zig:34,69`), so every `sendMessage` batch for those
   notifications already carries `publishDiagnostics`. There is no server-side
   debounce in the WASM build (`lsp/Debouncer.zig`: "WASM debounces JS-side")
   — pacing is the client's job.
2. **The edit hot path publishes *cheap* diagnostics.** `didChange` runs
   `emitDiagnosticsCheap` = validator + the general lint packs, **without** the
   minify-lint / estimator pass. The comment at
   `lsp/wasm/document_sync.zig:66-68` states the contract: *the JS client
   schedules `wgslender/recomputeMinifyInsights` after typing settles*. That
   notification (`{textDocument:{uri}}`, `lsp/wire/primitives.zig:58-62`)
   refreshes the estimator and re-emits full diagnostics
   (`lsp/wasm/workspace_commands.zig:31-35`). The playground must implement
   that half of the protocol.
3. **Minify mode flips by command, not by settings.**
   `workspace/executeCommand` with `wgslender.setMinifyMode` +
   `["insights"|"strict"|"off"]` sets it server-side
   (`lsp/handler/commands.zig:62-71`), and the WASM adapter republishes every
   open document afterwards (`lsp/wasm/workspace_commands.zig:161-164`). Modes
   come from `MinifySettings.Mode` (`src/MinifySettings.zig:11-22`). Inlay
   hints are on by default (`Handler.inlayHintsEnabled()` → `true`), and the
   minify-size lane only fires when the effective mode is `insights`/`strict`.
4. **`wgslender.showMinifiedOutput` is routed in WASM even though it is not in
   the advertised command list** (`lsp/wasm/workspace_commands.zig:123-148`).
   Args `[uri]`; result `{uri, minified_text, byte_count, gz_count}`
   (`lsp/wire/workspace_commands.zig:17-31`). **`gz_count` is a real gzip
   count from the server** — that is where the stats bar's gzip column comes
   from, backing the README's 5-29 % compression claim without shipping a JS
   gzip.

`wgslender/reflect` takes `{textDocument:{uri}, format?: "v1"|"v2",
pretty?: bool}` (`lsp/wasm/workspace_commands.zig:37-78`).

### `wgslender` (minifier package) browser API

`initialize({wasmURL?|wasmModule?})` then `minify(source, opts) → {code,
errors, originalSize, minifiedSize}`. Options (`packages/js-npm/lib/main.d.ts:1-77`):
`minifyWhitespace|minifyIdentifiers|minifySyntax` (default true),
`mangleExternalBindings|treeShaking|preserveUniformStructTypes|keepNames|
sortDeclarations|scopeLocalRename|sourceMap` — `sortDeclarations` and
`scopeLocalRename` are the compression-friendly pair (default false, documented
5-29 % gzip savings). Also `reflect(source)` → v2 shape (`bindings`, `uniforms`,
`storage`, `textures`, `samplers`, `structs`, `entryPoints`, `overrides`,
`functions`, `aliases`), `validate`, `lint(source, {extends, rules})` with the
packs `@wgslender/{recommended,style,performance,portability,strict}`,
`compile`, `getVersion` (`main.d.ts:498-875`).

### Diagnostic codes the sample shader will produce

`W0001` unused var (`src/Diagnostic.zig:897`), `W0003` unused binding
(`:899`), `E0206` no-such-member (`:805`). LSP lint is **on by default** with
`@wgslender/recommended` (`lsp/handler/diagnostics.zig:163,235-245`), so an
unused function warns without any client configuration.

### What to take from miniray, and what not to

**Take:** two-panel grid collapsing to one column under 768 px; 300 ms input
debounce; option pills (`label` wrapping a checkbox, `:has(input:checked)`
highlight); stats bar; copy button with a 1.5 s "Copied!" flash; a default
shader on load so the page demos itself; one plain state object with pure
render-from-state.
**Leave:** boreDOM, the `<textarea>`, the Go wasm polling loop, and miniray's
`--color-*` tokens — Starlight already ships a theme, so use `--sl-*`
variables and get dark/light for free.

---

## Design rules

- **Two wasms, one job each.** `wgslender-lsp.wasm` owns everything
  *positional* (diagnostics, hover, completion, definition, rename, format,
  inlay hints) plus insights and gzip counts. `wgslender.wasm` owns everything
  *option-driven* (the minify pills, reflection tables) — the LSP's minify
  command takes no options, and `minify()`/`reflect()` are the API a visitor
  would actually call from JS. Say this in the page copy; it is the honest
  story of the toolkit.
- **lsp-client for the standard features, our code for the wgslender ones.**
  Never reimplement what `languageServerExtensions()` already does. Inlay
  hints, the minify/reflect panels and the insights toggle go through
  `client.request` / `client.notification`.
- **No UI framework.** One `.astro` component, plain TypeScript modules,
  CodeMirror 6 as the only editor dependency.
- **Starlight tokens only.** Scoped styles using `--sl-color-*` / `--sl-font-*`.
  No new palette, no global CSS. The page must look native in both themes.
- **Logic outside the DOM.** Anything testable under Node — LSP message flow,
  panel models, debounce policy, stats math — lives in
  `web/src/scripts/playground/` as pure modules; the `.astro` `<script>` is
  wiring only. That is what makes a web page TDD-able.
- **TDD, reds first.** Tests are written and observed failing before the
  implementation. Gate per block: `cd web && pnpm test`
  (`node --test 'tests/*.test.mjs'`) plus `pnpm build` (catches SSR/import
  errors Node tests can't), then a hand pass in the browser. **No CI** — the
  gate is local and on demand, deliberately.
- Conventional commits, one block ≈ one commit (Block 1 may be two: wasm
  refresh, then deps + tests).

### Out of scope

- Publishing any package (an open, user-owned decision).
- The binary-shader `compile` panel and any WebGPU canvas preview. This page
  demos the *toolchain*; compute.toys already exists for shader art.
- Multi-file workspaces, call hierarchy / code lens / folding UI, source maps.
- Site branding beyond the two-line truth fix in Block 5.

---

## Target layout

```
web/
  package.json                 # + file: deps, codemirror deps, test/sync scripts
  astro.config.mjs             # + sidebar entry, title fix
  scripts/sync-wasm.mjs        # Block 1: copy both .wasm into public/
  tests/
    lsp-flow.test.mjs          # Block 1 (grows in Block 4): headless LSP session
    panels.test.mjs            # Block 3: minify/reflect/diagnostic models
  src/
    components/
      PlaygroundEditor.astro   # Blocks 2-4: markup + scoped styles + boot script
    scripts/playground/
      sample-shader.ts         # Block 1: the default shader (tests + UI share it)
      wgsl-language.ts         # Block 2: StreamLanguage WGSL mode
      lsp-session.ts           # Block 2: transport, client, protocol extras
      wasm.ts                  # Block 2: init both wasms from /public URLs
      panels.ts                # Block 3: pure panel-model builders
      insights.ts              # Block 4: inlay-hint ViewPlugin + mode toggle
    content/docs/
      playground.mdx           # Block 2: the page (grows through Block 5)
```

---

## Block 1 — packages wired, wasm fresh, headless LSP session green

*Fresh-session context: `web/` is a pristine Starlight starter on pnpm; the two
local packages (`../packages/js-npm`, `../npm/wgslender-lsp`, both 1.1.0,
unpublished) each ship a checked-in `.wasm`. Everything about their APIs and
the LSP wire protocol is in "Verified current state" above.*

**Write the sample shader first** — `src/scripts/playground/sample-shader.ts`,
exporting `export const sampleShader = String.raw\`…\``. It is the fixture for
every test and the editor's initial document, so it must earn every panel:

- a uniform struct with mixed field types (reflection layout: offsets, size,
  align) and a storage buffer of a second struct;
- an `override` declaration (reflection `overrides`);
- a texture + sampler pair, both actually sampled (so they appear as bindings
  without adding a W0003);
- one helper function called from an entry point (hover / definition / rename
  targets) and one uncalled helper (W0001 + visible tree-shaking);
- a `@vertex` and a `@fragment` entry point (reflection `entryPoints`, stage +
  IO).

Pin its expected diagnostics with the repo's own CLI before trusting it:
`zig build && ./zig-out/bin/wgslender lint <sample>` should report exactly the
one W0001, and `validate` should be clean. A sample that surprises the linter
poisons every later assertion.

**Red.** Add `"test": "node --test 'tests/*.test.mjs'"` to `web/package.json`
and write `web/tests/lsp-flow.test.mjs`:

1. Initialize `wgslender-lsp` with a `wasmModule` compiled from the bytes at
   `createRequire(import.meta.url).resolve('wgslender-lsp/wasm')` (the
   `fetch(file:)` trap), and `wgslender` alongside it.
2. Drive a session over `sendMessage` directly (no CodeMirror in Node):
   `initialize` → `initialized` → `didOpen` with the sample. Assert the
   returned batch contains a `textDocument/publishDiagnostics` for the URI
   carrying `W0001` on the unused helper.
3. `didChange` (full-text form) mutating a struct member access to a
   nonexistent field → assert `E0206` appears; change it back → assert it
   clears.
4. `textDocument/hover` over the uniform variable returns non-empty contents;
   `textDocument/definition` on the called helper points at its declaration.
5. `workspace/executeCommand` `wgslender.showMinifiedOutput` with `[uri]`
   returns `minified_text`, `byte_count`, and a **`gz_count` smaller than
   `byte_count`**.
6. Package-side: `minify(sample)` shrinks the source and drops the unused
   helper from `code`; `reflect(sample)` reports the uniform + storage
   bindings, the texture/sampler, the override, and both entry points.

Keep the JSON-RPC plumbing (id counter, `send(method, params)` →
parsed-responses, `notify`) in one small helper at the top of the file; Block 4
extends the same session.

Run `pnpm test`: red on unresolvable imports.

**Green.**

1. Rebuild both wasms from this tree and copy them in, exactly as the
   packages' own `prepublishOnly` scripts do — from the repo root:
   `zig build wasm -Doptimize=ReleaseSafe && cp zig-out/bin/wgslender.wasm
   packages/js-npm/` and `zig build lsp-wasm -Doptimize=ReleaseSafe &&
   cp zig-out/bin/wgslender-lsp.wasm npm/wgslender-lsp/`. If `git status`
   shows changed bytes, commit that refresh **on its own** (see Behavior
   changes). If it shows nothing, say so in the commit message for the deps
   commit — "checked-in wasm verified current" is a fact worth recording.
2. Add to `web/package.json`: the two `file:` deps, `codemirror` (^6.0.2),
   `@codemirror/{state,view,language,lint,autocomplete}`,
   `@codemirror/lsp-client` (^6.2.5). `pnpm install`.
3. `pnpm test` until green. Where a message or code differs from what this
   plan predicted, pin what the server actually says and note it in Status.

**Gate:** `cd web && pnpm test` green; `pnpm build` still green.

---

## Block 2 — the editor island: CodeMirror + WGSL mode + live diagnostics

*Fresh-session context: Block 1 landed `file:` deps, codemirror deps, a green
`tests/lsp-flow.test.mjs`, and `sample-shader.ts`. `@codemirror/lsp-client`
6.2.5 gives completion, hover, format, rename, signature help, jump-to-def,
find-references and push-diagnostic rendering via `languageServerExtensions()`;
`createTransport()` matches its `Transport` type. Server sync is incremental
with utf-16 positions. Dev server: `astro dev --background` per
`web/AGENTS.md`.*

1. `scripts/sync-wasm.mjs` + `"predev"`/`"prebuild"` hooks: resolve
   `wgslender/wasm` and `wgslender-lsp/wasm` via `createRequire` and copy both
   into `web/public/`. Add `public/*.wasm` to `web/.gitignore`. This is the
   deliberate choice over `import … from 'wgslender/wasm?url'`: Vite resolving
   a `?url` export subpath across a pnpm `file:` symlink is exactly the kind of
   thing that breaks between versions, and a copy step keeps the wasm-freshness
   rule mechanical. (If a later session wants `?url`, it must delete the sync
   script, not stack the two.)
2. `src/scripts/playground/wasm.ts` — `initPlayground()` initializes both
   packages in parallel from `/wgslender.wasm` and `/wgslender-lsp.wasm`,
   returning a promise per package so the editor can come up before the
   minifier lands (~1.6 MB of wasm total — never block first paint on both).
3. `src/scripts/playground/wgsl-language.ts` — a `StreamLanguage.define` WGSL
   mode: keyword / type / builtin lists lifted from `src/Lexer.zig` (do not
   invent them; `private`, `uniform`, `storage`, `read`, `write`, `read_write`
   are address-space/access words, *not* reserved), `//` comments and **nesting
   `/* */` comments** (WGSL nests them — the mode must count depth), numeric
   literals with suffixes, `@attributes`. Give the `Language` the name `wgsl`
   so lsp-client derives the right `languageID`. Highlighting works before any
   wasm arrives; semantic tokens are a possible future enhancement, not a
   dependency.
4. `src/scripts/playground/lsp-session.ts` — `createSession()`: `initialize()`
   → `createTransport()` → `new LSPClient({extensions:
   languageServerExtensions()})` → `client.connect(transport)`, and returns
   `{client, uri, extension: client.plugin(uri)}` plus two wgslender-specific
   helpers used from Block 3 on: `refreshInsights()` (the debounced
   `wgslender/recomputeMinifyInsights` notification the server's hot path
   expects) and `showMinifiedOutput()` (the executeCommand round-trip returning
   `byte_count`/`gz_count`).
5. `src/components/PlaygroundEditor.astro` — server-rendered shell: a
   `<pre>` holding the sample shader (so the page is readable with JS off and
   there is no layout jump), the two-column grid (`1fr 1fr`, one column under
   768 px), a status line, and an empty right pane for Block 3. Its `<script>`
   dynamically imports the boot module and replaces the `<pre>` with a
   CodeMirror view (`basicSetup` + WGSL mode + the LSP extension).
6. `src/content/docs/playground.mdx` — `title: Playground`,
   `tableOfContents: false`, renders `<PlaygroundEditor />`, one line of copy:
   everything on this page runs in your browser, no server. Add
   `{ label: 'Playground', slug: 'playground' }` to the sidebar in
   `astro.config.mjs`.

**Hand verification:** breaking a member access squiggles `E0206` within a
keystroke; the unused helper carries its `W0001` squiggle on load; hover shows
types; `Ctrl-Space` after `.` completes struct fields; both themes look native;
mobile width collapses to one column.

**Gate:** `pnpm test` (Block 1 suite still green) + `pnpm build`.

**Executed** (`283771a`, `d18ae43`): `pnpm test` 17/17, `pnpm build` green,
`pnpm smoke` 10/10. Everything above verified in a real browser except hover
and the two themes — see Status. `web/tests/wgsl-language.test.mjs` pins the
mode (nested comments across lines, suffixed literals, builtin vs user call vs
member access); `web/scripts/smoke.mjs` pins the wiring.

---

## Block 3 — the working panels: minify, reflect, diagnostics

*Fresh-session context: Blocks 1-2 landed the editor island with live LSP
diagnostics on `/playground/`. `wasm.ts` already initializes the minifier
package; nothing calls `minify`/`reflect` yet. `lsp-session.ts` exposes
`showMinifiedOutput()` for the gzip number. miniray's playground is the UX
reference.*

**Red.** `web/tests/panels.test.mjs` against a new pure module
`src/scripts/playground/panels.ts`, run against the real wasm:

- `buildMinifyModel(source, opts)` → `{code, stats: {original, minified,
  savedPct}, errors}`. Assert on the sample: default options shrink it and drop
  the unused helper; `treeShaking: false` keeps it; `mangleExternalBindings:
  false` (the default) keeps the binding's original name in `code`;
  `minifyIdentifiers: false` keeps the called helper's name; enabling
  `sortDeclarations + scopeLocalRename` changes `code` without changing what
  `reflect` reports about it.
- `buildReflectModel(source)` → grouped rows: uniforms / storage / textures /
  samplers with group+binding, entry points with stage (and workgroup size when
  present), struct fields with offset/size/align, overrides. Assert the
  sample's uniform struct field offsets — those numbers are the reflection
  engine's whole point.
- `formatDiagnostics(payload)` → rows `{severity, code, line, col, message}`
  sorted errors-first, then by position; feed it a `publishDiagnostics` payload
  captured from the Block 1 session.

**Green.** Implement `panels.ts` (pure, no DOM), then wire the right pane in
`PlaygroundEditor.astro` as three tabs. Prefer Starlight's `<Tabs>`/`<TabItem>`
from `@astrojs/starlight/components` if they compose with island content;
otherwise three buttons styled with `--sl-*` tokens — record which won.

- **Minified** — read-only CodeMirror (same WGSL mode, `EditorState.readOnly`),
  option pills (Whitespace / Identifiers / Syntax / Mangle bindings / Tree
  shaking / Sort declarations / Scope-local rename), miniray's stats bar
  extended with a **gzip column** fed by `showMinifiedOutput()`'s `gz_count`,
  and a copy button with the "Copied!" flash. Recompute on pill change and on
  the shared 300 ms debounce.
- **Reflection** — `buildReflectModel` tables in monospace, plus a raw-JSON
  `<details>`.
- **Diagnostics** — the formatted rows; clicking one moves the editor cursor to
  that position (thin DOM wiring by design).

One debounce drives all three: on it, run `minify` + `reflect` on the current
document and fire `refreshInsights()`. Ordering matters — the LSP's `didChange`
already fired synchronously on keystroke (cheap diagnostics); this pass is the
expensive half the server explicitly defers to the client.

**Gate:** `pnpm test` (both suites) + `pnpm build` + hand check: toggling
"Tree shaking" makes the unused helper reappear and the stats bar move; the
gzip number tracks the sort/scope pills.

**Executed** (`e20ab6e`, `8e8752b`, `09b3a74`): `pnpm test` 35/35, `pnpm build`
green, `pnpm smoke` 27/27. The hand check is automated — the smoke script
toggles the pills and asserts both that the helper's body reappears and that
the gzip figure moves (407 B → 403 B with sort + scope-local rename on), then
clicks a diagnostic row and checks the editor's active line. `panels.ts` is
pure and tested against the real wasm; `render.ts` builds DOM with
`textContent` throughout, since every string on the page comes from whatever
the visitor typed.

---

## Block 4 — the wgslender showpiece: minify insights

*Fresh-session context: `/playground/` has a working editor plus three panels.
Minify-size inlay hints exist server-side (`lsp/handler/inlay_hints.zig`,
`kind = minify_size`, each carrying an "approximate" tooltip) but only fire
when the effective mode is `insights` or `strict`. The mode flips via
`workspace/executeCommand` `wgslender.setMinifyMode` with
`["insights"|"strict"|"off"]` — lsp-client cannot push settings, so the command
is the route. `@codemirror/lsp-client` has no inlay-hint support; this is ours.*

1. **Red first**, extending `tests/lsp-flow.test.mjs`: with mode `off`, a
   whole-document `textDocument/inlayHint` returns no `minify_size`-flavoured
   hints; after `wgslender.setMinifyMode ["insights"]`, hints come back with
   byte counts in their labels and a tooltip; after `["off"]` they disappear.
   Also pin `textDocument/rename` of the called helper (a WorkspaceEdit
   touching every reference) and `textDocument/formatting` on a deliberately
   misindented document.
2. `src/scripts/playground/insights.ts` — a CodeMirror `ViewPlugin` that, on
   the shared debounce, requests `textDocument/inlayHint` for the visible range
   and renders the results as inline widget decorations (position mapped from
   LSP utf-16 line/char, tooltip on hover). Keep it small and self-contained;
   it is the one place we implement an LSP feature the client library lacks.
3. A "Minify insights" toggle pill sends the executeCommand, then
   `refreshInsights()`, then re-requests hints. The server republishes
   diagnostics for every open document after the command, so M-code minify
   lints appear in the Diagnostics panel at the same moment the hints do —
   check that they do.
4. Page copy gains a short "try this" list: hover a builtin, F2-rename a
   function, toggle Minify insights and watch per-declaration byte estimates
   appear next to each declaration.

**Gate:** `pnpm test` + `pnpm build` + hand check of hints, rename and format
in the browser, both themes.

**Executed** (`e7ae464`, `dba5c76`, `c49a6f1`, `afa04ac`): `pnpm test` 50/50,
`pnpm build` green, `pnpm smoke` 39/39. The hand checks are automated — smoke
drives the toggle, F2 and Shift-Alt-f, and asserts geometry rather than
`textContent`. Both themes confirmed by screenshot.

Corrections to this block's predictions, all found by probing the live server
before writing assertions:

- **The toggle sends `strict`, not `insights`.** Step 3 wanted the M-code
  minify lints to appear with the hints; `insights` mode produces the hints
  but no lints (`MinifySettings.modeDefaults` only sets `lints_enabled` under
  `strict`). Since M0100 names the bindings the "Mangle bindings" pill
  controls, `strict` is also the better demo.
- **A `StateField`, not a `ViewPlugin`.** Hints arrive from a debounced
  request while the visitor keeps typing; a StateField maps its ranges
  through the intervening changes for free.
- **Minify hints carry no distinguishing `kind`** — the wire maps them to
  `InlayHintKind.Type` alongside real type hints
  (`lsp/wire/editing.zig::inlayHintKindCode`), so the tooltip is the only
  marker. And they **ignore the requested range**, unlike type hints.
- **`unused_helper` gets no hint at all.** The estimator walks live
  declarations only, so a tree-shaken function has no size to report. Worth
  saying out loud on the page: its silence is the insight.
- The server returns hints in traversal order with the module total *last*,
  so `Decoration.set(..., true)` is load-bearing.
- CodeMirror virtualizes: how many widgets exist in the DOM depends on scroll
  position and window height, so no browser check may assert a fixed count.

Two findings that are not about this block:

- **`textDocument/formatting` is destructive.** `computeFormatting` runs the
  whole minifier with only whitespace and identifier renaming disabled, so
  formatting a document also strips every comment, tree-shakes dead code and
  rewrites literals (`1.0` → `1.`). `languageServerExtensions()` binds it to
  Shift-Alt-f, so a visitor can hit it by accident. Pinned in both suites;
  left as-is because it is the tool's real behaviour, and `src/Cst.zig` is
  trivia-preserving if it should ever become a true formatter.
- **A Block 2 bug, fixed here** (`dba5c76`): Starlight's markdown vertical
  rhythm was adding 16px between every `.cm-line`, which desynchronised
  CodeMirror's height map and made clicking a line land two lines away.
  Rename could not work until this was fixed. `not-content` is Starlight's
  own opt-out. Twenty-five lines now fit where fourteen did — and this is
  very likely why hover never looked right either.

---

## Block 5 — truth pass and the full gate

*Fresh-session context: the playground is functionally complete. What's left is
making the rest of the site point at it and stop lying.*

1. `astro.config.mjs`: title `'My Docs'` → `'WGSLender'`, social link →
   `https://github.com/HugoDaniel/wgslender`. Two lines, deliberately inside
   this plan's scope even though broader branding is not — a page titled "My
   Docs" undercuts the demo it frames.
2. `index.mdx`: hero action #1 becomes "Try the playground" → `/playground/`
   (replacing the dead starter link); drop or re-point the "Read the Starlight
   docs" action; the minifier / validator / discoverability / LSP cards link
   into the playground.
3. `web/README.md`: replace the starter text with the real structure —
   playground modules, `pnpm test`, and the `file:` dependency consequence
   (`pnpm install` in `web/` requires the sibling package directories, true in
   every fresh clone).
4. `web/AGENTS.md` (remember `CLAUDE.md` symlinks to it): add `pnpm test`, the
   `sync-wasm` step, and the rule that a wire-affecting Zig change requires
   rebuilding both wasms before trusting playground behavior.
5. Full gate, in order: `cd web && pnpm test && pnpm build`; then `zig build
   test` from the repo root (`-j1`) to prove the Block 1 wasm rebuild didn't
   ride on a broken tree; then a final hand pass over `/playground/`.
6. Update this file's **Status** to executed with the commit list and every
   deviation (lsp-client version actually installed, Tabs vs buttons, any
   message or code that differed from the predictions above), following
   `docs/plans/rust-examples.md`'s convention.

---

## Behavior changes (explicit)

- **None to the Zig library, CLI, native LSP, or any package's JS API.** The
  playground only consumes shipped surfaces.
- **The checked-in wasm binaries may change bytes** (Block 1 refresh),
  changing what the unpublished npm packages would ship. Lands as its own
  commit so it can be reverted independently.
- `web/package.json` gains runtime deps (codemirror family) and two `file:`
  links: `pnpm install` in `web/` now depends on the sibling package
  directories existing.
- `web/public/` gains two generated, gitignored `.wasm` files and
  `web/package.json` gains `predev`/`prebuild` hooks that write them.
- Site title and GitHub link change from the Starlight starter defaults
  (Block 5, item 1).

## Definition of done

- [ ] `/playground/` renders inside the Starlight shell, both themes, mobile
      column collapse included, with no custom color values (only `--sl-*`).
- [ ] Editor: WGSL highlighting incl. nested comments, live diagnostics with
      codes, hover, completion, go-to-definition, rename, format, signature
      help.
- [ ] Panels: minified output with option pills + byte/gzip stats + copy;
      reflection tables + raw JSON; clickable diagnostics list.
- [ ] Minify-insights toggle turns per-declaration byte hints on and off.
- [ ] `cd web && pnpm test` — headless LSP session + panel models, green.
- [ ] `cd web && pnpm build` — green.
- [ ] Both wasm binaries verified current against the tree, committed if changed.
- [ ] `index.mdx` links to the playground; no starter links or starter title
      remain.
- [ ] Status records commits and every deviation from this plan's predictions.
