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
