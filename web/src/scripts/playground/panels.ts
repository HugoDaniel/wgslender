/**
 * Everything the output panels show, as plain data.
 *
 * The three panels — Minified, Reflection, Diagnostics — are each a pure
 * function from a shader (or a server payload) to rows. Keeping them here,
 * free of DOM and of CodeMirror, is what lets `web/tests/panels.test.mjs`
 * check them against the real wasm instead of against a rendered page.
 *
 * `minify` and `reflect` come from the `wgslender` package, which must be
 * initialized before any of these run — the playground does that in
 * `wasm.ts`, the tests in their `before` hook.
 */
import { minify, reflect } from 'wgslender';
import type {
  BindingInfo,
  MinifyOptions,
  ReflectResult,
  StructLayout,
} from 'wgslender';

/* -------------------------------------------------------------- minify --- */

/** The subset of `MinifyOptions` the panel exposes as pills. */
export type PanelMinifyOptions = Pick<
  MinifyOptions,
  | 'minifyWhitespace'
  | 'minifyIdentifiers'
  | 'minifySyntax'
  | 'mangleExternalBindings'
  | 'treeShaking'
  | 'sortDeclarations'
  | 'scopeLocalRename'
>;

export interface PanelMinifyOption {
  key: keyof PanelMinifyOptions;
  label: string;
  /** What `minify()` does when the option is not passed at all. */
  default: boolean;
  help: string;
}

/**
 * The pills, in the order they are drawn. Defaults mirror the package's own
 * (`packages/js-npm/lib/main.d.ts`), so the panel opens showing stock
 * `minify(source)` behaviour rather than a configuration of our invention.
 */
export const minifyOptions: PanelMinifyOption[] = [
  {
    key: 'minifyWhitespace',
    label: 'Whitespace',
    default: true,
    help: 'Drop the spacing and newlines the parser does not need.',
  },
  {
    key: 'minifyIdentifiers',
    label: 'Identifiers',
    default: true,
    help: 'Rename locals and private declarations to short names.',
  },
  {
    key: 'minifySyntax',
    label: 'Syntax',
    default: true,
    help: 'Shorten what the syntax allows — 1.0 becomes 1., and so on.',
  },
  {
    key: 'mangleExternalBindings',
    label: 'Mangle bindings',
    default: false,
    help: 'Rename uniform and storage variables too. Breaks name-based binding lookup.',
  },
  {
    key: 'treeShaking',
    label: 'Tree shaking',
    default: true,
    help: 'Remove declarations no entry point can reach.',
  },
  {
    key: 'sortDeclarations',
    label: 'Sort declarations',
    default: false,
    help: 'Group declarations by kind so the output compresses better.',
  },
  {
    key: 'scopeLocalRename',
    label: 'Scope-local rename',
    default: false,
    help: 'Reuse short names per scope, which also compresses better.',
  },
];

export function defaultMinifyOptions(): PanelMinifyOptions {
  return Object.fromEntries(
    minifyOptions.map((option) => [option.key, option.default]),
  ) as PanelMinifyOptions;
}

export interface MinifyStats {
  /** UTF-8 bytes in, as the toolkit counts them. */
  original: number;
  /** UTF-8 bytes out. */
  minified: number;
  /** Percentage saved, to one decimal. Zero for an empty document. */
  savedPct: number;
}

export interface MinifyModel {
  code: string;
  stats: MinifyStats;
  /**
   * Parse failures, as messages.
   *
   * Deliberately `string[]` and not the declared `MinifyError[]`: the wasm
   * boundary serializes only `message` (`src/api_json.zig` `writeMinifyJson`),
   * so the `line` and `column` that `MinifyOptions`' sibling type promises are
   * always `undefined` at runtime. Rendering them would print "undefined".
   */
  errors: string[];
}

/** Run the minifier with the pills applied over its own defaults. */
export function buildMinifyModel(
  source: string,
  options: Partial<PanelMinifyOptions> = {},
): MinifyModel {
  const result = minify(source, { ...defaultMinifyOptions(), ...options });
  const { originalSize, minifiedSize } = result;

  return {
    code: result.code,
    stats: {
      original: originalSize,
      minified: minifiedSize,
      savedPct:
        originalSize === 0 ? 0 : Math.round((1 - minifiedSize / originalSize) * 1000) / 10,
    },
    errors: result.errors.map((error) => error.message),
  };
}

/* ------------------------------------------------------------- reflect --- */

export interface BindingRow {
  group: number;
  binding: number;
  name: string;
  type: string;
  /** Access mode for storage buffers; empty otherwise. */
  access: string;
  /** Size, stride or sample type — whatever the kind makes worth showing. */
  detail: string;
}

export interface BindingGroup {
  title: string;
  rows: BindingRow[];
}

export interface StructFieldRow {
  name: string;
  type: string;
  offset: number;
  size: number;
  alignment: number;
}

export interface StructRow {
  name: string;
  size: number;
  alignment: number;
  fields: StructFieldRow[];
}

export interface EntryPointRow {
  name: string;
  stage: string;
  /** `8×4×1` for compute, empty for vertex and fragment. */
  workgroupSize: string;
  /** Bindings reachable from this entry point, sorted for stable display. */
  resources: string[];
}

export interface OverrideRow {
  name: string;
  /** `@id(N)` as text; empty when the override is keyed by name. */
  id: string;
  type: string;
  default: string;
}

export interface ReflectModel {
  /** Only non-empty groups, in binding-kind order. */
  bindingGroups: BindingGroup[];
  structs: StructRow[];
  entryPoints: EntryPointRow[];
  overrides: OverrideRow[];
  errors: string[];
  /** The untouched engine output, behind the panel's JSON disclosure. */
  raw: ReflectResult;
}

/**
 * Which table a binding belongs in.
 *
 * Derived from `bindings[]` rather than read from the v2 `uniforms` /
 * `storage` / `textures` / `samplers` subset arrays, so this also works on v1
 * output — those arrays are optional. `panels.test.mjs` pins the derivation
 * against the engine's own subsets so the two cannot drift apart.
 *
 * Address space is checked first: storage *textures* live in the handle
 * space, so there is no overlap with `var<storage>`.
 */
function classify(binding: BindingInfo): string {
  if (binding.addressSpace === 'uniform') return 'Uniforms';
  if (binding.addressSpace === 'storage') return 'Storage';

  const kind = binding.typeInfo?.kind;
  if (kind === 'texture' || binding.type.startsWith('texture_')) return 'Textures';
  if (kind === 'sampler' || binding.type.startsWith('sampler')) return 'Samplers';
  return 'Other';
}

function bindingDetail(binding: BindingInfo): string {
  if (binding.array) {
    const { elementStride, elementCount } = binding.array;
    const count = elementCount === null ? 'runtime-sized' : `${elementCount} elements`;
    return `stride ${elementStride} B, ${count}`;
  }
  if (binding.layout) return `${binding.layout.size} B, align ${binding.layout.alignment}`;

  const info = binding.typeInfo;
  if (info?.kind === 'texture') {
    // A sampled texture reports its sample type, a storage texture its texel
    // format; a depth texture reports neither.
    return [info.texKind, info.sampleType ?? info.format ?? ''].filter(Boolean).join(' ');
  }
  if (info?.kind === 'sampler') return info.comparison ? 'comparison' : 'non-comparison';
  return '';
}

function fieldsOf(layout: StructLayout): StructFieldRow[] {
  return layout.fields.map((field) => ({
    name: field.name,
    type: field.type,
    offset: field.offset,
    size: field.size,
    alignment: field.alignment,
  }));
}

/** `[8, 4, 1]` → `8×4×1`; `null` (vertex / fragment) → empty. */
function formatWorkgroupSize(size: [number, number, number] | null): string {
  return size ? size.join('×') : '';
}

export function buildReflectModel(source: string): ReflectModel {
  const info = reflect(source);

  const titles = ['Uniforms', 'Storage', 'Textures', 'Samplers', 'Other'];
  const bindingGroups = titles
    .map((title) => ({
      title,
      rows: info.bindings
        .filter((binding) => classify(binding) === title)
        .map((binding) => ({
          group: binding.group,
          binding: binding.binding,
          name: binding.name,
          type: binding.type,
          access: binding.accessMode ?? '',
          detail: bindingDetail(binding),
        })),
    }))
    .filter((group) => group.rows.length > 0);

  return {
    bindingGroups,
    // `structs` is keyed by name and its key order is not source order, so
    // sort it — otherwise the table reshuffles between reparses.
    structs: Object.entries(info.structs)
      .map(([name, layout]) => ({
        name,
        size: layout.size,
        alignment: layout.alignment,
        fields: fieldsOf(layout),
      }))
      .sort((a, b) => a.name.localeCompare(b.name)),
    entryPoints: info.entryPoints.map((entry) => ({
      name: entry.name,
      stage: entry.stage,
      workgroupSize: formatWorkgroupSize(entry.workgroupSize),
      resources: [...entry.resources].sort(),
    })),
    overrides: info.overrides.map((override) => ({
      name: override.name,
      id: override.id === null ? '' : String(override.id),
      type: override.type ?? '',
      default: override.default ?? '',
    })),
    errors: info.errors ?? [],
    raw: info,
  };
}

/* --------------------------------------------------------- diagnostics --- */

export type DiagnosticSeverity = 'error' | 'warning' | 'info' | 'hint';

/** An LSP `Position`: zero-based line and utf-16 character. */
export interface LspPosition {
  line: number;
  character: number;
}

export interface DiagnosticRow {
  severity: DiagnosticSeverity;
  code: string;
  /** One-based, for display. */
  line: number;
  /** One-based, for display. */
  col: number;
  message: string;
  /** The raw zero-based LSP position, for moving the editor's cursor. */
  position: LspPosition;
  /** Spec link from `codeDescription`, when the server sent one. */
  href: string;
}

export interface PublishDiagnosticsPayload {
  uri?: string;
  diagnostics?: {
    range: { start: LspPosition; end: LspPosition };
    severity?: number;
    code?: string | number;
    message: string;
    codeDescription?: { href: string };
  }[];
}

/** LSP `DiagnosticSeverity`. A missing severity means error, per the spec. */
const severities: DiagnosticSeverity[] = ['error', 'warning', 'info', 'hint'];

/**
 * Turn a `textDocument/publishDiagnostics` payload into display rows, most
 * severe first and then in document order.
 *
 * The server currently happens to publish validator errors ahead of lint
 * warnings, but that is its business and not a guarantee — the panel sorts.
 */
export function formatDiagnostics(payload: PublishDiagnosticsPayload | undefined): DiagnosticRow[] {
  const rank = (row: DiagnosticRow) => severities.indexOf(row.severity);

  return (payload?.diagnostics ?? [])
    .map((diagnostic) => {
      const start = diagnostic.range.start;
      return {
        severity: severities[(diagnostic.severity ?? 1) - 1] ?? 'error',
        code: diagnostic.code === undefined ? '' : String(diagnostic.code),
        line: start.line + 1,
        col: start.character + 1,
        message: diagnostic.message,
        position: start,
        href: diagnostic.codeDescription?.href ?? '',
      };
    })
    .sort(
      (a, b) => rank(a) - rank(b) || a.line - b.line || a.col - b.col,
    );
}
