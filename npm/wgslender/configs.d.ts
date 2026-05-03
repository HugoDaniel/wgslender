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
 * `workspace/configuration` (or `initializationOptions`). The schema is
 * identical to `wgslender.json` — set a key in the file and the same
 * key works in your editor's LSP settings with identical semantics.
 *
 * Each `workspace/configuration` push replaces the workspace overlay
 * wholesale; clients omitting a key reset it to the project-layer
 * (or default) value. The Zig parser is permissive: unknown keys and
 * wrong types are accepted without effect.
 */
export interface LspSettings {
  /**
   * LSP-only knobs live under this namespace. CLI/file users set
   * these too — they're forwarded into the LSP layer when discovered
   * from `wgslender.json`.
   */
  lsp?: {
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
    };
    /**
     * Phase 8 — opt-in: when true, the LSP runs the heavy full-minify
     * estimator (production renamer + gzip-of-output) for ground-truth
     * byte and gzip counts. Slower to recompute on every edit;
     * defaults to false (the cheap length-only estimator).
     */
    minifyEstimator?: { useFullMinify?: boolean };
  };
  /**
   * Per-rule severity overrides keyed by rule id (e.g.
   * `"minify/external-binding-blocks-rename"`). Same shape as
   * ESLint's `rules` field; same shape as `wgslender.json`'s.
   * Both project (`wgslender.json`) and workspace
   * (`workspace/configuration`) layers contribute; workspace wins.
   */
  rules?: Record<string, 'off' | 'warn' | 'warning' | 'error'>;
  /** Lint pack inheritance, e.g. `["@wgslender/recommended"]`. */
  extends?: string[];
  /**
   * Treat unused `wgslender-disable` comments as warnings. Flows through
   * to the linter via `Linter.Options.report_unused_disable_directives`.
   */
  reportUnusedDisableDirectives?: boolean;
  /**
   * CLI-minifier knobs (also live in `wgslender.json`). The LSP
   * forwards these to the `wgslender.showMinifiedOutput` command and
   * uses them to key the per-document estimator cache, so flipping
   * any of them invalidates the displayed insights.
   */
  minifyWhitespace?: boolean;
  minifyIdentifiers?: boolean;
  minifySyntax?: boolean;
  treeShaking?: boolean;
  preserveUniformStructTypes?: boolean;
  /**
   * Rename `@group/@binding` vars directly. Same field drives both the
   * minifier output and the LSP M0100 hint gate — to silence the hint
   * without changing minifier behavior, set the rule to `off` via
   * `rules: { "minify/external-binding-blocks-rename": "off" }`.
   */
  mangleExternalBindings?: boolean;
  keepNames?: string[];
  sortDeclarations?: boolean;
  scopeLocalRename?: boolean;
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
