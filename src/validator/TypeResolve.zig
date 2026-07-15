//! Type resolution: AST type nodes → resolved `Types.Type`.
//!
//! Owns `resolveType` and its eight per-kind resolvers, `lookupType`
//! (name → builtin/shorthand/struct/alias type), the vec/mat shorthand
//! parsers, the AST-enum → Types-enum texture conversions, and the
//! did-you-mean suggestion helpers (resolution-adjacent: they fire on unknown
//! types/identifiers and share the same callers). Callers in `Declarations.zig`,
//! `Expressions.zig`, and `Statements.zig` reach these through `Validator`'s
//! re-export aliases as `v.resolveType(...)`; this module imports none of them
//! (the star import graph routes through `Validator`).
//!
//! Composite `Types.Type` values are freshly `create`d per resolution and are
//! not interned (only scalar singletons are shared, `Types.zig`), so relocating
//! this code cannot change type identity. Loc/range helpers and diagnostic
//! emitters stay in `Validator.zig`; this module reaches them via the
//! `*Validator` receiver and the `astTypeRange`/`exprRange` file-local aliases
//! below (the same pattern the sibling submodules use).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Ast = @import("../Ast.zig");
const Types = @import("../Types.zig");
const Builtins = @import("../Builtins.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Suggest = @import("../Suggest.zig");
const Predeclared = @import("../Predeclared.zig");
const Validator = @import("../Validator.zig");

const astTypeRange = Validator.astTypeRange;
const exprRange = Validator.exprRange;
const levenshteinBounded = Suggest.levenshteinBounded;

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
        if (!v.scratch.enabled_features.contains("f16")) {
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
    if (v.out.struct_types.get(name)) |st| {
        return .{ .@"struct" = st };
    }

    // Check type aliases
    if (v.out.alias_types.get(name)) |maybe_type| {
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
    var sit = v.out.struct_types.iterator();
    while (sit.next()) |entry| {
        const d = levenshteinBounded(name, entry.key_ptr.*, best_dist);
        if (d < best_dist) {
            best = entry.key_ptr.*;
            best_dist = d;
        }
    }
    // Type aliases
    var ait = v.out.alias_types.iterator();
    while (ait.next()) |entry| {
        const d = levenshteinBounded(name, entry.key_ptr.*, best_dist);
        if (d < best_dist) {
            best = entry.key_ptr.*;
            best_dist = d;
        }
    }
    return best;
}

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
// Tests
// =========================================================================

test "validator: shorthandElement" {
    try std.testing.expectEqual(Types.ScalarKind.i32, shorthandElement("vec3i").kind);
    try std.testing.expectEqual(Types.ScalarKind.u32, shorthandElement("vec4u").kind);
    try std.testing.expectEqual(Types.ScalarKind.f32, shorthandElement("vec2f").kind);
    try std.testing.expectEqual(Types.ScalarKind.f16, shorthandElement("mat3x3h").kind);
    try std.testing.expectEqual(Types.ScalarKind.f32, shorthandElement("").kind);
}
