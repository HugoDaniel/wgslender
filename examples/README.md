# examples/

Worked examples of consuming wgslender from another language. Each one builds
and runs on demand — there is no CI here, so the commands below are the whole
verification story.

| Example | What it shows | Run it |
|---|---|---|
| [`c/`](c/) | The C ABI over `libwgslender.a`: minify (bitflags and JSON options), validate, reflect, lint, lint-fix, rename, refactor-by-stable-id, compile | `zig build lib && make -C examples/c test` |

`make -C examples/c lint-portability` additionally compiles every C example
against glibc headers through `zig cc -target x86_64-linux-gnu`, so a
macOS-only libc call fails here rather than on someone else's Linux box.

The Rust story is not here: it is a package rather than an example, and lives
in [`packages/rust/`](../packages/rust/README.md).
