/**
 * Minification, three ways.
 *
 * Run: npm run build && node dist/minify.mjs
 *
 * The thing worth internalising here: `minify()` only fails on *parse*
 * errors. A shader with a semantic error — an undeclared identifier, a type
 * mismatch — minifies perfectly happily and hands you back renamed nonsense.
 * If you want minification to gate a build, run `validate()` too. See
 * validate.mts.
 */

import { readFileSync } from 'node:fs';
import { initialize, minify, type MinifyResult } from 'wgslender';

const source = readFileSync(new URL('../shaders/demo.wgsl', import.meta.url), 'utf8');

await initialize();

function report(label: string, result: MinifyResult): void {
  const saved = ((1 - result.minifiedSize / result.originalSize) * 100).toFixed(1);
  console.log(`${label}`);
  console.log(`  original  ${result.originalSize} bytes`);
  console.log(`  minified  ${result.minifiedSize} bytes  (${saved}% saved)`);
}

// ---------------------------------------------------------------------------
// 1. Defaults: whitespace, identifiers, syntax and tree shaking, all on.
// ---------------------------------------------------------------------------

const full = minify(source);
if (full.errors.length > 0) {
  console.error('minification failed:');
  for (const e of full.errors) console.error(`  ${e.message}`);
  process.exit(1);
}

report('default options', full);
console.log();
console.log(full.code);
console.log();

// Two names survive that renaming, and for the same reason: they are the
// shader's API. Entry points are looked up by string when the pipeline is
// created, and @group/@binding variables are what the host binds against.
console.log(`entry point 'main' preserved:      ${full.code.includes('fn main(')}`);
console.log(`binding 'params' preserved:        ${full.code.includes('params')}`);
// The sampler is a different story: nothing references it, so tree shaking
// removes the declaration outright.
console.log(`unused binding 'samp' shaken out:  ${!full.code.includes('samp')}`);
console.log();

// ---------------------------------------------------------------------------
// 2. keepNames: opt individual private symbols out of renaming.
// ---------------------------------------------------------------------------

const kept = minify(source, { keepNames: ['luminance'] });

report("keepNames: ['luminance']", kept);
// Printed as a computed comparison rather than a claim, so this line is only
// true if keepNames did something the default run would not have done.
console.log(
  `  helper 'luminance': default -> ${full.code.includes('luminance') ? 'kept' : 'renamed'}` +
    `, keepNames -> ${kept.code.includes('luminance') ? 'kept' : 'renamed'}`,
);
console.log(`  cost of keeping it: ${kept.minifiedSize - full.minifiedSize} bytes`);
console.log();

// ---------------------------------------------------------------------------
// 3. Whitespace only: shrink the file, keep every name readable.
// ---------------------------------------------------------------------------

const wsOnly = minify(source, {
  minifyWhitespace: true,
  minifyIdentifiers: false,
  minifySyntax: false,
});

report('whitespace only', wsOnly);
console.log(`  identifiers intact: ${wsOnly.code.includes('resolution')}`);
