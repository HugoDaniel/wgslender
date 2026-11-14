// Virtual documents for pngine inline `:code` parts.
//
// The language server names an inline part with a stable URI:
//
//   wgslender-pngine://part/<percent-encoded-program-path>/<part-index>/<sha256>
//
// This module is the desktop extension's half of that contract. It is pure
// Node/TypeScript — no `vscode` import — so the codec and the provider's
// cache can be exercised by `node --test` on a headless host. The extension
// entry point adapts it to `TextDocumentContentProvider` and answers the
// provider with the native `wgslender/pnginePart` request.
//
// Escaping is the same as `src/pngine/VirtualUri.zig`: every byte outside
// `A-Z a-z 0-9 - . _ ~` is `%XX` with uppercase hex, including `/` and `%`.
// Decoding runs exactly once, so a literal `%2F` in a path encodes as
// `%252F` and decodes back to `%2F`, never to a path separator.
//
// The URI hash is what makes reopening honest: the provider asks the server
// for the part named by the URI, and the server refuses (`missing part` or
// `stale part`) when the part disappeared or its `:code` text changed. The
// provider caches only successful text and evicts it when a SJON document
// changes or a fetch fails.

export const PNGINE_PART_SCHEME = 'wgslender-pngine';
const PREFIX = `${PNGINE_PART_SCHEME}://part/`;
const HEX = '0123456789ABCDEF';

export interface PnginePartUri {
  /** Canonical program document path, as encoded by the native store. */
  programPath: string;
  /** Source-order part index (`Types.PartId.index`). */
  partIndex: number;
  /** Lowercase hexadecimal SHA-256 of the author text the URI was minted for. */
  contentHash: string;
}

export interface PnginePartText {
  text: string;
  languageId: string;
}

export type PnginePartFetcher = (uri: string) => Promise<PnginePartText>;
export type PnginePartChangeListener = (uri: string) => void;

/** Encode `(program path, part index, content hash)` as a virtual URI. */
export function encodePnginePartUri(
  programPath: string,
  partIndex: number,
  contentHash: string,
): string {
  if (!isAbsoluteProgramPath(programPath)) throw invalidUri();
  if (!Number.isInteger(partIndex) || partIndex < 0 || partIndex > 0xffff_ffff) {
    throw invalidUri();
  }
  if (!/^[0-9a-f]{64}$/.test(contentHash)) throw invalidUri();

  return `${PREFIX}${encodeSegment(programPath)}/${partIndex}/${contentHash}`;
}

/** Decode a virtual URI, rejecting every ambiguous or malformed spelling. */
export function decodePnginePartUri(uri: string): PnginePartUri {
  if (!uri.startsWith(PREFIX)) throw invalidUri();
  const rest = uri.slice(PREFIX.length);

  const first = rest.indexOf('/');
  if (first <= 0) throw invalidUri();
  const encodedPath = rest.slice(0, first);

  const second = rest.indexOf('/', first + 1);
  if (second < 0) throw invalidUri();
  const indexText = rest.slice(first + 1, second);
  const hashText = rest.slice(second + 1);
  if (indexText.length === 0) throw invalidUri();
  if (hashText.includes('/')) throw invalidUri();
  if (!/^[0-9]+$/.test(indexText)) throw invalidUri();
  if (!/^[0-9a-fA-F]{64}$/.test(hashText)) throw invalidUri();

  const partIndex = Number(indexText);
  if (!Number.isSafeInteger(partIndex) || partIndex > 0xffff_ffff) throw invalidUri();

  const programPath = decodeSegment(encodedPath);
  if (!isAbsoluteProgramPath(programPath)) throw invalidUri();

  return { programPath, partIndex, contentHash: hashText.toLowerCase() };
}

function encodeSegment(text: string): string {
  const bytes = new TextEncoder().encode(text);
  let out = '';
  for (const byte of bytes) {
    if (isUnreserved(byte)) {
      out += String.fromCharCode(byte);
    } else {
      out += `%${HEX[byte >> 4]}${HEX[byte & 0x0f]}`;
    }
  }
  return out;
}

function decodeSegment(text: string): string {
  const bytes: number[] = [];
  let i = 0;
  while (i < text.length) {
    const code = text.charCodeAt(i);
    if (code === 0x25 /* % */) {
      if (i + 2 >= text.length) throw invalidUri();
      const hi = hexValue(text.charCodeAt(i + 1));
      const lo = hexValue(text.charCodeAt(i + 2));
      if (hi === undefined || lo === undefined) throw invalidUri();
      bytes.push((hi << 4) | lo);
      i += 3;
      continue;
    }
    if (!isUnreserved(code)) throw invalidUri();
    bytes.push(code);
    i += 1;
  }

  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(Uint8Array.from(bytes));
  } catch {
    throw invalidUri();
  }
}

function isUnreserved(code: number): boolean {
  return (
    (code >= 0x41 && code <= 0x5a) || // A-Z
    (code >= 0x61 && code <= 0x7a) || // a-z
    (code >= 0x30 && code <= 0x39) || // 0-9
    code === 0x2d || // -
    code === 0x2e || // .
    code === 0x5f || // _
    code === 0x7e // ~
  );
}

function hexValue(code: number): number | undefined {
  if (code >= 0x30 && code <= 0x39) return code - 0x30;
  if (code >= 0x61 && code <= 0x66) return code - 0x61 + 10;
  if (code >= 0x41 && code <= 0x46) return code - 0x41 + 10;
  return undefined;
}

function isAbsoluteProgramPath(path: string): boolean {
  if (path.length === 0 || path.includes('\0')) return false;
  // POSIX absolute, or a Windows drive/UNC spelling. The native store uses
  // the host's own path flavor; this accepts the shapes that can be minted.
  return (
    path.startsWith('/') ||
    path.startsWith('\\\\') ||
    /^[A-Za-z]:[\\/]/.test(path)
  );
}

function invalidUri(): Error {
  return new Error('invalid pngine part URI');
}

/**
 * `TextDocumentContentProvider` core with an explicit cache.
 *
 * `provideTextDocumentContent` is intentionally URI-in, text-out: the
 * extension adapts VS Code's `Uri` with `.toString()`. A fetch failure is
 * never cached, so reopening a stale URI re-asks the server instead of
 * replaying bytes the server already rejected.
 */
export class PnginePartProvider {
  private readonly cache = new Map<string, string>();
  private readonly listeners = new Set<PnginePartChangeListener>();
  private readonly fetchPart: PnginePartFetcher;

  constructor(fetchPart: PnginePartFetcher) {
    this.fetchPart = fetchPart;
  }

  get cacheSize(): number {
    return this.cache.size;
  }

  onDidChange(listener: PnginePartChangeListener): { dispose(): void } {
    this.listeners.add(listener);
    return { dispose: () => this.listeners.delete(listener) };
  }

  async provideTextDocumentContent(uri: string | { toString(): string }): Promise<string> {
    const key = typeof uri === 'string' ? uri : uri.toString();
    const cached = this.cache.get(key);
    if (cached !== undefined) return cached;

    // Validate the URI before asking a server for anything. A provider hit
    // for an unrelated scheme must not become a network request.
    decodePnginePartUri(key);

    let result: PnginePartText;
    try {
      result = await this.fetchPart(key);
    } catch (error) {
      this.cache.delete(key);
      throw error;
    }
    if (!result || result.languageId !== 'wgsl' || typeof result.text !== 'string') {
      this.cache.delete(key);
      throw new Error('invalid pngine part language id (expected wgsl)');
    }

    this.cache.set(key, result.text);
    return result.text;
  }

  /**
   * Drop cached text for one program document, or every program when
   * `programPath` is omitted. Emits `onDidChange` for each affected URI so
   * an open virtual editor refetches instead of showing old bytes.
   *
   * Returns the affected URIs in sorted order, which keeps tests and the
   * watcher deterministic.
   */
  invalidate(programPath?: string): string[] {
    const removed: string[] = [];
    for (const uri of this.cache.keys()) {
      if (programPath !== undefined) {
        let decoded: PnginePartUri;
        try {
          decoded = decodePnginePartUri(uri);
        } catch {
          continue;
        }
        if (decoded.programPath !== programPath) continue;
      }
      removed.push(uri);
    }

    removed.sort();
    for (const uri of removed) {
      this.cache.delete(uri);
      for (const listener of this.listeners) listener(uri);
    }
    return removed;
  }

  dispose(): void {
    this.cache.clear();
    this.listeners.clear();
  }
}
