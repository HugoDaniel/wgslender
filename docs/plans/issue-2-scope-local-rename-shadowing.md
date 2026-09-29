# Issue #2: scope-local rename hands two symbols one name

**Report:** GitHub issue #2, "scopeLocalRename emits shadowed names", filed
2026-09-09 by sagacity against wgslender 1.4.1. Evidence read against this
tree at `38f38a0` (the 1.5.0 artefact rebuild) on 2026-09-29, working tree
clean. Reproduced on the native CLI, on the npm package's 1.5.0 wasm through
the same `minify()` call the report used, and on the `compile` subcommand.

**Status:** **executed, shipped in 1.5.1** (2026-09-29). All four blocks are on
`main` — `810667e` (the reds), `d4bae45` (the fix), `3a2658d` / `72028f8` /
`cddfb86` (compiler seam, estimator, compile-text tests), `69487aa` / `ab8bdf1`
(artefact rebuilds), `d079a3e` (changelog), `75a7457` (the follow-up recorded
under "Execution" at the end of this file). Reviewed once on 2026-09-29; the
review section at the end of this file records what the review changed. Check
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
ones. Decoded from the wasm that `compile --no-mangle` produces for a loop
whose counter is named `a`:

```
fn f(a:i32)->i32{var b=0;for(var a=0;a<4;a++){b=b+a+a;}return b;}
```

The parameter `x` became `a`, the counter kept its source name `a`, and
`x + a` reads the counter twice. Default `compile` gives the same shader
`var b=0;for(var b=0;…){b=b+a+b;}`, which is the report's shape.

## Two crashes on the same ceiling

Both name generators stop after 256 consecutive reserved names and declare
the rest unreachable. The reserved set is not bounded by the language: it
holds every renamed global's name and every user pin, so a valid shader can
exceed it.

- `allocCanonicalName` at `src/Minifier.zig:492-499` walks the canonical
  sequence with `for (0..256)`. A shader with 300 used module-scope
  constants renames them to the first 300 names of the sequence, the wrapper
  reserves all 300, and the first local of any function panics:
  `thread … panic: reached unreachable code, src/Minifier.zig:499`.
- `skipReservedNames` at `src/Renamer.zig:265-271` has the same loop. Passing
  the first 260 names of the sequence as `--keep-names` panics the ordinary
  renamer without scope-local naming: `src/Renamer.zig:270`, reached from
  `assignNames`. `estimateRenameLength` shares the helper, so the LSP's size
  estimate would hit it as well.

In a release build `unreachable` is undefined behaviour rather than a panic.

## Where it ships

Three places construct the wrapper, and all three inherit every shape above.

| Caller | Line | Reached by |
|---|---|---|
| `Pipeline.runPrint` | `src/Pipeline.zig:264-268` | `--scope-local-rename`, `scopeLocalRename` in the npm package and in `wgslender.json`, the Go and Rust option of the same name |
| `Compiler.sortedMinifiedText` | `src/Compiler.zig:228` | every `compile` call: the CLI subcommand, the C ABI and wasm exports, and the bindings built on them |
| `MinifyEstimator.estimate` | `src/MinifyEstimator.zig:152-155` | LSP size estimates, in both of its modes |

The estimator has two modes (`src/MinifyEstimator.zig:41-59`). The full mode
(`use_full_minify`) runs the production renamer and prints real names. The
cheap mode runs a `LengthRenamer` (`src/MinifyEstimator.zig:283-291`) that
answers every symbol with a run of `x` of the right length, so when the
wrapper reserves "the base name of every global" in cheap mode it reserves
`x` and `xx` instead of the names the real run reserves. The canonical
sequence then crosses into two-character names at a different local, and the
cheap estimate undercounts near that boundary. Measured on a shader with 10
used globals and 52 locals under `scope_local_rename`:

| Path | Bytes |
|---|---:|
| cheap estimator | 978 |
| full estimator | 998 |
| actual minifier | 998 |

That inaccuracy predates this issue and is not caused by the fix, but the
fix has to touch the same reservation step, and passing the keyword set
alone does not repair it.

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

## A neighbouring bug this plan does not fix

A local declared with the same name as a module-scope alias, struct or
function binds wrongly before any renamer runs, and no amount of name
reservation can repair a reference that already points at the wrong symbol.

```wgsl
alias T = i32;
fn f() -> i32 {
  let T: T = T();
  return T;
}
```

Validates as source (one `W0100`), and minifies under the default renamer to
`fn b()->i32{let a:a=a();return a;}`, which fails to validate (`E0200
unknown type 'a'`, `E0204`). In WGSL the declared name is not in scope until
its declaration ends, so the type `T` and the call `T()` mean the alias. The
binder disagrees twice: `AstVisit.visitType` at `src/AstVisit.zig:370` sets
`ctx.current_loc = 0` before looking a type name up, which switches off the
text-order filter and lets the later local win, and the initialiser is
resolved with the declaration it initialises already visible. Six Tint
shadowing fixtures are skipped for exactly this in
`tests/exhaustive/tint_test.zig:48-57` (`shadowing/alias/{const,let,var}`,
`shadowing/function/var`, `shadowing/struct/{let,var}`).

This is a binder bug, it reproduces with every naming mode, and it needs its
own plan. The binding-preservation helper this plan adds (Block 1) is the
test that will catch it; the fixture above must not enter this plan's fixture
table until the binder is fixed, or it fails for the wrong reason.

---

# Verdict

Accepted as a bug, to ship as a patch release. The wrapper's job is to give
every function-local symbol a name from one sequence; it misses one
declaration position, it never reserves the names that can still reach the
printer past it, and both name generators stop at a fixed count that a valid
shader can exceed. The fix closes all three, and closes the reservation gap
by construction rather than by listing cases.

## Design

The invariant the wrapper must hold: **inside a function body, every
identifier the printer can emit comes from one of two disjoint sets.** The
first set is the canonical names the wrapper assigns. The second is every
name that reaches the printer without the wrapper (renamed globals, pinned
symbols answering with their source name, WGSL keywords and builtins), and
every member of the second set is reserved before the first canonical name
is handed out.

**1. Visit the `for` initialiser.** In `collectBodyLocals`, the `for` arm
records a `.decl` in `s.init_stmt` the moment it meets the loop, before
pushing the body:

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

**2. Reserve every name that can bypass the wrapper.** `init` becomes three
named steps, collect, reserve, name, in that order, each callable on its own
so a unit test can drive them:

- `collect`: walk every function as today (plus change 1) into an ordered
  list of candidate symbols per function, and a set of all candidates.
- `reserve`: start from the pipeline's reserved set (a new `reserved:
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
- `name`: per function, restart the counter and assign a canonical name to
  each candidate in order, skipping the reserved set.

**3. Terminate on the reserved set, not on a constant.** At most
`reserved.count()` names of the sequence can be reserved, so a walk of
`reserved.count() + 1` consecutive indices always reaches a free name. Both
`allocCanonicalName` (`src/Minifier.zig:492`) and `skipReservedNames`
(`src/Renamer.zig:266`) loop to that bound instead of 256, and keep the
`unreachable` after it, which is now a true statement. `estimateRenameLength`
inherits the fix through the shared helper.

**4. The estimator's cheap mode reserves real names.** `estimateRenameLength`
already walks the real sequence to compute each rank's length
(`src/MinifyEstimator.zig:330` region, through `skipReservedNames`), so the
sequence index of every symbol's name is known. The `LengthRenamer` keeps
that index per symbol and answers with the materialised name for module-scope
declarations and pinned symbols, which is what the wrapper reserves, and with
the placeholder for everything else, which the wrapper overrides anyway.
Cheap and full estimates then agree with the minifier on the boundary shader
above.

**5. Signature and call sites.** `ScopeLocalRenamer.init(arena, module,
base, policy, reserved)`. `src/Pipeline.zig:265` passes `state.reserved.?`.
`src/Compiler.zig`: `RenamerPrep` (`:257-263`) gains a `reserved` field,
`prepareRenamer` returns `state.reserved.?`, and `sortedMinifiedText` (`:228`)
passes it. `src/MinifyEstimator.zig:153` passes the `reserved` it built at
`:130`.

**6. A public seam for the compiler's text.** `sortedMinifiedText` becomes
`pub fn minifiedText(arena, source, module, options)`, documented as the
exact bytes the BPE stage compresses and regenerates. The in-module
round-trip pin at `src/Compiler.zig:1724-1750` already proves that
`decodeBpe(compress(text)) == text`, so a test that proves `minifiedText`
correct proves the decoded wasm correct without a wasm runtime.

### Rejected alternatives

- **Walk the scope tree instead of the statements.** `Ast.Scope`
  (`src/Ast.zig:182-203`) reaches every declared symbol by construction,
  including the implicit `for` block, and would make change 1 unnecessary.
  But its members are a hash map, so the walk has to sort by `ScopeMember.loc`
  to be deterministic, and that assigns names in strict text order where the
  statement walk names an enclosing body before its nested bodies. Every
  scope-local and `compile` output with a nested block would change bytes.
  Not needed for correctness; possible later as a compression experiment.
- **Only fix the `for` arm.** Closes the report, leaves the `keep_names`,
  keyword and ceiling shapes open, and leaves the next missed position
  silent again.
- **Force the estimator's full mode under scope-local.** Correct, but the
  full mode also gzips the real text, and the cheap mode exists so the LSP
  can answer on every keystroke. Materialising a handful of global names is
  the cheaper repair.

### Behaviour changes, stated plainly

- **Output bytes change** for every scope-local or `compile` output whose
  functions contain a `for` initialiser declaration: the counter takes a
  canonical name, and every canonical name assigned after it in that
  function shifts by one. That includes the four corpus shaders above, which
  were correct by luck. No pinned golden is produced under these modes:
  `tests/snapshot_test.zig` keeps its goldens inline and never sets
  `scope_local_rename`, the Go, Rust and npm fixture sets contain no `for`
  initialiser, and the compile round-trip pin compares two live code paths,
  not stored bytes.
- **Output bytes change** for `--keep-names` with a pinned local, and for
  functions with 321 or more parameters and locals. Both were wrong.
- **Shaders that crashed now minify.** More than 256 reserved names in a row
  no longer reach `unreachable` in either generator.
- **LSP size estimates change** in cheap mode for documents using
  `scope_local_rename`, in the direction of the full mode's numbers.
- **`ScopeLocalRenamer.init` gains a parameter.** It is `pub` and reachable
  as `wgslender.Minifier.ScopeLocalRenamer`, so a Zig consumer calling it
  directly fails to compile until it passes a reserved set. No binding
  exposes it; the three in-tree callers are listed above.
- **`Compiler` gains a public function**, `minifiedText`. Additive.
- No option, flag, JSON key, C ABI or wire change.

## Plan

Four blocks. Each is self-contained: it says what to read, what to change,
and what proves it. Run tests from the repository root; the corpus tests read
goldens relative to it. The fast red/green check for one test file is

```
zig test --dep wgslender -Mroot=tests/collision_test.zig -Mwgslender=src/root.zig
```

and the gate is `zig build test -j1`, exit code only.

### Block 1: reds, in `tests/collision_test.zig`

Read `tests/collision_test.zig:1-142` first: `checkNoDuplicateNames`,
`expectMinifiesWithoutRedeclaration`, and the `rename_configs` table every
collision fixture runs against. Three of its five entries enable scope-local
naming (`scope-local-rename`, `sort+scope-local`, `all`).

1. **`expectBindingsPreserved(arena, source, options)`, the check that
   carries the proof.** Minify with `options` plus `minify_syntax = false`,
   `tree_shaking = false` and `sort_declarations = false`, parse the output,
   and compare the binding structure of source and output. Sorting is
   switched off because it changes declaration order and nothing else: the
   wrapper is built from the unsorted module and the sorted print reads the
   same renamer (`src/Pipeline.zig:264-275`, `src/Compiler.zig:228-245`), so
   proving the unsorted variant proves the names of the sorted one. With
   those three off the printer preserves every declaration and every
   reference in document order.

   The binding structure is a sequence built by one `wgslender.MultiVisitor.
   walk` (`src/lint/MultiVisitor.zig:51-60`, document order) run over each
   module. `on_decl` gives a function's parameters ordinals 0, 1, 2 and
   records the ordinals of the type names in its signature; `on_stmt` gives
   each declaration statement the next ordinal, including a `for`
   initialiser, and records the type name of a typed `let`/`var`; `on_expr`
   records every `.ident`. Each recorded reference becomes `local(ordinal)`
   when the symbol was declared in the current function, `global(index into
   module.declarations)` when it is a module-scope member
   (`module.scope.members`), and `other(name)` for builtins and unbound
   names. The two sequences must be equal. Print both around the first
   mismatch on failure. This is the test the counterexample in the review
   section fails and the count-based smoke test passes.
2. **`expectNoIntroducedShadowing(arena, source, options)`, kept as a smoke
   test only.** It validates source and output and fails if the number of
   `Diagnostic.Code.shadowing` diagnostics grew. Its doc comment must state
   why it is not a proof: the wrapper gives every local a fresh name, so it
   removes legitimate source shadows at the same time it introduces harmful
   ones, and the counts can cancel.
3. **`shadow_fixtures`**, a table of `{ name, source, keep_names }`, and one
   test that runs every fixture against every `rename_configs` entry through
   `expectMinifiesWithoutRedeclaration`, `expectBindingsPreserved` and the
   smoke test, printing fixture and config names on failure. Fixtures:
   - the report's shader;
   - the `let` initialiser;
   - the nested loops inside `if`;
   - the report's shader with `{ let x = 7; total += x; }` inserted before
     the loop, the shape whose warning count does not move;
   - the pinned local with `keep_names = &.{"a"}`;
   - a `loop`/`continuing`, `switch` and `while` shader that already prints
     correctly, pinning the shapes that must not regress;
   - a function with 340 locals built with a `comptime` loop
     (`@setEvalBranchQuota`), the keyword shape;
   - 300 used module-scope constants plus one function with a local, the
     wrapper's ceiling;
   - a small shader with `keep_names` set to the first 260 names of
     `numberToMinifiedName` (generated at `comptime` from the same head and
     tail alphabets), the base renamer's ceiling, which fails under every
     config in the table.
4. **Structural completeness.** Parse a shader with every declaration
   position, run the passes `Compiler.prepareRenamer` runs
   (`src/Compiler.zig:284-292`, through `wgslender.Pipeline`), build the
   wrapper, then walk `module.scope` recursively and assert three things:
   every `ScopeMember` of a non-module scope is pinned by the policy or
   present in `overrides`; the override names within one function are
   pairwise distinct; and no override name equals `base.nameForSymbol` of
   any symbol outside `overrides` (members excepted). This is the test that
   fails the next time a declaration position is added and not walked, and
   the test that would have failed on the reserved-set gap alone.
5. Call `expectBindingsPreserved` from the two existing `for
   (rename_configs)` tests at `tests/collision_test.zig:316` and `:403`.

Expected reds before Block 2: fixtures 1 through 5 and 7 fail
`expectBindingsPreserved` under the three scope-local configs (7 fails to
parse first); fixture 8 panics under those configs; fixture 9 panics under
every config; the structural test fails on the `for` counter. Fixture 6 and
everything existing stay green. A panic is a red, but it takes the test
binary down with it, so run fixtures 8 and 9 last or under a `skip` toggle
until Block 2 lands, and remove the toggle in the same commit as the fix.

Commit: `test(collision): pin renamer-introduced shadowing and the reserved-name ceilings`.

### Block 2: the wrapper and the two ceilings

Read `src/Minifier.zig:429-571`, `src/Renamer.zig:255-313` and the three call
sites. Then:

1. Restructure `init` into `collect`, `reserve` and `name` as described under
   Design, with the new `reserved` parameter, the `for` initialiser arm, and
   the reserved-set termination bound in `allocCanonicalName`.
2. Change the bound in `skipReservedNames` the same way and fix its doc
   comment, which currently argues from the keyword count.
3. Add a unit test beside `ScopeLocalRenamer` in `src/Minifier.zig` that runs
   `collect` on a small module, removes one local from the candidate list by
   hand, runs `reserve` and `name`, and asserts that the removed local's base
   name is in the reserved set and equals no override. That is the proof of
   the fallback guarantee, and it cannot be written from the public API
   because nothing public misses a declaration.
4. Replace the doc comment on `ScopeLocalRenamer` with the invariant in one
   paragraph: what the two name sets are, why members are excluded, and that
   a missed declaration keeps its base name safely.
5. Update `src/Pipeline.zig:265`, `src/Compiler.zig` (`RenamerPrep`,
   `prepareRenamer`, `sortedMinifiedText`) and `src/MinifyEstimator.zig:153`
   to pass the reserved set.
6. Run the single-file check: every Block 1 test green, ceiling toggles
   removed. Run `zig build test -j1`; expect exit 0 and no golden drift (the
   validator path does not import the minifier, so the Tint goldens cannot
   move). `tests/determinism_test.zig` and `tests/oom_test.zig` already cover
   the scope-local path and must stay green.

Commit: `fix(minifier): name for-init declarations, reserve every bypassing
name, and bound both name generators by the reserved set`, with `Fixes #2`
in the body.

### Block 3: the compiler seam and the estimator

Read `src/Compiler.zig:215-297` and `src/MinifyEstimator.zig:91-180` and
`:283-372`.

1. Rename `sortedMinifiedText` to `pub fn minifiedText` with the doc comment
   from Design item 6. Additive, so no red is possible before it exists.
2. Reds in a new `tests/compile_text_test.zig` (register it in `build.zig`
   through `hasFile` like its neighbours): call `Compiler.minifiedText` for
   the report's shader, the `keep_names` fixture and the counter-named-`a`
   shader under `.minify = true` and under `.minify = false`, and assert each
   result through `expectBindingsPreserved` against the source and through a
   clean `validate`. Move `expectBindingsPreserved` into a shared helper
   file (`tests/bindings_preserved.zig`, alongside `tests/parse_ok.zig`) so
   both suites import it. Expect the `.minify = false` cases red until the
   wrapper fix from Block 2 is on the branch, and green after it; the seam
   itself needs no further change.
3. Reds in `tests/minify_estimator_test.zig`: the 10-globals, 52-locals
   shader under `scope_local_rename`, asserting `total_min` equal to the real
   minifier's byte count in cheap mode and in full mode. Cheap is red at 978
   against 998.
4. Implement Design item 4 in `MinifyEstimator`: keep the sequence index per
   symbol in `buildLengthRenamer`, materialise names for module-scope and
   pinned symbols, answer placeholders for the rest. Green.
5. One end-to-end assertion in the npm suite: compile the report's shader,
   instantiate the wasm, run `generate()`, and assert the decoded text
   validates with zero diagnostics. This is the only test that executes the
   generated module, and it runs against the rebuilt wasm from Block 4, so
   write it here and expect it green only after Block 4 step 1.

Commits: `feat(compiler): expose the text the BPE stage compresses`,
`fix(estimator): reserve real global names in the cheap path under
scope-local rename`, `test(compile): pin decoded-text bindings in both
naming modes`.

### Block 4: artefacts, proof, changelog

1. `zig build release-assets`, then commit the five copies as `build(wasm):
   rebuild every artefact for the scope-local rename fix`. The rebuild is
   required by the release rule in `CLAUDE.md`; `tests/wasm_freshness_test.
   zig` cannot detect a stale binary within a version (its own header says
   so), and the only automatic gate is `release.sh`'s `git diff --exit-code`.
2. Prove it where the reporter saw it: `cd packages/js-npm && npm test`
   (which now includes the decoded-text assertion), then the report's
   `minify()` call through `lib/main.js`, expecting a `validate()` with zero
   diagnostics. Rerun the corpus measurement with each config in its own
   quoted argument list (the interactive shell here is zsh, which does not
   split an unquoted variable) and expect zero shaders gaining a shadow
   under every config, the two-flag one included. `cargo xtask check` for
   Rust, since it links the static library, and the Go package tests, since
   they embed the wasm.
3. `CHANGELOG.md`: a `## [Unreleased]` section with a `### Fixed` entry that
   names the four shapes and the two ceilings, says that scope-local and
   `compile` output bytes change for shaders with a `for` initialiser, notes
   the cheap estimator change, and credits the reporter. `README.md` needs
   no change; the `--scope-local-rename` row at line 76 still describes the
   flag.
4. Reply on issue #2 (draft below) once the fix is on `main`, and cut 1.5.1
   with `./scripts/release.sh` as a separate step.

Commit: `docs(changelog): record the scope-local rename fix`.

### Effort

Block 1 about forty minutes, most of it the binding walk. Block 2 about
forty. Block 3 about forty. Block 4 about an hour of mostly waiting on the
full suite and the binding suites.

## Not in this plan

- The binder bug for locals named after a module-scope alias, struct or
  function (`src/AstVisit.zig:370` and the initialiser's visibility of its
  own declaration). Its own plan; `expectBindingsPreserved` is the gate to
  reuse, and the six skipped Tint fixtures are its corpus.
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
> compares the binding structure of source and output, which is the check
> that should have caught this. Note that scope-local and `compile` output
> bytes change for shaders with a `for` initialiser, since the counter now
> takes a canonical name. Thank you for the precise report.

---

# Review, 2026-09-29

A review of the first draft of this plan reported four gaps and two
corrections. Every claim was re-run against `38f38a0` before the plan was
changed; all of them hold. What each one changed is recorded here, so the
first draft's reasoning stays visible.

**The fixed 256-iteration ceilings crash on valid input.** Reproduced both
ways: 300 used globals panic the wrapper at `src/Minifier.zig:499`, and 260
kept generated names panic the base renamer at `src/Renamer.zig:270` with
scope-local naming off. The first draft said the ceiling "stays" and argued
from the keyword count; the reserved set also holds every global's name and
every pin, which the language does not bound. Now Design item 3, the
"Two crashes" section above, fixtures 8 and 9, and Block 2 step 2.

**A warning count cannot prove that bindings survived.** Reproduced with the
report's shader plus `{ let x = 7; total += x; }` before the loop: one
`W0100` in source, one in output, and the output still reads the counter
where it meant `base`. The wrapper removes legitimate shadows while adding
harmful ones, so the counts cancel. The count helper is demoted to a smoke
test and `expectBindingsPreserved` (Block 1 item 1) carries the proof. The
structural test also gained the uniqueness and disjointness assertions the
review asked for.

**The estimator's cheap mode needs a real repair.** Reproduced with my own
shader: cheap 978, full 998, minifier 998. The first draft's table said the
estimator produced "wrong names, right lengths", which is false when the
wrapper reserves placeholders instead of names. Now the estimator paragraph
under "Where it ships", Design item 4, Block 3 steps 3 and 4, and a
behaviour-change line.

**The compiler needs its own regressions, including the no-op base.**
Reproduced by decoding the wasm: default `compile` and `compile --no-mangle`
both alias the parameter and the counter. The first draft's coverage leaned
on the compile round-trip pin, which compares two paths that share the
wrapper and so cannot establish correctness on its own. Now Design item 6,
Block 3 steps 1, 2 and 5, and the fallback-guarantee unit test in Block 2
step 3, which the review also asked for.

**A separate binder bug is out of scope and now stated as a boundary.** The
alias/local reproduction was run under the default renamer and produces
invalid output as described. Now "A neighbouring bug this plan does not fix"
and the first item under "Not in this plan".

**Two corrections.** `tests/wasm_freshness_test.zig` cannot detect a stale
binary within a version, so the first draft's claim that it "fails until the
five copies are rebuilt" was wrong; Block 4 step 1 now cites the release
rule instead. `rename_configs` has three scope-local entries, not two; the
expected-reds paragraph says so.

The review also ran the existing collision suite and found all four tests
passing, which is the expected state before Block 1: nothing in the suite
observes a warning or a binding.

---

# Execution, 2026-09-29

All four blocks were executed against this plan the same day and shipped in
1.5.1. Everything below is a correction the execution turned up, recorded so
the plan's reasoning above stays readable as written.

**Design item 6's premise is false.** There is no in-tree
`decodeBpe(compress(text)) == text` pin at `src/Compiler.zig:1724-1750`: those
lines are the tail of an op-decode assertion plus the
sorted-print-vs-minifier pin, and the round-trip tests at `:1954+` are
`compileAndVerifyRoundTrip` over `decodeOps`. The consequence is the opposite
of what the item assumed — the npm decoded-text assertion added in Block 3 is
the *only* end-to-end proof that executes the generated module, and no
changelog entry may claim an in-tree BPE round trip. The committed doc comment
states the real chain.

**The 978/998 estimator fixture is not in the repo.** The reconstruction reds
at `1061` against `1081` — the same 20-byte undercount, so the mechanism is
confirmed even though the plan's absolute bytes are not reproducible. Compare
the delta, not the absolute number.

**Fixture 9 as written was vacuous.** With `fn f(x: i32)`, both names fall in
the first 260 generated names, so both were pinned, no slots were allocated,
and the ceiling was never walked: it passed for the wrong reason. The committed
fixture uses `fn foo(bar: i32) -> i32 { return bar + 1; }`, which does reach
the ceiling.

**"Five copies" is three tracked paths.** `npm/wgslender-vscode/dist/*.wasm` is
gitignored (`npm/wgslender-vscode/.gitignore`), so an artefact commit lists
three files, matching every historical `build(wasm)` commit; all five
destinations are still rebuilt. Related: the gate's `1 skipped` becomes `0
skipped` once those gitignored copies exist and
`tests/wasm_freshness_test.zig`'s LSP copy-equality check has two copies to
compare.

**Block 5: a follow-up the plan did not call for.** Block 2's fix introduced
`src/Pipeline.zig:265`'s `if (state.reserved) |*r| r else return;`, a *new*
silent no-output path — pre-fix, `runPrint` called `ScopeLocalRenamer.init`
unconditionally. It is unreachable in-tree (every built-in pass list with
`.print` also has `.build_reserved_names`), but reachable through the public
composable pipeline, and quietly printing nothing is worse than loudly printing
the wrong bytes. `75a7457` derives the reserved set and the renamer on demand
instead. Note what the fix had to get right: deriving only the reserved set is
not enough, because `runBuildRenamer`'s own `reserved orelse return` leaves
`state.renamer` null and `runPrint` then returns at its pre-existing
`renamer_base orelse return` — a fix whose guard sits behind another early
return cannot reach the failure path it claims to close.

**Two ceilings, not one, and not a fixed count.** Both generators are bounded
by `reserved.count() + 1` rather than 256, because the ceiling trips when that
many reserved names cover the head of the sequence, which 300 used globals do
and 260 pins do — the plan's "300 module-scope constants plus a local" is a
simplification of the same thing.

**Stale line numbers.** The `tests/collision_test.zig` references drift
(helper at 102 not 107, the `for (rename_configs)` loops at 388/422 not
316/403). Cosmetic.

**Gates that could not be run here.** `cargo`, `go` and `rustc` are absent from
both machines, so `cargo xtask check` and the Go package tests were reported as
gaps rather than run.

The evidence, per block: the cold-cache suite (`305/305 steps succeeded;
4421/4421 tests passed`), the anti-vacuity runs for both the estimator
(`expected 1081, found 1061` with the parent revision restored) and the
pipeline test, the npm suite (`193 passed, 0 failed` in all four variants with
the decoded-text assertion green), the corpus sweep (**0 of 324** shaders gain
a shadow under each of five configs, down from 4 of 324), and a from-scratch
`release-assets` rebuild leaving every destination byte-identical with
`git status` clean.
