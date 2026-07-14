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
   * Sort top-level declarations by kind to improve DEFLATE compression of
   * the minified output (5-29% gzip savings on real shaders).
   * `compile()` defaults this to true; `minify()` defaults to false.
   * @default false
   */
  sortDeclarations?: boolean;

  /**
   * Rename function-local symbols using a per-scope counter rather than a
   * global frequency-sorted table, improving DEFLATE compression of the
   * minified output. `compile()` defaults this to true; `minify()` to false.
   * @default false
   */
  scopeLocalRename?: boolean;

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
 * Result of shader reflection. Shape is JSON v2 (see Zig
 * `Reflect.JsonVersion`) — `version` is the schema marker and the
 * `uniforms` / `storage` / `textures` / `samplers` arrays are subset
 * views over `bindings[]`. `aliases[]` lists top-level WGSL
 * `alias T = U;` declarations.
 */
export interface ReflectResult {
  /** JSON schema version. Present in v2 output; absent in v1. */
  version?: 2;
  /** All bindings (the union of all subset views below). */
  bindings: BindingInfo[];
  /** Bindings whose `addressSpace === "uniform"`. (v2 only) */
  uniforms?: BindingInfo[];
  /** Bindings whose `addressSpace === "storage"`. (v2 only) */
  storage?: BindingInfo[];
  /** Bindings whose `typeInfo.kind === "texture"`. (v2 only) */
  textures?: BindingInfo[];
  /** Bindings whose `typeInfo.kind === "sampler"`. (v2 only) */
  samplers?: BindingInfo[];
  /** Struct type layouts keyed by name. */
  structs: Record<string, StructLayout>;
  /** Entry point functions. */
  entryPoints: EntryPointInfo[];
  /** Pipeline-overridable constants (`@id` + override declarations). */
  overrides: OverrideInfo[];
  /** Per-function reflection records (entry points included). */
  functions: FunctionInfo[];
  /** Top-level `alias T = U;` declarations. (v2 only) */
  aliases?: AliasInfo[];
  /** Parse errors, if any. Omitted in successful reflection. */
  errors?: string[];
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
  /** Variable name (post-rename if a renamer was provided). */
  name: string;
  /** Original name, even when `name` was renamed by minification. */
  nameMapped: string;
  /** Byte offset of the declared name in the original source. */
  nameOffset: number;
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
  /** Address space: "uniform", "storage", "handle", or "". */
  addressSpace: string;
  /** Access mode for storage: "read", "write", "read_write", or undefined. */
  accessMode?: string;
  /** Type as a string (e.g., "MyStruct", "texture_2d<f32>"). */
  type: string;
  /** Renamer-mapped form of `type` when minified; equal to `type` otherwise. */
  typeMapped: string;
  /** Memory layout for struct-typed bindings; absent for handle types. */
  layout?: StructLayout;
  /** Array element layout when the binding's type is `array<...>`. */
  array?: ArrayInfo;
  /** Structured type tree mirroring `type`. */
  typeInfo?: TypeInfo;
  /**
   * Names of related bindings — for textures, the samplers paired with
   * them in `textureSample*` calls (and vice versa). Absent when empty.
   */
  relations?: string[];
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
  /** Pre-rename source name (equal to `name` when not minified). */
  nameMapped: string;
  /** Byte offset of the declared field name in the original source. */
  nameOffset: number;
  /** Reparse-stable identifier for this field. */
  stableId?: string;
  /** Byte range of just the member's type annotation. */
  typeSpan?: Span;
  /** Field type as a string */
  type: string;
  /** Renamer-mapped form of `type`. */
  typeMapped: string;
  /** Byte offset from start of struct */
  offset: number;
  /** Size in bytes */
  size: number;
  /** Required alignment in bytes */
  alignment: number;
  /** Nested layout for struct or array-of-struct fields */
  layout?: StructLayout;
  /** Structured type tree mirroring `type`. */
  typeInfo?: TypeInfo;
}

/**
 * Element-layout description for an `array<T, N>` binding.
 */
export interface ArrayInfo {
  /** Array nesting depth (`array<array<T,4>,3>` = 2). */
  depth: number;
  /** Compile-time element count. `null` for runtime-sized arrays. */
  elementCount: number | null;
  /** Per-element stride (host-shareable layout). */
  elementStride: number;
  /** Total array size in bytes. `null` for runtime-sized arrays. */
  totalSize: number | null;
  /** Element type spelled in source. */
  elementType: string;
  /** Renamer-mapped form of `elementType`. */
  elementTypeMapped: string;
  /** Element struct layout when the element is itself a struct. */
  elementLayout?: StructLayout;
  /** Inner array info for nested arrays. */
  nested?: ArrayInfo;
}

/**
 * Information about a shader entry point.
 */
export interface EntryPointInfo {
  /** Function name */
  name: string;
  /** Byte offset of the declared function name. */
  nameOffset: number;
  /** Reparse-stable identifier for this function symbol. */
  stableId?: string;
  /**
   * Byte range of the full function declaration (leading attributes
   * through the closing `}`).
   */
  declSpan?: Span;
  /** Shader stage: "vertex", "fragment", or "compute" */
  stage: string;
  /**
   * Workgroup size [x, y, z] for compute, null otherwise. An axis is
   * `0` when the value is supplied by an `@override` constant — see
   * `overrides[]` for the override names.
   */
  workgroupSize: [number, number, number] | null;
  /**
   * `@override` constants referenced from `@workgroup_size(...)`.
   * Empty unless the entry point's workgroup size is override-driven.
   */
  overrides?: string[];
  /** Per-attribute pipeline inputs (locations / builtins). */
  inputs: InputOutputInfo[];
  /** Per-attribute pipeline outputs. */
  outputs: InputOutputInfo[];
  /** Bindings reachable from this entry point's transitive call graph. */
  resources: string[];
}

/**
 * One pipeline input / output attribute (`@location(N)` or `@builtin`).
 */
export interface InputOutputInfo {
  /** Parameter / struct-member name (empty when attributed at return). */
  name: string;
  /** `@location(N)` value, or null when bound by `@builtin`. */
  location: number | null;
  /** `@builtin(name)` value (e.g. `"position"`); empty otherwise. */
  builtin: string;
  /** `@interpolate(type, sampling)` settings, or null. */
  interpolate: InterpolateInfo | null;
  /** Type spelled in source. */
  type: string;
  /** Structured type tree mirroring `type`. */
  typeInfo?: TypeInfo;
}

export interface InterpolateInfo {
  /** "perspective" | "linear" | "flat". */
  type: string;
  /** "center" | "centroid" | "sample" | "first" | "either" | "". */
  sampling: string;
}

/**
 * `@override` (pipeline-overridable constant) declaration.
 */
export interface OverrideInfo {
  name: string;
  nameMapped: string;
  nameOffset: number;
  stableId?: string;
  declSpan?: Span;
  /** `@id(N)` value, or null for pipeline-name-keyed overrides. */
  id: number | null;
  /** Source-spelled type; empty when the type was inferred. */
  type?: string;
  typeInfo?: TypeInfo;
  /** Default-value expression text from source; empty when omitted. */
  default?: string;
}

/**
 * Per-function reflection record. Includes entry points.
 */
export interface FunctionInfo {
  name: string;
  /** Renamer-mapped form of `name`; absent when no renamer was applied. */
  nameMapped?: string;
  nameOffset: number;
  stableId?: string;
  declSpan?: Span;
  /** Direct callees (user functions only). */
  calls: string[];
  /** Module-scope `var`s referenced directly from this body. */
  directResources: string[];
  /** `@override` constants referenced directly. */
  directOverrides: string[];
  /** Entry-point or transitively reachable from one. */
  inUse: boolean;
}

/**
 * Top-level `alias T = U;` declaration.
 */
export interface AliasInfo {
  name: string;
  nameMapped: string;
  nameOffset: number;
  stableId?: string;
  declSpan?: Span;
  /** Right-hand-side type spelled in source. */
  type: string;
  typeMapped: string;
  typeInfo?: TypeInfo;
}

/**
 * Structured WGSL type description. Mirrors the textual form so
 * consumers can walk a binding's type tree without reparsing.
 */
export type TypeInfo =
  | { kind: "scalar"; name: string; size: number; alignment: number }
  | { kind: "vec"; width: number; format: TypeInfo; size: number; alignment: number }
  | { kind: "mat"; cols: number; rows: number; format: TypeInfo; size: number; alignment: number; stride: number }
  | { kind: "array"; format: TypeInfo; count: number | null; size: number | null; stride: number; alignment: number }
  | { kind: "struct"; name: string; size: number; alignment: number }
  | { kind: "atomic"; format: TypeInfo; size: number; alignment: number }
  | { kind: "texture"; texture: TextureInfo }
  | { kind: "sampler"; comparison: boolean }
  | { kind: "ptr"; addressSpace: string; format: TypeInfo; access: string };

export interface TextureInfo {
  /** "1d" | "2d" | "2d_array" | "3d" | "cube" | "cube_array" | "multisampled_2d" | … */
  dim: string;
  /** "sampled" | "depth" | "external" | "storage" | "multisampled" */
  kind: string;
  /** Texel format for storage textures (e.g. "rgba8unorm"); empty otherwise. */
  format?: string;
  /** Access mode for storage textures: "read" | "write" | "read_write". */
  access?: string;
  /** Sample-type leaf for sampled / multisampled textures (e.g. "f32"). */
  sampleType?: string;
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
 * Options for compiling a WGSL shader to a `.wasm` binary. Forwarded to the
 * minifier pass that runs before BPE compression and codegen.
 *
 * Inherits all `MinifyOptions`. Note: `sortDeclarations` and
 * `scopeLocalRename` default to `true` here (vs. `false` on `minify()`)
 * because they materially improve compression of the embedded BPE payload.
 */
export interface CompileOptions extends MinifyOptions {}

/**
 * Result of a `compile()` call.
 */
export interface CompileResult {
  /** Generated WebAssembly module bytes. Feed to `WebAssembly.instantiate`. */
  wasm: Uint8Array;
  /** Size of the input WGSL source in bytes. */
  originalSize: number;
  /** Size of the generated `.wasm` in bytes. */
  wasmSize: number;
  /**
   * Syntax diagnostics collected during compile; empty on success. Each entry
   * carries a position and code, sharing the same shape as validation
   * diagnostics. A non-empty array means `wasm` is empty (no binary produced).
   */
  errors: DiagnosticInfo[];
}

/**
 * Compile WGSL source to a binary `.wasm` shader. The output module exports
 * a `generate()` function that, when called, writes the (BPE-decompressed)
 * WGSL bytes into the module's linear memory and returns the byte length.
 */
export function compile(source: string, options?: CompileOptions): CompileResult;

/**
 * Reflect WGSL source to extract binding and struct information.
 * @param source - WGSL source code to analyze
 * @returns Reflection result with bindings, structs, entryPoints, and errors
 */
export function reflect(source: string): ReflectResult;

/**
 * Pivot `bindings[]` into a `{[group]: {[binding]: BindingInfo}}` grid
 * keyed by integer group / binding indices. Holes are left undefined.
 *
 * Pure helper — no WASM dependency. Accepts either `BindingInfo[]`
 * directly or a full `ReflectResult`.
 */
export function getBindGroups(
  bindingsOrResult: ReflectResult | BindingInfo[],
): Record<number, Record<number, BindingInfo>>;

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
  /** Number of diagnostics that carry an autofix (ESLint-style). */
  fixableCount: number;
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
