# Changelog

The four crates — `wgslender`, `wgslender-core`, `wgslender-macros` and
`wgslender-sys` — are versioned in lock-step and released together, so one file
covers all of them. `xtask` is never published.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the versions are [semantic](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] — unreleased

Nothing is on crates.io yet: publishing needs the Zig sources vendored into
`wgslender-sys`, which is a decision rather than a step. See **Publishing** in
[README.md](README.md).

### Added

- `wgslender` — the facade: `minify`, `minify_with`, `minify_and_reflect`,
  `validate`, `lint`, `lint_fix`, `reflect`, `reflect_json`, `compile`,
  `version`, and `refactor::{find_references, rename, stable_id_at_offset,
  locate_stable_id}`. All 22 exports of the C ABI, reachable safely.
- `include_wgsl!` — validate and minify a shader while `cargo build` runs, and
  embed the result. A shader with a mistake in it fails the build, with the
  compiler pointing at the path literal.
- `include_wgsl_compressed!` (feature `compress`) — the same, storing DEFLATE
  and inflating on first use.
- `wgsl_module!` — generate a Rust module from what a shader declares: binding
  slots, entry-point names and workgroup sizes, and a `#[repr(C)]` struct per
  host-shareable struct, each carrying a `const _: ()` proof of its own size,
  alignment and field offsets.
- `wgslender-core` — the safe API, and the only crate besides `wgslender-sys`
  containing `unsafe`.
- `wgslender-sys` — the raw declarations, and a build script that builds
  `libwgslender.a` from this repository's Zig sources into the crate's own
  `OUT_DIR`.

[Unreleased]: https://github.com/HugoDaniel/wgslender/commits/main/packages/rust
[0.1.0]: https://github.com/HugoDaniel/wgslender/commits/main/packages/rust
