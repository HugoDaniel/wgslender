#!/usr/bin/env node
// Drives wgsl_reflect over a single WGSL file and prints a *canonical*
// JSON shape that can be compared to wgslender's output by `cross_check.sh`.
//
// The canonical shape intentionally includes only fields both reflectors
// agree on:
//
//   {
//     "bindings": [               // sorted by (group, binding, name)
//       {
//         "group": <int>,
//         "binding": <int>,
//         "name": <string>,
//         "addressSpace": "uniform"|"storage"|"handle"|"",
//         "kind": "uniform"|"storage"|"texture"|"sampler"|"storageTexture",
//         "size": <int>           // host-shareable size, omitted for handle types
//       },
//       ...
//     ],
//     "aliases": [<name>, ...],   // sorted, names only
//     "entryPoints": [            // sorted by name
//       { "name": <string>, "stage": "vertex"|"fragment"|"compute" },
//       ...
//     ],
//     "structs": [<name>, ...]    // sorted, names only
//   }
//
// Extensions wgslender emits but wgsl_reflect doesn't (stable_id,
// name_mapped, typeInfo, type spans, relations, function call graph,
// per-entry resource lists, override-driven workgroup_size, …) are
// elided on the wgslender side too — they appear under `version: 2`
// but the canonical shape is version-agnostic.

import { readFileSync } from 'node:fs';
import { WgslReflect, ResourceType } from '../external/wgsl_reflect/wgsl_reflect.module.js';

const path = process.argv[2];
if (!path) {
  console.error('usage: cross_check_wgsl_reflect.mjs <shader.wgsl>');
  process.exit(2);
}

const src = readFileSync(path, 'utf8');
const r = new WgslReflect(src);

function bindingRow(v, kind) {
  const row = {
    group: v.group,
    binding: v.binding,
    name: v.name,
    addressSpace: v.resourceType === ResourceType.Uniform ? 'uniform'
                 : v.resourceType === ResourceType.Storage ? 'storage'
                 : 'handle',
    kind,
  };
  // Buffer-like bindings carry a `size`; handle types don't.
  if (typeof v.size === 'number' && v.size > 0) row.size = v.size;
  return row;
}

const bindings = [
  ...r.uniforms.map(v => bindingRow(v, 'uniform')),
  ...r.storage.map(v => {
    // wgsl_reflect groups storage textures under storage[]; project them
    // back to texture-side for shape parity with wgslender.
    const isStorageTexture = v.resourceType === ResourceType.StorageTexture;
    return bindingRow(v, isStorageTexture ? 'storageTexture' : 'storage');
  }),
  ...r.textures.map(v => bindingRow(v, 'texture')),
  ...r.samplers.map(v => bindingRow(v, 'sampler')),
];
bindings.sort((a, b) => a.group - b.group || a.binding - b.binding || a.name.localeCompare(b.name));

const out = {
  bindings,
  aliases: r.aliases.map(a => a.name).sort(),
  entryPoints: [
    ...r.entry.vertex.map(e => ({ name: e.name, stage: 'vertex' })),
    ...r.entry.fragment.map(e => ({ name: e.name, stage: 'fragment' })),
    ...r.entry.compute.map(e => ({ name: e.name, stage: 'compute' })),
  ].sort((a, b) => a.name.localeCompare(b.name)),
  structs: r.structs.map(s => s.name).sort(),
};

process.stdout.write(JSON.stringify(out, null, 2) + '\n');
