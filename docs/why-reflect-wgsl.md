# Why Use WGSL Shader Reflection?

## Automatic Bind Group Layout Creation

WebGPU requires explicit bind group layouts that must exactly match the shader:

```javascript
// Without reflection: manual synchronization
const bindGroupLayout = device.createBindGroupLayout({
  entries: [
    { binding: 0, visibility: GPUShaderStage.FRAGMENT, buffer: { type: 'uniform' } },
    { binding: 1, visibility: GPUShaderStage.FRAGMENT, texture: { sampleType: 'float' } },
    // Must match shader exactly - error-prone
  ]
});

// With reflection: automatic generation
const info = reflect(shaderSource);
const entries = info.bindings.map(b => createLayoutEntry(b));
```

- No manual synchronization between shader and JavaScript
- Single source of truth
- Catch mismatches at build time

## Correct Buffer Layout Calculation

WGSL memory layout rules are complex:

| Type | Size | Alignment | Gotcha |
|------|------|-----------|--------|
| `vec3<f32>` | 12 | 16 | 4 bytes padding after |
| `mat3x3<f32>` | 48 | 16 | Each column is vec4-aligned |
| `array<f32, 3>` | 12 | 4 | Stride = element alignment |

Reflection provides exact layout:

```javascript
const info = reflect(source);
// info.bindings[0].layout = {
//   size: 48,
//   alignment: 16,
//   fields: [
//     { name: "time", offset: 0, size: 4 },
//     { name: "resolution", offset: 8, size: 8 },
//     { name: "matrix", offset: 16, size: 64 }
//   ]
// }
```

- Correctly sized buffer allocation
- Exact byte offsets for each field
- No manual calculation errors

## Comparison: Manual vs Reflection

| Aspect | Manual | With Reflection |
|--------|--------|-----------------|
| Buffer sizes | Calculate by hand | Automatic |
| Field offsets | Error-prone | Exact |
| Binding layout | Duplicate in JS | Single source of truth |
| Shader changes | Update JS manually | Automatic sync |
| Type safety | Runtime errors | Build-time checks |

## Dynamic Pipeline Creation

For shader-driven systems:
- Load shaders at runtime without hardcoded layouts
- Support user-provided shaders (shader editors, creative coding tools)
- Hot-reload shaders during development
- Shader variant/permutation systems

## Framework and Engine Development

Engines need reflection to provide:
- High-level material systems
- Automatic resource binding by name
- Abstract away WebGPU boilerplate

```javascript
// Engine can automatically:
// 1. Create bind group layout from shader
// 2. Allocate uniform buffer with correct size
// 3. Provide type-safe setters
material.setUniform("time", 1.5);
material.setUniform("resolution", [1920, 1080]);
```

## Uniform Buffer Management

**Without reflection:**
```javascript
// Hope these match the shader...
const UNIFORM_SIZE = 48;
const TIME_OFFSET = 0;
const RESOLUTION_OFFSET = 8;  // Is vec2 alignment correct?
```

**With reflection:**
```javascript
const layout = reflect(source).bindings[0].layout;
const buffer = device.createBuffer({ size: layout.size, ... });
const timeOffset = layout.fields.find(f => f.name === "time").offset;
// Guaranteed correct
```

## Code Generation

Generate TypeScript interfaces from shaders:

```typescript
// Auto-generated from shader reflection
interface Uniforms {
  time: number;                    // offset: 0, size: 4
  resolution: [number, number];    // offset: 8, size: 8
  modelMatrix: Float32Array;       // offset: 16, size: 64
}
```

## Minification Compatibility

Combined `minifyAndReflect()` provides name mapping:

```javascript
const result = minifyAndReflect(source);
// result.code = minified shader
// result.reflect.bindings[0].name = "uniforms"      // original
// result.reflect.bindings[0].nameMapped = "a"       // in minified code
```

## Entry Point Discovery

For multi-entry shaders:

```javascript
const info = reflect(source);
// info.entryPoints = [
//   { name: "vs_main", stage: "vertex" },
//   { name: "fs_main", stage: "fragment" },
//   { name: "compute_main", stage: "compute", workgroupSize: [8, 8, 1] }
// ]
```

- Discover all entry points automatically
- Get workgroup sizes for compute dispatch
- Automate pipeline creation

## Texture and Sampler Types

Reflection reveals binding types:

```javascript
// info.bindings = [
//   { name: "tex", type: "texture_2d<f32>", ... },
//   { name: "samp", type: "sampler", ... },
//   { name: "storage", type: "texture_storage_2d<rgba8unorm, write>", ... }
// ]
```

Essential for correct bind group layout creation.

## Cross-Platform Consistency

Reflection provides identical results regardless of:
- Browser implementation (Chrome/Firefox/Safari)
- GPU vendor
- Operating system

WGSL spec defines layout rules deterministically.

## Validation Before Runtime

Catch errors before GPU execution:
- Verify buffer sizes match shader expectations
- Check all required bindings are provided
- Validate data types match

## When Reflection is Most Valuable

- Large applications with many shaders
- Frameworks/engines abstracting WebGPU
- Dynamic shader loading at runtime
- Development tools (editors, debuggers)
- Material systems with automatic binding

## When Reflection May Be Overkill

- Simple demos with hardcoded shaders
- Static pipelines that never change
- Performance-critical paths preferring compile-time binding
