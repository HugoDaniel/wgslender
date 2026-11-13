# pngine Implicit Inclusion and Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make imported files and inline parts implicitly available to hover, definition, references, completion, rename, and related editor features without exposing assembled offsets.

**Architecture:** A request-context layer maps an author position into every containing root. Feature handlers operate on existing AST/analysis types, then project results back to `Location`/origin types. Declaration identity is based on origin and local declaration range, never a root-local `SymbolIndex` alone.

**Tech Stack:** Zig 0.16, existing Handler feature modules, LSP `Location[]` and multi-file `WorkspaceEdit`, VS Code virtual-document provider.

**Spec:** `docs/plans/pngine-shaders/README.md`

## Global Constraints

- Current/open text is authoritative.
- Module-scope declarations are order-independent; locals retain source-order scope.
- Never compare symbols across roots by `SymbolIndex` alone.
- Never return an assembled URI/range.
- Rename requires one unambiguous declaration identity across roots.
- Inline virtual documents are read-only to edits/refactors.
- Formatting stays local.
- Existing standalone responses remain semantically unchanged.
- Project behavior is native-only; the wasm LSP keeps today’s single-source responses.
- Every project text read goes through `SourceProvider`; no feature opens a project file directly.

## Interfaces consumed

- `Handler.analyzeRoot` and phase-03 root caches.
- `Assembled.offsetFromOrigin`, `offsetToOrigin`, and range mapping.
- Existing `NodeAtOffset.find`, `Edits.findReferences`, completion/hover/signature helpers.
- Existing native navigation and edit codecs; the wasm codecs stay single-source.
- The injected `SourceProvider` and phase-01 project text; no feature reads a project file directly.

## Interfaces produced

```zig
pub const Location = struct { uri: []const u8, range: Range };
pub const DocumentEdits = struct { uri: []const u8, edits: []const LspTextEdit };
pub const WorkspaceChanges = struct { documents: []const DocumentEdits };

pub const RequestContext = struct {
    root: RootId,
    analysis: *RootAnalysis,
    origin: Pngine.OriginKey,
    assembled_offset: u32,
};

pub fn contextsAt(
    handler: *Handler,
    uri: []const u8,
    position: Position,
) ![]RequestContext;

pub fn declarationKey(
    context: *const RequestContext,
    symbol: Ast.SymbolIndex,
) ?SymbolKey;
```

`SymbolKey` is `{origin, declaration_range}`. `contextsAt` returns one identity context for standalone documents and all valid containing roots for composed documents.

Existing `computeDefinition`, `computeTypeDefinition`, and `computeReferences` migrate to location slices. `computeRename` returns `WorkspaceChanges`. `computeDocumentHighlight` remains local ranges.

## File structure

- Create `lsp/handler/pngine_context.zig`: request contexts and symbol identity.
- Create `lsp/handler/pngine_symbols.zig`: cross-root reference/edit collection.
- Modify hover, definition, references_rename, completion, signature_help, semantic_tokens, inlay_hints, code_actions.
- Modify native navigation, symbols, editing, and wire/lspkit codecs; do not add project routes to the wasm adapters.
- Create `npm/wgslender-vscode/src/pngine-parts.ts` and register the virtual provider in the native/desktop host; the web/wasm host keeps single-source behaviour.
- Create `tests/pngine_navigation_test.zig`, `tests/pngine_rename_test.zig`, `tests/pngine_completion_test.zig`, `tests/pngine_editing_test.zig`.

## Ordered work

### Task 1: Request mapping and location shapes

**Files:** `pngine_context.zig` as named above, `Handler.zig`, navigation/edit codecs, tests.

- [ ] Add red tests for local→assembled→local round trips, multi-root contexts, inline origins, and invalid positions.
- [ ] Implement `contextsAt`, `declarationKey`, and origin-aware `Location`/`WorkspaceChanges`.
- [ ] Update codecs to carry each result’s own URI and group rename edits by document. Current single-URI assumptions are at `lsp/lspkit/navigation.zig:22-50` and `lsp/lspkit/edits.zig:32-43`.
- [ ] Preserve legacy shape: a standalone definition still serializes as one Location and standalone rename as a one-key `changes` object.
- [ ] Run existing navigation/symbol/editing parity suites before migrating feature logic; all pass.
- [ ] Commit: `refactor: carry URIs in WGSL navigation results`.

### Task 2: Hover, definitions, and signature help

**Files:** `hover.zig`, `definition.zig`, `signature_help.zig`, `pngine_context.zig` as above, tests.

- [ ] Add red cases for sibling function/type hover, root-to-fragment and fragment-to-root definition, inline definitions, and root-varying holes.
- [ ] Resolve `NodeAtOffset` at each mapped assembled offset; never call it with an author-local offset against assembled text.
- [ ] Deduplicate definition locations and hover/signature text. If content differs, include root labels rather than selecting the first.
- [ ] Map the returned hover range back to the request’s own origin.
- [ ] Apply the same location path to declaration and type definition.
- [ ] Keep builtin hover/completion behavior when no user symbol resolves.
- [ ] Run hover/definition/type/signature tests on the native LSP; the wasm single-source suites remain green.
- [ ] Commit: `feat: navigate pngine symbols across parts`.

### Task 3: References, highlights, and safe multi-file rename

**Files:** `references_rename.zig`, `pngine_symbols.zig`, symbols adapters/codecs, tests.

- [ ] Add red tests for shared declarations, divergent root bindings, include/exclude declaration, inline references, duplicate dedupe, and multi-file edits.
- [ ] Resolve the target in every root and compare `SymbolKey`. If keys differ, references report the ambiguity and rename/prepareRename decline rather than merging unrelated symbols.
- [ ] Collect `Edits.findReferences` per root, map each to its origin, and deduplicate by `(URI, range)`.
- [ ] Filter highlights to the current document while preserving read/write kind.
- [ ] Validate `new_name` with the existing WGSL identifier check and verify no affected root gains a declaration collision.
- [ ] Group edits by URI; refuse if any edit targets inline virtual text.
- [ ] Ensure open unsaved siblings receive edits against their current ranges.
- [ ] Run references/highlight/rename and native wire tests; the wasm single-source suites remain green.
- [ ] Commit: `feat: rename symbols across pngine file parts`.

### Task 4: Completion and member resolution

**Files:** `completion.zig`, tests.

- [ ] Add red tests for imported globals, root declarations, inline parts, locals before/after cursor, shadowing, and conflicting root types.
- [ ] Union active module-scope symbols from all root contexts; dedupe labels and retain compatible type details.
- [ ] Keep the existing `VisibleLocals` source-order rules (`completion.zig:135-222`) but evaluate them at each assembled cursor offset.
- [ ] Resolve member bases through the mapped AST/symbol first. Restrict the error-recovery name fallback to compatible active symbols; do not use the first same-named symbol across all roots (`completion.zig:92-108`).
- [ ] Preserve attribute, builtin, keyword, type, and swizzle lists.
- [ ] Run completion tests on the native LSP; the wasm single-source completion suite remains green.
- [ ] Commit: `feat: complete names from composed pngine modules`.

### Task 5: Semantic tokens, inlay hints, code actions, and formatting boundary

**Files:** listed feature modules and `tests/pngine_editing_test.zig`.

- [ ] Add red tests for cross-part symbol classification, current-file filtering, conflicting roots, safe/unsafe fixes, and formatting a fragment with holes.
- [ ] Map token offsets for symbol resolution but emit semantic tokens only for the current document’s own lexed text. Current token generation is explicitly local at `semantic_tokens.zig:58-80`.
- [ ] Filter inlay hints by origin and dedupe identical labels; omit conflicting answers. Show module-size hints only for an unambiguous root.
- [ ] Keep document symbols, folding, selection range, and ordinary highlights scoped to the current part; do not synthesize an assembled outline.
- [ ] Reuse phase-03 mapped diagnostics for code actions; reject edits crossing origins or touching inline code.
- [ ] Leave `computeFormatting` on the current buffer so a fragment with unresolved-alone holes still formats through the content-preserving parser path.
- [ ] Run all existing feature suites and native editing tests; the wasm single-source editing suite remains green.
- [ ] Commit: `feat: preserve per-file editing views in pngine projects`.

### Task 6: Inline virtual documents and native parity

**Files:** `pngine-parts.ts` as named above, the desktop extension entry point, native adapters, tests and npm fixtures.

- [ ] Add red tests for URI escaping, reopened/stale inline parts, provider missing part, and exact definition ranges.
- [ ] Implement the stable virtual URI encoder/decoder in shared project code and the VS Code desktop provider.
- [ ] Answer `wgslender/pnginePart` with current author text and language ID WGSL; invalidate the provider when the SJON part changes or disappears.
- [ ] Ensure every native LSP result shape is identical whether the project text came from open buffers or the filesystem provider; the wasm host parity is the reserved follow-on.
- [ ] Run the existing `npm test` suites for the LSP package and the VS Code desktop extension tests covering provider registration; no web/wasm project path is added.
- [ ] Commit: `feat: expose pngine inline WGSL parts to editors`.

## Exhaustive use-case inventory

| ID | Fixture or synthetic input | Action | Expected result | Why phase 04 |
|---|---|---|---|---|
| N01 | Fragment call to sibling function | Hover | Full resolved signature from assembled analysis. | Basic implicit inclusion. |
| N02 | Fragment uses sibling struct | Definition/type definition | Location in sibling `.wgsl`. | Cross-file type navigation. |
| N03 | Root calls fragment function | Definition | Location in imported file. | Root-to-fragment navigation. |
| N04 | Fragment references root declaration | Definition | Location in root file. | Holes supplied by root. |
| N05 | Diamond-shared declaration | Definition | One location, not one per graph path. | Graph dedupe. |
| N06 | `demo/palette.wgsl` symbol | Definition/references | Same declaration identity across four roots. | Multi-root shared library. |
| N07 | Hole resolves to different declarations in different roots | Definition | All distinct root-labelled locations; no first-root choice. | Genuine ambiguity. |
| N08 | Same differing hole | Hover | Root-labelled type/signature variants. | Root-specific semantics. |
| N09 | Builtin with no user declaration | Hover/definition | Existing builtin hover; no fake project definition. | Builtin fallback. |
| N10 | Declaration in inline `:code` | Definition | Exact range in stable virtual WGSL URI. | Inline navigation. |
| N11 | Inline reference from file part | References | Inline virtual location plus file locations. | Mixed-origin references. |
| N12 | Inline part removed/changed in SJON | Reopen old URI | Provider reports unavailable or updates content; never serves stale text silently. | Inline invalidation. |
| N13 | Client cannot open virtual scheme | Definition response | Related SJON form remains available where diagnostics provide it; no malformed URI. | Degraded client behavior. |
| N14 | Reference on blanked duplicate directive | Definition | Null because no semantic copy exists. | Negative directive mapping. |
| N15 | Reference on original hoisted directive | Feature request | Resolve through hoisted copy where meaningful. | Directive request mapping. |
| N16 | References with `includeDeclaration=false` | References | Declaration locations omitted in every origin. | Existing option semantics. |
| N17 | Same reference reached through four roots | References | One `(URI,range)` entry. | Cross-root dedupe. |
| N18 | Unrelated same-named symbols in separate roots | References | Only references bound to the selected declaration are returned. | Symbol identity safety. |
| N19 | Divergent target across roots | Rename/prepareRename | Refusal; no edits. | Rename ambiguity guard. |
| N20 | Shared file-backed declaration | Rename | Multi-file WorkspaceEdit containing every bound reference once. | Required cross-part rename. |
| N21 | New name invalid WGSL identifier | Rename | Existing rejection behavior. | Identifier validation. |
| N22 | New name collides in one root | Rename | Refusal before returning any edits. | Semantic collision safety. |
| N23 | Rename set includes inline code | Prepare/rename | Refusal; no virtual-document write. | Inline edit boundary. |
| N24 | Rename with unsaved sibling edits | Rename | Ranges derive from current open sibling text. | Unsaved-buffer correctness. |
| N25 | Document highlight on shared symbol | Highlight | Only current-document references, with read/write kinds. | Local highlighting. |
| N26 | Complete inside fragment | Completion | Imported and root module-scope names included. | Global completion. |
| N27 | Module declaration textually after cursor | Completion | Included because module scope is order-independent. | Correct WGSL scope. |
| N28 | Local declared after cursor | Completion | Excluded by existing local scope rules. | Local source order. |
| N29 | Shadowing local vs module symbol | Hover/member/completion | Bound local wins through AST symbol resolution. | Shadowing. |
| N30 | Error-recovery `p.` with same name in several contexts | Member completion | Only compatible active fields; otherwise empty, never first arbitrary symbol. | Fallback hardening. |
| N31 | Same completion label with same type in four roots | Completion | One item. | Completion dedupe. |
| N32 | Same label with different root types | Completion | One item with root-variant detail or separate root-labelled items; never a silent arbitrary type. | Conflicting completion detail. |
| N33 | Inline module-scope declaration | Completion from file | Included like a file declaration. | `:code` inclusion. |
| N34 | Attribute/builtin/keyword/type completion | Completion | Existing inventories unchanged. | No-regression behavior. |
| N35 | Cross-part function call | Signature help | Resolved parameters from the correct root context. | Related navigation feature. |
| N36 | Semantic tokens for current file | Request | Local token stream with composed symbol classification; no tokens from siblings. | Per-file rendering. |
| N37 | Symbol classified differently by root | Semantic tokens | Conservative lexical/unmodified result rather than arbitrary classification. | Conflicting presentation. |
| N38 | Type inlay from sibling declaration | Inlay hint | Correct hint at current-file position only. | Per-file hints. |
| N39 | Conflicting inlay types | Inlay hint | Omit conflicting hint; do not flicker by root order. | Presentation stability. |
| N40 | Shared fragment minify-size request | Inlay/code lens | No ambiguous whole-module size; root-local hints remain where unambiguous. | Module metric boundary. |
| N41 | Local diagnostic with safe fix | Code action | Existing single-file fix is returned. | Quick-fix compatibility. |
| N42 | Fix crosses parts or touches inline text | Code action | Withheld. | Edit safety. |
| N43 | Format fragment containing holes | Format | Only current buffer is formatted; no assembly or validation-first refusal beyond existing parse errors. | Formatting boundary. |
| N44 | File in no project | All features | Existing single-document results and JSON shapes remain compatible. | Standalone regression. |
| N45 | No valid root/cycle/missing file | Feature request | Use available local behavior or null; never resolve through stale assembled offsets. | Broken-graph degradation. |
| N46 | Pass-only context | Hover/definition | Author-text links work; generated prelude names have no definition. | Pass boundary. |
| N47 | Multi-root workspace with duplicate URI spellings | References/rename | Canonical identity dedupes results while response URIs remain valid for the client. | URI identity. |
| N48 | Native LSP, same fixture in memory and through the filesystem provider | Compare responses | Location/edit/completion JSON is independent of whether provider text is open-buffer or filesystem; wasm parity is the reserved follow-on. | Native transport consistency. |

## Red-first and gate commands

- `zig build test -j1`: exit `0`; all `N01–N48` plus existing hover/definition/reference/rename/completion/editing suites pass.
- `zig build lsp && zig build lsp-wasm -Dlsp=false`: both exit `0`; `lsp-wasm` advertises no project capability and fetches no SJON.
- `(cd npm/wgslender-lsp && npm test)`: exit `0`; the package exposes no project API.
- VS Code desktop extension tests: the provider registers, opens an inline definition, and applies a file-backed multi-file rename; the web host stays single-source.
- Performance guard: repeated hover/completion against an unchanged root reuse phase-03 analysis and perform no SJON parse, assembly, or project provider read.

## Stop-and-report conditions

- A feature cannot map its request/result positions without using assembled offsets in an author document.
- Two roots resolve a requested rename to different declarations. Refuse; do not pick one.
- Inline editing would require writing through the virtual provider. Keep it read-only.
- Existing single-document wire shapes change unintentionally.
- A proposed completion fallback depends on global name order rather than symbol identity.

## Risks

- **Large cross-root reference sets:** dedupe by URI/range and reuse cached analyses.
- **Incorrect rename semantics:** declaration identity and all-root collision checks are mandatory gates.
- **Virtual-document lifecycle:** explicit invalidation and missing-part responses prevent stale content.
- **Feature regressions:** existing suites remain on the identity-context path and native transport parity is retained; the wasm path is unchanged.
- **Presentation conflicts:** omit or label root variants rather than letting hash order choose output.

---
