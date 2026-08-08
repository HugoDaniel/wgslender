// wgslender.compile — palette command. Runs the compile pipeline
// against the active editor and writes the resulting .wasm via
// workspace.fs (works for desktop, web, and remote hosts).

import {
  Disposable,
  ExtensionContext,
  Uri,
  commands,
  window,
  workspace,
} from 'vscode';

import { getWgslenderEngine } from '../wgslender-engine';

export function registerCompileCommands(context: ExtensionContext): Disposable[] {
  return [commands.registerCommand('wgslender.compile', () => runCompile(context))];
}

async function runCompile(context: ExtensionContext): Promise<void> {
  const editor = window.activeTextEditor;
  if (!editor || editor.document.languageId !== 'wgsl') {
    window.showInformationMessage('wgslender: open a .wgsl document first.');
    return;
  }

  let result: { wasm: Uint8Array; originalSize: number; wasmSize: number; errors: { message: string }[] };
  try {
    const engine = await getWgslenderEngine(context);
    result = engine.compile(editor.document.getText(), compileOptionsFromConfig());
  } catch (err) {
    window.showErrorMessage(`wgslender: compile failed — ${formatError(err)}`);
    return;
  }

  if (result.errors.length > 0) {
    window.showErrorMessage(`wgslender: ${result.errors[0].message}`);
    return;
  }

  const defaultUri = await defaultOutputUri(editor.document.uri);
  const saveUri = await window.showSaveDialog({
    defaultUri,
    filters: { 'WebAssembly': ['wasm'] },
  });
  if (!saveUri) return;

  await workspace.fs.writeFile(saveUri, result.wasm);
  const ratio = result.originalSize > 0
    ? Math.round((1 - result.wasmSize / result.originalSize) * 100)
    : 0;
  window.setStatusBarMessage(
    `wgslender: compiled ${result.originalSize}B → ${result.wasmSize}B (${ratio}% smaller)`,
    4000,
  );
}

async function defaultOutputUri(sourceUri: Uri): Promise<Uri> {
  const wasmName = sourceUri.path.split('/').pop()!.replace(/\.wgsl$/, '.wasm');
  const outputDir = workspace.getConfiguration('wgslender.compile').get<string>('outputDirectory', '');
  if (!outputDir) {
    return sourceUri.with({ path: sourceUri.path.replace(/\.wgsl$/, '.wasm') });
  }
  const folder = workspace.getWorkspaceFolder(sourceUri);
  const baseUri = folder ? folder.uri : sourceUri.with({ path: sourceUri.path.replace(/\/[^/]*$/, '') });
  return Uri.joinPath(baseUri, outputDir, wasmName);
}

export function compileOptionsFromConfig(): Record<string, unknown> {
  const cfg = workspace.getConfiguration('wgslender');
  return {
    minifyWhitespace: cfg.get<boolean>('minifyWhitespace', true),
    minifyIdentifiers: cfg.get<boolean>('minifyIdentifiers', true),
    minifySyntax: cfg.get<boolean>('minifySyntax', true),
    treeShaking: cfg.get<boolean>('treeShaking', true),
    preserveUniformStructTypes: cfg.get<boolean>('preserveUniformStructTypes', false),
    // Compile defaults sortDeclarations + scopeLocalRename to true — the
    // BPE pass that follows benefits significantly from both, and the CLI
    // `compile` subcommand always applies them. package.json declares
    // these keys `default: false` (for the minify family), so `cfg.get`
    // with a fallback can never say true here; only an explicit user
    // value may override the compile default.
    sortDeclarations: explicitUserValue(cfg, 'sortDeclarations') ?? true,
    scopeLocalRename: explicitUserValue(cfg, 'scopeLocalRename') ?? true,
    mangleExternalBindings: cfg.get<boolean>('mangleExternalBindings', false),
    keepNames: cfg.get<string[]>('keepNames', []),
  };
}

/** The user's own setting for `key` at any scope, ignoring the package-manifest default. */
function explicitUserValue(
  cfg: ReturnType<typeof workspace.getConfiguration>,
  key: string,
): boolean | undefined {
  const info = cfg.inspect<boolean>(key);
  return (
    info?.workspaceFolderLanguageValue ??
    info?.workspaceLanguageValue ??
    info?.globalLanguageValue ??
    info?.workspaceFolderValue ??
    info?.workspaceValue ??
    info?.globalValue
  );
}

function formatError(err: unknown): string {
  if (err instanceof Error) return err.message;
  return String(err);
}
