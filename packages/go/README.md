# wgslender for Go

A pure-Go module wrapping the wgslender engine: minify, validate, lint,
reflect, compile and refactor WGSL from Go.

```go
result, err := wgslender.Minify(ctx, source, nil)
reflection, err := wgslender.Reflect(ctx, source)
```

No cgo, no C toolchain, no Zig. The engine ships here as a WebAssembly module
embedded in the package and executed by [wazero], so `go build` on any platform
Go targets is the whole build.

[wazero]: https://wazero.io

```
import path   git.hugodaniel.com/hugo/wgslender/packages/go/wgslender
module        git.hugodaniel.com/hugo/wgslender/packages/go
go            1.26
requires      github.com/tetratelabs/wazero v1.12.0
```

## What is here

| Path | What it is |
|---|---|
| `wgslender/` | **The package to import.** The whole public API. |
| `internal/wasmabi/` | The embedded `wgslender.wasm`, the wazero runtime, the instance pool, and the calling convention that reaches the guest. |
| `cmd/wgslgen/` | The `go:generate` tool: embeds a shader, minified and checked, and optionally describes it as Go. |

## The calls

| Function | What it does |
|---|---|
| `Minify` / `MinifyAndReflect` | Shorten a shader, optionally with its reflection. |
| `Validate` | Type-check it. |
| `Lint` / `LintFix` | Run the configured rules; apply the autofixes. |
| `Reflect` / `ReflectJSON` / `BindGroups` | Describe its interface. |
| `Compile` | Produce a binary shader — a tiny `.wasm` that generates the WGSL at run time. |
| `FindReferences`, `Rename`, `ChangeType`, `RemoveDeclaration`, … | The twelve refactor operations, by byte offset or by `StableID`. |
| `Version` | The engine's version. |

Every one of them takes a `context.Context` first and is safe to call from any
number of goroutines. See the package documentation for the rest.

## `go:generate`

`cmd/wgslgen` moves the checking and the minifying to build time, which is the
last moment at which a shader mistake is still cheap:

```go
//go:generate wgslgen -var Blur -o blur_shader.go blur.wgsl
```

That writes `blur_shader.go` holding the minified shader as a `const`, and
fails the generate step — with diagnostics and a non-zero status — if the
shader does not type-check. `-compress` stores a DEFLATE stream instead, behind
a `sync.OnceValue` that inflates it on first use.

```go
//go:generate wgslgen -module -var Blur -o blur_shader.go blur.wgsl
```

`-module` adds what the shader *declares*: a constant pair per binding, the
entry-point names and workgroup sizes, and a Go struct per WGSL struct with
explicit `_ [N]byte` padding so that every field lands at the offset the GPU
will read it from. It writes a second file beside the first —
`blur_shader_test.go` — asserting each struct's `unsafe.Sizeof` and
`unsafe.Offsetof` against the shader.

That test is the point. A generated struct is a claim about memory, and Go
cannot constrain a struct's layout in the language the way Rust's
`wgsl_module!` can at compile time, so the claim is checked by `go test`.

A WGSL type Go has no shape for is neither guessed at nor dropped: it becomes
padding of exactly its size, so every field after it stays put, plus a constant
saying where it begins. That is a runtime-sized array, whose length the host
chooses, and a matrix or array whose elements sit further apart than they are
wide — `mat3x3f` is three twelve-byte columns sixteen bytes apart, and a Go
array's stride is its element size.

`go generate` looks for the tool on `PATH`, so install it from a checkout —
`@latest` needs a published module, and this is not one yet (see
[Publishing](#publishing)):

```sh
go install ./cmd/wgslgen        # from packages/go
```

## Two things that are not symmetrical

**A nil `*MinifyOptions` means wgslender's defaults. A nil `*LintConfig` means
no rules at all.** Both are the engine's own reading, mirrored here rather than
smoothed over. Minification has a sensible default pipeline; linting has no
default rule set, and inventing one here would put this package's opinion in
front of the engine's. Ask for one by name:

```go
cfg := &wgslender.LintConfig{Extends: []wgslender.Pack{wgslender.PackRecommended}}
```

**`MinifyOptions` fields are tri-state.** `Opt[bool]` distinguishes *absent*
from *false*, because absent means "whatever wgslender decides" and pinning a
copy of those defaults here is how they go stale:

```go
opts := &wgslender.MinifyOptions{MinifyIdentifiers: wgslender.Set(false)}
```

## Where this diverges from the npm package

- **There is no `initialize()`.** The module compiles on first use — roughly
  130 ms once, per process — and every call after that is warm. The npm package
  makes the caller await an explicit initialisation; Go's lazy initialisation
  makes the ceremony unnecessary.
- **A shader's own problems are data, not errors.** Source that does not parse,
  does not type-check or trips a rule comes back in the result and the call
  succeeds. A returned `error` means the call could not be made or could not be
  trusted. The exceptions are the calls with nothing to report when they fail —
  `Compile` and the refactor family — and they say so in their documentation.
- **Non-UTF-8 input is refused** with `ErrInvalidUTF8` rather than answered.
  Rust cannot reach this case (`&str` is UTF-8 by construction) and npm hides
  it inside `TextDecoder`; a Go `string` is only bytes, and the engine copies
  stray ones into a reply no JSON decoder reads back faithfully.
- **Refactor errors are Go errors**, not `error` fields on a result, and
  minification errors are a flat `[]string`.

## The embedded wasm

`internal/wasmabi/wgslender.wasm` is a byte-for-byte copy of
`packages/js-npm/wgslender.wasm`, embedded so that a `go get` needs nothing
else. **Whenever the wire changes, rebuild and copy to both:**

```sh
zig build wasm
cp zig-out/bin/wgslender.wasm packages/js-npm/wgslender.wasm
cp zig-out/bin/wgslender.wasm packages/go/internal/wasmabi/wgslender.wasm
```

`TestWasmMatchesNpm` compares the two by SHA-256 and fails with that recipe in
the message. It is the only automated freshness check either package has.

## Gates

This repository has no CI by design. `make check` is the gate, and it must pass
before every commit:

```sh
make -C packages/go check      # gofmt -l, go vet, go build, go test -race
```

`-race` is not optional: the package hands a pool of single-threaded wasm
instances to arbitrarily many goroutines, and the detector is what keeps that
honest. The opt-in targets are for when you are working on the thing they
measure — `make lint` (golangci-lint, hard-fails if missing), `make fuzz`,
`make bench`.

## Publishing

Nothing here is published, and what stands in the way is a decision rather
than a step. Go has no registry to push to: an import path is a URL, and `go
get` fetches it by asking that URL for `?go-get=1` and reading a `go-import`
meta tag. So the question is which URL.

1. **Push the repository and rely on Gitea's own metadata.**
   `git.hugodaniel.com/hugo/wgslender/packages/go` would resolve directly.
   Unverified: whether the instance serves `go-import` for a subdirectory
   module, and whether it is reachable to the proxy at `proxy.golang.org` —
   a private host means every consumer needs `GOPRIVATE=git.hugodaniel.com`
   (or `GONOSUMDB`/`GONOSUMCHECK`) and loses the module proxy and the checksum
   database along with it.
2. **A vanity import path.** A short domain serving a `go-import` meta tag that
   points at wherever the code actually lives, which decouples the import path
   from the host and makes moving hosts a DNS change. Costs a domain and a page
   to serve.
3. **Mirror to a public host.** GitHub or Codeberg, with the canonical
   repository staying where it is. The proxy and the checksum database work
   without any consumer configuration; the cost is a second place the code
   lives and a mirror that can fall behind.

The module path is already `git.hugodaniel.com/hugo/wgslender/packages/go`, so
option 1 needs no code change and the others do. **Re-verify before publishing
either way**: a module path baked into every `import` line is expensive to
change afterwards.

## Licence

CC0-1.0, like the rest of the repository.
