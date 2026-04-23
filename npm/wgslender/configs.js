/**
 * Shareable lint configs for wgslender.
 *
 * Usage:
 *   const { recommended } = require('wgslender/configs');
 *   const { lint } = require('wgslender');
 *   await initialize();
 *   const result = lint(source, { extends: [recommended.name] });
 *
 * These exports mirror the built-in Zig configs (src/lint/configs.zig) so
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
    'naming-convention': 'warn',
    'no-large-local-arrays': 'warn',
    'require-entry-point-attrs': 'error',
    'consistent-binding-annotations': 'error',
    'no-f16-without-extension': 'error',
  },
};

module.exports = {
  recommended,
  style,
  performance,
  portability,
  strict,
};
