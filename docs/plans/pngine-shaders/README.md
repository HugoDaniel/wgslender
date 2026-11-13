# wgslender understands pngine shader projects

**Status:** design and ordered implementation plans.  
**Owner-approved scope:** composed diagnostics and implicit inclusion for hover, definition, references, completion, and rename.  
**Implementation order:** `01` → `02` → `03` → `04` → `05`. Each phase must leave the tree green and be independently shippable.

## Intent

A `.wgsl` file referenced by a pngine `(wgsl …)` or `(shader-module …)` form is not necessarily a complete WGSL module. wgslender must discover that reference, reconstruct every module containing the file, and analyze the file in those contexts.

The author continues to edit the original file. Assembled text is an analysis artifact, never a document the author must see or maintain.

The corpus drives the acceptance cases:

- `clock/program.sjon:31-36` defines a shared library, four dependent fragments, and one `sceneCode` root.
- `demo/program.sjon:34-39` shares `palette` among four roots.
- `bounce/program.sjon:12` and `veclock/program.sjon:15` are single-file roots and must not change behavior.

## Goals

1. Resolve sibling declarations during validation, lint, hover, definition, references, completion, signature help, and rename.
2. Judge unused/dead-code rules on assembled modules rather than isolated fragments.
3. Use unsaved text for every open part, with the current buffer authoritative for its own part.
4. Preserve exact author-local diagnostic and edit locations, including hoisted directives.
5. Support a file referenced by multiple roots or programs without arbitrarily choosing one.
6. Match pngine’s assembled bytes and line table exactly.
7. Keep native, WASM, CLI, release-tarball, and single-source behavior working.
8. Make cache invalidation explicit: a WGSL keystroke must not reparse the project’s SJON documents.

## Non-goals

- Running pngine, linking against pngine, or reproducing its pipeline/resource validation.
- Generating a project manifest or requiring markers inside WGSL.
- Applying pngine’s math-constant substitution or `(constant …)` specialization in the editor.
- Generating pass preludes, splitting pass `post()` modules, or validating pass-generated bindings.
- Workspace-wide diagnostic publication for closed files.
- Changing the single-source npm/C/Go/Rust APIs into project APIs.
- Cross-part call hierarchy, workspace-symbol expansion, or assembled-document formatting.
- SJON `(import …)` composition in this version. Discovery must recognize it and fail closed rather than constructing a partial graph. pngine’s import/rebinding semantics are separate behavior documented at `pngine/schema/pngine.sjon:1351-1369` and implemented by `document_import.zig`; they are not silently approximated.

## Anti-goals

- Reporting an unresolved identifier merely because it is declared in another part.
- Reporting a library declaration as globally dead when a root uses it.
- Replacing an open buffer with stale disk contents.
- Selecting the first project or root when several are valid.
- Returning assembled-text offsets as if they were offsets in an open `.wgsl` file.
- Applying a rename or quick fix to a different symbol in another root.
- Making release-tarball or `-Dlsp=false` builds depend on a sibling checkout.

## Evidence and constraints

### pngine is the semantic authority

`pngine/src/dsl_sjon/fragments.zig:1-50` defines roots, fragments, dependency-order assembly, directive hoisting, newline termination, and the line-only mapping invariant. Its public bounds are `1024` fragments, `64` imports per form, depth `64`, and `64` directives (`fragments.zig:56-83`).

The assembler emits a fragment once even in a diamond (`fragments.zig:789-851`), blanks hoisted directives without moving columns (`fragments.zig:393-463`), and attributes an end-of-text diagnostic to the root (`fragments.zig:186-205`).

The schema requires exactly one of `:code` and `:file` for fragments and shader modules (`pngine/schema/pngine.sjon:1484-1512`). `:requires` names author-declared holes, not SJON references (`pngine/schema/pngine.sjon:1492-1495` and `:1128-1139`).

pngine validates before minification and maps diagnostics through its assembly (`pngine/src/dsl_sjon/Emitter.zig:2403-2457`). wgslender will mirror only author-text assembly and mapping, not pngine’s later rewrites.

### SJON integration

Use `sjon.parse`/`sjon.Parser.parse` and the public `Ast.Tree` readers. SJON returns a recovered tree with diagnostics rather than throwing on syntax errors (`SJON/src/Parser.zig:8-21`); wgslender must not typed-walk an erroneous tree as though it were authoritative, following SJON’s own configuration reader precedent (`SJON/src/lsp/editor_config.zig:154-178`).

SJON 1.7.0 is the dependency baseline (`SJON/src/version.zig:8`). Its ordinary Zig consumption is `b.dependency(...).module("sjon")` and `@import("sjon")` (`SJON/README.md:85-108`). The `wasm32-freestanding` path is already exercised with `plugin-exec=false`, no libc, and `sjon.parse` forced through code generation (`pngine/build.zig:958-983`, `pngine/src/dsl_sjon/wasm_smoke.zig:13-23`), which keeps the reserved wasm follow-on feasible without making it a deliverable here.

### Packaging

Project support ships **native only**: the native CLI (`wgslender` subcommands) and the native LSP (`zig build lsp`). That is the whole shipping surface of phases 01–05.

Add SJON as a pinned **URL + hash** dependency, not a path dependency. The existing comments explain why a submodule/path-only solution breaks release archives (`build.zig.zon:14-24`). Mark it lazy in the same manifest:

```zig
.sjon = .{ .url = "…", .hash = "…", .lazy = true },
```

The build boundary, concretely:

1. Read the `lsp` option **before** the module declarations (today it is read at `build.zig:112-119`). A `-Dlsp=false` build declares the core, CLI, `wasm`, `lib`, `lsp-wasm`, and `release-assets` graphs and returns before `lsp_kit` or SJON is asked for (`build.zig:99-129`), so a core-only build fetches neither. `lsp-wasm` uses no `lsp_kit`, and `release-assets` builds only `wasm` and `lsp-wasm`, so both stay on the core side of that return even though they are LSP/release artefacts.
2. On the native-LSP/CLI path, resolve SJON with `b.lazyDependency("sjon", …)` and thread its module into the `wgslender` module (or add it as an optional import), so `src/pngine/*` compiles only where the dependency was resolved.
3. `zig build wasm` (`src/wasm.zig` → `src/root.zig`), `zig build lib` (`src/lib.zig`), and `zig build lsp-wasm` (`lsp/wasm.zig`, the npm `wgslender-lsp` package behind the VS Code extension) carry `pngine_support = false` permanently. They advertise no project capability, keep today’s single-source behaviour, do not import SJON, and never call `lazyDependency("sjon")`. The npm minify/validate/reflect API does not gain project awareness.
4. A generated build option, `pngine_support`, compiles project entry points out of every graph that did not resolve the dependency. There is no undetected “maybe SJON exists” runtime mode.

The dependency stays lazy, never eager: `wgslender-sys/build.rs` must build offline from a vendored source tree, and merely asking for a lazy dependency makes the build runner fetch it (`build.zig:104-111`). The Rust packaging path packages that constraint today (`scripts/release.sh:78-87`).

This is the shape the build already has for `lsp_kit`, and project support adds no new network requirement to a lane that had none: a default (`lsp=true`) `zig build wasm` already asks for the lazy dependency and the runner fetches it (`build.zig:99-129`), while `-Dlsp=false` fetches nothing.

### LSP integration

The current document analysis cache is keyed by `parse.module_version` (`lsp/Handler.zig:69-104`, `:495-568`). That remains the standalone path; composed roots need a separate cache because their inputs include sibling text and graph revisions.

Current diagnostics use one document’s `PositionMapper` (`lsp/handler/diagnostics.zig:122-199`), related information is always assigned the current URI (`lsp/lspkit/diagnostics.zig:34-50`, `lsp/wire/diagnostics.zig:18-35`), and pull diagnostics currently derive their result ID only from document/configuration state (`lsp/Handler.zig:336-350`).

Current definition/reference/rename results are also single-document: definitions return a range (`lsp/handler/definition.zig:16-25`), native adapters attach the request URI (`lsp/native/navigation.zig:25-35`, `:62-75`), and rename emits a one-key `WorkspaceEdit` (`lsp/lspkit/edits.zig:32-43`).

Watched-file invalidation is added to the native dispatcher; the WASM method table stays unchanged in this set (`lsp/wasm.zig:99-137`). Push and pull diagnostics must remain equivalent.

### CLI

The current subcommands are `minify`, `validate`, `lint`, `reflect`, and `compile` (`src/options.zig:77-81`). `validate` exits `1` for invalid input (`cli/main.zig:751-777`); `lint` uses `0`/`1` for diagnostic outcomes and `2` for invalid `--fix` usage (`cli/main.zig:915-993`). Preserve those conventions.

There is no CLI `format` subcommand. LSP formatting remains a local, content-preserving operation over the open buffer (`lsp/handler/formatting.zig:13-38`).

## Approaches considered

### A. Shell out to pngine — rejected

This would make the editor dependent on an executable, complicate unsaved buffers, and still require mapping and cache work. It also violates the approved in-process SJON decision.

### B. Treat `sjon-lsp.sjon` as a membership manifest — rejected

A marker can narrow discovery, but it cannot prove that a WGSL file belongs to a program. Membership comes only from a concrete `:file` reference. This also handles several documents referencing one file and files referenced outside a workspace root.

### C. Compose lowered pngine output — rejected

It would describe text the author did not write and would make unsaved editing and inline-code mapping unreliable. Directive hoisting is retained because it is part of WGSL assembly, not pngine lowering.

### D. Analyze one preferred root per file — rejected

It would hide root-specific failures and make shared-fragment navigation dependent on root order. wgslender will analyze all containing shader-module roots and merge results according to symbol and diagnostic identity.

### E. In-process, per-program graph with per-root analysis — chosen

SJON supplies parsing; wgslender owns discovery, graph caching, byte-exact assembly, per-root analysis, and origin mapping. This is the smallest design that supports both diagnostics and navigation without changing pngine.

## Project model

### Source provider invariant

The project store reads project text and enumerates candidate documents only through a `SourceProvider` owned by the `Handler` — conceptually `SourceProvider { readText(canonical_path) ![]u8, candidates(dir) ![]Path }`. The native CLI and native LSP bind a filesystem provider. Nothing in phases 01–04 reads a project file outside that provider, and no task may assume the provider is the filesystem. A future wasm host binds an injected provider over the reserved message below; that is the one seam that keeps the door open, not a delivery in this set.

### Identity

- **Program:** the graph extracted from one valid `.sjon` root document. Its identity is the canonical document path.
- **Part:** one `(wgsl …)`, `(shader-module …)`, or `(pass …)` form. Its identity is `(program, form occurrence)`, not its display name.
- **Fragment:** a `wgsl` part.
- **Root:** a `shader-module` or `pass` part.
- **Part name:** unique only within a valid program. Imports resolve against that program’s fragment table, never against a workspace-global name.
- **Root ID:** `(program ID, part ID)`. Passes do not acquire synthetic `main`/`post` IDs because no lowering is performed.
- **File membership:** the set of parts whose normalized `:file` target names the same file.
- **Origin:** either a file path or an inline-code location `(document, form occurrence, :code span)`.

A file may be a fragment in one program and a root in another. That is represented directly, not rejected as ambiguous.

### Discovery

1. Decode and normalize the document URI/path. Existing files use filesystem canonicalization so symlink aliases identify the same target; missing files retain a lexical absolute identity. Windows drive/UNC forms and separators are handled explicitly. Windows lookup is case-insensitive; POSIX lookup remains case-sensitive.
2. Search all workspace roots, not only the first. The current first-root config choice at `lsp/NativeServer.zig:233-250` is not reused as the project model.
3. Read candidate `.sjon` documents and expand `sjon-lsp.sjon` bundle `:files` patterns. A marker contributes candidates only.
4. If workspace discovery finds no reference, walk ancestor directories, including ancestors above the workspace root, inspecting immediate `.sjon` files and marker bundles.
5. Parse every candidate independently. A syntax error invalidates only that document. If a previous valid snapshot exists, retain it as a explicitly stale snapshot; otherwise the document contributes no membership.
6. Index only exact file references recovered from valid forms. Do not infer membership from directory layout, marker presence, or fragment name.
7. Preserve every candidate. LSP requests operate on all resulting contexts; CLI artifact-producing commands require explicit selection when needed.

Every read and directory enumeration in these steps goes through `SourceProvider`; the native binding is a filesystem implementation. No project code opens a path directly.

Discovery is bounded by a per-refresh limit of `4096` visited directories, `1024` candidate SJON documents, and `64 MiB` of SJON input. Exceeding a limit produces a project-incomplete result and a request for explicit `--project` in the CLI; it never silently returns “not in a project.”

### Text authority and caching

The precedence for a part is:

1. open buffer;
2. provider-injected text (reserved for a future wasm host; native has none);
3. text returned by the provider (native: disk).

Each cached document/part carries a SHA-256 content hash. Each root cache key contains the graph revision and the hashes of all contributing parts. Mtime may be used only as a hint to avoid a read; equality always depends on content.

- WGSL edit: update that part and invalidate only roots containing it.
- SJON create/change/delete: reparse that document and rebuild affected program/reverse-membership entries.
- Marker change: invalidate discovery, not WGSL text.
- Open-file external change: keep the open buffer authoritative.
- Closed sibling change: invalidate its dependent roots.
- No watcher response: `didOpen`, `didSave`, explicit project selection, and CLI invocation perform content-checked refresh.

Add `workspace/didChangeWatchedFiles` handling and client file watchers. Without a notification, cached data remains valid only until the next defined refresh boundary; there is no background full-project polling on keystrokes.

### Assembly and mapping

For each shader-module root:

1. Depth-first post-order traversal of root imports.
2. Emit each fragment once, then root text.
3. Hoist leading `enable`, `requires`, and module-scope `diagnostic` directives in part-walk order.
4. Deduplicate directives with pngine’s whitespace-insensitive comparison.
5. Blank every original directive byte except newlines.
6. Newline-terminate every part.

The map contains both line rows and byte-range segments:

- body segment;
- hoisted directive segment;
- original blanked directive segment;
- synthetic terminating newline;
- root/part identity.

Assembled → origin mapping is used for diagnostics and responses. Origin → assembled mapping is used for requests. A request at a blanked original directive follows its hoisted copy when one exists; a duplicate that was only blanked has no semantic target. A range crossing unrelated origins is split for references or rejected as a single primary diagnostic/edit.

### Pass decision

Passes are represented in the graph because their imports establish membership. Their generated prelude and post-processing split are not reproduced (`pngine/schema/pngine.sjon:2515-2540`, `:2591-2598`; `pngine/src/dsl_sjon/hooks.zig:2820-2887`).

Consequences:

- File-backed fragments imported only by passes receive syntax and graph diagnostics, not a semantic “valid module” claim.
- CLI validation of an explicitly selected pass root refuses with exit `2`.
- Navigation may still use the pass’s inline author text, but generated names such as prelude bindings have no definition.
- Mixed pass/shader-module membership uses the valid shader-module roots for composed diagnostics.
- Pass-only semantic support requires a separately approved author-text model.

### Diagnostics policy

- **Errors:** union across all valid shader-module roots containing the file.
- **Same defect in several roots:** deduplicate by origin range, code, and original message; attach every failing root as related information.
- **Root-specific failure:** retain the diagnostic and name the failing root.
- **Unresolved E0100:** append `— declared nowhere in pngine module '<root>'`; related information points to the root’s `.sjon` form.
- **W0001/W0002/W0003:** report only when the finding holds in every valid root containing that part. This is the “globally unused in this project” policy and prevents a library used by one root from reading as dead everywhere.
- **Other lint rules:** union and deduplicate by origin/code/message.
- **Module-size/minify diagnostics:** meaningful only for a uniquely identified root; never pretend one root’s size is a property of every shared fragment.
- **Primary location:** only diagnostics whose primary origin is the requested document are returned in that document’s report. Related information may point elsewhere.
- **Publication:** open documents only. An edit republishes every open document sharing an affected root. Pull returns the same set as full push.
- **No project:** unchanged legacy behavior.
- **Known fragment with no valid shader-module root:** local syntax plus an explicit project diagnostic; no misleading standalone semantic errors.

New project diagnostics:

| Code | Severity | Message contract |
|---|---|---|
| `P0001` | warning | `pngine project context is incomplete: <reason>; only local syntax is reported` |
| `P0002` | error | `pngine module '<root>' cannot be assembled: <cycle/unknown import/bound>` |
| `P0003` | error | `fragment '<fragment>' requires '<name>', declared nowhere in pngine module '<root>'` |
| `P0004` | warning | `pngine pass '<pass>' requires generated bindings; semantic validation is unavailable for this context` |

`P0002`/`P0003` carry related information to the controlling `.sjon` form. No `spec_ref` is invented for project diagnostics.

### Implicit inclusion policy

All request positions begin in an author part and are mapped into each relevant root. All results are mapped back to origins.

- Hover and signature help use the resolved symbol in each root; identical answers deduplicate, differing answers name their roots.
- Definition, declaration, and type definition return `Location[]`, including cross-file targets.
- References return unique `Location`s across all parts and roots.
- Document highlight is the reference set filtered to the requested document.
- Completion unions module-scope names from every root. Module-scope WGSL declarations remain order-independent; function locals retain existing source-order and shadowing rules.
- Rename is allowed only when every containing root resolves the target to the same declaration origin. It produces a multi-file `WorkspaceEdit`.
- A rename whose edit set touches inline code is refused during `prepareRename`; file-backed cross-part rename remains supported.
- Semantic tokens and inlay hints are filtered to the current origin. Conflicting root-specific answers are omitted rather than chosen arbitrarily.
- Formatting always rewrites only the current buffer.
- Quick fixes must map wholly to one real file and be valid in every affected root. Cross-part and inline-code fixes are withheld.

### Inline code

An inline `:code` part has no file path. Give it a stable virtual URI:

```text
wgslender-pngine://part/<percent-encoded-program-path>/<form-occurrence>
```

The VS Code extension registers a `TextDocumentContentProvider` backed by a custom `wgslender/pnginePart` request. Hover and references can therefore display inline text, and definition can land on its exact WGSL range. The native CLI and native LSP use the same URI and location shapes; a future wasm host would reuse them (reserved follow-on).

A client that cannot open that scheme still receives the controlling `.sjon` form as related information where available. Rename and quick fixes never write the virtual document.

### CLI and library matrix

| Operation | Project behavior |
|---|---|
| `validate` | Auto-compose every containing shader-module root; valid only if all are valid. `--root` restricts the set. |
| `lint` | Same discovery and merging policy as LSP. Fixes apply only to the input file. |
| `reflect` | Compose one selected root. Multiple roots require `--root`. Reflection describes the assembled module; numeric offsets are explicitly assembled-text offsets. |
| `minify` | Compose and minify one selected root; multiple roots require `--root`. |
| `compile` | Compose and compile one selected root; multiple roots require `--root`. |
| LSP `format` | Current part only; no assembly. |
| Zig library | Add experimental `wgslender.Pngine` project/assembly/mapping APIs; existing source functions remain unchanged. |
| npm/C/Go/Rust single-source APIs | No project call and no signature change. |
| WASM LSP | No project behavior in this set: today’s single-source responses, no new capability, no SJON import. The injected-source protocol is the reserved follow-on below. |

New CLI flags, registered through `src/options.zig`:

- `--project <program.sjon>`: use this root SJON document and bypass discovery.
- `--root <name>`: select one root within the selected/discovered program.
- `--no-project`: preserve single-source behavior for this invocation.

`--project` with stdin requires `--root`; stdin replaces that root’s own author text. Project selection/ambiguity usage errors exit `2`. Author graph/validation failures produce diagnostics and exit `1`.

Project-mode JSON diagnostics retain the existing envelope and add optional fields only when applicable:

```json
{
  "file": "kernels/lib.wgsl",
  "project": "/abs/program.sjon",
  "root": "sceneCode",
  "related": [
    {"file": "/abs/program.sjon", "line": 36, "column": 1, "message": "…"}
  ]
}
```

Unmapped single-source JSON remains byte-compatible.

Minify source maps are remapped from assembled coordinates to author origins, with one `sources[]` entry per contributing file/virtual part. Reflection does not claim those offsets are author-local.

## WASM project input contract (reserved follow-on)

**Out of scope for phases 01–05.** `zig build lsp-wasm` (`lsp/wasm.zig`, the npm `wgslender-lsp` package behind the VS Code extension) ships with no project capability: it advertises nothing new, keeps today’s single-source behaviour, and does not import SJON.

The contract is recorded so the native implementation does not close the door. WASM cannot synchronously read the workspace filesystem, so a future host would scan the workspace itself and inject the `.sjon` documents and sibling `.wgsl` texts over a new LSP message:

- `wgslender/pngineCatalog` notification: supplies changed `.sjon` documents as `{uri,text}` and removals.
- `wgslender/pngineRead` request: asks the host for referenced sibling `.wgsl` documents; the response contains `{uri,text|null}` entries.

The VS Code desktop and web entry points would share one implementation. Open buffers still arrive through normal LSP synchronization and override injected text. `npm/wgslender-lsp`’s `initialize`, `sendMessage`, and `createTransport` signatures remain unchanged.

## Phase index

| Phase | Ships |
|---|---|
| [01-discovery-and-graph](01-discovery-and-graph.md) | SJON dependency, canonical identity, discovery through the provider seam, graph extraction, source overlays, invalidation, native project input. The wasm host contract is reserved. |
| [02-assembly-and-mapping](02-assembly-and-mapping.md) | Byte-exact pngine assembly, directive hoist, bidirectional map, cross-repo parity gate. |
| [03-composed-diagnostics](03-composed-diagnostics.md) | Per-root analysis, mapped push/pull diagnostics, lint policy, corpus acceptance, cache/performance gates. |
| [04-implicit-inclusion](04-implicit-inclusion.md) | Cross-part hover, definitions, references, completion, rename, semantic/inlay filtering, inline-code locations. |
| [05-cli-library-and-release](05-cli-library-and-release.md) | CLI selection and output, composed reflection/minify/compile, source maps, public Zig surface, release/tarball gates. |

## Cross-repo contracts

| Repository | Contract | Change |
|---|---|---|
| SJON | `sjon.parse`, `Ast.Tree`, `Glob`, deterministic native/WASM parsing. | No semantic change requested. Pin the exact 1.7.0 source revision and build with `plugin-exec=false`. |
| pngine | Post-order/include-once assembly, directive rules, bounds, line rows. | Add a test-only comparison harness under pngine; no production emitter changes. |
| inercia-2026 | Four-project corpus and expected composed outcomes. | Read-only gate input; no generated files in the corpus. |
| wgslender | Discovery, mapping, analysis, editing, CLI, packaging. | All production changes planned here. |

The pngine harness builds both assemblers in one test process using pngine’s existing path dependency on wgslender, compiling wgslender’s `src/pngine/*` library with pngine’s own SJON module injected (02 Task 5) so exactly one SJON instance is linked. A dedicated `-Dinercia=…` option supplies the corpus. Ordinary wgslender tests do not require a pngine or inercia checkout.

## Completion criteria

- Every use-case row in phases 01–05 has a named test or explicit gate.
- pngine and wgslender produce identical assembled bytes and line rows for synthetic cases and all four corpus projects.
- The measured clock false positives are gone; demo’s shared palette is correct across all four roots.
- Unsaved current and sibling buffers are honored.
- Native CLI and native LSP responses agree, including cross-file related information and multi-file edits. The wasm LSP keeps its existing single-source responses.
- A 200-edit burst performs zero SJON reparses and zero project `SourceProvider` reads beyond the defined refresh boundaries.
- `zig build test -j1`, native builds, the project-free wasm/lib/lsp-wasm builds, release assets, npm LSP tests, and the release packaging check pass without the private exhaustive submodule.

## What this plan set does not cover

SJON document-import/rebinding support, generated pass semantics, pngine lowering/specialization, closed-file workspace diagnostics, inline-code mutation, cross-part call hierarchy, and project-aware versions of the single-source package APIs. Each has an explicit safe fallback rather than partial or accidental behavior. The wasm host contract (a JS-side workspace scan and injected project documents) is a named follow-on, not a phase here.

---
