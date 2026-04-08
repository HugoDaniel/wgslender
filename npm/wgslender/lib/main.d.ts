/**
 * Options for WGSL minification.
 */
export interface MinifyOptions {
  /**
   * Remove unnecessary whitespace and newlines.
   * @default true
   */
  minifyWhitespace?: boolean;

  /**
   * Rename identifiers to shorter names.
   * Entry points and API-facing declarations are preserved.
   * @default true
   */
  minifyIdentifiers?: boolean;

  /**
   * Apply syntax-level optimizations (numeric literals, etc).
   * @default true
   */
  minifySyntax?: boolean;

  /**
   * Rename uniform/storage variable declarations directly.
   * When false (default), original names are preserved and short aliases are used.
   * Set to true only if you don't use WebGPU's binding reflection APIs.
   * @default false
   */
  mangleExternalBindings?: boolean;

  /**
   * Enable dead code elimination to remove unused declarations.
   * @default true
   */
  treeShaking?: boolean;

  /**
   * Automatically preserve struct type names that are used in
   * var<uniform> or var<storage> declarations.
   * Useful for frameworks that detect uniforms by struct type name.
   * @default false
   */
  preserveUniformStructTypes?: boolean;

  /**
   * Identifier names that should not be renamed.
   */
  keepNames?: string[];

  /**
   * Generate a source map for the minified output.
   * @default false
   */
  sourceMap?: boolean;

  /**
   * Include original source content in the source map.
   * Only used when sourceMap is true.
   * @default false
   */
  sourceMapSources?: boolean;
}

/**
 * Error information from minification.
 */
export interface MinifyError {
  /** Error message */
  message: string;
  /** Line number (1-indexed, 0 if unknown) */
  line: number;
  /** Column number (1-indexed, 0 if unknown) */
  column: number;
}

/**
 * Result of minification.
 */
export interface MinifyResult {
  /** Minified WGSL code */
  code: string;
  /** Errors encountered during minification */
  errors: MinifyError[];
  /** Size of input in bytes */
  originalSize: number;
  /** Size of output in bytes */
  minifiedSize: number;
  /** Source map JSON object (only present when sourceMap option is true) */
  sourceMap?: object;
}

/**
 * Result of shader reflection.
 */
export interface ReflectResult {
  /** Binding declarations (@group/@binding variables) */
  bindings: BindingInfo[];
  /** Struct type layouts */
  structs: Record<string, StructLayout>;
  /** Entry point functions */
  entryPoints: EntryPointInfo[];
  /** Parse errors, if any */
  errors: string[];
}

/**
 * Information about a binding variable.
 */
export interface BindingInfo {
  /** Binding group index from @group(n) */
  group: number;
  /** Binding index from @binding(n) */
  binding: number;
  /** Variable name */
  name: string;
  /** Address space: "uniform", "storage", "handle", or "" */
  addressSpace: string;
  /** Access mode for storage: "read", "write", "read_write", or undefined */
  accessMode?: string;
  /** Type as a string (e.g., "MyStruct", "texture_2d<f32>") */
  type: string;
  /** Memory layout for struct types, null for textures/samplers */
  layout: StructLayout | null;
}

/**
 * Memory layout of a struct type.
 */
export interface StructLayout {
  /** Total size in bytes */
  size: number;
  /** Required alignment in bytes */
  alignment: number;
  /** Field layouts */
  fields: FieldInfo[];
}

/**
 * Layout information for a struct field.
 */
export interface FieldInfo {
  /** Field name */
  name: string;
  /** Field type as a string */
  type: string;
  /** Byte offset from start of struct */
  offset: number;
  /** Size in bytes */
  size: number;
  /** Required alignment in bytes */
  alignment: number;
  /** Nested layout for struct or array-of-struct fields */
  layout?: StructLayout;
}

/**
 * Information about a shader entry point.
 */
export interface EntryPointInfo {
  /** Function name */
  name: string;
  /** Shader stage: "vertex", "fragment", or "compute" */
  stage: string;
  /** Workgroup size [x, y, z] for compute, null otherwise */
  workgroupSize: [number, number, number] | null;
}

/**
 * Options for WGSL validation.
 */
export interface ValidateOptions {
  /**
   * Treat warnings as errors.
   * @default false
   */
  strictMode?: boolean;

  /**
   * Map of diagnostic rule names to their severity override.
   * Rules: "derivative_uniformity", "subgroup_uniformity"
   * Severities: "error", "warning", "info", "off"
   */
  diagnosticFilters?: Record<string, "error" | "warning" | "info" | "off">;
}

/**
 * A single validation diagnostic message.
 */
export interface DiagnosticInfo {
  /** Severity: "error", "warning", "info", or "note" */
  severity: "error" | "warning" | "info" | "note";
  /** Error code (e.g., "E0200" for type mismatch) */
  code?: string;
  /** Human-readable error message */
  message: string;
  /** Line number (1-based) */
  line: number;
  /** Column number (1-based) */
  column: number;
  /** End line number (1-based), if available */
  endLine?: number;
  /** End column number (1-based), if available */
  endColumn?: number;
  /** Reference to WGSL spec section */
  specRef?: string;
}

/**
 * Result of WGSL validation.
 */
export interface ValidateResult {
  /** Whether the shader is valid (no errors) */
  valid: boolean;
  /** All validation diagnostics */
  diagnostics: DiagnosticInfo[];
  /** Number of error-level diagnostics */
  errorCount: number;
  /** Number of warning-level diagnostics */
  warningCount: number;
}

/**
 * Options for initializing the WASM module.
 */
export interface InitializeOptions {
  /**
   * URL or path to the wgslender.wasm file.
   * Required unless wasmModule is provided.
   */
  wasmURL?: string | URL;

  /**
   * Pre-compiled WebAssembly.Module.
   * Use this to share a module across multiple instances.
   */
  wasmModule?: WebAssembly.Module;
}

/**
 * Initialize the WASM module. Must be called before minify().
 * @param options - Initialization options
 */
export function initialize(options: InitializeOptions): Promise<void>;

/**
 * Minify WGSL source code.
 * @param source - WGSL source code to minify
 * @param options - Minification options (defaults to full minification)
 * @returns Minification result
 */
export function minify(source: string, options?: MinifyOptions): MinifyResult;

/**
 * Reflect WGSL source to extract binding and struct information.
 * @param source - WGSL source code to analyze
 * @returns Reflection result with bindings, structs, entryPoints, and errors
 */
export function reflect(source: string): ReflectResult;

/**
 * Validate WGSL source code for errors and warnings.
 * Performs full semantic validation compatible with the Dawn Tint compiler.
 * @param source - WGSL source code to validate
 * @param options - Validation options
 * @returns Validation result with valid flag, diagnostics, and counts
 */
export function validate(source: string, options?: ValidateOptions): ValidateResult;

/**
 * Check if the WASM module is initialized.
 */
export function isInitialized(): boolean;

/**
 * Get the version of the minifier.
 */
export const version: string;
