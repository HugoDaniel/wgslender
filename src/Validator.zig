//! WGSL semantic validator.
//!
//! Performs type checking, symbol resolution validation, control flow analysis,
//! and uniformity analysis to ensure shaders conform to the WGSL specification.
//!
//! Validation runs in five phases:
//!   1. collectTypeDeclarations — gather struct and alias names
//!   2. resolveStructLayouts  — resolve struct fields and compute layouts
//!   3. validateDeclarations  — validate const/override/var/let decls
//!   4. validateFunctions     — validate functions, statements, expressions
//!   5. analyzeUniformity     — detect non-uniform control flow violations
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
//!   - Phases run in order: `analyze` and `validate` orchestrate exactly
//!     the same sequence — `analyze` retains semantic state for the LSP,
//!     `validate` returns only diagnostics.

const std = @import("std");
const Ast = @import("Ast.zig");
const Types = @import("Types.zig");
const Builtins = @import("Builtins.zig");
const Overload = @import("Overload.zig");
const Diagnostic = @import("Diagnostic.zig");
const Suggest = @import("Suggest.zig");
const Dce = @import("Dce.zig");
const Liveness = @import("Liveness.zig");
const UseCounts = @import("UseCounts.zig");
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
    pub fn deinit(self: *Result, allocator: Allocator) void {
        _ = allocator;
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
    pub fn deinit(self: *AnalysisResult, allocator: Allocator) void {
        _ = allocator;
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
};

// =========================================================================
// Validator State
// =========================================================================

arena: Allocator,
module: *Ast.Module,
diags: *Diagnostic,
options: Options,

// Current function context
current_func: ?*Ast.FunctionDecl = null,
current_stage: ShaderStage = .none,
in_loop: bool = false,
in_switch: bool = false,
in_continuing: bool = false,
return_type: ?Types.Type = null,
has_return: bool = false,
expr_depth: u32 = 0,
stmt_depth: u32 = 0,

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
binding_infos: std.ArrayListUnmanaged(BindingInfo) = .empty,

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
    // Pre: module came from a parse (or CstLower) — its scope tree must be
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

    // Pre-scan: detect multiple entry points for per-entry-point binding validation
    v.multi_entry_point = countEntryPoints(module) >= 2;

    // Phase 0: Process directives (enable, diagnostic)
    try v.processDirectives();

    // Phase 0.5: Reject reserved identifiers (WGSL spec: `_` alone, `__`-prefixed)
    v.checkReservedIdentifiers();

    // Phase 1: Collect type declarations (structs, aliases)
    try v.collectTypeDeclarations();

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
    diags.deduplicate();

    // Post: every depth-tracked walk inside the validator must return to
    // baseline. Stale state would silently lower the effective limit on
    // the next call against a reused Validator instance.
    std.debug.assert(v.expr_depth == 0);
    std.debug.assert(v.stmt_depth == 0);

    return .{
        .valid = !diags.hasErrors(),
        .diagnostics = diags,
    };
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

    // Pre-scan: detect multiple entry points for per-entry-point binding validation
    v.multi_entry_point = countEntryPoints(module) >= 2;

    try v.processDirectives();
    v.checkReservedIdentifiers();
    try v.collectTypeDeclarations();
    try v.resolveStructLayouts();
    try v.checkRecursiveStructs();
    try v.validateDeclarations();
    try v.registerFunctionSignatures();
    try v.checkRecursiveFunctions();
    try v.validateFunctions();
    try v.validatePerEntryPointBindings();
    v.checkSuspiciousBindingPatterns();
    try v.analyzeUniformity();
    v.detectShadowing();
    v.checkOperatorPrecedence();
    diags.deduplicate();

    std.debug.assert(v.expr_depth == 0);
    std.debug.assert(v.stmt_depth == 0);

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
// Phase 0: Process Directives
// =========================================================================

const known_enable_features = [_][]const u8{
    "f16",
    "subgroups",
    "subgroups_f16",
    "dual_source_blending",
    "clip_distances",
    "unrestricted_pointer_parameters",
    "chromium_experimental_framebuffer_fetch",
};

const known_diagnostic_rules = [_][]const u8{
    "derivative_uniformity",
};

pub fn processDirectives(v: *Validator) Allocator.Error!void {
    for (v.module.directives.items) |directive| {
        switch (directive) {
            .enable => |d| {
                for (d.features.items) |feature| {
                    var is_known = false;
                    for (known_enable_features) |kf| {
                        if (std.mem.eql(u8, feature, kf)) {
                            is_known = true;
                            break;
                        }
                    }
                    if (!is_known) {
                        const msg = if (suggestName(feature, &known_enable_features, 3)) |s|
                            v.fmtError("unknown enable feature '{s}'; did you mean '{s}'?", .{ feature, s })
                        else
                            v.fmtError("unknown enable feature '{s}'", .{feature});
                        v.addErrorWithCodeR(.{ .start = 0, .end = 1 }, Diagnostic.Code.unknown_feature, msg);
                    }
                    try v.enabled_features.put(v.arena, feature, {});
                }
            },
            .diagnostic => |d| {
                // WGSL spec section 3.2: severity must be one of the four defined levels.
                const valid_severities = [_][]const u8{ "error", "warning", "info", "off" };
                var severity_valid = false;
                for (valid_severities) |vs| {
                    if (std.mem.eql(u8, d.severity, vs)) {
                        severity_valid = true;
                        break;
                    }
                }
                if (!severity_valid) {
                    v.addErrorWithCodeR(.{ .start = 0, .end = 1 }, Diagnostic.Code.invalid_diagnostic_severity, v.fmtError("invalid diagnostic severity '{s}'; expected 'error', 'warning', 'info', or 'off'", .{d.severity}));
                }
                // Validate rule name (only warn for unknown standard rules)
                if (d.rule.len > 0 and std.mem.indexOfScalar(u8, d.rule, '.') == null) {
                    var rule_known = false;
                    for (known_diagnostic_rules) |kr| {
                        if (std.mem.eql(u8, d.rule, kr)) {
                            rule_known = true;
                            break;
                        }
                    }
                    if (!rule_known) {
                        v.addWarningR(.{ .start = 0, .end = 1 }, v.fmtError("unknown diagnostic rule '{s}'", .{d.rule}));
                    }
                }
            },
            .requires => {},
        }
    }
}

// =========================================================================
// Phase 0.5: Reserved identifier check (E0105)
// =========================================================================

/// WGSL spec (§2.4): identifiers consisting of a single `_`, or beginning
/// with `__`, are reserved. The former is only allowed as the left-hand side
/// of a phony assignment — the parser does not build a `Symbol` for that
/// case, so every surviving `_` symbol here is an invalid declaration.
pub fn checkReservedIdentifiers(v: *Validator) void {
    for (v.module.symbols.items, 0..) |sym, i| {
        switch (sym.kind) {
            .unbound, .builtin => continue,
            else => {},
        }
        const name = sym.original_name;
        if (name.len == 0) continue;

        const is_bare_underscore = name.len == 1 and name[0] == '_';
        const has_double_underscore_prefix = name.len >= 2 and name[0] == '_' and name[1] == '_';
        if (!is_bare_underscore and !has_double_underscore_prefix) continue;

        const sym_idx: Ast.SymbolIndex = @enumFromInt(@as(u32, @intCast(i)));
        const range = v.symbolRange(sym_idx);
        const msg = if (is_bare_underscore)
            "identifier '_' is reserved: it may only appear as the left-hand side of a phony assignment"
        else
            v.fmtError("identifier '{s}' is reserved: names beginning with '__' may not be declared", .{name});
        v.addErrorWithCodeR(range, Diagnostic.Code.reserved_identifier, msg);
    }
}

// =========================================================================
// Phase 1: Collect Type Declarations
// =========================================================================

pub fn collectTypeDeclarations(v: *Validator) Allocator.Error!void {
    for (v.module.declarations.items) |decl| {
        switch (decl) {
            .@"struct" => |d| {
                const name = v.symbolName(d.name);
                if (name.len == 0) continue;
                // Create struct type placeholder
                const st = try v.arena.create(Types.Struct);
                st.* = .{
                    .name = name,
                    .fields = &.{},
                    .size_bytes = 0,
                    .align_bytes = 0,
                    .has_runtime_array = false,
                };
                try v.struct_types.put(v.arena, name, st);
            },
            .alias => |d| {
                const name = v.symbolName(d.name);
                if (name.len == 0) continue;
                // Placeholder — resolved in phase 2
                try v.alias_types.put(v.arena, name, null);
            },
            else => {},
        }
    }
}

// =========================================================================
// Phase 2: Resolve Struct Layouts
// =========================================================================

pub fn resolveStructLayouts(v: *Validator) Allocator.Error!void {
    for (v.module.declarations.items) |decl| {
        switch (decl) {
            .@"struct" => |d| try v.resolveOneStructLayout(d),
            .alias => |d| {
                const name = v.symbolName(d.name);
                const alias_type = v.resolveType(d.typ);
                if (alias_type) |at| {
                    try v.alias_types.put(v.arena, name, at);
                } else {
                    v.addErrorR(v.symbolRange(d.name), v.fmtError("cannot resolve type alias '{s}'", .{name}));
                }
            },
            else => {},
        }
    }
}

pub fn resolveOneStructLayout(v: *Validator, d: *Ast.StructDecl) Allocator.Error!void {
    const name = v.symbolName(d.name);
    const st = v.struct_types.get(name) orelse return;
    const name_range = v.symbolRange(d.name);

    // Spec: struct must have at least 1 member.
    if (d.members.items.len == 0) {
        v.addErrorWithCodeR(name_range, Diagnostic.Code.empty_struct, v.fmtError("struct '{s}' must have at least one member", .{name}));
        return;
    }

    // Spec: struct may have at most 1023 members.
    if (d.members.items.len > 1023) {
        v.addErrorWithCodeR(name_range, Diagnostic.Code.empty_struct, v.fmtError("struct '{s}' has {d} members, exceeding the maximum of 1023", .{ name, d.members.items.len }));
        return;
    }

    // Build fields list, checking for duplicate member names
    var fields: std.ArrayListUnmanaged(Types.StructField) = .empty;
    var seen_members: std.StringHashMapUnmanaged(LocRange) = .{};
    for (d.members.items) |member| {
        try validateStructMember(v, name, member, &fields, &seen_members);
    }

    // Runtime-sized array must be the last member (WGSL spec section 6.2.10).
    for (fields.items, 0..) |field, i| {
        if (field.typ == .array and field.typ.array.count == 0) {
            if (i != fields.items.len - 1) {
                v.addErrorWithCodeR(name_range, Diagnostic.Code.runtime_array_not_last, v.fmtError("runtime-sized array member '{s}' must be the last member of struct '{s}'", .{ field.name, name }));
            }
        }
    }

    st.fields = fields.items;
    st.computeLayout();
}

pub fn validateStructMember(v: *Validator, struct_name: []const u8, member: anytype, fields: *std.ArrayListUnmanaged(Types.StructField), seen_members: *std.StringHashMapUnmanaged(LocRange)) Allocator.Error!void {
    const member_name = v.symbolName(member.name);
    const member_range = v.symbolRange(member.name);
    if (seen_members.get(member_name)) |first_range| {
        v.addErrorWithRelatedR(member_range, Diagnostic.Code.duplicate_symbol, v.fmtError("duplicate member '{s}' in struct '{s}'", .{ member_name, struct_name }), v.makeRelatedR(first_range, "first declared here"));
        return;
    }
    try seen_members.put(v.arena, member_name, member_range);
    const member_type = v.resolveType(member.typ) orelse {
        if (member.typ != .ident)
            v.addErrorR(member_range, v.fmtError("cannot resolve type for member '{s}'", .{member_name}));
        return;
    };
    // Validate @align and @size attributes
    for (member.attributes.items) |attr| {
        validateStructMemberAttr(v, attr, member_type);
    }
    // Opaque types (texture, sampler) cannot appear in structs (WGSL spec section 6.2.10).
    if (member_type == .texture or member_type == .sampler) {
        v.addErrorWithCodeR(member_range, Diagnostic.Code.opaque_in_struct, v.fmtError("struct member '{s}' has opaque type '{s}' which cannot appear in a struct", .{ member_name, member_type.string() }));
    }

    // Array members in structs must have const counts, not override-expression counts.
    if (member.typ == .array) {
        if (member.typ.array.size) |size_expr| {
            const stage = v.classifyExprStage(size_expr);
            if (stage == .override_expr) {
                v.addErrorWithCodeR(member_range, Diagnostic.Code.invalid_array_count, v.fmtError("struct member '{s}' has override-expression array count; must be const", .{member_name}));
            }
        }
    }

    // A struct containing a runtime-sized array cannot be used as a member of another struct.
    if (member_type == .@"struct") {
        if (member_type.@"struct".has_runtime_array) {
            v.addErrorWithCodeR(member_range, Diagnostic.Code.runtime_array_not_last, v.fmtError("struct member '{s}' contains a runtime-sized array and cannot be nested in struct '{s}'", .{ member_name, struct_name }));
        }
    }

    try fields.append(v.arena, .{
        .name = member_name,
        .typ = member_type,
        .offset = 0,
    });
}

pub fn validateStructMemberAttr(v: *Validator, attr: Ast.Attribute, member_type: Types.Type) void {
    const ar = attrRange(&attr);
    if (std.mem.eql(u8, attr.name, "align") and attr.args.items.len > 0) {
        if (v.classifyExprStage(attr.args.items[0]) != .const_expr) {
            v.addErrorWithCodeR(ar, Diagnostic.Code.expression_not_const, "@align value must be a const-expression");
        } else if (v.tryExtractIntValue(attr.args.items[0])) |val| {
            if (val <= 0 or (@as(u64, @intCast(val)) & (@as(u64, @intCast(val)) - 1)) != 0) {
                v.addErrorWithCodeR(ar, Diagnostic.Code.invalid_attribute, v.fmtError("@align value must be a positive power of 2, got {d}", .{val}));
            }
        }
    }
    if (std.mem.eql(u8, attr.name, "size") and attr.args.items.len > 0) {
        if (v.classifyExprStage(attr.args.items[0]) != .const_expr) {
            v.addErrorWithCodeR(ar, Diagnostic.Code.expression_not_const, "@size value must be a const-expression");
        } else if (v.tryExtractIntValue(attr.args.items[0])) |val| {
            const type_size = member_type.size();
            if (val <= 0) {
                v.addErrorWithCodeR(ar, Diagnostic.Code.invalid_attribute, v.fmtError("@size value must be positive, got {d}", .{val}));
            } else if (type_size > 0 and @as(u32, @intCast(val)) < type_size) {
                v.addErrorWithCodeR(ar, Diagnostic.Code.invalid_attribute, v.fmtError("@size({d}) is less than the byte size of the type ({d})", .{ val, type_size }));
            }
        }
    }
}

// =========================================================================
// Phase 2.5: Detect Recursive Struct Definitions
// =========================================================================

pub fn checkRecursiveStructs(v: *Validator) Allocator.Error!void {
    var iter = v.struct_types.iterator();
    while (iter.next()) |entry| {
        if (try v.structContainsCycle(entry.key_ptr.*, entry.value_ptr.*)) {
            v.addErrorWithCodeR(v.findStructRange(entry.key_ptr.*), Diagnostic.Code.recursive_type, v.fmtError("struct '{s}' contains itself recursively", .{entry.key_ptr.*}));
        }
    }
}

/// Iterative cycle detection using a worklist. Returns true if `root_name`
/// is reachable from any nested struct field of `start`.
pub fn structContainsCycle(v: *Validator, root_name: []const u8, start: *Types.Struct) Allocator.Error!bool {
    var visited: std.StringHashMapUnmanaged(void) = .{};
    var worklist: std.ArrayListUnmanaged(*Types.Struct) = .empty;
    try worklist.append(v.arena, start);

    // Bounded iteration — struct count is finite and small.
    const max_iterations = v.struct_types.count() + 1;
    for (0..max_iterations) |_| {
        const current = worklist.pop() orelse return false;
        for (current.fields) |field| {
            const nested = extractNestedStruct(field.typ) orelse continue;
            if (std.mem.eql(u8, nested.name, root_name)) return true;
            if (visited.get(nested.name) != null) continue;
            try visited.put(v.arena, nested.name, {});
            try worklist.append(v.arena, nested);
        }
    }
    return false;
}

/// Extract a nested struct from a type, looking through arrays.
pub fn extractNestedStruct(typ: Types.Type) ?*Types.Struct {
    return switch (typ) {
        .@"struct" => |s| s,
        .array => |arr| switch (arr.element) {
            .@"struct" => |s| s,
            else => null,
        },
        else => null,
    };
}

pub fn findStructLoc(v: *Validator, name: []const u8) u32 {
    return v.findStructRange(name).start;
}

pub fn findStructRange(v: *Validator, name: []const u8) LocRange {
    for (v.module.declarations.items) |decl| {
        switch (decl) {
            .@"struct" => |d| {
                if (std.mem.eql(u8, v.symbolName(d.name), name)) return v.symbolRange(d.name);
            },
            else => {},
        }
    }
    return .{ .start = 0, .end = 1 };
}

// =========================================================================
// Phase 3.75: Detect Recursive Functions
// =========================================================================

pub fn checkRecursiveFunctions(v: *Validator) Allocator.Error!void {
    // Build call graph: for each function, collect which other functions it calls.
    // Key: function symbol index, Value: list of called function symbol indices.
    var call_graph: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)) = .{};

    for (v.module.declarations.items) |decl| {
        switch (decl) {
            .function => |fn_decl| {
                if (!fn_decl.name.isValid()) continue;
                const fn_idx = fn_decl.name.index();

                // Collect all symbol refs from the function body
                var all_refs: std.ArrayListUnmanaged(u32) = .empty;
                if (fn_decl.body) |body| {
                    try Dce.collectStmtRefs(v.arena, .{ .compound = body }, &all_refs);
                }

                // Filter to only function symbols
                var fn_refs: std.ArrayListUnmanaged(u32) = .empty;
                for (all_refs.items) |ref_idx| {
                    if (ref_idx < v.module.symbols.items.len and
                        v.module.symbols.items[ref_idx].kind == .function)
                    {
                        try fn_refs.append(v.arena, ref_idx);
                    }
                }

                try call_graph.put(v.arena, fn_idx, fn_refs);
            },
            else => {},
        }
    }

    // DFS cycle detection with 3-color marking (0=white, 1=gray, 2=black)
    var color: std.AutoHashMapUnmanaged(u32, u2) = .{};
    var iter = call_graph.iterator();
    while (iter.next()) |entry| {
        const fn_idx = entry.key_ptr.*;
        if ((color.get(fn_idx) orelse 0) == 0) {
            try v.dfsFunctionCycle(&call_graph, &color, fn_idx);
        }
    }
}

/// Iterative DFS cycle detection using an explicit stack.
pub fn dfsFunctionCycle(v: *Validator, call_graph: *const std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)), color: *std.AutoHashMapUnmanaged(u32, u2), start: u32) Allocator.Error!void {
    const Frame = struct { fn_idx: u32, callee_idx: u32 };
    var stack: std.ArrayListUnmanaged(Frame) = .empty;
    defer stack.deinit(v.arena);

    const num_syms: usize = v.module.symbols.items.len;
    // Pre: `start` must be a real symbol index. The call-graph is keyed on
    // symbol indices produced by `collectCallGraph`; a stale index slipping
    // past the build phase would lead to a nonsense DFS and a later
    // spurious `recursive_function` diagnostic.
    std.debug.assert(start < num_syms);

    try color.put(v.arena, start, 1); // gray
    try stack.append(v.arena, .{ .fn_idx = start, .callee_idx = 0 });

    for (0..num_syms * (num_syms + 1)) |_| {
        const frame = &(stack.items[stack.items.len - 1 ..][0]);
        const callees = call_graph.get(frame.fn_idx) orelse {
            // No callees — mark black and pop
            try color.put(v.arena, frame.fn_idx, 2);
            _ = stack.pop();
            if (stack.items.len == 0) break;
            continue;
        };

        if (frame.callee_idx >= callees.items.len) {
            // All callees processed — mark black and pop
            try color.put(v.arena, frame.fn_idx, 2);
            _ = stack.pop();
            if (stack.items.len == 0) break;
            continue;
        }

        const callee = callees.items[frame.callee_idx];
        frame.callee_idx += 1;

        const callee_color = color.get(callee) orelse 0;
        if (callee_color == 1) {
            // Gray → cycle found
            const sym_idx: Ast.SymbolIndex = @enumFromInt(callee);
            v.addErrorWithCodeR(v.symbolRange(sym_idx), Diagnostic.Code.recursive_function, v.fmtError("function '{s}' is recursive", .{v.symbolName(sym_idx)}));
        } else if (callee_color == 0) {
            // White → push new frame
            try color.put(v.arena, callee, 1); // gray
            try stack.append(v.arena, .{ .fn_idx = callee, .callee_idx = 0 });
        }
        // black (2) = already fully processed, skip
    } else unreachable;
}

// =========================================================================
// Phase 3: Validate Declarations
// =========================================================================

pub fn validateDeclarations(v: *Validator) Allocator.Error!void {
    for (v.module.declarations.items) |decl| {
        switch (decl) {
            // Module-scope `const` keeps abstract typing per WGSL §6.6 so
            // `const PI = 3.14;` remains `abstract-float` and can be used to
            // initialize both `f32` and `f16` slots downstream.
            .@"const" => |d| try v.validateConstDecl(d, .keep),
            .override => |d| try v.validateOverrideDecl(d),
            .@"var" => |d| try v.validateVarDecl(d),
            .let => |d| try v.validateLetDecl(d),
            .const_assert => |d| try v.validateConstAssert(d),
            else => {},
        }
    }
}

pub fn validateConstDecl(v: *Validator, d: *Ast.ConstDecl, handling: AbstractHandling) Allocator.Error!void {
    const name = v.symbolName(d.name);
    const r = v.symbolRange(d.name);

    // const must have an initializer
    if (d.initializer == null) {
        v.addErrorWithCodeR(r, Diagnostic.Code.missing_initializer, v.fmtError("'const {s}' requires an initializer", .{name}));
        return;
    }

    // Pre-resolve the annotation (if any) so the initializer inference can
    // record materialized types in `expr_types` — a hover inside
    // `const MY: f32 = 1 + 2` sees `f32`, not `abstract-int`. Without an
    // annotation, function-scope const (handling = .concretize, §15) pushes
    // `.concrete` so the cache records the default concrete type; module-
    // scope const (handling = .keep, §6.6) keeps `.none` so abstract types
    // survive through the hover.
    var decl_type: ?Types.Type = null;
    const ann_type: ?Types.Type = if (d.typ) |ast_type| v.resolveType(ast_type) else null;
    const exp: Expectation = if (ann_type) |dt| .{ .exact = dt } else switch (handling) {
        .keep => .none,
        .concretize => .concrete,
    };

    // Infer or check type (and capture staging for the const-expression rule).
    const init_r = try v.checkExprE(d.initializer.?, exp);
    const init_type = init_r.typ orelse return;

    if (d.typ) |ast_type| {
        decl_type = ann_type;
        if (decl_type) |dt| {
            if (!Types.canConvertTo(init_type, dt)) {
                const type_range = astTypeRange(ast_type);
                const related = if (type_range.start != 0) v.makeRelatedR(type_range, v.fmtError("type '{s}' declared here", .{dt.string()})) else &[_]Diagnostic.RelatedInfo{};
                v.addErrorWithRelatedR(r, Diagnostic.Code.type_mismatch, v.fmtError("cannot initialize '{s}' with type '{s}' (expected '{s}')", .{ name, init_type.string(), dt.string() }), related);
                return;
            }
        }
    } else {
        // Infer type from initializer. Module-scope `const` keeps abstract
        // typing (§6.6); function-scope `const` demotes to concrete (§15).
        decl_type = switch (handling) {
            .keep => init_type,
            .concretize => Types.concreteType(init_type),
        };
    }

    // const initializer must be a const-expression (not override or runtime).
    if (d.initializer) |_| {
        const stage = init_r.stage;
        if (stage == .override_expr) {
            v.addErrorWithCodeR(r, Diagnostic.Code.invalid_const_expr, v.fmtError("const '{s}' initializer references an override; use 'override' instead of 'const'", .{name}));
            return;
        }
        if (stage == .runtime_expr) {
            v.addErrorWithCodeR(r, Diagnostic.Code.invalid_const_expr, v.fmtError("const '{s}' initializer is not a const-expression", .{name}));
            return;
        }
    }

    // const must have constructible type. Abstract types are "non-constructible"
    // in the sense that they cannot instantiate runtime memory, but §6.6 allows
    // module-scope `const` to retain an abstract type when the caller opted in
    // to `.keep` — downstream uses concretize at their own decl-site expectation.
    if (decl_type) |dt| {
        if (!dt.isConstructible() and !(handling == .keep and !dt.isConcrete())) {
            v.addErrorWithCodeR(r, Diagnostic.Code.invalid_const_expr, v.fmtError("const '{s}' has non-constructible type '{s}'", .{ name, dt.string() }));
            return;
        }
    }

    // Propagate known integer values for const-expression resolution.
    // This enables array sizes, @workgroup_size, @id, @align, @size,
    // and switch case selectors to reference const declarations.
    if (d.name.isValid()) {
        if (d.initializer) |init| {
            if (v.tryExtractIntValue(init)) |val| {
                try v.const_values.put(v.arena, d.name.index(), val);
            }
        }
    }

    try v.setSymbolType(d.name, decl_type);
}

pub fn validateOverrideDecl(v: *Validator, d: *Ast.OverrideDecl) Allocator.Error!void {
    const r = v.symbolRange(d.name);
    const name = v.symbolName(d.name);

    // override must be concrete scalar type. Infer the type (and cache
    // staging) from the initializer when the user didn't write an
    // explicit type annotation — the second checkExpr below would be a
    // redundant re-traversal otherwise.
    var decl_type: ?Types.Type = null;
    var init_r: ?InferResult = null;
    if (d.typ) |ast_type| {
        decl_type = v.resolveType(ast_type);
    } else if (d.initializer) |init| {
        const r_init = try v.checkExpr(init);
        init_r = r_init;
        decl_type = r_init.typ;
    }

    if (decl_type == null) {
        if (d.typ == null or d.typ.? != .ident)
            v.addErrorWithCodeR(r, Diagnostic.Code.invalid_override, v.fmtError("cannot determine type for 'override {s}'", .{name}));
        return;
    }

    const dt = decl_type.?;
    // Must be concrete scalar
    switch (dt) {
        .scalar => |s| {
            if (!s.isConcrete()) {
                v.addErrorWithCodeR(r, Diagnostic.Code.invalid_override, v.fmtError("'override {s}' must be bool, i32, u32, f32, or f16, got '{s}'", .{ name, dt.string() }));
                return;
            }
        },
        else => {
            v.addErrorWithCodeR(r, Diagnostic.Code.invalid_override, v.fmtError("'override {s}' must be bool, i32, u32, f32, or f16, got '{s}'", .{ name, dt.string() }));
            return;
        },
    }

    if (d.initializer) |init| {
        // Re-check only when we didn't already infer from the initializer.
        // Thread `exact(dt)` so subexpressions in `override FOO: f32 = 1;`
        // record `f32` instead of the raw `abstract-int` inference.
        const r_init = init_r orelse try v.checkExprE(init, .{ .exact = dt });
        init_r = r_init;
        if (r_init.typ) |it| {
            if (!Types.canConvertTo(it, dt)) {
                if (d.typ) |ast_type| {
                    const type_range = astTypeRange(ast_type);
                    if (type_range.start != 0) {
                        v.addErrorWithRelatedR(r, Diagnostic.Code.type_mismatch, v.fmtError("cannot initialize '{s}' with type '{s}' (expected '{s}')", .{ name, it.string(), dt.string() }), v.makeRelatedR(type_range, v.fmtError("type '{s}' declared here", .{dt.string()})));
                    } else {
                        v.addErrorWithCodeR(r, Diagnostic.Code.type_mismatch, v.fmtError("cannot initialize '{s}' with type '{s}' (expected '{s}')", .{ name, it.string(), dt.string() }));
                    }
                } else {
                    v.addErrorWithCodeR(r, Diagnostic.Code.type_mismatch, v.fmtError("cannot initialize '{s}' with type '{s}' (expected '{s}')", .{ name, it.string(), dt.string() }));
                }
            }
        }
    }

    // Per WGSL §5475–5559 an override initializer must be a const- or
    // override-expression — references to runtime state (let/var/param)
    // are not permitted.
    if (d.initializer) |init| {
        const stage = if (init_r) |r_init| r_init.stage else v.classifyExprStage(init);
        if (stage == .runtime_expr) {
            v.addErrorWithCodeR(exprRange(init), Diagnostic.Code.expression_not_const, v.fmtError("'override {s}' initializer must be a const- or override-expression", .{name}));
        }
    }

    // Validate @id attribute: must be 0..65535, unique
    try v.validateOverrideId(d, name);
    v.rejectIOAttrsOnModuleDecl(d.attributes, "override");

    try v.setSymbolType(d.name, decl_type);
}

pub fn validateOverrideId(v: *Validator, d: *Ast.OverrideDecl, name: []const u8) Allocator.Error!void {
    for (d.attributes.items) |attr| {
        if (!std.mem.eql(u8, attr.name, "id")) continue;
        if (attr.args.items.len == 0) continue;

        // @id must be a const-expression
        const id_stage = v.classifyExprStage(attr.args.items[0]);
        if (id_stage != .const_expr) {
            v.addErrorWithCodeR(attrRange(&attr), Diagnostic.Code.expression_not_const, "@id value must be a const-expression");
            continue;
        }

        const id_val = v.tryExtractIntValue(attr.args.items[0]) orelse continue;
        const ar = attrRange(&attr);
        if (id_val < 0 or id_val > 65535) {
            v.addErrorWithCodeR(ar, Diagnostic.Code.invalid_override_id, v.fmtError("@id value {d} is out of range [0, 65535]", .{id_val}));
            return;
        }
        const id: u32 = @intCast(id_val);
        if (v.override_ids.get(id)) |existing| {
            v.addErrorWithRelatedR(ar, Diagnostic.Code.duplicate_override_id, v.fmtError("@id({d}) is already used by override '{s}'", .{ id, existing.name }), v.makeRelatedR(.{ .start = existing.loc, .end = existing.loc +| 1 }, v.fmtError("@id({d}) first used here", .{id})));
        } else {
            try v.override_ids.put(v.arena, id, .{ .name = name, .loc = attr.loc });
        }
        return;
    }
}

pub fn validateVarDecl(v: *Validator, d: *Ast.VarDecl) Allocator.Error!void {
    const r = v.symbolRange(d.name);
    const name = v.symbolName(d.name);

    // Determine type (and cache the initializer's inference so the
    // compatibility check below doesn't walk the expression twice).
    var decl_type: ?Types.Type = null;
    var init_r: ?InferResult = null;
    if (d.typ) |ast_type| {
        decl_type = v.resolveType(ast_type);
    } else if (d.initializer) |init| {
        // `var` always concretizes; push `.concrete` so the initializer's
        // subexpressions cache their default concrete type for hovers, even
        // though we still apply `Types.concreteType` on the returned type
        // for the decl itself.
        const r_init = try v.checkExprE(init, .concrete);
        init_r = r_init;
        decl_type = r_init.typ;
        if (decl_type) |dt| decl_type = Types.concreteType(dt);
    }

    if (decl_type == null) {
        // Skip if resolveType already reported "unknown type" for .ident
        if (d.typ == null or d.typ.? != .ident)
            v.addErrorWithCodeR(r, Diagnostic.Code.type_mismatch, v.fmtError("cannot determine type for 'var {s}'", .{name}));
        return;
    }

    const dt = decl_type.?;

    // Validate address space constraints
    v.validateAddressSpace(d, dt);

    // Check initializer compatibility. When the `var` carried an explicit
    // type annotation we thread it down as an `exact(dt)` expectation so the
    // initializer's subexpressions record `dt` in `expr_types` rather than
    // the raw abstract inference. When the type was inferred above, `init_r`
    // is already populated and no re-check is needed.
    if (d.initializer) |init| {
        const r_init = init_r orelse try v.checkExprE(init, .{ .exact = dt });
        if (r_init.typ) |it| {
            if (!Types.canConvertTo(it, dt)) {
                if (d.typ) |ast_type| {
                    const type_range = astTypeRange(ast_type);
                    if (type_range.start != 0) {
                        v.addErrorWithRelatedR(r, Diagnostic.Code.type_mismatch, v.fmtError("cannot initialize '{s}' with type '{s}' (expected '{s}')", .{ name, it.string(), dt.string() }), v.makeRelatedR(type_range, v.fmtError("type '{s}' declared here", .{dt.string()})));
                    } else {
                        v.addErrorWithCodeR(r, Diagnostic.Code.type_mismatch, v.fmtError("cannot initialize '{s}' with type '{s}' (expected '{s}')", .{ name, it.string(), dt.string() }));
                    }
                } else {
                    v.addErrorWithCodeR(r, Diagnostic.Code.type_mismatch, v.fmtError("cannot initialize '{s}' with type '{s}' (expected '{s}')", .{ name, it.string(), dt.string() }));
                }
            }
        }
    }

    try v.validateBindingAttributes(d, name, r);
    v.rejectIOAttrsOnModuleDecl(d.attributes, "var");

    try v.setSymbolType(d.name, decl_type);

    // Record the variable's address space and access mode for `&` so that
    // the resulting pointer type carries the actual storage class instead of
    // a hardcoded `function` / `read_write`. We normalize `.none` here with
    // the spec defaults per address space (WGSL §8).
    const as_norm: Ast.AddressSpace = if (d.address_space == .none) .function else d.address_space;
    const am_norm: Ast.AccessMode = if (d.access_mode != .none) d.access_mode else switch (as_norm) {
        .uniform => .read,
        .storage => .read,
        .handle => .read,
        else => .read_write,
    };
    try v.var_info.put(v.arena, d.name.index(), .{ .address_space = as_norm, .access_mode = am_norm });
}

pub fn validateBindingAttributes(v: *Validator, d: *Ast.VarDecl, name: []const u8, r: LocRange) Allocator.Error!void {
    if (d.address_space != .uniform and d.address_space != .storage) return;

    var has_group = false;
    var has_binding = false;
    var group_val: ?i64 = null;
    var binding_val: ?i64 = null;
    for (d.attributes.items) |attr| {
        if (std.mem.eql(u8, attr.name, "group")) {
            has_group = true;
            if (attr.args.items.len > 0) group_val = v.tryExtractIntValue(attr.args.items[0]);
        }
        if (std.mem.eql(u8, attr.name, "binding")) {
            has_binding = true;
            if (attr.args.items.len > 0) binding_val = v.tryExtractIntValue(attr.args.items[0]);
        }
    }
    if (!has_group or !has_binding) {
        v.addErrorWithCodeR(r, Diagnostic.Code.missing_binding, v.fmtError("{s} var '{s}' requires @group and @binding attributes", .{ d.address_space.string(), name }));
    } else if (group_val != null and binding_val != null) {
        const gv: u32 = if (group_val.? >= 0 and group_val.? <= std.math.maxInt(u32)) @intCast(group_val.?) else 0;
        const bv: u32 = if (binding_val.? >= 0 and binding_val.? <= std.math.maxInt(u32)) @intCast(binding_val.?) else 0;
        const key = (@as(u64, gv) << 32) | @as(u64, bv);
        // When multiple entry points exist, defer duplicate checks to per-entry-point pass
        if (!v.multi_entry_point) {
            if (v.binding_pairs.get(key)) |existing| {
                v.addErrorWithRelatedR(r, Diagnostic.Code.duplicate_binding, v.fmtError("@group({d}) @binding({d}) is already used by '{s}'", .{ group_val.?, binding_val.?, existing.name }), v.makeRelatedR(.{ .start = existing.loc, .end = existing.loc +| 1 }, v.fmtError("'{s}' declared here", .{existing.name})));
            }
        }
        try v.binding_pairs.put(v.arena, key, .{ .name = name, .loc = r.start });
        // Collect binding info for pattern analysis
        try v.binding_infos.append(v.arena, .{
            .name = name,
            .loc = r.start,
            .group = gv,
            .binding = bv,
            .sym_idx = d.name.index(),
        });
    }
}

/// Check for suspicious binding patterns: gaps in binding numbers and unusually high values.
pub fn checkSuspiciousBindingPatterns(v: *Validator) void {
    if (v.binding_infos.items.len == 0) return;

    // Group bindings by @group value. Use a simple approach: find max group,
    // then iterate per group. Limit to groups 0..15 to avoid huge allocations.
    var max_group: u32 = 0;
    for (v.binding_infos.items) |info| {
        if (info.group > 15) {
            // High group number warning
            v.diags.add(v.arena, .{
                .severity = .info,
                .code = "W0102",
                .message = v.fmtError("@group({d}) is unusually high — typical WebGPU pipelines use groups 0–3", .{info.group}),
                .range = v.diags.makeRange(info.loc, info.loc +| @as(u32, @intCast(info.name.len))),
            });
        } else {
            if (info.group > max_group) max_group = info.group;
        }
        if (info.binding > 15) {
            v.diags.add(v.arena, .{
                .severity = .info,
                .code = "W0102",
                .message = v.fmtError("@binding({d}) is unusually high — verify this is intentional", .{info.binding}),
                .range = v.diags.makeRange(info.loc, info.loc +| @as(u32, @intCast(info.name.len))),
            });
        }
    }

    // Check for gaps within each group (only for groups 0..max_group)
    for (0..max_group + 1) |g| {
        const group: u32 = @intCast(g);
        // Collect binding numbers for this group
        var min_binding: u32 = std.math.maxInt(u32);
        var max_binding: u32 = 0;
        var count: u32 = 0;
        for (v.binding_infos.items) |info| {
            if (info.group != group) continue;
            if (info.binding < min_binding) min_binding = info.binding;
            if (info.binding > max_binding) max_binding = info.binding;
            count += 1;
        }
        if (count < 2) continue;
        // If there are gaps (range is larger than count), warn on each gap
        if (max_binding - min_binding + 1 > count and max_binding <= 15) {
            // Find the specific gaps
            for (min_binding..max_binding + 1) |b| {
                const binding: u32 = @intCast(b);
                var found = false;
                for (v.binding_infos.items) |info| {
                    if (info.group == group and info.binding == binding) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    // Find the binding just before the gap to attach the warning to
                    var best_loc: u32 = 0;
                    var best_name: []const u8 = "";
                    for (v.binding_infos.items) |info| {
                        if (info.group == group and info.binding < binding and info.binding >= best_loc) {
                            best_loc = info.loc;
                            best_name = info.name;
                        }
                    }
                    if (best_name.len > 0) {
                        v.diags.add(v.arena, .{
                            .severity = .info,
                            .code = "W0101",
                            .message = v.fmtError("gap in @group({d}) bindings: @binding({d}) is missing", .{ group, binding }),
                            .range = v.diags.makeRange(best_loc, best_loc +| @as(u32, @intCast(best_name.len))),
                        });
                    }
                }
            }
        }
    }
}

pub fn countEntryPoints(module: *const Ast.Module) u32 {
    var count: u32 = 0;
    for (module.symbols.items) |sym| {
        if (sym.flags.is_entry_point) count += 1;
    }
    return count;
}

/// Per-entry-point binding collision detection.
/// When multiple entry points exist, checks that each entry point's reachable
/// set of bindings has no duplicates. WebGPU allows different entry points to
/// share the same @group/@binding pair since they use separate pipeline layouts.
pub fn validatePerEntryPointBindings(v: *Validator) Allocator.Error!void {
    if (!v.multi_entry_point) return;
    if (v.binding_infos.items.len < 2) return;

    // Build dependency graph using the same logic as DCE
    var deps: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)) = .empty;
    try Dce.buildDependencyGraph(v.arena, v.module, &deps);

    // For each entry point, BFS to find reachable symbols, then check binding collisions
    for (v.module.symbols.items, 0..) |sym, idx| {
        if (!sym.flags.is_entry_point) continue;

        // BFS from this entry point
        var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
        var queue: std.ArrayListUnmanaged(u32) = .empty;
        try queue.append(v.arena, @intCast(idx));

        var head: usize = 0;
        while (head < queue.items.len) {
            const current = queue.items[head];
            head += 1;
            if (visited.contains(current)) continue;
            try visited.put(v.arena, current, {});

            if (deps.get(current)) |dep_list| {
                for (dep_list.items) |dep_idx| {
                    if (!visited.contains(dep_idx)) {
                        try queue.append(v.arena, dep_idx);
                    }
                }
            }
        }

        // Check for duplicate bindings within this entry point's reachable set
        var ep_bindings: std.AutoHashMapUnmanaged(u64, BindingInfo) = .empty;
        for (v.binding_infos.items) |info| {
            if (!visited.contains(info.sym_idx)) continue;
            const key = (@as(u64, info.group) << 32) | @as(u64, info.binding);
            if (ep_bindings.get(key)) |existing| {
                const r: LocRange = .{ .start = info.loc, .end = info.loc +| @as(u32, @intCast(info.name.len)) };
                v.addErrorWithRelatedR(r, Diagnostic.Code.duplicate_binding, v.fmtError("@group({d}) @binding({d}) is already used by '{s}' in entry point '{s}'", .{ info.group, info.binding, existing.name, sym.original_name }), v.makeRelatedR(.{ .start = existing.loc, .end = existing.loc +| @as(u32, @intCast(existing.name.len)) }, v.fmtError("'{s}' declared here", .{existing.name})));
            } else {
                try ep_bindings.put(v.arena, key, info);
            }
        }
    }
}

pub fn validateLetDecl(v: *Validator, d: *Ast.LetDecl) Allocator.Error!void {
    const r = v.symbolRange(d.name);
    const name = v.symbolName(d.name);

    // let must have an initializer
    if (d.initializer == null) {
        v.addErrorWithCodeR(r, Diagnostic.Code.missing_initializer, v.fmtError("'let {s}' requires an initializer", .{name}));
        return;
    }

    var decl_type: ?Types.Type = null;
    const ann_type: ?Types.Type = if (d.typ) |ast_type| v.resolveType(ast_type) else null;
    // `let` always concretizes (function scope, §15); without an annotation
    // push `.concrete` so the initializer's subexpressions cache their
    // default concrete type for LSP hovers.
    const exp: Expectation = if (ann_type) |dt| .{ .exact = dt } else .concrete;

    const init_type = (try v.checkExprE(d.initializer.?, exp)).typ orelse return;

    if (!init_type.isConstructible() and init_type != .pointer and init_type.isConcrete()) {
        v.addErrorWithCodeR(r, Diagnostic.Code.type_mismatch, v.fmtError("'let {s}' requires a constructible or pointer type, got '{s}'", .{ name, init_type.string() }));
        return;
    }

    if (d.typ) |ast_type| {
        decl_type = ann_type;
        if (decl_type) |dt| {
            if (!Types.canConvertTo(init_type, dt)) {
                const type_range = astTypeRange(ast_type);
                const related = if (type_range.start != 0) v.makeRelatedR(type_range, v.fmtError("type '{s}' declared here", .{dt.string()})) else &[_]Diagnostic.RelatedInfo{};
                v.addErrorWithRelatedR(r, Diagnostic.Code.type_mismatch, v.fmtError("cannot initialize '{s}' with type '{s}' (expected '{s}')", .{ name, init_type.string(), dt.string() }), related);
                return;
            }
        }
    } else {
        // Infer type from initializer, converting abstract to concrete
        decl_type = Types.concreteType(init_type);
    }

    try v.setSymbolType(d.name, decl_type);
}

pub fn validateConstAssert(v: *Validator, d: *Ast.ConstAssertDecl) Allocator.Error!void {
    // Per WGSL §11.9 a const_assert expression must be a const-expression.
    // Override- and runtime-expressions are rejected up front so we don't
    // emit a misleading "not bool" error when the real problem is staging.
    // Single checkExpr run carries both the inferred type and stage; the
    // staging check only fires when inference succeeded so that a type
    // error isn't shadowed by a spurious staging error.
    const result = try v.checkExpr(d.expr);
    if (result.typ == null) return;
    if (result.stage != .const_expr) {
        v.addErrorWithCodeR(exprSpan(d.expr), Diagnostic.Code.expression_not_const, "const_assert expression must be a const-expression");
        return;
    }

    const expr_type = result.typ.?;
    if (!expr_type.eql(Types.Bool)) {
        v.addErrorWithCodeR(exprSpan(d.expr), Diagnostic.Code.invalid_const_expr, v.fmtError("const_assert expression must be 'bool', got '{s}'", .{expr_type.string()}));
        return;
    }

    // WGSL spec section 9.6: const_assert condition must evaluate to true.
    if (v.tryEvalConstBool(d.expr)) |val| {
        if (!val) {
            v.addErrorWithCodeR(exprSpan(d.expr), Diagnostic.Code.const_assert_failed, "const_assert condition is false");
        }
    }
}

pub fn validateAddressSpace(v: *Validator, d: *Ast.VarDecl, var_type: Types.Type) void {
    const r = v.symbolRange(d.name);
    const name = v.symbolName(d.name);
    // WGSL §8: `function` is only valid inside a function body. Module-scope
    // `var<function> x: T;` is rejected here (v.current_func == null marks
    // module scope — set in validateFunction, cleared on return).
    if (v.current_func == null and d.address_space == .function) {
        v.addErrorWithCodeR(r, Diagnostic.Code.invalid_address_space, v.fmtError("module-scope 'var {s}' cannot use 'function' address space (valid only inside a function body)", .{name}));
        return;
    }
    // Handle types (texture, sampler) must not specify an address space
    const is_handle = var_type == .texture or var_type == .sampler;
    if (is_handle and d.address_space != .none) {
        v.addErrorWithCodeR(r, Diagnostic.Code.invalid_address_space, v.fmtError("var '{s}' of handle type must not specify an address space", .{name}));
        return;
    }
    // WGSL spec section 6.2.8: atomic types can only be in workgroup or storage(read_write) address space.
    if (typeContainsAtomic(var_type)) {
        if (d.address_space != .workgroup and d.address_space != .storage) {
            v.addErrorWithCodeR(r, Diagnostic.Code.invalid_atomic_type, v.fmtError("atomic var '{s}' must be in 'workgroup' or 'storage' address space", .{name}));
        } else if (d.address_space == .storage and d.access_mode != .read_write and d.access_mode != .none) {
            v.addErrorWithCodeR(r, Diagnostic.Code.invalid_atomic_type, v.fmtError("atomic var '{s}' in storage address space must have 'read_write' access mode", .{name}));
        }
    }

    switch (d.address_space) {
        .workgroup => {
            if (!var_type.isStorable()) {
                v.addErrorWithCodeR(r, Diagnostic.Code.invalid_workgroup_var, v.fmtError("workgroup var '{s}' has non-storable type '{s}'", .{ name, var_type.string() }));
            }
        },
        .uniform => {
            if (!var_type.isHostShareable()) {
                v.addErrorWithCodeR(r, Diagnostic.Code.invalid_uniform_var, v.fmtError("uniform var '{s}' has non-host-shareable type '{s}'", .{ name, var_type.string() }));
            }
            if (d.initializer != null) {
                v.addErrorWithCodeR(r, Diagnostic.Code.invalid_initializer, v.fmtError("uniform var '{s}' cannot have an initializer", .{name}));
            }
            // Uniform buffer layout: arrays must have element alignment >= 16
            v.checkUniformLayout(var_type, r, name);
        },
        .storage => {
            if (!var_type.isHostShareable()) {
                v.addErrorWithCodeR(r, Diagnostic.Code.invalid_storage_var, v.fmtError("storage var '{s}' has non-host-shareable type '{s}'", .{ name, var_type.string() }));
            }
            if (d.initializer != null) {
                v.addErrorWithCodeR(r, Diagnostic.Code.invalid_initializer, v.fmtError("storage var '{s}' cannot have an initializer", .{name}));
            }
            if (d.access_mode == .write) {
                v.addErrorWithCodeR(r, Diagnostic.Code.invalid_access_mode, v.fmtError("storage var '{s}' access mode must be 'read' or 'read_write'", .{name}));
            }
        },
        else => {},
    }
}

pub fn checkUniformLayout(v: *Validator, typ: Types.Type, r: LocRange, var_name: []const u8) void {
    switch (typ) {
        .array => |a| {
            const elem_align = a.element.alignment();
            if (elem_align > 0 and elem_align < 16) {
                v.addErrorWithCodeR(r, Diagnostic.Code.invalid_uniform_var, v.fmtError("uniform var '{s}' contains array with element alignment {d} (uniform requires 16)", .{ var_name, elem_align }));
            }
        },
        .@"struct" => |s| {
            for (s.fields) |field| {
                v.checkUniformLayout(field.typ, r, var_name);
            }
        },
        else => {},
    }
}

// =========================================================================
// Phase 3.5: Register Function Signatures
// =========================================================================

/// Pre-registers all function types before validating bodies.
/// This enables forward references — function A can call function B
/// even if B is declared after A.
pub fn registerFunctionSignatures(v: *Validator) Allocator.Error!void {
    for (v.module.declarations.items) |decl| {
        switch (decl) {
            .function => |fn_decl| {
                var param_types: std.ArrayListUnmanaged(Types.Type) = .empty;
                for (fn_decl.parameters.items) |param| {
                    if (v.resolveType(param.typ)) |pt| {
                        try param_types.append(v.arena, pt);
                    }
                }

                var return_type: ?Types.Type = null;
                if (fn_decl.return_type) |rt| {
                    return_type = v.resolveType(rt);
                }

                if (fn_decl.name.isValid()) {
                    const fn_type = Types.functionType(v.arena, param_types.items, return_type) catch null;
                    if (fn_type) |ft| {
                        try v.setSymbolType(fn_decl.name, ft);
                    }
                }
            },
            else => {},
        }
    }
}

// =========================================================================
// Phase 4: Validate Functions
// =========================================================================

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


pub fn determineShaderStage(fn_decl: *Ast.FunctionDecl) ShaderStage {
    for (fn_decl.attributes.items) |attr| {
        if (std.mem.eql(u8, attr.name, "vertex")) return .vertex;
        if (std.mem.eql(u8, attr.name, "fragment")) return .fragment;
        if (std.mem.eql(u8, attr.name, "compute")) return .compute;
    }
    return .none;
}

pub fn resolveFunctionParameters(v: *Validator, fn_decl: *Ast.FunctionDecl) Allocator.Error![]Types.Type {
    var param_types: std.ArrayListUnmanaged(Types.Type) = .empty;
    for (fn_decl.parameters.items) |param| {
        const param_type = v.resolveType(param.typ);
        if (param_type) |pt| {
            try v.setSymbolType(param.name, pt);
            try param_types.append(v.arena, pt);
            // WGSL spec section 8.6: parameters must be constructible, pointer, texture, or sampler.
            if (!pt.isConstructible() and pt != .pointer and pt != .texture and pt != .sampler) {
                v.addErrorWithCodeR(v.symbolRange(param.name), Diagnostic.Code.invalid_arg_type, v.fmtError("parameter '{s}' has non-constructible type '{s}'; must be constructible, pointer, texture, or sampler", .{ v.symbolName(param.name), pt.string() }));
            }
            // Pointer parameters: address space must be function or private by default.
            // With 'enable unrestricted_pointer_parameters', all address spaces are allowed.
            if (pt == .pointer and !v.enabled_features.contains("unrestricted_pointer_parameters")) {
                const space = pt.pointer.address_space;
                if (space != .function and space != .private and space != .none) {
                    v.addErrorWithCodeR(v.symbolRange(param.name), Diagnostic.Code.invalid_address_space, v.fmtError("pointer parameter '{s}' must use 'function' or 'private' address space, got '{s}' (enable 'unrestricted_pointer_parameters' to allow this)", .{ v.symbolName(param.name), space.string() }));
                }
            }
        }
        try v.validateParameterAttributes(param);
    }
    return param_types.items;
}

pub fn validateParameterAttributes(v: *Validator, param: Ast.Parameter) Allocator.Error!void {
    const param_type = v.resolveType(param.typ);
    const param_range = v.symbolRange(param.name);
    for (param.attributes.items) |attr| {
        if (std.mem.eql(u8, attr.name, "location")) {
            if (v.current_stage == .none) {
                v.addErrorWithCodeR(attrRange(&attr), Diagnostic.Code.invalid_attribute, "@location is only valid on entry point parameters");
            } else if (v.current_stage == .compute) {
                v.addErrorWithCodeR(attrRange(&attr), Diagnostic.Code.invalid_attribute, "compute shaders cannot have user-defined inputs (@location)");
            } else if (param_type) |pt| {
                v.validateLocationType(pt, param_range);
            }
            v.validateLocationArgExpr(&attr);
        } else if (std.mem.eql(u8, attr.name, "builtin")) {
            // @builtin must only be applied to entry-point params, return, or struct
            // members (WGSL spec §11.1). Reject when outside an entry point, but
            // still run the name check below so code-actions can offer suggestions.
            if (v.current_stage == .none) {
                v.addErrorWithCodeR(attrRange(&attr), Diagnostic.Code.invalid_attribute, "@builtin is only valid on entry point function parameters");
            }
            if (attr.args.items.len > 0) {
                switch (attr.args.items[0]) {
                    .ident => |ident| {
                        try v.validateBuiltinAttr(ident.name, true, attr.loc, param_type, param_range);
                    },
                    else => {},
                }
            }
        }
    }
}

/// WGSL spec §11.1 (`builtin`) / §11.2 (`location`): both attributes are only
/// valid on entry-point function parameters, entry-point function return
/// types, or struct members. This helper catches the non-entry *return*
/// site; parameters go through `validateParameterAttributes` and entry-point
/// returns are fully validated by `validateEntryPointIO`.
pub fn validateReturnAttributes(v: *Validator, fn_decl: *Ast.FunctionDecl) void {
    if (v.current_stage != .none) return;
    for (fn_decl.return_attr.items) |attr| {
        if (std.mem.eql(u8, attr.name, "location")) {
            v.addErrorWithCodeR(attrRange(&attr), Diagnostic.Code.invalid_attribute, "@location is only valid on entry point function return types");
        } else if (std.mem.eql(u8, attr.name, "builtin")) {
            v.addErrorWithCodeR(attrRange(&attr), Diagnostic.Code.invalid_attribute, "@builtin is only valid on entry point function return types");
        }
    }
}

/// WGSL spec §11.1 (`builtin`) / §11.2 (`location`): these attributes must
/// not appear on module-scope declarations. `site` is inserted into the
/// diagnostic (e.g. `"var"`, `"override"`).
pub fn rejectIOAttrsOnModuleDecl(v: *Validator, attrs: std.ArrayListUnmanaged(Ast.Attribute), site: []const u8) void {
    for (attrs.items) |attr| {
        if (std.mem.eql(u8, attr.name, "location")) {
            v.addErrorWithCodeR(attrRange(&attr), Diagnostic.Code.invalid_attribute, v.fmtError("@location is not valid on module-scope {s} declarations", .{site}));
        } else if (std.mem.eql(u8, attr.name, "builtin")) {
            v.addErrorWithCodeR(attrRange(&attr), Diagnostic.Code.invalid_attribute, v.fmtError("@builtin is not valid on module-scope {s} declarations", .{site}));
        }
    }
}

/// WGSL spec §11.1: @location argument must be a const-expression that
/// resolves to a non-negative i32 or u32.
pub fn validateLocationArgExpr(v: *Validator, attr: *const Ast.Attribute) void {
    if (attr.args.items.len == 0) return;
    const arg = attr.args.items[0];
    if (v.classifyExprStage(arg) != .const_expr) {
        v.addErrorWithCodeR(attrRange(attr), Diagnostic.Code.invalid_location, "@location argument must be a const-expression");
        return;
    }
    if (v.tryExtractIntValue(arg)) |val| {
        if (val < 0) {
            v.addErrorWithCodeR(attrRange(attr), Diagnostic.Code.invalid_location, v.fmtError("@location value must be non-negative, got {d}", .{val}));
        }
    }
}

pub fn validateEntryPoint(v: *Validator, fn_decl: *Ast.FunctionDecl) Allocator.Error!void {
    const fn_range = v.symbolRange(fn_decl.name);
    switch (v.current_stage) {
        .vertex => {
            // Must return @builtin(position)
            if (!v.vertexHasPositionOutput(fn_decl)) {
                v.addErrorWithCodeDataR(fn_range, Diagnostic.Code.invalid_entry_point, v.fmtError("vertex entry point '{s}' must include @builtin(position) output", .{v.symbolName(fn_decl.name)}), .vertex_missing_builtin_position);
            }
        },
        .fragment => {
            // Fragment can return void or typed output
        },
        .compute => {
            // Must have @workgroup_size
            var has_workgroup_size = false;
            for (fn_decl.attributes.items) |attr| {
                if (std.mem.eql(u8, attr.name, "workgroup_size")) {
                    has_workgroup_size = true;
                    if (attr.args.items.len == 0) {
                        v.addErrorWithCodeR(attrRange(&attr), Diagnostic.Code.invalid_attribute, "@workgroup_size requires at least one argument");
                    }
                    // Each @workgroup_size arg must be a const or override expression,
                    // and must evaluate to a positive integer (WGSL spec section 9.5).
                    var wg_product: u64 = 1;
                    for (attr.args.items) |arg| {
                        const stage = v.classifyExprStage(arg);
                        if (stage == .runtime_expr) {
                            v.addErrorWithCodeR(exprRange(arg), Diagnostic.Code.expression_not_const, "@workgroup_size arguments must be const-expressions or override-expressions");
                        }
                        if (v.tryExtractIntValue(arg)) |val| {
                            if (val <= 0) {
                                v.addErrorWithCodeR(exprRange(arg), Diagnostic.Code.invalid_attribute, v.fmtError("@workgroup_size dimension must be at least 1, got {d}", .{val}));
                            } else {
                                wg_product *|= @intCast(val);
                            }
                        }
                    }
                    // Product of dimensions must not overflow u32.
                    if (wg_product > std.math.maxInt(u32)) {
                        v.addErrorWithCodeR(attrRange(&attr), Diagnostic.Code.invalid_attribute, "@workgroup_size product exceeds maximum (4294967295)");
                    }
                }
            }
            if (!has_workgroup_size) {
                v.addErrorWithCodeR(fn_range, Diagnostic.Code.missing_attribute, v.fmtError("compute entry point '{s}' requires @workgroup_size", .{v.symbolName(fn_decl.name)}));
            }

            // Must not return a value
            if (fn_decl.return_type != null) {
                v.addErrorWithCodeR(fn_range, Diagnostic.Code.invalid_entry_point, v.fmtError("compute entry point '{s}' must not return a value", .{v.symbolName(fn_decl.name)}));
            }
        },
        .none => {},
    }

    // Validate entry point IO: duplicate @location and missing @builtin/@location on struct members
    try v.validateEntryPointIO(fn_decl);
}

pub const OutputLocEntry = struct { loc: u32, blend_src: ?i64 };
pub const BlendSrcEntry = struct { location: i64, value: i64, typ: ?Types.Type, member_range: LocRange, attr_loc: u32 };

pub fn validateEntryPointIO(v: *Validator, fn_decl: *Ast.FunctionDecl) Allocator.Error!void {
    try v.validateEntryPointInputs(fn_decl);
    try v.validateEntryPointOutputs(fn_decl);
}

pub fn validateEntryPointInputs(v: *Validator, fn_decl: *Ast.FunctionDecl) Allocator.Error!void {
    var input_builtins: std.StringHashMapUnmanaged(u32) = .{};
    var input_locations: std.AutoHashMapUnmanaged(i64, u32) = .{};
    for (fn_decl.parameters.items) |param| {
        // Direct @location on parameter
        if (getLocationInfo(param.attributes)) |info| {
            if (input_locations.get(info.value)) |first_loc| {
                const loc_u32: u32 = std.math.cast(u32, info.value) orelse 0;
                v.addErrorWithRelatedDataR(v.symbolRange(param.name), Diagnostic.Code.invalid_shader_io, v.fmtError("duplicate input @location({d})", .{info.value}), v.makeRelatedR(.{ .start = first_loc, .end = first_loc +| 1 }, v.fmtError("@location({d}) first used here", .{info.value})), .{ .duplicate_location = loc_u32 });
            } else {
                try input_locations.put(v.arena, info.value, info.loc);
            }
        }
        // If param type is a struct, check its members
        const param_type = v.resolveType(param.typ) orelse continue;
        if (param_type == .@"struct") {
            if (v.findStructDecl(param_type.@"struct".name)) |sd| {
                for (sd.members.items) |member| {
                    // WGSL spec section 10.1: entry point I/O struct members must not be struct types.
                    const mt = v.resolveType(member.typ);
                    if (mt != null and mt.? == .@"struct") {
                        v.addErrorWithCodeR(v.symbolRange(member.name), Diagnostic.Code.invalid_shader_io, v.fmtError("entry point I/O member '{s}' cannot be a struct type", .{v.symbolName(member.name)}));
                    }
                    if (!hasLocationOrBuiltin(member.attributes)) {
                        v.addErrorWithCodeR(v.symbolRange(member.name), Diagnostic.Code.invalid_shader_io, v.fmtError("entry point struct member '{s}' must have @builtin or @location", .{v.symbolName(member.name)}));
                    }
                    if (getLocationInfo(member.attributes)) |info| {
                        if (input_locations.get(info.value)) |first_loc| {
                            const loc_u32: u32 = std.math.cast(u32, info.value) orelse 0;
                            v.addErrorWithRelatedDataR(v.symbolRange(member.name), Diagnostic.Code.invalid_shader_io, v.fmtError("duplicate input @location({d})", .{info.value}), v.makeRelatedR(.{ .start = first_loc, .end = first_loc +| 1 }, v.fmtError("@location({d}) first used here", .{info.value})), .{ .duplicate_location = loc_u32 });
                        } else {
                            try input_locations.put(v.arena, info.value, info.loc);
                        }
                    }
                    // Validate @interpolate on fragment inputs
                    if (v.current_stage == .fragment) {
                        v.validateInterpolation(member.attributes, mt, v.symbolLoc(member.name));
                    }
                    v.validateInvariantAttr(member.attributes, v.symbolLoc(member.name));
                    // @location and @builtin on same member is invalid (WGSL spec section 10.1).
                    if (hasAttr(member.attributes, "location") and hasAttr(member.attributes, "builtin")) {
                        v.addErrorWithCodeR(v.symbolRange(member.name), Diagnostic.Code.duplicate_attribute, v.fmtError("member '{s}' cannot have both @location and @builtin", .{v.symbolName(member.name)}));
                    }
                    // Duplicate @builtin in entry point input.
                    if (getBuiltinAttrName(member.attributes)) |bn| {
                        if (input_builtins.get(bn)) |_| {
                            v.addErrorWithCodeR(v.symbolRange(member.name), Diagnostic.Code.invalid_shader_io, v.fmtError("duplicate @builtin({s}) in entry point input", .{bn}));
                        } else {
                            try input_builtins.put(v.arena, bn, v.symbolLoc(member.name));
                        }
                    }
                    // @builtin stage/direction + required type.
                    for (member.attributes.items) |a| {
                        if (!std.mem.eql(u8, a.name, "builtin") or a.args.items.len == 0) continue;
                        switch (a.args.items[0]) {
                            .ident => |ident| try v.validateBuiltinAttr(ident.name, true, a.loc, mt, v.symbolRange(member.name)),
                            else => {},
                        }
                    }
                    // @location: reject on compute inputs (user-defined I/O forbidden),
                    // otherwise check the member type is numeric scalar/vector.
                    if (hasAttr(member.attributes, "location")) {
                        if (v.current_stage == .compute) {
                            v.addErrorWithCodeR(v.symbolRange(member.name), Diagnostic.Code.invalid_attribute, v.fmtError("compute shaders cannot have user-defined inputs (@location on struct member '{s}')", .{v.symbolName(member.name)}));
                        } else if (mt) |member_type| {
                            v.validateLocationType(member_type, v.symbolRange(member.name));
                        }
                        for (member.attributes.items) |*a| {
                            if (std.mem.eql(u8, a.name, "location")) v.validateLocationArgExpr(a);
                        }
                    }
                    // @blend_src is only valid on fragment outputs (WGSL spec §11.3).
                    if (hasAttr(member.attributes, "blend_src")) {
                        const bs_loc = attrLocByName(member.attributes, "blend_src");
                        v.addErrorWithCodeR(.{ .start = bs_loc, .end = bs_loc +| 9 }, Diagnostic.Code.invalid_attribute, "@blend_src is only valid on fragment outputs");
                    }
                }
            }
        }
    }
}

pub fn validateEntryPointOutputs(v: *Validator, fn_decl: *Ast.FunctionDecl) Allocator.Error!void {
    const fn_range = v.symbolRange(fn_decl.name);
    // Check output locations (return type)
    var output_locations: std.AutoHashMapUnmanaged(i64, OutputLocEntry) = .{};
    if (getLocationInfo(fn_decl.return_attr)) |info| {
        try output_locations.put(v.arena, info.value, .{ .loc = info.loc, .blend_src = null });
    }
    const rt = fn_decl.return_type orelse return;
    const ret_type = v.resolveType(rt) orelse return;
    if (ret_type == .@"struct") {
        try validateEntryPointStructOutput(v, fn_decl, ret_type, fn_range, &output_locations);
    } else {
        try validateEntryPointDirectOutput(v, fn_decl, ret_type, fn_range);
    }
}

pub fn validateEntryPointStructOutput(v: *Validator, fn_decl: *Ast.FunctionDecl, ret_type: Types.Type, fn_range: LocRange, output_locations: *std.AutoHashMapUnmanaged(i64, OutputLocEntry)) Allocator.Error!void {
    _ = fn_decl;
    const sd = v.findStructDecl(ret_type.@"struct".name) orelse return;
    var output_builtins: std.StringHashMapUnmanaged(u32) = .{};
    var blend_src_members: std.ArrayListUnmanaged(BlendSrcEntry) = .empty;
    for (sd.members.items) |member| {
        try validateEntryPointStructOutputMember(v, member, fn_range, output_locations, &output_builtins, &blend_src_members);
    }
    // Post-walk: validate @blend_src dual-source pairing (WGSL spec §11.3,
    // §12.3.1.2). Each location with @blend_src must have exactly 2 members
    // with values {0, 1} of the same type.
    v.validateBlendSrcPairing(blend_src_members.items, fn_range);
}

pub fn validateEntryPointStructOutputMember(v: *Validator, member: anytype, fn_range: LocRange, output_locations: *std.AutoHashMapUnmanaged(i64, OutputLocEntry), output_builtins: *std.StringHashMapUnmanaged(u32), blend_src_members: *std.ArrayListUnmanaged(BlendSrcEntry)) Allocator.Error!void {
    const out_mt = v.resolveType(member.typ);
    // Nested struct in output I/O is invalid.
    if (out_mt != null and out_mt.? == .@"struct") {
        v.addErrorWithCodeR(v.symbolRange(member.name), Diagnostic.Code.invalid_shader_io, v.fmtError("entry point I/O member '{s}' cannot be a struct type", .{v.symbolName(member.name)}));
    }
    if (!hasLocationOrBuiltin(member.attributes)) {
        v.addErrorWithCodeR(fn_range, Diagnostic.Code.invalid_shader_io, v.fmtError("entry point struct member '{s}' must have @builtin or @location", .{v.symbolName(member.name)}));
    }
    // Collect @blend_src info for pairing & attribute-site validation.
    const bs_info = getBlendSrcInfo(member.attributes);
    if (getLocationInfo(member.attributes)) |info| {
        if (output_locations.get(info.value)) |first| {
            // Duplicate @location is permitted only when both members carry
            // @blend_src with valid values (0 & 1) — the pairing check below
            // validates the full rule.
            const both_blend_src = first.blend_src != null and bs_info != null;
            if (!both_blend_src) {
                const loc_u32: u32 = std.math.cast(u32, info.value) orelse 0;
                v.addErrorWithRelatedDataR(fn_range, Diagnostic.Code.invalid_shader_io, v.fmtError("duplicate output @location({d})", .{info.value}), v.makeRelatedR(.{ .start = first.loc, .end = first.loc +| 1 }, v.fmtError("@location({d}) first used here", .{info.value})), .{ .duplicate_location = loc_u32 });
            }
        } else {
            try output_locations.put(v.arena, info.value, .{ .loc = info.loc, .blend_src = if (bs_info) |b| b.value else null });
        }
    }
    if (bs_info) |bs| {
        try checkBlendSrcAttr(v, member, bs, out_mt, blend_src_members);
    }
    // Validate @interpolate on vertex outputs
    if (v.current_stage == .vertex) {
        v.validateInterpolation(member.attributes, out_mt, v.symbolLoc(member.name));
    }
    v.validateInvariantAttr(member.attributes, v.symbolLoc(member.name));
    if (hasAttr(member.attributes, "location") and hasAttr(member.attributes, "builtin")) {
        v.addErrorWithCodeR(v.symbolRange(member.name), Diagnostic.Code.duplicate_attribute, v.fmtError("member '{s}' cannot have both @location and @builtin", .{v.symbolName(member.name)}));
    }
    if (getBuiltinAttrName(member.attributes)) |bn| {
        if (output_builtins.get(bn)) |_| {
            v.addErrorWithCodeR(v.symbolRange(member.name), Diagnostic.Code.invalid_shader_io, v.fmtError("duplicate @builtin({s}) in entry point output", .{bn}));
        } else {
            try output_builtins.put(v.arena, bn, v.symbolLoc(member.name));
        }
    }
    // @builtin stage/direction + required type on output members.
    for (member.attributes.items) |a| {
        if (!std.mem.eql(u8, a.name, "builtin") or a.args.items.len == 0) continue;
        switch (a.args.items[0]) {
            .ident => |ident| try v.validateBuiltinAttr(ident.name, false, a.loc, out_mt, v.symbolRange(member.name)),
            else => {},
        }
    }
    // @location type check on output members.
    if (hasAttr(member.attributes, "location")) {
        if (out_mt) |member_type| {
            v.validateLocationType(member_type, v.symbolRange(member.name));
        }
        for (member.attributes.items) |*a| {
            if (std.mem.eql(u8, a.name, "location")) v.validateLocationArgExpr(a);
        }
    }
}

pub fn checkBlendSrcAttr(v: *Validator, member: anytype, bs: anytype, out_mt: ?Types.Type, blend_src_members: *std.ArrayListUnmanaged(BlendSrcEntry)) Allocator.Error!void {
    const bs_range: LocRange = .{ .start = bs.loc, .end = bs.loc +| 9 };
    if (v.current_stage != .fragment) {
        v.addErrorWithCodeR(bs_range, Diagnostic.Code.invalid_attribute, "@blend_src is only valid on fragment outputs");
    } else if (!hasAttr(member.attributes, "location")) {
        v.addErrorWithCodeR(bs_range, Diagnostic.Code.invalid_attribute, "@blend_src requires a @location attribute on the same member");
    } else if (bs.value != 0 and bs.value != 1) {
        v.addErrorWithCodeR(bs_range, Diagnostic.Code.invalid_attribute, v.fmtError("@blend_src value must be 0 or 1, got {d}", .{bs.value}));
    }
    const loc_val: i64 = if (getLocationInfo(member.attributes)) |li| li.value else -1;
    try blend_src_members.append(v.arena, .{ .location = loc_val, .value = bs.value, .typ = out_mt, .member_range = v.symbolRange(member.name), .attr_loc = bs.loc });
}

pub fn validateEntryPointDirectOutput(v: *Validator, fn_decl: *Ast.FunctionDecl, ret_type: Types.Type, fn_range: LocRange) Allocator.Error!void {
    // Direct (non-struct) return: validate @builtin stage/direction + type,
    // @location type, plus @invariant and @interpolate (vertex-output only).
    for (fn_decl.return_attr.items) |a| {
        if (std.mem.eql(u8, a.name, "builtin") and a.args.items.len > 0) {
            switch (a.args.items[0]) {
                .ident => |ident| try v.validateBuiltinAttr(ident.name, false, a.loc, ret_type, fn_range),
                else => {},
            }
        }
    }
    if (hasAttr(fn_decl.return_attr, "location")) {
        v.validateLocationType(ret_type, fn_range);
        for (fn_decl.return_attr.items) |*a| {
            if (std.mem.eql(u8, a.name, "location")) v.validateLocationArgExpr(a);
        }
    }
    // @blend_src is only valid on struct members, not direct returns.
    if (hasAttr(fn_decl.return_attr, "blend_src")) {
        const bs_loc = attrLocByName(fn_decl.return_attr, "blend_src");
        v.addErrorWithCodeR(.{ .start = bs_loc, .end = bs_loc +| 9 }, Diagnostic.Code.invalid_attribute, "@blend_src must only be applied to a struct member");
    }
    v.validateInvariantAttr(fn_decl.return_attr, fn_range.start);
    if (v.current_stage == .vertex) {
        v.validateInterpolation(fn_decl.return_attr, ret_type, fn_range.start);
    }
}

/// Verify dual-source blending pairing rules (WGSL spec §12.3.1.2):
/// members with @blend_src must come as exactly two entries at the same
/// @location, one with value 0 and one with value 1, of the same type.
pub fn validateBlendSrcPairing(v: *Validator, entries: []const BlendSrcEntry, fn_range: LocRange) void {
    if (entries.len == 0) return;
    // Group by location — expected to always be location 0 per spec, but we
    // check each distinct location independently.
    for (entries, 0..) |e, i| {
        // Find the paired entry at the same location with the opposite value.
        const want_other: i64 = if (e.value == 0) 1 else if (e.value == 1) 0 else continue;
        var found_partner = false;
        for (entries, 0..) |o, j| {
            if (i == j) continue;
            if (o.location != e.location) continue;
            if (o.value == want_other) {
                // Same-type check
                if (e.typ != null and o.typ != null and !e.typ.?.eql(o.typ.?)) {
                    v.addErrorWithCodeR(e.member_range, Diagnostic.Code.invalid_shader_io, v.fmtError("@blend_src pair at @location({d}) must share a type, got '{s}' and '{s}'", .{ e.location, e.typ.?.string(), o.typ.?.string() }));
                }
                found_partner = true;
                break;
            }
        }
        if (!found_partner and e.value >= 0 and e.value <= 1) {
            v.addErrorWithCodeR(e.member_range, Diagnostic.Code.invalid_shader_io, v.fmtError("@blend_src({d}) at @location({d}) is missing its paired @blend_src({d}) member", .{ e.value, e.location, want_other }));
        }
    }
    // Count distinct locations with @blend_src — none may have more than 2 members.
    var seen_counts: std.AutoHashMapUnmanaged(i64, u32) = .{};
    defer seen_counts.deinit(v.arena);
    for (entries) |e| {
        const gop = seen_counts.getOrPut(v.arena, e.location) catch return;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }
    var it = seen_counts.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* > 2) {
            v.addErrorWithCodeR(fn_range, Diagnostic.Code.invalid_shader_io, v.fmtError("@location({d}) has {d} members with @blend_src, expected exactly 2", .{ kv.key_ptr.*, kv.value_ptr.* }));
        }
    }
}

/// Validate @interpolate attributes on entry point I/O members.
/// Called from validateEntryPointIO for fragment inputs and vertex outputs.
pub fn validateInterpolation(v: *Validator, attrs: std.ArrayListUnmanaged(Ast.Attribute), member_type: ?Types.Type, member_loc: u32) void {
    const has_location = hasAttr(attrs, "location");
    const has_interpolate = hasAttr(attrs, "interpolate");

    // @interpolate only applies to user-defined I/O with @location (WGSL spec section 10.3).
    if (has_interpolate and !has_location) {
        v.addErrorWithCodeR(.{ .start = member_loc, .end = member_loc +| 1 }, Diagnostic.Code.invalid_interpolation, "@interpolate can only be used with @location, not @builtin");
        return;
    }
    if (!has_location) return;

    const is_integer = if (member_type) |mt| Types.isInteger(mt) or isIntegerVector(mt) else false;

    // Find @interpolate attribute
    var interpolate_attr: ?*const Ast.Attribute = null;
    for (attrs.items) |*attr| {
        if (std.mem.eql(u8, attr.name, "interpolate")) {
            interpolate_attr = attr;
            break;
        }
    }

    // WGSL spec section 10.3: integer-typed I/O cannot be interpolated, so flat is mandatory.
    if (is_integer) {
        if (interpolate_attr) |attr| {
            if (attr.args.items.len > 0) {
                const interp_type = exprIdent(attr.args.items[0]);
                if (interp_type.len > 0 and !std.mem.eql(u8, interp_type, "flat")) {
                    v.addErrorWithCodeR(attrRange(attr), Diagnostic.Code.invalid_interpolation, v.fmtError("integer-typed @location must use @interpolate(flat), got @interpolate({s})", .{interp_type}));
                }
            }
        } else {
            v.addErrorWithCodeR(.{ .start = member_loc, .end = member_loc +| 1 }, Diagnostic.Code.missing_interpolation, "integer-typed @location requires @interpolate(flat)");
        }
    }

    // WGSL spec section 10.3: only three interpolation types exist, each with restricted sampling modes.
    if (interpolate_attr) |attr| {
        if (attr.args.items.len > 0) {
            const interp_type = exprIdent(attr.args.items[0]);

            if (interp_type.len > 0 and !std.mem.eql(u8, interp_type, "flat") and
                !std.mem.eql(u8, interp_type, "perspective") and
                !std.mem.eql(u8, interp_type, "linear"))
            {
                v.addErrorWithCodeR(attrRange(attr), Diagnostic.Code.invalid_interpolation, v.fmtError("invalid interpolation type '{s}'; expected 'flat', 'perspective', or 'linear'", .{interp_type}));
            }

            // Flat and perspective/linear have disjoint valid sampling sets per spec.
            if (attr.args.items.len > 1) {
                const sampling = exprIdent(attr.args.items[1]);
                if (sampling.len > 0) {
                    if (std.mem.eql(u8, interp_type, "flat")) {
                        // flat: sampling must be 'first' or 'either'
                        if (!std.mem.eql(u8, sampling, "first") and !std.mem.eql(u8, sampling, "either")) {
                            v.addErrorWithCodeR(attrRange(attr), Diagnostic.Code.invalid_interpolation, v.fmtError("@interpolate(flat) sampling must be 'first' or 'either', got '{s}'", .{sampling}));
                        }
                    } else {
                        // perspective/linear: sampling must be 'center', 'centroid', or 'sample'
                        if (!std.mem.eql(u8, sampling, "center") and !std.mem.eql(u8, sampling, "centroid") and !std.mem.eql(u8, sampling, "sample")) {
                            v.addErrorWithCodeR(attrRange(attr), Diagnostic.Code.invalid_interpolation, v.fmtError("@interpolate({s}) sampling must be 'center', 'centroid', or 'sample', got '{s}'", .{ interp_type, sampling }));
                        }
                    }
                }
            }
        }
    }
}

/// Check if a type contains an atomic anywhere (including inside structs/arrays).
pub fn typeContainsAtomic(typ: Types.Type) bool {
    var current = typ;
    for (0..32) |_| {
        switch (current) {
            .atomic => return true,
            .array => |a| current = a.element,
            .@"struct" => |s| {
                for (s.fields) |f| {
                    if (typeContainsAtomic(f.typ)) return true;
                }
                return false;
            },
            else => return false,
        }
    }
    return false;
}

/// Detect duplicate characters in a swizzle string (e.g., "xx", "xyxy").
pub fn hasDuplicateSwizzleChars(name: []const u8) bool {
    if (name.len < 2 or name.len > 4) return false;
    // Only check if it looks like a swizzle (all chars are xyzw or rgba).
    const xyzw = "xyzwrgba";
    for (name) |c| {
        if (std.mem.indexOfScalar(u8, xyzw, c) == null) return false;
    }
    for (name, 0..) |c, i| {
        for (name[i + 1 ..]) |d| {
            if (c == d) return true;
        }
    }
    return false;
}

/// Returns true if `name` is a syntactically valid swizzle (1–4 chars,
/// all from xyzw or all from rgba — never mixed). Used alongside the
/// base-type check to distinguish struct-field access from swizzles.
pub fn isSwizzleName(name: []const u8) bool {
    if (name.len == 0 or name.len > 4) return false;
    var saw_xyzw = false;
    var saw_rgba = false;
    for (name) |c| switch (c) {
        'x', 'y', 'z', 'w' => saw_xyzw = true,
        'r', 'g', 'b', 'a' => saw_rgba = true,
        else => return false,
    };
    return saw_xyzw != saw_rgba;
}

/// @invariant can only apply to @builtin(position) (WGSL spec section 9.3.3).
pub fn validateInvariantAttr(v: *Validator, attrs: std.ArrayListUnmanaged(Ast.Attribute), member_loc: u32) void {
    if (!hasAttr(attrs, "invariant")) return;
    if (!hasBuiltinAttr(attrs, "position")) {
        v.addErrorWithCodeR(.{ .start = member_loc, .end = member_loc +| 1 }, Diagnostic.Code.invalid_attribute, "@invariant can only be applied to @builtin(position)");
    }
}

pub fn hasAttr(attrs: std.ArrayListUnmanaged(Ast.Attribute), name: []const u8) bool {
    for (attrs.items) |attr| {
        if (std.mem.eql(u8, attr.name, name)) return true;
    }
    return false;
}

pub fn exprIdent(expr: Ast.Expr) []const u8 {
    return switch (expr) {
        .ident => |e| e.name,
        else => "",
    };
}

pub fn isIntegerVector(t: Types.Type) bool {
    return switch (t) {
        .vector => |ve| Types.isInteger(.{ .scalar = ve.element }),
        else => false,
    };
}

pub fn vertexHasPositionOutput(v: *Validator, fn_decl: *Ast.FunctionDecl) bool {
    // Check return attributes for @builtin(position)
    if (hasBuiltinAttr(fn_decl.return_attr, "position")) return true;
    // Check if return type is a struct with a @builtin(position) member
    if (fn_decl.return_type) |rt| {
        if (v.resolveType(rt)) |resolved| {
            if (resolved == .@"struct") {
                const struct_name = resolved.@"struct".name;
                for (v.module.declarations.items) |decl| {
                    switch (decl) {
                        .@"struct" => |sd| {
                            if (std.mem.eql(u8, v.symbolName(sd.name), struct_name)) {
                                for (sd.members.items) |member| {
                                    if (hasBuiltinAttr(member.attributes, "position")) return true;
                                }
                            }
                        },
                        else => {},
                    }
                }
            }
        }
    }
    return false;
}

pub fn findStructDecl(v: *Validator, struct_name: []const u8) ?*Ast.StructDecl {
    for (v.module.declarations.items) |decl| {
        switch (decl) {
            .@"struct" => |sd| {
                if (std.mem.eql(u8, v.symbolName(sd.name), struct_name)) return sd;
            },
            else => {},
        }
    }
    return null;
}

pub fn getLocationValue(attrs: std.ArrayListUnmanaged(Ast.Attribute)) ?i64 {
    if (getLocationInfo(attrs)) |info| return info.value;
    return null;
}

pub fn getLocationInfo(attrs: std.ArrayListUnmanaged(Ast.Attribute)) ?struct { value: i64, loc: u32 } {
    for (attrs.items) |attr| {
        if (std.mem.eql(u8, attr.name, "location") and attr.args.items.len > 0) {
            if (extractLiteralIntValue(attr.args.items[0])) |val| {
                return .{ .value = val, .loc = attr.loc };
            }
        }
    }
    return null;
}

/// @blend_src attribute info: returns the const value (0 or 1 when valid)
/// and the attribute's source location. Returns null when absent or when
/// the argument is not extractable as an integer literal.
pub fn getBlendSrcInfo(attrs: std.ArrayListUnmanaged(Ast.Attribute)) ?struct { value: i64, loc: u32 } {
    for (attrs.items) |attr| {
        if (std.mem.eql(u8, attr.name, "blend_src") and attr.args.items.len > 0) {
            if (extractLiteralIntValue(attr.args.items[0])) |val| {
                return .{ .value = val, .loc = attr.loc };
            }
            return .{ .value = -1, .loc = attr.loc }; // present but non-literal
        }
    }
    return null;
}

pub fn attrLocByName(attrs: std.ArrayListUnmanaged(Ast.Attribute), name: []const u8) u32 {
    for (attrs.items) |attr| {
        if (std.mem.eql(u8, attr.name, name)) return attr.loc;
    }
    return 0;
}

/// Extract @builtin name from attributes, or null.
pub fn getBuiltinAttrName(attrs: std.ArrayListUnmanaged(Ast.Attribute)) ?[]const u8 {
    for (attrs.items) |attr| {
        if (std.mem.eql(u8, attr.name, "builtin") and attr.args.items.len > 0) {
            switch (attr.args.items[0]) {
                .ident => |ident| return ident.name,
                else => {},
            }
        }
    }
    return null;
}

pub fn hasLocationOrBuiltin(attrs: std.ArrayListUnmanaged(Ast.Attribute)) bool {
    for (attrs.items) |attr| {
        if (std.mem.eql(u8, attr.name, "location") or std.mem.eql(u8, attr.name, "builtin")) return true;
    }
    return false;
}

pub fn hasBuiltinAttr(attrs: std.ArrayListUnmanaged(Ast.Attribute), builtin_name: []const u8) bool {
    for (attrs.items) |attr| {
        if (std.mem.eql(u8, attr.name, "builtin") and attr.args.items.len > 0) {
            switch (attr.args.items[0]) {
                .ident => |ident| {
                    if (std.mem.eql(u8, ident.name, builtin_name)) return true;
                },
                else => {},
            }
        }
    }
    return false;
}

const all_builtin_values = [_][]const u8{
    "vertex_index",
    "instance_index",
    "position",
    "front_facing",
    "sample_index",
    "sample_mask",
    "frag_depth",
    "local_invocation_id",
    "local_invocation_index",
    "global_invocation_id",
    "global_invocation_index",
    "workgroup_id",
    "workgroup_index",
    "num_workgroups",
    "subgroup_invocation_id",
    "subgroup_size",
    "subgroup_id",
    "num_subgroups",
    "clip_distances",
    "primitive_index",
};

const vertex_input_builtins = [_][]const u8{ "vertex_index", "instance_index" };
const vertex_output_builtins = [_][]const u8{ "position", "clip_distances" };
const fragment_input_builtins = [_][]const u8{ "position", "front_facing", "sample_index", "sample_mask", "primitive_index", "subgroup_invocation_id", "subgroup_size" };
const fragment_output_builtins = [_][]const u8{ "frag_depth", "sample_mask" };
const compute_input_builtins = [_][]const u8{ "local_invocation_id", "local_invocation_index", "global_invocation_id", "global_invocation_index", "workgroup_id", "workgroup_index", "num_workgroups", "subgroup_invocation_id", "subgroup_size", "subgroup_id", "num_subgroups" };

pub fn isKnownBuiltinValue(name: []const u8) bool {
    for (&all_builtin_values) |v| {
        if (std.mem.eql(u8, name, v)) return true;
    }
    return false;
}

pub fn getStageBuiltins(stage: ShaderStage, is_input: bool) []const []const u8 {
    return switch (stage) {
        .vertex => if (is_input) &vertex_input_builtins else &vertex_output_builtins,
        .fragment => if (is_input) &fragment_input_builtins else &fragment_output_builtins,
        .compute => if (is_input) &compute_input_builtins else &.{},
        .none => &all_builtin_values,
    };
}

pub fn validateBuiltinForStage(v: *Validator, builtin_name: []const u8, is_input: bool, loc: u32) void {
    const r: LocRange = .{ .start = loc, .end = loc +| @as(u32, @intCast(builtin_name.len)) };
    // Check if the name is a known builtin value at all
    if (!isKnownBuiltinValue(builtin_name)) {
        if (suggestName(builtin_name, &all_builtin_values, 3)) |s| {
            v.addErrorWithCodeDataR(r, Diagnostic.Code.invalid_builtin, v.fmtError("unknown @builtin value '{s}'; did you mean '{s}'?", .{ builtin_name, s }), .{ .did_you_mean = s });
        } else {
            v.addErrorWithCodeR(r, Diagnostic.Code.invalid_builtin, v.fmtError("unknown @builtin value '{s}'", .{builtin_name}));
        }
        return;
    }

    const valid = switch (v.current_stage) {
        .vertex => if (is_input)
            isVertexInput(builtin_name)
        else
            isVertexOutput(builtin_name),
        .fragment => if (is_input)
            isFragmentInput(builtin_name)
        else
            isFragmentOutput(builtin_name),
        .compute => if (is_input)
            isComputeInput(builtin_name)
        else
            false,
        .none => true, // Not an entry point, skip validation
    };

    if (!valid) {
        const stage_builtins = getStageBuiltins(v.current_stage, is_input);
        if (suggestName(builtin_name, stage_builtins, 3)) |s| {
            v.addErrorWithCodeDataR(r, Diagnostic.Code.invalid_builtin, v.fmtError("@builtin({s}) is not valid for {s} shaders; did you mean '{s}'?", .{ builtin_name, v.current_stage.string(), s }), .{ .did_you_mean = s });
        } else {
            v.addErrorWithCodeR(r, Diagnostic.Code.invalid_builtin, v.fmtError("@builtin({s}) is not valid for {s} shaders", .{ builtin_name, v.current_stage.string() }));
        }
    }
}

pub fn isVertexInput(name: []const u8) bool {
    return std.mem.eql(u8, name, "vertex_index") or
        std.mem.eql(u8, name, "instance_index");
}

pub fn isVertexOutput(name: []const u8) bool {
    return std.mem.eql(u8, name, "position") or
        std.mem.eql(u8, name, "clip_distances");
}

pub fn isFragmentInput(name: []const u8) bool {
    return std.mem.eql(u8, name, "position") or
        std.mem.eql(u8, name, "front_facing") or
        std.mem.eql(u8, name, "sample_index") or
        std.mem.eql(u8, name, "sample_mask") or
        std.mem.eql(u8, name, "primitive_index") or
        std.mem.eql(u8, name, "subgroup_invocation_id") or
        std.mem.eql(u8, name, "subgroup_size");
}

pub fn isFragmentOutput(name: []const u8) bool {
    return std.mem.eql(u8, name, "frag_depth") or
        std.mem.eql(u8, name, "sample_mask");
}

/// Returns the WGSL type that the named built-in is required to have, per
/// the table in WGSL spec §9.3.1. Returns null for unknown names, for
/// clip_distances (handled specially by validateClipDistancesType due to
/// the N ≤ 8 constraint), and for builtins that have no type check
/// (currently none do — kept for future extensions).
pub fn builtinExpectedType(v: *Validator, name: []const u8) Allocator.Error!?Types.Type {
    // u32 scalars
    if (std.mem.eql(u8, name, "vertex_index") or
        std.mem.eql(u8, name, "instance_index") or
        std.mem.eql(u8, name, "sample_index") or
        std.mem.eql(u8, name, "sample_mask") or
        std.mem.eql(u8, name, "local_invocation_index") or
        std.mem.eql(u8, name, "global_invocation_index") or
        std.mem.eql(u8, name, "workgroup_index") or
        std.mem.eql(u8, name, "subgroup_invocation_id") or
        std.mem.eql(u8, name, "subgroup_size") or
        std.mem.eql(u8, name, "subgroup_id") or
        std.mem.eql(u8, name, "num_subgroups") or
        std.mem.eql(u8, name, "primitive_index"))
    {
        return Types.U32;
    }
    if (std.mem.eql(u8, name, "front_facing")) return Types.Bool;
    if (std.mem.eql(u8, name, "frag_depth")) return Types.F32;
    if (std.mem.eql(u8, name, "position")) {
        return try Types.vec(v.arena, 4, Types.scalar_f32_ptr);
    }
    if (std.mem.eql(u8, name, "local_invocation_id") or
        std.mem.eql(u8, name, "global_invocation_id") or
        std.mem.eql(u8, name, "workgroup_id") or
        std.mem.eql(u8, name, "num_workgroups"))
    {
        return try Types.vec(v.arena, 3, Types.scalar_u32_ptr);
    }
    return null;
}

/// Validates a @builtin attribute site: combines the stage/direction check
/// (validateBuiltinForStage) with the type check against the required
/// spec type. `host_type` is the resolved type the builtin is attached to
/// (param type, return type, or struct-member type). `host_range` is the
/// range reported on type mismatches.
pub fn validateBuiltinAttr(
    v: *Validator,
    builtin_name: []const u8,
    is_input: bool,
    attr_loc: u32,
    host_type: ?Types.Type,
    host_range: LocRange,
) Allocator.Error!void {
    v.validateBuiltinForStage(builtin_name, is_input, attr_loc);
    const actual = host_type orelse return;
    if (std.mem.eql(u8, builtin_name, "clip_distances")) {
        v.validateClipDistancesType(actual, host_range);
        return;
    }
    const expected = (try v.builtinExpectedType(builtin_name)) orelse return;
    if (!actual.eql(expected)) {
        v.addErrorWithCodeR(host_range, Diagnostic.Code.type_mismatch, v.fmtError("@builtin({s}) requires type '{s}', got '{s}'", .{ builtin_name, expected.string(), actual.string() }));
    }
}

/// @builtin(clip_distances) requires `array<f32, N>` with 1 ≤ N ≤ 8
/// (WGSL spec §9.3.1 + clip_distances extension).
pub fn validateClipDistancesType(v: *Validator, actual: Types.Type, host_range: LocRange) void {
    if (actual != .array) {
        v.addErrorWithCodeR(host_range, Diagnostic.Code.type_mismatch, v.fmtError("@builtin(clip_distances) requires type 'array<f32, N>' (N ≤ 8), got '{s}'", .{actual.string()}));
        return;
    }
    const arr = actual.array;
    if (arr.element != .scalar or arr.element.scalar.kind != .f32) {
        v.addErrorWithCodeR(host_range, Diagnostic.Code.type_mismatch, v.fmtError("@builtin(clip_distances) requires array of f32, got array of '{s}'", .{arr.element.string()}));
        return;
    }
    if (arr.count == 0) {
        v.addErrorWithCodeR(host_range, Diagnostic.Code.type_mismatch, "@builtin(clip_distances) requires a fixed-size array");
        return;
    }
    if (arr.count > 8) {
        v.addErrorWithCodeR(host_range, Diagnostic.Code.type_mismatch, v.fmtError("@builtin(clip_distances) requires array size ≤ 8, got {d}", .{arr.count}));
    }
}

/// WGSL spec §10.2.1 + §9.5: user-defined I/O (@location) must be a numeric
/// scalar (i32/u32/f32/f16) or vector of those.
pub fn isValidLocationType(t: Types.Type) bool {
    return switch (t) {
        .scalar => |s| switch (s.kind) {
            .i32, .u32, .f32, .f16 => true,
            else => false,
        },
        .vector => |ve| switch (ve.element.kind) {
            .i32, .u32, .f32, .f16 => true,
            else => false,
        },
        else => false,
    };
}

pub fn validateLocationType(v: *Validator, actual: Types.Type, host_range: LocRange) void {
    if (!isValidLocationType(actual)) {
        v.addErrorWithCodeR(host_range, Diagnostic.Code.invalid_location, v.fmtError("@location requires numeric scalar or numeric vector type, got '{s}'", .{actual.string()}));
    }
}

pub fn isComputeInput(name: []const u8) bool {
    return std.mem.eql(u8, name, "local_invocation_id") or
        std.mem.eql(u8, name, "local_invocation_index") or
        std.mem.eql(u8, name, "global_invocation_id") or
        std.mem.eql(u8, name, "global_invocation_index") or
        std.mem.eql(u8, name, "workgroup_id") or
        std.mem.eql(u8, name, "workgroup_index") or
        std.mem.eql(u8, name, "num_workgroups") or
        std.mem.eql(u8, name, "subgroup_invocation_id") or
        std.mem.eql(u8, name, "subgroup_size") or
        std.mem.eql(u8, name, "subgroup_id") or
        std.mem.eql(u8, name, "num_subgroups");
}


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

pub fn resolveType(v: *Validator, ast_type: Ast.Type) ?Types.Type {
    return switch (ast_type) {
        .ident => |t| resolveIdentType(v, t),
        .vec => |t| resolveVecType(v, t),
        .mat => |t| resolveMatType(v, t),
        .array => |t| resolveArrayType(v, t),
        .ptr => |t| resolvePtrType(v, t),
        .atomic => |t| resolveAtomicType(v, t),
        .sampler => |t| resolveSamplerType(v, t),
        .texture => |t| resolveTextureType(v, t),
    };
}

pub fn resolveIdentType(v: *Validator, t: anytype) ?Types.Type {
    if (v.lookupType(t.name)) |typ| return typ;
    // Type not found — report with suggestion if close match exists.
    if (v.suggestType(t.name, null)) |suggestion| {
        v.addErrorWithCodeDataR(astTypeRange(.{ .ident = t }), Diagnostic.Code.type_mismatch, v.fmtError("unknown type '{s}'; did you mean '{s}'?", .{ t.name, suggestion }), .{ .did_you_mean = suggestion });
    } else {
        v.addErrorWithCodeR(astTypeRange(.{ .ident = t }), Diagnostic.Code.type_mismatch, v.fmtError("unknown type '{s}'", .{t.name}));
    }
    return null;
}

pub fn resolveVecType(v: *Validator, t: anytype) ?Types.Type {
    var elem_scalar: *const Types.Scalar = Types.scalar_f32_ptr;
    if (t.elem_type) |et| {
        if (v.resolveType(et)) |resolved| {
            switch (resolved) {
                .scalar => |s| elem_scalar = s,
                else => {},
            }
        }
    } else if (t.shorthand.len > 0) {
        elem_scalar = shorthandElement(t.shorthand);
    }
    const result = v.arena.create(Types.Vector) catch return null;
    result.* = .{ .width = t.size, .element = elem_scalar };
    return .{ .vector = result };
}

pub fn resolveMatType(v: *Validator, t: anytype) ?Types.Type {
    var elem_scalar: *const Types.Scalar = Types.scalar_f32_ptr;
    if (t.elem_type) |et| {
        if (v.resolveType(et)) |resolved| {
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
    const result = v.arena.create(Types.Matrix) catch return null;
    result.* = .{ .cols = t.cols, .rows = t.rows, .element = elem_scalar };
    return .{ .matrix = result };
}

pub fn resolveArrayType(v: *Validator, t: anytype) ?Types.Type {
    const elem_type = if (t.elem_type) |et| (v.resolveType(et) orelse return null) else return null;
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
    const result = v.arena.create(Types.Array) catch return null;
    result.* = .{ .element = elem_type, .count = count };
    return .{ .array = result };
}

pub fn resolvePtrType(v: *Validator, t: anytype) ?Types.Type {
    const elem_type = v.resolveType(t.elem_type) orelse return null;
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
    const result = v.arena.create(Types.Pointer) catch return null;
    result.* = .{
        .address_space = t.address_space,
        .element = elem_type,
        .access_mode = t.access_mode,
    };
    return .{ .pointer = result };
}

pub fn resolveAtomicType(v: *Validator, t: anytype) ?Types.Type {
    const elem_type = v.resolveType(t.elem_type) orelse return null;
    switch (elem_type) {
        .scalar => |s| {
            // Spec: atomic type requires i32 or u32 only.
            if (s.kind != .i32 and s.kind != .u32) {
                v.addErrorWithCodeR(astTypeRange(.{ .atomic = t }), Diagnostic.Code.invalid_atomic_type, v.fmtError("atomic type requires i32 or u32, got '{s}'", .{elem_type.string()}));
                return null;
            }
            const result = v.arena.create(Types.Atomic) catch return null;
            result.* = .{ .element = s };
            return .{ .atomic = result };
        },
        else => {
            v.addErrorWithCodeR(astTypeRange(.{ .atomic = t }), Diagnostic.Code.invalid_atomic_type, v.fmtError("atomic type requires scalar element, got '{s}'", .{elem_type.string()}));
            return null;
        },
    }
}

pub fn resolveSamplerType(v: *Validator, t: anytype) ?Types.Type {
    const result = v.arena.create(Types.Sampler) catch return null;
    result.* = .{ .comparison = t.comparison };
    return .{ .sampler = result };
}

pub fn resolveTextureType(v: *Validator, t: anytype) ?Types.Type {
    const tex_range = astTypeRange(.{ .texture = t });
    const kind = astTextureKindToType(t.kind);
    const dimension = astTextureDimToType(t.dimension);

    var sampled_scalar: ?*const Types.Scalar = null;
    if (t.sampled_type) |st| {
        if (v.resolveType(st)) |resolved| {
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

    const result = v.arena.create(Types.Texture) catch return null;
    result.* = .{
        .kind = kind,
        .dimension = dimension,
        .sampled_type = sampled_scalar,
        .texel_format = t.texel_format,
        .access_mode = t.access_mode,
    };
    return .{ .texture = result };
}

pub fn lookupType(v: *Validator, name: []const u8) ?Types.Type {
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
        const s = v.arena.create(Types.Sampler) catch return null;
        s.* = .{ .comparison = false };
        return .{ .sampler = s };
    }
    if (std.mem.eql(u8, name, "sampler_comparison")) {
        const s = v.arena.create(Types.Sampler) catch return null;
        s.* = .{ .comparison = true };
        return .{ .sampler = s };
    }

    // Vector shorthand (vec2f, vec3i, etc.) and bare constructors (vec2, vec3, vec4)
    if (name.len >= 4 and std.mem.startsWith(u8, name, "vec")) {
        return v.parseVectorShorthand(name);
    }

    // Matrix shorthand (mat2x2f, mat3x3f, etc.) and bare constructors (mat2x2, mat3x3, etc.)
    if (name.len >= 5 and std.mem.startsWith(u8, name, "mat")) {
        return v.parseMatrixShorthand(name);
    }

    // Depth texture types (no template args)
    if (std.mem.startsWith(u8, name, "texture_depth")) {
        const dim: Types.TextureDimension = if (std.mem.eql(u8, name, "texture_depth_2d"))
            .@"2d"
        else if (std.mem.eql(u8, name, "texture_depth_2d_array"))
            .@"2d_array"
        else if (std.mem.eql(u8, name, "texture_depth_cube"))
            .cube
        else if (std.mem.eql(u8, name, "texture_depth_cube_array"))
            .cube_array
        else if (std.mem.eql(u8, name, "texture_depth_multisampled_2d"))
            .@"2d"
        else
            return null;
        const kind: Types.TextureKind = if (std.mem.eql(u8, name, "texture_depth_multisampled_2d"))
            .depth_multisampled
        else
            .depth;
        const t = v.arena.create(Types.Texture) catch return null;
        t.* = .{ .kind = kind, .dimension = dim, .sampled_type = null, .texel_format = "", .access_mode = .read };
        return .{ .texture = t };
    }

    // External texture type
    if (std.mem.eql(u8, name, "texture_external")) {
        const t = v.arena.create(Types.Texture) catch return null;
        t.* = .{ .kind = .external, .dimension = .@"2d", .sampled_type = null, .texel_format = "", .access_mode = .read };
        return .{ .texture = t };
    }

    // Bare array constructor
    if (std.mem.eql(u8, name, "array")) {
        const arr = v.arena.create(Types.Array) catch return null;
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
        const arity_match = if (arg_count) |ac| arityOfTypeConstructor(candidate) == ac else false;
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
    var best: ?[]const u8 = null;
    var best_dist: usize = 3;
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
    var best: ?[]const u8 = null;
    var best_dist: usize = 3;
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
/// For vector shorthands (vec2f, vec3i, vec4, ...) returns the width (2, 3, 4).
/// For matrix shorthands (mat2x3f, ...) returns the column count.
/// Returns null for types that don't encode arity in their name.
pub fn arityOfTypeConstructor(name: []const u8) ?usize {
    if (name.len >= 4 and name.len <= 5 and std.mem.startsWith(u8, name, "vec")) {
        return switch (name[3]) {
            '2' => 2,
            '3' => 3,
            '4' => 4,
            else => null,
        };
    }
    if (name.len >= 6 and name.len <= 7 and std.mem.startsWith(u8, name, "mat") and name[4] == 'x') {
        return switch (name[3]) {
            '2' => 2,
            '3' => 3,
            '4' => 4,
            else => null,
        };
    }
    return null;
}

pub fn parseVectorShorthand(v: *Validator, name: []const u8) ?Types.Type {
    if (name.len < 4) return null;

    const size: u8 = switch (name[3]) {
        '2' => 2,
        '3' => 3,
        '4' => 4,
        else => return null,
    };

    var elem: *const Types.Scalar = Types.scalar_f32_ptr;
    if (name.len == 5) {
        elem = switch (name[4]) {
            'i' => Types.scalar_i32_ptr,
            'u' => Types.scalar_u32_ptr,
            'f' => Types.scalar_f32_ptr,
            'h' => Types.scalar_f16_ptr,
            else => return null,
        };
    } else if (name.len == 4) {
        elem = Types.scalar_f32_ptr; // Default to f32
    } else {
        return null;
    }

    const result = v.arena.create(Types.Vector) catch return null;
    result.* = .{ .width = size, .element = elem };
    return .{ .vector = result };
}

pub fn parseMatrixShorthand(v: *Validator, name: []const u8) ?Types.Type {
    if (name.len < 6) return null;

    const cols = name[3] -| '0';
    if (name[4] != 'x') return null;
    const rows = name[5] -| '0';

    if (cols < 2 or cols > 4 or rows < 2 or rows > 4) return null;

    var elem: *const Types.Scalar = Types.scalar_f32_ptr;
    if (name.len > 6) {
        elem = switch (name[6]) {
            'f' => Types.scalar_f32_ptr,
            'h' => Types.scalar_f16_ptr,
            else => return null,
        };
    }

    const result = v.arena.create(Types.Matrix) catch return null;
    result.* = .{ .cols = @intCast(cols), .rows = @intCast(rows), .element = elem };
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

/// Try to evaluate a const bool expression (for const_assert).
/// Handles: true/false literals, comparison operators on known-const int operands, logical not.
pub fn tryEvalConstBool(v: *const Validator, expr: Ast.Expr) ?bool {
    switch (expr) {
        .literal => |lit| {
            if (std.mem.eql(u8, lit.value, "true")) return true;
            if (std.mem.eql(u8, lit.value, "false")) return false;
            return null;
        },
        .paren => |p| return v.tryEvalConstBool(p.expr),
        .unary => |u| {
            if (u.op == .not) {
                if (v.tryEvalConstBool(u.operand)) |val| return !val;
            }
            return null;
        },
        .binary => |b| {
            // Try evaluating as integer comparison.
            const left_val = v.tryExtractIntValue(b.left) orelse return null;
            const right_val = v.tryExtractIntValue(b.right) orelse return null;
            return switch (b.op) {
                .eq => left_val == right_val,
                .ne => left_val != right_val,
                .lt => left_val < right_val,
                .le => left_val <= right_val,
                .gt => left_val > right_val,
                .ge => left_val >= right_val,
                else => null,
            };
        },
        else => return null,
    }
}

/// Try to extract a constant integer value from an expression.
/// Handles literals, paren/negate wrappers, const-declared identifiers,
/// and binary arithmetic/bitwise operations on const sub-expressions.
pub fn tryExtractIntValue(v: *const Validator, expr: Ast.Expr) ?i64 {
    return v.tryExtractIntValueDepth(expr, 0);
}

pub fn tryExtractIntValueDepth(v: *const Validator, expr: Ast.Expr, depth: u32) ?i64 {
    if (depth > 32) return null;
    return switch (expr) {
        .literal => |lit| extractLiteralInt(lit),
        .ident => |ident| {
            if (ident.ref.isValid()) {
                return v.const_values.get(ident.ref.index());
            }
            return null;
        },
        .unary => |u| {
            const val = v.tryExtractIntValueDepth(u.operand, depth + 1) orelse return null;
            return switch (u.op) {
                .neg => 0 -| val,
                .bit_not => ~val,
                else => null,
            };
        },
        .paren => |p| v.tryExtractIntValueDepth(p.expr, depth + 1),
        .binary => |b| {
            const l = v.tryExtractIntValueDepth(b.left, depth + 1) orelse return null;
            const r = v.tryExtractIntValueDepth(b.right, depth + 1) orelse return null;
            return switch (b.op) {
                .add => l +| r,
                .sub => l -| r,
                .mul => l *| r,
                .div => if (r != 0) @divTrunc(l, r) else null,
                .mod => if (r != 0) @mod(l, r) else null,
                .shl => if (r >= 0 and r < 64) l << @intCast(r) else null,
                .shr => if (r >= 0 and r < 64) l >> @intCast(r) else null,
                .@"and" => l & r,
                .@"or" => l | r,
                .xor => l ^ r,
                else => null,
            };
        },
        else => null,
    };
}

pub fn extractLiteralInt(lit: *Ast.LiteralExpr) ?i64 {
    if (lit.value.len == 0) return 0;
    var val_str = lit.value;
    if (val_str.len > 0 and (val_str[val_str.len - 1] == 'i' or val_str[val_str.len - 1] == 'u')) {
        val_str = val_str[0 .. val_str.len - 1];
    }
    return std.fmt.parseInt(i64, val_str, 0) catch null;
}

/// Extract a constant integer from a literal expression (no const lookup).
/// Used by freestanding helpers that don't have access to the Validator.
pub fn extractLiteralIntValue(expr: Ast.Expr) ?i64 {
    return extractLiteralIntValueDepth(expr, 0);
}

pub fn extractLiteralIntValueDepth(expr: Ast.Expr, depth: u32) ?i64 {
    if (depth > 32) return null;
    return switch (expr) {
        .literal => |lit| extractLiteralInt(lit),
        .unary => |u| {
            const val = extractLiteralIntValueDepth(u.operand, depth + 1) orelse return null;
            return switch (u.op) {
                .neg => 0 -| val,
                .bit_not => ~val,
                else => null,
            };
        },
        .paren => |p| extractLiteralIntValueDepth(p.expr, depth + 1),
        .binary => |b| {
            const l = extractLiteralIntValueDepth(b.left, depth + 1) orelse return null;
            const r = extractLiteralIntValueDepth(b.right, depth + 1) orelse return null;
            return switch (b.op) {
                .add => l +| r,
                .sub => l -| r,
                .mul => l *| r,
                .div => if (r != 0) @divTrunc(l, r) else null,
                .mod => if (r != 0) @mod(l, r) else null,
                .shl => if (r >= 0 and r < 64) l << @intCast(r) else null,
                .shr => if (r >= 0 and r < 64) l >> @intCast(r) else null,
                .@"and" => l & r,
                .@"or" => l | r,
                .xor => l ^ r,
                else => null,
            };
        },
        else => null,
    };
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
