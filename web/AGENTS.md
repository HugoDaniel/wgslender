## What this site is

A Starlight site whose point is `/playground/` — a CodeMirror editor talking to
`wgslender-lsp.wasm`, with panels driven by `wgslender.wasm`. See `README.md`
for the module map. Everything here consumes shipped surfaces; nothing in `web/`
should require a change to the Zig library to work.

## Development

Both wasm binaries are copied into `public/` by `scripts/sync-wasm.mjs`, which
`pnpm dev`, `pnpm start` and `pnpm build` run for you. `astro dev` on its own
does **not** — so in background mode, sync first:

```
pnpm sync-wasm
astro dev --background --port 4324
```

Manage the background server with `astro dev stop`, `astro dev status`, and
`astro dev logs`. Port 4324 is what `pnpm dev` pins and what `pnpm smoke`
expects.

## Gate

```
pnpm test     # node --test 'tests/*.test.mjs' — the logic, against real wasm
pnpm build    # the site must build
pnpm smoke    # with a server running: the page, in headless Chrome
```

`pnpm test` and `pnpm smoke` answer different questions and neither substitutes
for the other. The tests drive the wasm with no DOM; the smoke check drives the
DOM in a real browser, and it measures `getBoundingClientRect()` rather than
`textContent` because both bugs it has caught so far were correct in the DOM and
zero pixels tall on screen. **Look at the page too** — a screenshot has caught
what neither did.

## The wasm is not rebuilt for you

`public/*.wasm` is gitignored and comes from the two npm packages, whose
binaries are checked in. A Zig change that touches the LSP wire, the minifier or
any diagnostic reaches this page only after:

```
zig build wasm && zig build lsp-wasm     # from the repo root
```

then copying the results over `packages/js-npm/wgslender.wasm` and
`npm/wgslender-lsp/wgslender-lsp.wasm`, then `pnpm install` in `web/` — pnpm
*copies* `file:` dependencies into its store instead of linking them, so an
edited package is invisible here until it reinstalls. Nothing warns you about a
stale binary; a rebase can make one stale without changing a byte of it.

## Documentation

Full documentation: https://docs.astro.build

Consult these guides before working on related tasks:

- [Adding pages, dynamic routes, or middleware](https://docs.astro.build/en/guides/routing/)
- [Working with Astro components](https://docs.astro.build/en/basics/astro-components/)
- [Using React, Vue, Svelte, or other framework components](https://docs.astro.build/en/guides/framework-components/)
- [Adding or managing content](https://docs.astro.build/en/guides/content-collections/)
- [Adding styles or using Tailwind](https://docs.astro.build/en/guides/styling/)
- [Supporting multiple languages](https://docs.astro.build/en/guides/internationalization/)
