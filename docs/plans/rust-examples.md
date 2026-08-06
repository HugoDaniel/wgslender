# Plan — `packages/rust/wgslender/examples/`: an example per capability

**Creates:** six new runnable examples in `packages/rust/wgslender/examples/`, one
edit to an existing one, and a gate task that actually *runs* them. Takes the Rust
package from 4 examples covering 4 capabilities to 10 examples covering all of them.

**Motivation:** the crate's own "What is here" table
(`packages/rust/wgslender/src/lib.rs:83-91`) lists seven capabilities. Four have a
runnable example; `validate`, `lint`/`lint_fix`, `compile` and the entire `refactor`
module — 871 LOC and 14 public functions, the most novel thing the crate does — have
none. Doctests cover them (near 1:1 with public functions), but a doctest is a
compile-checked assertion, not something a reader can run to see what the library
*says*.

**Status:** **executed** — all seven blocks, 2026-08-06, on the `rust-examples`
worktree branch off `main @ 3e65c1a`. Block 1 `e30211c` (the gate task that runs
them), 2 `93289fb` (`validate`), 3 `35ab316` (`lint`), 4 `1ab8f6a` (`compile`),
5 `db4490f` (`refactor`), 6 `f098dfb` (`minify_options`, `include_wgsl`, and the
`reflect_json` footnote), 7 `53cd631` (this documentation pass). `cd packages/rust
&& cargo xtask check` is green across all eight steps — ten examples run, not
merely compiled — and `cargo xtask msrv` with it.

Every number below was measured against `main @ 3e65c1a`, 2026-08-06, macOS arm64,
library version `1.1.0`. Do not re-derive them; do re-run the examples if HEAD has
moved. Where execution diverged from the plan it was because the plan's own ground
rule — numbers come from the library — pointed somewhere else:

- **Block 4 corrected a claim made here.** `sort_declarations` + `scope_local_rename`
  are described below as leaving the byte count identical. That holds up to a size:
  past roughly a dozen sibling scopes the raw count moves too, and `minify_options`
  prints the curve (3151 → 2959 bytes at 32 scopes). Its section 3 says so rather
  than repeating the blanket claim.
- **Block 6 could not take the first branch of its own instruction.** "Compress both
  outputs and show the real difference" needs a deflate the crate does not export:
  the only one is `CompressedWgsl::__deflate`, `#[doc(hidden)]` and `compress`-gated,
  and `compile()` forces both flags on regardless of the options it is handed. The
  example takes the second branch and makes it measurable instead — same bytes, a
  quarter fewer distinct names.
- **Two examples measure their own shader** rather than the one named here.
  `minify_options` needs dead code and sibling scopes for its options to have work to
  do, which `demo.wgsl` has neither of; the `reflect_json` footnote stays on
  `reflect_types.rs`'s Camera/Material shader so the example is about one shader
  throughout.

---

## Verified current state (do not re-derive)

### What exists

Four examples, all confirmed building and running green:

| Example | Covers | Measured output |
|---|---|---|
| `minify.rs` | `minify_and_reflect`, `MinifyOptions::default()` | 690 → 463 bytes (32% saved); both bindings map to themselves |
| `reflect_types.rs` | `reflect` | Camera 80 B/align 16, `view_projection` +0, `position` +64, `exposure` +76; Material 32 B; two entry points, no workgroup size |
| `wgsl_module.rs` | `wgsl_module!` | 609 B source; `tick` @[16,1,1]; Scene 112 B with fields at 0/64/80/96/100/104; `Instances::ITEMS_OFFSET` 32 |
| `embed_compressed.rs` | `include_wgsl_compressed!`, `CompressedWgsl` | 968 → 412 (42%) → 274 (28%) bytes |

Declared in `packages/rust/wgslender/Cargo.toml`: `embed_compressed` needs
`required-features = ["macros", "compress"]`, `wgsl_module` needs `["macros"]`. The
other two need no declaration.

### The gap, precisely

Public items with **no runnable example** (all have doctests):

- `validate`, `Strictness`, `Validation`, `Diagnostic`, `Severity`
- `lint`, `lint_fix`, `LintConfig`, `Pack`, `RuleSetting`, `Value`, `LintReport`,
  `LintFixOutcome`
- `compile`, `CompiledShader`
- the whole `refactor` module: `find_references`, `rename`, `rename_apply`,
  `stable_id_at_offset`, `locate_stable_id`, `locate_declaration`, `locate_type`,
  `rename_by_id`, `remove_declaration`, `remove_declaration_apply`, `change_type`,
  `change_type_apply`, plus `StableId`, `ByteRange`, `Edit`, `Reference`, `Applied`,
  `IncludeDeclaration`, `RefactorError`
- `reflect_json`, `minify_with` with non-default options, `version`
- `include_wgsl!` — the **default-feature** macro, and the only one of the three
  without an example (the `compress`-gated variant has one)

### The gate does not run examples — this is the load-bearing finding

`cargo xtask check` (`packages/rust/xtask/src/main.rs`) runs seven steps: fmt, clippy,
clippy `--all-features`, `test --workspace`, `test --workspace --all-features`,
`check --no-default-features`, and `doc`. The clippy and check steps pass
`--all-targets`, so examples are **compiled**. Nothing ever **executes** them.

An example that compiles and prints nonsense — or panics on its first unwrap — passes
the gate today. Adding six examples without fixing this multiplies the surface that
is compiled but unverified. Block 1 fixes it first, deliberately.

### The publish trap — read before adding any fixture

`packages/rust/wgslender/Cargo.toml` has an explicit `include` list:

```toml
include = [
    "src/**/*.rs",
    "examples/**/*.rs",
    "tests/fixtures/demo.wgsl",
    "tests/fixtures/layouts.wgsl",
]
```

Six fixtures exist on disk (`demo`, `invalid`, `layouts`, `padded_array`,
`padded_matrix`, `warning`) but **only two are published**. An example that does
`include_str!("../tests/fixtures/warning.wgsl")` compiles here and breaks for anyone
who downloads the crate from crates.io — and, because `examples/**/*.rs` *is*
published, it breaks their `cargo package --list` verification build too.

**Rule for this plan: new examples embed their WGSL as an inline `const` unless they
need `demo.wgsl` or `layouts.wgsl`.** No example adds a fixture, and no block edits
the `include` list. The two macro examples are the exception that already exists, and
they use the two published fixtures.

### Measured library behavior the new examples will show

Everything here was observed, not inferred. Pin these; if execution sees different
numbers, the library changed and the *plan* is stale — say so rather than quietly
adjusting.

**`version()`** → `"1.1.0"`.

**`validate`**, against the facade's own fixtures:

| Input | Strictness | valid | errors | warnings | Diagnostic |
|---|---|---|---|---|---|
| `warning.wgsl` | `Default` | true | 0 | 1 | `Warning W0103` 11:17 `code is unreachable` |
| `warning.wgsl` | `Strict` | false | 1 | 0 | the same W0103, now `Error` |
| `invalid.wgsl` | `Default` | false | 1 | 0 | `Error E0100` 6:13 `use of undeclared identifier 'undeclared_variable'` |

The strictness contrast is the whole point: *same diagnostic, same position, different
severity, different verdict*.

**`lint`**, over this source (call it `LINTY` — it is `wgslender-core`'s warning
fixture, which trips two rules; the facade's own `warning.wgsl` is a different, smaller
file and is not published):

```wgsl
@group(0) @binding(0) var<storage, read_write> counters: array<u32>;

@compute @workgroup_size(64)
fn main(@builtin(local_invocation_index) i: u32) {
    let doubled = u32(i * 2u);
    counters[i] = doubled;
    return;
    counters[i] = 0u;
}
```

| Pack | errors | warnings | fixable | diagnostics |
|---|---|---|---|---|
| `@wgslender/recommended` | 0 | 2 | 1 | 4 |
| `@wgslender/style` | 0 | 0 | 0 | 2 |
| `@wgslender/performance` | 0 | 0 | 0 | 2 |
| `@wgslender/portability` | 0 | 0 | 0 | 2 |
| `@wgslender/minify` | 0 | 0 | 0 | 3 |
| `@wgslender/strict` | 1 | 1 | 1 | 4 |

The four `recommended` diagnostics, in order:

```
Warning W0101 5:19  redundant cast: 'u32' is already 'u32'
Warning W0103 8:17  code is unreachable
Warning W0201 5:19  redundant cast to 'u32' — argument is already 'u32'
Warning W0210 8:5   unreachable code after terminator statement
```

Three things here are worth an example on their own, and the `lint.rs` example exists
to make all three visible:

1. **W0101/W0103 are the validator's, W0201/W0210 are the linter's.** Every pack shows
   the validator's two; only `recommended` and `strict` add lint findings. That is why
   `style`/`performance`/`portability` report `warning_count == 0` while
   `diagnostics.len() == 2`.
2. **`warning_count` is lint-only** — already documented on `LintReport`, and this is
   where a reader can see it.
3. **`@wgslender/minify` emits `Severity::Hint`** (`M0100`, one per external binding:
   `external binding 'counters' is preserved by the renamer …`), counted in neither
   `error_count` nor `warning_count`.

Under `strict`, W0210 becomes `Error` (so `error_count == 1`) while W0201 stays
`Warning`. Not every rule is promoted; that is the pack's choice, not a bug.

**`lint_fix`** with `recommended` over `LINTY` rewrites exactly one thing —
`let doubled = u32(i * 2u);` → `let doubled = i * 2u;` — and its report describes the
source **as handed in** (`fixable_count == 1`). Re-linting the output gives
`warning_count == 1, fixable_count == 0`: the unreachable `counters[i] = 0u;` has no
autofix.

**Rule overrides** over `LINTY`, starting from `recommended` (baseline
`warning_count == 2`):

| Override | Result |
|---|---|
| `.rule("no-redundant-casts", Off)` | `warning_count == 1` |
| `.rule("no-unreachable", Error)` | `error_count == 1, warning_count == 1` |
| `.rule("no-unreachable-code", Error)` | **`error_count == 0, warning_count == 2`** |

The third row is not a typo in this plan — it is a typo *in the rule id*, and the
library **silently ignores unknown ids**. `LintConfig::rule` documents this; the
example is where a reader can watch it happen. The real ids come from
`src/lint/rules/*.zig` (`.id = "…"`); the unreachable-code rule is `no-unreachable`.

**`RuleSetting::WarnWith` / `ErrorWith` need a `Value`, and the facade cannot build
one.** `wgslender::Value` is a re-export of `serde_json::Value`, but `serde_json` is
not a dependency a consumer of `wgslender` gets — `serde_json::json!` and
`serde_json::Map` are both unreachable. Verified: the only dependency-free
construction is `FromStr`:

```rust
use core::str::FromStr as _;
let options = wgslender::Value::from_str(r#"{"ignore":[0,1]}"#)?;
```

This is a genuine ergonomic gap in the published API, found by writing this plan. It
is **not** fixed here (see "Out of scope"), but Block 3 documents it in the example
and in the `RuleSetting` rustdoc, because a re-export nobody can construct is worse
than no re-export.

**`compile`** — `CompiledShader { wasm: Vec<u8>, original_size: u32 }`:

- `compile(demo.wgsl)` → 561 B wasm, `original_size == 968`. Bytes start
  `00 61 73 6d 01 00 00 00` (the wasm magic + version).
- `compile("fn main( { let ; }")` → `Err(Error::Compile(_))` carrying 4 parse
  diagnostics, all line 1, none with a code.
- `compile(invalid.wgsl)` → **`Ok`**. The type error does not stop it: only the parser
  rejects. Consistent with the rest of the library, and worth stating in the example.

The size story, measured on three real shaders:

| Shader | source | minified | wasm | wasm ÷ minified |
|---|---|---|---|---|
| an 894 B synthetic | 894 | 481 | 609 | **1.27** |
| `tests/testdata/compute.toys/cubes_in_space.wgsl` | 4 292 | 1 127 | 998 | 0.89 |
| `tests/testdata/compute.toys/bridge.wgsl` | 28 855 | 8 266 | 4 676 | **0.57** |

**The wasm is bigger than the minified text on small shaders.** The BPE decoder and
the wasm framing are a fixed ~500 B overhead; the crossover is around 1–2 KB of
minified text. An example that showed only `demo.wgsl` (561 B wasm vs 412 B text)
would leave a reader thinking the feature is a pessimisation. Block 4 shows both
sides.

**`refactor`**, against `demo.wgsl` (968 bytes, published, so an example may use it):

| Call | Result |
|---|---|
| `stable_id_at_offset(demo, 593)` | `Some(StableId("v1:fn:luminance"))` |
| `find_references(demo, 593, Yes)` | `[{593..602, is_write: true}, {830..839, is_write: false}]` |
| `find_references(demo, 593, No)` | `[{830..839, is_write: false}]` |
| `locate_stable_id(demo, "v1:fn:luminance")` | `593..602` (the name) |
| `locate_declaration(demo, "v1:fn:luminance")` | `590..681` (the whole `fn`) |
| `rename_by_id(demo, …, "relative_luminance")` | 2 edits, at 593..602 and 830..839 |
| `rename_apply(demo, 593, "relative_luminance")` | 2 edits, 968 → 986 bytes |
| `locate_stable_id(demo, "v1:var:params")` | `506..512` |
| `locate_type(demo, "v1:var:params")` | `514..520` |
| `change_type(demo, "v1:var:params", "Uniforms")` | 1 edit at 514..520 |
| `rename(demo, 593, "fn")` | `Err(Refactor(InvalidIdentifier))` |
| `rename(demo, 0, "x")` | `Err(Refactor(SymbolNotFound))` |
| `rename_by_id(demo, "v1:fn:nope", "x")` | `Err(Refactor(SymbolNotFound))` |

Two traps for the executor:

- **Offset 593 is `demo.wgsl`'s `fn luminance` declaration name.** Do not compute it
  with `source.find("luminance")` — the fixture's header comment mentions `luminance`
  first, so that yields 93, and every refactor call there answers `None` /
  `SymbolNotFound`. Derive it as `find("fn luminance") + 3`, which is what produced
  593, or hard-code 593 with a comment saying why.
- **`remove_declaration_apply` leaves the blank lines behind.** Measured on a small
  unused-helper source: 207 → 156 bytes, with two blank lines where the function was.
  It removes the declaration, not the surrounding whitespace. Show it honestly rather
  than picking a source that hides it.

**`reflect_json`** on `demo.wgsl` → 4 577 bytes of the v2 envelope, beginning:

```json
{"version":2,"bindings":[{"group":0,"binding":0,"name":"params","nameMapped":"params",
"nameOffset":506,"stableId":"v1:var:params","declSpan":{"start":471,"end":…
```

`nameOffset`, `stableId` and `declSpan` are **not on the typed `Binding` struct**
(which carries `group`, `binding`, `name`, `name_mapped`, `address_space`,
`access_mode`, `ty`, `ty_mapped`, `layout`). That is the reason `reflect_json` exists,
and it is the bridge between the two halves of the API: the `stableId` in the JSON is
exactly what `StableId::new` takes. Note `nameOffset: 506` and `stableId:
"v1:var:params"` match the refactor table above — the same symbol, reached two ways.

**`minify_with`** over the 894 B synthetic shader (three uncalled helpers, two sibling
scopes) and over `demo.wgsl` (968 B):

| Options | synthetic | demo |
|---|---|---|
| `default()` | 481 | 412 |
| `.minify_identifiers(false)` | 581 | 468 |
| `.tree_shaking(false)` | 577 | 412 |
| `.keep_names(["luminance"])` | 505 | 428 |
| `.mangle_external_bindings(true)` | 452 | 386 |
| `.sort_declarations(true).scope_local_rename(true)` | 481 | 412 |

Two honest facts the example must not paper over:

- `tree_shaking(false)` costs nothing on `demo.wgsl` (412 either way) because it has
  no dead code. The synthetic shader, with three uncalled helpers, shows the real
  96-byte difference. **Pick a shader where the option bites**, or the row teaches
  nothing.
- `sort_declarations` + `scope_local_rename` produce **the same byte count** as the
  default. They are not size optimisations — they are *compression* optimisations, and
  the win only appears after DEFLATE. An example that prints raw byte counts for that
  row is actively misleading. Block 6 must either compress both outputs and compare,
  or state plainly that the number is expected to be identical and say where the win
  is.

---

## Ground rules

Same as `plans/README.md`, restated so a block can be executed without it:

- **Blocks are self-contained context blocks.** Each restates the paths, API shapes
  and commands it needs. Execute one block per session when context is tight.
- **TDD, reds first.** Block 1 builds the harness that lists all ten examples and is
  therefore red six times over. Every later block turns exactly one row green. Confirm
  the red before writing the example.
- **No CI.** The gate is `cargo xtask …`, run on demand. Do not create workflow YAML.
- **Commit per block**, conventional and atomic:
  `feat(rust): add the validate example`, `test(rust): run examples in the gate`,
  `docs(rust): …`. Never sweep in unrelated working-tree changes — at plan-writing
  time `docs/obsidian/` was untracked; leave it alone.
- **Numbers are pinned against the library, never guessed.** Every figure in this plan
  was measured. If an example prints a number, it prints one the library produced.
- **Every example follows the house voice.** Read `minify.rs` and
  `embed_compressed.rs` first: a `//!` header saying what the example is *for*, the
  `cargo run` line in a `text` block, prose that explains why a number matters, and
  doc comments on the constants. Prints are aligned columns, not `{:?}` dumps. An
  example is documentation that happens to execute.
- **No new fixtures, no `include` edits.** See "The publish trap" above.

### Out of scope

- **Fixing the `Value` ergonomics gap.** Making `RuleSetting::WarnWith` usable without
  `serde_json` means either re-exporting `serde_json::json!`, adding a builder, or
  taking `&str` — a public API decision, and Hugo's call. Block 3 documents the
  `Value::from_str` workaround; it does not change the API.
- **Publishing.** Untouched; see `packages/rust/README.md § Publishing`.
- **`examples/rust/`** (the `plans/02-rust.md` directory) — superseded and never
  built. This plan touches only `packages/rust/`.

---

## Target layout

```
packages/rust/
├── wgslender/
│   ├── Cargo.toml           # + 1 [[example]] block for include_wgsl
│   └── examples/
│       ├── minify.rs          (exists)
│       ├── reflect_types.rs   (exists — Block 6 appends a reflect_json section)
│       ├── wgsl_module.rs     (exists)
│       ├── embed_compressed.rs(exists)
│       ├── validate.rs        NEW  Block 2
│       ├── lint.rs            NEW  Block 3
│       ├── compile.rs         NEW  Block 4
│       ├── refactor.rs        NEW  Block 5
│       ├── minify_options.rs  NEW  Block 6
│       └── include_wgsl.rs    NEW  Block 6
└── xtask/src/main.rs        # + the `examples` task, folded into `check`
```

---

## Block 1 — the gate runs examples (red: six missing rows)

**Red first.** Add an `examples` task to `packages/rust/xtask/src/main.rs` driven by a
table of every example that should exist:

```rust
/// Every example, and the features it needs. A row per example; the drift
/// check below is what keeps this list honest.
const EXAMPLES: &[(&str, &[&str])] = &[
    ("minify", &[]),
    ("reflect_types", &[]),
    ("wgsl_module", &[]),
    ("embed_compressed", &["compress"]),
    ("validate", &[]),
    ("lint", &[]),
    ("compile", &[]),
    ("refactor", &[]),
    ("minify_options", &[]),
    ("include_wgsl", &[]),
];
```

Each row runs `cargo run -p wgslender --example <name>` (plus `--features …` when the
row asks for it) and fails the task on a non-zero exit **or empty stdout** — an
example that runs and says nothing has not demonstrated anything.

Then the drift guard, which is the part that earns its keep: read
`wgslender/examples/`, and fail if any `*.rs` file there is absent from `EXAMPLES`.
Without it, example number eleven gets added and silently never runs. `xtask` has zero
dependencies by design (`main.rs:10-11`); `std::fs::read_dir` keeps it that way.

Wire `examples` into `CHECK` as the last step, after `documentation` — it is the
slowest and the least likely to fail once green.

**Confirm the red:** `cargo xtask examples` must fail on the first missing example
(`validate`), with a message naming it. Six rows are red at this point; each later
block turns one green.

Then make the four existing rows pass, which they should immediately — all four were
verified running green. If one does not, that is a genuine find: report it before
proceeding.

**Green:** `cargo xtask examples` fails only on the six not-yet-written examples.
`cargo xtask check` reaches the new step and fails there.

**Commit:** `test(rust): run every example in the gate, and guard against drift`

**Note for later blocks:** until Block 6 lands, `cargo xtask check` is red at the last
step. That is intended. Use `cargo xtask examples` to check your own block, and run
the full gate at Block 7.

---

## Block 2 — `validate.rs` (red: `xtask examples` cannot find it)

**What it shows:** the same shader, the same diagnostic, two strictness settings and
two different verdicts — then a shader with a real error, rendered the way a compiler
would render it.

**Source:** inline `const`s, not fixtures (`warning.wgsl` and `invalid.wgsl` are on
disk but **not published**; see "The publish trap"). Copy the two fixtures' contents
into the example as `const UNREACHABLE` and `const UNDECLARED`, keeping their
explanatory comments.

**Pinned expectations** (from the measured table above):

- `UNREACHABLE` + `Strictness::Default` → `valid: true`, 0 errors, 1 warning,
  `Warning W0103` at 11:17, `code is unreachable`. Adjust the line number if the
  inlined constant shifts it — derive it, do not guess.
- `UNREACHABLE` + `Strictness::Strict` → `valid: false`, 1 error, 0 warnings, the same
  W0103 now `Error`.
- `UNDECLARED` + `Default` → `valid: false`, 1 error, `Error E0100`,
  `use of undeclared identifier 'undeclared_variable'`.

**Shape:** a small `report(label, &Validation)` helper printing
`severity code line:column message` in aligned columns, called three times. Show
`Severity` being matched on rather than `{:?}`-printed — a reader wants to see the
enum used.

The header must say the thing the table makes obvious: **a rejected shader is not a
Rust `Err`.** `validate` returns `Ok(Validation { valid: false, .. })`. That is the
crate's central convention (`lib.rs:118-124`) and this is the example that
demonstrates it.

**Green:** `cargo xtask examples` gets past the `validate` row.

**Commit:** `feat(rust): add the validate example`

---

## Block 3 — `lint.rs` (red: the `lint` row)

The richest of the six. Four things to show, in this order:

**1. Packs disagree, and the counts are not what they look like.** Run `LINTY` (the
source is in "Measured library behavior" above; inline it as a `const`) through all six
packs and print a table: pack, errors, warnings, fixable, total diagnostics. The
measured values are pinned above — `recommended` 0/2/1/4, `style` 0/0/0/2, and so on.
Then explain the shape in prose, because the numbers alone read as a bug:

- Every pack reports the validator's two diagnostics (W0101, W0103). Only
  `recommended` and `strict` add the linter's (W0201, W0210).
- `warning_count` counts **lint** warnings only, which is why three packs show
  `warning_count == 0` alongside two diagnostics.
- `@wgslender/minify` adds `Severity::Hint` diagnostics (`M0100`) that appear in
  neither count.

**2. Overrides, including the one that does nothing.** From `recommended`:
`no-redundant-casts` → `Off` drops warnings 2 → 1; `no-unreachable` → `Error` gives
1 error and 1 warning. Then, deliberately, `no-unreachable-code` → `Error`, which is
**not a rule id** and changes nothing (0 errors, 2 warnings). Print it beside the
correct one so the silent no-op is visible. Rule ids live in `src/lint/rules/*.zig`.

**3. `RuleSetting::WarnWith`, and the gap it exposes.** Build the options `Value` with
`FromStr` — the only construction available to a consumer, because `serde_json` is not
a dependency the facade passes through:

```rust
use core::str::FromStr as _;
// `wgslender::Value` is `serde_json::Value` re-exported, but `serde_json` itself
// is not a dependency you get — so `json!` is out of reach and this is the way in.
let ignore_trivial = wgslender::Value::from_str(r#"{"ignore":[0,1]}"#)?;
```

A comment saying why, not just the code. Then, in the same block, add a short
paragraph to the `RuleSetting` rustdoc in
`packages/rust/wgslender-core/src/lint.rs` pointing at `Value::from_str` — a reader
hitting the wall in the docs should not have to find the example to get out.

**4. `lint_fix`, and whose report it is.** Fix `LINTY` with `recommended`: the output
differs in exactly one place (`u32(i * 2u)` → `i * 2u`), the returned report describes
the source **as handed in** (`fixable_count == 1`), and re-linting the fixed source
gives `warning_count == 1, fixable_count == 0`. Print all three states. The
pre-fix-report asymmetry is documented on `LintFixOutcome` and is exactly the kind of
thing an example makes stick.

Close by asserting the fixed source still validates. An autofix that emits invalid
WGSL is the failure mode worth guarding, and `wgslender-core/tests/lint.rs:204` already
guards it in the suite — the example showing it too costs three lines.

**Green:** `cargo xtask examples` gets past the `lint` row.

**Commit:** `feat(rust): add the lint example` (the rustdoc paragraph rides along —
same subject).

---

## Block 4 — `compile.rs` (red: the `compile` row)

**What it shows:** a shader becomes a self-expanding wasm module; what is in the
bytes; when it is worth doing.

**Three parts:**

1. **The mechanics.** `compile(demo.wgsl, &MinifyOptions::default())` → 561 B wasm,
   `original_size == 968`. Show the first eight bytes are `00 61 73 6d 01 00 00 00`
   and say what they are. State the module's contract, from the `CompiledShader`
   rustdoc: no imports, exports `memory` and `generate() -> i32`, which writes the
   minified WGSL at offset 0 and returns its length. Note that `original_size` is the
   size of the *input*, not of what `generate` produces.

2. **When it pays.** This example must not oversell. Measured:

   | | source | minified | wasm | ratio |
   |---|---|---|---|---|
   | small (~900 B) | 894 | 481 | 609 | 1.27 |
   | medium (~4 KB) | 4 292 | 1 127 | 998 | 0.89 |
   | large (~29 KB) | 28 855 | 8 266 | 4 676 | 0.57 |

   The wasm loses on small shaders — fixed decoder overhead of roughly 500 bytes,
   crossover around 1–2 KB of minified text. Show at least two points on this curve so
   the shape is visible. **Do not add a fixture** to get a large shader: build one in
   the example by emitting N parameterised helper functions into a `String`, which is
   self-contained, obviously synthetic, and lets the example print the crossover it
   actually found. Pin whatever it produces; the three rows above are the reference.

3. **What counts as failure.** `compile("fn main( { let ; }")` →
   `Err(Error::Compile(diagnostics))` with 4 parse diagnostics, all line 1, none
   carrying a code — match on `Error::Compile` and print them. Then the other half:
   `invalid.wgsl`'s content (inline it) **compiles fine**, because only the parser
   rejects; a type error does not stop it. Both halves, or the reader learns the wrong
   rule. `compile` is one of only two deliberate `Err`-on-bad-shader exceptions in the
   crate (`lib.rs:118-124`), and the header should say so.

**Green:** `cargo xtask examples` gets past the `compile` row.

**Commit:** `feat(rust): add the compile example`

---

## Block 5 — `refactor.rs` (red: the `refactor` row)

The biggest gap: 871 LOC, 14 public functions, zero runnable examples. Use
`demo.wgsl` — it is published, and every offset below was measured against it.

**Read the two traps in "Measured library behavior" before writing a line.** Offset
593 is `fn luminance`'s name; `demo.find("luminance")` gives 93, which is inside the
header comment and makes every call answer `None`/`SymbolNotFound`. Derive it as
`find("fn luminance") + 3`.

**Structure it as the two ways in, then the edits, then the failures:**

1. **By offset** — what an editor has when a cursor is somewhere.
   `find_references(demo, 593, IncludeDeclaration::Yes)` → two references, 593..602
   (`is_write: true`, the declaration) and 830..839 (`is_write: false`). With
   `::No` → just the second. Print the source text at each range; a byte range the
   reader cannot see resolved is not illuminating. This is also where
   `IncludeDeclaration` earns its existence as an enum rather than a `bool` — say so.

2. **By stable id** — what a tool has after the file changed.
   `stable_id_at_offset(demo, 593)` → `StableId("v1:fn:luminance")`. Then
   `locate_stable_id` → 593..602 (the name) and `locate_declaration` → 590..681 (the
   whole `fn`), and show that the two answer different questions. Say what "stable"
   buys: an offset is invalidated by the next keystroke, an id survives a reparse.

3. **The edits.** `rename_by_id(demo, id, "relative_luminance")` → 2 `Edit`s at
   593..602 and 830..839. Show the `Edit` list *and* the `_apply` form:
   `rename_apply(demo, 593, "relative_luminance")` → 2 edits, 968 → 986 bytes. Make
   the point the `Edit` rustdoc makes — edits are ordered by `start` and never
   overlap, so applying them yourself means back to front, or let `_apply` do it.

   Then the type edit, via `StableId::new("v1:var:params")` — a literal id, which is
   what a tool that stored one would have: `locate_stable_id` → 506..512,
   `locate_type` → 514..520, `change_type(…, "Uniforms")` → 1 edit at 514..520.

   Then removal, on a small inline source with an unused helper (not `demo.wgsl` —
   nothing in it is removable without breaking it). Measured: 207 → 156 bytes. **Show
   the output verbatim, blank lines and all** — `remove_declaration_apply` removes the
   declaration, not the whitespace around it. An example that hides that is setting up
   a surprise.

4. **The failures**, which are the module's third answer shape and worth their own
   section. `rename(demo, 593, "fn")` → `Refactor(InvalidIdentifier)`;
   `rename(demo, 0, "x")` → `Refactor(SymbolNotFound)`;
   `rename_by_id(demo, "v1:fn:nope", "x")` → `Refactor(SymbolNotFound)`. Contrast with
   the queries, which answer `Ok(None)` for the same "not there" condition —
   `locate_stable_id(demo, &StableId::new("nonsense"))` → `Ok(None)`. The module's
   rule, from its own rustdoc: *asking about something absent is a fine question with
   the answer "no"; asking to edit something absent is a broken request.* Match on
   `RefactorError` variants, do not `{:?}` them.

This example will be the longest of the six. That is proportionate — it is the only
documentation of the crate's largest module that a reader can run.

**Green:** `cargo xtask examples` gets past the `refactor` row.

**Commit:** `feat(rust): add the refactor example`

---

## Block 6 — the last three: options, `include_wgsl!`, `reflect_json`

Three small pieces; one block, because none justifies a session.

### `minify_options.rs`

The `MinifyOptions` builder, one row per option, against a shader where the options
actually bite. Measured over an 894 B synthetic (three uncalled helpers, two sibling
scopes):

| Options | bytes |
|---|---|
| `default()` | 481 |
| `.minify_identifiers(false)` | 581 |
| `.tree_shaking(false)` | 577 |
| `.keep_names(["luminance"])` | 505 |
| `.mangle_external_bindings(true)` | 452 |
| `.sort_declarations(true).scope_local_rename(true)` | 481 |

Two things this example must get right, or it teaches something false:

- **Use a shader with dead code.** On `demo.wgsl`, `tree_shaking(false)` costs
  literally nothing (412 either way) because there is nothing to shake. Inline the
  synthetic shader instead.
- **The compression pair produces identical byte counts** (481 = 481), because
  `sort_declarations` and `scope_local_rename` optimise for DEFLATE, not for length.
  Printing that row next to the others without comment reads as "these options do
  nothing". Either compress both outputs and show the real difference, or print the
  identical number with a sentence saying where the win actually is. The README's
  claim is 5–29% gzip savings; `compile` (Block 4) turns both on for exactly this
  reason.

Also show `mangle_external_bindings` for what it costs, not just what it saves: 452
bytes is the smallest row *and* the one that renames the names a host program binds
against. The `minify.rs` example already shows the default keeping them; this is the
other side.

### `include_wgsl.rs`

The default-feature macro, and currently the only one of the three without an example.
Small: `include_wgsl!("tests/fixtures/demo.wgsl")` (published — safe), print the length
against `include_str!` of the same file, and state the rule that surprises everyone —
**the path is relative to the crate root, not to the file the macro is written in**.
Show one option in the macro's option list (its own rustdoc has the table) and note
that a shader with a mistake in it fails `cargo build` rather than the pipeline, which
is the entire point.

Needs `[[example]] name = "include_wgsl", required-features = ["macros"]` in
`wgslender/Cargo.toml`, alongside the two that are already there. `macros` is a default
feature, but `--no-default-features` builds must skip the target rather than fail to
find a `main` — the comment already in that file explains the pattern.

Close with `wgslender::version()` → `"1.1.0"`, one line: it is the last uncovered
public function and it belongs next to "what got compiled into your binary".

### `reflect_types.rs` — append a `reflect_json` section

Not a new example; three or four lines at the end of the existing one.
`reflect_json(source)` returns the raw v2 envelope — 4 577 bytes for `demo.wgsl` —
carrying fields the typed `Reflection` does not expose: `nameOffset`, `stableId`,
`declSpan`. Print the length and the first binding's `stableId`, and say why it
matters: that `stableId` is exactly what `StableId::new` takes, so `reflect_json` is
the bridge to the `refactor` module. Point at `refactor.rs` (Block 5), which reaches
the same symbol from the other direction.

Keep it short. The existing example is about the typed API and should stay that way;
this is a footnote saying where to go when the typed API is not enough.

**Green:** `cargo xtask examples` is fully green — ten rows, ten examples.

**Commit:** `feat(rust): add the remaining option, macro and reflect-json examples`

---

## Block 7 — documentation truth pass, and the full gate

Small, surgical, no new behavior.

1. **`packages/rust/README.md § Examples` (line 231).** It lists four commands; make
   it ten, grouped so a reader can find the one they want:

   ```
   cargo run -p wgslender --example minify           # what shrank, and by how much
   cargo run -p wgslender --example minify_options   # what each option costs
   cargo run -p wgslender --example validate         # accepted, and accepted-but-strict
   cargo run -p wgslender --example lint             # packs, overrides, autofixes
   cargo run -p wgslender --example reflect_types    # bindings, layouts, entry points
   cargo run -p wgslender --example refactor         # find, rename and edit by symbol
   cargo run -p wgslender --example compile          # a shader as a wasm module
   cargo run -p wgslender --example include_wgsl     # embedding at compile time
   cargo run -p wgslender --example wgsl_module      # a generated module's layout
   cargo run -p wgslender --features compress --example embed_compressed
   ```

   Add a line noting `cargo xtask examples` runs all of them.

2. **`packages/rust/wgslender/src/lib.rs`, the "What is here" table (lines 83-91).**
   Every row now has an example; name it in the row. This is the table that made the
   gap visible in the first place, and it should be the thing that keeps it closed.

3. **`packages/rust/README.md § The gate` (line 157).** It describes what
   `cargo xtask check` runs; add the `examples` step. Say what it proves that
   `--all-targets` did not: examples are now *executed*, not merely compiled.

4. **`docs/plans/README.md`** — the index does not exist under `docs/plans/` (the
   plan index lives at `plans/README.md` and covers a different, finished set). Either
   create a one-table `docs/plans/README.md` for this plan and future ones, or add a
   pointer from `plans/README.md`. Hugo's call; default to the pointer, since a
   README listing one plan is not worth its own file.

5. **Run the whole gate**, which has not been green since Block 1:

   ```
   cd packages/rust && cargo xtask check
   ```

   All eight steps, including the new one. Then `cargo xtask msrv` — six new examples
   are six new things that could use a post-1.85 API, and `--all-targets` means the
   MSRV check covers them.

**Commit:** `docs(rust): document the ten examples and the gate step that runs them`

---

## Behavior changes (explicit)

Called out rather than smuggled, per house rule. None of these change library
behavior; two change what a contributor and a consumer see.

1. **`cargo xtask check` gains a step and gets slower.** Ten examples, each a
   `cargo run`, after the doc build. Cached builds make it cheap; a cold one adds a
   link step per example. A contributor who was used to `check` finishing in N seconds
   will notice.
2. **`cargo xtask check` is red from Block 1 until Block 6 lands.** Intended and
   stated in Block 1. Anyone running the gate mid-plan sees a failure that is the
   plan's progress bar, not a regression.
3. **The published crate grows by six example files.** `examples/**/*.rs` is in the
   `include` list, so they ship. Roughly 25–35 KB of source; no new dependency, no new
   fixture, no change to the built artifact.
4. **One rustdoc paragraph is added to `RuleSetting`** (Block 3), documenting
   `Value::from_str`. Documentation only — the public API is untouched.
5. **Not changed, deliberately:** the `Value`/`serde_json` ergonomics gap. It is a real
   defect in the published API — `RuleSetting::WarnWith` takes a type a consumer cannot
   conveniently build — but fixing it is an API decision, not an examples task. Flagged
   here so it is a decision rather than an oversight.

---

## Definition of done

- Ten examples in `packages/rust/wgslender/examples/`, each with a `//!` header, a
  `cargo run` line, and aligned output that explains itself.
- Every public item in the crate's "What is here" table has a runnable example, and
  the table names it.
- `cargo xtask examples` runs all ten, fails on a non-zero exit or empty output, and
  fails if an example file exists that the table does not list.
- `cargo xtask check` green, all eight steps. `cargo xtask msrv` green.
- No new fixture; the `include` list is unchanged apart from nothing.
- `packages/rust/README.md` lists all ten and describes the gate step accurately.
- Every number an example prints came from the library, and matches this plan's
  measured tables — or the divergence is reported as a library change.
