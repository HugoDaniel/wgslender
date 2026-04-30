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
  {
    ...shared,
    entryPoints: { extension: 'src/extension.ts' },
    outdir: 'dist',
    platform: 'node',
    format: 'cjs',
    external: ['vscode'],
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
