//! WGSL semantic validator.
//!
//! Performs type checking, symbol resolution validation, control flow analysis,
//! and uniformity analysis to ensure shaders conform to the WGSL specification.
//! Ported from Go's internal/validator/validator.go and uniformity.go.
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
const Dce = @import("Dce.zig");
const Allocator = std.mem.Allocator;

const Validator = @This();

/// Name and source location pair, used for duplicate-detection maps.
const LocName = struct { name: []const u8, loc: u32 };

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
    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        _ = allocator;
        var arena = self._arena orelse return;
        arena.deinit();
        self._arena = null;
    }
};

// =========================================================================
// Validator State
// =========================================================================

allocator: Allocator,
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

// Symbol type cache: maps SymbolIndex -> resolved Types.Type
symbol_types: std.AutoHashMapUnmanaged(u32, Types.Type) = .{},

// Struct type cache: maps name -> resolved struct type
struct_types: std.StringHashMapUnmanaged(*Types.Struct) = .{},

// Alias type cache: maps name -> resolved type (null = placeholder)
alias_types: std.StringHashMapUnmanaged(?Types.Type) = .{},

// Override ID tracking for uniqueness validation
override_ids: std.AutoHashMapUnmanaged(u32, LocName) = .{},
// Binding pair tracking for uniqueness validation: key = (group << 32) | binding
binding_pairs: std.AutoHashMapUnmanaged(u64, LocName) = .{},

// =========================================================================
// Public API
// =========================================================================

/// Validate a parsed WGSL module.
pub fn validate(allocator: Allocator, module: *Ast.Module, options: Options) !Result {
    const diags = try allocator.create(Diagnostic);
    diags.* = Diagnostic.init(allocator, module.source);
    diags.line_offset = options.line_offset;

    var v = Validator{
        .allocator = allocator,
        .module = module,
        .diags = diags,
        .options = options,
    };

    // Phase 1: Collect type declarations (structs, aliases)
    v.collectTypeDeclarations();

    // Phase 2: Resolve struct layouts
    v.resolveStructLayouts();

    // Phase 2.5: Detect recursive struct definitions
    v.checkRecursiveStructs();

    // Phase 3: Validate declarations
    v.validateDeclarations();

    // Phase 3.5: Register function signatures (enables forward references)
    v.registerFunctionSignatures();

    // Phase 3.75: Detect recursive function calls
    v.checkRecursiveFunctions();

    // Phase 4: Validate functions and statements
    v.validateFunctions();

    // Phase 5: Uniformity analysis
    v.analyzeUniformity();

    return .{
        .valid = !diags.hasErrors(),
        .diagnostics = diags,
    };
}

// =========================================================================
// Phase 1: Collect Type Declarations
// =========================================================================

fn collectTypeDeclarations(v: *Validator) void {
    for (v.module.declarations.items) |decl| {
        switch (decl) {
            .@"struct" => |d| {
                const name = v.symbolName(d.name);
                if (name.len == 0) continue;
                // Create struct type placeholder
                const st = v.allocator.create(Types.Struct) catch continue;
                st.* = .{
                    .name = name,
                    .fields = &.{},
                    .size_bytes = 0,
                    .align_bytes = 0,
                    .has_runtime_array = false,
                };
                v.struct_types.put(v.allocator, name, st) catch {};
            },
            .alias => |d| {
                const name = v.symbolName(d.name);
                if (name.len == 0) continue;
                // Placeholder — resolved in phase 2
                v.alias_types.put(v.allocator, name, null) catch {};
            },
            else => {},
        }
    }
}

// =========================================================================
// Phase 2: Resolve Struct Layouts
// =========================================================================

fn resolveStructLayouts(v: *Validator) void {
    for (v.module.declarations.items) |decl| {
        switch (decl) {
            .@"struct" => |d| {
                const name = v.symbolName(d.name);
                const st = v.struct_types.get(name) orelse continue;
                const loc = v.symbolLoc(d.name);

                // Spec: struct must have at least 1 member.
                if (d.members.items.len == 0) {
                    v.addErrorWithCode(loc, Diagnostic.Code.empty_struct, v.fmtError("struct '{s}' must have at least one member", .{name}));
                    continue;
                }

                // Build fields list, checking for duplicate member names
                var fields: std.ArrayListUnmanaged(Types.StructField) = .empty;
                var seen_members: std.StringHashMapUnmanaged(u32) = .{};
                for (d.members.items) |member| {
                    const member_name = v.symbolName(member.name);
                    if (seen_members.get(member_name)) |first_loc| {
                        v.addErrorWithRelated(v.symbolLoc(member.name), Diagnostic.Code.duplicate_symbol, v.fmtError("duplicate member '{s}' in struct '{s}'", .{ member_name, name }), v.makeRelated(first_loc, "first declared here"));
                        continue;
                    }
                    seen_members.put(v.allocator, member_name, v.symbolLoc(member.name)) catch {};
                    const member_type = v.resolveType(member.typ) orelse {
                        if (member.typ != .ident)
                            v.addError(v.symbolLoc(member.name), v.fmtError("cannot resolve type for member '{s}'", .{member_name}));
                        continue;
                    };
                    // Validate @align and @size attributes
                    for (member.attributes.items) |attr| {
                        if (std.mem.eql(u8, attr.name, "align") and attr.args.items.len > 0) {
                            if (tryExtractIntValue(attr.args.items[0])) |val| {
                                if (val <= 0 or (@as(u64, @intCast(val)) & (@as(u64, @intCast(val)) - 1)) != 0) {
                                    v.addErrorWithCode(attr.loc, Diagnostic.Code.invalid_attribute, v.fmtError("@align value must be a positive power of 2, got {d}", .{val}));
                                }
                            }
                        }
                        if (std.mem.eql(u8, attr.name, "size") and attr.args.items.len > 0) {
                            if (tryExtractIntValue(attr.args.items[0])) |val| {
                                const type_size = member_type.size();
                                if (val <= 0) {
                                    v.addErrorWithCode(attr.loc, Diagnostic.Code.invalid_attribute, v.fmtError("@size value must be positive, got {d}", .{val}));
                                } else if (type_size > 0 and @as(u32, @intCast(val)) < type_size) {
                                    v.addErrorWithCode(attr.loc, Diagnostic.Code.invalid_attribute, v.fmtError("@size({d}) is less than the byte size of the type ({d})", .{ val, type_size }));
                                }
                            }
                        }
                    }
                    fields.append(v.allocator, .{
                        .name = member_name,
                        .typ = member_type,
                        .offset = 0,
                    }) catch {};
                }

                st.fields = fields.items;
                st.computeLayout();
            },
            .alias => |d| {
                const name = v.symbolName(d.name);
                const alias_type = v.resolveType(d.typ);
                if (alias_type) |at| {
                    v.alias_types.put(v.allocator, name, at) catch {};
                } else {
                    v.addError(v.symbolLoc(d.name), v.fmtError("cannot resolve type alias '{s}'", .{name}));
                }
            },
            else => {},
        }
    }
}

// =========================================================================
// Phase 2.5: Detect Recursive Struct Definitions
// =========================================================================

fn checkRecursiveStructs(v: *Validator) void {
    var iter = v.struct_types.iterator();
    while (iter.next()) |entry| {
        if (v.structContainsCycle(entry.key_ptr.*, entry.value_ptr.*)) {
            const loc = v.findStructLoc(entry.key_ptr.*);
            v.addErrorWithCode(loc, Diagnostic.Code.recursive_type, v.fmtError("struct '{s}' contains itself recursively", .{entry.key_ptr.*}));
        }
    }
}

/// Iterative cycle detection using a worklist. Returns true if `root_name`
/// is reachable from any nested struct field of `start`.
fn structContainsCycle(v: *Validator, root_name: []const u8, start: *Types.Struct) bool {
    var visited: std.StringHashMapUnmanaged(void) = .{};
    var worklist: std.ArrayListUnmanaged(*Types.Struct) = .empty;
    worklist.append(v.allocator, start) catch return false;

    // Bounded iteration — struct count is finite and small.
    const max_iterations = v.struct_types.count() + 1;
    for (0..max_iterations) |_| {
        const current = worklist.pop() orelse return false;
        for (current.fields) |field| {
            const nested = extractNestedStruct(field.typ) orelse continue;
            if (std.mem.eql(u8, nested.name, root_name)) return true;
            if (visited.get(nested.name) != null) continue;
            visited.put(v.allocator, nested.name, {}) catch continue;
            worklist.append(v.allocator, nested) catch continue;
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
    for (v.module.declarations.items) |decl| {
        switch (decl) {
            .@"struct" => |d| {
                if (std.mem.eql(u8, v.symbolName(d.name), name)) return v.symbolLoc(d.name);
            },
            else => {},
        }
    }
    return 0;
}

// =========================================================================
// Phase 3.75: Detect Recursive Functions
// =========================================================================

fn checkRecursiveFunctions(v: *Validator) void {
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
                    Dce.collectStmtRefs(v.allocator, .{ .compound = body }, &all_refs);
                }

                // Filter to only function symbols
                var fn_refs: std.ArrayListUnmanaged(u32) = .empty;
                for (all_refs.items) |ref_idx| {
                    if (ref_idx < v.module.symbols.items.len and
                        v.module.symbols.items[ref_idx].kind == .function)
                    {
                        fn_refs.append(v.allocator, ref_idx) catch {};
                    }
                }

                call_graph.put(v.allocator, fn_idx, fn_refs) catch {};
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
            v.dfsFunctionCycle(&call_graph, &color, fn_idx);
        }
    }
}

fn dfsFunctionCycle(v: *Validator, call_graph: *const std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)), color: *std.AutoHashMapUnmanaged(u32, u2), fn_idx: u32) void {
    color.put(v.allocator, fn_idx, 1) catch return; // gray
    if (call_graph.get(fn_idx)) |callees| {
        for (callees.items) |callee| {
            const callee_color = color.get(callee) orelse 0;
            if (callee_color == 1) {
                // Gray → cycle found. Report on the callee (the function being called recursively).
                const sym_idx: Ast.SymbolIndex = @enumFromInt(callee);
                v.addErrorWithCode(v.symbolLoc(sym_idx), Diagnostic.Code.recursive_function, v.fmtError("function '{s}' is recursive", .{v.symbolName(sym_idx)}));
            } else if (callee_color == 0) {
                v.dfsFunctionCycle(call_graph, color, callee);
            }
            // black (2) = already fully processed, skip
        }
    }
    color.put(v.allocator, fn_idx, 2) catch return; // black
}

// =========================================================================
// Phase 3: Validate Declarations
// =========================================================================

fn validateDeclarations(v: *Validator) void {
    for (v.module.declarations.items) |decl| {
        switch (decl) {
            .@"const" => |d| v.validateConstDecl(d),
            .override => |d| v.validateOverrideDecl(d),
            .@"var" => |d| v.validateVarDecl(d),
            .let => |d| v.validateLetDecl(d),
            .const_assert => |d| v.validateConstAssert(d),
            else => {},
        }
    }
}

fn validateConstDecl(v: *Validator, d: *Ast.ConstDecl) void {
    const name = v.symbolName(d.name);

    const loc = v.symbolLoc(d.name);

    // const must have an initializer
    if (d.initializer == null) {
        v.addErrorWithCode(loc, Diagnostic.Code.missing_initializer, v.fmtError("'const {s}' requires an initializer", .{name}));
        return;
    }

    // Infer or check type
    const init_type = v.checkExpr(d.initializer.?) orelse return;

    var decl_type: ?Types.Type = null;
    if (d.typ) |ast_type| {
        decl_type = v.resolveType(ast_type);
        if (decl_type) |dt| {
            if (!Types.canConvertTo(init_type, dt)) {
                const type_loc = astTypeLoc(ast_type);
                const related = if (type_loc != 0) v.makeRelated(type_loc, v.fmtError("type '{s}' declared here", .{dt.string()})) else &[_]Diagnostic.RelatedInfo{};
                v.addErrorWithRelated(loc, Diagnostic.Code.type_mismatch, v.fmtError("cannot initialize '{s}' with type '{s}' (expected '{s}')", .{ name, init_type.string(), dt.string() }), related);
                return;
            }
        }
    } else {
        // Infer type from initializer, converting abstract to concrete
        decl_type = Types.concreteType(init_type);
    }

    // const must have constructible type
    if (decl_type) |dt| {
        if (!dt.isConstructible()) {
            v.addErrorWithCode(loc, Diagnostic.Code.invalid_const_expr, v.fmtError("const '{s}' has non-constructible type '{s}'", .{ name, dt.string() }));
            return;
        }
    }

    v.setSymbolType(d.name, decl_type);
}

fn validateOverrideDecl(v: *Validator, d: *Ast.OverrideDecl) void {
    const loc = v.symbolLoc(d.name);
    const name = v.symbolName(d.name);

    // override must be concrete scalar type
    var decl_type: ?Types.Type = null;
    if (d.typ) |ast_type| {
        decl_type = v.resolveType(ast_type);
    } else if (d.initializer) |init| {
        decl_type = v.checkExpr(init);
    }

    if (decl_type == null) {
        if (d.typ == null or d.typ.? != .ident)
            v.addErrorWithCode(loc, Diagnostic.Code.invalid_override, v.fmtError("cannot determine type for 'override {s}'", .{name}));
        return;
    }

    const dt = decl_type.?;
    // Must be concrete scalar
    switch (dt) {
        .scalar => |s| {
            if (!s.isConcrete()) {
                v.addErrorWithCode(loc, Diagnostic.Code.invalid_override, v.fmtError("'override {s}' must be bool, i32, u32, f32, or f16, got '{s}'", .{ name, dt.string() }));
                return;
            }
        },
        else => {
            v.addErrorWithCode(loc, Diagnostic.Code.invalid_override, v.fmtError("'override {s}' must be bool, i32, u32, f32, or f16, got '{s}'", .{ name, dt.string() }));
            return;
        },
    }

    if (d.initializer) |init| {
        const init_type = v.checkExpr(init);
        if (init_type) |it| {
            if (!Types.canConvertTo(it, dt)) {
                if (d.typ) |ast_type| {
                    const type_loc = astTypeLoc(ast_type);
                    if (type_loc != 0) {
                        v.addErrorWithRelated(loc, Diagnostic.Code.type_mismatch, v.fmtError("cannot initialize '{s}' with type '{s}' (expected '{s}')", .{ name, it.string(), dt.string() }), v.makeRelated(type_loc, v.fmtError("type '{s}' declared here", .{dt.string()})));
                    } else {
                        v.addErrorWithCode(loc, Diagnostic.Code.type_mismatch, v.fmtError("cannot initialize '{s}' with type '{s}' (expected '{s}')", .{ name, it.string(), dt.string() }));
                    }
                } else {
                    v.addErrorWithCode(loc, Diagnostic.Code.type_mismatch, v.fmtError("cannot initialize '{s}' with type '{s}' (expected '{s}')", .{ name, it.string(), dt.string() }));
                }
            }
        }
    }

    // Validate @id attribute: must be 0..65535, unique
    v.validateOverrideId(d, name);

    v.setSymbolType(d.name, decl_type);
}

fn validateOverrideId(v: *Validator, d: *Ast.OverrideDecl, name: []const u8) void {
    for (d.attributes.items) |attr| {
        if (!std.mem.eql(u8, attr.name, "id")) continue;
        if (attr.args.items.len == 0) continue;

        const id_val = tryExtractIntValue(attr.args.items[0]) orelse continue;
        if (id_val < 0 or id_val > 65535) {
            v.addErrorWithCode(attr.loc, Diagnostic.Code.invalid_override_id, v.fmtError("@id value {d} is out of range [0, 65535]", .{id_val}));
            return;
        }
        const id: u32 = @intCast(id_val);
        if (v.override_ids.get(id)) |existing| {
            v.addErrorWithRelated(attr.loc, Diagnostic.Code.duplicate_override_id, v.fmtError("@id({d}) is already used by override '{s}'", .{ id, existing.name }), v.makeRelated(existing.loc, v.fmtError("@id({d}) first used here", .{id})));
        } else {
            v.override_ids.put(v.allocator, id, .{ .name = name, .loc = attr.loc }) catch return;
        }
        return;
    }
}

fn validateVarDecl(v: *Validator, d: *Ast.VarDecl) void {
    const loc = v.symbolLoc(d.name);
    const name = v.symbolName(d.name);

    // Determine type
    var decl_type: ?Types.Type = null;
    if (d.typ) |ast_type| {
        decl_type = v.resolveType(ast_type);
    } else if (d.initializer) |init| {
        decl_type = v.checkExpr(init);
        // Convert abstract types to concrete for var declarations
        if (decl_type) |dt| decl_type = Types.concreteType(dt);
    }

    if (decl_type == null) {
        // Skip if resolveType already reported "unknown type" for .ident
        if (d.typ == null or d.typ.? != .ident)
            v.addErrorWithCode(loc, Diagnostic.Code.type_mismatch, v.fmtError("cannot determine type for 'var {s}'", .{name}));
        return;
    }

    const dt = decl_type.?;

    // Validate address space constraints
    v.validateAddressSpace(d, dt);

    // Check initializer compatibility
    if (d.initializer) |init| {
        const init_type = v.checkExpr(init);
        if (init_type) |it| {
            if (!Types.canConvertTo(it, dt)) {
                if (d.typ) |ast_type| {
                    const type_loc = astTypeLoc(ast_type);
                    if (type_loc != 0) {
                        v.addErrorWithRelated(loc, Diagnostic.Code.type_mismatch, v.fmtError("cannot initialize '{s}' with type '{s}' (expected '{s}')", .{ name, it.string(), dt.string() }), v.makeRelated(type_loc, v.fmtError("type '{s}' declared here", .{dt.string()})));
                    } else {
                        v.addErrorWithCode(loc, Diagnostic.Code.type_mismatch, v.fmtError("cannot initialize '{s}' with type '{s}' (expected '{s}')", .{ name, it.string(), dt.string() }));
                    }
                } else {
                    v.addErrorWithCode(loc, Diagnostic.Code.type_mismatch, v.fmtError("cannot initialize '{s}' with type '{s}' (expected '{s}')", .{ name, it.string(), dt.string() }));
                }
            }
        }
    }

    // Check for required @group/@binding on uniform/storage vars
    if (d.address_space == .uniform or d.address_space == .storage) {
        var has_group = false;
        var has_binding = false;
        var group_val: ?i64 = null;
        var binding_val: ?i64 = null;
        for (d.attributes.items) |attr| {
            if (std.mem.eql(u8, attr.name, "group")) {
                has_group = true;
                if (attr.args.items.len > 0) group_val = tryExtractIntValue(attr.args.items[0]);
            }
            if (std.mem.eql(u8, attr.name, "binding")) {
                has_binding = true;
                if (attr.args.items.len > 0) binding_val = tryExtractIntValue(attr.args.items[0]);
            }
        }
        if (!has_group or !has_binding) {
            v.addErrorWithCode(loc, Diagnostic.Code.missing_binding, v.fmtError("{s} var '{s}' requires @group and @binding attributes", .{ d.address_space.string(), name }));
        } else if (group_val != null and binding_val != null) {
            const key = (@as(u64, @intCast(group_val.?)) << 32) | @as(u64, @intCast(binding_val.?));
            if (v.binding_pairs.get(key)) |existing| {
                v.addErrorWithRelated(loc, Diagnostic.Code.duplicate_binding, v.fmtError("@group({d}) @binding({d}) is already used by '{s}'", .{ group_val.?, binding_val.?, existing.name }), v.makeRelated(existing.loc, v.fmtError("'{s}' declared here", .{existing.name})));
            } else {
                v.binding_pairs.put(v.allocator, key, .{ .name = name, .loc = loc }) catch {};
            }
        }
    }

    v.setSymbolType(d.name, decl_type);
}

fn validateLetDecl(v: *Validator, d: *Ast.LetDecl) void {
    const loc = v.symbolLoc(d.name);
    const name = v.symbolName(d.name);

    // let must have an initializer
    if (d.initializer == null) {
        v.addErrorWithCode(loc, Diagnostic.Code.missing_initializer, v.fmtError("'let {s}' requires an initializer", .{name}));
        return;
    }

    const init_type = v.checkExpr(d.initializer.?) orelse return;

    if (!init_type.isConstructible() and init_type != .pointer and init_type.isConcrete()) {
        v.addErrorWithCode(loc, Diagnostic.Code.type_mismatch, v.fmtError("'let {s}' requires a constructible or pointer type, got '{s}'", .{ name, init_type.string() }));
        return;
    }

    var decl_type: ?Types.Type = null;
    if (d.typ) |ast_type| {
        decl_type = v.resolveType(ast_type);
        if (decl_type) |dt| {
            if (!Types.canConvertTo(init_type, dt)) {
                const type_loc = astTypeLoc(ast_type);
                const related = if (type_loc != 0) v.makeRelated(type_loc, v.fmtError("type '{s}' declared here", .{dt.string()})) else &[_]Diagnostic.RelatedInfo{};
                v.addErrorWithRelated(loc, Diagnostic.Code.type_mismatch, v.fmtError("cannot initialize '{s}' with type '{s}' (expected '{s}')", .{ name, init_type.string(), dt.string() }), related);
                return;
            }
        }
    } else {
        // Infer type from initializer, converting abstract to concrete
        decl_type = Types.concreteType(init_type);
    }

    v.setSymbolType(d.name, decl_type);
}

fn validateConstAssert(v: *Validator, d: *Ast.ConstAssertDecl) void {
    // Spec: const_assert expression must be of type bool.
    const expr_type = v.checkExpr(d.expr) orelse return;
    if (!expr_type.eql(Types.Bool)) {
        v.addErrorWithCode(exprLoc(d.expr), Diagnostic.Code.invalid_const_expr, v.fmtError("const_assert expression must be 'bool', got '{s}'", .{expr_type.string()}));
    }
}

fn validateAddressSpace(v: *Validator, d: *Ast.VarDecl, var_type: Types.Type) void {
    const loc = v.symbolLoc(d.name);
    const name = v.symbolName(d.name);
    // Handle types (texture, sampler) must not specify an address space
    const is_handle = var_type == .texture or var_type == .sampler;
    if (is_handle and d.address_space != .none) {
        v.addErrorWithCode(loc, Diagnostic.Code.invalid_address_space, v.fmtError("var '{s}' of handle type must not specify an address space", .{name}));
        return;
    }
    switch (d.address_space) {
        .workgroup => {
            if (!var_type.isStorable()) {
                v.addErrorWithCode(loc, Diagnostic.Code.invalid_workgroup_var, v.fmtError("workgroup var '{s}' has non-storable type '{s}'", .{ name, var_type.string() }));
            }
        },
        .uniform => {
            if (!var_type.isHostShareable()) {
                v.addErrorWithCode(loc, Diagnostic.Code.invalid_uniform_var, v.fmtError("uniform var '{s}' has non-host-shareable type '{s}'", .{ name, var_type.string() }));
            }
            if (d.initializer != null) {
                v.addErrorWithCode(loc, Diagnostic.Code.invalid_initializer, v.fmtError("uniform var '{s}' cannot have an initializer", .{name}));
            }
            // Uniform buffer layout: arrays must have element alignment >= 16
            v.checkUniformLayout(var_type, loc, name);
        },
        .storage => {
            if (!var_type.isHostShareable()) {
                v.addErrorWithCode(loc, Diagnostic.Code.invalid_storage_var, v.fmtError("storage var '{s}' has non-host-shareable type '{s}'", .{ name, var_type.string() }));
            }
            if (d.initializer != null) {
                v.addErrorWithCode(loc, Diagnostic.Code.invalid_initializer, v.fmtError("storage var '{s}' cannot have an initializer", .{name}));
            }
            if (d.access_mode == .write) {
                v.addErrorWithCode(loc, Diagnostic.Code.invalid_access_mode, v.fmtError("storage var '{s}' access mode must be 'read' or 'read_write'", .{name}));
            }
        },
        else => {},
    }
}

fn checkUniformLayout(v: *Validator, typ: Types.Type, loc: u32, var_name: []const u8) void {
    switch (typ) {
        .array => |a| {
            const elem_align = a.element.alignment();
            if (elem_align > 0 and elem_align < 16) {
                v.addErrorWithCode(loc, Diagnostic.Code.invalid_uniform_var, v.fmtError("uniform var '{s}' contains array with element alignment {d} (uniform requires 16)", .{ var_name, elem_align }));
            }
        },
        .@"struct" => |s| {
            for (s.fields) |field| {
                v.checkUniformLayout(field.typ, loc, var_name);
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
fn registerFunctionSignatures(v: *Validator) void {
    for (v.module.declarations.items) |decl| {
        switch (decl) {
            .function => |fn_decl| {
                var param_types: std.ArrayListUnmanaged(Types.Type) = .empty;
                for (fn_decl.parameters.items) |param| {
                    if (v.resolveType(param.typ)) |pt| {
                        param_types.append(v.allocator, pt) catch {};
                    }
                }

                var return_type: ?Types.Type = null;
                if (fn_decl.return_type) |rt| {
                    return_type = v.resolveType(rt);
                }

                if (fn_decl.name.isValid()) {
                    const fn_type = Types.functionType(v.allocator, param_types.items, return_type) catch null;
                    if (fn_type) |ft| {
                        v.setSymbolType(fn_decl.name, ft);
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

fn validateFunctions(v: *Validator) void {
    for (v.module.declarations.items) |decl| {
        switch (decl) {
            .function => |fn_decl| v.validateFunction(fn_decl),
            else => {},
        }
    }
}

fn validateFunction(v: *Validator, fn_decl: *Ast.FunctionDecl) void {
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

    // Resolve return type
    if (fn_decl.return_type) |rt| {
        v.return_type = v.resolveType(rt);
        if (v.return_type) |ret| {
            if (!ret.isConstructible()) {
                v.addErrorWithCode(v.symbolLoc(fn_decl.name), Diagnostic.Code.type_mismatch, v.fmtError("function '{s}' has non-constructible return type '{s}'", .{ v.symbolName(fn_decl.name), ret.string() }));
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
            v.setSymbolType(param.name, pt);
            param_types.append(v.allocator, pt) catch {};
        }
        v.validateParameterAttributes(param);
    }

    // Register function type in symbol_types so calls can resolve it
    if (fn_decl.name.isValid()) {
        const fn_type = Types.functionType(v.allocator, param_types.items, v.return_type) catch null;
        if (fn_type) |ft| {
            v.setSymbolType(fn_decl.name, ft);
        }
    }

    // Validate entry point requirements
    if (v.current_stage != .none) {
        v.validateEntryPoint(fn_decl);
    }

    // Validate function body
    if (fn_decl.body) |body| {
        v.validateCompoundStmt(body);
    }

    // Check for missing return
    if (v.return_type != null and !v.has_return) {
        v.addErrorWithCode(v.symbolLoc(fn_decl.name), Diagnostic.Code.missing_return, v.fmtError("function '{s}' must return a value", .{v.symbolName(fn_decl.name)}));
    }

    v.current_func = null;
    v.return_type = null;
}

fn validateParameterAttributes(v: *Validator, param: Ast.Parameter) void {
    for (param.attributes.items) |attr| {
        if (std.mem.eql(u8, attr.name, "location")) {
            if (v.current_stage == .none) {
                v.addErrorWithCode(attr.loc, Diagnostic.Code.invalid_attribute, "@location is only valid on entry point parameters");
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

fn validateEntryPoint(v: *Validator, fn_decl: *Ast.FunctionDecl) void {
    const fn_loc = v.symbolLoc(fn_decl.name);
    switch (v.current_stage) {
        .vertex => {
            // Must return @builtin(position)
            if (!v.vertexHasPositionOutput(fn_decl)) {
                v.addErrorWithCode(fn_loc, Diagnostic.Code.invalid_entry_point, v.fmtError("vertex entry point '{s}' must include @builtin(position) output", .{v.symbolName(fn_decl.name)}));
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
                        v.addErrorWithCode(attr.loc, Diagnostic.Code.invalid_attribute, "@workgroup_size requires at least one argument");
                    }
                }
            }
            if (!has_workgroup_size) {
                v.addErrorWithCode(fn_loc, Diagnostic.Code.missing_attribute, v.fmtError("compute entry point '{s}' requires @workgroup_size", .{v.symbolName(fn_decl.name)}));
            }

            // Must not return a value
            if (fn_decl.return_type != null) {
                v.addErrorWithCode(fn_loc, Diagnostic.Code.invalid_entry_point, v.fmtError("compute entry point '{s}' must not return a value", .{v.symbolName(fn_decl.name)}));
            }
        },
        .none => {},
    }

    // Validate entry point IO: duplicate @location and missing @builtin/@location on struct members
    v.validateEntryPointIO(fn_decl);
}

fn validateEntryPointIO(v: *Validator, fn_decl: *Ast.FunctionDecl) void {
    const fn_loc = v.symbolLoc(fn_decl.name);

    // Check input locations (parameters)
    var input_locations: std.AutoHashMapUnmanaged(i64, u32) = .{};
    for (fn_decl.parameters.items) |param| {
        // Direct @location on parameter
        if (getLocationInfo(param.attributes)) |info| {
            if (input_locations.get(info.value)) |first_loc| {
                v.addErrorWithRelated(v.symbolLoc(param.name), Diagnostic.Code.invalid_shader_io, v.fmtError("duplicate input @location({d})", .{info.value}), v.makeRelated(first_loc, v.fmtError("@location({d}) first used here", .{info.value})));
            } else {
                input_locations.put(v.allocator, info.value, info.loc) catch {};
            }
        }
        // If param type is a struct, check its members
        const param_type = v.resolveType(param.typ) orelse continue;
        if (param_type == .@"struct") {
            if (v.findStructDecl(param_type.@"struct".name)) |sd| {
                for (sd.members.items) |member| {
                    if (!hasLocationOrBuiltin(member.attributes)) {
                        v.addErrorWithCode(v.symbolLoc(member.name), Diagnostic.Code.invalid_shader_io, v.fmtError("entry point struct member '{s}' must have @builtin or @location", .{v.symbolName(member.name)}));
                    }
                    if (getLocationInfo(member.attributes)) |info| {
                        if (input_locations.get(info.value)) |first_loc| {
                            v.addErrorWithRelated(v.symbolLoc(member.name), Diagnostic.Code.invalid_shader_io, v.fmtError("duplicate input @location({d})", .{info.value}), v.makeRelated(first_loc, v.fmtError("@location({d}) first used here", .{info.value})));
                        } else {
                            input_locations.put(v.allocator, info.value, info.loc) catch {};
                        }
                    }
                }
            }
        }
    }

    // Check output locations (return type)
    var output_locations: std.AutoHashMapUnmanaged(i64, u32) = .{};
    if (getLocationInfo(fn_decl.return_attr)) |info| {
        output_locations.put(v.allocator, info.value, info.loc) catch {};
    }
    if (fn_decl.return_type) |rt| {
        const ret_type = v.resolveType(rt) orelse return;
        if (ret_type == .@"struct") {
            if (v.findStructDecl(ret_type.@"struct".name)) |sd| {
                for (sd.members.items) |member| {
                    if (!hasLocationOrBuiltin(member.attributes)) {
                        v.addErrorWithCode(fn_loc, Diagnostic.Code.invalid_shader_io, v.fmtError("entry point struct member '{s}' must have @builtin or @location", .{v.symbolName(member.name)}));
                    }
                    if (getLocationInfo(member.attributes)) |info| {
                        if (output_locations.get(info.value)) |first_loc| {
                            v.addErrorWithRelated(fn_loc, Diagnostic.Code.invalid_shader_io, v.fmtError("duplicate output @location({d})", .{info.value}), v.makeRelated(first_loc, v.fmtError("@location({d}) first used here", .{info.value})));
                        } else {
                            output_locations.put(v.allocator, info.value, info.loc) catch {};
                        }
                    }
                }
            }
        }
    }
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
            if (tryExtractIntValue(attr.args.items[0])) |val| {
                return .{ .value = val, .loc = attr.loc };
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

fn validateBuiltinForStage(v: *Validator, builtin_name: []const u8, is_input: bool, loc: u32) void {
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
        v.addErrorWithCode(loc, Diagnostic.Code.invalid_builtin, v.fmtError("@builtin({s}) is not valid for {s} shaders", .{ builtin_name, v.current_stage.string() }));
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

fn validateStmt(v: *Validator, stmt: Ast.Stmt) void {
    switch (stmt) {
        .compound => |s| v.validateCompoundStmt(s),
        .@"return" => |s| v.validateReturnStmt(s),
        .@"if" => |s| v.validateIfStmt(s),
        .@"switch" => |s| v.validateSwitchStmt(s),
        .loop => |s| v.validateLoopStmt(s),
        .@"while" => |s| v.validateWhileStmt(s),
        .@"for" => |s| v.validateForStmt(s),
        .@"break" => |s| v.validateBreakStmt(s),
        .break_if => |s| v.validateBreakIfStmt(s),
        .@"continue" => |s| v.validateContinueStmt(s),
        .discard => |s| v.validateDiscardStmt(s),
        .assign => |s| v.validateAssignStmt(s),
        .incr_decr => |s| v.validateIncrDecrStmt(s),
        .call => |s| v.validateCallStmt(s),
        .decl => |s| v.validateDeclStmt(s),
    }
}

fn validateCompoundStmt(v: *Validator, s: *Ast.CompoundStmt) void {
    var terminated = false;
    for (s.stmts.items) |stmt| {
        if (terminated) {
            v.addErrorWithCode(v.getStmtLoc(stmt), Diagnostic.Code.unreachable_code, "code is unreachable");
            break; // report once per block
        }
        v.validateStmt(stmt);
        if (stmtTerminates(stmt)) terminated = true;
    }
}

fn stmtTerminates(stmt: Ast.Stmt) bool {
    return switch (stmt) {
        .@"return", .@"break", .@"continue" => true,
        .compound => |s| s.stmts.items.len > 0 and stmtTerminates(s.stmts.items[s.stmts.items.len - 1]),
        .@"if" => |s| blk: {
            const body_terminates = s.body.stmts.items.len > 0 and stmtTerminates(s.body.stmts.items[s.body.stmts.items.len - 1]);
            break :blk if (s.else_branch) |eb| body_terminates and stmtTerminates(eb) else false;
        },
        .@"switch" => |s| blk: {
            var has_default = false;
            for (s.cases.items) |c| {
                if (c.selectors.items.len == 0) has_default = true;
                if (c.body.stmts.items.len == 0 or !stmtTerminates(c.body.stmts.items[c.body.stmts.items.len - 1])) break :blk false;
            }
            break :blk has_default;
        },
        else => false,
    };
}

fn getStmtLoc(v: *Validator, stmt: Ast.Stmt) u32 {
    return switch (stmt) {
        .@"return" => |s| s.loc,
        .@"break" => |s| s.loc,
        .@"continue" => |s| s.loc,
        .discard => |s| s.loc,
        .assign => |s| s.loc,
        .incr_decr => |s| s.loc,
        .call => |s| s.call.loc,
        .decl => |s| v.symbolLoc(s.decl.nameRef()),
        else => 0,
    };
}

fn validateReturnStmt(v: *Validator, s: *Ast.ReturnStmt) void {
    v.has_return = true;

    if (s.value == null) {
        if (v.return_type) |rt| {
            v.addErrorWithCode(s.loc, Diagnostic.Code.missing_return, v.fmtError("return must provide a value of type '{s}'", .{rt.string()}));
        }
        return;
    }

    const expr_type = v.checkExpr(s.value.?) orelse return;

    if (expr_type.isRuntimeSizedArray()) {
        v.addErrorWithCode(s.loc, Diagnostic.Code.type_mismatch, "cannot return a runtime-sized array");
        return;
    }

    if (v.return_type) |rt| {
        if (!Types.canConvertTo(expr_type, rt)) {
            const related = if (v.current_func) |func| blk: {
                if (func.return_type) |frt| {
                    const rt_loc = astTypeLoc(frt);
                    if (rt_loc != 0) break :blk v.makeRelated(rt_loc, v.fmtError("return type '{s}' declared here", .{rt.string()}));
                }
                break :blk &[_]Diagnostic.RelatedInfo{};
            } else &[_]Diagnostic.RelatedInfo{};
            v.addErrorWithRelated(s.loc, Diagnostic.Code.type_mismatch, v.fmtError("cannot return '{s}' from function expecting '{s}'", .{ expr_type.string(), rt.string() }), related);
        }
    } else {
        const fn_name = if (v.current_func) |f| v.symbolName(f.name) else "";
        v.addErrorWithCode(s.loc, Diagnostic.Code.invalid_return, v.fmtError("cannot return a value from void function '{s}'", .{fn_name}));
    }
}

fn validateIfStmt(v: *Validator, s: *Ast.IfStmt) void {
    const cond_type = v.checkExpr(s.condition);
    if (cond_type) |ct| {
        if (!ct.eql(Types.Bool)) {
            v.addErrorWithCode(exprLoc(s.condition), Diagnostic.Code.type_mismatch, v.fmtError("if condition must be 'bool', got '{s}'", .{ct.string()}));
        }
    }

    v.validateCompoundStmt(s.body);
    if (s.else_branch) |else_stmt| {
        v.validateStmt(else_stmt);
    }
}

fn validateSwitchStmt(v: *Validator, s: *Ast.SwitchStmt) void {
    const selector_type = v.checkExpr(s.expr);
    if (selector_type) |st| {
        if (!Types.isInteger(st)) {
            v.addErrorWithCode(exprLoc(s.expr), Diagnostic.Code.type_mismatch, v.fmtError("switch selector must be integer, got '{s}'", .{st.string()}));
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
                v.addErrorWithCode(exprLoc(s.expr), Diagnostic.Code.missing_default_case, "switch statement has multiple default clauses");
            }
        }
        for (case.selectors.items) |sel| {
            const sel_type = v.checkExpr(sel);
            if (sel_type != null and selector_type != null) {
                if (!Types.canConvertTo(sel_type.?, selector_type.?)) {
                    v.addErrorWithRelated(exprLoc(sel), Diagnostic.Code.type_mismatch, v.fmtError("case selector '{s}' doesn't match switch type '{s}'", .{ sel_type.?.string(), selector_type.?.string() }), v.makeRelated(exprLoc(s.expr), v.fmtError("switch expression has type '{s}'", .{selector_type.?.string()})));
                }
            }
            // Check for duplicate case selector values
            if (tryExtractIntValue(sel)) |val| {
                if (seen_values.get(val) != null) {
                    v.addErrorWithCode(exprLoc(sel), Diagnostic.Code.duplicate_case_selector, v.fmtError("duplicate case selector value '{d}'", .{val}));
                } else {
                    seen_values.put(v.allocator, val, 1) catch {};
                }
            }
        }
        v.validateCompoundStmt(case.body);
    }

    if (default_count == 0) {
        v.addErrorWithCode(exprLoc(s.expr), Diagnostic.Code.missing_default_case, "switch statement must have a default clause");
    }

    v.in_switch = prev_in_switch;
}

fn validateLoopStmt(v: *Validator, s: *Ast.LoopStmt) void {
    const prev_in_loop = v.in_loop;
    v.in_loop = true;

    v.validateCompoundStmt(s.body);
    if (s.continuing) |cont| {
        const prev_in_continuing = v.in_continuing;
        v.in_continuing = true;
        v.validateCompoundStmt(cont);
        v.in_continuing = prev_in_continuing;
    }

    v.in_loop = prev_in_loop;
}

fn validateWhileStmt(v: *Validator, s: *Ast.WhileStmt) void {
    const cond_type = v.checkExpr(s.condition);
    if (cond_type) |ct| {
        if (!ct.eql(Types.Bool)) {
            v.addErrorWithCode(exprLoc(s.condition), Diagnostic.Code.type_mismatch, v.fmtError("while condition must be 'bool', got '{s}'", .{ct.string()}));
        }
    }

    const prev_in_loop = v.in_loop;
    v.in_loop = true;
    v.validateCompoundStmt(s.body);
    v.in_loop = prev_in_loop;
}

fn validateForStmt(v: *Validator, s: *Ast.ForStmt) void {
    if (s.init_stmt) |init| {
        v.validateStmt(init);
    }
    if (s.condition) |cond| {
        const cond_type = v.checkExpr(cond);
        if (cond_type) |ct| {
            if (!ct.eql(Types.Bool)) {
                v.addErrorWithCode(exprLoc(cond), Diagnostic.Code.type_mismatch, v.fmtError("for condition must be 'bool', got '{s}'", .{ct.string()}));
            }
        }
    }
    if (s.update) |update| {
        v.validateStmt(update);
    }

    const prev_in_loop = v.in_loop;
    v.in_loop = true;
    v.validateCompoundStmt(s.body);
    v.in_loop = prev_in_loop;
}

fn validateBreakStmt(v: *Validator, s: *Ast.BreakStmt) void {
    if (!v.in_loop and !v.in_switch) {
        v.addErrorWithCode(s.loc, Diagnostic.Code.break_outside_loop, "break statement must be inside a loop or switch");
    } else if (v.in_continuing) {
        v.addErrorWithCode(s.loc, Diagnostic.Code.break_outside_loop, "'break' must not be used in a continuing block (use 'break if' instead)");
    }
}

fn validateBreakIfStmt(v: *Validator, s: *Ast.BreakIfStmt) void {
    const cond_type = v.checkExpr(s.condition);
    if (cond_type) |ct| {
        if (!ct.eql(Types.Bool)) {
            v.addErrorWithCode(exprLoc(s.condition), Diagnostic.Code.type_mismatch, v.fmtError("break if condition must be 'bool', got '{s}'", .{ct.string()}));
        }
    }
}

fn validateContinueStmt(v: *Validator, s: *Ast.ContinueStmt) void {
    if (!v.in_loop) {
        v.addErrorWithCode(s.loc, Diagnostic.Code.continue_outside_loop, "continue statement must be inside a loop");
    }
}

fn validateDiscardStmt(v: *Validator, s: *Ast.DiscardStmt) void {
    if (v.current_stage != .fragment) {
        v.addErrorWithCode(s.loc, Diagnostic.Code.discard_outside_fragment, v.fmtError("'discard' is only valid in fragment shaders, not {s}", .{v.current_stage.string()}));
    }
}

fn validateAssignStmt(v: *Validator, s: *Ast.AssignStmt) void {
    const lhs_type = v.checkExpr(s.left) orelse return;
    const rhs_type = v.checkExpr(s.right) orelse return;

    if (s.op == .simple) {
        // Simple assignment: RHS must be convertible to LHS.
        if (!Types.canConvertTo(rhs_type, lhs_type)) {
            v.addErrorWithRelated(s.loc, Diagnostic.Code.type_mismatch, v.fmtError("cannot assign '{s}' to '{s}'", .{ rhs_type.string(), lhs_type.string() }), v.makeRelated(exprLoc(s.left), v.fmtError("left-hand side has type '{s}'", .{lhs_type.string()})));
        }
        return;
    }

    // Compound assignment (+=, -=, *=, etc.): v op= e is defined as v = v op e.
    // Compute the result type of the binary operation, then verify assignability.
    const result_type: ?Types.Type = switch (s.op) {
        .add, .sub => Types.addSubResultType(v.allocator, lhs_type, rhs_type) catch null,
        .mul => Types.multiplyResultType(v.allocator, lhs_type, rhs_type) catch null,
        .div => Types.divResultType(v.allocator, lhs_type, rhs_type) catch null,
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
        v.addErrorWithCode(s.loc, Diagnostic.Code.invalid_operand, v.fmtError("invalid operands for '{s}': '{s}' and '{s}'", .{ s.op.string(), lhs_type.string(), rhs_type.string() }));
        return;
    }

    if (!Types.canConvertTo(result_type.?, lhs_type)) {
        v.addErrorWithCode(s.loc, Diagnostic.Code.type_mismatch, v.fmtError("result type '{s}' of '{s}' is not assignable to '{s}'", .{ result_type.?.string(), s.op.string(), lhs_type.string() }));
    }
}

fn validateIncrDecrStmt(v: *Validator, s: *Ast.IncrDecrStmt) void {
    const expr_type = v.checkExpr(s.expr) orelse return;
    // Spec: operand must be a concrete integer scalar (i32 or u32 only).
    const is_concrete_int_scalar = switch (expr_type) {
        .scalar => |sc| sc.kind == .i32 or sc.kind == .u32,
        else => false,
    };
    if (!is_concrete_int_scalar) {
        v.addErrorWithCode(s.loc, Diagnostic.Code.type_mismatch, v.fmtError("increment/decrement requires concrete integer scalar (i32 or u32), got '{s}'", .{expr_type.string()}));
    }
}

fn validateCallStmt(v: *Validator, s: *Ast.CallStmt) void {
    _ = v.checkCallExpr(s.call);
}

fn validateDeclStmt(v: *Validator, s: *Ast.DeclStmt) void {
    switch (s.decl) {
        .@"const" => |d| v.validateConstDecl(d),
        .let => |d| v.validateLetDecl(d),
        .@"var" => |d| v.validateVarDecl(d),
        .const_assert => |d| v.validateConstAssert(d),
        else => {},
    }
}

// =========================================================================
// Expression Type Checking
// =========================================================================

fn checkExpr(v: *Validator, expr: Ast.Expr) ?Types.Type {
    return switch (expr) {
        .literal => |e| v.checkLiteral(e),
        .ident => |e| v.checkIdent(e),
        .binary => |e| v.checkBinary(e),
        .unary => |e| v.checkUnary(e),
        .call => |e| v.checkCallExpr(e),
        .index => |e| v.checkIndex(e),
        .member => |e| v.checkMember(e),
        .paren => |e| v.checkExpr(e.expr),
    };
}

fn checkLiteral(v: *Validator, e: *Ast.LiteralExpr) ?Types.Type {
    _ = v;
    const val = e.value;
    if (val.len == 0) return Types.AbstractInt;

    // Boolean literals
    if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "false")) {
        return Types.Bool;
    }

    // Check for float indicators
    if (hasByteAny(val, ".eE")) {
        if (val[val.len - 1] == 'h') return Types.F16;
        if (val[val.len - 1] == 'f') return Types.F32;
        return Types.AbstractFloat;
    }

    // Suffix-based typing
    if (val[val.len - 1] == 'h') return Types.F16;
    if (val[val.len - 1] == 'f') return Types.F32;
    if (val[val.len - 1] == 'u') return Types.U32;
    if (val[val.len - 1] == 'i') return Types.I32;

    return Types.AbstractInt;
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
    v.addErrorWithCode(e.loc, Diagnostic.Code.undefined_symbol, v.fmtError("use of undeclared identifier '{s}'", .{e.name}));
    return null;
}

fn checkBinary(v: *Validator, e: *Ast.BinaryExpr) ?Types.Type {
    const left_type = v.checkExpr(e.left) orelse return null;
    const right_type = v.checkExpr(e.right) orelse return null;

    const op_str = e.op.string();
    switch (e.op) {
        .logical_and, .logical_or => {
            if (!left_type.eql(Types.Bool) or !right_type.eql(Types.Bool)) {
                v.addErrorWithCode(e.loc, Diagnostic.Code.invalid_operand, v.fmtError("operator '{s}' requires 'bool' operands, got '{s}' and '{s}'", .{ op_str, left_type.string(), right_type.string() }));
                return null;
            }
            return Types.Bool;
        },
        .eq, .ne => {
            if (!left_type.eql(right_type) and
                !Types.canConvertTo(left_type, right_type) and
                !Types.canConvertTo(right_type, left_type))
            {
                v.addErrorWithCode(e.loc, Diagnostic.Code.invalid_operand, v.fmtError("operator '{s}' requires compatible types, got '{s}' and '{s}'", .{ op_str, left_type.string(), right_type.string() }));
                return null;
            }
            // Vector comparisons return vec<N, bool>
            if (left_type == .vector) {
                const bvec = v.allocator.create(Types.Vector) catch return Types.Bool;
                bvec.* = .{ .width = left_type.vector.width, .element = Types.scalar_bool_ptr };
                return .{ .vector = bvec };
            }
            return Types.Bool;
        },
        .lt, .le, .gt, .ge => {
            if (!Types.isNumeric(left_type) or !Types.isNumeric(right_type)) {
                v.addErrorWithCode(e.loc, Diagnostic.Code.invalid_operand, v.fmtError("operator '{s}' requires numeric operands, got '{s}' and '{s}'", .{ op_str, left_type.string(), right_type.string() }));
                return null;
            }
            // Vector comparisons return vec<N, bool>
            if (left_type == .vector) {
                const bvec = v.allocator.create(Types.Vector) catch return Types.Bool;
                bvec.* = .{ .width = left_type.vector.width, .element = Types.scalar_bool_ptr };
                return .{ .vector = bvec };
            }
            return Types.Bool;
        },
        .add, .sub => {
            const result = Types.addSubResultType(v.allocator, left_type, right_type) catch return null;
            if (result) |r| {
                return r;
            }
            v.addErrorWithCode(e.loc, Diagnostic.Code.invalid_operand, v.fmtError("operator '{s}' requires numeric types, got '{s}' and '{s}'", .{ op_str, left_type.string(), right_type.string() }));
            return null;
        },
        .mul => {
            const result = Types.multiplyResultType(v.allocator, left_type, right_type) catch return null;
            if (result) |r| {
                return r;
            }
            v.addErrorWithCode(e.loc, Diagnostic.Code.invalid_operand, v.fmtError("cannot multiply '{s}' by '{s}'", .{ left_type.string(), right_type.string() }));
            return null;
        },
        .div => {
            const result = Types.divResultType(v.allocator, left_type, right_type) catch return null;
            if (result) |r| {
                return r;
            }
            v.addErrorWithCode(e.loc, Diagnostic.Code.invalid_operand, v.fmtError("cannot divide '{s}' by '{s}'", .{ left_type.string(), right_type.string() }));
            return null;
        },
        .mod => {
            // WGSL % works on both integers and floats (unlike C where fmod is separate).
            if (!Types.isNumeric(left_type) or !Types.isNumeric(right_type)) {
                v.addErrorWithCode(e.loc, Diagnostic.Code.invalid_operand, v.fmtError("operator '%' requires numeric operands, got '{s}' and '{s}'", .{ left_type.string(), right_type.string() }));
                return null;
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
            v.addErrorWithCode(e.loc, Diagnostic.Code.invalid_operand, v.fmtError("operator '{s}' requires integer or bool, got '{s}' and '{s}'", .{ op_str, left_type.string(), right_type.string() }));
            return null;
        },
        .shl, .shr => {
            if (!Types.isInteger(left_type)) {
                v.addErrorWithCode(e.loc, Diagnostic.Code.invalid_operand, v.fmtError("operator '{s}' requires integer left operand, got '{s}'", .{ op_str, left_type.string() }));
                return null;
            }
            if (!right_type.eql(Types.U32) and !Types.canConvertTo(right_type, Types.U32)) {
                v.addErrorWithCode(e.loc, Diagnostic.Code.invalid_operand, v.fmtError("shift amount must be 'u32', got '{s}'", .{right_type.string()}));
                return null;
            }
            return left_type;
        },
    }
}

fn checkUnary(v: *Validator, e: *Ast.UnaryExpr) ?Types.Type {
    const operand_type = v.checkExpr(e.operand) orelse return null;

    switch (e.op) {
        .neg => {
            if (!Types.isNumeric(operand_type)) {
                v.addErrorWithCode(e.loc, Diagnostic.Code.invalid_operand, v.fmtError("unary '-' requires numeric type, got '{s}'", .{operand_type.string()}));
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
                v.addErrorWithCode(e.loc, Diagnostic.Code.invalid_operand, v.fmtError("unary '!' requires 'bool', got '{s}'", .{operand_type.string()}));
                return null;
            }
            return Types.Bool;
        },
        .bit_not => {
            if (!Types.isInteger(operand_type)) {
                v.addErrorWithCode(e.loc, Diagnostic.Code.invalid_operand, v.fmtError("unary '~' requires integer type, got '{s}'", .{operand_type.string()}));
                return null;
            }
            return operand_type;
        },
        .deref => {
            switch (operand_type) {
                .pointer => |p| return p.element,
                .reference => |r| return r.element,
                else => {
                    v.addErrorWithCode(e.loc, Diagnostic.Code.invalid_operand, v.fmtError("cannot dereference non-pointer type '{s}'", .{operand_type.string()}));
                    return null;
                },
            }
        },
        .addr => {
            // Creates a pointer to the operand (simplified — actual address space detection is complex)
            const p = v.allocator.create(Types.Pointer) catch return null;
            p.* = .{
                .address_space = .function,
                .element = operand_type,
                .access_mode = .read_write,
            };
            return .{ .pointer = p };
        },
    }
}

fn checkCallExpr(v: *Validator, e: *Ast.CallExpr) ?Types.Type {
    // First check if it's a template type constructor
    if (e.template_type) |tt| {
        return v.resolveType(tt);
    }

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
                v.addErrorWithCode(e.loc, Diagnostic.Code.not_callable, "expression is not callable");
                return null;
            },
        }
    }

    // Check if it's a builtin function
    if (Builtins.lookup(callee_name)) |builtin| {
        // Check argument count
        const arg_count: u32 = @intCast(e.args.items.len);
        if (!builtin.checkArgCount(arg_count)) {
            v.addErrorWithCode(e.loc, Diagnostic.Code.invalid_arg_count, v.fmtError("'{s}' expects {d} to {d} arguments, got {d}", .{ callee_name, builtin.min_args, builtin.max_args, arg_count }));
            return null;
        }

        // Collect argument types (single pass — no double evaluation)
        var arg_types: [8]?Types.Type = .{null} ** 8;
        const max_check = @min(e.args.items.len, 8);
        for (0..max_check) |i| {
            arg_types[i] = v.checkExpr(e.args.items[i]);
        }

        // Type check arguments based on builtin kind
        switch (builtin.kind) {
            .numeric, .derivative => {
                for (0..max_check) |i| {
                    if (arg_types[i]) |at| {
                        if (!Types.isNumeric(at) and !Types.isFloat(at) and !Types.isMatrix(at)) {
                            v.addErrorWithCode(e.loc, Diagnostic.Code.invalid_arg_type, v.fmtError("'{s}' requires numeric argument, got '{s}'", .{ callee_name, at.string() }));
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
                            v.addErrorWithCode(e.loc, Diagnostic.Code.invalid_arg_type, v.fmtError("'{s}' requires 'bool' argument, got '{s}'", .{ callee_name, at.string() }));
                            return null;
                        }
                    }
                }
            },
            else => {},
        }

        return v.inferBuiltinReturnType(builtin, callee_name, arg_types);
    }

    // For non-builtin calls, validate all argument expressions and collect types
    var constructor_arg_types: std.ArrayListUnmanaged(?Types.Type) = .empty;
    for (e.args.items) |arg| {
        constructor_arg_types.append(v.allocator, v.checkExpr(arg)) catch {};
    }

    // Check if it's a type constructor
    if (v.lookupType(callee_name)) |t| {
        return v.checkTypeConstructor(e, t, constructor_arg_types.items);
    }

    // Check if it's a user-defined function
    if (e.func) |func| {
        switch (func) {
            .ident => |ident| {
                if (ident.ref.isValid()) {
                    const idx = ident.ref.index();
                    if (v.symbol_types.get(idx)) |sym_type| {
                        switch (sym_type) {
                            .function => |fn_type| {
                                const fn_related = v.makeRelated(v.symbolLoc(ident.ref), v.fmtError("'{s}' declared here", .{callee_name}));
                                // Check argument count
                                if (e.args.items.len != fn_type.parameters.len) {
                                    v.addErrorWithRelated(e.loc, Diagnostic.Code.invalid_arg_count, v.fmtError("'{s}' expects {d} arguments, got {d}", .{ callee_name, fn_type.parameters.len, e.args.items.len }), fn_related);
                                    return null;
                                }
                                // Check argument types
                                for (e.args.items, 0..) |arg, ai| {
                                    if (ai < fn_type.parameters.len) {
                                        const arg_type = v.checkExpr(arg);
                                        if (arg_type) |at| {
                                            const param_type = fn_type.parameters[ai];
                                            if (!at.eql(param_type) and !Types.canConvertTo(at, param_type)) {
                                                v.addErrorWithRelated(e.loc, Diagnostic.Code.invalid_arg_type, v.fmtError("argument {d} of '{s}' has type '{s}', expected '{s}'", .{ ai + 1, callee_name, at.string(), param_type.string() }), fn_related);
                                                return null;
                                            }
                                        }
                                    }
                                }
                                return fn_type.return_type;
                            },
                            else => {
                                // Symbol exists but is not a function
                                v.addErrorWithCode(e.loc, Diagnostic.Code.not_callable, v.fmtError("'{s}' is not a function or type constructor", .{callee_name}));
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
                    v.addErrorWithCode(e.loc, Diagnostic.Code.not_callable, v.fmtError("'{s}' is not a function or type constructor", .{callee_name}));
                    return null;
                }
            },
            else => {},
        }
    }

    // Unresolved call — if we have a name and it's not a builtin, error
    if (callee_name.len > 0) {
        v.addErrorWithCode(e.loc, Diagnostic.Code.not_callable, v.fmtError("'{s}' is not a function or type constructor", .{callee_name}));
    }
    return null;
}

fn inferBuiltinReturnType(v: *Validator, builtin: Builtins.Builtin, name: []const u8, arg_types: [8]?Types.Type) ?Types.Type {
    return switch (builtin.return_pattern) {
        .same_as_arg => arg_types[0],
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
            const result = v.allocator.create(Types.Vector) catch return null;
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

    const result = v.allocator.create(Types.Vector) catch return null;
    result.* = .{ .width = width, .element = Types.scalar_u32_ptr };
    return .{ .vector = result };
}

fn inferCustomBuiltin(v: *Validator, name: []const u8, arg_types: [8]?Types.Type) ?Types.Type {
    // transpose: swap cols/rows
    if (std.mem.eql(u8, name, "transpose")) {
        if (arg_types[0]) |at| {
            if (at == .matrix) {
                const m = at.matrix;
                const result = v.allocator.create(Types.Matrix) catch return null;
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

    // atomicCompareExchangeWeak returns a struct — simplified to null
    if (std.mem.eql(u8, name, "atomicCompareExchangeWeak")) {
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
    // frexp/modf: return structs — simplified to null
    return null;
}

// Singleton vectors for common return types
const vec4_f32_singleton = Types.Vector{ .width = 4, .element = Types.scalar_f32_ptr };
const vec4_u32_singleton = Types.Vector{ .width = 4, .element = Types.scalar_u32_ptr };
const vec4_i32_singleton = Types.Vector{ .width = 4, .element = Types.scalar_i32_ptr };
const vec2_f32_singleton = Types.Vector{ .width = 2, .element = Types.scalar_f32_ptr };

fn checkTypeConstructor(v: *Validator, e: *Ast.CallExpr, t: Types.Type, arg_types: []const ?Types.Type) ?Types.Type {
    const arg_count = e.args.items.len;

    switch (t) {
        .scalar => {
            if (arg_count > 1) return null;
            // Scalar constructor: single arg must be a scalar type
            if (arg_count == 1) {
                if (arg_types.len > 0) {
                    if (arg_types[0]) |at| {
                        if (at != .scalar) {
                            v.addErrorWithCode(e.loc, Diagnostic.Code.invalid_conversion, v.fmtError("cannot convert '{s}' to '{s}'", .{ at.string(), t.string() }));
                            return null;
                        }
                    }
                }
            }
        },
        .vector => |ve| {
            // Single vector arg: element types must be scalar-compatible
            if (arg_count == 1 and arg_types.len > 0) {
                if (arg_types[0]) |at| {
                    if (at == .vector) {
                        const src_elem = at.vector.element;
                        const dst_elem = ve.element;
                        // Both must be numeric or both bool
                        if (src_elem.isNumeric() != dst_elem.isNumeric()) {
                            v.addErrorWithCode(e.loc, Diagnostic.Code.invalid_conversion, v.fmtError("cannot convert '{s}' to '{s}'", .{ at.string(), t.string() }));
                            return null;
                        }
                    }
                }
            }
        },
        .@"struct" => |st| {
            if (arg_count != 0 and arg_count != st.fields.len) return null;
            // Check each field type matches
            if (arg_count == st.fields.len) {
                for (st.fields, 0..) |field, i| {
                    if (i < arg_types.len) {
                        if (arg_types[i]) |at| {
                            if (!at.eql(field.typ) and !Types.canConvertTo(at, field.typ)) {
                                v.addErrorWithCode(e.loc, Diagnostic.Code.invalid_conversion, v.fmtError("cannot convert '{s}' to '{s}' for field '{s}'", .{ at.string(), field.typ.string(), field.name }));
                                return null;
                            }
                        }
                    }
                }
            }
        },
        else => {},
    }
    return t;
}

fn checkIndex(v: *Validator, e: *Ast.IndexExpr) ?Types.Type {
    const base_type = v.checkExpr(e.base) orelse return null;
    const index_type = v.checkExpr(e.idx);

    // Check index type
    if (index_type) |it| {
        if (!Types.isInteger(it)) {
            v.addErrorWithCode(e.loc, Diagnostic.Code.type_mismatch, v.fmtError("array index must be integer, got '{s}'", .{it.string()}));
        }
    }

    // Get element type
    switch (base_type) {
        .array => |a| return a.element,
        .vector => |ve| return .{ .scalar = ve.element },
        .matrix => |m| {
            // Indexing a matrix gives a column vector
            const col_vec = v.allocator.create(Types.Vector) catch return null;
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

    v.addErrorWithCode(e.loc, Diagnostic.Code.not_indexable, v.fmtError("type '{s}' is not indexable", .{base_type.string()}));
    return null;
}

fn validateSwizzle(v: *Validator, name: []const u8, vec_width: u8, loc: u32, base_type: Types.Type) bool {
    const xyzw = "xyzw";
    const rgba = "rgba";
    var has_xyzw = false;
    var has_rgba = false;
    for (name) |c| {
        const xyzw_idx = std.mem.indexOfScalar(u8, xyzw, c);
        const rgba_idx = std.mem.indexOfScalar(u8, rgba, c);
        if (xyzw_idx == null and rgba_idx == null) {
            v.addErrorWithCode(loc, Diagnostic.Code.no_such_member, v.fmtError("invalid swizzle '.{s}' on type '{s}'", .{ name, base_type.string() }));
            return false;
        }
        if (xyzw_idx != null) has_xyzw = true;
        if (rgba_idx != null) has_rgba = true;
        // Check component index vs vector width
        const idx: u8 = @intCast(xyzw_idx orelse rgba_idx.?);
        if (idx >= vec_width) {
            v.addErrorWithCode(loc, Diagnostic.Code.no_such_member, v.fmtError("swizzle component '{c}' is out of bounds for '{s}'", .{ c, base_type.string() }));
            return false;
        }
    }
    if (has_xyzw and has_rgba) {
        v.addErrorWithCode(loc, Diagnostic.Code.no_such_member, v.fmtError("swizzle '.{s}' mixes xyzw and rgba groups", .{name}));
        return false;
    }
    return true;
}

fn checkMember(v: *Validator, e: *Ast.MemberExpr) ?Types.Type {
    var base_type = v.checkExpr(e.base) orelse return null;

    // Auto-dereference pointers/references
    while (true) {
        switch (base_type) {
            .pointer => |p| base_type = p.element,
            .reference => |r| base_type = r.element,
            else => break,
        }
    }

    switch (base_type) {
        .@"struct" => |st| {
            if (st.getField(e.member_name)) |field| {
                return field.typ;
            }
            const related = if (v.findStructDecl(st.name)) |sd|
                v.makeRelated(v.symbolLoc(sd.name), v.fmtError("struct '{s}' defined here", .{st.name}))
            else
                &[_]Diagnostic.RelatedInfo{};
            v.addErrorWithRelated(e.loc, Diagnostic.Code.no_such_member, v.fmtError("struct '{s}' has no member '{s}'", .{ st.name, e.member_name }), related);
            return null;
        },
        .vector => |ve| {
            if (e.member_name.len < 1 or e.member_name.len > 4) {
                v.addErrorWithCode(e.loc, Diagnostic.Code.no_such_member, v.fmtError("invalid swizzle '.{s}' on type '{s}'", .{ e.member_name, base_type.string() }));
                return null;
            }
            if (!v.validateSwizzle(e.member_name, ve.width, e.loc, base_type)) return null;
            // Single-component swizzle: returns scalar
            if (e.member_name.len == 1) {
                return .{ .scalar = ve.element };
            }
            // Multi-component swizzle: returns vector
            const swiz_vec = v.allocator.create(Types.Vector) catch return null;
            swiz_vec.* = .{
                .width = @intCast(e.member_name.len),
                .element = ve.element,
            };
            return .{ .vector = swiz_vec };
        },
        else => {
            v.addErrorWithCode(e.loc, Diagnostic.Code.no_such_member, v.fmtError("type '{s}' has no members", .{base_type.string()}));
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
        .allocator = v.allocator,
        .filters = if (v.options.diagnostic_filters) |f| f else null,
    };
    ua.analyze();
}

/// Uniformity analysis detects non-uniform control flow violations.
/// Implements WGSL spec section 15.
const UniformityAnalyzer = struct {
    module: *Ast.Module,
    diags: *Diagnostic,
    allocator: Allocator,
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
                                ua.non_uniform_sources.append(ua.allocator, .{
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

        ua.diags.add(ua.allocator, .{
            .severity = severity,
            .code = code,
            .message = message,
            .range = ua.diags.makeRange(loc, loc + 1),
            .spec_ref = "15",
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
            if (v.suggestType(t.name)) |suggestion| {
                v.addErrorWithCode(t.loc, Diagnostic.Code.type_mismatch, v.fmtError("unknown type '{s}'; did you mean '{s}'?", .{ t.name, suggestion }));
            } else {
                v.addErrorWithCode(t.loc, Diagnostic.Code.type_mismatch, v.fmtError("unknown type '{s}'", .{t.name}));
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
            const result = v.allocator.create(Types.Vector) catch return null;
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
                                v.addErrorWithCode(t.loc, Diagnostic.Code.invalid_matrix_element, v.fmtError("matrix element type must be f32 or f16, got '{s}'", .{resolved.string()}));
                                return null;
                            }
                            elem_scalar = s;
                        },
                        else => {
                            v.addErrorWithCode(t.loc, Diagnostic.Code.invalid_matrix_element, v.fmtError("matrix element type must be scalar, got '{s}'", .{resolved.string()}));
                            return null;
                        },
                    }
                }
            } else if (t.shorthand.len > 0) {
                elem_scalar = shorthandElement(t.shorthand);
            }
            const result = v.allocator.create(Types.Matrix) catch return null;
            result.* = .{ .cols = t.cols, .rows = t.rows, .element = elem_scalar };
            return .{ .matrix = result };
        },
        .array => |t| {
            const elem_type = if (t.elem_type) |et| (v.resolveType(et) orelse return null) else return null;
            var count: u32 = 0;
            if (t.size) |size_expr| {
                // Try to evaluate constant expression for array size
                if (tryExtractIntValue(size_expr)) |val| {
                    if (val <= 0) {
                        // Spec: array element count must be > 0
                        v.addErrorWithCode(exprLoc(size_expr), Diagnostic.Code.invalid_array_count, "array element count must be greater than 0");
                        return null;
                    }
                    count = @intCast(val);
                }
                // If we couldn't extract the value (identifier, complex expr), leave count=0
            }
            const result = v.allocator.create(Types.Array) catch return null;
            result.* = .{ .element = elem_type, .count = count };
            return .{ .array = result };
        },
        .ptr => |t| {
            const elem_type = v.resolveType(t.elem_type) orelse return null;
            const result = v.allocator.create(Types.Pointer) catch return null;
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
                        v.addErrorWithCode(t.loc, Diagnostic.Code.invalid_atomic_type, v.fmtError("atomic type requires i32 or u32, got '{s}'", .{elem_type.string()}));
                        return null;
                    }
                    const result = v.allocator.create(Types.Atomic) catch return null;
                    result.* = .{ .element = s };
                    return .{ .atomic = result };
                },
                else => {
                    v.addErrorWithCode(t.loc, Diagnostic.Code.invalid_atomic_type, v.fmtError("atomic type requires scalar element, got '{s}'", .{elem_type.string()}));
                    return null;
                },
            }
        },
        .sampler => |t| {
            const result = v.allocator.create(Types.Sampler) catch return null;
            result.* = .{ .comparison = t.comparison };
            return .{ .sampler = result };
        },
        .texture => |t| {
            var sampled_scalar: ?*const Types.Scalar = null;
            if (t.sampled_type) |st| {
                if (v.resolveType(st)) |resolved| {
                    switch (resolved) {
                        .scalar => |s| sampled_scalar = s,
                        else => {},
                    }
                }
            }
            const result = v.allocator.create(Types.Texture) catch return null;
            result.* = .{
                .kind = astTextureKindToType(t.kind),
                .dimension = astTextureDimToType(t.dimension),
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
    if (std.mem.eql(u8, name, "f16")) return Types.F16;
    if (std.mem.eql(u8, name, "sampler")) {
        const s = v.allocator.create(Types.Sampler) catch return null;
        s.* = .{ .comparison = false };
        return .{ .sampler = s };
    }
    if (std.mem.eql(u8, name, "sampler_comparison")) {
        const s = v.allocator.create(Types.Sampler) catch return null;
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
        const t = v.allocator.create(Types.Texture) catch return null;
        t.* = .{ .kind = kind, .dimension = dim, .sampled_type = null, .texel_format = "", .access_mode = .read };
        return .{ .texture = t };
    }

    // External texture type
    if (std.mem.eql(u8, name, "texture_external")) {
        const t = v.allocator.create(Types.Texture) catch return null;
        t.* = .{ .kind = .external, .dimension = .@"2d", .sampled_type = null, .texel_format = "", .access_mode = .read };
        return .{ .texture = t };
    }

    // Bare array constructor
    if (std.mem.eql(u8, name, "array")) {
        const arr = v.allocator.create(Types.Array) catch return null;
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
fn suggestType(v: *Validator, name: []const u8) ?[]const u8 {
    // Suffixed variants first — they're more commonly intended than bare constructors.
    const builtins = [_][]const u8{
        "bool",  "i32",   "u32",   "f32",   "f16",
        "sampler",        "sampler_comparison",
        "vec2f", "vec2i", "vec2u", "vec2h", "vec2",
        "vec3f", "vec3i", "vec3u", "vec3h", "vec3",
        "vec4f", "vec4i", "vec4u", "vec4h", "vec4",
        "mat2x2f",  "mat2x2h",  "mat2x2",
        "mat2x3f",  "mat2x3h",  "mat2x3",
        "mat2x4f",  "mat2x4h",  "mat2x4",
        "mat3x2f",  "mat3x2h",  "mat3x2",
        "mat3x3f",  "mat3x3h",  "mat3x3",
        "mat3x4f",  "mat3x4h",  "mat3x4",
        "mat4x2f",  "mat4x2h",  "mat4x2",
        "mat4x3f",  "mat4x3h",  "mat4x3",
        "mat4x4f",  "mat4x4h",  "mat4x4",
        "array",
        "texture_depth_2d",             "texture_depth_2d_array",
        "texture_depth_cube",           "texture_depth_cube_array",
        "texture_depth_multisampled_2d", "texture_external",
    };
    var best: ?[]const u8 = null;
    var best_dist: usize = 3; // only suggest if distance <= 2
    for (&builtins) |candidate| {
        const d = levenshteinBounded(name, candidate, best_dist);
        if (d < best_dist) {
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

/// Levenshtein distance with early termination at `max`.
fn levenshteinBounded(a: []const u8, b: []const u8, max: usize) usize {
    if (a.len > max and b.len > max and
        (if (a.len > b.len) a.len - b.len else b.len - a.len) >= max)
        return max;
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;
    // Use a single row of the DP matrix (stack-allocated, bounded).
    const width = b.len + 1;
    if (width > 128) return max; // don't bother with very long names
    var row: [128]usize = undefined;
    for (0..width) |j| row[j] = j;
    for (a, 0..) |ca, i| {
        var prev = i;
        row[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = if (ca == cb) 0 else 1;
            const ins = row[j + 1] + 1;
            const del = row[j] + 1;
            const sub = prev + cost;
            prev = row[j + 1];
            row[j + 1] = @min(ins, @min(del, sub));
        }
    }
    return row[b.len];
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

    const result = v.allocator.create(Types.Vector) catch return null;
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

    const result = v.allocator.create(Types.Matrix) catch return null;
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

/// Get byte offset for a symbol declaration.
fn symbolLoc(v: *Validator, sym_idx: Ast.SymbolIndex) u32 {
    if (!sym_idx.isValid()) return 0;
    const idx = sym_idx.index();
    if (idx < v.module.symbols.items.len) {
        return v.module.symbols.items[idx].loc;
    }
    return 0;
}

/// Extract the best available source location from an expression.
fn exprLoc(expr: Ast.Expr) u32 {
    return switch (expr) {
        .ident => |e| e.loc,
        .literal => |e| e.loc,
        .binary => |e| e.loc,
        .unary => |e| e.loc,
        .call => |e| e.loc,
        .index => |e| e.loc,
        .member => |e| e.loc,
        .paren => |e| exprLoc(e.expr),
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

fn setSymbolType(v: *Validator, sym_idx: Ast.SymbolIndex, typ: ?Types.Type) void {
    if (!sym_idx.isValid()) return;
    if (typ) |t| {
        v.symbol_types.put(v.allocator, sym_idx.index(), t) catch {};
    }
}

fn fmtError(v: *Validator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(v.allocator, fmt, args) catch fmt;
}

fn addError(v: *Validator, offset: u32, message: []const u8) void {
    v.diags.addError(v.allocator, offset, message);
}

fn addErrorWithCode(v: *Validator, offset: u32, code: []const u8, message: []const u8) void {
    v.diags.addErrorWithCode(v.allocator, offset, code, message);
}

fn addErrorWithRelated(v: *Validator, offset: u32, code: []const u8, message: []const u8, related: []const Diagnostic.RelatedInfo) void {
    v.diags.add(v.allocator, .{
        .severity = .@"error",
        .code = code,
        .message = message,
        .range = v.diags.makeRange(offset, offset + 1),
        .related = related,
    });
}

fn makeRelated(v: *Validator, offset: u32, message: []const u8) []const Diagnostic.RelatedInfo {
    const slice = v.allocator.alloc(Diagnostic.RelatedInfo, 1) catch return &.{};
    slice[0] = .{
        .range = v.diags.makeRange(offset, offset + 1),
        .message = message,
    };
    return slice;
}

fn astTypeLoc(ast_type: Ast.Type) u32 {
    return switch (ast_type) {
        .ident => |t| t.loc,
        .vec => |t| t.loc,
        .mat => |t| t.loc,
        .atomic => |t| t.loc,
        .array, .ptr, .sampler, .texture => 0,
    };
}

fn addWarning(v: *Validator, offset: u32, message: []const u8) void {
    if (v.options.strict_mode) {
        v.diags.addError(v.allocator, offset, message);
    } else {
        v.diags.addWarning(v.allocator, offset, message);
    }
}

/// Try to extract a constant integer value from a literal expression.
/// Iteratively unwraps paren and unary-negate to reach the literal.
fn tryExtractIntValue(expr: Ast.Expr) ?i64 {
    var current = expr;
    var negate = false;

    // Iteratively peel wrappers (parens, unary negate). Bounded to
    // prevent runaway on malformed ASTs.
    for (0..32) |_| {
        switch (current) {
            .literal => |lit| {
                if (lit.value.len == 0) return if (negate) @as(i64, 0) else @as(i64, 0);
                // Strip integer suffix (e.g., "1i", "2u")
                var val_str = lit.value;
                if (val_str.len > 0 and (val_str[val_str.len - 1] == 'i' or val_str[val_str.len - 1] == 'u')) {
                    val_str = val_str[0 .. val_str.len - 1];
                }
                const val = std.fmt.parseInt(i64, val_str, 0) catch return null;
                return if (negate) -val else val;
            },
            .unary => |u| {
                if (u.op == .neg) {
                    negate = !negate;
                    current = u.operand;
                } else {
                    return null;
                }
            },
            .paren => |p| current = p.expr,
            else => return null,
        }
    }
    return null;
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

test "ShaderStage string" {
    try std.testing.expectEqualStrings("vertex", ShaderStage.vertex.string());
    try std.testing.expectEqualStrings("fragment", ShaderStage.fragment.string());
    try std.testing.expectEqualStrings("compute", ShaderStage.compute.string());
    try std.testing.expectEqualStrings("none", ShaderStage.none.string());
}

test "isNonUniformBuiltin" {
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

test "isVertexInput" {
    try std.testing.expect(isVertexInput("vertex_index"));
    try std.testing.expect(isVertexInput("instance_index"));
    try std.testing.expect(!isVertexInput("position"));
}

test "isFragmentInput" {
    try std.testing.expect(isFragmentInput("position"));
    try std.testing.expect(isFragmentInput("front_facing"));
    try std.testing.expect(isFragmentInput("sample_index"));
    try std.testing.expect(!isFragmentInput("vertex_index"));
}

test "isComputeInput" {
    try std.testing.expect(isComputeInput("local_invocation_id"));
    try std.testing.expect(isComputeInput("global_invocation_id"));
    try std.testing.expect(isComputeInput("workgroup_id"));
    try std.testing.expect(isComputeInput("num_workgroups"));
    try std.testing.expect(!isComputeInput("position"));
}

test "shorthandElement" {
    try std.testing.expectEqual(Types.ScalarKind.i32, shorthandElement("vec3i").kind);
    try std.testing.expectEqual(Types.ScalarKind.u32, shorthandElement("vec4u").kind);
    try std.testing.expectEqual(Types.ScalarKind.f32, shorthandElement("vec2f").kind);
    try std.testing.expectEqual(Types.ScalarKind.f16, shorthandElement("mat3x3h").kind);
    try std.testing.expectEqual(Types.ScalarKind.f32, shorthandElement("").kind);
}

test "hasByteAny" {
    try std.testing.expect(hasByteAny("hello.world", ".eE"));
    try std.testing.expect(hasByteAny("1e5", ".eE"));
    try std.testing.expect(hasByteAny("3.14", ".eE"));
    try std.testing.expect(!hasByteAny("42", ".eE"));
    try std.testing.expect(!hasByteAny("", ".eE"));
}

test "validate empty module" {
    const allocator = std.testing.allocator;
    var scope = Ast.Scope.init(null);
    var module = Ast.Module.init(&scope, "");
    const result = try validate(allocator, &module, .{});
    defer allocator.destroy(result.diagnostics);
    defer result.diagnostics.deinit(allocator);
    try std.testing.expect(result.valid);
    try std.testing.expect(!result.diagnostics.hasErrors());
}
