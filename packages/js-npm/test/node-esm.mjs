#!/usr/bin/env node
import { createRequire } from 'module';

const require = createRequire(import.meta.url);
const { runSuite } = require('./_suite.cjs');

const wgslender = await import('../esm/node.mjs');

try {
  const { failed } = await runSuite(wgslender, { variantName: 'node-esm (esm/node.mjs)' });
  process.exit(failed > 0 ? 1 : 0);
} catch (err) {
  console.error('Fatal error:', err);
  process.exit(1);
}
