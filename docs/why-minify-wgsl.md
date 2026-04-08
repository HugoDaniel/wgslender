# Why Minify WGSL Shaders?

## Reduced File Size & Bandwidth

WGSL is a text-based format (unlike SPIR-V binary), so minification provides significant savings:

| Optimization | Typical Reduction |
|--------------|-------------------|
| Whitespace removal | 20-30% |
| Identifier shortening | 20-40% |
| Dead code elimination | varies |
| **Total** | **55-71%** |

For web-based WebGPU applications, this means:
- Faster initial page load
- Lower bandwidth costs
- Better performance on mobile/constrained networks

## Faster Shader Compilation

The GPU driver must parse WGSL text at runtime:
- Less text = faster tokenization and parsing
- Smaller AST construction
- Though the benefit is modest since optimization passes dominate compile time

## IP Protection / Obfuscation

```wgsl
// Before: reveals algorithm intent
fn calculatePhongLighting(normal: vec3f, lightDir: vec3f) -> f32

// After: harder to reverse-engineer
fn a(b:vec3f,c:vec3f)->f32
```

This isn't encryption, but it:
- Raises the bar for copying proprietary techniques
- Removes semantic hints about algorithms
- Tree shaking removes unused code that might reveal internal structure

## Production Workflow

- **Development**: Readable shaders with meaningful names
- **Production**: Minified for deployment
- **Debugging**: Source maps map back to original (wgslender supports v3 source maps)

## Web-Specific Benefits

Unlike desktop APIs with binary formats:
- WebGPU mandates text-based WGSL
- Web developers already minify JS/CSS—shaders are no different
- Embedded shader strings bloat JavaScript bundles
- CDNs and gzip work better with smaller base files

## When Minification Matters Most

- Large shaders with verbose naming
- Applications with many shaders
- Mobile web / bandwidth-constrained environments
- Commercial applications where IP protection matters

## When Minification Matters Less

- Small utility shaders
- Offline/local applications
- Internal tools where readability trumps size
- Already gzip-compressed delivery (text compresses well)

## Trade-offs

| Benefit | Risk |
|---------|------|
| Smaller size | Minifier bugs could alter behavior |
| Obfuscation | Harder to debug without source maps |
| Faster parsing | Must preserve external binding names for reflection |

Wgslender mitigates these by preserving API-facing names (`@group/@binding` vars, entry points) by default and offering source map generation for debugging.
