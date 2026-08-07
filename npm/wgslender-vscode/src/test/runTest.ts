// Bootstraps @vscode/test-electron, downloading a VS Code build and
// running the Mocha suite under it. Invoked by `npm test`.

import * as os from 'os';
import * as path from 'path';

import { runTests } from '@vscode/test-electron';

async function main(): Promise<void> {
  try {
    const extensionDevelopmentPath = path.resolve(__dirname, '..', '..');
    const extensionTestsPath = path.resolve(__dirname, './suite');

    // VS Code opens a unix socket under --user-data-dir, and macOS caps
    // socket paths at 103 characters. The default lives inside the checkout,
    // which in a git worktree is already deep enough to fail startup with
    // `listen EINVAL`, so point it somewhere short instead.
    const userDataDir = path.join(os.tmpdir(), 'wgslender-vscode-test');

    await runTests({
      extensionDevelopmentPath,
      extensionTestsPath,
      launchArgs: ['--user-data-dir', userDataDir],
    });
  } catch (err) {
    console.error(err);
    process.exit(1);
  }
}

void main();
