# docs/plans/asks — adaptations a downstream host asked for

This directory is the third in a chain. `~/Dev/SJON/docs/plans/asks/` is where
hosts file against the substrate; `~/Dev/pngine/docs/plans/asks/` is where they
file against PNGine; this is where they file against wgslender. The conventions
are copied from the first of them because they work.

**The rules, unchanged:**

- **The ask states the gap, not the fix.** A filing carries the claim, the
  evidence read against a named tree (file:line), a reproduction, where the gap
  would live, and the cost of not closing it. The verdict, the design and the
  plan are wgslender's to write, appended to the same file under a `---`.
- **A refusal is a verdict.** "No change needed", "this is the contract, and
  here is the doc line that should have said so", and "the host works around
  it" are all outcomes. A filing that cannot survive being refused is not
  ready.
- **Evidence is cited, not summarised.** Every claim names the file and line it
  was read from, and the tree it was read against, so it can be re-validated
  before anything is decided.
- **Decisions changed later are appended as dated notes**, not silently
  rewritten.

## Filed

| # | Ask | Host | Verdict | Plan |
|---|---|---|---|---|
| W1 | Reflection reports every function's name and none of its type | animader | **Accepted 2026-08-31** — `FunctionInfo` gains AST-spelled `params` / `return_type`, JSON v2 only. **Landed 2026-08-31** | [01](01-function-signatures-in-reflection.md) |

Plan numbers track the W-numbers one-to-one, the way PNGine's track the
P-numbers.

## The host

**animader** is a planned interaction and creative tier for the same family:
an event log, a state machine, a bridge onto pacer's write buffer, and above
them a piece format whose creative vocabulary is a growing set of lowering
verbs over PNGine and pacer rather than a language of its own. Its plans are in
`~/Dev/animader/animader/plans/`, and its constitution is
`~/Dev/animader/animader/product.md`.

What animader wants from wgslender is narrow and it is stated in one place,
`plans/animader/02-domains.md`, "Checking a kernel". A **kernel** there is a
WGSL function with a declared signature class, shipped as a fragment with no
entry point and no `@group`/`@binding`, pulled into a PNGine pass through
`:imports`. Five classes exist and they are the whole type system on the WGSL
side:

| Class | WGSL signature |
|---|---|
| `field1` | `fn(vec2f) -> f32` |
| `field2` | `fn(vec2f) -> vec2f` |
| `field4` | `fn(vec2f) -> vec4f` |
| `shade` | `fn(f32) -> vec4f` |
| `step` | `fn(ptr<function, Element>, f32)` |

wgslender was adopted on 2026-08-31 because it is the only tool in the family
that reads WGSL at all: PNGine treats shader text as opaque, and animader's own
law A calls a piece's kernels as authoritative as its SJON. Four properties
decided it, all verified against `aa76395`: a bare fragment with no entry point
validates clean; a body contradicting its class is `E0200`; reflection reports
an `address_space`, an `access_mode` and the resources each function touches;
and one engine serves the CLI, the library, wasm and the language server, so a
corpus gate and an editor pane check identically.

This ask is filed from plans rather than from a build. Nothing is blocked
today, because nothing is built, and what it carries instead is the workaround
that ships without it.
