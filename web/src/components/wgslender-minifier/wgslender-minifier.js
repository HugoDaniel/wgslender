// @ts-check
/** @typedef {import("../../types").AppState} AppState */
/** @typedef {import("boredom").InitFunction<AppState | undefined>} InitFunction */
/** @typedef {import("boredom").RenderFunction<AppState | undefined>} RenderFunction */
import { webComponent } from "boredom"
import { minifyShader, presets } from "../../main.js"

const DEBOUNCE_MS = 300
let debounceTimer

export const WgslMinifier = webComponent(
  /** @type {InitFunction} */
  ({ on }) => {
    on("inputChange", ({ state: mutable, e }) => {
      if (!mutable) return

      const target = e.event.target
      if (target instanceof HTMLTextAreaElement) {
        mutable.input = target.value

        clearTimeout(debounceTimer)
        debounceTimer = setTimeout(() => {
          minifyShader(mutable)
        }, DEBOUNCE_MS)
      }
    })

    on("presetChange", ({ state: mutable, e }) => {
      if (!mutable) return

      const target = e.event.target
      if (!(target instanceof HTMLSelectElement)) return

      const presetName = target.value
      const preset = presets[presetName]
      if (!preset) return

      mutable.preset = presetName
      mutable.options.keepNames = [...preset.keepNames]
      mutable.options.mangleExternalBindings = preset.mangleExternalBindings

      minifyShader(mutable)
    })

    on("optionChange", ({ state: mutable, e }) => {
      if (!mutable) return

      const target = e.event.target
      if (!(target instanceof HTMLInputElement)) return

      const name = target.closest("label")?.textContent?.trim().toLowerCase()

      if (name?.includes("whitespace")) {
        mutable.options.minifyWhitespace = target.checked
      } else if (name?.includes("identifiers")) {
        mutable.options.minifyIdentifiers = target.checked
      } else if (name?.includes("syntax")) {
        mutable.options.minifySyntax = target.checked
      } else if (name?.includes("mangle")) {
        mutable.options.mangleExternalBindings = target.checked
      }

      minifyShader(mutable)
    })

    on("copy", async ({ state: mutable, e }) => {
      if (!mutable) return

      try {
        await navigator.clipboard.writeText(mutable.output)
        const btn = e.dispatcher
        if (btn instanceof HTMLButtonElement) {
          const original = btn.textContent
          btn.textContent = "Copied!"
          setTimeout(() => {
            btn.textContent = original
          }, 1500)
        }
      } catch (err) {
        console.error("Failed to copy:", err)
      }
    })

    on("selectOutput", ({ e }) => {
      const target = e.event.target
      if (target instanceof HTMLTextAreaElement) {
        target.select()
      }
    })

    return onRender
  }
)

/** @type {RenderFunction} */
function onRender({ state, refs }) {
  if (!state) return

  const loading = refs.loading
  const content = refs.content
  const error = refs.error
  const stats = refs.stats

  // Loading state
  if (loading instanceof HTMLElement) {
    loading.hidden = !state.isLoading
  }
  if (content instanceof HTMLElement) {
    content.hidden = state.isLoading
  }

  // Input/output
  const input = refs.input
  const output = refs.output
  if (input instanceof HTMLTextAreaElement && input.value !== state.input) {
    input.value = state.input
  }
  if (output instanceof HTMLTextAreaElement) {
    output.value = state.output
  }

  // Error display
  if (error instanceof HTMLElement) {
    error.hidden = !state.error
    error.textContent = state.error || ""
  }

  // Preset dropdown
  const preset = refs.preset
  if (preset instanceof HTMLSelectElement) {
    preset.value = state.preset
  }

  // Options checkboxes
  const whitespace = refs.whitespace
  const identifiers = refs.identifiers
  const syntax = refs.syntax
  const mangle = refs.mangle

  if (whitespace instanceof HTMLInputElement) {
    whitespace.checked = state.options.minifyWhitespace
  }
  if (identifiers instanceof HTMLInputElement) {
    identifiers.checked = state.options.minifyIdentifiers
  }
  if (syntax instanceof HTMLInputElement) {
    syntax.checked = state.options.minifySyntax
  }
  if (mangle instanceof HTMLInputElement) {
    mangle.checked = state.options.mangleExternalBindings
  }

  // Stats
  if (stats instanceof HTMLElement) {
    stats.hidden = !state.stats

    if (state.stats) {
      const original = refs.original
      const minified = refs.minified
      const savings = refs.savings

      if (original instanceof HTMLElement) {
        original.textContent = `Original: ${state.stats.original} bytes`
      }
      if (minified instanceof HTMLElement) {
        minified.textContent = `Minified: ${state.stats.minified} bytes`
      }
      if (savings instanceof HTMLElement) {
        savings.textContent = `Savings: ${state.stats.savings}%`
      }
    }
  }
}
