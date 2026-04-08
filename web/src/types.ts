export type AppState = {
  input: string
  output: string
  isLoading: boolean
  isMinifying: boolean
  error: string | null
  stats: {
    original: number
    minified: number
    savings: number
  } | null
  preset: string
  options: {
    minifyWhitespace: boolean
    minifyIdentifiers: boolean
    minifySyntax: boolean
    mangleExternalBindings: boolean
    keepNames: string[]
  }
  [key: symbol]: {
    wasm: any
  }
}
