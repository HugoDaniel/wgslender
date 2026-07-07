//! Single source of truth for the WGSL predeclared-type-name inventory.
//!
//! The set of predeclared names — scalars, samplers, vector/matrix
//! shorthands, texture types, address spaces, access modes — was previously
//! restated across the Parser, CstLower, the Validator, `Suggest`, and the
//! LSP completion handler, and had drifted: `texture_external` was known to
//! CstLower's texture table but missing from the Parser's. This module holds
//! the one canonical inventory; every front-end consults it.
//!
//! Depends only on `Ast` (the syntactic layer) — the returned descriptors are
//! spelled in the AST's own enums so the Parser and CstLower can consume them
//! directly. The Validator maps these descriptors into its `Types.*`
//! representation at the call site; the shorthand parsers here are
//! allocation-free so they can be shared without an allocator.

const std = @import("std");
const Ast = @import("Ast.zig");

// -------------------------------------------------------------------------
// Scalars and samplers
// -------------------------------------------------------------------------

pub const scalar_type_names = [_][]const u8{ "bool", "i32", "u32", "f32", "f16" };
pub const sampler_names = [_][]const u8{ "sampler", "sampler_comparison" };

/// Type-constructor names that are neither scalars, samplers, vec/mat
/// shorthands, nor textures (i.e. take non-shorthand template arguments).
pub const other_type_names = [_][]const u8{ "array", "atomic", "ptr" };

// -------------------------------------------------------------------------
// Texture types
// -------------------------------------------------------------------------

pub const TextureInfo = struct {
    kind: Ast.TextureKind,
    dim: Ast.TextureDimension,
};

const TextureEntry = struct { name: []const u8, info: TextureInfo };

/// The canonical texture-type table. `texture_external` lives here (it was
/// the historically drifted entry). Order matches the Parser's original
/// listing plus `texture_external` after the sampled/multisampled group.
const texture_table = [_]TextureEntry{
    .{ .name = "texture_1d", .info = .{ .kind = .sampled, .dim = .@"1d" } },
    .{ .name = "texture_2d", .info = .{ .kind = .sampled, .dim = .@"2d" } },
    .{ .name = "texture_2d_array", .info = .{ .kind = .sampled, .dim = .@"2d_array" } },
    .{ .name = "texture_3d", .info = .{ .kind = .sampled, .dim = .@"3d" } },
    .{ .name = "texture_cube", .info = .{ .kind = .sampled, .dim = .cube } },
    .{ .name = "texture_cube_array", .info = .{ .kind = .sampled, .dim = .cube_array } },
    .{ .name = "texture_multisampled_2d", .info = .{ .kind = .multisampled, .dim = .@"2d" } },
    .{ .name = "texture_external", .info = .{ .kind = .external, .dim = .@"2d" } },
    .{ .name = "texture_storage_1d", .info = .{ .kind = .storage, .dim = .@"1d" } },
    .{ .name = "texture_storage_2d", .info = .{ .kind = .storage, .dim = .@"2d" } },
    .{ .name = "texture_storage_2d_array", .info = .{ .kind = .storage, .dim = .@"2d_array" } },
    .{ .name = "texture_storage_3d", .info = .{ .kind = .storage, .dim = .@"3d" } },
    .{ .name = "texture_depth_2d", .info = .{ .kind = .depth, .dim = .@"2d" } },
    .{ .name = "texture_depth_2d_array", .info = .{ .kind = .depth, .dim = .@"2d_array" } },
    .{ .name = "texture_depth_cube", .info = .{ .kind = .depth, .dim = .cube } },
    .{ .name = "texture_depth_cube_array", .info = .{ .kind = .depth, .dim = .cube_array } },
    .{ .name = "texture_depth_multisampled_2d", .info = .{ .kind = .depth_multisampled, .dim = .@"2d" } },
};

const texture_map = std.StaticStringMap(TextureInfo).initComptime(blk: {
    var kvs: [texture_table.len]struct { []const u8, TextureInfo } = undefined;
    for (texture_table, 0..) |e, i| kvs[i] = .{ e.name, e.info };
    break :blk kvs;
});

/// Resolve a texture-type spelling (`texture_2d`, `texture_depth_cube`,
/// `texture_external`, …) into its kind + dimension. Null for non-textures.
pub fn textureInfo(name: []const u8) ?TextureInfo {
    return texture_map.get(name);
}

/// All texture-type spellings, in `texture_table` order.
pub const texture_type_names = blk: {
    var arr: [texture_table.len][]const u8 = undefined;
    for (texture_table, 0..) |e, i| arr[i] = e.name;
    break :blk arr;
};

// -------------------------------------------------------------------------
// Address spaces and access modes (the parseable subsets)
// -------------------------------------------------------------------------

const address_space_map = std.StaticStringMap(Ast.AddressSpace).initComptime(.{
    .{ "function", .function },
    .{ "private", .private },
    .{ "workgroup", .workgroup },
    .{ "uniform", .uniform },
    .{ "storage", .storage },
});

/// Resolve a `var<...>` address-space keyword. Null for unknown spellings
/// (the caller decides whether to suggest a fix or silently accept `.none`).
pub fn addressSpace(text: []const u8) ?Ast.AddressSpace {
    return address_space_map.get(text);
}

const access_mode_map = std.StaticStringMap(Ast.AccessMode).initComptime(.{
    .{ "read", .read },
    .{ "write", .write },
    .{ "read_write", .read_write },
});

/// Resolve an access-mode keyword (`read` / `write` / `read_write`).
pub fn accessMode(text: []const u8) ?Ast.AccessMode {
    return access_mode_map.get(text);
}

// -------------------------------------------------------------------------
// Vector / matrix shorthand names and descriptors
// -------------------------------------------------------------------------

/// True for the bare vector constructor spellings `vec2` / `vec3` / `vec4`.
pub fn isVecName(name: []const u8) bool {
    return name.len == 4 and std.mem.eql(u8, name[0..3], "vec") and name[3] >= '2' and name[3] <= '4';
}

/// True for the bare matrix constructor spellings `matNxM`. Matches the
/// Parser's original predicate: length 6, `mat` prefix, `x` separator (the
/// column/row digits are validated downstream when the template is parsed).
pub fn isMatName(name: []const u8) bool {
    return name.len == 6 and std.mem.eql(u8, name[0..3], "mat") and name[4] == 'x';
}

/// The scalar element implied by a vec/mat shorthand suffix. WGSL defines
/// suffixes for the four concrete numeric scalars only (there is no `vec2b`).
pub const SuffixScalar = enum { i32, u32, f32, f16 };

pub const VecShorthand = struct {
    /// Component count: 2, 3, or 4.
    width: u8,
    /// Element from the suffix; null for the bare form (`vec3`), whose
    /// element is left to the caller (the Validator defaults it to f32).
    elem: ?SuffixScalar,
};

pub const MatShorthand = struct {
    cols: u8,
    rows: u8,
    /// Element from the suffix; null for the bare form (`mat2x2`).
    elem: ?SuffixScalar,
};

/// Parse a vector shorthand (`vec3`, `vec3f`, `vec2i`, …) into a descriptor.
/// Null for anything that is not a valid shorthand.
pub fn parseVecShorthand(name: []const u8) ?VecShorthand {
    if (name.len < 4 or name.len > 5) return null;
    if (!std.mem.eql(u8, name[0..3], "vec")) return null;
    const width: u8 = switch (name[3]) {
        '2' => 2,
        '3' => 3,
        '4' => 4,
        else => return null,
    };
    if (name.len == 4) return .{ .width = width, .elem = null };
    return .{ .width = width, .elem = suffixScalar(name[4]) orelse return null };
}

/// Parse a matrix shorthand (`mat2x2`, `mat4x3f`, `mat2x2h`, …). Matrices
/// are float-only, so `i`/`u` suffixes are rejected. Null otherwise.
pub fn parseMatShorthand(name: []const u8) ?MatShorthand {
    if (name.len < 6 or name.len > 7) return null;
    if (!std.mem.eql(u8, name[0..3], "mat")) return null;
    if (name[4] != 'x') return null;
    const cols: u8 = switch (name[3]) {
        '2' => 2,
        '3' => 3,
        '4' => 4,
        else => return null,
    };
    const rows: u8 = switch (name[5]) {
        '2' => 2,
        '3' => 3,
        '4' => 4,
        else => return null,
    };
    if (name.len == 6) return .{ .cols = cols, .rows = rows, .elem = null };
    const elem: SuffixScalar = switch (name[6]) {
        'f' => .f32,
        'h' => .f16,
        else => return null,
    };
    return .{ .cols = cols, .rows = rows, .elem = elem };
}

fn suffixScalar(c: u8) ?SuffixScalar {
    return switch (c) {
        'i' => .i32,
        'u' => .u32,
        'f' => .f32,
        'h' => .f16,
        else => null,
    };
}

/// The natural argument count encoded in a type-constructor name: the width
/// for a vector shorthand, the column count for a matrix shorthand. Null for
/// names that do not encode an arity. Used as a suggestion tiebreaker.
pub fn arityOfTypeConstructor(name: []const u8) ?usize {
    if (name.len == 0) return null;
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

// -------------------------------------------------------------------------
// Derived name lists
// -------------------------------------------------------------------------

/// Every vector shorthand spelling: bare `vecN` plus the `i`/`u`/`f`/`h`
/// suffixed forms.
pub const vec_type_names = blk: {
    const widths = [_]u8{ 2, 3, 4 };
    const suffixes = [_][]const u8{ "", "i", "u", "f", "h" };
    var arr: [widths.len * suffixes.len][]const u8 = undefined;
    var idx: usize = 0;
    for (widths) |w| {
        for (suffixes) |s| {
            arr[idx] = std.fmt.comptimePrint("vec{d}{s}", .{ w, s });
            idx += 1;
        }
    }
    break :blk arr;
};

/// Every matrix shorthand spelling: bare `matNxM` plus the `f`/`h` suffixed
/// forms.
pub const mat_type_names = blk: {
    const dims = [_][2]u8{
        .{ 2, 2 }, .{ 2, 3 }, .{ 2, 4 },
        .{ 3, 2 }, .{ 3, 3 }, .{ 3, 4 },
        .{ 4, 2 }, .{ 4, 3 }, .{ 4, 4 },
    };
    const suffixes = [_][]const u8{ "", "f", "h" };
    var arr: [dims.len * suffixes.len][]const u8 = undefined;
    var idx: usize = 0;
    for (dims) |d| {
        for (suffixes) |s| {
            arr[idx] = std.fmt.comptimePrint("mat{d}x{d}{s}", .{ d[0], d[1], s });
            idx += 1;
        }
    }
    break :blk arr;
};

/// The complete predeclared type-name inventory, for consumers that want the
/// full set (LSP completion; the completeness/no-dup invariant test).
pub const all_type_names =
    scalar_type_names ++
    sampler_names ++
    vec_type_names ++
    mat_type_names ++
    other_type_names ++
    texture_type_names;

test {
    std.testing.refAllDecls(@This());
}
