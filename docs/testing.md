# Testing

wgslender carries 64,919 lines of test code across 144 files, against 73,775 lines of implementation in `src/`, `lsp/`, and `cli/`. The suite is split into two tiers.

| Tier | Files | Lines | Availability |
|------|-------|-------|--------------|
| Core | 131 | 54,939 | Public, in this repository |
| Exhaustive | 13 | 9,980 | Licensed, `tests/exhaustive/` |

The core tier ships with the source and runs on a clean checkout with no additional setup. The exhaustive tier is a separate repository mounted as a submodule and is available under license.

## Running the core suite

```bash
zig build test          # everything registered in build.zig
zig build test -j1      # serial; use this for the full suite
```

Run from the repository root. Several test binaries resolve golden files and corpora relative to the working directory and will report missing fixtures if invoked from elsewhere.

The `-j1` flag matters once the optional corpora are present. Corpus tests hold large parsed modules in memory, and running several concurrently on a machine with limited RAM produces allocation failures that look like test failures.

Individual files compile and run on their own, which is the fast path while iterating:

```bash
zig test --dep wgslender -Mroot=tests/validation_test.zig -Mwgslender=src/root.zig
```

For a test that lives inside `src/`, `zig test src/Validator.zig` builds the whole source graph and runs the pins in that file.

Determine pass or fail from the process exit code. Zig prints `failed command` lines for individual test binaries during runs that ultimately succeed, so scanning the output for that string reports failures that did not happen.

## What the core tier covers

| Area | Lines | Notes |
|------|-------|-------|
| Validation | 7,115 | Type checking, diagnostics, exact message text and source positions |
| LSP | 7,046 | Feature handlers across 26 files, plus native/WASM transport parity |
| Lint | 3,926 | Per-rule behavior, autofixes, config pack resolution, disable comments |
| Reflection | 3,336 | Binding extraction, memory layout, JSON wire format |
| Minification | 2,867 | Snapshot goldens, source maps, determinism, size estimation |
| Parser and CST | 1,767 | Precedence, template disambiguation, round-trip losslessness |
| Type inference | 25 files | Overload resolution, abstract promotion, builtin signatures |

Two tests in the core tier carry more weight than their size suggests. `tests/oom_test.zig` uses `std.testing.checkAllAllocationFailures` to inject failure at every allocation point in the parser, validator, reflector, source-map writer, and minifier, verifying that out-of-memory propagates, leaks nothing, and consumes a deterministic number of allocations across runs. `tests/compute_toys_test.zig` minifies real production shaders from compute.toys and checks that the result parses and validates identically to the input.

Diagnostic wording and position are pinned in `tests/validation_location_test.zig`. Any change to an error message needs a corresponding case there.

Transport parity is enforced by asserting byte-equivalence between the manual JSON codecs in `lsp/wire/` and the lsp-kit writers in `lsp/lspkit/`. Both encode the same Handler types, so a change to one without the other fails the parity tests.

Two tests guard release hygiene. `tests/version_sync_test.zig` fails when any manifest version drifts from `pub const version` in `src/root.zig`. `tests/wasm_freshness_test.zig` fails when a `.wasm` copy in a package directory differs from a fresh build.

## The exhaustive tier

The exhaustive tier holds the differential and mutation machinery built to attack the incremental reparse path and the validator's inference behavior.

| File | Lines | What it does |
|------|-------|--------------|
| `incremental_mutation_longtail_test.zig` | 3,669 | Systematic edit-shape mutations checked against full reparse |
| `incremental_mutation_test.zig` | 1,181 | Core mutation matrix over anchor classifications |
| `incremental_corpus_addsub_test.zig` | 1,055 | Add and remove declaration sweeps across the corpus |
| `incremental_mutation_fuzz_test.zig` | 854 | Randomized edit sequences with equivalence checking |
| `ast_equal.zig` | 631 | Module equivalence engine backing every differential check |
| `incremental_longtail_test.zig` | 512 | Edge-case edit shapes found by earlier fuzzing runs |
| `incremental_corpus_test.zig` | 443 | Whole-corpus incremental replay |
| `inference_corpus_pinning_test.zig` | 356 | Per-code diagnostic histogram and triage goldens |
| `tint_triage.zig` | 347 | Conformance worklist and per-shader report generator |
| `tint_oracle.zig` | 248 | Classifies corpus shaders by Tint's own verdict |
| `tint_test.zig` | 245 | Semantic preservation over the Tint corpus |
| `fuzz_test.zig` | 226 | Parser and printer fuzzing |
| `incremental_fuzz_test.zig` | 213 | Incremental-specific fuzz driver |

The central technique is differential. Every incremental reparse is checked against a full reparse of the same final source, and `ast_equal.expectModulesEquivalent` asserts the two modules match. That check is stale-tolerant and pairs symbols by name, which lets it accept the append-only symbol growth and lazy interior-pending bias the incremental hot path depends on.

The Tint work runs 8,604 shaders from Google's Dawn Tint project and pins two goldens: a per-code diagnostic histogram, and that histogram split by Tint's own accept and reject verdicts into false positives, true positives, and unknowns. The false-positive bucket is the conformance worklist.

The Tint shader corpus itself belongs to Google and ships under the Dawn project's license. This tier contains the harness that drives it, and the corpus is fetched separately from upstream by anyone who wants to run it.

Licensing and access: contact mail@hugodaniel.pt.

## Building with the exhaustive tier present

`build.zig` registers test files conditionally through `hasFile`. Absent files are skipped at configure time and the build exits zero, so a checkout without the exhaustive tier configures and tests normally. The `tint-test` and `tint-triage` steps are registered only when the tier is present, which keeps `zig build --list-steps` honest about what the checkout can actually run.

With access, initialize the submodule:

```bash
git config submodule.tests/exhaustive.update checkout
git submodule update --init tests/exhaustive
zig build test -j1
```

The `git config` line is required because `.gitmodules` sets `update = none`, which lets `git clone --recursive` succeed for everyone without access. That setting also suppresses the checkout for licensees until it is overridden locally, and a `git submodule update --init` without the override exits zero having populated nothing.

## Corpora

Corpora are fetched on demand, and every test that reads one skips cleanly when it is absent.

| Corpus | Size | Fetch |
|--------|------|-------|
| Tint shaders | 383 MB, 11,952 files | `./scripts/fetch-tint-testdata.sh`, revision pinned in `scripts/tint-testdata.rev` |
| Unicode character data | 1.1 MB | `./scripts/fetch-ucd.sh`, revision pinned in `scripts/ucd.rev` |
| Validation fixtures | 1.2 MB | Tracked in this repository |
| compute.toys shaders | 68 KB | Tracked in this repository |

Bumping the Tint revision means editing `scripts/tint-testdata.rev`, removing `tests/testdata/tint` and both goldens under `tests/exhaustive/`, re-fetching, running the suite to regenerate, and committing the revision together with both goldens.

An out-of-memory crash during corpus pinning writes no golden and therefore produces an empty git diff, which reads identically to a clean run. Confirm the exit code before concluding that a corpus run showed no drift.

## Regenerating goldens

```bash
rm tests/exhaustive/corpus_golden.txt tests/exhaustive/triage_golden.txt
zig build test
```

Snapshot goldens for minification output regenerate the same way: delete the golden, run the suite, inspect the diff before committing.

The triage tool reports without gating, and requires the exhaustive tier:

```bash
zig build tint-triage                                   # summary table
zig build tint-triage -- --code E0200 --bucket fp       # false-positive worklist
zig build tint-triage -- --tsv report.tsv               # per-shader report
```

## Contributing

A patch is verified against the core tier, which covers the behavior a change is likely to touch: parsing, validation, lint rules, reflection output, minification goldens, LSP responses, and allocation-failure handling. Add cases to the file that already pins the relevant behavior.

Changes to the incremental reparse path in `src/Incremental.zig` and `src/incremental/` are additionally verified against the exhaustive tier before merge. Submit the change with core-tier coverage and the exhaustive run happens as part of review.
