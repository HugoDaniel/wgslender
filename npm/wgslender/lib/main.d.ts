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

/** A half-open byte range `[start, end)` into the original source. */
export interface Span {
  start: number;
  end: number;
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
  /**
   * Reparse-stable identifier for this binding. Present when reflection
   * produced an ID; survives reparses that don't move the declaration.
   */
  stableId?: string;
  /**
   * Byte range of the full declaration (attributes through `;`).
   * Present when the span was captured at parse time.
   */
  declSpan?: Span;
  /**
   * Byte range of just the type annotation (e.g., the `Uniforms` in
   * `var<uniform> u: Uniforms;`). Omitted when the declaration has no
   * explicit type.
   */
  typeSpan?: Span;
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
  /** Reparse-stable identifier for this field. */
  stableId?: string;
  /** Byte range of just the member's type annotation. */
  typeSpan?: Span;
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
  /** Reparse-stable identifier for this function symbol. */
  stableId?: string;
  /**
   * Byte range of the full function declaration (leading attributes
   * through the closing `}`).
   */
  declSpan?: Span;
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
 * A byte range in the source with read/write context.
 * All offsets are UTF-8 byte offsets, not UTF-16 code-unit offsets.
 */
export interface Reference {
  /** Byte offset where the reference begins. */
  start: number;
  /** Byte offset one past the last byte of the reference. */
  end: number;
  /** True if the reference is the target of a write (assignment, ++/--, or the declaration site). */
  isWrite: boolean;
}

/**
 * A text edit to apply to the original source.
 * Replace bytes `[start, end)` with `newText`.
 */
export interface TextEdit {
  start: number;
  end: number;
  newText: string;
}

/** Result of findReferences. */
export interface FindReferencesResult {
  references: Reference[];
  /** Present only on parse error. */
  error?: string;
}

/** Result of rename — the edits to apply. Empty edits + error on failure. */
export interface RenameResult {
  edits: TextEdit[];
  /** "parse error" | "symbol not found" | "invalid identifier" on failure. */
  error?: string;
}

/** Result of renameApply — rewritten source plus the edits that produced it. */
export interface RenameApplyResult {
  ok: boolean;
  /** Rewritten source on success, original source on failure. */
  source: string;
  edits: TextEdit[];
  error?: string;
}

/**
 * Find every reference to the symbol under `offset` in `source`.
 * `offset` is a UTF-8 byte offset.
 * If no symbol is under `offset`, returns `{references: []}`.
 */
export function findReferences(
  source: string,
  offset: number,
  includeDeclaration?: boolean
): FindReferencesResult;

/**
 * Compute text edits that rename the symbol under `offset` to `newName`.
 * Returns `{edits: [], error: ...}` if the rename cannot be applied
 * (invalid identifier, symbol not found, parse error).
 */
export function rename(
  source: string,
  offset: number,
  newName: string
): RenameResult;

/**
 * Rename-and-apply: produces the rewritten source plus the edit list.
 * On failure `source` contains the original text so callers can use
 * the return value as a drop-in replacement either way.
 */
export function renameApply(
  source: string,
  offset: number,
  newName: string
): RenameApplyResult;

/** Result of stableIdAtOffset — the ID string, or null if no symbol. */
export interface StableIdResult {
  stableId: string | null;
  /** Present on parse error or if the ID would exceed the max length. */
  error?: string;
}

/** Result of locateStableId — the declaration byte range. */
export interface LocateStableIdResult {
  start: number | null;
  end: number | null;
  error?: string;
}

/**
 * Compute the reparse-stable identifier for the symbol under `offset`.
 * The returned string survives reparses and edits that do not reorder or
 * insert a `.block` scope at or above the symbol's declaration.
 */
export function stableIdAtOffset(source: string, offset: number): StableIdResult;

/**
 * Resolve a stable ID back to the byte range of its declaration in the
 * current source. Returns `{start: null, end: null}` if the ID does not
 * resolve (e.g., the symbol was deleted).
 */
export function locateStableId(source: string, stableId: string): LocateStableIdResult;

/**
 * Rename a symbol identified by stable ID. Same result shape as `rename`.
 */
export function renameByStableId(
  source: string,
  stableId: string,
  newName: string
): RenameResult;

/**
 * Resolve a stable ID to the full declaration span — from the first
 * attribute (if any) through the terminating `;` or `}`. Returns
 * `{start: null, end: null}` for builtins, struct members, parameters,
 * or stale IDs.
 */
export function locateDeclaration(source: string, stableId: string): LocateStableIdResult;

/**
 * Resolve a stable ID to its type-annotation span. Works for:
 *   - struct members (`x: f32` → `f32`)
 *   - function parameters
 *   - function return types (pass the function's stable ID)
 *   - `var` / `const` / `let` / `override` with explicit `: T`
 * Returns `{start: null, end: null}` when the target has no type
 * annotation or does not resolve.
 */
export function locateType(source: string, stableId: string): LocateStableIdResult;

/**
 * Compute a `TextEdit` list that deletes the full declaration identified
 * by `stableId`. Empty `edits` + an `error` field if the target is not a
 * removable declaration (member, parameter, builtin, or unresolved ID).
 */
export function removeDeclarationByStableId(
  source: string,
  stableId: string
): RenameResult;

/**
 * Remove-and-apply by stable ID. Returns the rewritten source plus the
 * edit list. On failure `source` contains the original text so callers
 * can use the return value either way.
 */
export function removeDeclarationApplyByStableId(
  source: string,
  stableId: string
): RenameApplyResult;

/**
 * Replace the type annotation of the symbol identified by `stableId`
 * with `newType` (e.g. `"vec3<f32>"`). Empty `edits` + `error` if the
 * target has no type annotation or `newType` is malformed (empty,
 * multiline, or contains `;`/`{`/`}`).
 */
export function changeTypeByStableId(
  source: string,
  stableId: string,
  newType: string
): RenameResult;

/**
 * Change-type-and-apply by stable ID. Same shape as
 * `removeDeclarationApplyByStableId`.
 */
export function changeTypeApplyByStableId(
  source: string,
  stableId: string,
  newType: string
): RenameApplyResult;

/**
 * Check if the WASM module is initialized.
 */
export function isInitialized(): boolean;

/**
 * Get the version of the minifier.
 */
export const version: string;

// =============================================================================
// Lint
// =============================================================================

/** Severity of a lint rule. */
export type LintSeverity = 'off' | 'warn' | 'error';

/**
 * A per-rule setting. Either a severity string, or a tuple `[severity, opts]`
 * to pass rule-specific options (currently forwarded opaquely to the Zig
 * backend — only a handful of rules read them).
 */
export type RuleSetting = LintSeverity | [LintSeverity, Record<string, unknown>];

/** Options for `lint()` / `lintAndFix()`. */
export interface LintOptions {
  /**
   * Names of built-in configs to inherit rules from.
   * Known values: `@wgslender/recommended`, `@wgslender/style`,
   * `@wgslender/performance`, `@wgslender/portability`, `@wgslender/strict`.
   * Unknown names are silently ignored.
   */
  extends?: string[];

  /**
   * Per-rule severity overrides. Keys are public rule ids
   * (e.g. `"no-unused-vars"`). These take precedence over anything inherited
   * via `extends`.
   */
  rules?: Record<string, RuleSetting>;

  /**
   * Emit a W0209 warning for every `wgslender-disable` directive that never
   * matched a diagnostic.
   * @default false
   */
  reportUnusedDisableDirectives?: boolean;
}

/** A lint diagnostic returned by `lint()`. */
export interface LintDiagnostic {
  severity: 'error' | 'warning' | 'info' | 'note';
  code: string;
  message: string;
  line: number;
  column: number;
  endLine?: number;
  endColumn?: number;
  source?: string;
  specRef?: string;
  fix?: {
    range: {
      startLine: number;
      startColumn: number;
      startOffset: number;
      endLine: number;
      endColumn: number;
      endOffset: number;
    };
    text: string;
  };
}

/** Result of `lint()`. */
export interface LintResult {
  diagnostics: LintDiagnostic[];
  errorCount: number;
  warningCount: number;
}

/** Result of `lintAndFix()`. Extends LintResult with the fixed source. */
export interface LintFixResult extends LintResult {
  fixed: string;
}

/**
 * Lint WGSL source. Returns diagnostics from both the WGSL validator
 * (spec errors) and the lint rules selected by `options.extends` / `rules`.
 */
export function lint(source: string, options?: LintOptions): LintResult;

/**
 * Lint and apply autofixes. Overlapping fixes are dropped; the remaining
 * diagnostics list still includes the skipped ones so a follow-up pass
 * can converge.
 */
export function lintAndFix(source: string, options?: LintOptions): LintFixResult;
