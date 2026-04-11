# WGSL Minifier Benchmark

Comparison of **wgslender 1.0** (Zig) output modes and the legacy **miniray 0.3.1** (Go) minifier.

All sizes include gzipped output to reflect real-world transfer costs.

## Test Files

Benchmark uses 11 real-world WebGPU shaders — compute.toys projects plus large production ray marching and particle shaders:

| File | Size | Description |
|------|------|-------------|
| [sceneW.wgsl](tests/testdata/sceneW.wgsl) | 70KB | Large ray marching scene |
| [sceneY.wgsl](tests/testdata/sceneY.wgsl) | 41KB | Ray marching scene variant |
| [sceneE.wgsl](tests/testdata/sceneE.wgsl) | 40KB | Ray marching scene variant |
| [starsParticlesModule.wgsl](tests/testdata/starsParticlesModule.wgsl) | 33KB | Star particle system |
| [bridge.wgsl](tests/testdata/compute.toys/bridge.wgsl) | 29KB | Complex compute shader |
| [jitter_starfield.wgsl](tests/testdata/compute.toys/jitter_starfield.wgsl) | 4.5KB | Particle system |
| [spaced.wgsl](tests/testdata/compute.toys/spaced.wgsl) | 4.4KB | Space visualization |
| [cubes_in_space.wgsl](tests/testdata/compute.toys/cubes_in_space.wgsl) | 4.3KB | 3D rendering shader |
| [prelude.wgsl](tests/testdata/compute.toys/prelude.wgsl) | 3KB | Shared prelude library |
| [mouse_draw.wgsl](tests/testdata/compute.toys/mouse_draw.wgsl) | 1.4KB | Mouse interaction |
| [circle_sample.wgsl](tests/testdata/compute.toys/circle_sample.wgsl) | 1.2KB | Circle drawing |

## Results

### Raw Size (bytes)

| File | Original | wgslender minify | wgslender BPE | miniray (Go) |
|------|----------|-----------------|---------------|-------------|
| sceneW.wgsl | 70,035 | 20,840 (71%) | **11,935 (83%)** | 21,702 (70%) |
| sceneY.wgsl | 40,843 | 11,283 (73%) | **5,822 (86%)** | 11,868 (71%) |
| sceneE.wgsl | 40,054 | 7,411 (82%) | **4,078 (90%)** | 7,744 (81%) |
| starsParticlesModule.wgsl | 33,438 | 3,260 (91%) | **2,188 (94%)** | 3,298 (91%) |
| bridge.wgsl | 28,855 | 8,266 (72%) | **4,676 (84%)** | 8,555 (71%) |
| jitter_starfield.wgsl | 4,472 | 1,289 (72%) | **1,120 (75%)** | 1,334 (71%) |
| spaced.wgsl | 4,352 | 1,574 (64%) | **1,296 (71%)** | 1,630 (63%) |
| cubes_in_space.wgsl | 4,292 | 1,127 (74%) | **998 (77%)** | 1,159 (73%) |
| prelude.wgsl | 2,985 | 423 (86%) | **576 (81%)** | 424 (86%) |
| mouse_draw.wgsl | 1,449 | **641 (56%)** | 697 (52%) | 656 (55%) |
| circle_sample.wgsl | 1,212 | **522 (57%)** | 638 (48%) | 528 (57%) |
| **Total** | **231,987** | **56,636 (76%)** | **34,024 (86%)** | **58,898 (75%)** |

### Gzipped Size (bytes)

| File | Original | wgslender minify | wgslender BPE | miniray (Go) |
|------|----------|-----------------|---------------|-------------|
| sceneW.wgsl | 15,432 | 7,675 | **6,250** | 7,781 |
| sceneY.wgsl | 10,334 | 3,789 | **3,421** | 3,839 |
| sceneE.wgsl | 8,652 | 2,864 | **2,561** | 2,899 |
| starsParticlesModule.wgsl | 7,568 | **1,511** | 1,599 | 1,522 |
| bridge.wgsl | 7,471 | 3,297 | **3,034** | 3,333 |
| jitter_starfield.wgsl | 1,904 | **797** | 1,008 | 806 |
| spaced.wgsl | 1,919 | **898** | 1,122 | 911 |
| cubes_in_space.wgsl | 1,944 | **696** | 911 | 703 |
| prelude.wgsl | 1,079 | **319** | 519 | 320 |
| mouse_draw.wgsl | 675 | **402** | 638 | 406 |
| circle_sample.wgsl | 645 | **384** | 600 | 386 |
| **Total** | **57,623** | **22,632 (61% smaller)** | **21,663 (63% smaller)** | **22,906 (61% smaller)** |

**Bold** indicates best (smallest) result per row.

## Summary

| Variant | Raw reduction | Gzip total | vs original gzip |
|---------|--------------|------------|------------------|
| **wgslender BPE** | **86%** | **21,663 bytes** | **63% smaller** |
| **wgslender minify** | 76% | 22,632 bytes | 61% smaller |
| miniray (Go) | 75% | 22,906 bytes | 61% smaller |

Key findings:

- **BPE wins overall** — best raw size (86%) and best gzip (21,663 bytes). The advantage is strongest on large shaders where BPE has more patterns to exploit.
- **Minified text wins on small shaders** — for files under ~5KB, gzipped minified text beats gzipped BPE because DEFLATE's dictionary works well at that scale.
- **BPE crossover point** is around 5KB — above that, the BPE `.wasm` binary gzips smaller than minified text.
- **Zig rewrite beats Go** across the board — 76% vs 75% raw, 22,632 vs 22,906 gzip.

### Conclusion

For **large shaders** (>5KB) — which represent most real-world WebGPU projects — **use `wgslender compile`**. The BPE `.wasm` output is the smallest both raw and gzipped, and reconstructs the original WGSL at runtime with a ~110 byte decoder. On a 70KB shader, BPE delivers a 6.2KB gzipped file vs 7.7KB for minified text — a 20% further saving.

For **small shaders** (<5KB) or when you need the output to remain readable WGSL, **use `wgslender` (default minify)**. Gzipped minified text is slightly smaller at this scale, and the output is standard WGSL that can be inspected or further processed.

In both cases, wgslender reduces shader transfer size by **61–63%** compared to gzipping the original source alone.

## Output Modes

### wgslender minify (default)

Produces minified WGSL text. Identifiers renamed, whitespace stripped, syntax simplified.
Best when the output will be gzip/brotli compressed for network transfer of small shaders.

```bash
wgslender shader.wgsl -o shader.min.wgsl
```

### wgslender compile (BPE)

Produces a `.wasm` binary that reconstructs the WGSL at runtime via byte-pair encoding.
The .wasm file is self-contained (~110 byte decoder + compressed data). Best for large
shaders or when you want the smallest possible transfer size.

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

# Run on all test shaders (default)
./scripts/benchmark.sh

# Run on specific files
./scripts/benchmark.sh path/to/shader.wgsl

# Override binary paths
MINIRAY_BIN=/path/to/miniray ./scripts/benchmark.sh
```
