/** Shareable lint configs. Mirrors src/lint/configs.zig. */

export interface SharedConfig {
  name: string;
  rules: Record<string, 'off' | 'warn' | 'error'>;
}

export const recommended: SharedConfig;
export const style: SharedConfig;
export const performance: SharedConfig;
export const portability: SharedConfig;
export const strict: SharedConfig;

/**
 * Shape of the `wgslender.*` settings object the LSP reads via
 * `workspace/configuration` (or `initializationOptions`). Documented
 * here so editors with TypeScript-driven completion (e.g.
 * `contributes.configuration` JSON Schema generators) can surface
 * the same keys the Zig handler parses.
 *
 * Keys mirror the Zig settings parser in `lsp/Handler.zig`
 * (`applyClientSettings`); fields the parser ignores (unknown keys,
 * wrong types) are accepted client-side without effect.
 */
export interface LspSettings {
  inlayHints?: { enabled?: boolean };
  diagnostics?: { enabled?: boolean };
  minifyMode?: 'off' | 'insights' | 'strict';
  minifyInsights?: {
    format?: 'delta' | 'bytes' | 'both';
    functionSize?: boolean;
    declSize?: boolean;
    totalSize?: boolean;
  };
  minifyLints?: {
    enabled?: boolean;
    /** M0500 budget in bytes; null/missing = rule no-ops. */
    budgetBytes?: number | null;
    /** Code → severity overrides (e.g. {"M0100": "warning"}). */
    severities?: Record<string, 'off' | 'hint' | 'info' | 'warn' | 'warning' | 'error'>;
  };
  /**
   * Phase 8 — opt-in: when true, the LSP runs the heavy full-minify
   * estimator (production renamer + gzip-of-output) for ground-truth
   * byte and gzip counts. Slower to recompute on every edit; defaults
   * to false (the cheap length-only estimator).
   */
  minifyEstimator?: { useFullMinify?: boolean };
  mangleExternalBindings?: boolean;
}

/**
 * JSON Schema-shaped descriptor for `LspSettings`. Editors that build
 * a `package.json` `contributes.configuration` schema from a JS object
 * (or VS Code language-server-protocol clients that synthesize
 * settings UI) can require this to populate dropdowns.
 */
export const lspSettingsSchema: {
  readonly type: 'object';
  readonly properties: Readonly<Record<string, unknown>>;
};
