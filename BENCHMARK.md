# WGSL Minifier Benchmark

Comparison of **wgslender 1.0** (Zig) output modes and the legacy **miniray 0.3.1** (Go) minifier.

All sizes include gzipped output to reflect real-world transfer costs.

## Test Files

Benchmark uses compute.toys shaders — real-world WebGPU shaders:

| File | Description |
|------|-------------|
| [bridge.wgsl](tests/testdata/compute.toys/bridge.wgsl) | Complex compute shader (28KB) |
| [cubes_in_space.wgsl](tests/testdata/compute.toys/cubes_in_space.wgsl) | 3D rendering shader |
| [jitter_starfield.wgsl](tests/testdata/compute.toys/jitter_starfield.wgsl) | Particle system |
| [spaced.wgsl](tests/testdata/compute.toys/spaced.wgsl) | Space visualization |
| [circle_sample.wgsl](tests/testdata/compute.toys/circle_sample.wgsl) | Circle drawing |
| [mouse_draw.wgsl](tests/testdata/compute.toys/mouse_draw.wgsl) | Mouse interaction |
| [prelude.wgsl](tests/testdata/compute.toys/prelude.wgsl) | Shared prelude library |

## Results

### Raw Size (bytes)

| File | Original | wgslender minify | wgslender BPE | miniray (Go) |
|------|----------|-----------------|---------------|-------------|
| bridge.wgsl | 28,855 | 8,266 (**72%**) | 4,676 (**84%**) | 8,555 (71%) |
| circle_sample.wgsl | 1,212 | 522 (**57%**) | 638 (48%) | 528 (57%) |
| cubes_in_space.wgsl | 4,292 | 1,127 (**74%**) | 998 (**77%**) | 1,159 (73%) |
| jitter_starfield.wgsl | 4,472 | 1,289 (**72%**) | 1,120 (**75%**) | 1,334 (71%) |
| mouse_draw.wgsl | 1,449 | 641 (**56%**) | 697 (52%) | 656 (55%) |
| prelude.wgsl | 2,985 | 423 (**86%**) | 576 (81%) | 424 (86%) |
| spaced.wgsl | 4,352 | 1,574 (**64%**) | 1,296 (**71%**) | 1,630 (63%) |
| **Total** | **47,617** | **13,842 (71%)** | **10,001 (79%)** | **14,286 (70%)** |

### Gzipped Size (bytes)

| File | Original | wgslender minify | wgslender BPE | miniray (Go) |
|------|----------|-----------------|---------------|-------------|
| bridge.wgsl | 7,471 | **3,297** | 3,034 | 3,333 |
| circle_sample.wgsl | 645 | **384** | 600 | 386 |
| cubes_in_space.wgsl | 1,944 | **696** | 911 | 703 |
| jitter_starfield.wgsl | 1,904 | **797** | 1,008 | 806 |
| mouse_draw.wgsl | 675 | **402** | 638 | 406 |
| prelude.wgsl | 1,079 | **319** | 519 | 320 |
| spaced.wgsl | 1,919 | **898** | 1,122 | 911 |
| **Total** | **15,637** | **6,793 (57% smaller)** | **7,832 (50% smaller)** | **6,865 (56% smaller)** |

**Bold** indicates best (smallest) result per row.

## Summary

| Variant | Raw reduction | Gzip total | Best for |
|---------|--------------|------------|----------|
| **wgslender minify** | 71% | **6,793 bytes** | Network transfer (best gzip) |
| **wgslender BPE** | **79%** | 7,832 bytes | No-gzip environments, raw size |
| miniray (Go) | 70% | 6,865 bytes | Legacy reference |

Key findings:

- **BPE wins on raw size** (79% reduction) — the `.wasm` binary is smallest before compression
- **Minified text wins after gzip** (6,793 bytes) — DEFLATE already captures the patterns that BPE encodes, so minified text compresses slightly better
- **Zig rewrite beats Go** on both raw size (71% vs 70%) and gzip (6,793 vs 6,865 bytes)

## Output Modes

### wgslender minify (default)

Produces minified WGSL text. Identifiers renamed, whitespace stripped, syntax simplified.
Best when the output will be gzip/brotli compressed for network transfer.

```bash
wgslender shader.wgsl -o shader.min.wgsl
```

### wgslender compile (BPE)

Produces a `.wasm` binary that reconstructs the WGSL at runtime via byte-pair encoding.
The .wasm file is self-contained (~110 byte decoder + compressed data). Best when you
need the smallest possible raw file without relying on transport compression.

```bash
wgslender compile shader.wgsl -o shader.wasm
```

```javascript
const { instance } = await WebAssembly.instantiate(shaderWasm);
const len = instance.exports.generate();
const wgsl = new TextDecoder().decode(new Uint8Array(instance.exports.memory.buffer, 0, len));
```

## Running the Benchmark

```bash
# Build wgslender first
zig build

# Run on all compute.toys shaders (default)
./scripts/benchmark.sh

# Run on specific files
./scripts/benchmark.sh path/to/shader.wgsl

# Override binary paths
MINIRAY_BIN=/path/to/miniray ./scripts/benchmark.sh
WGSLENDER_BIN=./zig-out/bin/wgslender ./scripts/benchmark.sh
```
