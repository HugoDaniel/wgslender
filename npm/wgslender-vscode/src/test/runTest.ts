// Bootstraps @vscode/test-electron, downloading a VS Code build and
// running the Mocha suite under it. Invoked by `npm test`.

import * as path from 'path';

import { runTests } from '@vscode/test-electron';

async function main(): Promise<void> {
  try {
    const extensionDevelopmentPath = path.resolve(__dirname, '..', '..');
    const extensionTestsPath = path.resolve(__dirname, './suite');

    await runTests({ extensionDevelopmentPath, extensionTestsPath });
  } catch (err) {
    console.error(err);
    process.exit(1);
  }
}

void main();
