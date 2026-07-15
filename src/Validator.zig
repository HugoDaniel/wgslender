//! WGSL semantic validator.
//!
//! Performs type checking, symbol resolution validation, control flow analysis,
//! and uniformity analysis to ensure shaders conform to the WGSL specification.
//!
//! Validation runs a fixed, ordered phase sequence, extracted into
//! `runPhases` so `validate` (diagnostics only) and `analyze` (retains
//! semantic state for the LSP) cannot drift:
//!   0.   processDirectives          — enable / diagnostic directives
//!   0.5  checkReservedIdentifiers    — reject `_` alone, `__`-prefixed
//!   1.   collectTypeDeclarations     — gather struct and alias names
//!   1.5  resolveAliasTypes           — order-independent alias forward refs
//!   2.   resolveStructLayouts        — resolve fields, compute layouts
//!   2.5  checkRecursiveStructs        — reject recursive struct definitions
//!   3.   validateDeclarations        — const/override/var/let decls
//!   3.5  registerFunctionSignatures   — enable forward references
//!   3.75 checkRecursiveFunctions      — reject recursion (WGSL forbids it)
//!   4.   validateFunctions           — functions, statements, expressions
//!   4.5  validatePerEntryPointBindings + checkSuspiciousBindingPatterns
//!   5.   analyzeUniformity           — non-uniform control flow (E0700–E0703)
//!   6.   detectShadowing             — scope-tree shadow detection (W0100)
//!   7.   checkOperatorPrecedence     — ambiguous precedence combos (E0213)
//! then `diags.deduplicate()` collapses overlaps.
//!
//! Invariants:
//!   - The input `Module` is a parsed root: `module.scope.parent == null`,
//!     `module.source.len < maxInt(u32)`. Asserted on entry to `validate`
//!     and `analyze`.
//!   - `expr_depth` and `stmt_depth` return to zero before either entry
//!     point returns. Asserted on the way out so a missing `defer` in a
//!     deeply nested check path surfaces immediately.
//!   - Diagnostic byte offsets index into the same `module.source` the
//!     parser used; the validator never re-tokenizes.
//!   - Both entry points call `runPhases` — the single orchestrator — so the
//!     sequence is identical by construction, not by convention. `analyze`
//!     retains semantic state for the LSP; `validate` returns only diagnostics.

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("Ast.zig");
const Types = @import("Types.zig");
const Builtins = @import("Builtins.zig");
const Overload = @import("Overload.zig");
const Diagnostic = @import("Diagnostic.zig");
const Suggest = @import("Suggest.zig");
const Predeclared = @import("Predeclared.zig");
const Dce = @import("Dce.zig");
const Liveness = @import("Liveness.zig");
const UseCounts = @import("UseCounts.zig");
const ConstEval = @import("ConstEval.zig");
const Allocator = std.mem.Allocator;

const Validator = @This();

/// Name and source location pair, used for duplicate-detection maps.
pub const LocName = struct { name: []const u8, loc: u32 };

pub const BindingInfo = struct {
    name: []const u8,
    loc: u32,
    group: u32,
    binding: u32,
    sym_idx: u32,
};

// =========================================================================
// Public Types
// =========================================================================

/// Shader pipeline stage.
pub const ShaderStage = enum(u8) {
    none,
    vertex,
    fragment,
    compute,

    pub fn string(self: ShaderStage) []const u8 {
        return switch (self) {
            .vertex => "vertex",
            .fragment => "fragment",
            .compute => "compute",
            .none => "none",
        };
    }
};

/// Controls validation behaviour.
pub const Options = struct {
    /// StrictMode treats warnings as errors.
    strict_mode: bool = false,
    /// DiagnosticFilters control which diagnostics are reported.
    diagnostic_filters: ?*Diagnostic.DiagnosticFilter = null,
    /// Added to all reported line numbers. Useful when validating a
    /// snippet extracted from a larger file. May be negative.
    line_offset: i32 = 0,
};

/// Validation result.
pub const Result = struct {
    /// True iff no `.error`-severity diagnostic was emitted. Warnings alone
    /// still report `valid = true` unless `Options.strict_mode` was set.
    valid: bool,
    /// All diagnostics produced by this run, in emission (roughly source)
    /// order. Lifetime is tied to the internal arena owned by this Result.
    diagnostics: *Diagnostic,
    _arena: ?std.heap.ArenaAllocator = null,

    /// Free all memory owned by this result. After calling deinit,
    /// the diagnostics pointer is invalid.
    pub fn deinit(self: *Result) void {
        var arena = self._arena orelse return;
        arena.deinit();
        self._arena = null;
    }
};

/// Enriched analysis result that retains the validator's semantic state.
/// Used by the LSP to power features like hover, go-to-definition, etc.
/// Type information for an expression, keyed by the expression's start offset.
pub const ExprTypeInfo = struct {
    typ: Types.Type,
    end_offset: u32,
};

/// Per-var declaration metadata: records the address-space / access-mode of
/// each `var` symbol so that `&v` can produce a pointer whose AS/AM matches
/// the variable's actual storage class (not a hardcoded default).
pub const VarInfo = struct {
    address_space: Ast.AddressSpace,
    access_mode: Ast.AccessMode,
};

/// Expression evaluation stage per WGSL spec sections 6.7-6.9.
pub const ExprStage = enum(u2) {
    const_expr, // Evaluable at shader creation time from const declarations
    override_expr, // Evaluable at pipeline creation time (references overrides)
    runtime_expr, // Only evaluable at runtime

    pub fn combine(a: ExprStage, b: ExprStage) ExprStage {
        return @enumFromInt(@max(@intFromEnum(a), @intFromEnum(b)));
    }
};

/// Type + staging classification inferred for an expression in a single
/// traversal. `typ == null` signals inference failure (diagnostic already
/// emitted); `stage` is still populated conservatively so downstream
/// staging checks don't misreport. Callers that only care about type do
/// `(try v.checkExpr(e)).typ`; callers that need staging use `.stage`.
pub const InferResult = struct {
    typ: ?Types.Type,
    stage: ExprStage,

    pub const fail: InferResult = .{ .typ = null, .stage = .runtime_expr };

    pub fn some(t: Types.Type, s: ExprStage) InferResult {
        return .{ .typ = t, .stage = s };
    }
};

/// Top-down type expectation threaded into expression inference.
///
/// Driving the cached `expr_types` entries with the *materialized* view (what
/// the surrounding context asks for) instead of the raw bottom-up inference
/// fixes LSP hovers inside typed contexts: in `let v: f32 = 1 + 2` the binary
/// expression records `f32`, not `abstract-int`. The materialization only
/// kicks in when the inferred type is abstract and convertible to the target
/// — concrete mismatches remain errors that the decl validator still reports.
///
/// The union is open-ended by design: Stage 2 only wires `.none` / `.exact`;
/// `.integer_scalar` (shift RHS, array index) and `.concrete` (runtime slots)
/// are reserved for later stages.
pub const Expectation = union(enum) {
    none,
    exact: Types.Type,
    /// The value must be a scalar integer (`i32`, `u32`, or `abstract-int`).
    /// Vectors / floats / bools / composites are rejected at the inference
    /// site with E0200. Abstract-int is accepted as-is — callers that need a
    /// specific concrete type (e.g. shift RHS requires `u32`) narrow after
    /// the subtree returns.
    integer_scalar,
    /// The value will land in a runtime slot (unannotated `let` / `var` /
    /// function-scope `const`). Abstract values materialize to their default
    /// concrete form (`abstract-int`→`i32`, `abstract-float`→`f32`) in the
    /// `expr_types` cache; no errors ever emitted.
    concrete,
};

/// Controls whether an abstract-typed initializer is concretized at decl
/// time. WGSL §6.6 keeps abstract typing for module-scope `const`; §15 demotes
/// function-scope `const` to concrete. Call sites pick the rule they want.
pub const AbstractHandling = enum { keep, concretize };

pub const AnalysisResult = struct {
    /// True iff validation surfaced no errors (same semantics as `Result.valid`).
    valid: bool,
    /// All diagnostics produced during analysis. Lifetime = this result's arena.
    diagnostics: *Diagnostic,
    /// The parsed AST module. Null only when parsing failed entirely.
    module: ?*Ast.Module = null,
    /// `SymbolIndex` → resolved type. Populated for every declared symbol
    /// that survived inference. Used by LSP hover and go-to-definition.
    symbol_types: std.AutoHashMapUnmanaged(u32, Types.Type) = .{},
    /// struct name → layout-resolved type. Keys are declaration-time names
    /// (pre-rename). Cycles / unresolved nesting are stored as null-body types.
    struct_types: std.StringHashMapUnmanaged(*Types.Struct) = .{},
    /// `alias X = T;` mapping. Null value means the alias target failed to
    /// resolve; the key is still present so references don't spuriously
    /// report "unknown identifier".
    alias_types: std.StringHashMapUnmanaged(?Types.Type) = .{},
    /// `SymbolIndex` → folded integer value for const-evaluable expressions.
    /// Used by `@workgroup_size` / array-length / `const_assert` validation.
    const_values: std.AutoHashMapUnmanaged(u32, i64) = .{},
    /// Byte-offset of expression start → type + end-offset. Populated on the
    /// fly during the checkExpr walk; read by LSP hover and inlay hints.
    expr_types: std.AutoHashMapUnmanaged(u32, ExprTypeInfo) = .{},
    /// Per-symbol use counts. After B.M5 this is a flat reference to
    /// `module.use_counts` — no separate snapshot.
    use_counts: UseCounts = .{ .counts = &.{} },
    /// Per-symbol liveness bits. Null when DCE has not yet run for
    /// this analysis. Populated lazily by the Linter (when an enabled
    /// rule sets `requires_dce`) and by callers like the LSP that
    /// explicitly drive DCE before reading.
    liveness: ?Liveness = null,
    _arena: ?std.heap.ArenaAllocator = null,

    /// Free all memory owned by this result.
    pub fn deinit(self: *AnalysisResult) void {
        var arena = self._arena orelse return;
        arena.deinit();
        self._arena = null;
    }

    /// Reference count for `Symbol[sym_idx]`. Out-of-range indices return
    /// zero — matches the side-table's silent-no-op semantics on
    /// never-counted symbols.
    pub fn useCount(self: *const AnalysisResult, sym_idx: u32) u32 {
        if (sym_idx >= self.use_counts.counts.len) return 0;
        return self.use_counts.counts[sym_idx];
    }

    /// True iff `Symbol[sym_idx]` should fire `W0001` (declared but never
    /// used). Single source of truth shared by the LSP
    /// `appendUnusedWarnings` pass and the `no-unused-vars` lint rule so
    /// the two surfaces can never disagree on what counts as unused.
    /// Skips parameters because function signatures are typically part of
    /// an external contract the author can't change.
    pub fn isUnusedReportable(self: *const AnalysisResult, sym_idx: u32) bool {
        const module = self.module orelse return false;
        if (sym_idx >= module.symbols.items.len) return false;
        const sym = module.symbols.items[sym_idx];
        if (self.useCount(sym_idx) > 0) return false;
        if (sym.original_name.len == 0) return false;
        if (sym.flags.is_entry_point) return false;
        if (sym.flags.is_api_facing) return false;
        if (sym.flags.is_external_binding) return false;
        return switch (sym.kind) {
            .function, .@"const", .let, .@"var", .override => true,
            else => false,
        };
    }

    /// True iff `Symbol[sym_idx]` should fire `W0003` (unused
    /// `@group/@binding`). Shared by the LSP `appendUnusedBindingWarnings`
    /// pass and the `no-unused-binding` lint rule.
    pub fn isUnusedBindingReportable(self: *const AnalysisResult, sym_idx: u32) bool {
        const module = self.module orelse return false;
        if (sym_idx >= module.symbols.items.len) return false;
        const sym = module.symbols.items[sym_idx];
        if (!sym.flags.is_external_binding) return false;
        if (self.useCount(sym_idx) > 0) return false;
        if (sym.original_name.len == 0) return false;
        return true;
    }

    /// True iff the module declares at least one entry-point symbol.
    /// Dead-code analysis is meaningless without one — DCE conservatively
    /// marks every symbol live in library mode — so both the LSP
    /// `appendDeadCodeWarnings` pass and the `no-dead-code` lint rule gate
    /// on this before scanning for `W0002`.
    pub fn hasEntryPoints(self: *const AnalysisResult) bool {
        const module = self.module orelse return false;
        for (module.symbols.items) |sym| {
            if (sym.flags.is_entry_point) return true;
        }
        return false;
    }

    /// True iff `Symbol[sym_idx]` should fire `W0002` (referenced by other
    /// declarations but unreachable from any entry point). Shared base
    /// filter for the LSP `appendDeadCodeWarnings` hint pass and the
    /// `no-dead-code` lint rule.
    ///
    /// Requires liveness (DCE) to have run: without it, dead can't be told
    /// from live, so this conservatively returns false. Callers gate on
    /// `hasEntryPoints()` first — in library mode DCE marks everything live,
    /// so this would return false for all symbols anyway, but the explicit
    /// gate documents intent and short-circuits the scan. The `no-dead-code`
    /// rule layers an extra enclosing-function suppression on top of this
    /// predicate; the LSP hint pass does not, by design.
    pub fn isDeadCodeReportable(self: *const AnalysisResult, sym_idx: u32) bool {
        const module = self.module orelse return false;
        if (sym_idx >= module.symbols.items.len) return false;
        const sym = module.symbols.items[sym_idx];
        const liv = self.liveness orelse return false;
        if (liv.isLive(sym_idx)) return false;
        // use_count == 0 is W0001's territory (never referenced at all).
        if (self.useCount(sym_idx) == 0) return false;
        if (sym.original_name.len == 0) return false;
        if (sym.flags.is_entry_point) return false;
        if (sym.flags.is_external_binding) return false;
        return switch (sym.kind) {
            .function, .@"struct", .@"const", .let, .@"var", .override => true,
            else => false,
        };
    }
};

/// Per-function cursor state — the mutable position of the walk inside the
/// function currently being validated. `Statements.validateFunction` resets
/// this at each function entry (WGSL functions don't nest); the loop/switch
/// validators save and restore *individual* fields around nested constructs.
///
/// The grouping is namespacing only: never snapshot and restore the whole
/// struct. `has_return` must persist across nested blocks (set deep in a
/// branch, read at function end), so a whole-struct restore would silently
/// revert it and break missing-return diagnostics.
///
/// `expr_depth`/`stmt_depth` are the exception to "per-function": they are
/// balanced by `defer` across the *entire* walk and asserted 0 at `runPhases`
/// exit. They are not per-function state and must never be zeroed by the
/// per-function reset (doing so would mask an imbalance the asserts exist to
/// catch).
const FnContext = struct {
    current_func: ?*Ast.FunctionDecl = null,
    current_stage: ShaderStage = .none,
    in_loop: bool = false,
    in_switch: bool = false,
    in_continuing: bool = false,
    /// True when a plain `break` at the current position would exit the loop whose
    /// `continuing` block encloses it — i.e. we are lexically inside a continuing
    /// block with no intervening nested loop/switch/for/while (which would re-target
    /// the break to itself). Distinct from `in_continuing`, which the
    /// nesting-insensitive `return`-in-continuing rule uses: a nested break-target
    /// body clears this flag while `in_continuing` stays set.
    break_exits_continuing: bool = false,
    return_type: ?Types.Type = null,
    has_return: bool = false,
    expr_depth: u32 = 0,
    stmt_depth: u32 = 0,
};

// =========================================================================
// Validator State
// =========================================================================

arena: Allocator,
module: *Ast.Module,
diags: *Diagnostic,
options: Options,

// Current function context (see `FnContext`).
fn_ctx: FnContext = .{},

// Symbol type cache: maps SymbolIndex -> resolved Types.Type
symbol_types: std.AutoHashMapUnmanaged(u32, Types.Type) = .{},

// Struct type cache: maps name -> resolved struct type
struct_types: std.StringHashMapUnmanaged(*Types.Struct) = .{},

// Alias type cache: maps name -> resolved type (null = placeholder)
alias_types: std.StringHashMapUnmanaged(?Types.Type) = .{},

// Expression type cache: maps expression start offset -> type info
expr_types: std.AutoHashMapUnmanaged(u32, ExprTypeInfo) = .{},

// Override ID tracking for uniqueness validation
override_ids: std.AutoHashMapUnmanaged(u32, LocName) = .{},
// Binding pair tracking for uniqueness validation: key = (group << 32) | binding
binding_pairs: std.AutoHashMapUnmanaged(u64, LocName) = .{},

// Binding info collection for suspicious pattern analysis and per-entry-point validation
binding_infos: std.ArrayList(BindingInfo) = .empty,

// True when module has >= 2 entry points (per-entry-point binding validation needed)
multi_entry_point: bool = false,

// Const value propagation: maps SymbolIndex raw u32 -> evaluated integer value
const_values: std.AutoHashMapUnmanaged(u32, i64) = .{},

// Enabled features from 'enable' directives
enabled_features: std.StringHashMapUnmanaged(void) = .{},

// Per-var declaration metadata: populated during validateVarDecl. See
// `VarInfo` above for details on what's recorded and why.
var_info: std.AutoHashMapUnmanaged(u32, VarInfo) = .{},

// =========================================================================
// Public API
// =========================================================================

/// Validate a parsed WGSL module.
pub fn validate(arena: Allocator, module: *Ast.Module, options: Options) !Result {
    // Pre: module came from a parse — its scope tree must be
    // rooted, and the source slice is what diagnostics will index into.
    std.debug.assert(module.scope.parent == null);
    std.debug.assert(module.source.len < std.math.maxInt(u32));

    const diags = try arena.create(Diagnostic);
    diags.* = try Diagnostic.init(arena, module.source);
    diags.line_offset = options.line_offset;

    var v = Validator{
        .arena = arena,
        .module = module,
        .diags = diags,
        .options = options,
    };

    try runPhases(&v);

    return .{
        .valid = !diags.hasErrors(),
        .diagnostics = diags,
    };
}

/// The fixed validation phase sequence, run by both `validate` and `analyze`
/// so a newly added phase can never land on only one entry point (CLI vs
/// LSP). Order is load-bearing — later phases read state seeded by earlier
/// ones — so this is a deliberate straight-line sequence, not a data-driven
/// `Pipeline.Pass` table: the phases are fixed and non-composable, and a
/// list would add machinery for zero flexibility.
fn runPhases(v: *Validator) !void {
    // Pre-scan: detect multiple entry points for per-entry-point binding validation
    v.multi_entry_point = countEntryPoints(v.module) >= 2;

    // Phase 0: Process directives (enable, diagnostic)
    try v.processDirectives();

    // Phase 0.5: Reject reserved identifiers (WGSL spec: `_` alone, `__`-prefixed)
    v.checkReservedIdentifiers();

    // Phase 1: Collect type declarations (structs, aliases)
    try v.collectTypeDeclarations();

    // Phase 1.5: Resolve type aliases (order-independent forward refs)
    try v.resolveAliasTypes();

    // Phase 2: Resolve struct layouts
    try v.resolveStructLayouts();

    // Phase 2.5: Detect recursive struct definitions
    try v.checkRecursiveStructs();

    // Phase 3: Validate declarations
    try v.validateDeclarations();

    // Phase 3.5: Register function signatures (enables forward references)
    try v.registerFunctionSignatures();

    // Phase 3.75: Detect recursive function calls
    try v.checkRecursiveFunctions();

    // Phase 4: Validate functions and statements
    try v.validateFunctions();

    // Phase 4.5: Per-entry-point binding validation + suspicious patterns
    try v.validatePerEntryPointBindings();
    v.checkSuspiciousBindingPatterns();

    // Phase 5: Uniformity analysis
    try v.analyzeUniformity();

    // Phase 6: Scope-tree shadow detection (W0100)
    v.detectShadowing();

    // Phase 7: Ambiguous operator-precedence combinations (E0213)
    v.checkOperatorPrecedence();

    // Remove duplicate diagnostics produced by overlapping phases
    v.diags.deduplicate();

    // Post: every depth-tracked walk inside the validator must return to
    // baseline. Stale state would silently lower the effective limit on
    // the next call against a reused Validator instance.
    std.debug.assert(v.fn_ctx.expr_depth == 0);
    std.debug.assert(v.fn_ctx.stmt_depth == 0);
}

/// Analyze a parsed WGSL module, retaining semantic state.
/// Returns an enriched result with resolved types, struct layouts, etc.
///
/// If `module` was produced by `Incremental.reparse`, any non-owner
/// decls may carry deferred `interior_pending` bias. We drain it up
/// front so every span/loc read inside the validator (diagnostic
/// ranges, attribute positions, etc.) sees current coordinates.
pub fn analyze(arena: Allocator, module: *Ast.Module, options: Options) !AnalysisResult {
    std.debug.assert(module.scope.parent == null);
    std.debug.assert(module.source.len < std.math.maxInt(u32));

    module.absorbInteriors();

    const diags = try arena.create(Diagnostic);
    diags.* = try Diagnostic.init(arena, module.source);
    diags.line_offset = options.line_offset;

    var v = Validator{
        .arena = arena,
        .module = module,
        .diags = diags,
        .options = options,
    };

    try runPhases(&v);

    // B.M5: `Symbol.use_count` is gone — the canonical use counts live
    // on `module.use_counts`, populated by AstVisit Pass 2. The
    // analysis result just hands a reference to it so consumers
    // (lint, LSP unused warnings) don't have to reach back for the
    // module pointer.
    return .{
        .valid = !diags.hasErrors(),
        .diagnostics = diags,
        .module = module,
        .symbol_types = v.symbol_types,
        .struct_types = v.struct_types,
        .alias_types = v.alias_types,
        .const_values = v.const_values,
        .expr_types = v.expr_types,
        .use_counts = module.use_counts,
    };
}

// =========================================================================
// Top-level declaration validation (moved to validator/Declarations.zig)
// =========================================================================

const _Declarations = @import("validator/Declarations.zig");
pub const processDirectives = _Declarations.processDirectives;
pub const checkReservedIdentifiers = _Declarations.checkReservedIdentifiers;
pub const collectTypeDeclarations = _Declarations.collectTypeDeclarations;
pub const resolveAliasTypes = _Declarations.resolveAliasTypes;
pub const resolveStructLayouts = _Declarations.resolveStructLayouts;
pub const checkRecursiveStructs = _Declarations.checkRecursiveStructs;
pub const validateDeclarations = _Declarations.validateDeclarations;
pub const registerFunctionSignatures = _Declarations.registerFunctionSignatures;
pub const checkRecursiveFunctions = _Declarations.checkRecursiveFunctions;
pub const validatePerEntryPointBindings = _Declarations.validatePerEntryPointBindings;
pub const checkSuspiciousBindingPatterns = _Declarations.checkSuspiciousBindingPatterns;
pub const countEntryPoints = _Declarations.countEntryPoints;

// Cross-phase helpers consumed by Statements.zig / Expressions.zig.
pub const determineShaderStage = _Declarations.determineShaderStage;
pub const resolveFunctionParameters = _Declarations.resolveFunctionParameters;
pub const validateReturnAttributes = _Declarations.validateReturnAttributes;
pub const validateEntryPoint = _Declarations.validateEntryPoint;
pub const validateConstDecl = _Declarations.validateConstDecl;
pub const validateConstAssert = _Declarations.validateConstAssert;
pub const validateLetDecl = _Declarations.validateLetDecl;
pub const validateVarDecl = _Declarations.validateVarDecl;
pub const findStructDecl = _Declarations.findStructDecl;
pub const isSwizzleName = _Declarations.isSwizzleName;
pub const hasDuplicateSwizzleChars = _Declarations.hasDuplicateSwizzleChars;
pub const isVertexInput = _Declarations.isVertexInput;
pub const isVertexOutput = _Declarations.isVertexOutput;
pub const isFragmentInput = _Declarations.isFragmentInput;
pub const isFragmentOutput = _Declarations.isFragmentOutput;
pub const isComputeInput = _Declarations.isComputeInput;

// =========================================================================
// Statement / control-flow / post-pass walkers (moved to validator/Statements.zig)
// =========================================================================

const _Statements = @import("validator/Statements.zig");
pub const validateFunctions = _Statements.validateFunctions;
pub const validateFunction = _Statements.validateFunction;
pub const validateStmt = _Statements.validateStmt;
pub const validateCompoundStmt = _Statements.validateCompoundStmt;
pub const validateDeclStmt = _Statements.validateDeclStmt;
pub const validateReturnStmt = _Statements.validateReturnStmt;
pub const validateIfStmt = _Statements.validateIfStmt;
pub const validateSwitchStmt = _Statements.validateSwitchStmt;
pub const validateLoopStmt = _Statements.validateLoopStmt;
pub const validateWhileStmt = _Statements.validateWhileStmt;
pub const validateForStmt = _Statements.validateForStmt;
pub const validateBreakStmt = _Statements.validateBreakStmt;
pub const validateBreakIfStmt = _Statements.validateBreakIfStmt;
pub const validateContinueStmt = _Statements.validateContinueStmt;
pub const validateDiscardStmt = _Statements.validateDiscardStmt;
pub const validateAssignStmt = _Statements.validateAssignStmt;
pub const validateIncrDecrStmt = _Statements.validateIncrDecrStmt;
pub const validateCallStmt = _Statements.validateCallStmt;
pub const detectShadowing = _Statements.detectShadowing;
pub const checkOperatorPrecedence = _Statements.checkOperatorPrecedence;
pub const blockHasExit = _Statements.blockHasExit;
pub const continuingHasBreakIf = _Statements.continuingHasBreakIf;
pub const stmtTerminates = _Statements.stmtTerminates;
pub const getStmtLoc = _Statements.getStmtLoc;
pub const getStmtRange = _Statements.getStmtRange;



// =========================================================================
// Expression Type Checking (moved to src/validator/Expressions.zig)
// =========================================================================

const _Expressions = @import("validator/Expressions.zig");
pub const checkExpr = _Expressions.checkExpr;
pub const checkExprE = _Expressions.checkExprE;
pub const checkLiteral = _Expressions.checkLiteral;
pub const checkIntLiteralRange = _Expressions.checkIntLiteralRange;
pub const checkF16Enabled = _Expressions.checkF16Enabled;
pub const checkFloatLiteralValue = _Expressions.checkFloatLiteralValue;
pub const checkIdent = _Expressions.checkIdent;
pub const checkBinary = _Expressions.checkBinary;
pub const checkBinaryE = _Expressions.checkBinaryE;
pub const checkUnary = _Expressions.checkUnary;
pub const checkUnaryE = _Expressions.checkUnaryE;
pub const checkCallExpr = _Expressions.checkCallExpr;
pub const checkBitcastCall = _Expressions.checkBitcastCall;
pub const checkIndex = _Expressions.checkIndex;
pub const checkMember = _Expressions.checkMember;



// =========================================================================
// Phase 5: Uniformity Analysis (moved to src/validator/Uniformity.zig)
// =========================================================================

pub const analyzeUniformity = @import("validator/Uniformity.zig").analyzeUniformity;

// =========================================================================
// Type Resolution Helpers
// =========================================================================

pub fn resolveType(v: *Validator, ast_type: Ast.Type) Allocator.Error!?Types.Type {
    return switch (ast_type) {
        .ident => |t| try resolveIdentType(v, t),
        .vec => |t| try resolveVecType(v, t),
        .mat => |t| try resolveMatType(v, t),
        .array => |t| try resolveArrayType(v, t),
        .ptr => |t| try resolvePtrType(v, t),
        .atomic => |t| try resolveAtomicType(v, t),
        .sampler => |t| try resolveSamplerType(v, t),
        .texture => |t| try resolveTextureType(v, t),
    };
}

pub fn resolveIdentType(v: *Validator, t: anytype) Allocator.Error!?Types.Type {
    if (try v.lookupType(t.name)) |typ| return typ;
    // Type not found — report with suggestion if close match exists.
    if (v.suggestType(t.name, null)) |suggestion| {
        v.addErrorWithCodeDataR(astTypeRange(.{ .ident = t }), Diagnostic.Code.type_mismatch, v.fmtError("unknown type '{s}'; did you mean '{s}'?", .{ t.name, suggestion }), .{ .did_you_mean = suggestion });
    } else {
        v.addErrorWithCodeR(astTypeRange(.{ .ident = t }), Diagnostic.Code.type_mismatch, v.fmtError("unknown type '{s}'", .{t.name}));
    }
    return null;
}

pub fn resolveVecType(v: *Validator, t: anytype) Allocator.Error!?Types.Type {
    var elem_scalar: *const Types.Scalar = Types.scalar_f32_ptr;
    if (t.elem_type) |et| {
        if (try v.resolveType(et)) |resolved| {
            switch (resolved) {
                .scalar => |s| elem_scalar = s,
                else => {},
            }
        }
    } else if (t.shorthand.len > 0) {
        elem_scalar = shorthandElement(t.shorthand);
    }
    const result = try v.arena.create(Types.Vector);
    result.* = .{ .width = t.size, .element = elem_scalar };
    return .{ .vector = result };
}

pub fn resolveMatType(v: *Validator, t: anytype) Allocator.Error!?Types.Type {
    var elem_scalar: *const Types.Scalar = Types.scalar_f32_ptr;
    if (t.elem_type) |et| {
        if (try v.resolveType(et)) |resolved| {
            switch (resolved) {
                .scalar => |s| {
                    // Spec: matrix element type must be f32, f16, or AbstractFloat.
                    if (!s.isFloat()) {
                        v.addErrorWithCodeR(astTypeRange(.{ .mat = t }), Diagnostic.Code.invalid_matrix_element, v.fmtError("matrix element type must be f32 or f16, got '{s}'", .{resolved.string()}));
                        return null;
                    }
                    elem_scalar = s;
                },
                else => {
                    v.addErrorWithCodeR(astTypeRange(.{ .mat = t }), Diagnostic.Code.invalid_matrix_element, v.fmtError("matrix element type must be scalar, got '{s}'", .{resolved.string()}));
                    return null;
                },
            }
        }
    } else if (t.shorthand.len > 0) {
        elem_scalar = shorthandElement(t.shorthand);
    }
    const result = try v.arena.create(Types.Matrix);
    result.* = .{ .cols = t.cols, .rows = t.rows, .element = elem_scalar };
    return .{ .matrix = result };
}

pub fn resolveArrayType(v: *Validator, t: anytype) Allocator.Error!?Types.Type {
    const elem_type = if (t.elem_type) |et| ((try v.resolveType(et)) orelse return null) else return null;
    var count: u32 = 0;
    if (t.size) |size_expr| {
        // Array element count must be a const-expression or override-expression
        const size_stage = v.classifyExprStage(size_expr);
        if (size_stage == .runtime_expr) {
            v.addErrorWithCodeR(exprRange(size_expr), Diagnostic.Code.expression_not_const, "array element count must be a const-expression or override-expression");
        }
        // Try to evaluate constant expression for array size
        if (v.tryExtractIntValue(size_expr)) |val| {
            if (val <= 0) {
                // Spec: array element count must be > 0
                v.addErrorWithCodeR(exprRange(size_expr), Diagnostic.Code.invalid_array_count, "array element count must be greater than 0");
                return null;
            }
            count = @intCast(val);
        }
        // If we couldn't extract the value (identifier, complex expr), leave count=0
    }
    const result = try v.arena.create(Types.Array);
    result.* = .{ .element = elem_type, .count = count };
    return .{ .array = result };
}

pub fn resolvePtrType(v: *Validator, t: anytype) Allocator.Error!?Types.Type {
    const elem_type = (try v.resolveType(t.elem_type)) orelse return null;
    // Spec: pointer element type must not be a pointer, reference, sampler, or texture.
    switch (elem_type) {
        .pointer, .reference => {
            v.addErrorWithCodeR(astTypeRange(.{ .ptr = t }), Diagnostic.Code.type_mismatch, "pointer element type must not be a pointer or reference");
            return null;
        },
        .sampler => {
            v.addErrorWithCodeR(astTypeRange(.{ .ptr = t }), Diagnostic.Code.type_mismatch, "pointer element type must not be a sampler");
            return null;
        },
        .texture => {
            v.addErrorWithCodeR(astTypeRange(.{ .ptr = t }), Diagnostic.Code.type_mismatch, "pointer element type must not be a texture");
            return null;
        },
        else => {},
    }
    const result = try v.arena.create(Types.Pointer);
    result.* = .{
        .address_space = t.address_space,
        .element = elem_type,
        .access_mode = t.access_mode,
    };
    return .{ .pointer = result };
}

pub fn resolveAtomicType(v: *Validator, t: anytype) Allocator.Error!?Types.Type {
    const elem_type = (try v.resolveType(t.elem_type)) orelse return null;
    switch (elem_type) {
        .scalar => |s| {
            // Spec: atomic type requires i32 or u32 only.
            if (s.kind != .i32 and s.kind != .u32) {
                v.addErrorWithCodeR(astTypeRange(.{ .atomic = t }), Diagnostic.Code.invalid_atomic_type, v.fmtError("atomic type requires i32 or u32, got '{s}'", .{elem_type.string()}));
                return null;
            }
            const result = try v.arena.create(Types.Atomic);
            result.* = .{ .element = s };
            return .{ .atomic = result };
        },
        else => {
            v.addErrorWithCodeR(astTypeRange(.{ .atomic = t }), Diagnostic.Code.invalid_atomic_type, v.fmtError("atomic type requires scalar element, got '{s}'", .{elem_type.string()}));
            return null;
        },
    }
}

pub fn resolveSamplerType(v: *Validator, t: anytype) Allocator.Error!?Types.Type {
    const result = try v.arena.create(Types.Sampler);
    result.* = .{ .comparison = t.comparison };
    return .{ .sampler = result };
}

pub fn resolveTextureType(v: *Validator, t: anytype) Allocator.Error!?Types.Type {
    const tex_range = astTypeRange(.{ .texture = t });
    const kind = astTextureKindToType(t.kind);
    const dimension = astTextureDimToType(t.dimension);

    var sampled_scalar: ?*const Types.Scalar = null;
    if (t.sampled_type) |st| {
        if (try v.resolveType(st)) |resolved| {
            switch (resolved) {
                .scalar => |s| sampled_scalar = s,
                else => {},
            }
        }
    }

    // Spec: sampled and multisampled texture element types must be f32, i32, or u32.
    if (kind == .sampled or kind == .multisampled) {
        if (sampled_scalar) |s| {
            if (s.kind != .f32 and s.kind != .i32 and s.kind != .u32) {
                v.addErrorWithCodeR(tex_range, Diagnostic.Code.type_mismatch, v.fmtError("texture element type must be f32, i32, or u32, got '{s}'", .{s.string()}));
            }
        }
    }

    // Spec: multisampled textures must be 2D.
    if (kind == .multisampled or kind == .depth_multisampled) {
        if (dimension != .@"2d") {
            v.addErrorWithCodeR(tex_range, Diagnostic.Code.type_mismatch, v.fmtError("multisampled texture must be 2d, got '{s}'", .{dimension.string()}));
        }
    }

    // Spec: storage textures must not use cube or cube_array dimensions.
    if (kind == .storage) {
        if (dimension == .cube or dimension == .cube_array) {
            v.addErrorWithCodeR(tex_range, Diagnostic.Code.type_mismatch, v.fmtError("storage texture must not use '{s}' dimension", .{dimension.string()}));
        }
    }

    const result = try v.arena.create(Types.Texture);
    result.* = .{
        .kind = kind,
        .dimension = dimension,
        .sampled_type = sampled_scalar,
        .texel_format = t.texel_format,
        .access_mode = t.access_mode,
    };
    return .{ .texture = result };
}

pub fn lookupType(v: *Validator, name: []const u8) Allocator.Error!?Types.Type {
    assert(name.len > 0);
    assert(v.module.source.len < std.math.maxInt(u32));
    // Built-in scalar types
    if (std.mem.eql(u8, name, "bool")) return Types.Bool;
    if (std.mem.eql(u8, name, "i32")) return Types.I32;
    if (std.mem.eql(u8, name, "u32")) return Types.U32;
    if (std.mem.eql(u8, name, "f32")) return Types.F32;
    if (std.mem.eql(u8, name, "f16")) {
        if (!v.enabled_features.contains("f16")) {
            v.addErrorWithCodeDataR(.{ .start = 0, .end = 1 }, Diagnostic.Code.feature_not_enabled, "'f16' requires 'enable f16;'", .{ .feature_not_enabled = "f16" });
        }
        return Types.F16;
    }
    if (std.mem.eql(u8, name, "sampler")) {
        const s = try v.arena.create(Types.Sampler);
        s.* = .{ .comparison = false };
        return .{ .sampler = s };
    }
    if (std.mem.eql(u8, name, "sampler_comparison")) {
        const s = try v.arena.create(Types.Sampler);
        s.* = .{ .comparison = true };
        return .{ .sampler = s };
    }

    // Vector shorthand (vec2f, vec3i, etc.) and bare constructors (vec2, vec3, vec4)
    if (name.len >= 4 and std.mem.startsWith(u8, name, "vec")) {
        return try v.parseVectorShorthand(name);
    }

    // Matrix shorthand (mat2x2f, mat3x3f, etc.) and bare constructors (mat2x2, mat3x3, etc.)
    if (name.len >= 5 and std.mem.startsWith(u8, name, "mat")) {
        return try v.parseMatrixShorthand(name);
    }

    // Texture types spelled without template arguments: depth textures and
    // `texture_external`. Sampled/storage/multisampled textures require
    // template args and are parsed into AST texture nodes by the Parser, so
    // they never reach `lookupType` by name (a bare `texture_2d` stays
    // "unknown type").
    if (Predeclared.textureInfo(name)) |info| switch (info.kind) {
        .depth, .depth_multisampled, .external => {
            const t = try v.arena.create(Types.Texture);
            t.* = .{
                .kind = astTextureKindToType(info.kind),
                .dimension = astTextureDimToType(info.dim),
                .sampled_type = null,
                .texel_format = "",
                .access_mode = .read,
            };
            return .{ .texture = t };
        },
        .sampled, .multisampled, .storage => {},
    };

    // Bare array constructor
    if (std.mem.eql(u8, name, "array")) {
        const arr = try v.arena.create(Types.Array);
        arr.* = .{ .element = Types.F32, .count = 0 };
        return .{ .array = arr };
    }

    // Check struct types
    if (v.struct_types.get(name)) |st| {
        return .{ .@"struct" = st };
    }

    // Check type aliases
    if (v.alias_types.get(name)) |maybe_type| {
        return maybe_type;
    }

    return null;
}

/// Find the closest type name to `name` within Levenshtein distance 2.
/// Checks built-in WGSL types plus user-defined structs and aliases.
/// When `arg_count` is provided, uses it as a tiebreaker for type constructors
/// whose names encode an arity (e.g. vec3f → 3 components).
pub fn suggestType(v: *Validator, name: []const u8, arg_count: ?usize) ?[]const u8 {
    // Suffixed variants first — they're more commonly intended than bare constructors.
    const builtins = [_][]const u8{
        "bool",             "i32",                    "u32",                "f32",                      "f16",
        "sampler",          "sampler_comparison",     "vec2f",              "vec2i",                    "vec2u",
        "vec2h",            "vec2",                   "vec3f",              "vec3i",                    "vec3u",
        "vec3h",            "vec3",                   "vec4f",              "vec4i",                    "vec4u",
        "vec4h",            "vec4",                   "mat2x2f",            "mat2x2h",                  "mat2x2",
        "mat2x3f",          "mat2x3h",                "mat2x3",             "mat2x4f",                  "mat2x4h",
        "mat2x4",           "mat3x2f",                "mat3x2h",            "mat3x2",                   "mat3x3f",
        "mat3x3h",          "mat3x3",                 "mat3x4f",            "mat3x4h",                  "mat3x4",
        "mat4x2f",          "mat4x2h",                "mat4x2",             "mat4x3f",                  "mat4x3h",
        "mat4x3",           "mat4x4f",                "mat4x4h",            "mat4x4",                   "array",
        "texture_depth_2d", "texture_depth_2d_array", "texture_depth_cube", "texture_depth_cube_array", "texture_depth_multisampled_2d",
        "texture_external",
    };
    var best: ?[]const u8 = null;
    var best_dist: usize = 3; // only suggest if distance <= 2
    for (&builtins) |candidate| {
        // Use best_dist + 1 as the bound so that exact ties are distinguishable
        // from "capped at max" returns from levenshteinBounded.
        const d = levenshteinBounded(name, candidate, best_dist + 1);
        const arity_match = if (arg_count) |ac| Predeclared.arityOfTypeConstructor(candidate) == ac else false;
        if (d < best_dist or (d == best_dist and arity_match)) {
            best = candidate;
            best_dist = d;
        }
    }
    // User-defined struct types
    var sit = v.struct_types.iterator();
    while (sit.next()) |entry| {
        const d = levenshteinBounded(name, entry.key_ptr.*, best_dist);
        if (d < best_dist) {
            best = entry.key_ptr.*;
            best_dist = d;
        }
    }
    // Type aliases
    var ait = v.alias_types.iterator();
    while (ait.next()) |entry| {
        const d = levenshteinBounded(name, entry.key_ptr.*, best_dist);
        if (d < best_dist) {
            best = entry.key_ptr.*;
            best_dist = d;
        }
    }
    return best;
}

const levenshteinBounded = Suggest.levenshteinBounded;
const suggestName = Suggest.suggestName;

/// Suggest a close match for an undeclared identifier from all visible symbols and builtin functions.
pub fn suggestIdentifier(v: *Validator, name: []const u8) ?[]const u8 {
    assert(name.len > 0);
    var best: ?[]const u8 = null;
    var best_dist: usize = 3;
    assert(best_dist > 0);
    // User-defined symbols
    for (v.module.symbols.items) |sym| {
        if (sym.original_name.len == 0 or sym.kind == .unbound) continue;
        const d = levenshteinBounded(name, sym.original_name, best_dist);
        if (d < best_dist) {
            best = sym.original_name;
            best_dist = d;
        }
    }
    // Builtin functions
    for (Builtins.names()) |bname| {
        const d = levenshteinBounded(name, bname, best_dist);
        if (d < best_dist) {
            best = bname;
            best_dist = d;
        }
    }
    return best;
}

/// Suggest a close match for a not-callable name from builtin functions, user functions, and type constructors.
pub fn suggestCallable(v: *Validator, name: []const u8, arg_count: ?usize) ?[]const u8 {
    assert(name.len > 0);
    var best: ?[]const u8 = null;
    var best_dist: usize = 3;
    assert(best_dist > 0);
    // Builtin functions
    for (Builtins.names()) |bname| {
        const d = levenshteinBounded(name, bname, best_dist);
        if (d < best_dist) {
            best = bname;
            best_dist = d;
        }
    }
    // User-defined functions
    for (v.module.symbols.items) |sym| {
        if (sym.kind != .function or sym.original_name.len == 0) continue;
        const d = levenshteinBounded(name, sym.original_name, best_dist);
        if (d < best_dist) {
            best = sym.original_name;
            best_dist = d;
        }
    }
    // Type constructors
    if (v.suggestType(name, arg_count)) |type_name| {
        const d = levenshteinBounded(name, type_name, best_dist);
        if (d < best_dist) {
            best = type_name;
        }
    }
    return best;
}

/// Extract the natural argument count from a type constructor name.
/// See `Predeclared.arityOfTypeConstructor` — the canonical implementation.
pub const arityOfTypeConstructor = Predeclared.arityOfTypeConstructor;

/// Map a shorthand suffix (or the bare default) to its concrete scalar. The
/// bare vec/mat form (no suffix) defaults to f32.
fn suffixScalarPtr(elem: ?Predeclared.SuffixScalar) *const Types.Scalar {
    return switch (elem orelse .f32) {
        .i32 => Types.scalar_i32_ptr,
        .u32 => Types.scalar_u32_ptr,
        .f32 => Types.scalar_f32_ptr,
        .f16 => Types.scalar_f16_ptr,
    };
}

pub fn parseVectorShorthand(v: *Validator, name: []const u8) Allocator.Error!?Types.Type {
    const sh = Predeclared.parseVecShorthand(name) orelse return null;
    const result = try v.arena.create(Types.Vector);
    result.* = .{ .width = sh.width, .element = suffixScalarPtr(sh.elem) };
    return .{ .vector = result };
}

pub fn parseMatrixShorthand(v: *Validator, name: []const u8) Allocator.Error!?Types.Type {
    const sh = Predeclared.parseMatShorthand(name) orelse return null;
    const result = try v.arena.create(Types.Matrix);
    result.* = .{ .cols = sh.cols, .rows = sh.rows, .element = suffixScalarPtr(sh.elem) };
    return .{ .matrix = result };
}

pub fn shorthandElement(shorthand: []const u8) *const Types.Scalar {
    if (shorthand.len == 0) return Types.scalar_f32_ptr;
    return switch (shorthand[shorthand.len - 1]) {
        'i' => Types.scalar_i32_ptr,
        'u' => Types.scalar_u32_ptr,
        'f' => Types.scalar_f32_ptr,
        'h' => Types.scalar_f16_ptr,
        else => Types.scalar_f32_ptr,
    };
}

// =========================================================================
// AST Enum Conversions
// =========================================================================

pub fn astTextureKindToType(kind: Ast.TextureKind) Types.TextureKind {
    return switch (kind) {
        .sampled => .sampled,
        .multisampled => .multisampled,
        .storage => .storage,
        .depth => .depth,
        .depth_multisampled => .depth_multisampled,
        .external => .external,
    };
}

pub fn astTextureDimToType(dim: Ast.TextureDimension) Types.TextureDimension {
    return switch (dim) {
        .@"1d" => .@"1d",
        .@"2d" => .@"2d",
        .@"2d_array" => .@"2d_array",
        .@"3d" => .@"3d",
        .cube => .cube,
        .cube_array => .cube_array,
    };
}

// =========================================================================
// Internal Helpers
// =========================================================================

/// Byte range in source code (start inclusive, end exclusive).
pub const LocRange = struct { start: u32, end: u32 };

/// Get byte offset for a symbol declaration.
pub fn symbolLoc(v: *Validator, sym_idx: Ast.SymbolIndex) u32 {
    return v.symbolRange(sym_idx).start;
}

/// Get byte range for a symbol declaration name.
pub fn symbolRange(v: *Validator, sym_idx: Ast.SymbolIndex) LocRange {
    if (!sym_idx.isValid()) return .{ .start = 0, .end = 1 };
    const idx = sym_idx.index();
    if (idx < v.module.symbols.items.len) {
        const sym = v.module.symbols.items[idx];
        return .{ .start = sym.loc, .end = sym.loc +| @as(u32, @intCast(sym.original_name.len)) };
    }
    return .{ .start = 0, .end = 1 };
}

/// Extract the best available source location from an expression.
pub fn exprLoc(expr: Ast.Expr) u32 {
    return exprRange(expr).start;
}

/// Get byte range for the primary token of an expression.
pub fn exprRange(expr: Ast.Expr) LocRange {
    return switch (expr) {
        .ident => |e| .{ .start = e.loc, .end = e.loc +| @as(u32, @intCast(e.name.len)) },
        .literal => |e| .{ .start = e.loc, .end = e.loc +| @as(u32, @intCast(e.value.len)) },
        .binary => |e| .{ .start = e.loc, .end = e.loc +| @as(u32, @intCast(e.op.string().len)) },
        .unary => |e| .{ .start = e.loc, .end = e.loc +| @as(u32, @intCast(e.op.string().len)) },
        .call => |e| if (e.func) |f| exprRange(f) else .{ .start = e.loc, .end = e.loc +| 1 },
        .index => |e| .{ .start = e.loc, .end = e.loc +| 1 },
        .member => |e| .{ .start = e.loc, .end = e.loc +| 1 +| @as(u32, @intCast(e.member_name.len)) },
        .paren => |e| exprRange(e.expr),
    };
}

/// Get byte range spanning an entire expression (from leftmost to rightmost token).
/// For `a + b`, spans from start of `a` to end of `b`.
pub fn exprSpan(expr: Ast.Expr) LocRange {
    return switch (expr) {
        .binary => |e| .{
            .start = exprSpan(e.left).start,
            .end = exprSpan(e.right).end,
        },
        .unary => |e| .{
            .start = e.loc,
            .end = exprSpan(e.operand).end,
        },
        .call => |e| .{
            .start = if (e.func) |f| exprSpan(f).start else e.loc,
            .end = if (e.end_loc > 0) e.end_loc else exprRange(expr).end,
        },
        .index => |e| .{
            .start = exprSpan(e.base).start,
            .end = if (e.end_loc > 0) e.end_loc else exprRange(expr).end,
        },
        .paren => |e| exprSpan(e.expr),
        else => exprRange(expr),
    };
}

pub fn symbolName(v: *Validator, sym_idx: Ast.SymbolIndex) []const u8 {
    if (!sym_idx.isValid()) return "";
    const idx = sym_idx.index();
    if (idx < v.module.symbols.items.len) {
        return v.module.symbols.items[idx].original_name;
    }
    return "";
}

pub fn setSymbolType(v: *Validator, sym_idx: Ast.SymbolIndex, typ: ?Types.Type) Allocator.Error!void {
    if (!sym_idx.isValid()) return;
    if (typ) |t| {
        // Defensive check: abstract types must not survive into var/let storage
        if (!t.isConcrete()) {
            const idx = sym_idx.index();
            if (idx < v.module.symbols.items.len) {
                const kind = v.module.symbols.items[idx].kind;
                if (kind == .@"var" or kind == .let) {
                    v.addWarningR(v.symbolRange(sym_idx), v.fmtError("'{s}' has abstract type '{s}' which will be concretized", .{ v.symbolName(sym_idx), t.string() }));
                }
            }
        }
        try v.symbol_types.put(v.arena, sym_idx.index(), t);
    }
}

/// Best-effort by contract: on OOM this returns the raw (unformatted) format
/// string rather than propagating an error. A degraded diagnostic *message* is
/// never a wrong *result* — the caller has already decided a diagnostic is
/// warranted, so the worst case here is a less-specific string, not a fabricated
/// or missed verdict. This is the deliberate counterpart to the resolveType /
/// constructor-inference families, whose allocations DO propagate `error.OutOfMemory`
/// because their failure would corrupt the inferred type (see Block 1.5).
pub fn fmtError(v: *Validator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(v.arena, fmt, args) catch fmt;
}

// -- Single-offset helpers (kept for backward compat / simple cases) ------

pub fn addError(v: *Validator, offset: u32, message: []const u8) void {
    v.diags.addError(v.arena, offset, message);
}

pub fn addErrorWithCode(v: *Validator, offset: u32, code: []const u8, message: []const u8) void {
    v.diags.addErrorWithCode(v.arena, offset, code, message);
}

pub fn addWarning(v: *Validator, offset: u32, message: []const u8) void {
    if (v.options.strict_mode) {
        v.diags.addError(v.arena, offset, message);
    } else {
        v.diags.addWarning(v.arena, offset, message);
    }
}

// -- Range-aware helpers --------------------------------------------------

pub fn addErrorR(v: *Validator, r: LocRange, message: []const u8) void {
    v.diags.addErrorRange(v.arena, r.start, r.end, message);
}

pub fn addErrorWithCodeR(v: *Validator, r: LocRange, code: []const u8, message: []const u8) void {
    v.diags.addErrorWithCodeRange(v.arena, r.start, r.end, code, message);
}

pub fn addErrorWithRelatedR(v: *Validator, r: LocRange, code: []const u8, message: []const u8, related: []const Diagnostic.RelatedInfo) void {
    v.diags.add(v.arena, .{
        .severity = .@"error",
        .code = code,
        .message = message,
        .range = v.diags.makeRange(r.start, r.end),
        .related = related,
    });
}

/// Range-aware error emitter with a structured `QuickFixHint`. The LSP
/// reads `data` to build code-action edits without re-parsing the
/// message. Use this at emit sites where the LSP offers a quickfix
/// (did-you-mean, cast, location bump, vertex builtin, feature enable).
pub fn addErrorWithCodeDataR(v: *Validator, r: LocRange, code: []const u8, message: []const u8, data: Diagnostic.QuickFixHint) void {
    v.diags.add(v.arena, .{
        .severity = .@"error",
        .code = code,
        .message = message,
        .range = v.diags.makeRange(r.start, r.end),
        .data = data,
    });
}

/// `addErrorWithRelatedR` + `data`. Currently used by the duplicate-
/// `@location(N)` E0602 sites so the LSP knows N without parsing the
/// message back.
pub fn addErrorWithRelatedDataR(v: *Validator, r: LocRange, code: []const u8, message: []const u8, related: []const Diagnostic.RelatedInfo, data: Diagnostic.QuickFixHint) void {
    v.diags.add(v.arena, .{
        .severity = .@"error",
        .code = code,
        .message = message,
        .range = v.diags.makeRange(r.start, r.end),
        .related = related,
        .data = data,
    });
}

pub fn addWarningR(v: *Validator, r: LocRange, message: []const u8) void {
    if (v.options.strict_mode) {
        v.diags.addErrorRange(v.arena, r.start, r.end, message);
    } else {
        v.diags.addWarningRange(v.arena, r.start, r.end, message);
    }
}

pub fn addWarningWithCodeR(v: *Validator, r: LocRange, code: []const u8, message: []const u8) void {
    v.diags.add(v.arena, .{
        .severity = if (v.options.strict_mode) .@"error" else .warning,
        .code = code,
        .message = message,
        .range = v.diags.makeRange(r.start, r.end),
    });
}

pub fn makeRelatedR(v: *Validator, r: LocRange, message: []const u8) []const Diagnostic.RelatedInfo {
    const slice = v.arena.alloc(Diagnostic.RelatedInfo, 1) catch return &.{};
    slice[0] = .{
        .range = v.diags.makeRange(r.start, r.end),
        .message = message,
    };
    return slice;
}

// -- Legacy single-offset wrappers for related info -----------------------

pub fn addErrorWithRelated(v: *Validator, offset: u32, code: []const u8, message: []const u8, related: []const Diagnostic.RelatedInfo) void {
    v.addErrorWithRelatedR(.{ .start = offset, .end = offset + 1 }, code, message, related);
}

pub fn makeRelated(v: *Validator, offset: u32, message: []const u8) []const Diagnostic.RelatedInfo {
    return v.makeRelatedR(.{ .start = offset, .end = offset + 1 }, message);
}

// -- Type location helpers ------------------------------------------------

pub fn astTypeLoc(ast_type: Ast.Type) u32 {
    return astTypeRange(ast_type).start;
}

pub fn astTypeRange(ast_type: Ast.Type) LocRange {
    return switch (ast_type) {
        .ident => |t| .{ .start = t.loc, .end = t.loc +| @as(u32, @intCast(t.name.len)) },
        .vec => |t| blk: {
            const len: u32 = if (t.shorthand.len > 0) @intCast(t.shorthand.len) else 4; // "vecN"
            break :blk .{ .start = t.loc, .end = t.loc +| len };
        },
        .mat => |t| blk: {
            const len: u32 = if (t.shorthand.len > 0) @intCast(t.shorthand.len) else 6; // "matNxM"
            break :blk .{ .start = t.loc, .end = t.loc +| len };
        },
        .atomic => |t| .{ .start = t.loc, .end = t.loc +| 6 }, // "atomic"
        .array, .ptr, .sampler, .texture => .{ .start = 0, .end = 1 },
    };
}

/// Get byte range for an attribute token (e.g., `@group`).
pub fn attrRange(attr: *const Ast.Attribute) LocRange {
    // +1 for the '@' prefix
    return .{ .start = attr.loc, .end = attr.loc +| 1 +| @as(u32, @intCast(attr.name.len)) };
}

/// Resolver adapting the Validator's precomputed const map to `ConstEval`.
/// Eager, integer-domain: `const_values` holds only the module-scope `const`
/// decls whose initializer already int-reduced (populated by
/// `validateConstDecl`). Members are intentionally *not* resolved — the
/// pre-extraction extractor never folded `a.x`, so returning null keeps the
/// migrated paths byte-for-byte. See `docs/deferred/consteval-extraction.md`.
const ConstResolver = struct {
    v: *const Validator,

    pub fn resolveIdent(self: ConstResolver, ref: Ast.SymbolIndex) ?ConstEval.Value {
        if (ref.isValid()) {
            if (self.v.const_values.get(ref.index())) |i| return .{ .int = i };
        }
        return null;
    }

    pub fn resolveMember(_: ConstResolver, _: *Ast.MemberExpr, _: u32) ?ConstEval.Value {
        return null;
    }
};

/// Try to evaluate a const bool expression (for const_assert).
/// Handles true/false literals, logical not, and comparison operators on
/// known-const int operands — the integer-domain subset of `ConstEval`
/// (`evalIntOnly`), narrowed to the boolean results (`Value.asBool`).
pub fn tryEvalConstBool(v: *const Validator, expr: Ast.Expr) ?bool {
    const val = ConstEval.evalIntOnly(ConstResolver{ .v = v }, .saturate, expr, 0) orelse return null;
    return val.asBool();
}

/// Try to extract a constant integer value from an expression.
/// Handles literals, paren/negate wrappers, const-declared identifiers,
/// and binary arithmetic/bitwise operations on const sub-expressions.
///
/// The Validator's const-integer folder. Delegates to the shared
/// `src/ConstEval.zig` in its integer-only mode (`evalIntOnly`) with
/// **saturating** overflow (`.saturate`) and a `const_values`-backed resolver,
/// then narrows to `.int` (`Value.asInt`). It differs from Reflect's use of the
/// same evaluator — the full `{int,float,bool}` domain with **wrapping**
/// overflow (`ConstEval.eval(..., .wrap, ...)`) — so the `.call` / float folding
/// (`u32(sin(...))` chains) that Reflect resolves stays invisible here. That
/// capability gap is deliberate today; ConstEval C3 is where it closes.
/// Characterization pins for both sides: `tests/const_eval_test.zig`.
pub fn tryExtractIntValue(v: *const Validator, expr: Ast.Expr) ?i64 {
    return v.tryExtractIntValueDepth(expr, 0);
}

pub fn tryExtractIntValueDepth(v: *const Validator, expr: Ast.Expr, depth: u32) ?i64 {
    const val = ConstEval.evalIntOnly(ConstResolver{ .v = v }, .saturate, expr, depth) orelse return null;
    return val.asInt();
}

/// Extract a constant integer from a literal/arithmetic expression with no
/// const-identifier lookup. Used by freestanding helpers that don't have a
/// `*Validator` (`getLocationInfo` / `getBlendSrcInfo`). Same integer-only,
/// saturating evaluator, resolved through `ConstEval.NullResolver` so idents
/// and members fold to null.
pub fn extractLiteralIntValue(expr: Ast.Expr) ?i64 {
    return extractLiteralIntValueDepth(expr, 0);
}

pub fn extractLiteralIntValueDepth(expr: Ast.Expr, depth: u32) ?i64 {
    const val = ConstEval.evalIntOnly(ConstEval.NullResolver{}, .saturate, expr, depth) orelse return null;
    return val.asInt();
}

/// Classify the evaluation stage of an expression.
/// const_expr < override_expr < runtime_expr; parent = max(children).
pub fn classifyExprStage(v: *const Validator, expr: Ast.Expr) ExprStage {
    return v.classifyExprStageDepth(expr, 0);
}

pub fn classifyExprStageDepth(v: *const Validator, expr: Ast.Expr, depth: u32) ExprStage {
    if (depth > 64) return .runtime_expr;
    switch (expr) {
        .literal => return .const_expr,
        .ident => |e| {
            if (e.ref.isValid()) {
                const idx = e.ref.index();
                if (idx < v.module.symbols.items.len) {
                    const kind = v.module.symbols.items[idx].kind;
                    return switch (kind) {
                        .@"const" => .const_expr,
                        .override => .override_expr,
                        .let, .@"var", .parameter => .runtime_expr,
                        .@"struct", .alias => .const_expr,
                        .function, .builtin => .const_expr,
                        else => .runtime_expr,
                    };
                }
            }
            // Attribute args may not have resolved refs — look up by name
            return v.classifyIdentByName(e.name);
        },
        .binary => |e| {
            const left = v.classifyExprStageDepth(e.left, depth + 1);
            const right = v.classifyExprStageDepth(e.right, depth + 1);
            return @enumFromInt(@max(@intFromEnum(left), @intFromEnum(right)));
        },
        .unary => |e| return v.classifyExprStageDepth(e.operand, depth + 1),
        .paren => |e| return v.classifyExprStageDepth(e.expr, depth + 1),
        .call => |e| {
            // Type constructors with all-const args are const
            // Builtin const_eval functions with all-const args are const
            var max_stage: ExprStage = .const_expr;
            for (e.args.items) |arg| {
                const arg_stage = v.classifyExprStageDepth(arg, depth + 1);
                max_stage = @enumFromInt(@max(@intFromEnum(max_stage), @intFromEnum(arg_stage)));
            }
            // Check if callee is a const-evaluable builtin
            if (e.func) |func| {
                switch (func) {
                    .ident => |ident| {
                        if (Builtins.lookup(ident.name)) |bi| {
                            if (bi.stage != .const_eval) {
                                max_stage = @enumFromInt(@max(@intFromEnum(max_stage), @intFromEnum(ExprStage.runtime_expr)));
                            }
                        }
                    },
                    else => {},
                }
            }
            return max_stage;
        },
        .index => |e| {
            const base = v.classifyExprStageDepth(e.base, depth + 1);
            const idx_stage = v.classifyExprStageDepth(e.idx, depth + 1);
            return @enumFromInt(@max(@intFromEnum(base), @intFromEnum(idx_stage)));
        },
        .member => |e| return v.classifyExprStageDepth(e.base, depth + 1),
    }
}


/// Look up an identifier by name in module-scope declarations to classify its stage.
/// Used when the ident ref is unresolved (e.g., in attribute arguments).
pub fn classifyIdentByName(v: *const Validator, name: []const u8) ExprStage {
    for (v.module.declarations.items) |decl| {
        const decl_name_idx = decl.nameRef();
        if (!decl_name_idx.isValid()) continue;
        const idx = decl_name_idx.index();
        if (idx >= v.module.symbols.items.len) continue;
        if (std.mem.eql(u8, v.module.symbols.items[idx].original_name, name)) {
            return switch (v.module.symbols.items[idx].kind) {
                .@"const" => .const_expr,
                .override => .override_expr,
                .@"struct", .alias => .const_expr,
                .function => .const_expr,
                else => .runtime_expr,
            };
        }
    }
    // Check if it's a builtin type name
    if (std.mem.eql(u8, name, "true") or std.mem.eql(u8, name, "false"))
        return .const_expr;
    return .runtime_expr;
}

// =========================================================================
// Tests
// =========================================================================

test "validator: ShaderStage string" {
    try std.testing.expectEqualStrings("vertex", ShaderStage.vertex.string());
    try std.testing.expectEqualStrings("fragment", ShaderStage.fragment.string());
    try std.testing.expectEqualStrings("compute", ShaderStage.compute.string());
    try std.testing.expectEqualStrings("none", ShaderStage.none.string());
}

test "validator: isVertexInput" {
    try std.testing.expect(isVertexInput("vertex_index"));
    try std.testing.expect(isVertexInput("instance_index"));
    try std.testing.expect(!isVertexInput("position"));
}

test "validator: isFragmentInput" {
    try std.testing.expect(isFragmentInput("position"));
    try std.testing.expect(isFragmentInput("front_facing"));
    try std.testing.expect(isFragmentInput("sample_index"));
    try std.testing.expect(!isFragmentInput("vertex_index"));
}

test "validator: isComputeInput" {
    try std.testing.expect(isComputeInput("local_invocation_id"));
    try std.testing.expect(isComputeInput("global_invocation_id"));
    try std.testing.expect(isComputeInput("workgroup_id"));
    try std.testing.expect(isComputeInput("num_workgroups"));
    try std.testing.expect(!isComputeInput("position"));
}

test "validator: shorthandElement" {
    try std.testing.expectEqual(Types.ScalarKind.i32, shorthandElement("vec3i").kind);
    try std.testing.expectEqual(Types.ScalarKind.u32, shorthandElement("vec4u").kind);
    try std.testing.expectEqual(Types.ScalarKind.f32, shorthandElement("vec2f").kind);
    try std.testing.expectEqual(Types.ScalarKind.f16, shorthandElement("mat3x3h").kind);
    try std.testing.expectEqual(Types.ScalarKind.f32, shorthandElement("").kind);
}

test "validator: validate empty module" {
    const allocator = std.testing.allocator;
    var scope = Ast.Scope.init(null, .module);
    var module = Ast.Module.init(&scope, "");
    const result = try validate(allocator, &module, .{});
    defer allocator.destroy(result.diagnostics);
    defer result.diagnostics.deinit(allocator);
    try std.testing.expect(result.valid);
    try std.testing.expect(!result.diagnostics.hasErrors());
}
