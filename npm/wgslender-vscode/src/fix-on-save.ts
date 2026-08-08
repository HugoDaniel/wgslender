// wgslender.lint.fixOnSave — apply lint autofixes as a save participant.
//
// Mirrors the CLI's `lint --fix`: the engine's `lintAndFix` applies every
// non-overlapping autofix from the configured packs/rules in one pass.
// Runs through onWillSaveTextDocument so the fixed text lands in the same
// save, like ESLint's fix-on-save.

import {
  Disposable,
  ExtensionContext,
  Position,
  Range,
  TextDocument,
  TextEdit,
  workspace,
} from 'vscode';

import { getWgslenderEngine } from './wgslender-engine';

export function registerFixOnSave(context: ExtensionContext): Disposable {
  return workspace.onWillSaveTextDocument((event) => {
    if (event.document.languageId !== 'wgsl') return;
    if (!workspace.getConfiguration('wgslender').get<boolean>('lint.fixOnSave', false)) return;
    event.waitUntil(computeFixEdits(context, event.document));
  });
}

async function computeFixEdits(
  context: ExtensionContext,
  document: TextDocument,
): Promise<TextEdit[]> {
  try {
    const engine = await getWgslenderEngine(context);
    const cfg = workspace.getConfiguration('wgslender');
    const source = document.getText();
    const result = engine.lintAndFix(source, {
      extends: cfg.get<string[]>('extends', ['@wgslender/recommended']),
      rules: cfg.get<Record<string, 'off' | 'warn' | 'error'>>('rules', {}),
      reportUnusedDisableDirectives: cfg.get<boolean>('reportUnusedDisableDirectives', false),
    });
    if (result.fixed === source) return [];
    const fullRange = new Range(new Position(0, 0), document.positionAt(source.length));
    return [TextEdit.replace(fullRange, result.fixed)];
  } catch (err) {
    // Never block the save; the lint diagnostics still show what's wrong.
    console.error('wgslender: fix-on-save failed', err);
    return [];
  }
}
