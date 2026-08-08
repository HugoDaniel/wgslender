// TreeDataProvider for the wgslenderReflection sidebar view.
//
// Backed by the same wgslender/reflect LSP request the palette command
// uses. Refreshes lazily on document changes (debounced upstream) and
// always reflects the currently active .wgsl editor.

import {
  Event,
  EventEmitter,
  ProviderResult,
  ThemeIcon,
  TreeDataProvider,
  TreeItem,
  TreeItemCollapsibleState,
} from 'vscode';
import { BaseLanguageClient } from 'vscode-languageclient';

interface ReflectResponse {
  uri: string;
  version: 1 | 2;
  /**
   * The reflection payload. Both transports embed it on the wire as a
   * nested object (`lsp/wire/workspace_commands.zig::appendReflectResult`
   * splices the pre-rendered JSON verbatim), so it arrives here parsed —
   * same trap `commands/lsp.ts` documents. Typed unknown so the string
   * case stays handled if a transport ever re-encodes.
   */
  json: unknown;
}

interface ReflectData {
  uri: string;
  bindings?: Array<{
    group: number;
    binding: number;
    name: string;
    addressSpace: string;
    type: string;
  }>;
  structs?: Record<string, { size: number; alignment: number; fields?: Array<{ name: string; type: string; offset: number; size: number }> }>;
  entryPoints?: Array<{
    name: string;
    stage: string;
    workgroupSize?: [number, number, number] | null;
  }>;
  overrides?: Array<{ name: string; type?: string; id?: number | null; default?: string }>;
  functions?: Array<{ name: string; calls?: string[]; inUse?: boolean }>;
  aliases?: Array<{ name: string; type: string }>;
  errors?: string[];
}

export class ReflectionNode extends TreeItem {
  constructor(
    label: string,
    collapsibleState: TreeItemCollapsibleState,
    public children?: ReflectionNode[],
  ) {
    super(label, collapsibleState);
  }
}

export class ReflectionProvider implements TreeDataProvider<ReflectionNode> {
  private readonly _onDidChangeTreeData = new EventEmitter<ReflectionNode | undefined>();
  readonly onDidChangeTreeData: Event<ReflectionNode | undefined> = this._onDidChangeTreeData.event;

  private data: ReflectData | undefined;
  private loading = false;

  constructor(private readonly client: BaseLanguageClient) {}

  getTreeItem(element: ReflectionNode): TreeItem {
    return element;
  }

  getChildren(element?: ReflectionNode): ProviderResult<ReflectionNode[]> {
    if (element) return element.children ?? [];
    if (this.loading) return [statusNode('Loading…')];
    if (!this.data) return [statusNode('Open a .wgsl file to populate.')];
    return rootNodes(this.data);
  }

  async refresh(uri: string | undefined, version: 'v1' | 'v2'): Promise<void> {
    if (!uri) {
      this.data = undefined;
      this._onDidChangeTreeData.fire(undefined);
      return;
    }

    this.loading = true;
    this._onDidChangeTreeData.fire(undefined);

    try {
      const response = await this.client.sendRequest<ReflectResponse>('wgslender/reflect', {
        textDocument: { uri },
        format: version,
        pretty: false,
      });
      const parsed = (
        typeof response.json === 'string' ? JSON.parse(response.json) : response.json
      ) as Omit<ReflectData, 'uri'>;
      this.data = { uri, ...parsed };
    } catch (err) {
      this.data = {
        uri,
        errors: [err instanceof Error ? err.message : String(err)],
      };
    } finally {
      this.loading = false;
      this._onDidChangeTreeData.fire(undefined);
    }
  }

  dispose(): void {
    this._onDidChangeTreeData.dispose();
  }
}

function statusNode(label: string): ReflectionNode {
  const node = new ReflectionNode(label, TreeItemCollapsibleState.None);
  node.iconPath = new ThemeIcon('info');
  return node;
}

function rootNodes(data: ReflectData): ReflectionNode[] {
  const out: ReflectionNode[] = [];

  if (data.errors && data.errors.length > 0) {
    const children = data.errors.map((msg) => {
      const item = new ReflectionNode(msg, TreeItemCollapsibleState.None);
      item.iconPath = new ThemeIcon('error');
      return item;
    });
    out.push(group(`Errors (${data.errors.length})`, 'warning', children));
  }

  if (data.entryPoints && data.entryPoints.length > 0) {
    out.push(
      group(
        `Entry Points (${data.entryPoints.length})`,
        'play',
        data.entryPoints.map((ep) => {
          const node = new ReflectionNode(ep.name, TreeItemCollapsibleState.None);
          node.description = ep.stage + (ep.workgroupSize ? ` @workgroup_size${formatTuple(ep.workgroupSize)}` : '');
          node.iconPath = new ThemeIcon(stageIcon(ep.stage));
          return node;
        }),
      ),
    );
  }

  if (data.bindings && data.bindings.length > 0) {
    const groups = new Map<number, typeof data.bindings>();
    for (const b of data.bindings) {
      if (!groups.has(b.group)) groups.set(b.group, []);
      groups.get(b.group)!.push(b);
    }
    const groupNodes = Array.from(groups.entries())
      .sort(([a], [b]) => a - b)
      .map(([groupId, bindings]) => {
        const items = bindings
          .slice()
          .sort((a, b) => a.binding - b.binding)
          .map((b) => {
            const node = new ReflectionNode(`@binding(${b.binding}) ${b.name}`, TreeItemCollapsibleState.None);
            node.description = b.type + (b.addressSpace ? ` <${b.addressSpace}>` : '');
            node.iconPath = new ThemeIcon('symbol-variable');
            return node;
          });
        return group(`@group(${groupId})`, 'symbol-namespace', items);
      });
    out.push(group(`Bind Groups (${groups.size})`, 'symbol-namespace', groupNodes));
  }

  if (data.structs) {
    const names = Object.keys(data.structs).sort();
    if (names.length > 0) {
      const children = names.map((name) => {
        const layout = data.structs![name];
        const item = new ReflectionNode(name, layout.fields && layout.fields.length > 0
          ? TreeItemCollapsibleState.Collapsed
          : TreeItemCollapsibleState.None);
        item.description = `${layout.size}B @ ${layout.alignment}`;
        item.iconPath = new ThemeIcon('symbol-struct');
        if (layout.fields && layout.fields.length > 0) {
          item.children = layout.fields.map((f) => {
            const fnode = new ReflectionNode(f.name, TreeItemCollapsibleState.None);
            fnode.description = `${f.type} (+${f.offset}, ${f.size}B)`;
            fnode.iconPath = new ThemeIcon('symbol-field');
            return fnode;
          });
        }
        return item;
      });
      out.push(group(`Structs (${names.length})`, 'symbol-struct', children));
    }
  }

  if (data.overrides && data.overrides.length > 0) {
    const children = data.overrides.map((ov) => {
      const node = new ReflectionNode(ov.name, TreeItemCollapsibleState.None);
      const idLabel = ov.id != null ? `@id(${ov.id}) ` : '';
      node.description = `${idLabel}${ov.type ?? ''}${ov.default ? ` = ${ov.default}` : ''}`;
      node.iconPath = new ThemeIcon('symbol-constant');
      return node;
    });
    out.push(group(`Overrides (${data.overrides.length})`, 'symbol-constant', children));
  }

  if (data.functions && data.functions.length > 0) {
    const inUse = data.functions.filter((f) => f.inUse !== false);
    if (inUse.length > 0) {
      const children = inUse.map((f) => {
        const node = new ReflectionNode(f.name, TreeItemCollapsibleState.None);
        if (f.calls && f.calls.length > 0) node.description = `→ ${f.calls.join(', ')}`;
        node.iconPath = new ThemeIcon('symbol-function');
        return node;
      });
      out.push(group(`Functions (${inUse.length})`, 'symbol-function', children));
    }
  }

  if (data.aliases && data.aliases.length > 0) {
    const children = data.aliases.map((a) => {
      const node = new ReflectionNode(a.name, TreeItemCollapsibleState.None);
      node.description = `= ${a.type}`;
      node.iconPath = new ThemeIcon('symbol-type-parameter');
      return node;
    });
    out.push(group(`Aliases (${data.aliases.length})`, 'symbol-type-parameter', children));
  }

  if (out.length === 0) {
    out.push(statusNode('No reflection data.'));
  }

  return out;
}

function group(label: string, icon: string, children: ReflectionNode[]): ReflectionNode {
  const node = new ReflectionNode(label, TreeItemCollapsibleState.Expanded, children);
  node.iconPath = new ThemeIcon(icon);
  return node;
}

function stageIcon(stage: string): string {
  switch (stage) {
    case 'vertex': return 'arrow-up';
    case 'fragment': return 'paintcan';
    case 'compute': return 'server-process';
    default: return 'play';
  }
}

function formatTuple([x, y, z]: [number, number, number]): string {
  return `(${x}, ${y}, ${z})`;
}
