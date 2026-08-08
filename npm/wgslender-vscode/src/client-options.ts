// LanguageClient options shared by the desktop and web hosts, so the two
// entry points cannot drift. The middleware implements the two settings
// the server has no knowledge of:
//
//   * `wgslender.format.enable` — formatting is gated client-side; the
//     server always answers, the middleware declines to ask.
//   * `wgslender.validate.strict` — warning diagnostics escalate to
//     errors client-side (the CLI's `validate --strict`). The server
//     republishes on every configuration change, so toggling the setting
//     re-runs this middleware without an edit.

import { Diagnostic, DiagnosticSeverity, workspace } from 'vscode';
import { LanguageClientOptions } from 'vscode-languageclient';

function strictMode(): boolean {
  return workspace.getConfiguration('wgslender').get<boolean>('validate.strict', false);
}

function escalateWarnings(diagnostics: Diagnostic[]): void {
  for (const diagnostic of diagnostics) {
    if (diagnostic.severity === DiagnosticSeverity.Warning) {
      diagnostic.severity = DiagnosticSeverity.Error;
    }
  }
}

export function buildClientOptions(): LanguageClientOptions {
  return {
    documentSelector: [{ language: 'wgsl' }],
    synchronize: {
      configurationSection: 'wgslender',
    },
    initializationOptions: workspace.getConfiguration('wgslender'),
    middleware: {
      provideDocumentFormattingEdits: (document, options, token, next) =>
        workspace.getConfiguration('wgslender').get<boolean>('format.enable', true)
          ? next(document, options, token)
          : undefined,
      // Push-model diagnostics (textDocument/publishDiagnostics).
      handleDiagnostics: (uri, diagnostics, next) => {
        if (strictMode()) escalateWarnings(diagnostics);
        next(uri, diagnostics);
      },
      // Pull-model diagnostics (textDocument/diagnostic) — the server
      // advertises diagnosticProvider, and this path bypasses
      // handleDiagnostics entirely.
      provideDiagnostics: async (document, previousResultId, token, next) => {
        const report = await next(document, previousResultId, token);
        if (report && strictMode() && 'items' in report && Array.isArray(report.items)) {
          escalateWarnings(report.items as Diagnostic[]);
        }
        return report;
      },
    },
  };
}
