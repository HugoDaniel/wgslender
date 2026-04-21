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

const std = @import("std");
const Ast = @import("Ast.zig");
const Types = @import("Types.zig");
const Builtins = @import("Builtins.zig");
const Diagnostic = @import("Diagnostic.zig");
const Suggest = @import("Suggest.zig");
const Dce = @import("Dce.zig");
const Allocator = std.mem.Allocator;

const Validator = @This();

/// Name and source location pair, used for duplicate-detection maps.
const LocName = struct { name: []const u8, loc: u32 };

const BindingInfo = struct {
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
    valid: bool,
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

pub const AnalysisResult = struct {
    valid: bool,
    diagnostics: *Diagnostic,
    /// The parsed AST module. Null only when parsing failed entirely.
    module: ?*Ast.Module = null,
    symbol_types: std.AutoHashMapUnmanaged(u32, Types.Type) = .{},
    struct_types: std.StringHashMapUnmanaged(*Types.Struct) = .{},
    alias_types: std.StringHashMapUnmanaged(?Types.Type) = .{},
    const_values: std.AutoHashMapUnmanaged(u32, i64) = .{},
    expr_types: std.AutoHashMapUnmanaged(u32, ExprTypeInfo) = .{},
    _arena: ?std.heap.ArenaAllocator = null,

    /// Free all memory owned by this result.
    pub fn deinit(self: *AnalysisResult, allocator: Allocator) void {
        _ = allocator;
        var arena = self._arena orelse return;
        arena.deinit();
        self._arena = null;
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

// =========================================================================
// Public API
// =========================================================================

/// Validate a parsed WGSL module.
pub fn validate(arena: Allocator, module: *Ast.Module, options: Options) !Result {
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
    v.checkRecursiveStructs();

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
    v.analyzeUniformity();

    // Phase 6: Scope-tree shadow detection (W0100)
    v.detectShadowing();

    // Phase 7: Ambiguous operator-precedence combinations (E0213)
    v.checkOperatorPrecedence();

    // Remove duplicate diagnostics produced by overlapping phases
    diags.deduplicate();

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
    v.checkRecursiveStructs();
    try v.validateDeclarations();
    try v.registerFunctionSignatures();
    try v.checkRecursiveFunctions();
    try v.validateFunctions();
    try v.validatePerEntryPointBindings();
    v.checkSuspiciousBindingPatterns();
    v.analyzeUniformity();
    v.detectShadowing();
    v.checkOperatorPrecedence();
    diags.deduplicate();

    return .{
        .valid = !diags.hasErrors(),
        .diagnostics = diags,
        .module = module,
        .symbol_types = v.symbol_types,
        .struct_types = v.struct_types,
        .alias_types = v.alias_types,
        .const_values = v.const_values,
        .expr_types = v.expr_types,
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

fn processDirectives(v: *Validator) Allocator.Error!void {
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
fn checkReservedIdentifiers(v: *Validator) void {
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

fn collectTypeDeclarations(v: *Validator) Allocator.Error!void {
    for (v.module.declarations.items) |decl| {
        switch (decl) {
            .@"struct" => |d| {
                const name = v.symbolName(d.name);
                if (name.len == 0) continue;
                // Create struct type placeholder
                const st = v.arena.create(Types.Struct) catch continue;
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

fn resolveStructLayouts(v: *Validator) Allocator.Error!void {
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

fn resolveOneStructLayout(v: *Validator, d: *Ast.StructDecl) Allocator.Error!void {
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
        const member_name = v.symbolName(member.name);
        const member_range = v.symbolRange(member.name);
        if (seen_members.get(member_name)) |first_range| {
            v.addErrorWithRelatedR(member_range, Diagnostic.Code.duplicate_symbol, v.fmtError("duplicate member '{s}' in struct '{s}'", .{ member_name, name }), v.makeRelatedR(first_range, "first declared here"));
            continue;
        }
        try seen_members.put(v.arena, member_name, member_range);
        const member_type = v.resolveType(member.typ) orelse {
            if (member.typ != .ident)
                v.addErrorR(member_range, v.fmtError("cannot resolve type for member '{s}'", .{member_name}));
            continue;
        };
        // Validate @align and @size attributes
        for (member.attributes.items) |attr| {
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
                v.addErrorWithCodeR(member_range, Diagnostic.Code.runtime_array_not_last, v.fmtError("struct member '{s}' contains a runtime-sized array and cannot be nested in struct '{s}'", .{ member_name, name }));
            }
        }

        try fields.append(v.arena, .{
            .name = member_name,
            .typ = member_type,
            .offset = 0,
        });
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

// =========================================================================
// Phase 2.5: Detect Recursive Struct Definitions
// =========================================================================

fn checkRecursiveStructs(v: *Validator) void {
    var iter = v.struct_types.iterator();
    while (iter.next()) |entry| {
        if (v.structContainsCycle(entry.key_ptr.*, entry.value_ptr.*)) {
            v.addErrorWithCodeR(v.findStructRange(entry.key_ptr.*), Diagnostic.Code.recursive_type, v.fmtError("struct '{s}' contains itself recursively", .{entry.key_ptr.*}));
        }
    }
}

/// Iterative cycle detection using a worklist. Returns true if `root_name`
/// is reachable from any nested struct field of `start`.
fn structContainsCycle(v: *Validator, root_name: []const u8, start: *Types.Struct) bool {
    var visited: std.StringHashMapUnmanaged(void) = .{};
    var worklist: std.ArrayListUnmanaged(*Types.Struct) = .empty;
    worklist.append(v.arena, start) catch return false;

    // Bounded iteration — struct count is finite and small.
    const max_iterations = v.struct_types.count() + 1;
    for (0..max_iterations) |_| {
        const current = worklist.pop() orelse return false;
        for (current.fields) |field| {
            const nested = extractNestedStruct(field.typ) orelse continue;
            if (std.mem.eql(u8, nested.name, root_name)) return true;
            if (visited.get(nested.name) != null) continue;
            visited.put(v.arena, nested.name, {}) catch continue;
            worklist.append(v.arena, nested) catch continue;
        }
    }
    return false;
}

/// Extract a nested struct from a type, looking through arrays.
fn extractNestedStruct(typ: Types.Type) ?*Types.Struct {
    return switch (typ) {
        .@"struct" => |s| s,
        .array => |arr| switch (arr.element) {
            .@"struct" => |s| s,
            else => null,
        },
        else => null,
    };
}

fn findStructLoc(v: *Validator, name: []const u8) u32 {
    return v.findStructRange(name).start;
}

fn findStructRange(v: *Validator, name: []const u8) LocRange {
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

fn checkRecursiveFunctions(v: *Validator) Allocator.Error!void {
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
fn dfsFunctionCycle(v: *Validator, call_graph: *const std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)), color: *std.AutoHashMapUnmanaged(u32, u2), start: u32) Allocator.Error!void {
    const Frame = struct { fn_idx: u32, callee_idx: usize };
    var stack: std.ArrayListUnmanaged(Frame) = .empty;
    defer stack.deinit(v.arena);

    color.put(v.arena, start, 1) catch return; // gray
    stack.append(v.arena, .{ .fn_idx = start, .callee_idx = 0 }) catch return;

    const num_syms: usize = v.module.symbols.items.len;
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
            color.put(v.arena, callee, 1) catch continue; // gray
            try stack.append(v.arena, .{ .fn_idx = callee, .callee_idx = 0 });
        }
        // black (2) = already fully processed, skip
    } else unreachable;
}

// =========================================================================
// Phase 3: Validate Declarations
// =========================================================================

fn validateDeclarations(v: *Validator) Allocator.Error!void {
    for (v.module.declarations.items) |decl| {
        switch (decl) {
            .@"const" => |d| try v.validateConstDecl(d),
            .override => |d| try v.validateOverrideDecl(d),
            .@"var" => |d| try v.validateVarDecl(d),
            .let => |d| try v.validateLetDecl(d),
            .const_assert => |d| try v.validateConstAssert(d),
            else => {},
        }
    }
}

fn validateConstDecl(v: *Validator, d: *Ast.ConstDecl) Allocator.Error!void {
    const name = v.symbolName(d.name);
    const r = v.symbolRange(d.name);

    // const must have an initializer
    if (d.initializer == null) {
        v.addErrorWithCodeR(r, Diagnostic.Code.missing_initializer, v.fmtError("'const {s}' requires an initializer", .{name}));
        return;
    }

    // Infer or check type
    const init_type = (try v.checkExpr(d.initializer.?)) orelse return;

    var decl_type: ?Types.Type = null;
    if (d.typ) |ast_type| {
        decl_type = v.resolveType(ast_type);
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

    // const initializer must be a const-expression (not override or runtime).
    if (d.initializer) |init| {
        const stage = v.classifyExprStage(init);
        if (stage == .override_expr) {
            v.addErrorWithCodeR(r, Diagnostic.Code.invalid_const_expr, v.fmtError("const '{s}' initializer references an override; use 'override' instead of 'const'", .{name}));
            return;
        }
        if (stage == .runtime_expr) {
            v.addErrorWithCodeR(r, Diagnostic.Code.invalid_const_expr, v.fmtError("const '{s}' initializer is not a const-expression", .{name}));
            return;
        }
    }

    // const must have constructible type
    if (decl_type) |dt| {
        if (!dt.isConstructible()) {
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

fn validateOverrideDecl(v: *Validator, d: *Ast.OverrideDecl) Allocator.Error!void {
    const r = v.symbolRange(d.name);
    const name = v.symbolName(d.name);

    // override must be concrete scalar type
    var decl_type: ?Types.Type = null;
    if (d.typ) |ast_type| {
        decl_type = v.resolveType(ast_type);
    } else if (d.initializer) |init| {
        decl_type = try v.checkExpr(init);
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
        const init_type = try v.checkExpr(init);
        if (init_type) |it| {
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
        if (v.classifyExprStage(init) == .runtime_expr) {
            v.addErrorWithCodeR(exprRange(init), Diagnostic.Code.expression_not_const, v.fmtError("'override {s}' initializer must be a const- or override-expression", .{name}));
        }
    }

    // Validate @id attribute: must be 0..65535, unique
    try v.validateOverrideId(d, name);

    try v.setSymbolType(d.name, decl_type);
}

fn validateOverrideId(v: *Validator, d: *Ast.OverrideDecl, name: []const u8) Allocator.Error!void {
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

fn validateVarDecl(v: *Validator, d: *Ast.VarDecl) Allocator.Error!void {
    const r = v.symbolRange(d.name);
    const name = v.symbolName(d.name);

    // Determine type
    var decl_type: ?Types.Type = null;
    if (d.typ) |ast_type| {
        decl_type = v.resolveType(ast_type);
    } else if (d.initializer) |init| {
        decl_type = try v.checkExpr(init);
        // Convert abstract types to concrete for var declarations
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

    // Check initializer compatibility
    if (d.initializer) |init| {
        const init_type = try v.checkExpr(init);
        if (init_type) |it| {
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

    try v.setSymbolType(d.name, decl_type);
}

fn validateBindingAttributes(v: *Validator, d: *Ast.VarDecl, name: []const u8, r: LocRange) Allocator.Error!void {
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
fn checkSuspiciousBindingPatterns(v: *Validator) void {
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

fn countEntryPoints(module: *const Ast.Module) u32 {
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
fn validatePerEntryPointBindings(v: *Validator) Allocator.Error!void {
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

fn validateLetDecl(v: *Validator, d: *Ast.LetDecl) Allocator.Error!void {
    const r = v.symbolRange(d.name);
    const name = v.symbolName(d.name);

    // let must have an initializer
    if (d.initializer == null) {
        v.addErrorWithCodeR(r, Diagnostic.Code.missing_initializer, v.fmtError("'let {s}' requires an initializer", .{name}));
        return;
    }

    const init_type = (try v.checkExpr(d.initializer.?)) orelse return;

    if (!init_type.isConstructible() and init_type != .pointer and init_type.isConcrete()) {
        v.addErrorWithCodeR(r, Diagnostic.Code.type_mismatch, v.fmtError("'let {s}' requires a constructible or pointer type, got '{s}'", .{ name, init_type.string() }));
        return;
    }

    var decl_type: ?Types.Type = null;
    if (d.typ) |ast_type| {
        decl_type = v.resolveType(ast_type);
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

fn validateConstAssert(v: *Validator, d: *Ast.ConstAssertDecl) Allocator.Error!void {
    // Per WGSL §11.9 a const_assert expression must be a const-expression.
    // Override- and runtime-expressions are rejected up front so we don't
    // emit a misleading "not bool" error when the real problem is staging.
    if (v.classifyExprStage(d.expr) != .const_expr) {
        v.addErrorWithCodeR(exprSpan(d.expr), Diagnostic.Code.expression_not_const, "const_assert expression must be a const-expression");
        return;
    }

    const expr_type = (try v.checkExpr(d.expr)) orelse return;
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

fn validateAddressSpace(v: *Validator, d: *Ast.VarDecl, var_type: Types.Type) void {
    const r = v.symbolRange(d.name);
    const name = v.symbolName(d.name);
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

fn checkUniformLayout(v: *Validator, typ: Types.Type, r: LocRange, var_name: []const u8) void {
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
fn registerFunctionSignatures(v: *Validator) Allocator.Error!void {
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

fn validateFunctions(v: *Validator) Allocator.Error!void {
    for (v.module.declarations.items) |decl| {
        switch (decl) {
            .function => |fn_decl| try v.validateFunction(fn_decl),
            else => {},
        }
    }
}

fn validateFunction(v: *Validator, fn_decl: *Ast.FunctionDecl) Allocator.Error!void {
    v.current_func = fn_decl;
    v.in_loop = false;
    v.in_switch = false;
    v.has_return = false;

    // Determine shader stage
    v.current_stage = .none;
    for (fn_decl.attributes.items) |attr| {
        if (std.mem.eql(u8, attr.name, "vertex")) {
            v.current_stage = .vertex;
        } else if (std.mem.eql(u8, attr.name, "fragment")) {
            v.current_stage = .fragment;
        } else if (std.mem.eql(u8, attr.name, "compute")) {
            v.current_stage = .compute;
        }
    }

    // WGSL spec: function parameter count must not exceed 255
    if (fn_decl.parameters.items.len > 255) {
        v.addErrorWithCodeR(v.symbolRange(fn_decl.name), Diagnostic.Code.invalid_entry_point, v.fmtError("function '{s}' has {d} parameters, exceeding the maximum of 255", .{ v.symbolName(fn_decl.name), fn_decl.parameters.items.len }));
    }

    // Resolve return type
    if (fn_decl.return_type) |rt| {
        v.return_type = v.resolveType(rt);
        if (v.return_type) |ret| {
            if (!ret.isConstructible()) {
                v.addErrorWithCodeR(v.symbolRange(fn_decl.name), Diagnostic.Code.type_mismatch, v.fmtError("function '{s}' has non-constructible return type '{s}'", .{ v.symbolName(fn_decl.name), ret.string() }));
            }
        }
    } else {
        v.return_type = null;
    }

    // Resolve parameter types and build function type
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
        v.validateParameterAttributes(param);
    }

    // Register function type in symbol_types so calls can resolve it
    if (fn_decl.name.isValid()) {
        const fn_type = Types.functionType(v.arena, param_types.items, v.return_type) catch null;
        if (fn_type) |ft| {
            try v.setSymbolType(fn_decl.name, ft);
        }
    }

    // Validate entry point requirements
    if (v.current_stage != .none) {
        try v.validateEntryPoint(fn_decl);
    }

    // Validate function body
    if (fn_decl.body) |body| {
        try v.validateCompoundStmt(body);
    }

    // Check for missing return
    if (v.return_type != null and !v.has_return) {
        v.addErrorWithCodeR(v.symbolRange(fn_decl.name), Diagnostic.Code.missing_return, v.fmtError("function '{s}' must return a value", .{v.symbolName(fn_decl.name)}));
    }

    v.current_func = null;
    v.return_type = null;
}

fn validateParameterAttributes(v: *Validator, param: Ast.Parameter) void {
    for (param.attributes.items) |attr| {
        if (std.mem.eql(u8, attr.name, "location")) {
            if (v.current_stage == .none) {
                v.addErrorWithCodeR(attrRange(&attr), Diagnostic.Code.invalid_attribute, "@location is only valid on entry point parameters");
            } else if (v.current_stage == .compute) {
                v.addErrorWithCodeR(attrRange(&attr), Diagnostic.Code.invalid_attribute, "compute shaders cannot have user-defined inputs (@location)");
            }
        } else if (std.mem.eql(u8, attr.name, "builtin")) {
            if (attr.args.items.len > 0) {
                switch (attr.args.items[0]) {
                    .ident => |ident| {
                        v.validateBuiltinForStage(ident.name, true, attr.loc);
                    },
                    else => {},
                }
            }
        }
    }
}

fn validateEntryPoint(v: *Validator, fn_decl: *Ast.FunctionDecl) Allocator.Error!void {
    const fn_range = v.symbolRange(fn_decl.name);
    switch (v.current_stage) {
        .vertex => {
            // Must return @builtin(position)
            if (!v.vertexHasPositionOutput(fn_decl)) {
                v.addErrorWithCodeR(fn_range, Diagnostic.Code.invalid_entry_point, v.fmtError("vertex entry point '{s}' must include @builtin(position) output", .{v.symbolName(fn_decl.name)}));
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

fn validateEntryPointIO(v: *Validator, fn_decl: *Ast.FunctionDecl) Allocator.Error!void {
    const fn_range = v.symbolRange(fn_decl.name);

    // Track duplicate builtins across all I/O members.
    var input_builtins: std.StringHashMapUnmanaged(u32) = .{};
    var output_builtins: std.StringHashMapUnmanaged(u32) = .{};

    // Check input locations (parameters)
    var input_locations: std.AutoHashMapUnmanaged(i64, u32) = .{};
    for (fn_decl.parameters.items) |param| {
        // Direct @location on parameter
        if (getLocationInfo(param.attributes)) |info| {
            if (input_locations.get(info.value)) |first_loc| {
                v.addErrorWithRelatedR(v.symbolRange(param.name), Diagnostic.Code.invalid_shader_io, v.fmtError("duplicate input @location({d})", .{info.value}), v.makeRelatedR(.{ .start = first_loc, .end = first_loc +| 1 }, v.fmtError("@location({d}) first used here", .{info.value})));
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
                            v.addErrorWithRelatedR(v.symbolRange(member.name), Diagnostic.Code.invalid_shader_io, v.fmtError("duplicate input @location({d})", .{info.value}), v.makeRelatedR(.{ .start = first_loc, .end = first_loc +| 1 }, v.fmtError("@location({d}) first used here", .{info.value})));
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
                            input_builtins.put(v.arena, bn, v.symbolLoc(member.name)) catch {};
                        }
                    }
                }
            }
        }
    }

    // Check output locations (return type)
    var output_locations: std.AutoHashMapUnmanaged(i64, u32) = .{};
    if (getLocationInfo(fn_decl.return_attr)) |info| {
        try output_locations.put(v.arena, info.value, info.loc);
    }
    if (fn_decl.return_type) |rt| {
        const ret_type = v.resolveType(rt) orelse return;
        if (ret_type == .@"struct") {
            if (v.findStructDecl(ret_type.@"struct".name)) |sd| {
                for (sd.members.items) |member| {
                    // Nested struct in output I/O is invalid.
                    const out_mt = v.resolveType(member.typ);
                    if (out_mt != null and out_mt.? == .@"struct") {
                        v.addErrorWithCodeR(v.symbolRange(member.name), Diagnostic.Code.invalid_shader_io, v.fmtError("entry point I/O member '{s}' cannot be a struct type", .{v.symbolName(member.name)}));
                    }
                    if (!hasLocationOrBuiltin(member.attributes)) {
                        v.addErrorWithCodeR(fn_range, Diagnostic.Code.invalid_shader_io, v.fmtError("entry point struct member '{s}' must have @builtin or @location", .{v.symbolName(member.name)}));
                    }
                    if (getLocationInfo(member.attributes)) |info| {
                        if (output_locations.get(info.value)) |first_loc| {
                            v.addErrorWithRelatedR(fn_range, Diagnostic.Code.invalid_shader_io, v.fmtError("duplicate output @location({d})", .{info.value}), v.makeRelatedR(.{ .start = first_loc, .end = first_loc +| 1 }, v.fmtError("@location({d}) first used here", .{info.value})));
                        } else {
                            try output_locations.put(v.arena, info.value, info.loc);
                        }
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
                            output_builtins.put(v.arena, bn, v.symbolLoc(member.name)) catch {};
                        }
                    }
                }
            }
        }
    }
}

/// Validate @interpolate attributes on entry point I/O members.
/// Called from validateEntryPointIO for fragment inputs and vertex outputs.
fn validateInterpolation(v: *Validator, attrs: std.ArrayListUnmanaged(Ast.Attribute), member_type: ?Types.Type, member_loc: u32) void {
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
fn typeContainsAtomic(typ: Types.Type) bool {
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
fn hasDuplicateSwizzleChars(name: []const u8) bool {
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

/// @invariant can only apply to @builtin(position) (WGSL spec section 9.3.3).
fn validateInvariantAttr(v: *Validator, attrs: std.ArrayListUnmanaged(Ast.Attribute), member_loc: u32) void {
    if (!hasAttr(attrs, "invariant")) return;
    if (!hasBuiltinAttr(attrs, "position")) {
        v.addErrorWithCodeR(.{ .start = member_loc, .end = member_loc +| 1 }, Diagnostic.Code.invalid_attribute, "@invariant can only be applied to @builtin(position)");
    }
}

fn hasAttr(attrs: std.ArrayListUnmanaged(Ast.Attribute), name: []const u8) bool {
    for (attrs.items) |attr| {
        if (std.mem.eql(u8, attr.name, name)) return true;
    }
    return false;
}

fn exprIdent(expr: Ast.Expr) []const u8 {
    return switch (expr) {
        .ident => |e| e.name,
        else => "",
    };
}

fn isIntegerVector(t: Types.Type) bool {
    return switch (t) {
        .vector => |ve| Types.isInteger(.{ .scalar = ve.element }),
        else => false,
    };
}

fn vertexHasPositionOutput(v: *Validator, fn_decl: *Ast.FunctionDecl) bool {
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

fn findStructDecl(v: *Validator, struct_name: []const u8) ?*Ast.StructDecl {
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

fn getLocationValue(attrs: std.ArrayListUnmanaged(Ast.Attribute)) ?i64 {
    if (getLocationInfo(attrs)) |info| return info.value;
    return null;
}

fn getLocationInfo(attrs: std.ArrayListUnmanaged(Ast.Attribute)) ?struct { value: i64, loc: u32 } {
    for (attrs.items) |attr| {
        if (std.mem.eql(u8, attr.name, "location") and attr.args.items.len > 0) {
            if (extractLiteralIntValue(attr.args.items[0])) |val| {
                return .{ .value = val, .loc = attr.loc };
            }
        }
    }
    return null;
}

/// Extract @builtin name from attributes, or null.
fn getBuiltinAttrName(attrs: std.ArrayListUnmanaged(Ast.Attribute)) ?[]const u8 {
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

fn hasLocationOrBuiltin(attrs: std.ArrayListUnmanaged(Ast.Attribute)) bool {
    for (attrs.items) |attr| {
        if (std.mem.eql(u8, attr.name, "location") or std.mem.eql(u8, attr.name, "builtin")) return true;
    }
    return false;
}

fn hasBuiltinAttr(attrs: std.ArrayListUnmanaged(Ast.Attribute), builtin_name: []const u8) bool {
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
    "workgroup_id",
    "num_workgroups",
    "subgroup_invocation_id",
    "subgroup_size",
};

const vertex_input_builtins = [_][]const u8{ "vertex_index", "instance_index" };
const vertex_output_builtins = [_][]const u8{"position"};
const fragment_input_builtins = [_][]const u8{ "position", "front_facing", "sample_index", "sample_mask", "subgroup_invocation_id", "subgroup_size" };
const fragment_output_builtins = [_][]const u8{ "frag_depth", "sample_mask" };
const compute_input_builtins = [_][]const u8{ "local_invocation_id", "local_invocation_index", "global_invocation_id", "workgroup_id", "num_workgroups", "subgroup_invocation_id", "subgroup_size" };

fn isKnownBuiltinValue(name: []const u8) bool {
    for (&all_builtin_values) |v| {
        if (std.mem.eql(u8, name, v)) return true;
    }
    return false;
}

fn getStageBuiltins(stage: ShaderStage, is_input: bool) []const []const u8 {
    return switch (stage) {
        .vertex => if (is_input) &vertex_input_builtins else &vertex_output_builtins,
        .fragment => if (is_input) &fragment_input_builtins else &fragment_output_builtins,
        .compute => if (is_input) &compute_input_builtins else &.{},
        .none => &all_builtin_values,
    };
}

fn validateBuiltinForStage(v: *Validator, builtin_name: []const u8, is_input: bool, loc: u32) void {
    const r: LocRange = .{ .start = loc, .end = loc +| @as(u32, @intCast(builtin_name.len)) };
    // Check if the name is a known builtin value at all
    if (!isKnownBuiltinValue(builtin_name)) {
        if (suggestName(builtin_name, &all_builtin_values, 3)) |s| {
            v.addErrorWithCodeR(r, Diagnostic.Code.invalid_builtin, v.fmtError("unknown @builtin value '{s}'; did you mean '{s}'?", .{ builtin_name, s }));
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
            v.addErrorWithCodeR(r, Diagnostic.Code.invalid_builtin, v.fmtError("@builtin({s}) is not valid for {s} shaders; did you mean '{s}'?", .{ builtin_name, v.current_stage.string(), s }));
        } else {
            v.addErrorWithCodeR(r, Diagnostic.Code.invalid_builtin, v.fmtError("@builtin({s}) is not valid for {s} shaders", .{ builtin_name, v.current_stage.string() }));
        }
    }
}

fn isVertexInput(name: []const u8) bool {
    return std.mem.eql(u8, name, "vertex_index") or
        std.mem.eql(u8, name, "instance_index");
}

fn isVertexOutput(name: []const u8) bool {
    return std.mem.eql(u8, name, "position");
}

fn isFragmentInput(name: []const u8) bool {
    return std.mem.eql(u8, name, "position") or
        std.mem.eql(u8, name, "front_facing") or
        std.mem.eql(u8, name, "sample_index") or
        std.mem.eql(u8, name, "sample_mask") or
        std.mem.eql(u8, name, "subgroup_invocation_id") or
        std.mem.eql(u8, name, "subgroup_size");
}

fn isFragmentOutput(name: []const u8) bool {
    return std.mem.eql(u8, name, "frag_depth") or
        std.mem.eql(u8, name, "sample_mask");
}

fn isComputeInput(name: []const u8) bool {
    return std.mem.eql(u8, name, "local_invocation_id") or
        std.mem.eql(u8, name, "local_invocation_index") or
        std.mem.eql(u8, name, "global_invocation_id") or
        std.mem.eql(u8, name, "workgroup_id") or
        std.mem.eql(u8, name, "num_workgroups") or
        std.mem.eql(u8, name, "subgroup_invocation_id") or
        std.mem.eql(u8, name, "subgroup_size");
}

// =========================================================================
// Statement Validation
// =========================================================================

fn validateStmt(v: *Validator, stmt: Ast.Stmt) Allocator.Error!void {
    switch (stmt) {
        .compound => |s| try v.validateCompoundStmt(s),
        .@"return" => |s| try v.validateReturnStmt(s),
        .@"if" => |s| try v.validateIfStmt(s),
        .@"switch" => |s| try v.validateSwitchStmt(s),
        .loop => |s| try v.validateLoopStmt(s),
        .@"while" => |s| try v.validateWhileStmt(s),
        .@"for" => |s| try v.validateForStmt(s),
        .@"break" => |s| v.validateBreakStmt(s),
        .break_if => |s| try v.validateBreakIfStmt(s),
        .@"continue" => |s| v.validateContinueStmt(s),
        .discard => |s| v.validateDiscardStmt(s),
        .assign => |s| try v.validateAssignStmt(s),
        .incr_decr => |s| try v.validateIncrDecrStmt(s),
        .call => |s| try v.validateCallStmt(s),
        .decl => |s| try v.validateDeclStmt(s),
    }
}

const max_stmt_depth: u32 = 127;

fn validateCompoundStmt(v: *Validator, s: *Ast.CompoundStmt) Allocator.Error!void {
    v.stmt_depth += 1;
    defer v.stmt_depth -= 1;

    if (v.stmt_depth > max_stmt_depth) {
        // Report once at the first stmt in the block (if any)
        const loc: LocRange = if (s.stmts.items.len > 0) v.getStmtRange(s.stmts.items[0]) else .{ .start = 0, .end = 1 };
        v.addErrorWithCodeR(loc, Diagnostic.Code.nesting_too_deep, v.fmtError("statement nesting depth exceeds maximum of {d}", .{max_stmt_depth}));
        return;
    }

    var terminated = false;
    for (s.stmts.items) |stmt| {
        if (terminated) {
            v.addErrorWithCodeR(v.getStmtRange(stmt), Diagnostic.Code.unreachable_code, "code is unreachable");
            break; // report once per block
        }
        try v.validateStmt(stmt);
        if (stmtTerminates(stmt)) terminated = true;
    }
}

/// Iteratively checks whether a statement always terminates (return/break/continue).
/// Uses a fixed-size stack: all pushed statements must terminate for the result to be true.
fn stmtTerminates(root: Ast.Stmt) bool {
    var stack: [64]Ast.Stmt = undefined;
    var top: usize = 1;
    stack[0] = root;

    while (top > 0) {
        top -= 1;
        var current = stack[top];
        // Follow compound→last and if→body+else chains
        for (0..65536) |_| {
            switch (current) {
                .@"return", .@"break", .@"continue", .discard => break,
                .compound => |s| {
                    if (s.stmts.items.len == 0) return false;
                    current = s.stmts.items[s.stmts.items.len - 1];
                },
                .@"if" => |s| {
                    if (s.body.stmts.items.len == 0) return false;
                    // Push else branch — it must also terminate
                    const eb = s.else_branch orelse return false;
                    if (top >= stack.len) return false;
                    stack[top] = eb;
                    top += 1;
                    // Continue checking body's last statement
                    current = s.body.stmts.items[s.body.stmts.items.len - 1];
                },
                .@"switch" => |s| {
                    var has_default = false;
                    for (s.cases.items) |c| {
                        if (c.selectors.items.len == 0) has_default = true;
                        if (c.body.stmts.items.len == 0) return false;
                        // Push each case's last statement — all must terminate
                        if (top >= stack.len) return false;
                        stack[top] = c.body.stmts.items[c.body.stmts.items.len - 1];
                        top += 1;
                    }
                    if (!has_default) return false;
                    break;
                },
                else => return false,
            }
        } else unreachable;
    }
    return true;
}

fn getStmtLoc(v: *Validator, stmt: Ast.Stmt) u32 {
    return v.getStmtRange(stmt).start;
}

fn getStmtRange(v: *Validator, stmt: Ast.Stmt) LocRange {
    return switch (stmt) {
        .@"return" => |s| .{ .start = s.loc, .end = s.loc +| 6 }, // "return"
        .@"break" => |s| .{ .start = s.loc, .end = s.loc +| 5 }, // "break"
        .@"continue" => |s| .{ .start = s.loc, .end = s.loc +| 8 }, // "continue"
        .discard => |s| .{ .start = s.loc, .end = s.loc +| 7 }, // "discard"
        .assign => |s| .{ .start = s.loc, .end = s.loc +| @as(u32, @intCast(s.op.string().len)) },
        .incr_decr => |s| .{ .start = s.loc, .end = s.loc +| 2 }, // ++ or --
        .call => |s| exprRange(.{ .call = s.call }),
        .decl => |s| v.symbolRange(s.decl.nameRef()),
        else => .{ .start = 0, .end = 1 },
    };
}

fn validateReturnStmt(v: *Validator, s: *Ast.ReturnStmt) Allocator.Error!void {
    v.has_return = true;
    const ret_range: LocRange = .{ .start = s.loc, .end = s.loc +| 6 }; // "return"

    // WGSL spec section 9.5.2: continuing block must not contain a return statement.
    if (v.in_continuing) {
        v.addErrorWithCodeR(ret_range, Diagnostic.Code.return_in_continuing, "'return' is not allowed inside a continuing block");
    }

    if (s.value == null) {
        if (v.return_type) |rt| {
            v.addErrorWithCodeR(ret_range, Diagnostic.Code.missing_return, v.fmtError("return must provide a value of type '{s}'", .{rt.string()}));
        }
        return;
    }

    const expr_type = (try v.checkExpr(s.value.?)) orelse return;

    if (expr_type.isRuntimeSizedArray()) {
        v.addErrorWithCodeR(exprSpan(s.value.?), Diagnostic.Code.type_mismatch, "cannot return a runtime-sized array");
        return;
    }

    if (v.return_type) |rt| {
        if (!Types.canConvertTo(expr_type, rt)) {
            const related = if (v.current_func) |func| blk: {
                if (func.return_type) |frt| {
                    const rt_r = astTypeRange(frt);
                    if (rt_r.start != 0) break :blk v.makeRelatedR(rt_r, v.fmtError("return type '{s}' declared here", .{rt.string()}));
                }
                break :blk &[_]Diagnostic.RelatedInfo{};
            } else &[_]Diagnostic.RelatedInfo{};
            v.addErrorWithRelatedR(exprSpan(s.value.?), Diagnostic.Code.type_mismatch, v.fmtError("cannot return '{s}' from function expecting '{s}'", .{ expr_type.string(), rt.string() }), related);
        }
    } else {
        const fn_name = if (v.current_func) |f| v.symbolName(f.name) else "";
        v.addErrorWithCodeR(exprSpan(s.value.?), Diagnostic.Code.invalid_return, v.fmtError("cannot return a value from void function '{s}'", .{fn_name}));
    }
}

/// Iteratively validates if/else-if/else chains without recursion.
fn validateIfStmt(v: *Validator, s: *Ast.IfStmt) Allocator.Error!void {
    var current: *Ast.IfStmt = s;
    for (0..65536) |_| {
        const cond_type = try v.checkExpr(current.condition);
        if (cond_type) |ct| {
            if (!ct.eql(Types.Bool)) {
                v.addErrorWithCodeR(exprSpan(current.condition), Diagnostic.Code.type_mismatch, v.fmtError("if condition must be 'bool', got '{s}'", .{ct.string()}));
            }
        }

        try v.validateCompoundStmt(current.body);
        const eb = current.else_branch orelse break;
        switch (eb) {
            .@"if" => |next_if| current = next_if,
            else => {
                try v.validateStmt(eb);
                break;
            },
        }
    } else unreachable;
}

fn validateSwitchStmt(v: *Validator, s: *Ast.SwitchStmt) Allocator.Error!void {
    const selector_type = try v.checkExpr(s.expr);
    if (selector_type) |st| {
        if (!Types.isInteger(st)) {
            v.addErrorWithCodeR(exprSpan(s.expr), Diagnostic.Code.type_mismatch, v.fmtError("switch selector must be integer, got '{s}'", .{st.string()}));
        }
    }

    const prev_in_switch = v.in_switch;
    v.in_switch = true;

    var default_count: u32 = 0;
    var seen_values: std.AutoHashMapUnmanaged(i64, u32) = .{};

    for (s.cases.items) |case| {
        if (case.selectors.items.len == 0) {
            // Default case
            default_count += 1;
            if (default_count > 1) {
                v.addErrorWithCodeR(exprSpan(s.expr), Diagnostic.Code.missing_default_case, "switch statement has multiple default clauses");
            }
        }
        for (case.selectors.items) |sel| {
            const sel_type = try v.checkExpr(sel);
            if (sel_type != null and selector_type != null) {
                if (!Types.canConvertTo(sel_type.?, selector_type.?)) {
                    v.addErrorWithRelatedR(exprRange(sel), Diagnostic.Code.type_mismatch, v.fmtError("case selector '{s}' doesn't match switch type '{s}'", .{ sel_type.?.string(), selector_type.?.string() }), v.makeRelatedR(exprRange(s.expr), v.fmtError("switch expression has type '{s}'", .{selector_type.?.string()})));
                }
            }
            // Switch case selectors must be const-expressions
            if (v.classifyExprStage(sel) != .const_expr) {
                v.addErrorWithCodeR(exprRange(sel), Diagnostic.Code.expression_not_const, "case selector must be a const-expression");
            }
            // Check for duplicate case selector values
            if (v.tryExtractIntValue(sel)) |val| {
                if (seen_values.get(val) != null) {
                    v.addErrorWithCodeR(exprRange(sel), Diagnostic.Code.duplicate_case_selector, v.fmtError("duplicate case selector value '{d}'", .{val}));
                } else {
                    try seen_values.put(v.arena, val, 1);
                }
            }
        }
        try v.validateCompoundStmt(case.body);
    }

    if (default_count == 0) {
        v.addErrorWithCodeR(exprSpan(s.expr), Diagnostic.Code.missing_default_case, "switch statement must have a default clause");
    }

    v.in_switch = prev_in_switch;
}

fn validateLoopStmt(v: *Validator, s: *Ast.LoopStmt) Allocator.Error!void {
    const prev_in_loop = v.in_loop;
    v.in_loop = true;

    try v.validateCompoundStmt(s.body);
    if (s.continuing) |cont| {
        const prev_in_continuing = v.in_continuing;
        v.in_continuing = true;
        try v.validateCompoundStmt(cont);
        v.in_continuing = prev_in_continuing;

        // Spec: break if must be the last statement in a continuing block.
        for (cont.stmts.items, 0..) |stmt, i| {
            if (stmt == .break_if and i != cont.stmts.items.len - 1) {
                v.addErrorWithCodeR(v.getStmtRange(stmt), Diagnostic.Code.break_outside_loop, "'break if' must be the last statement in a continuing block");
            }
        }
    }

    // Detect infinite loops: body has no exit and continuing has no break_if
    if (!blockHasExit(s.body) and !continuingHasBreakIf(s.continuing)) {
        // Use the first statement's location if available, or a default
        const loc = if (s.body.stmts.items.len > 0) v.getStmtRange(s.body.stmts.items[0]).start else 0;
        v.addWarningR(.{ .start = loc, .end = loc +| 4 }, "loop has no exit path (break, return, or discard)");
    }

    v.in_loop = prev_in_loop;
}

fn validateWhileStmt(v: *Validator, s: *Ast.WhileStmt) Allocator.Error!void {
    const cond_type = try v.checkExpr(s.condition);
    if (cond_type) |ct| {
        if (!ct.eql(Types.Bool)) {
            v.addErrorWithCodeR(exprSpan(s.condition), Diagnostic.Code.type_mismatch, v.fmtError("while condition must be 'bool', got '{s}'", .{ct.string()}));
        }
    }

    const prev_in_loop = v.in_loop;
    v.in_loop = true;
    try v.validateCompoundStmt(s.body);
    v.in_loop = prev_in_loop;
}

fn validateForStmt(v: *Validator, s: *Ast.ForStmt) Allocator.Error!void {
    if (s.init_stmt) |init| {
        try v.validateStmt(init);
    }
    if (s.condition) |cond| {
        const cond_type = try v.checkExpr(cond);
        if (cond_type) |ct| {
            if (!ct.eql(Types.Bool)) {
                v.addErrorWithCodeR(exprSpan(cond), Diagnostic.Code.type_mismatch, v.fmtError("for condition must be 'bool', got '{s}'", .{ct.string()}));
            }
        }
    }
    if (s.update) |update| {
        try v.validateStmt(update);
    }

    const prev_in_loop = v.in_loop;
    v.in_loop = true;
    try v.validateCompoundStmt(s.body);
    v.in_loop = prev_in_loop;
}

fn validateBreakStmt(v: *Validator, s: *Ast.BreakStmt) void {
    const r: LocRange = .{ .start = s.loc, .end = s.loc +| 5 }; // "break"
    if (!v.in_loop and !v.in_switch) {
        v.addErrorWithCodeR(r, Diagnostic.Code.break_outside_loop, "break statement must be inside a loop or switch");
    } else if (v.in_continuing) {
        v.addErrorWithCodeR(r, Diagnostic.Code.break_outside_loop, "'break' must not be used in a continuing block (use 'break if' instead)");
    }
}

fn validateBreakIfStmt(v: *Validator, s: *Ast.BreakIfStmt) Allocator.Error!void {
    const cond_type = try v.checkExpr(s.condition);
    if (cond_type) |ct| {
        if (!ct.eql(Types.Bool)) {
            v.addErrorWithCodeR(exprSpan(s.condition), Diagnostic.Code.type_mismatch, v.fmtError("break if condition must be 'bool', got '{s}'", .{ct.string()}));
        }
    }
}

fn validateContinueStmt(v: *Validator, s: *Ast.ContinueStmt) void {
    if (!v.in_loop) {
        v.addErrorWithCodeR(.{ .start = s.loc, .end = s.loc +| 8 }, Diagnostic.Code.continue_outside_loop, "continue statement must be inside a loop"); // "continue"
    }
}

fn validateDiscardStmt(v: *Validator, s: *Ast.DiscardStmt) void {
    if (v.current_stage != .fragment) {
        v.addErrorWithCodeR(.{ .start = s.loc, .end = s.loc +| 7 }, Diagnostic.Code.discard_outside_fragment, v.fmtError("'discard' is only valid in fragment shaders, not {s}", .{v.current_stage.string()})); // "discard"
    }
    // discard terminates the invocation, satisfying any return requirement.
    v.has_return = true;
}

fn validateAssignStmt(v: *Validator, s: *Ast.AssignStmt) Allocator.Error!void {
    const lhs_type = (try v.checkExpr(s.left)) orelse return;
    const rhs_type = (try v.checkExpr(s.right)) orelse return;

    // Check for assignment to immutable bindings (WGSL spec section 9.4).
    if (s.left == .ident) {
        const ident = s.left.ident;
        if (ident.ref.isValid()) {
            const idx = ident.ref.index();
            if (idx < v.module.symbols.items.len) {
                const kind = v.module.symbols.items[idx].kind;
                switch (kind) {
                    .let => v.addErrorWithCodeR(exprRange(s.left), Diagnostic.Code.invalid_assignment, v.fmtError("cannot assign to 'let' variable '{s}'", .{ident.name})),
                    .@"const" => v.addErrorWithCodeR(exprRange(s.left), Diagnostic.Code.invalid_assignment, v.fmtError("cannot assign to 'const' '{s}'", .{ident.name})),
                    .override => v.addErrorWithCodeR(exprRange(s.left), Diagnostic.Code.invalid_assignment, v.fmtError("cannot assign to 'override' '{s}'", .{ident.name})),
                    .parameter => v.addErrorWithCodeR(exprRange(s.left), Diagnostic.Code.invalid_assignment, v.fmtError("cannot assign to parameter '{s}'", .{ident.name})),
                    else => {},
                }
            }
        }
    }

    // Duplicate swizzle components in write target are invalid (WGSL spec section 9.4).
    if (s.left == .member) {
        const member = s.left.member;
        if (member.base == .ident or member.base == .member) {
            if (hasDuplicateSwizzleChars(member.member_name)) {
                v.addErrorWithCodeR(exprRange(s.left), Diagnostic.Code.invalid_assignment, v.fmtError("swizzle assignment target '{s}' has duplicate components", .{member.member_name}));
            }
        }
    }

    if (s.op == .simple) {
        // Simple assignment: RHS must be convertible to LHS.
        if (!Types.canConvertTo(rhs_type, lhs_type)) {
            v.addErrorWithRelatedR(exprSpan(s.right), Diagnostic.Code.type_mismatch, v.fmtError("cannot assign '{s}' to '{s}'", .{ rhs_type.string(), lhs_type.string() }), v.makeRelatedR(exprRange(s.left), v.fmtError("left-hand side has type '{s}'", .{lhs_type.string()})));
        }
        return;
    }

    // Compound assignment (+=, -=, *=, etc.): v op= e is defined as v = v op e.
    // Compute the result type of the binary operation, then verify assignability.
    const result_type: ?Types.Type = switch (s.op) {
        .add, .sub => Types.addSubResultType(v.arena, lhs_type, rhs_type) catch null,
        .mul => Types.multiplyResultType(v.arena, lhs_type, rhs_type) catch null,
        .div => Types.divResultType(v.arena, lhs_type, rhs_type) catch null,
        .mod => if (Types.isNumeric(lhs_type) and Types.isNumeric(rhs_type))
            Types.commonType(lhs_type, rhs_type)
        else
            null,
        .@"and", .@"or", .xor => if ((lhs_type.eql(Types.Bool) and rhs_type.eql(Types.Bool)) or
            (Types.isInteger(lhs_type) and Types.isInteger(rhs_type)))
            (Types.commonType(lhs_type, rhs_type) orelse lhs_type)
        else
            null,
        .shl, .shr => if (Types.isInteger(lhs_type) and
            (rhs_type.eql(Types.U32) or Types.canConvertTo(rhs_type, Types.U32)))
            lhs_type
        else
            null,
        .simple => unreachable,
    };

    if (result_type == null) {
        const op_range: LocRange = .{ .start = s.loc, .end = s.loc +| @as(u32, @intCast(s.op.string().len)) };
        v.addErrorWithCodeR(op_range, Diagnostic.Code.invalid_operand, v.fmtError("invalid operands for '{s}': '{s}' and '{s}'", .{ s.op.string(), lhs_type.string(), rhs_type.string() }));
        return;
    }

    if (!Types.canConvertTo(result_type.?, lhs_type)) {
        const op_range: LocRange = .{ .start = s.loc, .end = s.loc +| @as(u32, @intCast(s.op.string().len)) };
        v.addErrorWithCodeR(op_range, Diagnostic.Code.type_mismatch, v.fmtError("result type '{s}' of '{s}' is not assignable to '{s}'", .{ result_type.?.string(), s.op.string(), lhs_type.string() }));
    }
}

fn validateIncrDecrStmt(v: *Validator, s: *Ast.IncrDecrStmt) Allocator.Error!void {
    const expr_type = (try v.checkExpr(s.expr)) orelse return;
    // Spec: operand must be a concrete integer scalar (i32 or u32 only).
    const is_concrete_int_scalar = switch (expr_type) {
        .scalar => |sc| sc.kind == .i32 or sc.kind == .u32,
        else => false,
    };
    if (!is_concrete_int_scalar) {
        v.addErrorWithCodeR(exprSpan(s.expr), Diagnostic.Code.type_mismatch, v.fmtError("increment/decrement requires concrete integer scalar (i32 or u32), got '{s}'", .{expr_type.string()}));
    }
}

fn validateCallStmt(v: *Validator, s: *Ast.CallStmt) Allocator.Error!void {
    _ = try v.checkCallExpr(s.call);

    // @must_use: builtin functions with return values must not be called as statements
    if (s.call.func) |func| {
        switch (func) {
            .ident => |ident| {
                if (Builtins.lookup(ident.name)) |builtin_fn| {
                    if (builtin_fn.must_use) {
                        v.addErrorWithCodeR(exprRange(.{ .call = s.call }), Diagnostic.Code.must_use_ignored, v.fmtError("return value of '@must_use' builtin '{s}' must be used", .{ident.name}));
                    }
                }
            },
            else => {},
        }
    }
}

fn validateDeclStmt(v: *Validator, s: *Ast.DeclStmt) Allocator.Error!void {
    switch (s.decl) {
        .@"const" => |d| try v.validateConstDecl(d),
        .let => |d| try v.validateLetDecl(d),
        .@"var" => |d| try v.validateVarDecl(d),
        .const_assert => |d| try v.validateConstAssert(d),
        else => {},
    }
}

// =========================================================================
// Expression Type Checking
// =========================================================================

const max_expr_depth: u32 = 256;

fn checkExpr(v: *Validator, expr: Ast.Expr) Allocator.Error!?Types.Type {
    if (v.expr_depth >= max_expr_depth) return null;
    v.expr_depth += 1;
    defer v.expr_depth -= 1;
    const result: ?Types.Type = switch (expr) {
        .literal => |e| v.checkLiteral(e),
        .ident => |e| v.checkIdent(e),
        .binary => |e| try v.checkBinary(e),
        .unary => |e| try v.checkUnary(e),
        .call => |e| try v.checkCallExpr(e),
        .index => |e| try v.checkIndex(e),
        .member => |e| try v.checkMember(e),
        .paren => |e| try v.checkExpr(e.expr),
    };
    if (result) |typ| {
        // Key on each expression's own loc (operator for binary, open-paren
        // for call, etc.) so nested expressions that share the same start
        // offset don't collide in the hash map.
        const key: ?u32 = switch (expr) {
            .binary => |e| e.loc,
            .call => |e| e.loc,
            .index => |e| e.loc,
            .member => |e| e.loc,
            else => null,
        };
        if (key) |k| {
            v.expr_types.put(v.arena, k, .{
                .typ = typ,
                .end_offset = exprSpan(expr).end,
            }) catch {};
        }
    }
    return result;
}

fn checkLiteral(v: *Validator, e: *Ast.LiteralExpr) ?Types.Type {
    const val = e.value;
    if (val.len == 0) return Types.AbstractInt;

    // Boolean literals
    if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "false")) {
        return Types.Bool;
    }

    // Check for float indicators
    if (hasByteAny(val, ".eE")) {
        v.checkFloatLiteralValue(e);
        if (val[val.len - 1] == 'h') {
            v.checkF16Enabled(e.loc);
            return Types.F16;
        }
        if (val[val.len - 1] == 'f') return Types.F32;
        return Types.AbstractFloat;
    }

    // Suffix-based typing
    if (val[val.len - 1] == 'h') {
        v.checkFloatLiteralValue(e);
        v.checkF16Enabled(e.loc);
        return Types.F16;
    }
    if (val[val.len - 1] == 'f') {
        v.checkFloatLiteralValue(e);
        return Types.F32;
    }
    if (val[val.len - 1] == 'u') return Types.U32;
    if (val[val.len - 1] == 'i') return Types.I32;

    return Types.AbstractInt;
}

/// Walk the scope tree once and emit W0100 for every symbol declared in a
/// non-module scope whose name is also visible in an ancestor scope.
fn detectShadowing(v: *Validator) void {
    v.walkScopesForShadow(v.module.scope);
}

fn walkScopesForShadow(v: *Validator, scope: *Ast.Scope) void {
    for (scope.children.items) |child| {
        var it = child.members.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const member = entry.value_ptr.*;
            if (!member.ref.isValid()) continue;
            var ancestor: ?*Ast.Scope = child.parent;
            while (ancestor) |a| {
                if (a.members.get(name)) |outer| {
                    if (outer.ref.isValid() and outer.ref.index() != member.ref.index()) {
                        const kind = v.symbolKind(outer.ref);
                        const label = if (a.kind == .module)
                            "a module-scope declaration"
                        else switch (kind) {
                            .parameter => "a function parameter",
                            else => "an earlier declaration",
                        };
                        v.addWarningWithCodeR(
                            v.symbolRange(member.ref),
                            Diagnostic.Code.shadowing,
                            v.fmtError("'{s}' shadows {s}", .{ name, label }),
                        );
                        break;
                    }
                }
                ancestor = a.parent;
            }
        }
        v.walkScopesForShadow(child);
    }
}

fn symbolKind(v: *Validator, sym_idx: Ast.SymbolIndex) Ast.Symbol.Kind {
    if (!sym_idx.isValid()) return .unbound;
    return v.module.symbols.items[sym_idx.index()].kind;
}

// =========================================================================
// Phase 7: Ambiguous operator-precedence mixing (E0213)
// =========================================================================

/// Operator family for precedence-mixing checks. Ops within the same family
/// generally compose freely; ops across the pairs listed in `precedenceConflicts`
/// must be explicitly parenthesised by the author.
const OpClass = enum { arithmetic, shift, relational, equality, bitwise, logical, other };

fn classOfBinaryOp(op: Ast.BinaryOp) OpClass {
    return switch (op) {
        .add, .sub, .mul, .div, .mod => .arithmetic,
        .shl, .shr => .shift,
        .lt, .le, .gt, .ge => .relational,
        .eq, .ne => .equality,
        .@"and", .@"or", .xor => .bitwise,
        .logical_and, .logical_or => .logical,
    };
}

/// Returns true when a binary op applied to a non-parenthesised binary child
/// of this parent-and-child-op pair produces an expression whose intended
/// grouping is ambiguous under WGSL §8.18 and must be explicitly parenthesised.
/// The check is op-pair-aware for bitwise and logical families (where identical
/// ops are associative and fine, but mixed ones are not).
fn isAmbiguousNesting(parent: Ast.BinaryOp, child: Ast.BinaryOp) bool {
    const p = classOfBinaryOp(parent);
    const c = classOfBinaryOp(child);
    if (p == .shift and (c == .arithmetic or c == .relational or c == .equality or c == .shift)) return true;
    if ((p == .relational or p == .equality) and c == .shift) return true;
    // Bitwise `&`, `|`, `^`: each is associative with itself, but mixing any
    // two of them without parens is ambiguous.
    if (p == .bitwise and c == .bitwise and parent != child) return true;
    // Short-circuit `&&` and `||` cannot be mixed without parens.
    if (p == .logical and c == .logical and parent != child) return true;
    return false;
}

fn checkOperatorPrecedence(v: *Validator) void {
    for (v.module.declarations.items) |decl| {
        switch (decl) {
            .function => |d| if (d.body) |body| v.walkStmtForPrecedence(.{ .compound = body }),
            .@"const" => |d| if (d.initializer) |e| v.walkExprForPrecedence(e),
            .override => |d| if (d.initializer) |e| v.walkExprForPrecedence(e),
            .@"var" => |d| if (d.initializer) |e| v.walkExprForPrecedence(e),
            .let => |d| if (d.initializer) |e| v.walkExprForPrecedence(e),
            .const_assert => |d| v.walkExprForPrecedence(d.expr),
            else => {},
        }
    }
}

fn walkStmtForPrecedence(v: *Validator, stmt: Ast.Stmt) void {
    switch (stmt) {
        .compound => |s| for (s.stmts.items) |sub| v.walkStmtForPrecedence(sub),
        .@"return" => |s| if (s.value) |e| v.walkExprForPrecedence(e),
        .@"if" => |s| {
            v.walkExprForPrecedence(s.condition);
            v.walkStmtForPrecedence(.{ .compound = s.body });
            if (s.else_branch) |eb| v.walkStmtForPrecedence(eb);
        },
        .@"switch" => |s| {
            v.walkExprForPrecedence(s.expr);
            for (s.cases.items) |case| {
                for (case.selectors.items) |sel| v.walkExprForPrecedence(sel);
                v.walkStmtForPrecedence(.{ .compound = case.body });
            }
        },
        .@"for" => |s| {
            if (s.init_stmt) |init| v.walkStmtForPrecedence(init);
            if (s.condition) |c| v.walkExprForPrecedence(c);
            if (s.update) |u| v.walkStmtForPrecedence(u);
            v.walkStmtForPrecedence(.{ .compound = s.body });
        },
        .@"while" => |s| {
            v.walkExprForPrecedence(s.condition);
            v.walkStmtForPrecedence(.{ .compound = s.body });
        },
        .loop => |s| v.walkStmtForPrecedence(.{ .compound = s.body }),
        .break_if => |s| v.walkExprForPrecedence(s.condition),
        .assign => |s| {
            v.walkExprForPrecedence(s.left);
            v.walkExprForPrecedence(s.right);
        },
        .incr_decr => |s| v.walkExprForPrecedence(s.expr),
        .call => |s| v.walkExprForPrecedence(.{ .call = s.call }),
        .decl => |s| switch (s.decl) {
            .@"const" => |d| if (d.initializer) |e| v.walkExprForPrecedence(e),
            .@"var" => |d| if (d.initializer) |e| v.walkExprForPrecedence(e),
            .let => |d| if (d.initializer) |e| v.walkExprForPrecedence(e),
            else => {},
        },
        .@"break", .@"continue", .discard => {},
    }
}

fn walkExprForPrecedence(v: *Validator, expr: Ast.Expr) void {
    switch (expr) {
        .binary => |b| {
            v.checkBinaryPrecedence(b);
            v.walkExprForPrecedence(b.left);
            v.walkExprForPrecedence(b.right);
        },
        .unary => |u| v.walkExprForPrecedence(u.operand),
        .call => |c| {
            if (c.func) |f| v.walkExprForPrecedence(f);
            for (c.args.items) |a| v.walkExprForPrecedence(a);
        },
        .index => |i| {
            v.walkExprForPrecedence(i.base);
            v.walkExprForPrecedence(i.idx);
        },
        .member => |m| v.walkExprForPrecedence(m.base),
        .paren => |p| v.walkExprForPrecedence(p.expr),
        .ident, .literal => {},
    }
}

fn checkBinaryPrecedence(v: *Validator, b: *Ast.BinaryExpr) void {
    checkOneSide(v, b, b.left);
    checkOneSide(v, b, b.right);
}

fn checkOneSide(v: *Validator, b: *Ast.BinaryExpr, side: Ast.Expr) void {
    const child = switch (side) {
        .binary => |cb| cb,
        else => return,
    };
    if (!isAmbiguousNesting(b.op, child.op)) return;
    const range: LocRange = .{ .start = b.loc, .end = b.loc +| @as(u32, @intCast(b.op.string().len)) };
    v.addErrorWithCodeR(
        range,
        Diagnostic.Code.ambiguous_precedence,
        v.fmtError(
            "'{s}' and '{s}' mix without parentheses; WGSL requires explicit grouping",
            .{ b.op.string(), child.op.string() },
        ),
    );
}

fn checkF16Enabled(v: *Validator, loc: u32) void {
    if (!v.enabled_features.contains("f16")) {
        v.addErrorWithCodeR(.{ .start = loc, .end = loc +| 1 }, Diagnostic.Code.feature_not_enabled, "'f16' requires 'enable f16;'");
    }
}

/// Validate that a float literal does not evaluate to NaN or infinity.
fn checkFloatLiteralValue(v: *Validator, e: *Ast.LiteralExpr) void {
    // Strip suffix for parsing
    var parse_str = e.value;
    if (parse_str.len > 0 and (parse_str[parse_str.len - 1] == 'f' or parse_str[parse_str.len - 1] == 'h')) {
        parse_str = parse_str[0 .. parse_str.len - 1];
    }
    if (parse_str.len == 0) return;
    const parsed = std.fmt.parseFloat(f64, parse_str) catch return;
    if (std.math.isNan(parsed)) {
        v.addErrorWithCodeR(.{ .start = e.loc, .end = e.loc +| @as(u32, @intCast(e.value.len)) }, Diagnostic.Code.invalid_float_literal, "float literal evaluates to NaN");
    } else if (std.math.isInf(parsed)) {
        v.addErrorWithCodeR(.{ .start = e.loc, .end = e.loc +| @as(u32, @intCast(e.value.len)) }, Diagnostic.Code.invalid_float_literal, "float literal evaluates to infinity");
    }
}

fn checkIdent(v: *Validator, e: *Ast.IdentExpr) ?Types.Type {
    // Check if it's a type name being used as expression (constructor)
    if (v.lookupType(e.name)) |t| {
        return t;
    }

    // Check symbol table
    if (e.ref.isValid()) {
        if (v.symbol_types.get(e.ref.index())) |t| {
            return t;
        }
    }

    // Check if it's a builtin function — return null, type comes from call resolution
    if (Builtins.isBuiltin(e.name)) {
        return null;
    }

    // Check if it's a user-defined function (by looking up symbols in module)
    if (e.ref.isValid()) {
        const idx = e.ref.index();
        if (idx < v.module.symbols.items.len) {
            const kind = v.module.symbols.items[idx].kind;
            // Function type resolved at call site
            if (kind == .function) return null;
            // Symbol exists but type not yet assigned — use-before-decl
            // (parser already emitted E0102, don't also report E0100)
            if (kind != .unbound) return null;
        }
    }

    // Undefined identifier
    if (v.suggestIdentifier(e.name)) |s| {
        v.addErrorWithCodeR(exprRange(.{ .ident = e }), Diagnostic.Code.undefined_symbol, v.fmtError("use of undeclared identifier '{s}'; did you mean '{s}'?", .{ e.name, s }));
    } else {
        v.addErrorWithCodeR(exprRange(.{ .ident = e }), Diagnostic.Code.undefined_symbol, v.fmtError("use of undeclared identifier '{s}'", .{e.name}));
    }
    return null;
}

fn checkBinary(v: *Validator, e: *Ast.BinaryExpr) Allocator.Error!?Types.Type {
    const left_type = (try v.checkExpr(e.left)) orelse return null;
    const right_type = (try v.checkExpr(e.right)) orelse return null;

    const er = exprRange(.{ .binary = e }); // operator range
    const op_str = e.op.string();
    switch (e.op) {
        .logical_and, .logical_or => {
            if (!left_type.eql(Types.Bool) or !right_type.eql(Types.Bool)) {
                v.addErrorWithCodeR(exprRange(.{ .binary = e }), Diagnostic.Code.invalid_operand, v.fmtError("operator '{s}' requires 'bool' operands, got '{s}' and '{s}'", .{ op_str, left_type.string(), right_type.string() }));
                return null;
            }
            return Types.Bool;
        },
        .eq, .ne => {
            if (!left_type.eql(right_type) and
                !Types.canConvertTo(left_type, right_type) and
                !Types.canConvertTo(right_type, left_type))
            {
                v.addErrorWithCodeR(er, Diagnostic.Code.invalid_operand, v.fmtError("operator '{s}' requires compatible types, got '{s}' and '{s}'", .{ op_str, left_type.string(), right_type.string() }));
                return null;
            }
            // Vector comparisons return vec<N, bool>
            if (left_type == .vector) {
                const bvec = v.arena.create(Types.Vector) catch return Types.Bool;
                bvec.* = .{ .width = left_type.vector.width, .element = Types.scalar_bool_ptr };
                return .{ .vector = bvec };
            }
            return Types.Bool;
        },
        .lt, .le, .gt, .ge => {
            if (!Types.isNumeric(left_type) or !Types.isNumeric(right_type)) {
                v.addErrorWithCodeR(er, Diagnostic.Code.invalid_operand, v.fmtError("operator '{s}' requires numeric operands, got '{s}' and '{s}'", .{ op_str, left_type.string(), right_type.string() }));
                return null;
            }
            // Vector comparisons return vec<N, bool>
            if (left_type == .vector) {
                const bvec = v.arena.create(Types.Vector) catch return Types.Bool;
                bvec.* = .{ .width = left_type.vector.width, .element = Types.scalar_bool_ptr };
                return .{ .vector = bvec };
            }
            return Types.Bool;
        },
        .add, .sub => {
            const result = Types.addSubResultType(v.arena, left_type, right_type) catch return null;
            if (result) |r| {
                return r;
            }
            v.addErrorWithCodeR(er, Diagnostic.Code.invalid_operand, v.fmtError("operator '{s}' requires numeric types, got '{s}' and '{s}'", .{ op_str, left_type.string(), right_type.string() }));
            return null;
        },
        .mul => {
            const result = Types.multiplyResultType(v.arena, left_type, right_type) catch return null;
            if (result) |r| {
                return r;
            }
            v.addErrorWithCodeR(er, Diagnostic.Code.invalid_operand, v.fmtError("cannot multiply '{s}' by '{s}'", .{ left_type.string(), right_type.string() }));
            return null;
        },
        .div => {
            const result = Types.divResultType(v.arena, left_type, right_type) catch return null;
            if (result) |r| {
                // Const division by zero
                if (v.tryExtractIntValue(e.right)) |rhs_val| {
                    if (rhs_val == 0) {
                        v.addErrorWithCodeR(exprRange(e.right), Diagnostic.Code.division_by_zero, "division by zero in const-expression");
                    }
                }
                return r;
            }
            v.addErrorWithCodeR(er, Diagnostic.Code.invalid_operand, v.fmtError("cannot divide '{s}' by '{s}'", .{ left_type.string(), right_type.string() }));
            return null;
        },
        .mod => {
            // WGSL % works on both integers and floats (unlike C where fmod is separate).
            if (!Types.isNumeric(left_type) or !Types.isNumeric(right_type)) {
                v.addErrorWithCodeR(er, Diagnostic.Code.invalid_operand, v.fmtError("operator '%' requires numeric operands, got '{s}' and '{s}'", .{ left_type.string(), right_type.string() }));
                return null;
            }
            // Const modulo by zero
            if (v.tryExtractIntValue(e.right)) |rhs_val| {
                if (rhs_val == 0) {
                    v.addErrorWithCodeR(exprRange(e.right), Diagnostic.Code.division_by_zero, "division by zero in const-expression");
                }
            }
            return Types.commonType(left_type, right_type);
        },
        .@"and", .@"or", .xor => {
            if (left_type.eql(Types.Bool) and right_type.eql(Types.Bool)) {
                return Types.Bool;
            }
            if (Types.isInteger(left_type) and Types.isInteger(right_type)) {
                return Types.commonType(left_type, right_type);
            }
            v.addErrorWithCodeR(er, Diagnostic.Code.invalid_operand, v.fmtError("operator '{s}' requires integer or bool, got '{s}' and '{s}'", .{ op_str, left_type.string(), right_type.string() }));
            return null;
        },
        .shl, .shr => {
            if (!Types.isInteger(left_type)) {
                v.addErrorWithCodeR(er, Diagnostic.Code.invalid_operand, v.fmtError("operator '{s}' requires integer left operand, got '{s}'", .{ op_str, left_type.string() }));
                return null;
            }
            if (!right_type.eql(Types.U32) and !Types.canConvertTo(right_type, Types.U32)) {
                v.addErrorWithCodeR(er, Diagnostic.Code.invalid_operand, v.fmtError("shift amount must be 'u32', got '{s}'", .{right_type.string()}));
                return null;
            }
            // Shift amount must be less than the bit width of the LHS type (WGSL spec section 8.7).
            // AbstractInt LHS has no in-source bit width (`Scalar.size()` is 0);
            // per spec it concretizes to i32/u32 so a 32-bit cap is the right
            // shader-creation-time ceiling. Preserves spec-literal behavior
            // for concrete `i32`/`u32` LHS (also 32-bit).
            if (v.tryExtractIntValue(e.right)) |shift_val| {
                const bit_width: i64 = blk: {
                    if (left_type != .scalar) break :blk 32;
                    const sz = left_type.scalar.size();
                    break :blk if (sz == 0) 32 else @as(i64, sz) * 8;
                };
                if (shift_val < 0 or shift_val >= bit_width) {
                    v.addErrorWithCodeR(exprRange(e.right), Diagnostic.Code.invalid_operand, v.fmtError("shift amount {d} exceeds bit width of {d}", .{ shift_val, bit_width }));
                }
            }
            return left_type;
        },
    }
}

/// Syntactic approximation of whether an expression can denote a reference
/// — i.e. something addressable by `&`. The check is conservative: it
/// permits ident / member / index / paren-wrapped forms (which may reach a
/// variable) and `*p` (deref of a pointer yields a reference), and rejects
/// shapes that definitionally produce values (literals, calls, other unary
/// forms, binary ops).
fn addrOfOperandLooksAddressable(operand: Ast.Expr) bool {
    return switch (operand) {
        .ident, .member, .index => true,
        .paren => |p| addrOfOperandLooksAddressable(p.expr),
        .unary => |u| u.op == .deref and addrOfOperandLooksAddressable(u.operand),
        .literal, .call, .binary => false,
    };
}

fn checkUnary(v: *Validator, e: *Ast.UnaryExpr) Allocator.Error!?Types.Type {
    const operand_type = (try v.checkExpr(e.operand)) orelse return null;
    const er = exprRange(.{ .unary = e });

    switch (e.op) {
        .neg => {
            if (!Types.isNumeric(operand_type)) {
                v.addErrorWithCodeR(er, Diagnostic.Code.invalid_operand, v.fmtError("unary '-' requires numeric type, got '{s}'", .{operand_type.string()}));
                return null;
            }
            return operand_type;
        },
        .not => {
            if (!operand_type.eql(Types.Bool)) {
                // Also allow vector<bool>
                if (operand_type == .vector and operand_type.vector.element.kind == .bool) {
                    return operand_type;
                }
                v.addErrorWithCodeR(er, Diagnostic.Code.invalid_operand, v.fmtError("unary '!' requires 'bool', got '{s}'", .{operand_type.string()}));
                return null;
            }
            return Types.Bool;
        },
        .bit_not => {
            if (!Types.isInteger(operand_type)) {
                v.addErrorWithCodeR(er, Diagnostic.Code.invalid_operand, v.fmtError("unary '~' requires integer type, got '{s}'", .{operand_type.string()}));
                return null;
            }
            return operand_type;
        },
        .deref => {
            switch (operand_type) {
                .pointer => |p| return p.element,
                .reference => |r| return r.element,
                else => {
                    v.addErrorWithCodeR(er, Diagnostic.Code.deref_requires_pointer, v.fmtError("unary '*' requires a pointer, got '{s}'", .{operand_type.string()}));
                    return null;
                },
            }
        },
        .addr => {
            // The operand of `&` must denote a reference (a memory view) —
            // in practice, something you could read or write. Pure values like
            // literals and computed expression results have no address. We do
            // not yet flow reference types through the expression checker, so
            // use a syntactic approximation: reject any operand whose shape
            // cannot possibly carry a reference.
            if (!addrOfOperandLooksAddressable(e.operand)) {
                v.addErrorWithCodeR(
                    er,
                    Diagnostic.Code.addr_of_requires_reference,
                    "unary '&' requires a reference (e.g. a variable or member access); the operand has no address",
                );
                return null;
            }
            const p = v.arena.create(Types.Pointer) catch return null;
            p.* = .{
                .address_space = .function,
                .element = operand_type,
                .access_mode = .read_write,
            };
            return .{ .pointer = p };
        },
    }
}

fn checkCallExpr(v: *Validator, e: *Ast.CallExpr) Allocator.Error!?Types.Type {
    // Get callee name
    var callee_name: []const u8 = "";
    if (e.func) |func| {
        switch (func) {
            .ident => |ident| {
                callee_name = ident.name;
            },
            .member => {
                // Method call — simplified, treat as unknown
                callee_name = "";
            },
            else => {
                v.addErrorWithCodeR(exprRange(.{ .call = e }), Diagnostic.Code.not_callable, "expression is not callable");
                return null;
            },
        }
    }

    // bitcast<T>(expr): validate conversion constraints before the generic template path.
    if (std.mem.eql(u8, callee_name, "bitcast")) {
        if (e.template_type) |tt| {
            const dest_type = v.resolveType(tt) orelse return null;
            const range = exprRange(.{ .call = e });

            if (e.args.items.len != 1) {
                v.addErrorWithCodeR(range, Diagnostic.Code.invalid_arg_count, v.fmtError("'bitcast' requires exactly 1 argument, got {d}", .{e.args.items.len}));
                return null;
            }

            // Evaluate the source argument
            const src_type = (try v.checkExpr(e.args.items[0])) orelse return dest_type;

            // Spec: bitcast operands must be numeric scalar or vector (no bool, no pointer, no struct).
            const src_size = bitcastSize(src_type);
            const dst_size = bitcastSize(dest_type);
            if (src_size == 0) {
                v.addErrorWithCodeR(range, Diagnostic.Code.invalid_conversion, v.fmtError("cannot bitcast from '{s}'; must be a numeric scalar or vector of numeric scalars", .{src_type.string()}));
                return dest_type;
            }
            if (dst_size == 0) {
                v.addErrorWithCodeR(range, Diagnostic.Code.invalid_conversion, v.fmtError("cannot bitcast to '{s}'; must be a numeric scalar or vector of numeric scalars", .{dest_type.string()}));
                return dest_type;
            }
            // Spec: source and destination must have the same bit-width.
            if (src_size != dst_size) {
                v.addErrorWithCodeR(range, Diagnostic.Code.invalid_conversion, v.fmtError("bitcast source type '{s}' ({d} bits) and destination type '{s}' ({d} bits) must have the same bit-width", .{ src_type.string(), src_size, dest_type.string(), dst_size }));
            }
            return dest_type;
        }
    }

    // Template type constructor (e.g. array<vec3f, 7>(...), vec3<f32>(...))
    if (e.template_type) |tt| {
        const resolved = v.resolveType(tt) orelse return null;
        // Use type string as callee_name when the parser doesn't set func
        const name = if (callee_name.len > 0) callee_name else resolved.string();
        // Validate constructor arguments against the resolved type
        var constructor_arg_types: std.ArrayListUnmanaged(?Types.Type) = .empty;
        for (e.args.items) |arg| {
            try constructor_arg_types.append(v.arena, try v.checkExpr(arg));
        }
        return v.checkTypeConstructor(e, name, resolved, constructor_arg_types.items);
    }

    // Check if it's a builtin function
    if (Builtins.lookup(callee_name)) |builtin_fn| {
        return v.checkBuiltinCall(e, callee_name, builtin_fn);
    }

    // For non-builtin calls, validate all argument expressions and collect types
    var constructor_arg_types: std.ArrayListUnmanaged(?Types.Type) = .empty;
    for (e.args.items) |arg| {
        try constructor_arg_types.append(v.arena, try v.checkExpr(arg));
    }

    // Check if it's a type constructor
    if (v.lookupType(callee_name)) |t| {
        // Bare vec/mat constructors (`vec2`, `mat3x3`, …) infer their
        // element type from the argument list per WGSL §14.462 rather than
        // defaulting to f32. parseVectorShorthand / parseMatrixShorthand
        // return a f32-default type; swap its element with the arg-unified
        // scalar before validation so `let x = vec2(1, 2)` is vec2<i32>
        // (or vec2<abstract-int> in contexts that retain abstractness).
        const effective_t = v.inferGenericCtorElement(callee_name, t, constructor_arg_types.items) orelse t;
        return v.checkTypeConstructor(e, callee_name, effective_t, constructor_arg_types.items);
    }

    // Check if it's a user-defined function
    if (e.func) |func| {
        switch (func) {
            .ident => |ident| return v.checkUserFunctionCall(e, ident, callee_name),
            else => {},
        }
    }

    // Unresolved call — if we have a name and it's not a builtin, error
    if (callee_name.len > 0) {
        v.reportNotCallable(e, callee_name);
    }
    return null;
}

fn checkBuiltinCall(v: *Validator, e: *Ast.CallExpr, callee_name: []const u8, builtin_fn: Builtins.Builtin) Allocator.Error!?Types.Type {
    // Check argument count
    const arg_count: u32 = @intCast(e.args.items.len);
    if (!builtin_fn.checkArgCount(arg_count)) {
        v.addErrorWithCodeR(exprRange(.{ .call = e }), Diagnostic.Code.invalid_arg_count, v.fmtError("'{s}' expects {d} to {d} arguments, got {d}", .{ callee_name, builtin_fn.min_args, builtin_fn.max_args, arg_count }));
        return null;
    }

    // Collect argument types (single pass — no double evaluation)
    var arg_types: [8]?Types.Type = .{null} ** 8;
    const max_check = @min(e.args.items.len, 8);
    for (0..max_check) |i| {
        arg_types[i] = try v.checkExpr(e.args.items[i]);
    }

    // Type check arguments based on builtin kind
    switch (builtin_fn.kind) {
        .numeric, .derivative => {
            for (0..max_check) |i| {
                if (arg_types[i]) |at| {
                    if (!Types.isNumeric(at) and !Types.isFloat(at) and !Types.isMatrix(at)) {
                        v.addErrorWithCodeR(exprRange(.{ .call = e }), Diagnostic.Code.invalid_arg_type, v.fmtError("'{s}' requires numeric argument, got '{s}'", .{ callee_name, at.string() }));
                        return null;
                    }
                }
            }
        },
        .logical => {
            // all/any require bool args; select has (T, T, bool) signature
            if (!std.mem.eql(u8, callee_name, "select")) {
                if (arg_types[0]) |at| {
                    if (!at.eql(Types.Bool) and !Types.isVector(at)) {
                        v.addErrorWithCodeR(exprRange(.{ .call = e }), Diagnostic.Code.invalid_arg_type, v.fmtError("'{s}' requires 'bool' argument, got '{s}'", .{ callee_name, at.string() }));
                        return null;
                    }
                }
            }
        },
        else => {},
    }

    return v.inferBuiltinReturnType(builtin_fn, callee_name, arg_types);
}

fn checkUserFunctionCall(v: *Validator, e: *Ast.CallExpr, ident: *Ast.IdentExpr, callee_name: []const u8) Allocator.Error!?Types.Type {
    if (ident.ref.isValid()) {
        const idx = ident.ref.index();

        // Entry points must not be called as functions (WGSL spec 8.6)
        if (idx < v.module.symbols.items.len and v.module.symbols.items[idx].flags.is_entry_point) {
            v.addErrorWithCodeR(exprRange(.{ .call = e }), Diagnostic.Code.entry_point_called, v.fmtError("entry point '{s}' cannot be the target of a function call", .{callee_name}));
            return null;
        }

        if (v.symbol_types.get(idx)) |sym_type| {
            switch (sym_type) {
                .function => |fn_type| {
                    const call_range = exprRange(.{ .call = e });
                    const fn_related = v.makeRelatedR(v.symbolRange(ident.ref), v.fmtError("'{s}' declared here", .{callee_name}));
                    // Check argument count
                    if (e.args.items.len != fn_type.parameters.len) {
                        v.addErrorWithRelatedR(call_range, Diagnostic.Code.invalid_arg_count, v.fmtError("'{s}' expects {d} arguments, got {d}", .{ callee_name, fn_type.parameters.len, e.args.items.len }), fn_related);
                        return null;
                    }
                    // Check argument types
                    for (e.args.items, 0..) |arg, ai| {
                        if (ai < fn_type.parameters.len) {
                            const arg_type = try v.checkExpr(arg);
                            if (arg_type) |at| {
                                const param_type = fn_type.parameters[ai];
                                if (!at.eql(param_type) and !Types.canConvertTo(at, param_type)) {
                                    v.addErrorWithRelatedR(call_range, Diagnostic.Code.invalid_arg_type, v.fmtError("argument {d} of '{s}' has type '{s}', expected '{s}'", .{ ai + 1, callee_name, at.string(), param_type.string() }), fn_related);
                                    return null;
                                }
                            }
                        }
                    }
                    return fn_type.return_type;
                },
                else => {
                    // Symbol exists but is not a function
                    v.reportNotCallable(e, callee_name);
                    return null;
                },
            }
        }
        // Symbol exists but no type — check if it's a function symbol
        if (idx < v.module.symbols.items.len and
            v.module.symbols.items[idx].kind == .function)
        {
            // User function — check argument count against parameters
            return null; // Can't fully type-check without function type
        }
    }

    // Not resolvable — report error
    if (callee_name.len > 0 and !Builtins.isBuiltin(callee_name)) {
        v.reportNotCallable(e, callee_name);
        return null;
    }
    return null;
}

/// Unifies the argument types of a builtin whose return pattern is
/// `same_as_arg`. When args carry mixed abstract/concrete shapes (e.g.
/// `min(5, 0u)` or `clamp(0, 1f, 1)`) we must return the concrete type
/// that all args automatically convert to, not blindly `arg_types[0]`.
/// Walks args left-to-right folding through `Types.commonType`, which
/// already honors the abstract→concrete feasibility table. Stops on the
/// first incompatible arg (e.g. the bool predicate of `select`) and
/// returns the type unified so far — which matches the WGSL spec's
/// overload-resolution outcome for the first-two-numeric-args family.
fn sameAsArgResult(arg_types: [8]?Types.Type) ?Types.Type {
    var unified = arg_types[0] orelse return null;
    var i: usize = 1;
    while (i < arg_types.len) : (i += 1) {
        const next = arg_types[i] orelse break;
        const common = Types.commonType(unified, next) orelse break;
        unified = common;
    }
    return unified;
}

/// Bare `vec2`/`vec3`/`vec4` and `matCxR` accept any scalar element type
/// that's common to the arguments. `lookupType` hands back an f32 default
/// so other call paths stay simple; here we replace the element with the
/// unified scalar across the args (AbstractInt/AbstractFloat propagate
/// unless a concrete arg is present). Returns null when the name is not
/// a bare numeric constructor or when we fail to pick an element.
fn inferGenericCtorElement(v: *Validator, name: []const u8, default: Types.Type, arg_types: []const ?Types.Type) ?Types.Type {
    const is_bare_vec = std.mem.eql(u8, name, "vec2") or
        std.mem.eql(u8, name, "vec3") or
        std.mem.eql(u8, name, "vec4");
    const is_bare_mat = name.len == 6 and
        std.mem.startsWith(u8, name, "mat") and
        name[4] == 'x';
    if (!is_bare_vec and !is_bare_mat) return null;

    var elem: ?*const Types.Scalar = null;
    for (arg_types) |at_opt| {
        const at = at_opt orelse continue;
        const scalar_ptr: *const Types.Scalar = switch (at) {
            .scalar => |s| s,
            .vector => |vv| vv.element,
            .matrix => |mm| mm.element,
            else => continue,
        };
        elem = unifyScalarKinds(elem, scalar_ptr);
    }

    const chosen = elem orelse return null;
    if (is_bare_vec) {
        const result = v.arena.create(Types.Vector) catch return null;
        result.* = .{ .width = default.vector.width, .element = chosen };
        return .{ .vector = result };
    }
    // Matrices carry a float element only; fall back to default if an
    // integer sneaks in — checkTypeConstructor reports the real error.
    if (!chosen.isFloat()) return null;
    const result = v.arena.create(Types.Matrix) catch return null;
    result.* = .{ .cols = default.matrix.cols, .rows = default.matrix.rows, .element = chosen };
    return .{ .matrix = result };
}

fn unifyScalarKinds(a: ?*const Types.Scalar, b: *const Types.Scalar) ?*const Types.Scalar {
    const prev = a orelse return b;
    if (prev.kind == b.kind) return prev;
    // Abstract operands yield to concrete of a compatible family.
    if (prev.kind == .abstract_int and b.kind != .bool) return b;
    if (b.kind == .abstract_int and prev.kind != .bool) return prev;
    if (prev.kind == .abstract_float and b.isFloat()) return b;
    if (b.kind == .abstract_float and prev.isFloat()) return prev;
    // Incompatible concrete kinds — keep prev; validation will report it.
    return prev;
}

fn reportNotCallable(v: *Validator, e: *Ast.CallExpr, callee_name: []const u8) void {
    if (v.suggestCallable(callee_name, e.args.items.len)) |s| {
        v.addErrorWithCodeR(exprRange(.{ .call = e }), Diagnostic.Code.not_callable, v.fmtError("'{s}' is not a function or type constructor; did you mean '{s}'?", .{ callee_name, s }));
    } else {
        v.addErrorWithCodeR(exprRange(.{ .call = e }), Diagnostic.Code.not_callable, v.fmtError("'{s}' is not a function or type constructor", .{callee_name}));
    }
}

fn inferBuiltinReturnType(v: *Validator, builtin: Builtins.Builtin, name: []const u8, arg_types: [8]?Types.Type) ?Types.Type {
    return switch (builtin.return_pattern) {
        .same_as_arg => sameAsArgResult(arg_types),
        .bool_scalar => Types.Bool,
        .scalar_of_arg => if (arg_types[0]) |at| Types.scalarOf(at) else null,
        .void_type => Types.Void,
        .pack_u32 => Types.U32,
        .u32_scalar => Types.U32,
        .texture => v.inferTextureReturnType(name, arg_types),
        .texture_dims => v.inferTextureDimsType(arg_types),
        .custom => v.inferCustomBuiltin(name, arg_types),
    };
}

fn inferTextureReturnType(v: *Validator, name: []const u8, arg_types: [8]?Types.Type) ?Types.Type {
    // Comparison sampling always returns f32
    if (std.mem.eql(u8, name, "textureSampleCompare") or
        std.mem.eql(u8, name, "textureSampleCompareLevel"))
    {
        return Types.F32;
    }

    const tex_type = arg_types[0] orelse return .{ .vector = &vec4_f32_singleton };

    switch (tex_type) {
        .texture => |t| {
            // Depth textures
            if (t.kind == .depth or t.kind == .depth_multisampled) {
                // textureGather/GatherCompare on depth return vec4<f32>
                if (std.mem.eql(u8, name, "textureGather") or
                    std.mem.eql(u8, name, "textureGatherCompare"))
                {
                    return .{ .vector = &vec4_f32_singleton };
                }
                // textureLoad, textureSample on depth return f32
                return Types.F32;
            }

            // Get element scalar from sampled_type or texel_format
            var elem_scalar: *const Types.Scalar = Types.scalar_f32_ptr;
            if (t.sampled_type) |st| {
                elem_scalar = st;
            } else if (t.texel_format.len > 0) {
                elem_scalar = Types.texelFormatToScalar(t.texel_format);
            }

            // Return vec4<element>
            if (elem_scalar == Types.scalar_f32_ptr) {
                return .{ .vector = &vec4_f32_singleton };
            }
            const result = v.arena.create(Types.Vector) catch return null;
            result.* = .{ .width = 4, .element = elem_scalar };
            return .{ .vector = result };
        },
        else => return .{ .vector = &vec4_f32_singleton },
    }
}

fn inferTextureDimsType(v: *Validator, arg_types: [8]?Types.Type) ?Types.Type {
    const tex_type = arg_types[0] orelse return Types.U32;

    if (tex_type != .texture) return Types.U32;
    const t = tex_type.texture;

    const width: u8 = switch (t.dimension) {
        .@"1d" => 1,
        .@"2d", .@"2d_array", .cube, .cube_array => 2,
        .@"3d" => 3,
    };

    if (width == 1) return Types.U32;

    const result = v.arena.create(Types.Vector) catch return null;
    result.* = .{ .width = width, .element = Types.scalar_u32_ptr };
    return .{ .vector = result };
}

fn inferCustomBuiltin(v: *Validator, name: []const u8, arg_types: [8]?Types.Type) ?Types.Type {
    // transpose: swap cols/rows
    if (std.mem.eql(u8, name, "transpose")) {
        if (arg_types[0]) |at| {
            if (at == .matrix) {
                const m = at.matrix;
                const result = v.arena.create(Types.Matrix) catch return null;
                result.* = .{ .cols = m.rows, .rows = m.cols, .element = m.element };
                return .{ .matrix = result };
            }
        }
        return null;
    }

    // workgroupUniformLoad: returns element type of pointer arg
    if (std.mem.eql(u8, name, "workgroupUniformLoad")) {
        if (arg_types[0]) |at| {
            if (at == .pointer) return at.pointer.element;
        }
        return null;
    }

    // subgroupBallot: returns vec4<u32>
    if (std.mem.eql(u8, name, "subgroupBallot")) {
        return .{ .vector = &vec4_u32_singleton };
    }

    // atomicCompareExchangeWeak returns __atomic_compare_exchange_result<T>
    // per spec §17.9.7 where T is the underlying atomic scalar. Field
    // layout: { old_value: T, exchanged: bool }.
    if (std.mem.eql(u8, name, "atomicCompareExchangeWeak")) {
        const at = arg_types[0] orelse return null;
        if (at != .pointer) return null;
        if (at.pointer.element != .atomic) return null;
        const elem = at.pointer.element.atomic.element;
        return v.synthesizeAtomicExchangeResult(elem) catch null;
    }

    // frexp(e) returns __frexp_result_* per spec §17.5.33 where the
    // struct carries {fract: T, exp: i32-or-vecN<i32>} depending on
    // whether the operand is a scalar float or vector of floats.
    if (std.mem.eql(u8, name, "frexp")) {
        if (arg_types[0]) |at| return v.synthesizeFrexpResult(at) catch null;
        return null;
    }

    // modf(e) returns __modf_result_* per spec §17.5.49 with fields
    // {fract: T, whole: T}.
    if (std.mem.eql(u8, name, "modf")) {
        if (arg_types[0]) |at| return v.synthesizeModfResult(at) catch null;
        return null;
    }

    // Atomic ops: extract element type from atomic pointer
    if (std.mem.startsWith(u8, name, "atomic")) {
        if (arg_types[0]) |at| {
            if (at == .pointer) {
                if (at.pointer.element == .atomic) {
                    return .{ .scalar = at.pointer.element.atomic.element };
                }
            }
        }
        return Types.U32; // fallback
    }

    // Unpack functions
    if (std.mem.startsWith(u8, name, "unpack")) {
        if (std.mem.eql(u8, name, "unpack4xI8")) return .{ .vector = &vec4_i32_singleton };
        if (std.mem.eql(u8, name, "unpack4xU8")) return .{ .vector = &vec4_u32_singleton };
        if (std.mem.startsWith(u8, name, "unpack2x16")) return .{ .vector = &vec2_f32_singleton };
        // unpack4x8snorm, unpack4x8unorm → vec4<f32>
        return .{ .vector = &vec4_f32_singleton };
    }

    // bitcast: return type from template (handled by template_type check before reaching here)
    return null;
}

// Cache synthesized structs so repeated calls to frexp/modf/
// atomicCompareExchangeWeak with the same operand type return the
// same *Struct pointer (lets downstream member-access / eq work).
fn getOrSynthStruct(v: *Validator, name: []const u8, build: *const fn (*Validator, []const u8) Allocator.Error!*Types.Struct) Allocator.Error!*Types.Struct {
    if (v.struct_types.get(name)) |st| return st;
    const st = try build(v, name);
    try v.struct_types.put(v.arena, st.name, st);
    return st;
}

fn synthesizeAtomicExchangeResult(v: *Validator, elem: *const Types.Scalar) Allocator.Error!Types.Type {
    const name = try std.fmt.allocPrint(v.arena, "__atomic_compare_exchange_result_{s}", .{elem.string()});
    if (v.struct_types.get(name)) |st| return .{ .@"struct" = st };

    const fields = try v.arena.alloc(Types.StructField, 2);
    fields[0] = .{ .name = "old_value", .typ = .{ .scalar = elem }, .offset = 0 };
    fields[1] = .{ .name = "exchanged", .typ = Types.Bool, .offset = 0 };
    const st = try v.arena.create(Types.Struct);
    st.* = .{ .name = name, .fields = fields, .size_bytes = 0, .align_bytes = 0, .has_runtime_array = false };
    st.computeLayout();
    try v.struct_types.put(v.arena, name, st);
    return .{ .@"struct" = st };
}

fn frexpExpType(v: *Validator, operand: Types.Type) Allocator.Error!Types.Type {
    switch (operand) {
        .scalar => return Types.I32,
        .vector => |vv| {
            const result = try v.arena.create(Types.Vector);
            result.* = .{ .width = vv.width, .element = Types.scalar_i32_ptr };
            return .{ .vector = result };
        },
        else => return Types.I32,
    }
}

fn synthesizeFrexpResult(v: *Validator, operand: Types.Type) Allocator.Error!?Types.Type {
    if (!Types.isFloat(operand)) return null;
    const name = try std.fmt.allocPrint(v.arena, "__frexp_result_{s}", .{operand.string()});
    if (v.struct_types.get(name)) |st| return .{ .@"struct" = st };

    const fields = try v.arena.alloc(Types.StructField, 2);
    fields[0] = .{ .name = "fract", .typ = operand, .offset = 0 };
    fields[1] = .{ .name = "exp", .typ = try v.frexpExpType(operand), .offset = 0 };
    const st = try v.arena.create(Types.Struct);
    st.* = .{ .name = name, .fields = fields, .size_bytes = 0, .align_bytes = 0, .has_runtime_array = false };
    st.computeLayout();
    try v.struct_types.put(v.arena, name, st);
    return .{ .@"struct" = st };
}

fn synthesizeModfResult(v: *Validator, operand: Types.Type) Allocator.Error!?Types.Type {
    if (!Types.isFloat(operand)) return null;
    const name = try std.fmt.allocPrint(v.arena, "__modf_result_{s}", .{operand.string()});
    if (v.struct_types.get(name)) |st| return .{ .@"struct" = st };

    const fields = try v.arena.alloc(Types.StructField, 2);
    fields[0] = .{ .name = "fract", .typ = operand, .offset = 0 };
    fields[1] = .{ .name = "whole", .typ = operand, .offset = 0 };
    const st = try v.arena.create(Types.Struct);
    st.* = .{ .name = name, .fields = fields, .size_bytes = 0, .align_bytes = 0, .has_runtime_array = false };
    st.computeLayout();
    try v.struct_types.put(v.arena, name, st);
    return .{ .@"struct" = st };
}

// Singleton vectors for common return types
const vec4_f32_singleton = Types.Vector{ .width = 4, .element = Types.scalar_f32_ptr };
const vec4_u32_singleton = Types.Vector{ .width = 4, .element = Types.scalar_u32_ptr };
const vec4_i32_singleton = Types.Vector{ .width = 4, .element = Types.scalar_i32_ptr };
const vec2_f32_singleton = Types.Vector{ .width = 2, .element = Types.scalar_f32_ptr };

fn checkTypeConstructor(v: *Validator, e: *Ast.CallExpr, callee_name: []const u8, t: Types.Type, arg_types: []const ?Types.Type) ?Types.Type {
    const arg_count = e.args.items.len;
    const range = exprRange(.{ .call = e });

    // Spec: only constructible types can be used as value constructors.
    // Vectors/matrices with an abstract element type are transient results
    // of bare `vec2(...)` / `matCxR(...)` element inference — they will be
    // concretized at the enclosing use site, so we permit them here even
    // though `isConstructible` rejects abstract-typed containers.
    const is_transient_abstract = switch (t) {
        .vector => |vv| !vv.element.isConcrete(),
        .matrix => |mm| !mm.element.isConcrete(),
        else => false,
    };
    if (!t.isConstructible() and !is_transient_abstract and !std.mem.eql(u8, callee_name, "bitcast")) {
        v.addErrorWithCodeR(range, Diagnostic.Code.type_mismatch, v.fmtError("type '{s}' is not constructible", .{t.string()}));
        return null;
    }

    switch (t) {
        .scalar => {
            if (arg_count > 1) {
                v.addErrorWithCodeR(range, Diagnostic.Code.invalid_arg_count, v.fmtError("'{s}' constructor takes at most 1 argument, got {d}", .{ callee_name, arg_count }));
                return null;
            }
            // Scalar value constructors are explicit conversions — any scalar
            // to any scalar is valid (e.g. f32(i32_value), i32(0.9)).
            if (arg_count == 1 and arg_types.len > 0) {
                if (arg_types[0]) |at| {
                    if (at != .scalar) {
                        v.addErrorWithCodeR(range, Diagnostic.Code.invalid_conversion, v.fmtError("cannot convert '{s}' to '{s}'", .{ at.string(), t.string() }));
                        return null;
                    }
                    // W0101: argument's concrete scalar type already matches
                    // the constructor target — the cast is a no-op.
                    if (at.scalar.kind == t.scalar.kind and t.scalar.isConcrete()) {
                        v.addWarningWithCodeR(range, Diagnostic.Code.redundant_cast, v.fmtError("redundant cast: '{s}' is already '{s}'", .{ at.string(), t.string() }));
                    }
                }
            }
        },
        .vector => |ve| {
            const width: usize = ve.width;

            // 0 args: zero-value constructor
            if (arg_count == 0) return t;

            // 1 arg: splat (scalar) or copy/convert (matching-width vector)
            if (arg_count == 1) {
                if (arg_types.len > 0) {
                    if (arg_types[0]) |at| {
                        if (at == .scalar) {
                            if (!canConvertScalarTo(at.scalar, ve.element)) {
                                v.addErrorWithCodeR(range, Diagnostic.Code.invalid_conversion, v.fmtError("cannot convert '{s}' to '{s}' in '{s}' constructor", .{ at.string(), ve.element.string(), callee_name }));
                                return null;
                            }
                            return t; // splat
                        }
                        if (at == .vector) {
                            const src_width: usize = at.vector.width;
                            if (src_width != width) {
                                if (v.suggestVecForComponents(callee_name, src_width)) |suggestion| {
                                    v.addErrorWithCodeR(range, Diagnostic.Code.invalid_arg_count, v.fmtError("'{s}' requires {d} components, got {d}; did you mean '{s}'?", .{ callee_name, width, src_width, suggestion }));
                                } else {
                                    v.addErrorWithCodeR(range, Diagnostic.Code.invalid_arg_count, v.fmtError("'{s}' requires {d} components, got {d}", .{ callee_name, width, src_width }));
                                }
                                return null;
                            }
                            // Same width — check element type conversion
                            if (!canConvertScalarTo(at.vector.element, ve.element)) {
                                v.addErrorWithCodeR(range, Diagnostic.Code.invalid_conversion, v.fmtError("cannot convert '{s}' to '{s}'", .{ at.string(), t.string() }));
                                return null;
                            }
                            return t;
                        }
                    }
                }
                return t; // unknown arg type, skip validation
            }

            // Multiple args: count total components (scalars + vector widths)
            var total: usize = 0;
            for (arg_types) |at_opt| {
                const at = at_opt orelse return t; // unknown type, skip
                if (at == .scalar) {
                    total += 1;
                } else if (at == .vector) {
                    total += at.vector.width;
                } else {
                    return t; // non-scalar/vector arg, skip validation
                }
            }

            if (total != width) {
                if (v.suggestVecForComponents(callee_name, total)) |suggestion| {
                    v.addErrorWithCodeR(range, Diagnostic.Code.invalid_arg_count, v.fmtError("'{s}' requires {d} components, got {d}; did you mean '{s}'?", .{ callee_name, width, total, suggestion }));
                } else {
                    v.addErrorWithCodeR(range, Diagnostic.Code.invalid_arg_count, v.fmtError("'{s}' requires {d} components, got {d}", .{ callee_name, width, total }));
                }
                return null;
            }

            // Check element type compatibility for each argument
            for (arg_types) |at_opt| {
                const at = at_opt orelse continue;
                const src_elem = elementTypeOf(at) orelse continue;
                if (!canConvertScalarTo(src_elem, ve.element)) {
                    v.addErrorWithCodeR(range, Diagnostic.Code.invalid_conversion, v.fmtError("cannot convert '{s}' to '{s}' in '{s}' constructor", .{ src_elem.string(), ve.element.string(), callee_name }));
                    return null;
                }
            }
        },
        .matrix => |mt| {
            const cols: usize = mt.cols;
            const rows: usize = mt.rows;

            // 0 args: zero-value constructor
            if (arg_count == 0) return t;

            // 1 arg: copy/convert (matching-dimension matrix)
            if (arg_count == 1) {
                if (arg_types.len > 0) {
                    if (arg_types[0]) |at| {
                        if (at == .matrix) {
                            if (at.matrix.cols != mt.cols or at.matrix.rows != mt.rows) {
                                v.addErrorWithCodeR(range, Diagnostic.Code.invalid_conversion, v.fmtError("cannot convert '{s}' to '{s}'", .{ at.string(), t.string() }));
                                return null;
                            }
                            if (!canConvertScalarTo(at.matrix.element, mt.element)) {
                                v.addErrorWithCodeR(range, Diagnostic.Code.invalid_conversion, v.fmtError("cannot convert '{s}' to '{s}'", .{ at.string(), t.string() }));
                                return null;
                            }
                        }
                    }
                }
                return t;
            }

            // Classify args: all scalars or all vectors
            var all_scalar = true;
            var all_vector = true;
            for (arg_types) |at_opt| {
                const at = at_opt orelse return t; // unknown type, skip
                if (at != .scalar) all_scalar = false;
                if (at != .vector) all_vector = false;
            }

            if (all_scalar) {
                // C*R scalars required
                if (arg_count != cols * rows) {
                    v.addErrorWithCodeR(range, Diagnostic.Code.invalid_arg_count, v.fmtError("'{s}' scalar constructor requires {d} values, got {d}", .{ callee_name, cols * rows, arg_count }));
                    return null;
                }
                // Check scalar element type compatibility
                for (arg_types) |at_opt| {
                    const at = at_opt orelse continue;
                    if (at == .scalar and !canConvertScalarTo(at.scalar, mt.element)) {
                        v.addErrorWithCodeR(range, Diagnostic.Code.invalid_conversion, v.fmtError("cannot convert '{s}' to '{s}' in '{s}' constructor", .{ at.scalar.string(), mt.element.string(), callee_name }));
                        return null;
                    }
                }
            } else if (all_vector) {
                // C column vectors of height R required
                if (arg_count != cols) {
                    v.addErrorWithCodeR(range, Diagnostic.Code.invalid_arg_count, v.fmtError("'{s}' column constructor requires {d} vectors, got {d}", .{ callee_name, cols, arg_count }));
                    return null;
                }
                // Check each column vector has height == rows and compatible element type
                for (arg_types) |at_opt| {
                    if (at_opt) |at| {
                        if (at == .vector) {
                            if (at.vector.width != rows) {
                                v.addErrorWithCodeR(range, Diagnostic.Code.invalid_arg_type, v.fmtError("'{s}' column vectors must have {d} components, got {d}", .{ callee_name, rows, at.vector.width }));
                                return null;
                            }
                            if (!canConvertScalarTo(at.vector.element, mt.element)) {
                                v.addErrorWithCodeR(range, Diagnostic.Code.invalid_conversion, v.fmtError("cannot convert '{s}' to '{s}' in '{s}' constructor", .{ at.vector.element.string(), mt.element.string(), callee_name }));
                                return null;
                            }
                        }
                    }
                }
            } else {
                v.addErrorWithCodeR(range, Diagnostic.Code.invalid_arg_type, v.fmtError("'{s}' constructor requires all scalar values or all column vectors, not a mix", .{callee_name}));
                return null;
            }
        },
        .@"struct" => |st| {
            if (arg_count != 0 and arg_count != st.fields.len) {
                v.addErrorWithCodeR(range, Diagnostic.Code.invalid_arg_count, v.fmtError("'{s}' constructor expects {d} arguments, got {d}", .{ callee_name, st.fields.len, arg_count }));
                return null;
            }
            if (arg_count == st.fields.len) {
                for (st.fields, 0..) |field, i| {
                    if (i < arg_types.len) {
                        if (arg_types[i]) |at| {
                            if (!at.eql(field.typ) and !Types.canConvertTo(at, field.typ)) {
                                v.addErrorWithCodeR(range, Diagnostic.Code.invalid_conversion, v.fmtError("cannot convert '{s}' to '{s}' for field '{s}'", .{ at.string(), field.typ.string(), field.name }));
                                return null;
                            }
                        }
                    }
                }
            }
        },
        .array => |arr| {
            // 0 args: zero-value constructor
            if (arg_count == 0) return t;

            // Check element count if the array has a fixed size
            if (arr.count > 0 and arg_count != arr.count) {
                v.addErrorWithCodeR(range, Diagnostic.Code.invalid_arg_count, v.fmtError("'{s}' constructor expects {d} elements, got {d}", .{ callee_name, arr.count, arg_count }));
                return null;
            }

            // Check each element type
            for (arg_types, 0..) |at_opt, i| {
                if (at_opt) |at| {
                    if (!at.eql(arr.element) and !Types.canConvertTo(at, arr.element)) {
                        v.addErrorWithCodeR(range, Diagnostic.Code.invalid_conversion, v.fmtError("cannot convert '{s}' to '{s}' for element {d}", .{ at.string(), arr.element.string(), i }));
                        return null;
                    }
                }
            }
        },
        else => {},
    }
    return t;
}

fn canConvertScalarTo(src: *const Types.Scalar, dst: *const Types.Scalar) bool {
    if (src == dst) return true;
    return Types.canConvertTo(.{ .scalar = src }, .{ .scalar = dst });
}

fn elementTypeOf(t: Types.Type) ?*const Types.Scalar {
    return switch (t) {
        .scalar => |s| s,
        .vector => |ve| ve.element,
        .matrix => |mt| mt.element,
        else => null,
    };
}

/// Returns the bit-width of a type for bitcast validation, or 0 if not bitcastable.
/// Spec: bitcast operands must be concrete numeric scalar or vector of concrete numeric scalars.
fn bitcastSize(t: Types.Type) u32 {
    switch (t) {
        .scalar => |s| {
            return switch (s.kind) {
                .f32, .i32, .u32 => 32,
                .f16 => 16,
                .bool, .abstract_int, .abstract_float => 0,
            };
        },
        .vector => |ve| {
            const elem_bits: u32 = switch (ve.element.kind) {
                .f32, .i32, .u32 => 32,
                .f16 => 16,
                .bool, .abstract_int, .abstract_float => return 0,
            };
            return elem_bits * ve.width;
        },
        else => return 0,
    }
}

/// Suggest a vector type name matching `total_components` by replacing the
/// width digit in `callee_name` (e.g. "vec2f" + 3 components → "vec3f").
fn suggestVecForComponents(v: *Validator, callee_name: []const u8, total_components: usize) ?[]const u8 {
    if (total_components < 2 or total_components > 4) return null;
    if (callee_name.len < 4 or !std.mem.startsWith(u8, callee_name, "vec")) return null;
    const buf = v.arena.alloc(u8, callee_name.len) catch return null;
    @memcpy(buf, callee_name);
    buf[3] = @as(u8, @intCast('0' + total_components));
    return buf;
}

fn checkIndex(v: *Validator, e: *Ast.IndexExpr) Allocator.Error!?Types.Type {
    const base_type = (try v.checkExpr(e.base)) orelse return null;
    const index_type = try v.checkExpr(e.idx);

    // Check index type
    if (index_type) |it| {
        if (!Types.isInteger(it)) {
            v.addErrorWithCodeR(exprRange(.{ .index = e }), Diagnostic.Code.type_mismatch, v.fmtError("array index must be integer, got '{s}'", .{it.string()}));
        }
    }

    // Out-of-bounds literal index detection
    if (v.tryExtractIntValue(e.idx)) |idx_val| {
        const bound: ?i64 = switch (base_type) {
            .array => |a| if (a.count > 0) @as(i64, @intCast(a.count)) else null,
            .vector => |ve| @as(i64, @intCast(ve.width)),
            .matrix => |m| @as(i64, @intCast(m.cols)),
            else => null,
        };
        if (bound) |b| {
            if (idx_val < 0 or idx_val >= b) {
                v.addErrorWithCodeR(exprRange(e.idx), Diagnostic.Code.index_out_of_bounds, v.fmtError("index {d} is out of bounds for '{s}' with {d} element{s}", .{ idx_val, base_type.string(), b, if (b != 1) "s" else "" }));
            }
        }
    }

    // Get element type
    switch (base_type) {
        .array => |a| return a.element,
        .vector => |ve| return .{ .scalar = ve.element },
        .matrix => |m| {
            // Indexing a matrix gives a column vector
            const col_vec = v.arena.create(Types.Vector) catch return null;
            col_vec.* = .{ .width = m.rows, .element = m.element };
            return .{ .vector = col_vec };
        },
        .pointer => |p| {
            // Indexing through pointer to array
            switch (p.element) {
                .array => |a| return a.element,
                else => {},
            }
        },
        .reference => |r| {
            switch (r.element) {
                .array => |a| return a.element,
                else => {},
            }
        },
        else => {},
    }

    v.addErrorWithCodeR(exprRange(.{ .index = e }), Diagnostic.Code.not_indexable, v.fmtError("type '{s}' is not indexable", .{base_type.string()}));
    return null;
}

fn validateSwizzle(v: *Validator, name: []const u8, vec_width: u8, loc: u32, base_type: Types.Type) bool {
    // Range covers the dot + swizzle name
    const r: LocRange = .{ .start = loc, .end = loc +| 1 +| @as(u32, @intCast(name.len)) };
    const xyzw = "xyzw";
    const rgba = "rgba";
    var has_xyzw = false;
    var has_rgba = false;
    for (name) |c| {
        const xyzw_idx = std.mem.indexOfScalar(u8, xyzw, c);
        const rgba_idx = std.mem.indexOfScalar(u8, rgba, c);
        if (xyzw_idx == null and rgba_idx == null) {
            const msg = if (v.suggestSwizzle(name, vec_width)) |s|
                v.fmtError("invalid swizzle '.{s}' on type '{s}'; valid components are xyzw or rgba; did you mean '.{s}'?", .{ name, base_type.string(), s })
            else
                v.fmtError("invalid swizzle '.{s}' on type '{s}'; valid components are xyzw or rgba", .{ name, base_type.string() });
            v.addErrorWithCodeR(r, Diagnostic.Code.no_such_member, msg);
            return false;
        }
        if (xyzw_idx != null) has_xyzw = true;
        if (rgba_idx != null) has_rgba = true;
        // Check component index vs vector width
        const idx: u8 = @intCast(xyzw_idx orelse rgba_idx.?);
        if (idx >= vec_width) {
            v.addErrorWithCodeR(r, Diagnostic.Code.no_such_member, v.fmtError("swizzle component '{c}' is out of bounds for '{s}'", .{ c, base_type.string() }));
            return false;
        }
    }
    if (has_xyzw and has_rgba) {
        const msg = if (v.suggestSwizzle(name, vec_width)) |s|
            v.fmtError("swizzle '.{s}' mixes xyzw and rgba groups; did you mean '.{s}'?", .{ name, s })
        else
            v.fmtError("swizzle '.{s}' mixes xyzw and rgba groups", .{name});
        v.addErrorWithCodeR(r, Diagnostic.Code.no_such_member, msg);
        return false;
    }
    return true;
}

/// Build a best-guess valid swizzle name. The dominant group (xyzw or rgba)
/// wins ties; invalid / out-of-bounds chars are replaced with the group's
/// first in-bounds component. Returns null when no change is needed, when
/// the name is empty, or when the vector width is zero.
fn suggestSwizzle(v: *Validator, name: []const u8, vec_width: u8) ?[]const u8 {
    if (name.len == 0 or name.len > 4 or vec_width == 0) return null;
    var xyzw_count: u8 = 0;
    var rgba_count: u8 = 0;
    for (name) |c| {
        if (std.mem.indexOfScalar(u8, "xyzw", c)) |_| xyzw_count += 1;
        if (std.mem.indexOfScalar(u8, "rgba", c)) |_| rgba_count += 1;
    }
    const group: []const u8 = if (xyzw_count >= rgba_count) "xyzw" else "rgba";
    const max_w: u8 = @min(vec_width, 4);
    var buf = v.arena.alloc(u8, name.len) catch return null;
    var changed = false;
    for (name, 0..) |c, i| {
        if (std.mem.indexOfScalar(u8, group, c)) |idx| {
            if (idx < max_w) {
                buf[i] = c;
            } else {
                buf[i] = group[max_w - 1];
                changed = true;
            }
        } else {
            buf[i] = group[0];
            changed = true;
        }
    }
    if (!changed) return null;
    return buf;
}

fn checkMember(v: *Validator, e: *Ast.MemberExpr) Allocator.Error!?Types.Type {
    var base_type = (try v.checkExpr(e.base)) orelse return null;
    const mr = exprRange(.{ .member = e }); // dot + member_name

    // Auto-dereference pointers/references
    for (0..32) |_| {
        switch (base_type) {
            .pointer => |p| base_type = p.element,
            .reference => |r| base_type = r.element,
            else => break,
        }
    } else unreachable;

    switch (base_type) {
        .@"struct" => |st| {
            if (st.getField(e.member_name)) |field| {
                return field.typ;
            }
            const related = if (v.findStructDecl(st.name)) |sd|
                v.makeRelatedR(v.symbolRange(sd.name), v.fmtError("struct '{s}' defined here", .{st.name}))
            else
                &[_]Diagnostic.RelatedInfo{};
            const suggestion = blk: {
                var field_names: [64][]const u8 = undefined;
                const count = @min(st.fields.len, 64);
                for (0..count) |i| field_names[i] = st.fields[i].name;
                break :blk suggestName(e.member_name, field_names[0..count], 3);
            };
            if (suggestion) |s| {
                v.addErrorWithRelatedR(mr, Diagnostic.Code.no_such_member, v.fmtError("struct '{s}' has no member '{s}'; did you mean '{s}'?", .{ st.name, e.member_name, s }), related);
            } else {
                v.addErrorWithRelatedR(mr, Diagnostic.Code.no_such_member, v.fmtError("struct '{s}' has no member '{s}'", .{ st.name, e.member_name }), related);
            }
            return null;
        },
        .vector => |ve| {
            if (e.member_name.len < 1 or e.member_name.len > 4) {
                v.addErrorWithCodeR(mr, Diagnostic.Code.no_such_member, v.fmtError("invalid swizzle '.{s}' on type '{s}'; valid components are xyzw or rgba", .{ e.member_name, base_type.string() }));
                return null;
            }
            if (!v.validateSwizzle(e.member_name, ve.width, e.loc, base_type)) return null;
            // Single-component swizzle: returns scalar
            if (e.member_name.len == 1) {
                return .{ .scalar = ve.element };
            }
            // Multi-component swizzle: returns vector
            const swiz_vec = v.arena.create(Types.Vector) catch return null;
            swiz_vec.* = .{
                .width = @intCast(e.member_name.len),
                .element = ve.element,
            };
            return .{ .vector = swiz_vec };
        },
        else => {
            v.addErrorWithCodeR(mr, Diagnostic.Code.no_such_member, v.fmtError("type '{s}' has no members", .{base_type.string()}));
            return null;
        },
    }
}

// =========================================================================
// Phase 5: Uniformity Analysis
// =========================================================================

fn analyzeUniformity(v: *Validator) void {
    var ua = UniformityAnalyzer{
        .module = v.module,
        .diags = v.diags,
        .arena = v.arena,
        .filters = if (v.options.diagnostic_filters) |f| f else null,
    };
    ua.analyze();
}

/// Uniformity analysis detects non-uniform control flow violations.
/// Implements WGSL spec section 15.
const UniformityAnalyzer = struct {
    module: *Ast.Module,
    diags: *Diagnostic,
    arena: Allocator,
    filters: ?*Diagnostic.DiagnosticFilter,

    // Current function context
    current_func: ?*Ast.FunctionDecl = null,
    current_stage: ShaderStage = .none,

    // Current uniformity state
    state: UniformityState = .uniform,

    // Sources of non-uniformity
    non_uniform_sources: std.ArrayListUnmanaged(NonUniformSource) = .empty,

    const UniformityState = enum(u8) {
        uniform,
        may_be_non_uniform,
        non_uniform,
    };

    const NonUniformSource = struct {
        loc: u32,
        reason: []const u8,
        builtin_name: []const u8,
    };

    fn analyze(ua: *UniformityAnalyzer) void {
        for (ua.module.declarations.items) |decl| {
            switch (decl) {
                .function => |fn_decl| ua.analyzeFunction(fn_decl),
                else => {},
            }
        }
    }

    fn analyzeFunction(ua: *UniformityAnalyzer, fn_decl: *Ast.FunctionDecl) void {
        ua.current_func = fn_decl;
        ua.state = .uniform;
        ua.non_uniform_sources = .empty;

        // Determine shader stage
        ua.current_stage = .none;
        for (fn_decl.attributes.items) |attr| {
            if (std.mem.eql(u8, attr.name, "vertex")) {
                ua.current_stage = .vertex;
            } else if (std.mem.eql(u8, attr.name, "fragment")) {
                ua.current_stage = .fragment;
            } else if (std.mem.eql(u8, attr.name, "compute")) {
                ua.current_stage = .compute;
            }
        }

        // Parameters may introduce non-uniformity
        ua.analyzeParameters(fn_decl.parameters.items);

        // Analyze function body
        if (fn_decl.body) |body| {
            ua.analyzeCompoundStmt(body);
        }

        ua.current_func = null;
    }

    fn analyzeParameters(ua: *UniformityAnalyzer, params: []const Ast.Parameter) void {
        for (params) |param| {
            for (param.attributes.items) |attr| {
                if (std.mem.eql(u8, attr.name, "builtin") and attr.args.items.len > 0) {
                    switch (attr.args.items[0]) {
                        .ident => |ident| {
                            if (isNonUniformBuiltin(ident.name)) {
                                ua.non_uniform_sources.append(ua.arena, .{
                                    .loc = ident.loc,
                                    .reason = "builtin input is non-uniform",
                                    .builtin_name = ident.name,
                                }) catch {};
                            }
                        },
                        else => {},
                    }
                }
            }
        }
    }

    fn analyzeCompoundStmt(ua: *UniformityAnalyzer, s: *Ast.CompoundStmt) void {
        for (s.stmts.items) |stmt| {
            ua.analyzeStmt(stmt);
        }
    }

    fn analyzeStmt(ua: *UniformityAnalyzer, stmt: Ast.Stmt) void {
        switch (stmt) {
            .compound => |s| ua.analyzeCompoundStmt(s),
            .@"if" => |s| ua.analyzeIfStmt(s),
            .@"switch" => |s| ua.analyzeSwitchStmt(s),
            .loop => |s| ua.analyzeLoopStmt(s),
            .@"while" => |s| ua.analyzeWhileStmt(s),
            .@"for" => |s| ua.analyzeForStmt(s),
            .@"return" => |s| {
                if (s.value) |val| ua.analyzeExpr(val);
            },
            .assign => |s| {
                ua.analyzeExpr(s.left);
                ua.analyzeExpr(s.right);
            },
            .call => |s| ua.analyzeExpr(.{ .call = s.call }),
            .decl => |s| {
                switch (s.decl) {
                    .@"var" => |d| {
                        if (d.initializer) |init| ua.analyzeExpr(init);
                    },
                    .let => |d| {
                        if (d.initializer) |init| ua.analyzeExpr(init);
                    },
                    .@"const" => |d| {
                        if (d.initializer) |init| ua.analyzeExpr(init);
                    },
                    else => {},
                }
            },
            .incr_decr => |s| ua.analyzeExpr(s.expr),
            .break_if => |s| ua.analyzeExpr(s.condition),
            .@"break", .@"continue", .discard => {},
        }
    }

    fn analyzeIfStmt(ua: *UniformityAnalyzer, s: *Ast.IfStmt) void {
        const cond_non_uniform = ua.analyzeExprUniformity(s.condition);

        const prev_state = ua.state;
        if (cond_non_uniform) {
            ua.state = .non_uniform;
        }

        ua.analyzeCompoundStmt(s.body);
        if (s.else_branch) |else_stmt| {
            ua.analyzeStmt(else_stmt);
        }

        ua.state = prev_state;
    }

    fn analyzeSwitchStmt(ua: *UniformityAnalyzer, s: *Ast.SwitchStmt) void {
        const cond_non_uniform = ua.analyzeExprUniformity(s.expr);

        const prev_state = ua.state;
        if (cond_non_uniform) {
            ua.state = .non_uniform;
        }

        for (s.cases.items) |case| {
            for (case.selectors.items) |sel| {
                ua.analyzeExpr(sel);
            }
            ua.analyzeCompoundStmt(case.body);
        }

        ua.state = prev_state;
    }

    fn analyzeLoopStmt(ua: *UniformityAnalyzer, s: *Ast.LoopStmt) void {
        const prev_state = ua.state;
        ua.analyzeCompoundStmt(s.body);
        if (s.continuing) |cont| {
            ua.analyzeCompoundStmt(cont);
        }
        ua.state = prev_state;
    }

    fn analyzeWhileStmt(ua: *UniformityAnalyzer, s: *Ast.WhileStmt) void {
        const cond_non_uniform = ua.analyzeExprUniformity(s.condition);

        const prev_state = ua.state;
        if (cond_non_uniform) {
            ua.state = .non_uniform;
        }
        ua.analyzeCompoundStmt(s.body);
        ua.state = prev_state;
    }

    fn analyzeForStmt(ua: *UniformityAnalyzer, s: *Ast.ForStmt) void {
        if (s.init_stmt) |init| {
            ua.analyzeStmt(init);
        }

        var cond_non_uniform = false;
        if (s.condition) |cond| {
            cond_non_uniform = ua.analyzeExprUniformity(cond);
        }

        const prev_state = ua.state;
        if (cond_non_uniform) {
            ua.state = .non_uniform;
        }

        ua.analyzeCompoundStmt(s.body);

        if (s.update) |update| {
            ua.analyzeStmt(update);
        }

        ua.state = prev_state;
    }

    fn analyzeExpr(ua: *UniformityAnalyzer, expr: Ast.Expr) void {
        switch (expr) {
            .call => |e| ua.analyzeCallExpr(e),
            .binary => |e| {
                ua.analyzeExpr(e.left);
                ua.analyzeExpr(e.right);
            },
            .unary => |e| ua.analyzeExpr(e.operand),
            .index => |e| {
                ua.analyzeExpr(e.base);
                ua.analyzeExpr(e.idx);
            },
            .member => |e| ua.analyzeExpr(e.base),
            .paren => |e| ua.analyzeExpr(e.expr),
            .ident, .literal => {},
        }
    }

    fn analyzeCallExpr(ua: *UniformityAnalyzer, e: *Ast.CallExpr) void {
        var callee_name: []const u8 = "";
        if (e.func) |func| {
            switch (func) {
                .ident => |ident| callee_name = ident.name,
                else => {},
            }
        }

        // Check arguments
        for (e.args.items) |arg| {
            ua.analyzeExpr(arg);
        }

        // Check if this is a builtin that requires uniform control flow
        if (Builtins.lookup(callee_name)) |builtin| {
            if (builtin.requiresUniform() and ua.state != .uniform) {
                ua.reportUniformityError(e, callee_name, builtin.kind);
            }
        }
    }

    fn analyzeExprUniformity(ua: *UniformityAnalyzer, expr: Ast.Expr) bool {
        switch (expr) {
            .ident => |e| {
                // Check if identifier refers to non-uniform source
                for (ua.non_uniform_sources.items) |src| {
                    if (std.mem.eql(u8, src.builtin_name, e.name)) {
                        return true;
                    }
                }
                if (isNonUniformBuiltin(e.name)) {
                    return true;
                }
                return false;
            },
            .call => |e| {
                // Some builtins produce non-uniform results
                var callee_name: []const u8 = "";
                if (e.func) |func| {
                    switch (func) {
                        .ident => |ident| callee_name = ident.name,
                        else => {},
                    }
                }
                if (Builtins.lookup(callee_name)) |builtin| {
                    if (builtin.kind == .texture) {
                        return true; // Simplified
                    }
                }
                for (e.args.items) |arg| {
                    if (ua.analyzeExprUniformity(arg)) {
                        return true;
                    }
                }
                return false;
            },
            .binary => |e| {
                return ua.analyzeExprUniformity(e.left) or ua.analyzeExprUniformity(e.right);
            },
            .unary => |e| return ua.analyzeExprUniformity(e.operand),
            .index => |e| {
                return ua.analyzeExprUniformity(e.base) or ua.analyzeExprUniformity(e.idx);
            },
            .member => |e| return ua.analyzeExprUniformity(e.base),
            .paren => |e| return ua.analyzeExprUniformity(e.expr),
            .literal => return false,
        }
    }

    fn reportUniformityError(ua: *UniformityAnalyzer, e: *Ast.CallExpr, func_name: []const u8, kind: Builtins.Kind) void {
        // Determine the location
        var loc: u32 = 0;
        if (e.func) |func| {
            switch (func) {
                .ident => |ident| loc = ident.loc,
                else => {},
            }
        }

        // Determine the diagnostic rule and code
        var rule: []const u8 = "";
        var code: []const u8 = "";

        switch (kind) {
            .derivative => {
                rule = Diagnostic.rule_derivative_uniformity;
                code = Diagnostic.Code.non_uniform_derivative;
            },
            .synchronization => {
                rule = ""; // Always an error, cannot be filtered
                code = Diagnostic.Code.non_uniform_barrier;
            },
            .texture => {
                rule = Diagnostic.rule_derivative_uniformity;
                code = Diagnostic.Code.non_uniform_texture;
            },
            .subgroup => {
                rule = Diagnostic.rule_subgroup_uniformity;
                code = Diagnostic.Code.non_uniform_subgroup;
            },
            else => return,
        }

        // Check if this rule is filtered
        if (rule.len > 0 and ua.filters != null) {
            if (ua.filters.?.isDisabled(rule)) {
                return;
            }
        }

        // Determine severity
        var severity = Diagnostic.Severity.@"error";
        if (rule.len > 0 and ua.filters != null) {
            severity = ua.filters.?.getSeverity(rule, .@"error");
        }

        // Build message
        const message = switch (kind) {
            .derivative => "derivative function must only be called from uniform control flow",
            .synchronization => "barrier function must only be called from uniform control flow",
            .texture => "texture sampling with implicit LOD must only be called from uniform control flow",
            .subgroup => "subgroup operation requires uniform control flow",
            else => "function requires uniform control flow",
        };

        _ = func_name;

        ua.diags.add(ua.arena, .{
            .severity = severity,
            .code = code,
            .message = message,
            .range = ua.diags.makeRange(loc, loc + 1),
        });
    }
};

/// Returns true if the builtin input is known to be non-uniform.
fn isNonUniformBuiltin(name: []const u8) bool {
    const non_uniform = std.StaticStringMap(void).initComptime(.{
        .{ "vertex_index", {} },
        .{ "instance_index", {} },
        .{ "position", {} },
        .{ "front_facing", {} },
        .{ "sample_index", {} },
        .{ "sample_mask", {} },
        .{ "local_invocation_id", {} },
        .{ "local_invocation_index", {} },
        .{ "global_invocation_id", {} },
    });
    return non_uniform.has(name);
}

// =========================================================================
// Type Resolution Helpers
// =========================================================================

fn resolveType(v: *Validator, ast_type: Ast.Type) ?Types.Type {
    switch (ast_type) {
        .ident => |t| {
            if (v.lookupType(t.name)) |typ| return typ;
            // Type not found — report with suggestion if close match exists.
            if (v.suggestType(t.name, null)) |suggestion| {
                v.addErrorWithCodeR(astTypeRange(.{ .ident = t }), Diagnostic.Code.type_mismatch, v.fmtError("unknown type '{s}'; did you mean '{s}'?", .{ t.name, suggestion }));
            } else {
                v.addErrorWithCodeR(astTypeRange(.{ .ident = t }), Diagnostic.Code.type_mismatch, v.fmtError("unknown type '{s}'", .{t.name}));
            }
            return null;
        },
        .vec => |t| {
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
        },
        .mat => |t| {
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
        },
        .array => |t| {
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
        },
        .ptr => |t| {
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
        },
        .atomic => |t| {
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
        },
        .sampler => |t| {
            const result = v.arena.create(Types.Sampler) catch return null;
            result.* = .{ .comparison = t.comparison };
            return .{ .sampler = result };
        },
        .texture => |t| {
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
        },
    }
}

fn lookupType(v: *Validator, name: []const u8) ?Types.Type {
    // Built-in scalar types
    if (std.mem.eql(u8, name, "bool")) return Types.Bool;
    if (std.mem.eql(u8, name, "i32")) return Types.I32;
    if (std.mem.eql(u8, name, "u32")) return Types.U32;
    if (std.mem.eql(u8, name, "f32")) return Types.F32;
    if (std.mem.eql(u8, name, "f16")) {
        if (!v.enabled_features.contains("f16")) {
            v.addErrorWithCodeR(.{ .start = 0, .end = 1 }, Diagnostic.Code.feature_not_enabled, "'f16' requires 'enable f16;'");
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
fn suggestType(v: *Validator, name: []const u8, arg_count: ?usize) ?[]const u8 {
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
fn suggestIdentifier(v: *Validator, name: []const u8) ?[]const u8 {
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
fn suggestCallable(v: *Validator, name: []const u8, arg_count: ?usize) ?[]const u8 {
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
fn arityOfTypeConstructor(name: []const u8) ?usize {
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

fn parseVectorShorthand(v: *Validator, name: []const u8) ?Types.Type {
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

fn parseMatrixShorthand(v: *Validator, name: []const u8) ?Types.Type {
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

fn shorthandElement(shorthand: []const u8) *const Types.Scalar {
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

fn astTextureKindToType(kind: Ast.TextureKind) Types.TextureKind {
    return switch (kind) {
        .sampled => .sampled,
        .multisampled => .multisampled,
        .storage => .storage,
        .depth => .depth,
        .depth_multisampled => .depth_multisampled,
        .external => .external,
    };
}

fn astTextureDimToType(dim: Ast.TextureDimension) Types.TextureDimension {
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
const LocRange = struct { start: u32, end: u32 };

/// Get byte offset for a symbol declaration.
fn symbolLoc(v: *Validator, sym_idx: Ast.SymbolIndex) u32 {
    return v.symbolRange(sym_idx).start;
}

/// Get byte range for a symbol declaration name.
fn symbolRange(v: *Validator, sym_idx: Ast.SymbolIndex) LocRange {
    if (!sym_idx.isValid()) return .{ .start = 0, .end = 1 };
    const idx = sym_idx.index();
    if (idx < v.module.symbols.items.len) {
        const sym = v.module.symbols.items[idx];
        return .{ .start = sym.loc, .end = sym.loc +| @as(u32, @intCast(sym.original_name.len)) };
    }
    return .{ .start = 0, .end = 1 };
}

/// Extract the best available source location from an expression.
fn exprLoc(expr: Ast.Expr) u32 {
    return exprRange(expr).start;
}

/// Get byte range for the primary token of an expression.
fn exprRange(expr: Ast.Expr) LocRange {
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
fn exprSpan(expr: Ast.Expr) LocRange {
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

fn symbolName(v: *Validator, sym_idx: Ast.SymbolIndex) []const u8 {
    if (!sym_idx.isValid()) return "";
    const idx = sym_idx.index();
    if (idx < v.module.symbols.items.len) {
        return v.module.symbols.items[idx].original_name;
    }
    return "";
}

fn setSymbolType(v: *Validator, sym_idx: Ast.SymbolIndex, typ: ?Types.Type) Allocator.Error!void {
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

fn fmtError(v: *Validator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(v.arena, fmt, args) catch fmt;
}

// -- Single-offset helpers (kept for backward compat / simple cases) ------

fn addError(v: *Validator, offset: u32, message: []const u8) void {
    v.diags.addError(v.arena, offset, message);
}

fn addErrorWithCode(v: *Validator, offset: u32, code: []const u8, message: []const u8) void {
    v.diags.addErrorWithCode(v.arena, offset, code, message);
}

fn addWarning(v: *Validator, offset: u32, message: []const u8) void {
    if (v.options.strict_mode) {
        v.diags.addError(v.arena, offset, message);
    } else {
        v.diags.addWarning(v.arena, offset, message);
    }
}

// -- Range-aware helpers --------------------------------------------------

fn addErrorR(v: *Validator, r: LocRange, message: []const u8) void {
    v.diags.addErrorRange(v.arena, r.start, r.end, message);
}

fn addErrorWithCodeR(v: *Validator, r: LocRange, code: []const u8, message: []const u8) void {
    v.diags.addErrorWithCodeRange(v.arena, r.start, r.end, code, message);
}

fn addErrorWithRelatedR(v: *Validator, r: LocRange, code: []const u8, message: []const u8, related: []const Diagnostic.RelatedInfo) void {
    v.diags.add(v.arena, .{
        .severity = .@"error",
        .code = code,
        .message = message,
        .range = v.diags.makeRange(r.start, r.end),
        .related = related,
    });
}

fn addWarningR(v: *Validator, r: LocRange, message: []const u8) void {
    if (v.options.strict_mode) {
        v.diags.addErrorRange(v.arena, r.start, r.end, message);
    } else {
        v.diags.addWarningRange(v.arena, r.start, r.end, message);
    }
}

fn addWarningWithCodeR(v: *Validator, r: LocRange, code: []const u8, message: []const u8) void {
    v.diags.add(v.arena, .{
        .severity = if (v.options.strict_mode) .@"error" else .warning,
        .code = code,
        .message = message,
        .range = v.diags.makeRange(r.start, r.end),
    });
}

fn makeRelatedR(v: *Validator, r: LocRange, message: []const u8) []const Diagnostic.RelatedInfo {
    const slice = v.arena.alloc(Diagnostic.RelatedInfo, 1) catch return &.{};
    slice[0] = .{
        .range = v.diags.makeRange(r.start, r.end),
        .message = message,
    };
    return slice;
}

// -- Legacy single-offset wrappers for related info -----------------------

fn addErrorWithRelated(v: *Validator, offset: u32, code: []const u8, message: []const u8, related: []const Diagnostic.RelatedInfo) void {
    v.addErrorWithRelatedR(.{ .start = offset, .end = offset + 1 }, code, message, related);
}

fn makeRelated(v: *Validator, offset: u32, message: []const u8) []const Diagnostic.RelatedInfo {
    return v.makeRelatedR(.{ .start = offset, .end = offset + 1 }, message);
}

// -- Type location helpers ------------------------------------------------

fn astTypeLoc(ast_type: Ast.Type) u32 {
    return astTypeRange(ast_type).start;
}

fn astTypeRange(ast_type: Ast.Type) LocRange {
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
fn attrRange(attr: *const Ast.Attribute) LocRange {
    // +1 for the '@' prefix
    return .{ .start = attr.loc, .end = attr.loc +| 1 +| @as(u32, @intCast(attr.name.len)) };
}

/// Try to evaluate a const bool expression (for const_assert).
/// Handles: true/false literals, comparison operators on known-const int operands, logical not.
fn tryEvalConstBool(v: *const Validator, expr: Ast.Expr) ?bool {
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
fn tryExtractIntValue(v: *const Validator, expr: Ast.Expr) ?i64 {
    return v.tryExtractIntValueDepth(expr, 0);
}

fn tryExtractIntValueDepth(v: *const Validator, expr: Ast.Expr, depth: u32) ?i64 {
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

fn extractLiteralInt(lit: *Ast.LiteralExpr) ?i64 {
    if (lit.value.len == 0) return 0;
    var val_str = lit.value;
    if (val_str.len > 0 and (val_str[val_str.len - 1] == 'i' or val_str[val_str.len - 1] == 'u')) {
        val_str = val_str[0 .. val_str.len - 1];
    }
    return std.fmt.parseInt(i64, val_str, 0) catch null;
}

/// Extract a constant integer from a literal expression (no const lookup).
/// Used by freestanding helpers that don't have access to the Validator.
fn extractLiteralIntValue(expr: Ast.Expr) ?i64 {
    return extractLiteralIntValueDepth(expr, 0);
}

fn extractLiteralIntValueDepth(expr: Ast.Expr, depth: u32) ?i64 {
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

/// Expression evaluation stage per WGSL spec sections 6.7-6.9.
const ExprStage = enum(u2) {
    const_expr, // Evaluable at shader creation time from const declarations
    override_expr, // Evaluable at pipeline creation time (references overrides)
    runtime_expr, // Only evaluable at runtime
};

/// Classify the evaluation stage of an expression.
/// const_expr < override_expr < runtime_expr; parent = max(children).
fn classifyExprStage(v: *const Validator, expr: Ast.Expr) ExprStage {
    return v.classifyExprStageDepth(expr, 0);
}

fn classifyExprStageDepth(v: *const Validator, expr: Ast.Expr, depth: u32) ExprStage {
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

/// Check if a compound statement block contains any exit (break, return, discard).
/// Check if a compound block contains any exit (break, return, discard).
/// Uses a bounded worklist to avoid unbounded recursion on deep ASTs.
fn blockHasExit(block: *Ast.CompoundStmt) bool {
    var stack: [128]Ast.Stmt = undefined;
    var top: usize = 0;

    // Seed the stack with all statements in the block.
    for (block.stmts.items) |stmt| {
        if (top >= stack.len) return false;
        stack[top] = stmt;
        top += 1;
    }

    while (top > 0) {
        top -= 1;
        const stmt = stack[top];
        switch (stmt) {
            .@"break", .@"return", .discard => return true,
            .compound => |s| {
                for (s.stmts.items) |inner| {
                    if (top >= stack.len) return false;
                    stack[top] = inner;
                    top += 1;
                }
            },
            .@"if" => |s| {
                for (s.body.stmts.items) |inner| {
                    if (top >= stack.len) return false;
                    stack[top] = inner;
                    top += 1;
                }
                if (s.else_branch) |eb| {
                    if (top >= stack.len) return false;
                    stack[top] = eb;
                    top += 1;
                }
            },
            .@"switch" => |s| {
                for (s.cases.items) |c| {
                    for (c.body.stmts.items) |inner| {
                        if (top >= stack.len) return false;
                        stack[top] = inner;
                        top += 1;
                    }
                }
            },
            .loop => |s| {
                for (s.body.stmts.items) |inner| {
                    if (top >= stack.len) return false;
                    stack[top] = inner;
                    top += 1;
                }
            },
            .@"for" => |s| {
                for (s.body.stmts.items) |inner| {
                    if (top >= stack.len) return false;
                    stack[top] = inner;
                    top += 1;
                }
            },
            .@"while" => |s| {
                for (s.body.stmts.items) |inner| {
                    if (top >= stack.len) return false;
                    stack[top] = inner;
                    top += 1;
                }
            },
            else => {},
        }
    }
    return false;
}

/// Check if a continuing block has a break_if statement.
fn continuingHasBreakIf(continuing: ?*Ast.CompoundStmt) bool {
    const cont = continuing orelse return false;
    for (cont.stmts.items) |stmt| {
        switch (stmt) {
            .break_if => return true,
            else => {},
        }
    }
    return false;
}

/// Look up an identifier by name in module-scope declarations to classify its stage.
/// Used when the ident ref is unresolved (e.g., in attribute arguments).
fn classifyIdentByName(v: *const Validator, name: []const u8) ExprStage {
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

/// Check if a byte slice contains any of the given bytes.
fn hasByteAny(s: []const u8, chars: []const u8) bool {
    for (s) |c| {
        for (chars) |ch| {
            if (c == ch) return true;
        }
    }
    return false;
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

test "validator: isNonUniformBuiltin" {
    try std.testing.expect(isNonUniformBuiltin("vertex_index"));
    try std.testing.expect(isNonUniformBuiltin("instance_index"));
    try std.testing.expect(isNonUniformBuiltin("position"));
    try std.testing.expect(isNonUniformBuiltin("front_facing"));
    try std.testing.expect(isNonUniformBuiltin("sample_index"));
    try std.testing.expect(isNonUniformBuiltin("local_invocation_id"));
    try std.testing.expect(isNonUniformBuiltin("global_invocation_id"));
    // Uniform builtins
    try std.testing.expect(!isNonUniformBuiltin("workgroup_id"));
    try std.testing.expect(!isNonUniformBuiltin("num_workgroups"));
    try std.testing.expect(!isNonUniformBuiltin("not_a_builtin"));
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

test "validator: hasByteAny" {
    try std.testing.expect(hasByteAny("hello.world", ".eE"));
    try std.testing.expect(hasByteAny("1e5", ".eE"));
    try std.testing.expect(hasByteAny("3.14", ".eE"));
    try std.testing.expect(!hasByteAny("42", ".eE"));
    try std.testing.expect(!hasByteAny("", ".eE"));
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
