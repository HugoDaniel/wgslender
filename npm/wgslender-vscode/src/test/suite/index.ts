// Mocha entry point — picked up by @vscode/test-electron via
// extensionTestsPath. Discovers and runs every *.test.js sibling.

import * as fs from 'fs';
import * as path from 'path';

// A default import, not `* as`: mocha is CommonJS with `export = Mocha`, and
// under `esModuleInterop` the namespace form is not constructable — which is
// what stopped this suite from compiling at all.
import Mocha from 'mocha';

export async function run(): Promise<void> {
  const mocha = new Mocha({ ui: 'tdd', color: true, timeout: 30_000 });
  const testsRoot = path.resolve(__dirname, '.');

  for (const file of await listTestFiles(testsRoot)) {
    mocha.addFile(file);
  }

  await new Promise<void>((resolve, reject) => {
    try {
      mocha.run((failures: number) => {
        if (failures > 0) reject(new Error(`${failures} tests failed.`));
        else resolve();
      });
    } catch (e) {
      reject(e instanceof Error ? e : new Error(String(e)));
    }
  });
}

async function listTestFiles(dir: string): Promise<string[]> {
  const out: string[] = [];
  for (const entry of await fs.promises.readdir(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      out.push(...await listTestFiles(full));
    } else if (entry.isFile() && entry.name.endsWith('.test.js')) {
      out.push(full);
    }
  }
  return out;
}
