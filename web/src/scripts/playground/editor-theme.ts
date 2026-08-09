/**
 * CodeMirror styling for the playground, expressed entirely in the design
 * tokens defined in `style.css`.
 *
 * Every colour here is a `var(--pg-color-*)` reference, which means the
 * editor follows the page's light/dark media query at paint time with no JS
 * and no second palette to keep in sync. That is also why this is a
 * `theme()` and a `HighlightStyle` rather than plain CSS: CodeMirror builds
 * its DOM at runtime, so a stylesheet scoped to the host page would never
 * match it.
 */
import { HighlightStyle, syntaxHighlighting } from '@codemirror/language';
import { EditorView } from '@codemirror/view';
import { tags as t } from '@lezer/highlight';
import type { Extension } from '@codemirror/state';

const chrome = EditorView.theme({
  '&': {
    height: '100%',
    color: 'var(--pg-color-white)',
    backgroundColor: 'var(--pg-color-bg)',
    fontSize: 'var(--pg-text-code-sm)',
  },
  '&.cm-focused': { outline: '2px solid var(--pg-color-text-accent)' },
  '.cm-scroller': {
    fontFamily: 'var(--pg-font-system-mono)',
    lineHeight: '1.6',
    overflow: 'auto',
  },
  '.cm-content': { caretColor: 'var(--pg-color-text-accent)' },
  '.cm-cursor, .cm-dropCursor': { borderLeftColor: 'var(--pg-color-text-accent)' },
  '.cm-gutters': {
    backgroundColor: 'var(--pg-color-bg)',
    color: 'var(--pg-color-gray-4)',
    borderRight: '1px solid var(--pg-color-hairline)',
  },
  '.cm-activeLine': { backgroundColor: 'var(--pg-color-gray-6)' },
  '.cm-activeLineGutter': {
    backgroundColor: 'var(--pg-color-gray-6)',
    color: 'var(--pg-color-white)',
  },
  '&.cm-focused .cm-selectionBackground, .cm-selectionBackground, .cm-content ::selection': {
    backgroundColor: 'var(--pg-color-accent-low)',
  },
  '.cm-selectionMatch': { backgroundColor: 'var(--pg-color-accent-low)' },
  '.cm-matchingBracket, .cm-nonmatchingBracket': {
    outline: '1px solid var(--pg-color-gray-4)',
  },
  // Completion, hover and signature-help popups all come from lsp-client.
  '.cm-tooltip': {
    backgroundColor: 'var(--pg-color-bg-nav)',
    color: 'var(--pg-color-white)',
    border: '1px solid var(--pg-color-hairline-shade)',
    borderRadius: '0.25rem',
    fontFamily: 'var(--pg-font-system)',
    fontSize: 'var(--pg-text-xs)',
  },
  '.cm-tooltip .cm-tooltip-arrow:after': { borderTopColor: 'var(--pg-color-bg-nav)' },
  '.cm-tooltip.cm-tooltip-autocomplete > ul > li': { fontFamily: 'var(--pg-font-system-mono)' },
  '.cm-tooltip.cm-tooltip-autocomplete > ul > li[aria-selected]': {
    backgroundColor: 'var(--pg-color-accent)',
    color: 'var(--pg-color-white)',
  },
  '.cm-panels': {
    backgroundColor: 'var(--pg-color-bg-nav)',
    color: 'var(--pg-color-white)',
    fontFamily: 'var(--pg-font-system)',
    fontSize: 'var(--pg-text-xs)',
  },
});

const highlight = HighlightStyle.define([
  { tag: t.comment, color: 'var(--pg-color-gray-3)', fontStyle: 'italic' },
  { tag: t.keyword, color: 'var(--pg-color-purple-high)', fontWeight: '600' },
  { tag: t.modifier, color: 'var(--pg-color-orange-high)' },
  { tag: t.attributeName, color: 'var(--pg-color-orange-high)' },
  { tag: t.typeName, color: 'var(--pg-color-blue-high)' },
  { tag: [t.number, t.bool], color: 'var(--pg-color-green-high)' },
  { tag: t.standard(t.variableName), color: 'var(--pg-color-blue-high)' },
  { tag: t.function(t.variableName), color: 'var(--pg-color-text-accent)' },
  { tag: t.propertyName, color: 'var(--pg-color-white)' },
  { tag: t.variableName, color: 'var(--pg-color-white)' },
  { tag: [t.operator, t.punctuation], color: 'var(--pg-color-gray-3)' },
]);

/**
 * `syntaxHighlighting` without `fallback` outranks the one `basicSetup`
 * installs, so this palette wins wherever it defines a tag.
 */
export const playgroundTheme: Extension = [chrome, syntaxHighlighting(highlight)];
