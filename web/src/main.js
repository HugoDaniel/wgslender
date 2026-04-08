/** @typedef {import("./types").AppState} AppState */
import { inflictBoreDOM } from "boredom"

const runtimeAttr = Symbol("runtime")

/** @type {Record<string, { keepNames: string[], mangleExternalBindings: boolean }>} */
export const presets = {
  default: {
    keepNames: [],
    mangleExternalBindings: false,
  },
  "compute.toys": {
    keepNames: [
      "time", "mouse", "custom", "dispatch", "screen", "pass_in", "pass_out",
      "channel0", "channel1", "nearest", "bilinear", "trilinear",
      "nearest_repeat", "bilinear_repeat", "trilinear_repeat", "_keyboard",
      "Time", "Mouse", "Custom", "DispatchInfo",
      "int", "uint", "float",
      "int2", "int3", "int4", "uint2", "uint3", "uint4",
      "float2", "float3", "float4", "bool2", "bool3", "bool4",
      "float2x2", "float2x3", "float2x4", "float3x2", "float3x3", "float3x4",
      "float4x2", "float4x3", "float4x4",
      "keyDown", "assert", "passStore", "passLoad",
      "passSampleLevelBilinearRepeat", "main_image",
    ],
    mangleExternalBindings: false,
  },
}

/** @type {AppState} */
const initialState = {
  input: `// Example WGSL shader
@group(0) @binding(0) var<uniform> uniforms: Uniforms;

struct Uniforms {
    resolution: vec2f,
    time: f32,
}

fn computeColor(uv: vec2f) -> vec4f {
    let color = vec3f(uv, sin(uniforms.time) * 0.5 + 0.5);
    return vec4f(color, 1.0);
}

@fragment
fn main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
    let uv = pos.xy / uniforms.resolution;
    return computeColor(uv);
}`,
  output: "",
  isLoading: true,
  isMinifying: false,
  error: null,
  stats: null,
  preset: "default",
  options: {
    minifyWhitespace: true,
    minifyIdentifiers: true,
    minifySyntax: true,
    mangleExternalBindings: false,
    keepNames: [],
  },
  [runtimeAttr]: {
    wasm: null,
  },
}

export { runtimeAttr }

async function loadWasm() {
  const script = document.createElement("script")
  script.src = "./wasm_exec.js"
  document.head.appendChild(script)

  await new Promise((resolve, reject) => {
    script.onload = resolve
    script.onerror = reject
  })

  const go = new Go()
  const response = await fetch("./wgslender.wasm")
  const wasmBuffer = await response.arrayBuffer()
  const result = await WebAssembly.instantiate(wasmBuffer, go.importObject)

  // Start Go runtime (returns a Promise that resolves when Go exits)
  go.run(result.instance)

  // Wait for Go to set up __wgslender (poll instead of fixed timeout)
  for (let i = 0; i < 50; i++) {
    if (globalThis.__wgslender) {
      return globalThis.__wgslender
    }
    await new Promise(resolve => setTimeout(resolve, 10))
  }

  throw new Error("WASM initialization failed: __wgslender not set")
}

window.addEventListener("DOMContentLoaded", async () => {
  const state = await inflictBoreDOM(initialState)

  try {
    const wasm = await loadWasm()
    state[runtimeAttr].wasm = wasm
    state.isLoading = false

    // Initial minification
    minifyShader(state)
  } catch (err) {
    state.error = `Failed to load WASM: ${err.message}`
    state.isLoading = false
  }
})

/** @param {AppState} state */
export function minifyShader(state) {
  const wasm = state[runtimeAttr].wasm
  if (!wasm || state.isMinifying) return

  state.isMinifying = true
  state.error = null

  // Use setTimeout to avoid blocking the UI and allow state to update
  setTimeout(() => {
    try {
      const result = wasm.minify(state.input, state.options)

      if (result.errors && result.errors.length > 0) {
        state.error = result.errors.map(e => e.message).join("\n")
        state.output = ""
        state.stats = null
      } else {
        state.output = result.code
        state.stats = {
          original: result.originalSize,
          minified: result.minifiedSize,
          savings: Math.round((1 - result.minifiedSize / result.originalSize) * 100),
        }
      }
    } catch (err) {
      state.error = err.message || "Minification failed"
      state.output = ""
      state.stats = null
    }

    state.isMinifying = false
  }, 0)
}
