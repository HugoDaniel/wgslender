# Issue #2: scope-local rename hands two symbols one name

**Report:** GitHub issue #2, "scopeLocalRename emits shadowed names", filed
2026-09-09 by sagacity against wgslender 1.4.1. Evidence read against this
tree at `38f38a0` (the 1.5.0 artefact rebuild) on 2026-09-29, working tree
clean. Reproduced on the native CLI, on the npm package's 1.5.0 wasm through
the same `minify()` call the report used, and on the `compile` subcommand.

**Status:** proposed, not executed. The plan is at the end of this file. Check
`git log -- src/Minifier.zig tests/collision_test.zig` before trusting this
line.

## The claim

With `scopeLocalRename: true` the minifier can give a `for` loop counter the
same name as a function-scope binding that is still live, and the loop body
then reads the counter where it meant the outer binding. The output is
well-formed WGSL, so it compiles and runs, and `validate()` reports it only as
the shadowing warning `W0100`. A pipeline that gates on errors alone ships a
shader that means something else.

The reporter's shader, unchanged:

```wgsl
fn accumulate(x: i32) -> i32 {
  let base = x * 2;
  var total = 0;
  for (var idx = 0; idx < 4; idx++) {
    total = total + base + idx;
  }
  return total;
}
```

What this tree prints for it, on every path that enables scope-local naming:

```
$ wgslender --scope-local-rename repro.wgsl
fn e(a:i32)->i32{let b=a*2;var c=0;for(var b=0;b<4;b++){c=c+b+b;}return c;}

$ wgslender compile repro.wgsl -o repro.wasm && <run generate()>
fn e(a:i32)->i32{let b=a*2;var c=0;for(var b=0;b<4;b++){c=c+b+b;}return c;}

$ node -e '… minify(src, { minifyIdentifiers: true, scopeLocalRename: true }) …'
fn e(a:i32)->i32{let b=a*2;var c=0;for(var b=0;b<4;b++){c=c+b+b;}return c;}
```

`base` became `b` and the counter `idx` also became `b`, so `total + base +
idx` prints as `c+b+b` and reads the counter twice. `validate` on that output
says exactly what the reporter said it says, and nothing more:

```
repro.min.wgsl:1:44: warning: 'b' shadows an earlier declaration [W0100]
valid
```

The claim is correct in every particular, and it understates the reach: the
`compile` subcommand always uses scope-local naming, so binary shaders carry
the bug without anyone opting in.

## Root cause

Scope-local renaming is a wrapper over the ordinary renamer, and the two hand
out names from different sequences that are never checked against each
other. The wrapper covers most function-local declarations and lets the rest
fall through to the renamer underneath, and a symbol that falls through gets
a name the wrapper never reserved.

The wrapper is `ScopeLocalRenamer` in `src/Minifier.zig:435-571`. Its `init`
walks every function, gives parameters and body locals canonical names from
a per-function counter (`a`, `b`, `c`, restarting at each function), and
stores them in an `overrides` map. Its `nameForSymbol` at
`src/Minifier.zig:565-570` answers from that map first and otherwise
forwards to the base renamer:

```zig
if (self.overrides.get(ref.index())) |name| return name;
return self.base.nameForSymbol(ref);
```

The body walk, `collectBodyLocals` at `src/Minifier.zig:503-563`, is a stack
of compound statements. It names a `.decl` statement when it meets one and
pushes nested bodies for later. Its `for` arm pushes only the loop body:

```zig
.@"for" => |s| try bodies.append(arena, s.body),
```

`Ast.ForStmt` at `src/Ast.zig:1124-1130` keeps the loop's initialiser in a
separate field, `init_stmt: ?Stmt`, and the parser puts a `var` or `let` there
as a `.decl` statement wrapped in its own block scope (`src/Parser.zig:2181-
2200`). The walk never looks at that field, so the counter never enters
`overrides`, and at print time it gets whatever the base renamer chose for
it.

That would be harmless if the two sequences could not overlap, but they
overlap by design. The base renamer, `MinifyRenamer` in `src/Renamer.zig`,
gives every renameable symbol in the module one slot (`allocateSlots`,
`src/Renamer.zig:141-165`) and walks the slots with a single monotonic name
index (`assignNames`, `src/Renamer.zig:179-211`), so its names are unique
across the whole module and it never shadows anything on its own. Locals are
frequent, so they sit early in that sequence and get one-letter names. The
wrapper's sequence also starts at `a` in every function. The only names the
wrapper refuses to hand out are the base names of module-scope declarations
(`src/Minifier.zig:456-465`, added when a parameter once shadowed a struct
return type). The base name of a fallen-through local is not in that set, so
a collision is the expected outcome for any function with a `for` loop, not
an edge case, and the reproduction collides on the first try.

## The same seam, three more shapes

Every shape below was run against this tree and reproduces.

**Any `for` initialiser, and nested loops.** A `let` initialiser fails the
same way, and nesting multiplies the collisions:

```
fn f(x: i32) -> i32 { let base = x * 2; var total = 0;
  for (let idx = 0; idx < 4;) { total = total + base + idx; } return total; }
→ fn e(a:i32)->i32{let b=a*2;var c=0;for(let b=0;b<4;){c=c+b+b;}return c;}

fn f(x: i32) -> i32 { let base = x * 2; var total = 0;
  if (x > 0) { for (var i = 0; i < 4; i++) { for (var j = 0; j < 4; j++) {
    total = total + base + i * j; } } } return total; }
→ fn f(a:i32)->i32{let b=a*2;var c=0;if (a>0){for(var b=0;b<4;b++){for(var c=0;c<4;c++){c=c+b+b*c;}}}return c;}
```

In the second output `total` and the inner counter are both `c`, and `base`
and the outer counter are both `b`.

**A local pinned by `keep_names`.** The wrapper skips any symbol the
`RenamePolicy` pins (`src/Minifier.zig:477` and `:525`), and a pinned symbol
answers with its original name through the base. Nothing reserves that name
in the wrapper, so a canonical name can land on it:

```
$ wgslender --scope-local-rename --keep-names a f.wgsl
fn f(x: i32) -> i32 { let a = 1; return x + a; }
→ fn c(a:i32)->i32{let a=1;return a+a;}
```

The parameter `x` became `a` and the kept local is still `a`, so `x + a`
reads the local twice. The base renamer never has this problem because
`runBuildReservedNames` at `src/Pipeline.zig:215-221` puts every `keep_names`
entry into the set it skips; the wrapper never sees that set.

**WGSL keywords.** `allocCanonicalName` at `src/Minifier.zig:491-500` skips
only the reserved global names. The base renamer skips its whole reserved
set through `skipReservedNames` (`src/Renamer.zig:265-271`), which
`computeReservedNames` fills with 417 entries: keywords, reserved words,
builtin types and functions, address spaces, access modes and texel formats
(`src/Renamer.zig:421-558`). The wrapper's sequence is the same
`numberToMinifiedName` (`src/Renamer.zig:295-313`), and index 320 of it is
`if`, index 326 is `of`. A function with 321 or more parameters and locals
gets a local named `if`:

```
$ wgslender --scope-local-rename many_locals.wgsl | wgslender validate -
…: error: 'let ' requires an initializer [E0300]
…: error: expected '='
```

This one is not silent (the output does not parse), but it is the same
missing reservation.

**The compiler's non-minify mode.** `prepareRenamer` in
`src/Compiler.zig:275-297` builds a no-op base when `options.minify` is false
and `sortedMinifiedText` at `src/Compiler.zig:228` wraps it anyway, so a
fallen-through local keeps its source name while its neighbours get canonical
ones. A source local named `i` next to nine or more canonical names collides
the same way.

## Where it ships

Three places construct the wrapper, and all three inherit every shape above.

| Caller | Line | Reached by |
|---|---|---|
| `Pipeline.runPrint` | `src/Pipeline.zig:264-268` | `--scope-local-rename`, `scopeLocalRename` in the npm package and in `wgslender.json`, the Go and Rust option of the same name |
| `Compiler.sortedMinifiedText` | `src/Compiler.zig:228` | every `compile` call: the CLI subcommand, the C ABI and wasm exports, and the bindings built on them |
| `MinifyEstimator` | `src/MinifyEstimator.zig:152-155` | LSP size estimates; wrong names, right lengths, so no user-visible effect |

The estimator has the pipeline's reserved set in scope at
`src/MinifyEstimator.zig:130-145`, which matters for the fix below.

## Why nothing caught it

**The collision gate skips warnings.** `expectMinifiesWithoutRedeclaration`
in `tests/collision_test.zig:107-124` is the load-bearing check for renamer
collisions, and its loop reads `if (d.severity != .@"error") continue;`. That
is the same blind spot as the reporter's pipeline. Shadowing is legal WGSL,
so a shadow can only ever surface as the warning `W0100`, emitted by the scope
walk in `src/validator/Statements.zig:625-650`. An absent name-uniqueness
error is not evidence that the renamer kept every reference pointing at the
same symbol.

**The corpus was correct by luck.** Over the 324 non-Tint shaders under
`tests/testdata`, minifying and re-validating shows how many shaders gain a
`W0100` they did not have in source:

| Config | Shaders that gain a shadow |
|---|---|
| defaults | 0 of 324 |
| `--mangle-external-bindings` | 0 of 324 |
| `--sort-declarations` | 0 of 324 |
| `--scope-local-rename` | 4 of 324: `shadow_fragment.wgsl`, `blur.wgsl`, `compute.toys/jitter_starfield.wgsl`, `compute.toys/spaced.wgsl` |

`--sort-declarations --scope-local-rename` behaves the same as the single
flag on `blur.wgsl` (four shadows either way). The two shaders examined
closely keep their meaning only because the inner shadow is declared before
every read of that name in the loop body, which is an accident of those two
sources.

**The exhaustive tier never turns the flag on.** No file under
`tests/exhaustive/` mentions `scope_local`, so the Tint semantic-preservation
run and the fuzzers exercise the default renamer only.

**Nothing else has this walker gap.** Every other `for` arm in the tree was
read. The walkers that must see the initialiser do: `AstVisit`, `Dce`,
`reflect/CallGraph`, `lint/MultiVisitor`, `Edits`, `StableId`,
`incremental/Splice`, `validator/Uniformity`, `validator/Statements` and the
LSP handlers all visit `init_stmt`. The remaining arms in lint rules and
`blockHasExit` look at the body or the condition only, which is what those
passes are for. The wrapper is also the only renamer that layers over
another: the other `nameForSymbolFn` implementations are the base renamer,
the no-op renamer and the estimator's length renamer.

---

# Verdict

Accepted as a bug, to ship as a patch release. The wrapper's job is to give
every function-local symbol a name from one sequence; it misses one
declaration position and it never reserves the names that can still reach
the printer past it. The fix closes both, and closes the second one by
construction rather than by listing cases.

## Design

The invariant the wrapper must hold: **inside a function body, every
identifier the printer can emit comes from one of two disjoint sets.** The
first set is the canonical names the wrapper assigns. The second is every
name that reaches the printer without the wrapper (renamed globals, pinned
symbols answering with their source name, WGSL keywords and builtins), and
every member of the second set is reserved before the first canonical name
is handed out.

Three changes to `ScopeLocalRenamer` in `src/Minifier.zig`, one signature
change, three call sites.

**1. Visit the `for` initialiser.** In `collectBodyLocals`, the `for` arm
names a `.decl` in `s.init_stmt` the moment it meets the loop, before pushing
the body:

```zig
.@"for" => |s| {
    if (s.init_stmt) |is| if (is == .decl) try candidates.append(arena, is.decl.decl.nameRef());
    try bodies.append(arena, s.body);
},
```

That is the text-order position for the counter and it leaves the existing
naming order of everything else untouched, so shaders that print correctly
today print the same bytes after the change unless they contain a `for`
initialiser.

**2. Reserve every name that can bypass the wrapper.** `init` becomes
collect, reserve, name, in that order:

- Collect: walk every function as today (plus change 1) into an ordered list
  of candidate symbols per function, and a set of all candidates.
- Reserve: start from the pipeline's reserved set (a new `reserved:
  *const std.StringHashMapUnmanaged(void)` parameter; keywords, builtins and
  `keep_names` are already in it), then add `base.nameForSymbol(s)` for every
  symbol `s` in `module.symbols` that is not a candidate and is not of kind
  `.member`. That covers module-scope declarations (today's
  `src/Minifier.zig:449-465`), pinned locals, and any declaration position a
  future walker misses: a missed symbol keeps its base name, that name is
  reserved, and no canonical name can land on it. Struct members are
  excluded because they are not scope members (`declareSymbolNoScope` at
  `src/Parser.zig:1204`) and never occupy identifier position inside a body,
  so reserving their names would only burn short ones.
- Name: per function, restart the counter and assign a canonical name to each
  candidate in order, with `allocCanonicalName` skipping the reserved set as
  it does now.

**3. Signature and call sites.** `init(arena, module, base, policy, reserved)`.
`src/Pipeline.zig:265` passes `state.reserved.?`. `src/Compiler.zig`:
`RenamerPrep` (`:257-263`) gains a `reserved` field, `prepareRenamer` returns
`state.reserved.?`, and `sortedMinifiedText` (`:228`) passes it.
`src/MinifyEstimator.zig:153` passes the `reserved` it already built.

The 256-iteration ceiling in `allocCanonicalName` stays. The base renamer
skips the same 417-entry set under the same ceiling, and a run of
consecutive reserved names in the sequence is short.

### Rejected alternatives

- **Walk the scope tree instead of the statements.** `Ast.Scope`
  (`src/Ast.zig:182-203`) reaches every declared symbol by construction,
  including the implicit `for` block, and would make change 1 unnecessary.
  But its members are a hash map, so the walk has to sort by `ScopeMember.loc`
  to be deterministic, and that assigns names in strict text order where the
  statement walk names an enclosing body before its nested bodies. Every
  scope-local and `compile` output with a nested block would change bytes.
  Not needed for correctness; possible later as a compression experiment.
- **Only fix the `for` arm.** Closes the report, leaves the `keep_names` and
  keyword shapes open, and leaves the next missed position silent again.

### Behaviour changes, stated plainly

- **Output bytes change** for every scope-local or `compile` output whose
  functions contain a `for` initialiser declaration: the counter takes a
  canonical name, and every canonical name assigned after it in that
  function shifts by one. That includes the four corpus shaders above, which
  were correct by luck. No pinned golden is produced under these modes:
  `tests/snapshot_test.zig` keeps its goldens inline and never sets
  `scope_local_rename`, the Go, Rust and npm fixture sets contain no `for`
  initialiser, and the compile round-trip pin in `src/Compiler.zig:1724-1750`
  compares two live code paths, not stored bytes.
- **Output bytes change** for `--keep-names` with a pinned local, and for
  functions with 321 or more parameters and locals. Both were wrong.
- **`ScopeLocalRenamer.init` gains a parameter.** It is `pub` and reachable
  as `wgslender.Minifier.ScopeLocalRenamer`, so a Zig consumer calling it
  directly fails to compile until it passes a reserved set. No binding
  exposes it; the three in-tree callers are listed above.
- No option, flag, JSON key, C ABI or wire change.

## Plan

Three blocks. Each is self-contained: it says what to read, what to change,
and what proves it. Run tests from the repository root; the corpus tests read
goldens relative to it. The fast red/green check for one test file is

```
zig test --dep wgslender -Mroot=tests/collision_test.zig -Mwgslender=src/root.zig
```

and the gate is `zig build test -j1`, exit code only.

### Block 1: reds, in `tests/collision_test.zig`

Read `tests/collision_test.zig:1-142` first: `checkNoDuplicateNames`,
`expectMinifiesWithoutRedeclaration`, and the `rename_configs` table every
collision fixture runs against.

1. Add `expectNoIntroducedShadowing(arena, source, options)`. It validates
   `source`, minifies it, validates the output, and fails if the number of
   diagnostics with code `Diagnostic.Code.shadowing` grew, printing the
   output. Counting rather than banning is what keeps it sound: source
   shadowing is legal and must survive, dead-code elimination may remove a
   shadow, and the base renamer's module-unique names mean no config can
   legitimately add one (the table above: zero shaders in 324 for every
   config without the wrapper). Document that argument on the helper.
2. Add a `shadow_fixtures` table of `{ name, source, keep_names }` and one
   test that runs every fixture against every `rename_configs` entry through
   both helpers, printing the fixture and config names on failure. Fixtures:
   the report's shader; the `let` initialiser; the nested loops inside `if`;
   the pinned local with `keep_names = &.{"a"}`; a `loop`/`continuing`,
   `switch` and `while` shader that already prints correctly, so the test
   also pins the shapes that must not regress; and a function with 340
   locals built with a `comptime` loop (`@setEvalBranchQuota`), which is the
   keyword shape.
3. Add a structural completeness test: parse a shader with every declaration
   position, run the passes `Compiler.prepareRenamer` runs
   (`src/Compiler.zig:284-292`, through `wgslender.Pipeline`), build the
   wrapper, then walk `module.scope` recursively and assert every
   `ScopeMember` of a non-module scope is either pinned by the policy or
   present in `overrides`. This is the test that fails the next time a
   declaration position is added and not walked.
4. Call `expectNoIntroducedShadowing` from the two existing
   `for (rename_configs)` tests at `tests/collision_test.zig:316` and `:403`.

Expected reds before Block 2: fixture 1, 2, 3 and 6 fail under the two
scope-local configs on the shadowing count (6 fails on parse), fixture 4
fails under those configs on the count, and the structural test fails on the
`for` counter. Everything else stays green.

Commit: `test(collision): pin renamer-introduced shadowing under scope-local rename`.

### Block 2: the fix, in `src/Minifier.zig` and three callers

Read `src/Minifier.zig:429-571` and the three call sites. Then:

1. Restructure `init` into collect, reserve, name as described under Design,
   with the new `reserved` parameter. Keep `collectBodyLocals` as the
   statement walk, feeding an ordered candidate list instead of naming
   inline, and add the `for` initialiser arm.
2. Replace the doc comment on `ScopeLocalRenamer` with the invariant in one
   paragraph: what the two name sets are, why members are excluded, and that
   a missed declaration keeps its base name safely.
3. Update `src/Pipeline.zig:265`, `src/Compiler.zig` (`RenamerPrep`,
   `prepareRenamer`, `sortedMinifiedText`) and `src/MinifyEstimator.zig:153`.
4. Run the single-file check: every Block 1 test green. Run
   `zig build test -j1`; expect exit 0 and no golden drift (the validator
   path does not import the minifier, so the Tint goldens cannot move).
   `tests/determinism_test.zig` and `tests/oom_test.zig` already cover the
   scope-local path and must stay green.

Commit: `fix(minifier): name for-init declarations and reserve every base
name under scope-local rename`, with `Fixes #2` in the body.

### Block 3: artefacts, proof, changelog

1. `zig build release-assets`: the source changed, so every embedded wasm
   changes and `tests/wasm_freshness_test.zig` fails until the five copies
   are rebuilt. Commit them as `build(wasm): rebuild every artefact for the
   scope-local rename fix`.
2. Prove it where the reporter saw it: `cd packages/js-npm && npm test`, then
   the report's `minify()` call through `lib/main.js`, expecting a
   `validate()` with zero diagnostics. Rerun the corpus measurement with
   properly quoted flags and expect zero shaders gaining a shadow under every
   config, the two-flag one included. `cargo xtask check` for Rust, since it
   links the static library, and the Go package tests, since they embed the
   wasm.
3. `CHANGELOG.md`: a `## [Unreleased]` section with a `### Fixed` entry that
   names the three shapes, says that scope-local and `compile` output bytes
   change for shaders with a `for` initialiser, and credits the reporter.
   `README.md` needs no change; the `--scope-local-rename` row at line 76
   still describes the flag.
4. Reply on issue #2 (draft below) once the fix is on `main`, and cut 1.5.1
   with `./scripts/release.sh` as a separate step.

Commit: `docs(changelog): record the scope-local rename fix`.

### Effort

Block 1 about twenty minutes, Block 2 about thirty, Block 3 about an hour of
mostly waiting on the full suite and the binding suites.

## Not in this plan

- Turn `scope_local_rename` on in one of the exhaustive differential or fuzz
  configurations so the Tint corpus exercises the wrapper.
- A note in `docs/testing.md` or the README that a `W0100` present in
  minified output and absent in source is always a minifier bug, so hosts
  can gate on it.
- Strict text-order canonical naming (the scope-tree walk) as a compression
  experiment, measured on the compute.toys corpus before deciding.

## Reply to the reporter, draft

> Fixed in 1.5.1. The scope-local renamer never looked at a `for` loop's
> initialiser, so the counter kept the name the ordinary renamer gave it and
> that name was never checked against the per-function `a, b, c` sequence.
> The same missing reservation also let a `keepNames` local collide with a
> renamed parameter, and let a function with more than 320 locals receive a
> local named `if`. All three are closed by reserving every name that can
> bypass the renamer before it hands out any, and the collision suite now
> fails on any shadow that minification introduces, warning or not, which is
> the check that should have caught this. Note that scope-local and
> `compile` output bytes change for shaders with a `for` initialiser, since
> the counter now takes a canonical name. Thank you for the precise report.
