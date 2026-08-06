/**
 * Semantic validation, and what strict mode actually does.
 *
 * Run: npm run build && node dist/validate.mjs
 *
 * This script reports; it does not gate. It exits 0 even when a shader is
 * invalid, because its job is to show you the diagnostics. A real build step
 * would exit non-zero on `errorCount > 0` — and would need to, since minify()
 * will not do it for you (see minify.mts).
 */

import { readFileSync } from 'node:fs';
import {
  initialize,
  validate,
  type DiagnosticInfo,
  type ValidateResult,
} from 'wgslender';

const read = (name: string): string =>
  readFileSync(new URL(`../shaders/${name}`, import.meta.url), 'utf8');

await initialize();

function format(d: DiagnosticInfo): string {
  const code = d.code ? ` ${d.code}` : '';
  return `    ${d.severity}${code} ${d.line}:${d.column} ${d.message}`;
}

const plural = (n: number, noun: string): string =>
  `${n} ${noun}${n === 1 ? '' : 's'}`;

function summarise(file: string, r: ValidateResult): void {
  const counts = `(${plural(r.errorCount, 'error')}, ${plural(r.warningCount, 'warning')})`;
  console.log(`${file}: ${r.valid ? 'valid' : 'INVALID'} ${counts}`);
  for (const d of r.diagnostics) console.log(format(d));
}

// ---------------------------------------------------------------------------
// 1. The three fixtures under default options.
// ---------------------------------------------------------------------------

for (const file of ['demo.wgsl', 'invalid.wgsl', 'warning.wgsl']) {
  summarise(file, validate(read(file)));
}

console.log();

// ---------------------------------------------------------------------------
// 2. The same warning fixture under strict mode.
// ---------------------------------------------------------------------------
//
// `valid` is not a fixed property of a shader — it is a function of the
// severities you chose. warning.wgsl is legal WGSL either way; strict mode
// only decides whether you are willing to ship it.

const warningSrc = read('warning.wgsl');
const relaxed = validate(warningSrc);
const strict = validate(warningSrc, { strict: true });

console.log('warning.wgsl under strict mode');
console.log(`  default:  valid=${relaxed.valid}  ${relaxed.errorCount} errors, ${relaxed.warningCount} warnings`);
console.log(`  strict:   valid=${strict.valid}  ${strict.errorCount} errors, ${strict.warningCount} warnings`);

// The option is `strict`. `strictMode` is declared for backwards
// compatibility, is marked @deprecated, and has never had a runtime effect —
// which is easy to believe and easier to demonstrate:
const misspelled = validate(warningSrc, { strictMode: true });
console.log(`  strictMode (deprecated, inert): ${misspelled.errorCount} errors — unchanged`);
