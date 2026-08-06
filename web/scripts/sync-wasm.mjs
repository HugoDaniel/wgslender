#!/usr/bin/env node
// Copy both wasm binaries into `web/public/` so the browser can fetch them
// from a stable, absolute URL.
//
// Why a copy step and not `import wasm from 'wgslender/wasm?url'`: both
// packages are linked with `file:` deps, so the `?url` import would have to
// travel through a pnpm symlink into a directory outside the Astro root.
// That works until it doesn't, and when it breaks it breaks at build time
// with an opaque message. Copying keeps the freshness rule mechanical — the
// bytes in `public/` are always the bytes the package would publish.
//
// Runs automatically via the `predev` / `prebuild` hooks. If you start Astro
// directly (`astro dev --background`), run `pnpm sync-wasm` first.

import { copyFile, mkdir } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const publicDir = join(dirname(dirname(fileURLToPath(import.meta.url))), 'public');

await mkdir(publicDir, { recursive: true });

for (const spec of ['wgslender/wasm', 'wgslender-lsp/wasm']) {
  const from = require.resolve(spec);
  const name = basename(from);
  await copyFile(from, join(publicDir, name));
  console.log(`sync-wasm: public/${name} ← ${spec}`);
}
