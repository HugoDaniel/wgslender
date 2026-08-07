/**
 * Turns the models from `panels.ts` into DOM.
 *
 * Everything here builds nodes with `createElement` and writes text through
 * `textContent`. That is deliberate: every string on this page — binding
 * names, struct fields, diagnostic messages — comes from whatever the visitor
 * typed into the editor, so an `innerHTML` shortcut would be a script
 * injection with extra steps.
 */
import type {
  DiagnosticRow,
  LspPosition,
  MinifyStats,
  ReflectModel,
} from './panels';

type Child = Node | string | null | undefined | false;

function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  attrs: Record<string, string> = {},
  children: Child[] = [],
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  for (const [name, value] of Object.entries(attrs)) node.setAttribute(name, value);
  for (const child of children) {
    if (child === null || child === undefined || child === false) continue;
    node.append(typeof child === 'string' ? document.createTextNode(child) : child);
  }
  return node;
}

function table(headers: string[], rows: string[][]): HTMLElement {
  return el('div', { class: 'table-scroll' }, [
    el('table', {}, [
      el('thead', {}, [el('tr', {}, headers.map((head) => el('th', {}, [head])))]),
      el(
        'tbody',
        {},
        rows.map((cells) => el('tr', {}, cells.map((cell) => el('td', {}, [cell])))),
      ),
    ]),
  ]);
}

function heading(text: string, note = ''): HTMLElement {
  return el('h3', { class: 'section-title' }, [text, note && el('span', { class: 'note' }, [note])]);
}

/** `1024` → `1.0 kB`. Sizes are UTF-8 bytes throughout. */
export function formatBytes(bytes: number): string {
  return bytes < 1024 ? `${bytes} B` : `${(bytes / 1024).toFixed(1)} kB`;
}

/**
 * Gzip `text` in the browser.
 *
 * The stats bar's compressed number has to describe the code actually on
 * screen, which is minified with whatever the pills currently say. The
 * server's `wgslender.server.showMinifiedOutput` reports a gzip count too, but for
 * *its* settings rather than the panel's, so the two would disagree the
 * moment a pill was toggled. Returns null where `CompressionStream` is
 * missing, and the column is then left out rather than guessed at.
 */
export async function gzipSize(text: string): Promise<number | null> {
  if (typeof CompressionStream === 'undefined') return null;
  const compressed = new Blob([text]).stream().pipeThrough(new CompressionStream('gzip'));
  return (await new Response(compressed).arrayBuffer()).byteLength;
}

export function renderStats(
  container: HTMLElement,
  stats: MinifyStats,
  gzip: number | null,
): void {
  const cell = (label: string, value: string, highlight = false) =>
    el('div', { class: highlight ? 'stat highlight' : 'stat' }, [
      el('span', { class: 'stat-label' }, [label]),
      el('span', { class: 'stat-value' }, [value]),
    ]);

  const cells = [
    cell('Original', formatBytes(stats.original)),
    cell('Minified', formatBytes(stats.minified)),
    cell('Saved', `${stats.savedPct}%`, true),
  ];
  if (gzip !== null) cells.push(cell('Gzip', formatBytes(gzip)));
  container.replaceChildren(...cells);
}

export function renderReflect(container: HTMLElement, model: ReflectModel): void {
  const sections: Child[] = [];

  if (model.errors.length > 0) {
    sections.push(
      el('div', { class: 'notice' }, [
        el('p', {}, ['This shader does not parse, so there is nothing to reflect on yet.']),
        el('ul', {}, model.errors.map((message) => el('li', {}, [message]))),
      ]),
    );
  }

  for (const group of model.bindingGroups) {
    sections.push(
      heading(group.title),
      table(
        ['Binding', 'Name', 'Type', 'Detail'],
        group.rows.map((row) => [
          `@group(${row.group}) @binding(${row.binding})`,
          row.name,
          row.type,
          row.access ? `${row.access}, ${row.detail}` : row.detail,
        ]),
      ),
    );
  }

  if (model.entryPoints.length > 0) {
    sections.push(
      heading('Entry points'),
      table(
        ['Name', 'Stage', 'Workgroup', 'Resources'],
        model.entryPoints.map((entry) => [
          entry.name,
          entry.stage,
          entry.workgroupSize || '—',
          entry.resources.join(', ') || '—',
        ]),
      ),
    );
  }

  for (const struct of model.structs) {
    sections.push(
      heading(struct.name, `${struct.size} B, align ${struct.alignment}`),
      table(
        ['Field', 'Type', 'Offset', 'Size', 'Align'],
        struct.fields.map((field) => [
          field.name,
          field.type,
          String(field.offset),
          String(field.size),
          String(field.alignment),
        ]),
      ),
    );
  }

  if (model.overrides.length > 0) {
    sections.push(
      heading('Overrides'),
      table(
        ['Name', 'id', 'Type', 'Default'],
        model.overrides.map((override) => [
          override.name,
          override.id || '—',
          override.type || '—',
          override.default || '—',
        ]),
      ),
    );
  }

  sections.push(
    el('details', { class: 'raw' }, [
      el('summary', {}, ['Raw reflection JSON']),
      el('pre', {}, [JSON.stringify(model.raw, null, 2)]),
    ]),
  );

  container.replaceChildren(...(sections.filter(Boolean) as Node[]));
}

export function renderDiagnostics(
  container: HTMLElement,
  rows: DiagnosticRow[],
  onPick: (position: LspPosition) => void,
): void {
  if (rows.length === 0) {
    container.replaceChildren(
      el('p', { class: 'empty' }, ['Nothing to report — this shader is clean.']),
    );
    return;
  }

  container.replaceChildren(
    el(
      'ul',
      { class: 'diagnostics' },
      rows.map((row) => {
        const button = el('button', { type: 'button', class: `diagnostic ${row.severity}` }, [
          el('span', { class: 'diagnostic-where' }, [`${row.line}:${row.col}`]),
          el('span', { class: 'diagnostic-code' }, [row.code]),
          el('span', { class: 'diagnostic-message' }, [row.message]),
        ]);
        button.addEventListener('click', () => onPick(row.position));
        return el('li', {}, [button]);
      }),
    ),
  );
}
