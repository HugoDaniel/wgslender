/**
 * Reflection: everything a host needs to build a pipeline, without parsing
 * WGSL yourself.
 *
 * Run: npm run build && node dist/reflect.mjs
 *
 * The struct layout is the part worth reading closely. `Params` is four
 * fields' worth of data in 16 bytes, and `time` sits at offset 8 rather than
 * 4, because `resolution: vec2f` has to start on an 8-byte boundary. Getting
 * that wrong by hand is the classic source of a shader that reads garbage;
 * these are the numbers to feed your buffer writer.
 */

import { readFileSync } from 'node:fs';
import {
  initialize,
  reflect,
  getBindGroups,
  type StructLayout,
  type EntryPointInfo,
} from 'wgslender';

const source = readFileSync(new URL('../shaders/demo.wgsl', import.meta.url), 'utf8');

await initialize();

const result = reflect(source);

if (result.errors && result.errors.length > 0) {
  console.error('reflection failed:');
  for (const e of result.errors) console.error(`  ${e}`);
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Bindings, grouped the way a bind-group layout is declared.
// ---------------------------------------------------------------------------

console.log('bindings');
const groups = getBindGroups(result);
for (const group of Object.keys(groups).map(Number).sort((a, b) => a - b)) {
  for (const binding of Object.keys(groups[group]).map(Number).sort((a, b) => a - b)) {
    const b = groups[group][binding];
    const where = `@group(${group}) @binding(${binding})`.padEnd(26);
    const access = b.accessMode ? `  (${b.accessMode})` : '';
    console.log(`  ${where} ${b.name.padEnd(8)} ${b.addressSpace.padEnd(9)} ${b.type}${access}`);
  }
}
console.log();

// ---------------------------------------------------------------------------
// Struct layouts.
// ---------------------------------------------------------------------------

console.log('structs');
for (const [name, layout] of Object.entries(result.structs) as [string, StructLayout][]) {
  console.log(`  ${name.padEnd(10)} size ${layout.size}  align ${layout.alignment}`);
  for (const f of layout.fields) {
    const offset = String(f.offset).padStart(6);
    console.log(`  ${offset}   ${f.name}: ${f.type}  (size ${f.size}, align ${f.alignment})`);
  }
}
console.log();

// ---------------------------------------------------------------------------
// Entry points.
// ---------------------------------------------------------------------------

console.log('entry points');
for (const e of result.entryPoints as EntryPointInfo[]) {
  const wg = e.workgroupSize ? ` workgroup_size=${e.workgroupSize.join(',')}` : '';
  console.log(`  entry ${e.name} [${e.stage}]${wg}`);
  for (const i of e.inputs) {
    const source_ = i.builtin ? `@builtin(${i.builtin})` : `@location(${i.location})`;
    console.log(`    in  ${i.name}: ${i.type}  ${source_}`);
  }
  // Bindings reachable through this entry point's call graph — the set you
  // would actually bind for this pipeline. Note `samp` is absent: the demo
  // declares the sampler but never uses it, so nothing reaches it.
  console.log(`    uses ${e.resources.join(', ')}`);
}
