//! Tests for `src/Predeclared.zig` — the single source of truth for the
//! WGSL predeclared-type-name inventory (scalars, samplers, vector/matrix
//! shorthands, texture types, address spaces, access modes).
//!
//! These pin the inventory that the Parser, CstLower, Validator, and the LSP
//! completion handler all consult. The historically drift-prone entry is
//! `texture_external` (known to CstLower but previously missing from the
//! Parser's texture table); it is pinned explicitly below.

const std = @import("std");
const wgslender = @import("wgslender");

const Predeclared = wgslender.Predeclared;
const Ast = wgslender.Ast;

const TextureCase = struct {
    name: []const u8,
    kind: ?Ast.TextureKind,
    dim: Ast.TextureDimension = .@"2d",
};

test "predeclared: textureInfo resolves every texture spelling" {
    const cases = [_]TextureCase{
        .{ .name = "texture_1d", .kind = .sampled, .dim = .@"1d" },
        .{ .name = "texture_2d", .kind = .sampled, .dim = .@"2d" },
        .{ .name = "texture_2d_array", .kind = .sampled, .dim = .@"2d_array" },
        .{ .name = "texture_3d", .kind = .sampled, .dim = .@"3d" },
        .{ .name = "texture_cube", .kind = .sampled, .dim = .cube },
        .{ .name = "texture_cube_array", .kind = .sampled, .dim = .cube_array },
        .{ .name = "texture_multisampled_2d", .kind = .multisampled, .dim = .@"2d" },
        // The drift-fix pin: external must be present in the shared inventory.
        .{ .name = "texture_external", .kind = .external, .dim = .@"2d" },
        .{ .name = "texture_storage_1d", .kind = .storage, .dim = .@"1d" },
        .{ .name = "texture_storage_2d", .kind = .storage, .dim = .@"2d" },
        .{ .name = "texture_storage_2d_array", .kind = .storage, .dim = .@"2d_array" },
        .{ .name = "texture_storage_3d", .kind = .storage, .dim = .@"3d" },
        .{ .name = "texture_depth_2d", .kind = .depth, .dim = .@"2d" },
        .{ .name = "texture_depth_2d_array", .kind = .depth, .dim = .@"2d_array" },
        .{ .name = "texture_depth_cube", .kind = .depth, .dim = .cube },
        .{ .name = "texture_depth_cube_array", .kind = .depth, .dim = .cube_array },
        .{ .name = "texture_depth_multisampled_2d", .kind = .depth_multisampled, .dim = .@"2d" },
        // Negatives.
        .{ .name = "texture_foo", .kind = null },
        .{ .name = "texture", .kind = null },
        .{ .name = "vec3", .kind = null },
        .{ .name = "f32", .kind = null },
    };
    for (cases) |c| {
        const got = Predeclared.textureInfo(c.name);
        if (c.kind) |want_kind| {
            try std.testing.expect(got != null);
            try std.testing.expectEqual(want_kind, got.?.kind);
            try std.testing.expectEqual(c.dim, got.?.dim);
        } else {
            try std.testing.expect(got == null);
        }
    }
}

test "predeclared: addressSpace resolves the parseable spaces" {
    try std.testing.expectEqual(Ast.AddressSpace.function, Predeclared.addressSpace("function").?);
    try std.testing.expectEqual(Ast.AddressSpace.private, Predeclared.addressSpace("private").?);
    try std.testing.expectEqual(Ast.AddressSpace.workgroup, Predeclared.addressSpace("workgroup").?);
    try std.testing.expectEqual(Ast.AddressSpace.uniform, Predeclared.addressSpace("uniform").?);
    try std.testing.expectEqual(Ast.AddressSpace.storage, Predeclared.addressSpace("storage").?);
    try std.testing.expect(Predeclared.addressSpace("handle") == null);
    try std.testing.expect(Predeclared.addressSpace("nope") == null);
}

test "predeclared: accessMode resolves the three modes" {
    try std.testing.expectEqual(Ast.AccessMode.read, Predeclared.accessMode("read").?);
    try std.testing.expectEqual(Ast.AccessMode.write, Predeclared.accessMode("write").?);
    try std.testing.expectEqual(Ast.AccessMode.read_write, Predeclared.accessMode("read_write").?);
    try std.testing.expect(Predeclared.accessMode("readwrite") == null);
}

test "predeclared: isVecName / isMatName" {
    try std.testing.expect(Predeclared.isVecName("vec2"));
    try std.testing.expect(Predeclared.isVecName("vec3"));
    try std.testing.expect(Predeclared.isVecName("vec4"));
    try std.testing.expect(!Predeclared.isVecName("vec1"));
    try std.testing.expect(!Predeclared.isVecName("vec5"));
    try std.testing.expect(!Predeclared.isVecName("vector"));
    try std.testing.expect(!Predeclared.isVecName("vec3f"));

    try std.testing.expect(Predeclared.isMatName("mat2x2"));
    try std.testing.expect(Predeclared.isMatName("mat4x3"));
    try std.testing.expect(!Predeclared.isMatName("mat2x"));
    try std.testing.expect(!Predeclared.isMatName("matrix"));
    try std.testing.expect(!Predeclared.isMatName("mat2x2f"));
}

test "predeclared: parseVecShorthand descriptors" {
    try std.testing.expectEqual(Predeclared.VecShorthand{ .width = 3, .elem = .f32 }, Predeclared.parseVecShorthand("vec3f").?);
    try std.testing.expectEqual(Predeclared.VecShorthand{ .width = 2, .elem = .i32 }, Predeclared.parseVecShorthand("vec2i").?);
    try std.testing.expectEqual(Predeclared.VecShorthand{ .width = 4, .elem = .u32 }, Predeclared.parseVecShorthand("vec4u").?);
    try std.testing.expectEqual(Predeclared.VecShorthand{ .width = 3, .elem = .f16 }, Predeclared.parseVecShorthand("vec3h").?);
    try std.testing.expectEqual(Predeclared.VecShorthand{ .width = 3, .elem = null }, Predeclared.parseVecShorthand("vec3").?);
    try std.testing.expect(Predeclared.parseVecShorthand("vec5f") == null);
    try std.testing.expect(Predeclared.parseVecShorthand("vec3x") == null);
    try std.testing.expect(Predeclared.parseVecShorthand("vec3ff") == null);
    try std.testing.expect(Predeclared.parseVecShorthand("ve3") == null);
    try std.testing.expect(Predeclared.parseVecShorthand("vec3b") == null); // no bool shorthand in WGSL
}

test "predeclared: parseMatShorthand descriptors" {
    try std.testing.expectEqual(Predeclared.MatShorthand{ .cols = 2, .rows = 2, .elem = .f32 }, Predeclared.parseMatShorthand("mat2x2f").?);
    try std.testing.expectEqual(Predeclared.MatShorthand{ .cols = 4, .rows = 3, .elem = .f16 }, Predeclared.parseMatShorthand("mat4x3h").?);
    try std.testing.expectEqual(Predeclared.MatShorthand{ .cols = 2, .rows = 2, .elem = null }, Predeclared.parseMatShorthand("mat2x2").?);
    try std.testing.expect(Predeclared.parseMatShorthand("mat2x2i") == null); // matrices are float-only
    try std.testing.expect(Predeclared.parseMatShorthand("mat5x2f") == null);
    try std.testing.expect(Predeclared.parseMatShorthand("mat2x2ff") == null);
}

test "predeclared: arityOfTypeConstructor" {
    try std.testing.expectEqual(@as(?usize, 2), Predeclared.arityOfTypeConstructor("vec2"));
    try std.testing.expectEqual(@as(?usize, 3), Predeclared.arityOfTypeConstructor("vec3f"));
    try std.testing.expectEqual(@as(?usize, 2), Predeclared.arityOfTypeConstructor("mat2x3f"));
    try std.testing.expectEqual(@as(?usize, 4), Predeclared.arityOfTypeConstructor("mat4x4"));
    try std.testing.expect(Predeclared.arityOfTypeConstructor("f32") == null);
    try std.testing.expect(Predeclared.arityOfTypeConstructor("array") == null);
}

fn listContains(list: []const []const u8, needle: []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, needle)) return true;
    return false;
}

test "predeclared: all_type_names completeness and no duplicates" {
    const names = Predeclared.all_type_names;
    // Representative membership across every family.
    const must_have = [_][]const u8{
        "bool", "i32", "u32", "f32", "f16",
        "sampler", "sampler_comparison",
        "vec3", "vec3f", "vec2i", "vec4h",
        "mat4x4", "mat2x2f", "mat3x4h",
        "array",
        "texture_2d", "texture_external", "texture_depth_2d", "texture_storage_2d",
    };
    for (must_have) |name| {
        try std.testing.expect(listContains(&names, name));
    }
    // No duplicates.
    for (names, 0..) |a, i| {
        for (names[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a, b)) {
                std.debug.print("duplicate predeclared type name: {s}\n", .{a});
                return error.DuplicateName;
            }
        }
    }
}
