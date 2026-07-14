/**
 * Shareable lint configs for wgslender.
 *
 * GENERATED FILE — do not edit by hand. Regenerate with `zig build gen-npm`
 * (see tools/gen_npm.zig). The pack tables mirror src/lint/configs.zig and
 * the lspSettingsSchema minifier knobs mirror src/options.zig, so this
 * package can never silently drift from the Zig source of truth.
 *
 * Usage:
 *   const { recommended } = require('wgslender/configs');
 *   const { lint } = require('wgslender');
 *   await initialize();
 *   const result = lint(source, { extends: [recommended.name] });
 *
 * JS callers can either pass the config name (the WASM backend resolves it)
 * or merge rules client-side before calling `lint`.
 */

'use strict';

/** @type {{name: string, rules: Record<string, string>}} */
const recommended = {
  name: '@wgslender/recommended',
  rules: {
    'no-unused-vars': 'warn',
    'no-dead-code': 'warn',
    'no-unused-binding': 'warn',
    'no-unreachable': 'warn',
    'no-constant-condition': 'warn',
    'for-direction': 'warn',
    'no-duplicate-case': 'warn',
    'no-self-assign': 'warn',
    'no-redundant-casts': 'warn',
  },
};

/** @type {{name: string, rules: Record<string, string>}} */
const style = {
  name: '@wgslender/style',
  rules: {
    'naming-convention': 'warn',
    'prefer-let-over-var': 'warn',
    'no-empty': 'warn',
    'no-useless-return': 'warn',
    'no-lonely-if': 'warn',
    'no-shadow': 'warn',
  },
};

/** @type {{name: string, rules: Record<string, string>}} */
const performance = {
  name: '@wgslender/performance',
  rules: {
    'no-large-local-arrays': 'warn',
    'prefer-mix': 'warn',
  },
};

/** @type {{name: string, rules: Record<string, string>}} */
const portability = {
  name: '@wgslender/portability',
  rules: {
    'require-entry-point-attrs': 'error',
    'consistent-binding-annotations': 'warn',
    'no-f16-without-extension': 'warn',
  },
};

/** @type {{name: string, rules: Record<string, string>}} */
const minify = {
  name: '@wgslender/minify',
  rules: {
    'minify/external-binding-blocks-rename': 'hint',
    'minify/unused-const': 'hint',
    'minify/unused-override': 'hint',
    'minify/dead-code-kept': 'hint',
    'minify/long-entry-point-name': 'hint',
    'minify/shader-exceeds-size-budget': 'hint',
  },
};

/** @type {{name: string, rules: Record<string, string>}} */
const strict = {
  name: '@wgslender/strict',
  rules: {
    'no-unused-vars': 'error',
    'no-dead-code': 'error',
    'no-unused-binding': 'error',
    'no-unreachable': 'error',
    'no-constant-condition': 'error',
    'for-direction': 'error',
    'no-duplicate-case': 'error',
    'no-self-assign': 'error',
    'no-redundant-casts': 'warn',
    'prefer-mix': 'warn',
    'prefer-let-over-var': 'warn',
    'no-empty': 'warn',
    'no-useless-return': 'warn',
    'no-lonely-if': 'warn',
    'no-shadow': 'warn',
    'naming-convention': 'warn',
    'no-large-local-arrays': 'warn',
    'require-entry-point-attrs': 'error',
    'consistent-binding-annotations': 'error',
    'no-f16-without-extension': 'error',
    'max-params': 'warn',
    'max-depth': 'warn',
    'complexity': 'warn',
    'max-lines-per-function': 'warn',
  },
};

/**
 * Shape of the `wgslender.*` settings object the LSP reads. Identical
 * to `wgslender.json`'s schema (one parser serves both, see
 * `src/Config.zig::applyJsonValue`). Documented here so editor
 * configurations (VS Code `contributes.configuration`, CodeMirror
 * lsp-client wrappers) can synthesise UI without reaching into the
 * Zig source.
 *
 * Severity overrides live at the top level under `rules` (id-keyed,
 * ESLint-shape). LSP-only knobs are namespaced under `lsp.*`. Each
 * `workspace/configuration` push replaces the workspace overlay
 * wholesale.
 */
const lspSettingsSchema = Object.freeze({
  type: 'object',
  properties: {
    // LSP-only knobs.
    lsp: {
      type: 'object',
      properties: {
        inlayHints: { type: 'object', properties: { enabled: { type: 'boolean' } } },
        diagnostics: { type: 'object', properties: { enabled: { type: 'boolean' } } },
        minifyMode: { type: 'string', enum: ['off', 'insights', 'strict'] },
        minifyInsights: {
          type: 'object',
          properties: {
            format: { type: 'string', enum: ['delta', 'bytes', 'both'] },
            functionSize: { type: 'boolean' },
            declSize: { type: 'boolean' },
            totalSize: { type: 'boolean' },
          },
        },
        minifyLints: {
          type: 'object',
          properties: {
            enabled: { type: 'boolean' },
            budgetBytes: { type: ['integer', 'null'] },
          },
        },
        minifyEstimator: {
          type: 'object',
          properties: {
            // Phase 8 — opt-in ground-truth estimator. Slower to
            // recompute on every edit (runs the production
            // MinifyRenamer + gzip-of-output), but produces exact
            // byte and gzip counts instead of the cheap length-only
            // heuristic.
            useFullMinify: { type: 'boolean', default: false },
          },
        },
      },
    },
    // Per-rule severity overrides, id-keyed (ESLint-shape).
    rules: {
      type: 'object',
      additionalProperties: {
        type: 'string',
        enum: ['off', 'warn', 'warning', 'error'],
      },
    },
    extends: { type: 'array', items: { type: 'string' } },
    reportUnusedDisableDirectives: { type: 'boolean' },
    // CLI-minifier knobs (also accepted in wgslender.json).
    minifyWhitespace: { type: 'boolean' },
    minifyIdentifiers: { type: 'boolean' },
    minifySyntax: { type: 'boolean' },
    mangleExternalBindings: { type: 'boolean' },
    treeShaking: { type: 'boolean' },
    preserveUniformStructTypes: { type: 'boolean' },
    keepNames: { type: 'array', items: { type: 'string' } },
    sortDeclarations: { type: 'boolean' },
    scopeLocalRename: { type: 'boolean' },
  },
});

module.exports = {
  recommended,
  style,
  performance,
  portability,
  minify,
  strict,
  lspSettingsSchema,
};
