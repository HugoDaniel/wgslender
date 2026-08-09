/**
 * Minify-size inlay hints, rendered as CodeMirror decorations.
 *
 * This is the one LSP feature the playground implements itself.
 * `@codemirror/lsp-client` covers completion, hover, rename, diagnostics and
 * the rest, but it has no inlay-hint support at all — so the request, the
 * position mapping and the widgets are ours.
 *
 * What the server gives us (`lsp/handler/inlay_hints.zig`):
 *
 * - Hints only when the effective minify mode is `insights` or `strict`, and
 *   only when the document currently parses and validates.
 * - One hint at `{0,0}` for the module total, one at each function's closing
 *   brace, one at each other declaration's `;`.
 * - Labels are byte deltas (`"-547 B"`, `"-1.2 KB"`), and every one carries
 *   the same tooltip disclosing that the number is an estimate.
 * - **No `kind` of their own.** The wire maps minify hints to LSP
 *   `InlayHintKind.Type`, the same integer type hints use
 *   (`lsp/wire/editing.zig::inlayHintKindCode`), so the tooltip is the only
 *   marker distinguishing them — hence `isMinifySizeHint`.
 * - The minify lane ignores the requested `range`; it is always
 *   whole-document. Type hints, by contrast, are range-filtered. Both facts
 *   are pinned in `tests/lsp-flow.test.mjs`.
 *
 * The decorations live in a `StateField`, not a `ViewPlugin`. A ViewPlugin
 * owns its own decorations and recomputes them from the view, which is the
 * wrong shape here: the hints arrive asynchronously from a debounced request,
 * and while that request is in flight the visitor keeps typing. A StateField
 * maps its ranges through every intervening change for free, so stale hints
 * drift with the text they annotate instead of pointing at the wrong column.
 */
import { StateEffect, StateField, type Extension, type Text } from '@codemirror/state';
import { Decoration, EditorView, WidgetType, type DecorationSet } from '@codemirror/view';

/** LSP `Position` — line and utf-16 character, both zero-based. */
export interface LspPosition {
  line: number;
  character: number;
}

/** An LSP `InlayHint`, narrowed to the fields this server actually sends. */
export interface LspInlayHint {
  position: LspPosition;
  /** A plain string, or `InlayHintLabelPart[]` when the hint links to a definition. */
  label: string | Array<{ value: string }>;
  kind?: number;
  tooltip?: string;
}

/**
 * First words of the tooltip every minify-size hint carries. Matching on a
 * prefix rather than the whole sentence means rewording the disclosure does
 * not silently switch the panel off.
 */
export const minifySizeTooltipPrefix = 'approximate minified byte size';

/** Flatten a hint label, which is a string or a list of parts. */
export function hintLabel(hint: LspInlayHint): string {
  return typeof hint.label === 'string'
    ? hint.label
    : hint.label.map((part) => part.value).join('');
}

/** Is this one of the server's minify-size hints, rather than a type hint? */
export function isMinifySizeHint(hint: LspInlayHint): boolean {
  return hint.tooltip?.startsWith(minifySizeTooltipPrefix) ?? false;
}

/**
 * LSP line/character → document offset, clamped at both ends.
 *
 * Clamping is not defensive padding: hints are requested on a debounce, so a
 * reply can arrive after the visitor has deleted the lines it describes.
 * Clamping puts the widget somewhere harmless until the next tick replaces
 * it; throwing would take the whole editor update down with it.
 */
export function offsetOfPosition(doc: Text, position: LspPosition): number {
  if (position.line < 0) return 0;
  if (position.line >= doc.lines) return doc.length;
  const line = doc.line(position.line + 1);
  return Math.min(line.from + Math.max(position.character, 0), line.to);
}

/**
 * Is this the module total? The server puts exactly one hint at `{0,0}` for
 * the whole file; every other hint sits on a closing brace or a `;`, so
 * nothing else can land there.
 */
function isModuleTotal(hint: LspInlayHint): boolean {
  return hint.position.line === 0 && hint.position.character === 0;
}

class MinifySizeWidget extends WidgetType {
  readonly label: string;
  readonly tooltip: string;
  /** Module totals render as their own line; per-declaration hints render inline. */
  readonly block: boolean;

  // Written out longhand rather than as TypeScript parameter properties:
  // those emit code, so Node's strip-only loader rejects them and the tests
  // here import this module directly.
  constructor(label: string, tooltip: string, block = false) {
    super();
    this.label = label;
    this.tooltip = tooltip;
    this.block = block;
  }

  /** Decides whether CodeMirror redraws. Without it the hints flicker on every tick. */
  eq(other: MinifySizeWidget): boolean {
    return (
      other.label === this.label && other.tooltip === this.tooltip && other.block === this.block
    );
  }

  toDOM(): HTMLElement {
    const host = document.createElement(this.block ? 'div' : 'span');
    host.className = this.block ? 'cm-minify-hint cm-minify-total' : 'cm-minify-hint';
    host.title = this.tooltip;

    if (this.block) {
      // Chrome, not data: the label is the server's, the caption only says
      // what it measures. Inline, "-547 B" would read as an annotation on the
      // first line of the file rather than on the file.
      const caption = document.createElement('span');
      caption.className = 'cm-minify-total-caption';
      caption.textContent = 'whole file';
      host.append(caption, document.createTextNode(this.label));
    } else {
      host.textContent = this.label;
    }

    return host;
  }
}

/**
 * Build the decoration set for `hints`, keeping only the minify-size ones.
 *
 * The server sends hints in traversal order, which is *not* document order —
 * the module total comes last, after every per-declaration hint. `Decoration.set`
 * throws on unsorted input, so the sort flag is load-bearing.
 */
export function minifyHintDecorations(doc: Text, hints: readonly LspInlayHint[]): DecorationSet {
  const ranges = hints.filter(isMinifySizeHint).map((hint) => {
    const label = hintLabel(hint);
    const tooltip = hint.tooltip ?? '';

    if (isModuleTotal(hint)) {
      return Decoration.widget({
        widget: new MinifySizeWidget(label, tooltip, true),
        // A block widget on its own line above the document. Inline at offset
        // 0 it would render *inside* line 1, in front of its first character.
        side: -1,
        block: true,
      }).range(0);
    }

    return Decoration.widget({
      widget: new MinifySizeWidget(label, tooltip),
      // Sit after the character at this offset, so a hint on a closing brace
      // reads `} -36 B` rather than pushing the brace rightwards.
      side: 1,
    }).range(offsetOfPosition(doc, hint.position));
  });

  return Decoration.set(ranges, true);
}

/** Replace the document's minify hints. Dispatch with `setMinifyHints`. */
const setHintsEffect = StateEffect.define<readonly LspInlayHint[]>();

const minifyHintsField = StateField.define<DecorationSet>({
  create: () => Decoration.none,

  update(decorations, transaction) {
    for (const effect of transaction.effects) {
      if (effect.is(setHintsEffect)) return minifyHintDecorations(transaction.newDoc, effect.value);
    }
    // No new hints: carry the existing ones through the edit. `map` keeps each
    // widget attached to the text it was measured against.
    return decorations.map(transaction.changes);
  },

  provide: (field) => EditorView.decorations.from(field),
});

/** Push a fresh hint set into `view`. An empty list clears the hints. */
export function setMinifyHints(view: EditorView, hints: readonly LspInlayHint[]): void {
  view.dispatch({ effects: setHintsEffect.of(hints) });
}

/**
 * Styling for the hint widgets. A base theme rather than a rule scoped to the
 * host page, because the widgets are created by this module and CodeMirror
 * owns the DOM they live in — a page-scoped stylesheet never reaches them.
 */
const minifyHintTheme = EditorView.baseTheme({
  '.cm-minify-hint': {
    marginLeft: '0.6em',
    padding: '0 0.35em',
    borderRadius: '3px',
    fontSize: '0.85em',
    // `cursor: help` is the affordance that says the tooltip is worth reading.
    cursor: 'help',
    backgroundColor: 'var(--pg-color-green-low)',
    color: 'var(--pg-color-green-high)',
    whiteSpace: 'nowrap',
  },

  '.cm-minify-total': {
    // `fit-content` keeps the block widget's background hugging its text
    // instead of striping the full editor width.
    width: 'fit-content',
    margin: '0.15em 0 0.15em 0.6em',
  },

  '.cm-minify-total-caption': {
    marginRight: '0.4em',
    opacity: '0.75',
  },
});

/** The extension to add to an editor that should show minify-size hints. */
export const minifyInsights: Extension = [minifyHintsField, minifyHintTheme];
