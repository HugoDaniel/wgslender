# pngine CLI, Library, and Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose the same composed semantics through the native CLI and experimental Zig library, with correct diagnostics/source maps and reproducible release builds, while leaving single-source package APIs unchanged.

**Architecture:** A CLI project-selection layer resolves an input into one or more roots. Validate/lint reuse the diagnostic projector; artifact commands select exactly one root. `wgslender.Pngine` exposes discovery/assembly/mapping as experimental Zig APIs. Existing source-only APIs and WASM exports delegate to their current implementations.

**Tech Stack:** Zig 0.16, existing CLI/options/JSON/SourceMap/Reflect/Compiler modules, phase-01–04 project infrastructure, npm and release gates.

**Spec:** `docs/plans/pngine-shaders/README.md`

## Global Constraints

- Every new option is declared through `src/options.zig`.
- `--project` names one root SJON document, not a directory.
- Artifact-producing commands require one root.
- Validate/lint may process all containing shader-module roots.
- No project behavior on stdin unless both `--project` and `--root` are present.
- Single-source JSON and package APIs remain compatible.
- Reflection offsets are documented as assembled-text offsets.
- Source maps point to author origins.
- No required private exhaustive tier or sibling checkout for ordinary builds.

## Interfaces consumed

- Phase-01 `Store`, discovery, source overlays.
- Phase-02 `Assembled` and mapping.
- Phase-03 diagnostic projection and lint merge.
- Existing `runValidate`, `runLint`, `runReflect`, `runMinify`, `runCompile` (`cli/main.zig:686-993`).
- Existing `SourceMap.decodeMappings`, `LineIndex`, and VLQ encoder (`src/SourceMap.zig:294-305`, `:375-405`, `:601-605`).

## Interfaces produced

```zig
pub const ProjectSelection = struct {
    program: ProgramId,
    input_part: ?PartId,
    roots: []const RootId, // stable program/form order
};

pub fn selectProject(
    store: *Store,
    io: std.Io,
    input_path: ?[]const u8,
    project_path: ?[]const u8,
    root_name: ?[]const u8,
    no_project: bool,
) !ProjectSelection;
```

Experimental Zig exports:

```zig
pub const Pngine = struct {
    pub const Store = ...;
    pub const Program = ...;
    pub const Assembled = ...;
    pub const OriginRange = ...;
    pub fn assembleRoot(... ) !Assembled;
    pub fn mapDiagnostics(... ) !MappedDiagnostics;
    pub fn remapSourceMap(... ) !SourceMap.Result;
};
```

The existing `validate`, `lint`, `reflect`, `minify`, and `compile` function signatures do not gain filesystem parameters.

## File structure

- Create `cli/PngineSelection.zig`: flag interpretation and selection errors.
- Create `cli/PngineOutput.zig`: mapped text/JSON diagnostics and exit decisions.
- Create `src/pngine/SourceMaps.zig`: assembled→author source-map remapping.
- Modify `cli/main.zig`, `src/options.zig`, `src/Diagnostic.zig`, `src/api_json.zig`.
- Modify `src/root.zig` and relevant documentation.
- Create `tests/pngine_cli_test.zig`, `tests/pngine_sourcemap_test.zig`, `tests/pngine_options_test.zig`.
- Modify release/test scripts only to add the new public gates, not to require private fixtures.

## Ordered work

### Task 1: Options and root selection

**Files:** `src/options.zig`, `cli/main.zig`, `cli/PngineSelection.zig`, options/CLI tests.

- [ ] Add red parser/selection tests for every `X01–X17` case.
- [ ] Add string-valued `project`/`root` specs and boolean `no-project` support through the option-spec machinery; do not hand-parse them beside the spec table.
- [ ] Implement canonical explicit-document loading and discovery-based selection.
- [ ] Reject unknown roots, duplicate root names, project-less `--root`, directory `--project`, and stdin without both selectors as usage errors.
- [ ] For validate/lint, select all containing shader-module roots unless `--root` narrows the set. For other commands require exactly one.
- [ ] With stdin plus selectors, replace only the selected root’s own text; pass roots refuse with exit `2`.
- [ ] Run options precedence/help and selection tests; all pass.
- [ ] Commit: `feat: select pngine projects and roots from the CLI`.

### Task 2: Composed validate/lint and JSON

**Files:** `cli/PngineOutput.zig`, `cli/main.zig`, `src/Diagnostic.zig`, `src/api_json.zig`, CLI/JSON tests.

- [ ] Add red fixtures for mapped diagnostics, multiple roots, graph errors, strict mode, quiet/max warnings, and fix behavior.
- [ ] Reuse the phase-03 projector; do not create a second multi-root merge implementation.
- [ ] Print each primary diagnostic against its actual origin file and related SJON/WGSL locations.
- [ ] Add optional `file`, `project`, and `root` JSON fields only for mapped entries; retain existing envelopes/counts and byte compatibility for unmapped output.
- [ ] `validate` is valid only if every selected root is valid; preserve `--strict` warning escalation and exit `1`.
- [ ] `lint` preserves quiet/max-warning/count behavior. `--fix` and `--fix-dry-run` operate on the input part only; never print/write the assembled module.
- [ ] Project selection usage errors exit `2`; author graph/validation errors exit `1`.
- [ ] Run CLI, diagnostic JSON, lint, and options suites; all pass.
- [ ] Commit: `feat: validate and lint composed pngine modules`.

### Task 3: Reflect, minify, and compile one root

**Files:** `cli/main.zig`, CLI tests, reflection/minifier integration tests.

- [ ] Add red tests proving sibling declarations/resources reach reflection and output, and that multi-root input without `--root` is refused.
- [ ] Feed `Assembled.text` through existing `Reflect.reflect`, `minifyWithOptions`, and `compile` paths rather than duplicating compiler pipelines.
- [ ] Map parse/compile diagnostics back to author files and suppress output on errors according to the selected command’s documented policy.
- [ ] Document and test that reflection’s numeric spans/offsets describe assembled text; do not relabel them as author offsets.
- [ ] Preserve existing minify precedence/config behavior and compiler binary output for single-source inputs.
- [ ] Run reflect/minify/compile/snapshot/collision suites; all pass.
- [ ] Commit: `feat: reflect and build selected pngine modules`.

### Task 4: Author-origin source maps

**Files:** `src/pngine/SourceMaps.zig`, `cli/main.zig`, `tests/pngine_sourcemap_test.zig`.

- [ ] Add red tests for multiple sources, hoisted directives, names, inline sources, CRLF, UTF-16 columns, and empty mappings.
- [ ] Decode the minifier’s assembled source map, translate each original assembled line/column through phase-02 mapping, and re-encode with per-origin source indices.
- [ ] Preserve generated positions and name mappings. Drop only a mapping with no honest author origin and emit a warning identifying the root.
- [ ] Populate `sources[]` with file paths or stable inline virtual URIs and align `sourcesContent[]` when requested.
- [ ] Keep external map naming, inline-map comments, and `-o` behavior unchanged.
- [ ] Run source-map and CLI map tests, then decode the result to verify every origin range.
- [ ] Commit: `fix: map minified pngine output to author sources`.

### Task 5: Experimental Zig API and package boundary

**Files:** `src/root.zig`, `src/pngine/Pngine.zig`, API docs/tests, package tests.

- [ ] Add red compile tests showing project APIs available in normal builds and absent by design in `-Dlsp=false`.
- [ ] Export only the experimental store/program/assembly/mapping/source-map types documented above; do not expose LSP handler types through core.
- [ ] Document allocator ownership, source precedence, error sets, and the fact that discovery performs filesystem work only when given `std.Io`.
- [ ] Keep existing single-source functions as the implementation used by npm/WASM/C/Go/Rust calls.
- [ ] Add a JS LSP test using the JSON-RPC project protocol without adding a new npm function.
- [ ] Run core, CLI, LSP, and package tests; all pass.
- [ ] Commit: `docs: define experimental pngine Zig API boundaries`.

### Task 6: Full gates and release reproduction

**Files:** test/build registration and release documentation/scripts as needed.

- [ ] Register all public tests with `addTestStep`; prove a checkout without `tests/exhaustive/` configures and runs.
- [ ] Run the complete native/WASM/test matrix and pngine parity/corpus gates.
- [ ] Rebuild every committed WASM artifact with `release-assets`.
- [ ] Run npm LSP tests and VS Code project tests.
- [ ] Run `scripts/release.sh --check`; green requires its existing final clean-tree gate (`scripts/release.sh:122-145`) plus all new gates.
- [ ] Exercise the existing Rust packaging path, which vendors and unpacks Zig sources (`scripts/release.sh:78-87`), and verify the project-enabled normal build fetches SJON by URL while `-Dlsp=false` remains offline/core-only.
- [ ] Commit: `test: gate pngine project support for release`.

## Exhaustive use-case inventory

| ID | Fixture or synthetic input | Action | Expected result | Why phase 05 |
|---|---|---|---|---|
| X01 | Bare `.wgsl`, no reference | Any CLI command | Existing single-source behavior and output. | Compatibility baseline. |
| X02 | `--no-project` on referenced file | Validate/minify | Explicit single-source behavior. | Escape hatch. |
| X03 | `--project program.sjon` on file | Validate | Bypass workspace discovery and use that program. | Explicit project selection. |
| X04 | `--project` names directory | Parse/validate | Usage error, exit `2`. | Exact flag meaning. |
| X05 | `--root` without project/discovered membership | Any | Usage error, exit `2`. | Orphan selector. |
| X06 | Unknown root name | Any | Usage error naming available roots, exit `2`. | Selection failure. |
| X07 | Duplicate root name in invalid program | Select | Program/selection error; never first-wins. | Root identity. |
| X08 | Fragment in one root | Validate/lint | Auto-compose that root. | Simple automatic behavior. |
| X09 | `demo/palette.wgsl` | Validate/lint | All four roots run; merged counts/diagnostics follow phase 03. | Multi-root read operations. |
| X10 | Multi-root fragment | Reflect/minify/compile without `--root` | Usage error listing roots, exit `2`; no artifact. | Single-artifact ambiguity. |
| X11 | Same input with `--root bgCode` | Reflect/minify/compile | Exactly that root is processed. | Explicit artifact selection. |
| X12 | `--root` selects root not containing input | Select | Usage error; no unrelated module output. | Selector consistency. |
| X13 | Stdin without project flags | Any | Existing stdin behavior. | Stdin compatibility. |
| X14 | Stdin with only `--project` or only `--root` | Any | Usage error, exit `2`. | Unknown part identity. |
| X15 | Stdin with both selectors | Validate/minify | Stdin replaces selected root’s author text; imports come from project sources. | Unsaved CLI input. |
| X16 | Stdin selects pass root | Validate | Generated-context refusal, exit `2`. | Pass boundary. |
| X17 | Missing explicit project/file | Select | Located error; no empty program or fabricated WGSL. | Missing inputs. |
| X18 | Cycle/unknown import/overflow | Validate/lint | `P0002`, mapped JSON/text, exit `1`. | Author graph errors. |
| X19 | Unfilled `:requires` hole | Validate | `P0003`, related SJON location, exit `1`. | Hole contract. |
| X20 | Sibling declaration resolves | Validate | `valid`, exit `0`. | CLI goal. |
| X21 | One of several roots invalid | Validate | `invalid`, exit `1`, successful roots still report their findings. | All-root validity. |
| X22 | `validate --strict` with warnings | Validate | Existing warnings-as-invalid behavior. | Strict compatibility. |
| X23 | `validate --format=json` composed | Validate | Existing envelope plus optional origin/root fields; valid counts. | JSON contract. |
| X24 | Single-source JSON | Validate/lint | No shape/content drift. | Wire compatibility. |
| X25 | Related diagnostic in another file | Text/JSON | Primary and related paths are distinct and correct. | Cross-file output. |
| X26 | Hoisted-directive diagnostic | Text/JSON | Original file/line/column, not assembled line 1. | Mapping in CLI. |
| X27 | `lint --quiet` and `--max-warnings` | Lint | Existing filtering/count/exit semantics. | Lint option compatibility. |
| X28 | `lint --fix` with local safe fixes | Lint | Rewrite only input file. | Safe mutation. |
| X29 | Fix set includes sibling/inline/cross-root ambiguity | Lint fix | Refuse unsafe fix; do not write assembled output. | Fix boundary. |
| X30 | `lint --fix-dry-run` on fragment | Lint | Print transformed fragment only. | Dry-run identity. |
| X31 | Fragment with imported bindings | Reflect selected root | Reflection includes whole assembled module’s resources/entry points/functions. | Composed reflection. |
| X32 | Read reflection offsets | Reflect | Documentation/tests identify assembled coordinates; no false author-local claim. | Reflection mapping boundary. |
| X33 | Minify selected root | Minify | Whole-module DCE/rename across parts; output is one module. | pngine whole-unit behavior. |
| X34 | Compile selected root | Compile | Binary represents assembled/minified module; diagnostics map to authors. | Composed compile. |
| X35 | Parse/validation failure during artifact command | Minify/compile/reflect | No partial artifact and documented nonzero/error behavior. | Failure safety. |
| X36 | Minify with external source map | Minify | Map contains one source per contributing origin and correct local positions. | Source-map goal. |
| X37 | Inline source map with sources content | Minify | Valid comment/map; `sourcesContent` aligns with `sources`. | Inline map behavior. |
| X38 | Map contains symbol names | Minify/decode | Name indices and generated positions survive remapping. | VLQ/name fidelity. |
| X39 | Mapping on hoisted directive | Decode map | Original author directive position. | Hoist/source-map interaction. |
| X40 | Inline `:code` origin | Minify map | Stable virtual URI and inline content, not a nonexistent file path. | Inline source maps. |
| X41 | Unmappable generated mapping | Minify map | Omit that original mapping and warn; never fabricate a source index. | Negative mapping. |
| X42 | No mappings/empty source | Minify map | Valid empty SourceMap v3 result. | Empty input. |
| X43 | `format` request/CLI surface | Inspect/use | No new CLI format subcommand; LSP formatting remains local. | Explicit command boundary. |
| X44 | Zig consumer uses `wgslender.Pngine` | Compile/run | Experimental APIs obey ownership and source precedence. | Library exposure. |
| X45 | `-Dlsp=false` consumer | Build | No SJON fetch/import and existing source APIs work. | Offline/core build. |
| X46 | npm/C/Go/Rust single-source call | Package tests | No project discovery and no API signature change. | Package boundary. |
| X47 | WASM LSP project fixture | JSON-RPC test | Same composed output as native using injected sources. | WASM parity. |
| X48 | Release tarball normal build | Package gate | URL+hash dependency resolves; no sibling `../SJON` requirement. | Tarball correctness. |
| X49 | Release assets | `release-assets` | Both committed WASM modules rebuilt and freshness checks pass. | Shipped-editor parity. |
| X50 | Full release check | `scripts/release.sh --check` | Exit `0`, clean tree, all public gates green without private exhaustive tests. | Final completion gate. |

## Red-first and gate commands

- `zig build test -j1`: exit `0`; all `X01–X50` and existing suites pass.
- `zig build && zig build lsp && zig build wasm && zig build lsp-wasm`: every build exits `0`.
- `zig build -Dlsp=false`: exit `0` without SJON resolution.
- `zig build release-assets`: exit `0`; committed asset copies match.
- `(cd npm/wgslender-lsp && npm test)`: exit `0`.
- From pngine: `zig build test-wgslender-assembly-parity -Dinercia=../inercia-2026`: exit `0`.
- `SKIP_FOREIGN=1 ./scripts/release.sh --check`: Zig-only release gate exits `0` and leaves the tree clean.
- Full `./scripts/release.sh --check` where toolchains exist: exit `0`, including the vendored-package check.

## Stop-and-report conditions

- A new CLI option bypasses or cannot be represented by the option-spec table; extend the table mechanism rather than hand-parsing.
- A command would emit an artifact for more than one root without explicit selection.
- Source-map remapping loses generated positions or invents an author source.
- Reflection consumers require author-local offsets; report that as a separate API-design request instead of silently changing the established reflection schema.
- Release packaging requires a sibling path, private submodule, or unrecorded dependency hash.
- Existing package tests reveal an accidental project lookup in a single-source API.

## Risks

- **CLI behavior divergence:** selection and diagnostic projection are shared modules, not per-command reimplementations.
- **JSON compatibility:** new origin fields are optional and emitted only for composed diagnostics.
- **Source-map complexity:** decode/re-encode tests cover names, multiple sources, and every mapping category.
- **Reflection offset expectations:** the assembled-coordinate contract is explicit and tested.
- **Release regressions:** the existing clean-tree and vendored-package gates remain mandatory.
