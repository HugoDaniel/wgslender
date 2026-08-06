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

/// Enriched analysis result: the validator's retained semantic state, kept
/// alive for consumers that outlive the run — the LSP (hover, go-to-definition,
/// inlay hints) and the lint rules. This is the materialized form of the
/// validator's output contract: the five type/const caches (`symbol_types`,
/// `struct_types`, `alias_types`, `const_values`, `expr_types`) are exactly
/// the `Outputs` group, copied out verbatim by `analyze` and *only* there;
/// nothing in the validator's `Scratch` maps or `FnContext` cursor reaches
/// here. `use_counts` aliases `module.use_counts`; `liveness` is filled lazily
/// by whoever runs DCE. Stable surface: LSP handlers and lint `Context` read
/// these fields by name, so the field names/layout are pinned (see the
/// stability tiers in `root.zig`).
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
        // A `_` symbol only exists because the parser accepted `_` in a
        // declaration-name position so `checkReservedIdentifiers` could
        // report it (E0105). It is not a real declaration, and stacking
        // "declared but never used" on top of "reserved" is noise about a
        // name the user cannot use either way.
        if (std.mem.eql(u8, sym.original_name, "_")) return false;
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
        // `is_api_facing`, not `is_external_binding`: the latter is set from
        // the address space, so keying on it reported unused textures and
        // samplers as plain unused variables (W0001) instead of unused
        // bindings, losing the "consumes a bind group layout slot" message
        // for exactly the bindings most likely to be forgotten.
        if (!sym.flags.is_api_facing) return false;
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
        if (sym.flags.is_api_facing) return false;
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
    /// The one field with a genuine cross-submodule read: `Statements`
    /// (`validateFunction`) writes it at function entry, and `Declarations`'
    /// phase-4 entry-point IO helpers read it ~14×. Left as a shared field
    /// rather than threaded as an explicit `stage` param through those
    /// signatures, which would sprawl the helper list for no readability gain.
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

/// The validator's *output contract*: everything in `Outputs` outlives the
/// Validator by being copied into `AnalysisResult` (see `analyze`). Nothing
/// else the validator computes does — the `Scratch` maps and the `FnContext`
/// cursor are torn down with the stack frame. Adding a field here commits to
/// exposing it to LSP/lint consumers of `AnalysisResult`; adding one to
/// `Scratch` does not. Field order mirrors the `analyze` copy-out.
const Outputs = struct {
    /// Symbol type cache: maps SymbolIndex -> resolved Types.Type.
    symbol_types: std.AutoHashMapUnmanaged(u32, Types.Type) = .{},
    /// Struct type cache: maps name -> resolved struct type.
    struct_types: std.StringHashMapUnmanaged(*Types.Struct) = .{},
    /// Alias type cache: maps name -> resolved type (null = placeholder).
    alias_types: std.StringHashMapUnmanaged(?Types.Type) = .{},
    /// Const value propagation: maps SymbolIndex raw u32 -> evaluated integer value.
    const_values: std.AutoHashMapUnmanaged(u32, i64) = .{},
    /// Expression type cache: maps expression start offset -> type info.
    expr_types: std.AutoHashMapUnmanaged(u32, ExprTypeInfo) = .{},
};

/// Phase-scoped working state — maps and flags each populated and consumed
/// within `runPhases`, then discarded with the Validator. Unlike `Outputs`,
/// none of this is copied into `AnalysisResult`: it exists only to carry
/// information between phases of a single validation run.
const Scratch = struct {
    /// Override ID tracking for uniqueness validation.
    override_ids: std.AutoHashMapUnmanaged(u32, LocName) = .{},
    /// Binding pair tracking for uniqueness validation: key = (group << 32) | binding.
    binding_pairs: std.AutoHashMapUnmanaged(u64, LocName) = .{},
    /// Binding info collection for suspicious pattern analysis and per-entry-point validation.
    binding_infos: std.ArrayList(BindingInfo) = .empty,
    /// True when the module has >= 2 entry points (per-entry-point binding validation needed).
    multi_entry_point: bool = false,
    /// Enabled features from 'enable' directives.
    enabled_features: std.StringHashMapUnmanaged(void) = .{},
    /// Per-var declaration metadata: populated during validateVarDecl. See
    /// `VarInfo` above for what's recorded and why.
    var_info: std.AutoHashMapUnmanaged(u32, VarInfo) = .{},
    /// Uniformity `diagnostic(...)` controls collected from module-scope
    /// directives in phase 0 (`processDirectives`). Consumed by phase-5
    /// uniformity analysis, layered above any caller-provided
    /// `options.diagnostic_filters` and below function-level `@diagnostic`
    /// attributes (spec §2.3: the innermost scope wins). Empty `rules` map when
    /// the module declares no `diagnostic(...)` directive.
    module_diagnostics: Diagnostic.DiagnosticFilter = .{ .rules = .{} },
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

// Caches exported to AnalysisResult (see `Outputs`).
out: Outputs = .{},

// Phase-scoped working state (see `Scratch`).
scratch: Scratch = .{},

// =========================================================================
// Public API
// =========================================================================

/// Validate a parsed WGSL module. Returns only pass/fail + diagnostics; the
/// resolved-type caches (`Outputs`) are discarded with the run. Use `analyze`
/// to retain them.
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
    v.scratch.multi_entry_point = _Declarations.countEntryPoints(v.module) >= 2;

    // Each phase entry point is called directly through its submodule handle
    // rather than a `v.*` re-export alias: this driver is their only caller,
    // so an alias would be pure indirection (see the re-export contract below).

    // Phase 0: Process directives (enable, diagnostic)
    try _Declarations.processDirectives(v);

    // Phase 0.5: Reject reserved identifiers (WGSL spec: `_` alone, `__`-prefixed)
    _Declarations.checkReservedIdentifiers(v);

    // Phase 1: Collect type declarations (structs, aliases)
    try _Declarations.collectTypeDeclarations(v);

    // Phase 1.5: Resolve type aliases (order-independent forward refs)
    try _Declarations.resolveAliasTypes(v);

    // Phase 2: Resolve struct layouts
    try _Declarations.resolveStructLayouts(v);

    // Phase 2.5: Detect recursive struct definitions
    try _Declarations.checkRecursiveStructs(v);

    // Phase 3: Validate declarations
    try _Declarations.validateDeclarations(v);

    // Phase 3.5: Register function signatures (enables forward references)
    try _Declarations.registerFunctionSignatures(v);

    // Phase 3.75: Detect recursive function calls
    try _Declarations.checkRecursiveFunctions(v);

    // Phase 4: Validate functions and statements
    try _Statements.validateFunctions(v);

    // Phase 4.5: Per-entry-point binding validation + suspicious patterns
    try _Declarations.validatePerEntryPointBindings(v);
    _Declarations.checkSuspiciousBindingPatterns(v);

    // Phase 5: Uniformity analysis
    try _Uniformity.analyzeUniformity(v);

    // Phase 6: Scope-tree shadow detection (W0100)
    _Statements.detectShadowing(v);

    // Phase 7: Ambiguous operator-precedence combinations (E0213)
    _Statements.checkOperatorPrecedence(v);

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
/// The copy-out below is the validator's output contract: it materializes the
/// `Outputs` caches into the returned `AnalysisResult` — the only validator
/// state that outlives the run (`Scratch`/`FnContext` are torn down here).
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
        .symbol_types = v.out.symbol_types,
        .struct_types = v.out.struct_types,
        .alias_types = v.out.alias_types,
        .const_values = v.out.const_values,
        .expr_types = v.out.expr_types,
        .use_counts = module.use_counts,
    };
}

// =========================================================================
// Submodule re-export contract
// =========================================================================
//
// Each validation phase and helper lives in a `validator/*.zig` submodule and
// takes `v: *Validator` as its first parameter. The submodules do NOT import
// each other; the sideways calls they make route through the `pub const` aliases
// below, which make `foo` reachable both as `v.foo(...)` (Zig method sugar) and
// as a `const foo = Validator.foo;` file-local alias in a sibling.
//
// Only the genuinely cross-submodule surface is re-exported. A function whose
// only callers live in its own submodule is invoked there as a free call
// (`validateStmt(v, ...)`), needs no alias, and has none — V3 removed the ~64
// re-exports that were never reached from outside their defining module. Two
// audiences remain: cross-submodule contract, and this file's own `test` blocks.

const _Declarations = @import("validator/Declarations.zig");
const _Statements = @import("validator/Statements.zig");
const _Expressions = @import("validator/Expressions.zig");
const _TypeResolve = @import("validator/TypeResolve.zig");
const _Uniformity = @import("validator/Uniformity.zig");

// -- cross-submodule contract: Declarations helpers reached from
//    Statements.zig / Expressions.zig (via `v.*` or a file-local alias).
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

// -- consumed only by this file's `test` blocks (entry-point IO predicates).
pub const isVertexInput = _Declarations.isVertexInput;
pub const isFragmentInput = _Declarations.isFragmentInput;
pub const isComputeInput = _Declarations.isComputeInput;

// Statements (`validator/Statements.zig`) re-exports nothing: its phase entries
// (`validateFunctions`, `detectShadowing`, `checkOperatorPrecedence`) are called
// directly by `runPhases`, and every per-statement validator is a free call
// within the module (`validateStmt(v, ...)`).

// -- cross-submodule contract: the checkExpr-family entry points reached from
//    Statements.zig / Declarations.zig. The rest of the family (checkBinary,
//    checkIdent, …) is internal to Expressions.zig and re-exported nowhere.
pub const checkExpr = _Expressions.checkExpr;
pub const checkExprE = _Expressions.checkExprE;
pub const checkCallExpr = _Expressions.checkCallExpr;

// -- cross-submodule contract: type resolution reached from
//    Declarations.zig / Expressions.zig. The per-kind resolvers
//    (resolveVecType, …) are internal to TypeResolve.zig; `resolveType`
//    dispatches to them as free calls.
pub const resolveType = _TypeResolve.resolveType;
pub const lookupType = _TypeResolve.lookupType;
pub const suggestType = _TypeResolve.suggestType;
pub const suggestIdentifier = _TypeResolve.suggestIdentifier;
pub const suggestCallable = _TypeResolve.suggestCallable;
pub const parseVectorShorthand = _TypeResolve.parseVectorShorthand;
pub const parseMatrixShorthand = _TypeResolve.parseMatrixShorthand;

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
        try v.out.symbol_types.put(v.arena, sym_idx.index(), t);
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
            if (self.v.out.const_values.get(ref.index())) |i| return .{ .int = i };
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
