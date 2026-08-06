# examples/js-ts

Consuming wgslender from TypeScript, through the npm package (WebAssembly).

Three subexamples over one demo shader — **minify**, **validate**, **reflect** —
plus a test suite that runs all three and checks what they print.

## Run it

```bash
cd examples/js-ts
npm install          # links ../../packages/js-npm as a file: dependency
npm test             # builds, then runs the suite (27 cases)
```

The individual scripts, after `npm run build`:

```bash
node dist/minify.mjs
node dist/validate.mjs
node dist/reflect.mjs
```

Requires Node ≥ 20 (developed on 26.6.0). No global install and no CI: `npm test`
is the whole verification story.

## What each one shows

| Script | Shows |
|---|---|
| `src/minify.mts` | Defaults vs `keepNames` vs whitespace-only; which names survive and why |
| `src/validate.mts` | Diagnostics with codes and positions; `{ strict: true }` promoting warnings to errors |
| `src/reflect.mts` | Bind-group table, struct memory layout, entry points and their workgroup size |

The fixtures in `shaders/` are chosen to make those visible: `demo.wgsl` is valid
and has a uniform struct whose alignment is worth reading, `invalid.wgsl` has a
semantic error, and `warning.wgsl` is legal-but-sloppy so that strict mode has
something to promote.

## Three things worth knowing before you copy this

**`minify()` reports parse errors only.** A shader with an undeclared identifier
minifies cleanly and hands back renamed nonsense — the suite pins both halves of
that. If minification is a build gate for you, run `validate()` as well.

**The validate option is `strict`, not `strictMode`.** `strictMode` is declared
in the types for backwards compatibility, is marked `@deprecated`, and has never
had a runtime effect. `validate.mts` demonstrates the silence.

**Entry-point names and `@group`/`@binding` variables survive minification** by
default, because they are the shader's API. Everything else is fair game —
including unused bindings, which tree shaking deletes outright.

## Types

`tsconfig.json` uses `nodenext` + `strict` with `skipLibCheck: false`, so the
package's own declarations are type-checked too. This example compiles with no
`any` casts and no `@ts-ignore`.

Note that TypeScript resolves `wgslender` to `lib/main.d.ts` via the `require`
branch of the exports map — there is no `esm/node.d.mts` — so ESM consumers are
typed by the CJS declarations.

## WASM freshness

The example runs against the committed `packages/js-npm/wgslender.wasm`. If the
Zig-side wire formats change, refresh it:

```bash
zig build wasm && cp zig-out/bin/wgslender.wasm packages/js-npm/wgslender.wasm
cd packages/js-npm && npm test
```
