/**
 * CodeMirror styling for the playground, expressed entirely in Starlight's
 * design tokens.
 *
 * Every colour here is a `var(--sl-color-*)` reference, which means the
 * editor follows the site's light/dark toggle at paint time with no JS and no
 * second palette to keep in sync. That is also why this is a `theme()` and a
 * `HighlightStyle` rather than plain CSS: CodeMirror builds its DOM at
 * runtime, so Astro's scoped styles would never match it.
 */
import { HighlightStyle, syntaxHighlighting } from '@codemirror/language';
import { EditorView } from '@codemirror/view';
import { tags as t } from '@lezer/highlight';
import type { Extension } from '@codemirror/state';

const chrome = EditorView.theme({
  '&': {
    height: '100%',
    color: 'var(--sl-color-white)',
    backgroundColor: 'var(--sl-color-bg)',
    fontSize: 'var(--sl-text-code-sm)',
  },
  '&.cm-focused': { outline: '2px solid var(--sl-color-text-accent)' },
  '.cm-scroller': {
    fontFamily: 'var(--sl-font-system-mono)',
    lineHeight: '1.6',
    overflow: 'auto',
  },
  '.cm-content': { caretColor: 'var(--sl-color-text-accent)' },
  '.cm-cursor, .cm-dropCursor': { borderLeftColor: 'var(--sl-color-text-accent)' },
  '.cm-gutters': {
    backgroundColor: 'var(--sl-color-bg)',
    color: 'var(--sl-color-gray-4)',
    borderRight: '1px solid var(--sl-color-hairline)',
  },
  '.cm-activeLine': { backgroundColor: 'var(--sl-color-gray-6)' },
  '.cm-activeLineGutter': {
    backgroundColor: 'var(--sl-color-gray-6)',
    color: 'var(--sl-color-white)',
  },
  '&.cm-focused .cm-selectionBackground, .cm-selectionBackground, .cm-content ::selection': {
    backgroundColor: 'var(--sl-color-accent-low)',
  },
  '.cm-selectionMatch': { backgroundColor: 'var(--sl-color-accent-low)' },
  '.cm-matchingBracket, .cm-nonmatchingBracket': {
    outline: '1px solid var(--sl-color-gray-4)',
  },
  // Completion, hover and signature-help popups all come from lsp-client.
  '.cm-tooltip': {
    backgroundColor: 'var(--sl-color-bg-nav)',
    color: 'var(--sl-color-white)',
    border: '1px solid var(--sl-color-hairline-shade)',
    borderRadius: '0.25rem',
    fontFamily: 'var(--sl-font-system)',
    fontSize: 'var(--sl-text-xs)',
  },
  '.cm-tooltip .cm-tooltip-arrow:after': { borderTopColor: 'var(--sl-color-bg-nav)' },
  '.cm-tooltip.cm-tooltip-autocomplete > ul > li': { fontFamily: 'var(--sl-font-system-mono)' },
  '.cm-tooltip.cm-tooltip-autocomplete > ul > li[aria-selected]': {
    backgroundColor: 'var(--sl-color-accent)',
    color: 'var(--sl-color-white)',
  },
  '.cm-panels': {
    backgroundColor: 'var(--sl-color-bg-nav)',
    color: 'var(--sl-color-white)',
    fontFamily: 'var(--sl-font-system)',
    fontSize: 'var(--sl-text-xs)',
  },
});

const highlight = HighlightStyle.define([
  { tag: t.comment, color: 'var(--sl-color-gray-3)', fontStyle: 'italic' },
  { tag: t.keyword, color: 'var(--sl-color-purple-high)', fontWeight: '600' },
  { tag: t.modifier, color: 'var(--sl-color-orange-high)' },
  { tag: t.attributeName, color: 'var(--sl-color-orange-high)' },
  { tag: t.typeName, color: 'var(--sl-color-blue-high)' },
  { tag: [t.number, t.bool], color: 'var(--sl-color-green-high)' },
  { tag: t.standard(t.variableName), color: 'var(--sl-color-blue-high)' },
  { tag: t.function(t.variableName), color: 'var(--sl-color-text-accent)' },
  { tag: t.propertyName, color: 'var(--sl-color-white)' },
  { tag: t.variableName, color: 'var(--sl-color-white)' },
  { tag: [t.operator, t.punctuation], color: 'var(--sl-color-gray-3)' },
]);

/**
 * `syntaxHighlighting` without `fallback` outranks the one `basicSetup`
 * installs, so this palette wins wherever it defines a tag.
 */
export const playgroundTheme: Extension = [chrome, syntaxHighlighting(highlight)];
