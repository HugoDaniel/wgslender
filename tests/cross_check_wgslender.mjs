#!/usr/bin/env node
// Reduces wgslender's `reflect --reflect-format v2` output to the same
// canonical shape `cross_check_wgsl_reflect.mjs` emits, so `cross_check.sh`
// can diff them line-for-line.
//
// Reads the JSON wgslender emitted on stdin and writes the reduced
// JSON to stdout. The reducer drops every wgslender-specific field
// (stableId, nameMapped, typeInfo, declSpan, typeSpan, relations,
// `functions[]`, per-entry `resources[]` / `inputs[]` / `outputs[]`,
// override-driven workgroup metadata) so what's left lines up with
// wgsl_reflect's API surface.

import { readFileSync } from 'node:fs';

const raw = readFileSync(0, 'utf8');
const r = JSON.parse(raw);

function bindingRow(b) {
  // Determine kind. wgslender's BindingInfo carries addressSpace +
  // typeInfo.kind; map to the same labels the wgsl_reflect helper uses.
  let kind;
  const ti = b.typeInfo;
  if (b.addressSpace === 'uniform') {
    kind = 'uniform';
  } else if (b.addressSpace === 'storage') {
    kind = 'storage';
  } else if (ti && ti.kind === 'sampler') {
    kind = 'sampler';
  } else if (ti && ti.kind === 'texture') {
    // wgsl_reflect splits storage textures from sampled textures via the
    // ResourceType enum; mirror that split using `texKind` (which the
    // wgslender JSON puts directly on the typeInfo node, not under a
    // nested `texture` field).
    kind = ti.texKind === 'storage' ? 'storageTexture' : 'texture';
  } else {
    kind = 'unknown';
  }

  const row = {
    group: b.group,
    binding: b.binding,
    name: b.name,
    addressSpace: b.addressSpace,
    kind,
  };

  // Buffer-shape bindings expose a layout.size; record it for parity.
  if (b.layout && typeof b.layout.size === 'number') {
    row.size = b.layout.size;
  } else if (b.array && typeof b.array.totalSize === 'number') {
    row.size = b.array.totalSize;
  } else if (ti && (ti.kind === 'scalar' || ti.kind === 'vec' || ti.kind === 'mat' || ti.kind === 'array')) {
    if (typeof ti.size === 'number') row.size = ti.size;
  }
  return row;
}

const bindings = (r.bindings || []).map(bindingRow);
bindings.sort((a, b) => a.group - b.group || a.binding - b.binding || a.name.localeCompare(b.name));

const out = {
  bindings,
  aliases: (r.aliases || []).map(a => a.name).sort(),
  entryPoints: (r.entryPoints || []).map(e => ({ name: e.name, stage: e.stage })).sort(
    (a, b) => a.name.localeCompare(b.name),
  ),
  structs: Object.keys(r.structs || {}).sort(),
};

process.stdout.write(JSON.stringify(out, null, 2) + '\n');
