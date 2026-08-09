## What this site is

A single-page Vite app whose point is the page itself — a CodeMirror editor
talking to `wgslender-lsp.wasm`, with panels driven by `wgslender.wasm`. See
`README.md` for the module map. Everything here consumes shipped surfaces;
nothing in `web/` should require a change to the Zig library to work.

## Development

Both wasm binaries are copied into `public/` by `scripts/sync-wasm.mjs`, which
`pnpm dev`, `pnpm start` and `pnpm build` run for you. `vite` on its own does
**not** — so in background mode, sync first:

```
pnpm sync-wasm
./node_modules/.bin/vite --background
```

Port 4324 is pinned in `vite.config.ts` — what `pnpm dev`, `pnpm start`,
`pnpm preview` and `pnpm smoke` all expect.

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

## Publishing to hugodaniel.com

The page is also served at https://hugodaniel.com/pages/wgslender/. That build
is driven from the blog repo, not from here:

```
cd ../../hugodaniel.com && make wgslender    # build with --base, copy into static/pages/
```

Two things about that target are load-bearing:

**`--base=/pages/wgslender/` is passed in, not pinned.** The prefix is a fact
about the blog, so `vite.config.ts` stays on `/` and the Makefile supplies it.
`initPlayground` builds its wasm URLs off `import.meta.env.BASE_URL`, so both
binaries follow the flag automatically — but only because the base is
*absolute*. `--base=./` would resolve `new URL('./', location.origin)` back to
the site root and 404 both.

**The host serves `.wasm` as `application/octet-stream`.** `compileStreaming`
and `instantiateStreaming` reject anything that is not `application/wasm`, so
the playground compiles both binaries itself in `wasm.ts`, picking streaming or
a buffer off the response header. Before that it died on load there — and the
neighbouring `/pages/sjon/playground` still does, for exactly this reason.
Fixing the server's MIME table would be the better fix and would repair sjon
too; until then this page does not depend on it.

To check a build the way the blog will serve it, point `pnpm smoke` at a server
that reproduces both conditions — subpath and wrong MIME — rather than at
`pnpm preview`, which serves `.wasm` correctly and so cannot see the bug:

```
PLAYGROUND_URL=http://localhost:4517/pages/wgslender/ pnpm smoke
```

`public/preview.webp` is the social card and is a screenshot of this page;
regenerate it when the layout changes.

## Documentation

Full documentation: https://vite.dev/guide/
