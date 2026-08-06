// Two suites, both table-driven — a new case is a row, not new code.
//
//   Suite A runs the three compiled example scripts and checks what they
//   print. It is a smoke test: it proves the examples still run and still
//   demonstrate what their prose claims, so a README cannot drift away from
//   a program that no longer produces that output.
//
//   Suite B calls the package API directly and asserts on values. This is
//   where the real pinning happens.
//
// What is deliberately NOT asserted: minified byte counts. Those move every
// time the minifier improves, and a suite that fails on an improvement is one
// people learn to ignore. Sizes are asserted as relations (`minified <
// original`); only layout numbers — which are fixed by the WGSL spec's
// alignment rules, not by our cleverness — are pinned exactly. Those came
// from the CLI oracle:
//
//   ./zig-out/bin/wgslender reflect examples/js-ts/shaders/demo.wgsl

import { test, describe, before } from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

import { initialize, minify, validate, reflect, getBindGroups, getVersion } from 'wgslender';

const execFileAsync = promisify(execFile);
const exampleRoot = fileURLToPath(new URL('..', import.meta.url));
const shader = (name) =>
  readFileSync(new URL(`../shaders/${name}`, import.meta.url), 'utf8');

const demoSrc = shader('demo.wgsl');
const invalidSrc = shader('invalid.wgsl');
const warningSrc = shader('warning.wgsl');

// ---------------------------------------------------------------------------
// Suite A — the example scripts run and say what they promise
// ---------------------------------------------------------------------------

const scriptCases = [
  {
    script: 'dist/minify.mjs',
    expect: [
      /original\s+893\s+bytes/i,
      /minified\s+\d+\s+bytes/i,
      /@compute/,
      /fn main/,
      // The keepNames section: the helper survives there and nowhere else.
      /luminance/,
    ],
  },
  {
    script: 'dist/validate.mjs',
    expect: [
      /demo\.wgsl: valid/,
      /invalid\.wgsl: INVALID/,
      /E0100/,
      /use of undeclared identifier/,
      // Warnings are reported, and reported as warnings by default...
      /warning\.wgsl: valid \(0 errors, 2 warnings\)/,
      /W0103/,
      // ...then promoted. Without this the strict section could print
      // nothing at all and the row would still pass.
      /strict/i,
      /2 errors, 0 warnings/,
    ],
  },
  {
    script: 'dist/reflect.mjs',
    expect: [
      /@group\(0\) @binding\(0\)\s+params\s+uniform\s+Params/,
      /@group\(1\) @binding\(1\)\s+samp\s+handle\s+sampler/,
      /Params\s+size 16\s+align 8/,
      /\s+0\s+resolution: vec2f/,
      /\s+8\s+time: f32/,
      /\s+12\s+frame: u32/,
      /entry main \[compute\] workgroup_size=8,8,1/,
    ],
  },
];

describe('example scripts', () => {
  for (const { script, expect } of scriptCases) {
    test(`${script} runs and reports`, async () => {
      const { stdout } = await execFileAsync(process.execPath, [script], {
        cwd: exampleRoot,
      });
      for (const pattern of expect) {
        assert.match(stdout, pattern);
      }
    });
  }
});

// ---------------------------------------------------------------------------
// Suite B — the package API, asserted directly
// ---------------------------------------------------------------------------

describe('wgslender API', () => {
  before(async () => {
    // No arguments: in Node the wrapper finds its own wasm. This call is
    // itself a regression test — it did not type-check before the .d.ts fix.
    await initialize();
  });

  test('getVersion() reports a semver string', () => {
    assert.match(getVersion(), /^\d+\.\d+\.\d+/);
  });

  const minifyCases = [
    {
      name: 'default options shrink the demo shader without errors',
      source: () => demoSrc,
      options: undefined,
      check(r) {
        assert.equal(r.errors.length, 0);
        assert.ok(
          r.minifiedSize < r.originalSize,
          `expected shrinkage, got ${r.originalSize} -> ${r.minifiedSize}`,
        );
        assert.equal(r.originalSize, demoSrc.length);
        // Entry points keep their names: the host looks them up by string.
        assert.match(r.code, /@compute/);
        assert.match(r.code, /fn main\(/);
      },
    },
    {
      name: 'external binding names survive by default',
      source: () => demoSrc,
      options: undefined,
      check(r) {
        // @group/@binding vars are the API surface a host binds against, so
        // renaming them by default would break the caller.
        assert.match(r.code, /\bparams\b/);
        assert.match(r.code, /\bdata\b/);
      },
    },
    {
      name: 'keepNames preserves a private helper the default run renames',
      source: () => demoSrc,
      options: { keepNames: ['luminance'] },
      check(r) {
        assert.match(r.code, /\bluminance\b/);
        // The other half of the claim: without keepNames it really is gone,
        // otherwise this case would pass for the wrong reason.
        assert.ok(!minify(demoSrc).code.includes('luminance'));
      },
    },
    {
      name: 'whitespace-only minification leaves identifiers alone',
      source: () => demoSrc,
      options: {
        minifyWhitespace: true,
        minifyIdentifiers: false,
        minifySyntax: false,
      },
      check(r) {
        assert.match(r.code, /\bluminance\b/);
        assert.match(r.code, /\bresolution\b/);
        assert.ok(r.minifiedSize < r.originalSize);
      },
    },
    {
      name: 'a parse error is reported in errors[]',
      source: () => 'fn main( { ',
      options: undefined,
      check(r) {
        assert.ok(r.errors.length > 0);
      },
    },
    {
      name: 'a semantic error is NOT a minify error',
      source: () => invalidSrc,
      options: undefined,
      check(r) {
        // Only the parser rejects. minify() will happily rename and print a
        // shader that validate() calls invalid — which is why the two are
        // separate calls, and why a build step should run both.
        assert.equal(r.errors.length, 0);
        assert.ok(r.code.includes('undeclared_variable'));
      },
    },
  ];

  for (const { name, source, options, check } of minifyCases) {
    test(`minify: ${name}`, () => check(minify(source(), options)));
  }

  const validateCases = [
    {
      name: 'the demo shader is valid',
      source: () => demoSrc,
      options: undefined,
      check(r) {
        assert.equal(r.valid, true);
        assert.equal(r.errorCount, 0);
        assert.equal(r.warningCount, 0);
      },
    },
    {
      name: 'an undeclared identifier is an error with a usable location',
      source: () => invalidSrc,
      options: undefined,
      check(r) {
        assert.equal(r.valid, false);
        assert.ok(r.errorCount >= 1);
        const d = r.diagnostics[0];
        assert.equal(d.severity, 'error');
        assert.equal(d.code, 'E0100');
        assert.ok(d.line >= 1 && d.column >= 1, 'positions are 1-based');
        assert.match(d.message, /undeclared identifier/);
      },
    },
    {
      name: 'sloppy-but-legal code produces warnings, not errors',
      source: () => warningSrc,
      options: undefined,
      check(r) {
        assert.equal(r.valid, true);
        assert.equal(r.errorCount, 0);
        assert.equal(r.warningCount, 2);
        const codes = r.diagnostics.map((d) => d.code).sort();
        assert.deepEqual(codes, ['W0101', 'W0103']);
      },
    },
    {
      name: 'strict mode promotes every warning to an error',
      source: () => warningSrc,
      options: { strict: true },
      check(r) {
        const def = validate(warningSrc);
        assert.ok(
          r.errorCount >= def.errorCount + def.warningCount,
          `strict must absorb the warnings: ${def.errorCount}e/${def.warningCount}w -> ${r.errorCount}e`,
        );
        assert.equal(r.valid, false);
        assert.equal(r.warningCount, 0);
      },
    },
    {
      name: 'strictMode is the dead spelling and changes nothing',
      source: () => warningSrc,
      options: { strictMode: true },
      check(r) {
        // Pins the @deprecated note in main.d.ts to observable behavior: the
        // wrapper reads `strict`, so this option is inert. If someone wires
        // it up, this test fails and the doc comment gets fixed with it.
        assert.equal(r.valid, true);
        assert.equal(r.errorCount, 0);
        assert.equal(r.warningCount, 2);
      },
    },
  ];

  for (const { name, source, options, check } of validateCases) {
    test(`validate: ${name}`, () => check(validate(source(), options)));
  }

  describe('reflect', () => {
    let r;
    before(() => {
      r = reflect(demoSrc);
    });

    test('emits the v2 envelope', () => {
      assert.equal(r.version, 2);
    });

    // group, binding, name, addressSpace — pinned from the CLI oracle.
    const bindingRows = [
      [0, 0, 'params', 'uniform'],
      [0, 1, 'data', 'storage'],
      [1, 0, 'tex', 'handle'],
      [1, 1, 'samp', 'handle'],
    ];

    test('reports all four bindings', () => {
      assert.equal(r.bindings.length, bindingRows.length);
    });

    for (const [group, binding, name, addressSpace] of bindingRows) {
      test(`binding @group(${group}) @binding(${binding}) is ${name}`, () => {
        const b = r.bindings.find(
          (x) => x.group === group && x.binding === binding,
        );
        assert.ok(b, `no binding at @group(${group}) @binding(${binding})`);
        assert.equal(b.name, name);
        assert.equal(b.addressSpace, addressSpace);
      });
    }

    test('Params layout matches the WGSL alignment rules', () => {
      const s = r.structs.Params;
      assert.ok(s, 'Params is missing from structs');
      assert.equal(s.size, 16);
      assert.equal(s.alignment, 8);
    });

    // name, offset, size — vec2f forces the 8-byte alignment that makes this
    // layout worth showing.
    const fieldRows = [
      ['resolution', 0, 8],
      ['time', 8, 4],
      ['frame', 12, 4],
    ];

    for (const [name, offset, size] of fieldRows) {
      test(`Params.${name} sits at offset ${offset}`, () => {
        const f = r.structs.Params.fields.find((x) => x.name === name);
        assert.ok(f, `no field named ${name}`);
        assert.equal(f.offset, offset);
        assert.equal(f.size, size);
      });
    }

    test('reports the compute entry point and its workgroup size', () => {
      assert.equal(r.entryPoints.length, 1);
      const e = r.entryPoints[0];
      assert.equal(e.name, 'main');
      assert.equal(e.stage, 'compute');
      assert.deepEqual(e.workgroupSize, [8, 8, 1]);
    });

    test('getBindGroups indexes bindings by group and binding', () => {
      const groups = getBindGroups(r);
      assert.equal(groups[0][1].name, 'data');
      assert.equal(groups[1][0].name, 'tex');
      assert.equal(Object.keys(groups).length, 2);
    });
  });
});
