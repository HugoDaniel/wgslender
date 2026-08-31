# 01 — W1: reflection reports every function's name and none of its type

**Ask:** animader plans `plans/animader/02-domains.md` ("Checking a kernel")
and `plans/animader/03-vocabulary.md` ("The kernel register"), priority
**Low** (nothing is blocked; a workaround exists and is described below),
filed 2026-08-31 by **animader** (a host). Evidence read against this tree at
`aa76395` on 2026-08-31, working tree clean. The verdict, the design and the
plan are wgslender's to write, at the end of this file.

## The claim

`Reflect.FunctionInfo` describes a user-defined `fn` by everything except what
it is. `src/Reflect.zig:353`, doc comments elided:

```zig
pub const FunctionInfo = struct {
    name: []const u8,
    name_mapped: []const u8 = "",
    name_offset: u32 = 0,
    stable_id: []const u8 = "",
    decl_span: SpanInfo = .{},
    calls: std.ArrayList([]const u8) = .empty,
    direct_resources: std.ArrayList([]const u8) = .empty,
    direct_overrides: std.ArrayList([]const u8) = .empty,
    in_use: bool = false,
};
```

Nine fields: an identity, a location, a call graph, a resource graph, a
liveness flag. No parameter types and no return type. `docs/reflect.md:92`
describes the field the same way, and it is accurate: "Every user-defined
`fn`, with direct resource refs, direct override refs, outgoing call edges,
and transitive `in_use` flag."

The asymmetry is the load-bearing part of this ask. An **entry point** does
carry its I/O. `src/Reflect.zig:290` gives `EntryPointInfo` an `inputs` and an
`outputs`, each a list of `InputOutputInfo` flattened per `@location(N)` and
`@builtin(name)` (`src/Reflect.zig:308-314`). So the reflection report already
answers "what does this function take and return" for the one kind of function
whose answer the WGSL spec pins with attributes, and declines to answer it for
the kind whose answer is written in plain sight in the declaration.

The information is not missing from the library. It is computed, twice.

- **The validator resolves it.** `src/Types.zig:767`:
  `pub const Function = struct { parameters: []const Type, return_type: ?Type }`.
  `Validator.AnalysisResult` carries `symbol_types`, a `SymbolIndex` to
  resolved type map, "Populated for every declared symbol that survived
  inference" (`src/Validator.zig:207-209`).
- **The language server renders it.** `lsp/handler/hover.zig:241`,
  `formatFunctionSignature`, takes a `*const Types.Function` and prints the
  signature; `lsp/handler/signature_help.zig` calls it and its own comment says
  the AST fallback is "Only reached when the validator produced no
  `Types.Function` for the callee — otherwise the resolved rendering wins"
  (`lsp/handler/signature_help.zig:19-21`).

So a person hovering a kernel in VS Code is shown exactly the fact that the
reflection JSON for that same file does not contain.

The structural reason is visible in the pipeline and it is not an oversight.
`reflect()` is Lexer, Parser, Reflect (`src/root.zig:309-325`), and
`docs/reflect.md:20` states the contract: "Reflection runs after parsing and
never mutates the AST." Resolved types come from the validator, which
reflection does not run. That is a real design decision and this ask does not
assume it should be reversed; see "What the cheapest answer covers".

## The shape that hits it

animader's kernel is a WGSL function with a declared class, and the class is
the whole type system on that side of the tool. From
`plans/animader/02-domains.md`:

```
(kernel :name simplex :class field1
  :params [(scale :default 4) (speed :default 0.2)]
  :code """
    fn simplex(p: vec2f) -> f32 { … }
  """)
```

`:class field1` means `fn(vec2f) -> f32`. Everything downstream believes it:
the schema types `warp`'s `:by` as a cross-reference to a `field2` kernel, so
passing a `field1` there is a diagnostic with a span; the hole menu offers
`shade ∘ field1` as one row naming two kernels; `09-holes.md` gives seven
identity kernels one per class, and an identity kernel that is not the identity
of its position changes the picture in every piece being typed. All of that is
composition checking over a **label**, and until the label is checked against
the function, the checking is theatre.

The check animader needs is one comparison per kernel at load, once, on a
document that already parsed:

```
declared :class field1   ⇒   expect fn(vec2f) -> f32
reflected signature      ⇒   fn(vec2f) -> vec2f
                             kernel_class_mismatch, span at the fragment
```

Four of the five classes are a two-line comparison against a spelling the AST
already holds. The fifth, `step`, is `fn(ptr<function, Element>, f32)`.

## Why nobody hit it before

Every documented consumer of reflection is a host allocating GPU resources.
`docs/why-reflect-wgsl.md` and the format doc both frame it that way: bindings,
struct layouts, entry points, "ready to drive bind-group creation". A host
building bind groups needs the entry points, the bindings and the layouts, and
it needs `functions` only for the call graph and the liveness flag, which is
exactly the nine fields that exist.

animader is the first consumer whose unit is a function that is not an entry
point. Its kernels have no `@vertex`, `@fragment` or `@compute` and no
`@group`/`@binding`, on purpose: they are fragments concatenated into a PNGine
pass whose prelude owns group 0. They are, in wgslender's own terms, the only
declarations in a module that reflection sees, describes by name, and cannot
type.

That is the honest summary of the gap: **an entry point's signature is
reflected because attributes name it, and an ordinary function's is not,
although the validator resolves it and the language server prints it.**

## Reproduction

Against `aa76395`:

```
$ printf 'fn simplex(p: vec2f) -> f32 { return p.x + p.y; }\n' > k.wgsl
$ wgslender validate k.wgsl
valid
$ wgslender reflect k.wgsl
```

```json
{
  "version": 2,
  "bindings": [], "uniforms": [], "storage": [], "textures": [], "samplers": [],
  "structs": {}, "entryPoints": [], "overrides": [],
  "functions": [
    { "name": "simplex", "nameOffset": 3,
      "declSpan": { "start": 0, "end": 49 },
      "inUse": false, "calls": [], "directResources": [], "directOverrides": [] }
  ],
  "aliases": []
}
```

Two things in that output are worth stating plainly, because both are good
news and only the second is a gap. The fragment validates with no entry point,
which is the property animader adopted wgslender for. And `simplex` is
reported with its span, its stable id and its call graph, and the two facts a
caller wants (`vec2f` in, `f32` out) are the two the report leaves out, sitting
untouched at `k.wgsl:0-49`.

**The workaround, which works and is what ships without this ask.** Append one
line per kernel to the assembled module and read the diagnostic:

```
$ printf 'fn simplex(p: vec2f) -> f32 { return p.x + p.y; }\nfn _c() { let _: f32 = simplex(vec2f(0)); }\n' > probe.wgsl
$ wgslender validate probe.wgsl
valid
```

and with the class wrong, `E0200` names the mismatch. It is correct, it costs
one validate call that was going to happen anyway, and it is ugly: the probe
line is generated text appended to a user's shader, the diagnostic it produces
is phrased about the probe rather than about the kernel, and the offset
arithmetic to blame the right bytes is animader's to get right.

**The other route, and why it is not the answer.** A Zig host can reach the
resolved type today without this ask: call `analyze` (`src/root.zig:224`),
walk `module.declarations` for the function, and look its symbol index up in
`AnalysisResult.symbol_types` (`src/Validator.zig:209`), which is what
`signature_help.zig` does. That works, and animader is a Zig package, so it is
available. It is not proposed as the fix for three reasons: it is the language
server's internal path rather than a documented contract, so it can move
without a version bump; it is keyed on symbol indices rather than names, so a
caller reimplements the declaration walk the reflection report exists to spare
it; and it is Zig-only, while the reflection report is the surface the CLI,
wasm, npm, C, Rust and Go bindings all share. animader's corpus gate is Zig and
its editor pane is the browser LSP, so a fact available on only one of those is
a fact it has to compute twice.

## What the cheapest answer covers

The AST alone can spell four of the five classes, which is worth knowing
before anything is designed, because it means an answer inside the existing
Lexer, Parser, Reflect pipeline is possible and does not require reflection to
start running the validator.

| Class | Signature | What `Ast.Type` spells |
|---|---|---|
| `field1` | `fn(vec2f) -> f32` | `.vec` shorthand and `.ident`, exact |
| `field2` | `fn(vec2f) -> vec2f` | exact |
| `field4` | `fn(vec2f) -> vec4f` | exact |
| `shade` | `fn(f32) -> vec4f` | exact |
| `step` | `fn(ptr<function, Element>, f32)` | the pointer renders as `"?"` |

`lsp/handler/signature_help.zig:22-29`, `astTypeString`, is where that
limitation is already written down: `.ident`, `.vec` and `.mat` render, and
everything else is `"?"`. So a reflection field carrying the source spelling
of each parameter type and the return type, with no resolution, would answer
four of animader's five classes exactly and blur the one whose kernel does not
exist yet. animader would take that outcome and record which class it does not
cover.

A resolved answer, if reflection ever gains a validated variant (a
`reflectWithAnalysis`, or a flag), would cover the fifth and would also serve
the residency reading described below. That is a larger change and this ask
does not argue for it.

Two smaller notes on shape, offered as constraints rather than as a design.
Whatever field is added should be present for the same population `functions`
already covers, including functions with `in_use: false`, since an animader
kernel is not called from any entry point in the fragment it is authored in.
And it should reach JSON v2 through `src/reflect/Json.zig:327`,
`writeFunctionJson`, which is where the other eight fields are written and
where a ninth costs four lines.

## Where it would live

`src/Reflect.zig:353` is the struct, `src/reflect/Json.zig:327` is the v2
writer, and `docs/reflect.md:92` is the sentence that describes the field.
`src/root.zig:309` is the entry point whose pipeline decides whether resolved
or AST-spelled types are reachable.

Whether the answer is a `params`/`returns` pair of source spellings on
`FunctionInfo`, a single pre-rendered `signature` string of the kind
`formatFunctionSignature` already produces, a validated reflection variant, a
decision that `analyze` plus `symbol_types` is the supported route and should
be documented as one, or a decision that reflection is for resource binding and
a host wanting types should use the probe, is wgslender's call.

The last two are legitimate outcomes and animader would take either. "Use
`analyze`, here is the doc line that should have said so" closes this ask
completely for a Zig host and leaves the npm and wasm surfaces where they are,
which animader can live with because its gate is Zig. "Reflection is for
binding, probe for types" is also actionable, and animader would write the
probe path into `02-domains.md` as the permanent mechanism rather than as an
interim one. Only the current silence costs anything, because it reads as an
oversight and invites a host to keep waiting for a field that was never going
to come.

## Cost of not closing it

Small and specific, which is why this is filed at Low.

animader ships the probe. Every kernel check appends a generated line to a
user's shader, and a diagnostic phrased about that line has to be re-blamed
onto the kernel's own bytes before an author sees it. That is offset arithmetic
on top of the offset arithmetic the assembled module already needs, and the
second layer exists only because a fact the library computed was not reported.

The structural cost is the one worth weighing. animader has just written
wgslender into eight of its plan files as the instrument for the WGSL half of
its constitution, and the first thing it does with it is bypass the reflection
report for the one question its own type system asks. If reflection is the
contract, this is a hole in it. If reflection is for resource binding and the
type layer belongs to `analyze`, that is a clean boundary and animader would
rather be told where it is than infer it from a struct.

---

# Verdict

**Accepted, with a smaller design than the ask proposes.** Decided 2026-08-31
by wgslender, read against `aa76395`, working tree clean.

`FunctionInfo` gains `params` and `return_type`, spelled from the AST, in JSON
v2 only. Reflection keeps its pipeline position: no validator, no
`reflectWithAnalysis`, no resolved types. That covers all five of animader's
classes exactly, including `step`, which the ask expected to lose.

## Two corrections to the filing

The evidence in the ask re-validates line for line, except in two places, and
the second one changes the design.

**The workaround as filed does not validate.** Ask lines 156 to 161 claim
`wgslender validate probe.wgsl` prints `valid`. It prints:

```
probe.wgsl:2:15: error: identifier '_' is reserved: it may only appear as the
  left-hand side of a phony assignment [E0105]
invalid                                                            (exit 1)
```

`let _: f32 = …` puts `_` in a declaration-name position, where
`Declarations.checkReservedIdentifiers` reports E0105 by design. The
class-mismatch case does produce E0200 as claimed, but always alongside that
same E0105, and the exit code is 1 either way, so the probe cannot distinguish
a matching class from a mismatched one. Binding a real name works:

```
fn _c() { let probe: f32 = simplex(vec2f(0)); _ = probe; }   → valid
```

Worth stating because the ask is filed at **Low** on the strength of a
workaround that ships, and the workaround as written does not.

**`step` is exactly spellable from the AST.** Ask lines 190 to 204 conclude
that `ptr<function, Element>` renders as `"?"`, generalising from
`lsp/handler/signature_help.zig:22-29`. That function is a seven-line fallback
reached only when the validator produced nothing, and its own doc comment says
so. Reflection has its own type renderer,
`LayoutComputer.typeToStringMapped` at `src/reflect/Layout.zig:999`, which
already fills `BindingInfo.typ` and `AliasInfo.typ` and covers all eight
`Ast.Type` variants:

```zig
.ptr => |p| {
    const elem_str = self.typeToStringMapped(p.elem_type, mapped);
    return self.fmtAlloc("ptr<{s}, {s}>", .{ p.address_space.string(), elem_str });
},
```

`buildTypeInfo` has a matching `.ptr` arm at `src/reflect/Layout.zig:352`, and
`Ast.Type.span()` (`src/Ast.zig:785`) gives the exact source bytes of any type
as a third route. So the AST-only answer covers five classes out of five, and
the argument for a validated reflection variant in ask lines 206 to 209 does
not arise.

## A third finding, from this tree rather than from the ask

`docs/reflect.md:157-163` already promises what the ask asks for:

> `OverrideInfo` / `AliasInfo` / `FunctionInfo`
> Each surfaces names, source offsets, stable IDs, declaration spans, types
> (both source-spelled and structured `TypeInfo`) …

`FunctionInfo` surfaces no types at all. The row the ask cited at
`docs/reflect.md:92` is accurate, and this paragraph fourteen lines further
down is not. That reclassifies the filing: it is a divergence between the
documented contract and the code, not a feature request against a contract
that held. It is the reason this is accepted rather than answered with "use
`analyze`".

## Design

Reflection already walks every `FunctionDecl` and already spells every type it
reports. `CallGraph.buildCallGraph` at `src/reflect/CallGraph.zig:51` holds
`fn_decl`, whose `parameters` and `return_type` (`src/Ast.zig:645-646`) sit
unread beside the fields it does record, and the `LayoutComputer` that would
spell them is live at the call site (`src/Reflect.zig:474` declares `lc`,
line 601 calls `buildCallGraph`). The change is to pass one and read the
other two.

### New type

```zig
/// One declared parameter of a user-defined `fn`, in declaration order.
/// Types are spelled from the AST, so they carry the source form
/// (`"vec2f"`, not `"vec2<f32>"`) and never depend on the validator.
pub const ParamInfo = struct {
    name: []const u8,
    name_mapped: []const u8 = "",
    typ: []const u8 = "",
    type_mapped: []const u8 = "",
    type_info: ?*const TypeInfo = null,
};
```

Field set and naming copy `AliasInfo`, which is the closest existing record: a
name plus one type in three renderings.

### `FunctionInfo` additions

```zig
/// One entry per declared parameter, in declaration order. Present for
/// every function including entry points, whose attributed pipeline I/O
/// stays in `EntryPointInfo.inputs` / `.outputs`.
params: std.ArrayList(ParamInfo) = .empty,
/// Return type spelled as in source. Empty when the declaration has no
/// `-> T` clause.
return_type: []const u8 = "",
return_type_mapped: []const u8 = "",
return_type_info: ?*const TypeInfo = null,
```

### JSON

`writeFunctionJson` (`src/reflect/Json.zig:327`) takes a `version` parameter
and emits the new keys under v2 only. `functions[]` is written in both
versions (`src/reflect/Json.zig:80`, outside the v2 guards), and v1 is the
wgsl_reflect-parity shape, so v1 output stays byte-identical.

```json
{ "name": "simplex", "nameOffset": 3,
  "declSpan": { "start": 0, "end": 49 },
  "inUse": false, "calls": [], "directResources": [], "directOverrides": [],
  "params": [ { "name": "p", "typ": "vec2f", "typeInfo": { … } } ],
  "returnType": "f32" }
```

`"params"` is always present in v2, empty array for a nullary function.
`"returnType"` is `null` for a function with no return, following the
`"id": null` and `"workgroupSize": null` precedent in the same file.
`nameMapped` / `typeMapped` are omitted when equal to their unmapped form, the
rule `writeFunctionJson` already applies to `nameMapped`.

### Invariants

Two hold by construction and go in `docs/reflect.md`'s invariant list:

- `functions[i].params.len` equals the declared parameter count, in
  declaration order, for every function including entry points and including
  `in_use == false`.
- Without a renamer, `name_mapped == name` and `type_mapped == typ`, which
  the existing invariant already states and which `getMappedName`
  (`src/reflect/Layout.zig:983`) delivers by falling back to `getSymbolName`.

### What this does not do

Reflection still never runs the validator, so the types it reports are what
the author wrote, not what inference resolved. An alias chain resolves,
because `typeToStringMapped` follows `Symbol.kind == .alias`, but nothing
else does: an unresolvable type name is reported as written, and no diagnostic
is produced. A host that needs resolved types keeps using `analyze` plus
`symbol_types`.

For animader that boundary is: **reflection answers what a kernel's signature
says, and `validate` answers whether it is true.** Class checking wants the
first, which is a string comparison against `params[].typ` and `returnType`
with no probe and no offset arithmetic.

## Plan

Seven steps, one commit each, roughly two hours including the downstream
mirrors.

1. **Red.** Add cases to `tests/reflect_test.zig` asserting `params` and
   `return_type` on: a nullary void `fn`, `fn simplex(p: vec2f) -> f32`, a
   `ptr<function, T>` parameter, a struct-typed parameter, and an entry point
   (which must carry both its `params` and its existing `EntryPointInfo`
   I/O). Table-driven over `{ source, expected params, expected return }`.
   Confirm they fail.

2. **Green.** Add `ParamInfo` and the four `FunctionInfo` fields to
   `src/Reflect.zig`. Give `CallGraph.buildCallGraph` an `lc:
   *LayoutComputer` parameter, populate from `fn_decl.parameters` and
   `fn_decl.return_type`, and pass `&lc` at `src/Reflect.zig:601`.

3. **JSON.** Thread `version` into `writeFunctionJson`, emit the new keys
   under v2. Pin v1 byte-identity with a test that reflects a function-heavy
   fixture at v1 before and after.

4. **Docs.** Fix the false paragraph at `docs/reflect.md:157-163`, extend the
   `functions` row at `:92`, add the two invariants, and list `params` /
   `returnType` under "v2 adds" at `:242`.

5. **Bindings.** Mirror the fields in `packages/js-npm/lib/main.d.ts:352` and
   `packages/go/wgslender/types.go:588`. Rust returns raw JSON and needs no
   change beyond a test case.

6. **Assets.** `zig build release-assets` for the wasm surfaces, then
   `zig build test` to satisfy `tests/wasm_freshness_test.zig`. Build cli,
   wasm, lsp and lsp-wasm.

7. **Verify.** Full `zig build test -j1`, plus the reproduction from this ask
   re-run to show `params` and `returnType` in the output.

## Note to the host

The workaround in "Cost of not closing it" can be dropped rather than fixed.
Once step 3 lands, a kernel's class check is a comparison against two strings
in the reflection report the loader already reads, and no generated line is
appended to anybody's shader.

---

# Executed

**Landed 2026-08-31**, seven commits on `main` (`a2fb8b3` red, `96238a4`
green, `0b12fa8` JSON, `b2500dc` docs, `8e0ba2a` bindings, `7003882`
assets). The design above is what shipped; three details differ and are
recorded here rather than rewritten above.

**The JSON key for a parameter's type is `"type"`, not `"typ"`.** The
design sketch at "### JSON" wrote `"typ"`, which is the Zig field name.
Every other writer in `src/reflect/Json.zig` spells the key `"type"` —
`writeFieldInfoJson`, `writeAliasJson`, `writeInputOutputJson` — so
`writeParamJson` does too. `"returnType"` is unaffected.

**`returnTypeMapped` and `returnTypeInfo` reach the JSON as well**, on the
same omit-when-equal rule as `nameMapped`. The design listed them on the
struct and showed only `"returnType"` in the sketch; there was no reason
to make the return type less legible than a parameter.

**`FunctionInfo.stable_id` and `.name_mapped` were never populated.**
Both fields existed and both had been dead since `functions[]` was added:
`buildCallGraph` set `name`, `name_offset` and `decl_span` only. Filed
here as out of scope, then fixed on the same day at wgslender's own call
(`a312bd8` red, `d0b6277` green, `8a6b4d2` assets) — see the note below.

## Verification

- `tests/reflect_test.zig` — 121/121, including six signature shapes
  (nullary void, `fn(vec2f) -> f32`, `ptr<function, Element>`, a struct
  parameter, an entry point, and a long-form `vec2<f32>` spelling that
  survives verbatim), the unreached-function pin, and a byte pin on v1's
  `functions[]`.
- `zig build test -j1` — 4683/4684. The one crash,
  `tint_test.test.tint: semantic preservation`, is a SIGKILL that
  reproduces identically at `68dab58` with this work checked out, so it
  is not from this change. Both corpus goldens are unchanged.
- `go test ./wgslender/`, `npm test` (187 across all four wrappers), and
  a new raw-envelope case in `packages/rust/wgslender-core/tests/reflect.rs`.
- The reproduction at the top of this file, re-run:

```json
"functions": [
  { "name": "simplex", "nameOffset": 3,
    "declSpan": { "start": 0, "end": 49 },
    "inUse": false, "calls": [], "directResources": [], "directOverrides": [],
    "params": [ { "name": "p", "type": "vec2f", "typeInfo": { … } } ],
    "returnType": "f32", "returnTypeInfo": { … } }
]
```

## To the host

All five kernel classes are now a string comparison against
`params[].type` and `returnType`, on a document the loader already
reflects. `step` included: `ptr<function, Element>` is spelled whole.
Drop the probe rather than fixing it — and note that the probe as filed
never worked, for the E0105 reason in the verdict above.

---

# Follow-up, 2026-08-31: the two dead fields, and one v1 wire change

`FunctionInfo.stable_id` and `.name_mapped` are now populated. Filling
them was a two-line change once `buildCallGraph` already held the
`LayoutComputer`, and it removes a real hole rather than a cosmetic one:
a function that is not an entry point has no other record, so until now
there was no way to name one across a reparse. For a function that is an
entry point, the id here and the id in `entry_points[]` agree.

**This changes v1 output.** `functions[]` entries now carry `stableId` in
both schema versions. That is additive and it is what the writer always
intended — v1 already emitted `stableId` for bindings, struct fields and
entry points, and the `if (f.stable_id.len > 0)` branch sat outside every
version guard; `functions[]` lacked the key only because the field was
empty. Both the Go and the TypeScript types already declared it optional,
so no consumer breaks. The v1 byte pin in `tests/reflect_test.zig` was
updated to the new bytes rather than the key being gated to v2.

`nameMapped` on a function is now omitted when it equals `name`, matching
the contract `packages/js-npm/lib/main.d.ts` already stated ("absent when
no renamer was applied") and what the new `params[]` writer does. A
reflection with no renamer behind it therefore has no `nameMapped`
anywhere in `functions[]`, and v1 is otherwise byte-for-byte as before.

Re-verified: `tests/reflect_test.zig` 124/124; `zig build test -j1`
4686/4687 with the same pre-existing `tint: semantic preservation`
SIGKILL and no golden drift; full Go package and 187 npm assertions
across all four wrappers against rebuilt wasm.

For a host, the practical gain is that a kernel now has a durable name.
`stableId` survives a reparse where `nameOffset` and `declSpan` do not,
so a diagnostic attached to a kernel can outlive an edit above it.
