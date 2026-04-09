# Scripts

## test-compile.ts

Tests WGSL shader compilation using WebGPU via Deno.

### Usage

```bash
# Test original shader compiles
deno run --unstable-webgpu --allow-read scripts/test-compile.ts shader.wgsl

# Test minified shader compiles
deno run --unstable-webgpu --allow-read --allow-run scripts/test-compile.ts --minify shader.wgsl

# Compare original and minified
deno run --unstable-webgpu --allow-read --allow-run scripts/test-compile.ts --compare shader.wgsl

# With config file
deno run --unstable-webgpu --allow-read --allow-run scripts/test-compile.ts --compare --config configs/compute.toys.json shader.wgsl

# Multiple files
deno run --unstable-webgpu --allow-read --allow-run scripts/test-compile.ts --minify tests/testdata/*.wgsl
```

### Options

- `--minify` - Minify shader before compiling
- `--config <file>` - Config file for wgslender (requires --minify)
- `--compare` - Test both original and minified (implies --minify)
- `--verbose` - Show shader source on error

### Requirements

- Deno with WebGPU support
- GPU hardware (won't work in headless CI without GPU)
- `build/wgslender` binary (run `zig build` first)
