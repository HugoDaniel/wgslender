# Why Pre-Validate WGSL Shaders?

## Shift-Left Error Detection

Without pre-validation, errors only surface when `device.createShaderModule()` runs in the browser. Pre-validation catches them earlier:

| Stage | Without Pre-validation | With Pre-validation |
|-------|----------------------|---------------------|
| Development | Errors at runtime | Instant feedback |
| Build | No validation | Fail fast |
| CI/CD | Requires GPU | CPU-only checks |
| Production | User sees error | Never deploys |

## Better Error Messages

Browser implementations provide basic error messages that vary across platforms:

```
// Chrome/Dawn error
Shader compilation failed: :4:12 error: return statement type must match...

// Pre-validation error (richer context)
4:12: error [E0200]: cannot return 'vec3f' from function returning 'vec4f'
  spec: https://www.w3.org/TR/WGSL/#return-statement
```

Pre-validation provides:
- Precise line and column numbers
- Error codes for documentation lookup
- WGSL spec references
- Consistent format across environments

## CI/CD Integration

Automated quality gates without GPU hardware:

```yaml
# GitHub Actions - no GPU needed
- name: Validate shaders
  run: wgslender validate --strict shaders/*.wgsl
```

- Fail builds on shader errors
- Catch regressions in pull requests
- Run on standard CI runners (no GPU instances)

## Cross-Browser Consistency

| Browser | Implementation | Validation Strictness |
|---------|---------------|----------------------|
| Chrome | Dawn | Varies |
| Firefox | wgpu | Varies |
| Safari | WebKit | Varies |

Pre-validation ensures consistent behavior regardless of which browser runs the shader.

## Offline / GPU-less Development

- Validate on servers without GPUs
- Work in environments without WebGPU support
- Validate in Node.js build scripts
- Essential for shader generation systems

## Configurable Strictness

```javascript
validate(source, {
  strictMode: true,  // Treat warnings as errors
  diagnosticFilters: {
    derivative_uniformity: "error"  // Upgrade to error
  }
});
```

- Enforce stricter standards than the spec requires
- Disable noisy warnings for specific projects
- Gradual adoption (start lenient, tighten over time)

## Faster Development Iteration

**Without pre-validation:**
1. Write shader
2. Save, rebuild app
3. Wait for browser/WebGPU init
4. See error
5. Repeat

**With pre-validation:**
1. Write shader
2. Instant validation
3. Only run app when valid

## Semantic Analysis Depth

Pre-validation catches more than syntax errors:

| Check | Example |
|-------|---------|
| Type mismatches | `var x: f32 = 1;` (1 is `i32`) |
| Undefined symbols | Using variable before declaration |
| Invalid operations | `vec3f + mat4x4f` |
| Entry point issues | Missing `@builtin(position)` return |
| Uniformity violations | `textureSample` in non-uniform flow |

## Defense in Depth

- Extra validation layer before GPU driver
- Malformed shaders have historically caused driver bugs
- Reduces attack surface in security-sensitive applications

## Build Tool Integration

Enables:
- Webpack/Vite plugins with validation on save
- IDE extensions with real-time error highlighting
- Pre-commit hooks blocking invalid shaders
- Watch mode for continuous validation

## When Pre-validation Matters Most

- Large projects with many shaders
- Team environments needing consistent tooling
- CI/CD pipelines requiring automated checks
- Shader generators creating WGSL programmatically
- Cross-platform apps targeting multiple browsers

## When Runtime-Only May Suffice

- Quick prototypes with 1-2 shaders
- Exploratory coding where speed > safety
- Shaders that rarely change after initial development
