# WGSL Minifier Benchmark

Comparison of **wgslender** (Go) vs **[wgsl-minifier](https://crates.io/crates/wgsl-minifier)** (Rust).

## Test Files

Benchmark uses shaders from real-world WebGPU projects including:
- WebGPU Dawn samples (basic_vert, blur, shadow_fragment)
- Ray tracing demos (cornell_common)
- Large production shaders (sceneE, sceneW, sceneY, starsParticlesModule)

Repository includes sample shaders for testing:

| File | Description |
|------|-------------|
| [bridge.wgsl](tests/testdata/compute.toys/bridge.wgsl) | Complex compute shader |
| [cubes_in_space.wgsl](tests/testdata/compute.toys/cubes_in_space.wgsl) | 3D rendering shader |
| [jitter_starfield.wgsl](tests/testdata/compute.toys/jitter_starfield.wgsl) | Particle system |
| [spaced.wgsl](tests/testdata/compute.toys/spaced.wgsl) | Space visualization |

## Results

### Repository Test Files

| File | Original | wgslender | Rust | wgslender % | Rust % |
|------|----------|---------|------|-----------|--------|
| bridge.wgsl | 28,855 | 8,542 | ERR | **70%** | - |
| circle_sample.wgsl | 1,212 | 528 | ERR | **56%** | - |
| cubes_in_space.wgsl | 4,292 | 1,159 | ERR | **73%** | - |
| jitter_starfield.wgsl | 4,472 | 1,334 | ERR | **70%** | - |
| mouse_draw.wgsl | 1,449 | 656 | ERR | **55%** | - |
| prelude.wgsl | 2,985 | 424 | 1,553 | **86%** | 48% |
| spaced.wgsl | 4,352 | 1,629 | ERR | **63%** | - |

### External Test Files

| File | Original | wgslender | Rust | wgslender % | Rust % |
|------|----------|---------|------|-----------|--------|
| basic_vert.wgsl | 549 | 374 | 314 | 32% | **43%** |
| blur.wgsl | 2,678 | 1,049 | 1,890 | **61%** | 29% |
| cornell_common.wgsl | 4,673 | 1,544 | ERR | **67%** | - |
| example.wgsl | 1,759 | 940 | 833 | 47% | **53%** |
| fullscreen_quad.wgsl | 854 | 563 | 617 | **34%** | 28% |
| sceneE.wgsl | 40,054 | 7,743 | 14,381 | **81%** | 64% |
| sceneW.wgsl | 70,035 | 21,700 | ERR | **69%** | - |
| sceneY.wgsl | 40,843 | 11,858 | 18,332 | **71%** | 55% |
| shadow_fragment.wgsl | 1,299 | 736 | ERR | **43%** | - |
| starsParticlesModule.wgsl | 33,438 | 3,297 | 11,035 | **90%** | 67% |

**Bold** indicates better reduction for that file.

## Summary

### wgslender (Go)

- **Success rate**: 17/17 (100%)
- **Average reduction**: 67%
- **Best on**: Large shaders (81%, 90% reduction), compute.toys shaders
- **Approach**: Preserves external binding names for API compatibility

### wgsl-minifier (Rust)

- **Success rate**: 8/17 (47%)
- **Average reduction**: 42% (on successful files)
- **Best on**: Simple shaders with basic WGSL features
- **Approach**: More aggressive renaming including struct fields

### Rust Minifier Failures

| File | Reason |
|------|--------|
| bridge.wgsl | compute.toys extensions |
| circle_sample.wgsl | compute.toys extensions |
| cubes_in_space.wgsl | compute.toys extensions |
| jitter_starfield.wgsl | compute.toys extensions |
| mouse_draw.wgsl | compute.toys extensions |
| spaced.wgsl | compute.toys extensions |
| cornell_common.wgsl | Parsing error |
| sceneW.wgsl | `texture_external` not supported |
| shadow_fragment.wgsl | Parsing error |

## Key Differences

| Feature | wgslender (Go) | wgsl-minifier (Rust) |
|---------|--------------|----------------------|
| Type aliases | Uses short forms (`vec4f`) | Keeps explicit (`vec4<f32>`) |
| External bindings | Preserves names by default | Renames aggressively |
| Struct fields | Preserves (API safety) | Renames (smaller output) |
| WGSL coverage | Full spec support | Limited (no texture_external) |
| Tree shaking | Yes | No |

## Running the Benchmark

Use the included benchmark script to compare size and speed:

```bash
# Build wgslender
zig build

# Install Rust minifier (optional, for comparison)
cargo install wgsl-minifier

# Run benchmark on repo test files
./scripts/benchmark.sh

# Run on specific files
./scripts/benchmark.sh path/to/shader.wgsl

# Configure iterations for timing (default: 10)
ITERATIONS=20 ./scripts/benchmark.sh

# Use custom binary paths
WGSLENDER_BIN=./build/wgslender RUST_BIN=wgsl-minifier ./scripts/benchmark.sh
```

### Example Output

```
=== WGSL Minifier Benchmark ===
wgslender: ./build/wgslender
wgsl-minifier: wgsl-minifier (available: true)
iterations: 5

| File                         | Original | wgslender |    Rust | wgslender |   Rust |  wgslender |     Rust |
|                              |    bytes |   bytes |   bytes |       % |      % |     time |     time |
|------------------------------|----------|---------|---------|---------|--------|----------|----------|
| bridge.wgsl                  |    28855 |    8542 |     ERR |     71% |      -% |  56.60ms |      -ms |
| prelude.wgsl                 |     2985 |     424 |    1553 |     86% |     48% |  52.80ms |  50.00ms |

=== Summary ===

wgslender:
  Success: 7/7 files
  Total: 47617 -> 14272 bytes (70.1% reduction)
```

## Links

- **wgslender (Go)**: This repository
- **wgsl-minifier (Rust)**: [crates.io](https://crates.io/crates/wgsl-minifier) | [GitHub](https://github.com/pjoe/wgsl-minifier)
