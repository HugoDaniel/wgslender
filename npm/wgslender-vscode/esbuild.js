// Build the wgslender VS Code extension for both desktop (Node) and web (Browser) hosts.
//
//   node esbuild.js              # one-shot dev build
//   node esbuild.js --watch      # watch mode
//   node esbuild.js --production # minified production build

const esbuild = require('esbuild');

const args = new Set(process.argv.slice(2));
const watch = args.has('--watch');
const production = args.has('--production');

const shared = {
  bundle: true,
  minify: production,
  sourcemap: !production,
  logLevel: 'info',
  target: 'es2022',
};

/** @type {esbuild.BuildOptions[]} */
const builds = [
  // Desktop extension host (Node).
  //
  // `wgslender` is imported with ESM syntax, so esbuild resolves the `import`
  // condition of its exports map — `esm/node.mjs` — even though the output
  // format is cjs. That file computes `fileURLToPath(import.meta.url)` at
  // module scope, and `import.meta` is empty in cjs output, so the bundle
  // threw "The 'path' argument must be of type string" on load and the
  // extension never activated. Restoring it takes both halves below —
  // `define` values have to be an identifier or JSON, so the expression goes
  // in a banner and `define` points at it.
  {
    ...shared,
    entryPoints: { extension: 'src/extension.ts' },
    outdir: 'dist',
    platform: 'node',
    format: 'cjs',
    external: ['vscode'],
    banner: {
      js: "const __wgslender_import_meta_url = require('url').pathToFileURL(__filename).href;",
    },
    define: { 'import.meta.url': '__wgslender_import_meta_url' },
  },
  // Web extension host (Browser worker context for vscode.dev / github.dev).
  {
    ...shared,
    entryPoints: { 'web-extension': 'src/web-extension.ts' },
    outdir: 'dist',
    platform: 'browser',
    format: 'cjs',
    external: ['vscode'],
    mainFields: ['browser', 'module', 'main'],
    define: { global: 'globalThis' },
  },
  // LSP Worker — runs wgslender-lsp.wasm under the LanguageClient.
  // Used by both desktop and web hosts (Node 18+ exposes Worker).
  {
    ...shared,
    entryPoints: { server: 'src/server.ts' },
    outdir: 'dist',
    platform: 'browser',
    format: 'iife',
    mainFields: ['browser', 'module', 'main'],
    define: { global: 'globalThis' },
  },
];

async function run() {
  if (watch) {
    const ctxs = await Promise.all(builds.map((b) => esbuild.context(b)));
    await Promise.all(ctxs.map((c) => c.watch()));
    console.log('[wgslender-vscode] watching for changes...');
    return;
  }
  await Promise.all(builds.map((b) => esbuild.build(b)));
  console.log('[wgslender-vscode] build complete');
}

run().catch((err) => {
  console.error(err);
  process.exit(1);
});
