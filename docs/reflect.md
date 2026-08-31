# WGSL Reflection

Reflection extracts structured metadata from a parsed WGSL module — bindings,
struct memory layouts, entry points, override constants, type aliases, and the
function call graph — without modifying the source. It is the bridge between a
shader's text and the host code that has to allocate buffers, build bind-group
layouts, and dispatch pipelines for it.

The module lives in `src/Reflect.zig` and is exposed both as a Zig API and via
the CLI / WASM / npm package.

## Pipeline position

```
Source ─► Lexer ─► Parser ─► AST ─► Reflect ─► ReflectResult
                                       │
                                       └─► (optional) Renamer for post-mangle names
```

Reflection runs after parsing and never mutates the AST. It can optionally read
a `Printer.Renamer` to populate `*_mapped` fields with post-minification names,
which is what makes `minifyAndReflect()` possible in a single pass.

## Inputs

### Zig API

```zig
pub fn reflect(arena: Allocator, module: *Ast.Module) !ReflectResult;

pub fn reflectWithRenamer(
    arena: Allocator,
    module: *Ast.Module,
    renamer: ?*const Printer.Renamer,
) !ReflectResult;
```

| Input | Meaning |
|---|---|
| `arena` | Allocator backing every slice/list inside the result. An arena is required so callers can free the entire report with one `deinit`. |
| `module` | A `*Ast.Module` produced by the parser. Its scope tree must be rooted (`module.scope.parent == null`) and `module.symbols.items.len <= maxInt(u32)`. Both are asserted. |
| `renamer` | Optional. When non-null, `name_mapped` and `type_mapped` fields carry post-rename names; otherwise they equal the originals. |

### High-level entry points (`src/root.zig`)

```zig
pub fn reflect(gpa: Allocator, source: [:0]const u8) !Reflect.ReflectResult;
pub fn minifyAndReflect(gpa: Allocator, source: [:0]const u8, options: Minifier.Options) !Minifier.MinifyAndReflectResult;
```

These take raw WGSL source, manage their own arena internally (transferred into
the result), and return a `ReflectResult` whose `deinit` releases everything.

### CLI

```
wgslender reflect shader.wgsl
wgslender reflect --reflect-format v1 shader.wgsl
wgslender reflect --compact shader.wgsl
```

### NPM

```js
const { reflect, minify, getBindGroups } = require('wgslender');
const r = reflect(source);                       // JSON v2 by default
const { code, reflect: r2 } = minify(source, { reflect: true });
```

## Outputs

### `ReflectResult`

```zig
pub const ReflectResult = struct {
    bindings:     []BindingInfo,
    structs:      StringHashMap(StructLayout),
    entry_points: []EntryPointInfo,
    overrides:    []OverrideInfo,
    functions:    []FunctionInfo,
    aliases:      []AliasInfo,
    errors:       [][]const u8,
};
```

| Field | What it holds |
|---|---|
| `bindings` | Every module-scope `var` carrying `@group/@binding`. Includes textures, samplers, uniform/storage buffers, and storage textures. |
| `structs` | Map from struct name to fully-resolved layout (size, alignment, per-field offset/size/alignment). |
| `entry_points` | Functions with `@vertex` / `@fragment` / `@compute` attributes, with workgroup size, I/O signature, and transitive resource list. |
| `overrides` | `override` declarations with optional `@id`, type, and default-value text. |
| `functions` | Every user-defined `fn`, with its declared signature (`params` and `return_type`, spelled from the AST), direct resource refs, direct override refs, outgoing call edges, and transitive `in_use` flag. |
| `aliases` | `alias T = U;` declarations with resolved RHS type. |
| `errors` | Non-fatal reflection errors. Empty on success. |

### `BindingInfo` (key shape)

```zig
group, binding: i32                  // attribute values; both ≥ 0 in a returned binding
name, name_mapped: []const u8        // original / post-rename
name_offset: u32                     // byte offset of the declared name in source
stable_id: []const u8                // reparse-stable id (e.g. "v1:var:uniforms"); see StableId.zig
decl_span, type_span: SpanInfo       // byte ranges of the full decl and the type annotation
address_space: []const u8            // "uniform" | "storage" | "handle" | …
access_mode: []const u8              // "read" | "write" | "read_write" (storage only)
typ, type_mapped: []const u8         // type spelled in source / after rename
type_info: ?*const TypeInfo          // structured recursive type tree
layout: ?StructLayout                // populated for uniform/storage struct bindings
array: ?ArrayInfo                    // populated for uniform/storage array bindings
relations: [][]const u8              // bidirectional texture↔sampler pairings
```

### `StructLayout` / `FieldInfo`

Computed under WGSL §6.2.10 host-shareable rules. `alignment` is always a
power of two; `size` is rounded up to a multiple of `alignment`. Each
`FieldInfo` carries `offset`, `size`, `alignment`, optional nested `layout`
for struct members, and `type_info` for programmatic walking.

### `TypeInfo`

A tagged union mirroring WGSL types so consumers can walk a binding's type
tree without re-parsing the textual `typ` string:

```zig
union(enum) {
    scalar:    ScalarInfo,                      // size, alignment
    vec:       VecInfo,                         // width, format, size, alignment
    mat:       MatInfo,                         // cols, rows, format, size, alignment, stride
    array:     ArrayTypeInfo,                   // format, count?, size?, stride, alignment
    @"struct": StructTypeRef,                   // name → look up in result.structs
    atomic:    AtomicInfo,
    texture:   TextureInfo,                     // dim, kind, format, access, sample_type
    sampler:   SamplerInfo,                     // comparison: bool
    ptr:       PtrInfo,                         // address_space, format, access
}
```

Sizes/alignments inside `TypeInfo` match those reported on `BindingInfo.layout`
and `FieldInfo` for the same physical type.

### `EntryPointInfo`

```zig
name, stage: []const u8              // "vertex" | "fragment" | "compute"
workgroup_size: [3]u32               // axis = 0 when driven by an @override
overrides: [][]const u8              // override names referenced from @workgroup_size
inputs, outputs: []InputOutputInfo   // @location / @builtin entries (struct-flattened)
resources: [][]const u8              // bindings reachable from this entry's call graph
decl_span, name_offset, stable_id    // for IDE / diff tooling
```

`InputOutputInfo` carries `name`, `location`, `builtin`, `interpolate`, `typ`,
and a structured `type_info`. Struct-typed parameters and return types are
flattened: one `InputOutputInfo` per attributed member.

### `OverrideInfo` / `AliasInfo`

Each surfaces a name, a source offset, a stable ID, a declaration span, and its
type both source-spelled and as a structured `TypeInfo`. An override adds the
`@id(N)` value if present and the default expression as written.

### `FunctionInfo`

A name, a source offset, a stable ID, a declaration span, plus `calls`,
`direct_resources`, `direct_overrides`, and a transitive `in_use` flag. A
function that is not an entry point has no other record, so this is the only
place its stable ID appears; for one that is, the ID here and the ID in
`entry_points[]` are the same.

It also carries the declared signature: `params`, one `ParamInfo` per declared
parameter in declaration order, and `return_type` (empty when the declaration
has no `-> T` clause). A `ParamInfo` has the same field set as an `AliasInfo`
type — `name`, `name_mapped`, `typ`, `type_mapped`, `type_info` — and the
return type has the matching `return_type_mapped` and `return_type_info`.

Signature types are spelled from the AST, so they read as the author wrote
them: `"vec2f"`, not `"vec2<f32>"`, and a parameter declared `p: Pos` reports
`"Pos"`, not the alias's target. A type name that does not resolve at all is
likewise reported as written, with no diagnostic. The alias chain *is* followed
in the parallel `type_info` tree, so a host matching a signature against a
table of expected shapes should compare `type_info` and treat `typ` as the
label to show a human. A host that needs types the validator resolved uses
`analyze` and `AnalysisResult.symbol_types` instead. The boundary is:
reflection answers what a signature *says*, and `validate` answers whether it
is true.

One thing the spelling does carry is a pointer's access mode, when the author
wrote one: `ptr<storage, array<f32>, read_write>` round-trips, and
`ptr<function, Element>` does not grow a `read` it never had.

An entry point appears in both `functions[]` and `entry_points[]`. Its
`FunctionInfo.params` lists the declared parameters; its attributed pipeline
I/O, flattened per `@location(N)` / `@builtin(name)`, stays in
`EntryPointInfo.inputs` / `.outputs`.

## Approach

Reflection is a sequence of focused passes over `module.declarations`. Each pass
has a single responsibility, which keeps the code straightforward and lets later
passes assume earlier metadata is in place.

1. **Struct-layout pass.** Compute layout (size / alignment / per-field offset)
   for every `struct` declaration and store under its name. Doing this first
   means later passes can resolve struct types by name without forward-reference
   gymnastics.

2. **Alias collection.** Walk `alias T = U;` declarations and record the
   resolved RHS type. Aliases don't enter struct layouts — type-string and
   type-info construction follow `Symbol.kind == .alias` chains internally —
   but they're surfaced as metadata for v2 consumers.

3. **Override collection.** Capture `@id(N)` (if present), declared type, and
   the default expression (preferring the source byte span, falling back to a
   small renderer for legacy parser paths that don't stamp spans).

4. **Binding + entry-point extraction.**
   - Bindings: every module-scope `var` whose attributes include both `@group`
     and `@binding` (non-negative). Address space is inferred to `handle` for
     texture / sampler types. For uniform/storage struct bindings, the
     pre-computed struct layout is attached; for array bindings, an `ArrayInfo`
     is built (handles fixed-length and runtime-sized arrays, recursively).
   - Entry points: functions tagged `@vertex` / `@fragment` / `@compute`. For
     `@compute` the workgroup size is parsed: literals are evaluated as `u32`;
     references to `override` constants leave the axis as `0` and add the
     override's name to `entry_points[i].overrides`.

5. **Call-graph + resource-attribution pass.** Walk every user `FunctionDecl`
   body once, recording outgoing call edges, direct resource references, and
   direct override references. Texture-sampling builtin calls
   (`textureSample*`, `textureGather*`) populate bidirectional `relations` on
   the matching texture and sampler bindings.

6. **Reachability propagation.** BFS from every entry point through the call
   graph to compute (a) the transitive resource list per entry point, and (b)
   the `in_use` flag on every reachable function.

7. **Stable-ID + type-span annotation pass.** Stamp `stable_id` strings (see
   `StableId.zig`) and type-annotation byte spans onto bindings, struct
   members, entry points, overrides, aliases, and functions — used by tooling
   that needs to track identity across edits.

### Renamer integration

When a `Printer.Renamer` is supplied:

- `name_mapped` carries the post-rename name for the binding / function /
  override / alias / struct member;
- `type_mapped` carries the type string with user-defined type names
  (structs, aliases) substituted for their post-rename equivalents;
- Everything else (offsets, sizes, layouts, structured `TypeInfo`) is
  identical to the no-renamer call.

This is what `minifyAndReflect` exploits: one parse, one analysis, two outputs
(minified text + reflection report).

## JSON output

`ReflectResult.toJson()` and `toJsonPretty()` default to schema **v2**.
`toJsonVersion()` / `toJsonPrettyVersion()` let callers select v1 or v2.

### v1

```json
{
  "bindings":     [ … ],
  "structs":      { name: layout, … },
  "entryPoints":  [ … ],
  "overrides":    [ … ],
  "functions":    [ … ]
}
```

Both versions carry `stableId` on every record that has one, `functions[]`
included. A `nameMapped` is written only where it differs from `name`, so a
reflection with no renamer behind it has none at all.

### v2 — adds

- `"version": 2` marker;
- Subset views filtered out of `bindings[]`:
  - `uniforms[]`  — `address_space == "uniform"`;
  - `storage[]`   — `address_space == "storage"`;
  - `textures[]`  — `type_info.tag == .texture` (includes storage textures, so
    that `samplers[]` ∪ `textures[]` cover every handle binding);
  - `samplers[]`  — `type_info.tag == .sampler`;
- `"aliases": [ … ]` from the alias-collection pass;
- `"params": [ … ]` and `"returnType"` on every entry of `functions[]`.
  `"params"` is always present, an empty array for a nullary function;
  `"returnType"` is `null` for a function with no `-> T` clause. A param's
  optional `"nameMapped"` / `"typeMapped"` are omitted when they equal their
  unmapped form.

The legacy `bindings[]` array is still emitted in v2 as the union — adding the
subset views doesn't remove anything.

## Invariants

- Every returned `BindingInfo` has `group >= 0` and `binding >= 0`.
- Every `StructLayout.alignment` is a power of two; `size` is a multiple of
  `alignment`.
- Without a renamer, `name_mapped == name` and `type_mapped == typ`.
- `functions[i].params.len` equals the declared parameter count, in
  declaration order, for every function — entry points included, and
  `in_use == false` included. A fragment with no entry point at all still
  reports each function's full signature.
- `entry_points[i].workgroup_size[k] == 0` iff axis `k` is driven by an
  `override`; in that case the override name appears in
  `entry_points[i].overrides`.
- `result.deinit(allocator)` frees every slice/list reachable from the result.
  When the result was created via the high-level API (`root.zig`), the same
  `deinit` also tears down the internal arena.

## Verification

- `zig build test` — `tests/reflect_test.zig` covers struct layout, bindings,
  textures/samplers, entry points, workgroup const-eval, resource transitivity,
  arrays, and JSON v1/v2 schemas.
- `tests/reflect_wgslreflect_test.zig` adds torture cases (alias chains,
  deferred forward references, sampler↔texture pairing, control-flow scanning,
  template-arg const expressions).
- `wgslender reflect shader.wgsl` — manual end-to-end check.
- `cd npm/wgslender && node test.js` — exercises the JS surface (`reflect`,
  `minifyAndReflect`, `getBindGroups`, stable-id round-trips).
