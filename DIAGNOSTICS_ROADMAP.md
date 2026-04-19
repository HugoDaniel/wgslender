# Diagnostics Roadmap

Ideas and suggestions for improving wgslender's error reporting, LSP experience, and developer UX — ordered from low-hanging fruit to bigger architectural changes.

## 1. Related diagnostics — point to "the other place"

`Diagnostic.Entry` already has a `related: []const RelatedInfo` field and the formatter supports it, but it's never populated anywhere. This is the single highest-impact improvement because so many errors reference two locations.

**Duplicates** — "you already declared this here":
- `duplicate member 'x' in struct 'Foo'` — point to the first member
- `@group(0) @binding(0) is already used by 'uniforms'` — point to the existing binding
- `duplicate input @location(0)` — point to the first `@location(0)`
- `@id(1) is already used by override 'x'` — point to the existing override

**Type mismatches** — "this is what I expected":
- `cannot return 'f32' from function expecting 'i32'` — point to the function's return type declaration
- `cannot assign 'vec3f' to 'vec4f'` — point to the variable declaration
- `cannot initialize 'x' with type 'f32' (expected 'i32')` — point to the type annotation
- `case selector 'true' doesn't match switch type 'i32'` — point to the switch expression

**Struct/function references** — "this is where it's defined":
- `struct 'Foo' has no member 'bar'` — point to the struct definition (so you can see what members it *does* have)
- `argument 2 of 'foo' has type 'f32', expected 'i32'` — point to the function signature
- `function 'foo' is recursive` — point to the recursive call site

Turns a cryptic error into a conversation between two source locations — exactly how rustc and TypeScript present errors.

## 2. "Did you mean?" everywhere, not just types

The Levenshtein suggestion engine (`suggestType` in Validator.zig) only covers type names. The same pattern could help with:

- **Struct members**: `struct 'Vertex' has no member 'positon'` — "did you mean 'position'?"
- **Function names**: `use of undeclared identifier 'mai'` — "did you mean 'main'?"
- **Builtin names**: `@builtin(positio)` — "did you mean 'position'?"
- **Swizzle components**: Invalid swizzle `.xyw` on a vec3 — "did you mean '.xyz'?"
- **Address spaces / access modes**: Misspelled `worrkgroup` or `read_wrte`
- **Enable/requires extensions**: Misspelled feature names

The Levenshtein infrastructure is already there — it's just a matter of calling it in more contexts.

## 3. Serialize the diagnostic fields you already have

The LSP `LspDiagnostic` struct (Handler.zig) discards `code`, `related`, and `spec_ref` during conversion. Three quick wins:

- **Pass `code` through** — editors show `[E0200]` and users can search for it
- **Pass `related` through** as LSP's `relatedInformation` — editors show "see also" links
- **Pass `spec_ref` through** — could become a clickable link to the WGSL spec section

The internal infrastructure supports all of this; only the LSP serialization layer is missing.

## 4. Smarter error ranges (not just the start token)

Right now errors point to a single byte offset, producing a 1-character range. If you tracked end positions too:

- `unknown type 'VertexOutput'` could underline the entire `VertexOutput` token (12 chars) instead of just `V`
- `cannot assign 'vec3f' to 'vec4f'` could underline the entire RHS expression
- `operator '+' requires numeric operands` could underline both operands

Turns a tiny red dot into a red squiggly line under the relevant code — much more scannable.

## 5. Deduplicate errors across validation phases

The return type `-> VertexOutput` gets resolved in both phase 3 (type collection) and phase 4 (function validation), producing duplicate errors at the same location. A dedup pass before emitting diagnostics (or a "seen set" during validation) would clean this up.

## 6. Contextual parser errors

Parser errors are generic: `"expected type"`, `"expected expression"`, `"expected statement"`. Adding context would help:

- `"expected type"` — `"expected type after ':' in variable declaration"`
- `"expected expression"` — `"expected expression after '=' in let declaration"`
- `"expected statement"` — `"expected statement in function body"`

## 7. Code actions (quick fixes)

The LSP doesn't support `textDocument/codeAction` yet. With the diagnostic data already available, you could offer:

- **"did you mean?" — auto-rename**: Click to replace `VertexOutput` with `VertexOutputs`
- **Missing `@builtin(position)`** — insert it
- **Duplicate `@location(N)`** — increment to next available slot
- **Type mismatch in initialization** — insert a cast or change the type annotation
- **Unused variable** — prefix with `_` or remove

## 8. Hover and go-to-definition

The parser already builds a symbol table with scope chains and use counts. This is most of what you'd need for:

- **Hover**: Show the type of a variable/expression at a position
- **Go-to-definition**: Jump from a type reference to its struct/alias declaration
- **Find all references**: Show everywhere a symbol is used (already tracks `use_count`)

The symbol table infrastructure is there — it's the LSP request handling that's missing.

## 9. Spec references on more errors

Only uniformity errors set `spec_ref`. Every error code could link to the relevant WGSL spec section:

- `E0200` (type_mismatch) — spec section on types
- `E0103` (recursive_function) — spec section on function declarations
- `E0600` (invalid_entry_point) — spec section on entry points

Turns error messages into learning opportunities, especially for people new to WGSL.

## 10. Warnings for things that aren't errors but smell bad

The validator is strict about errors but doesn't warn about suspicious patterns:

- **Unused variables/parameters** (symbols with `use_count == 0` after binding)
- **Unreachable code after return** (partially done, could be expanded)
- **Shadowed variables** in nested scopes
- **Integer overflow in constant expressions**
- **Division by zero in constant expressions**
- **Redundant casts** (e.g., `f32(some_f32)`)

These could be warnings (or hints) that help catch bugs without blocking compilation.
