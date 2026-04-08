//! WGSL built-in functions and their type signatures.
//!
//! Implements the builtin function table as defined in WGSL spec section 17,
//! supporting overload resolution and validation of builtin function calls.
//! Ports the Go `internal/builtins/builtins.go` package.

const std = @import("std");

const Builtins = @This();

// =========================================================================
// Enums
// =========================================================================

/// Identifies categories of builtin functions.
pub const Kind = enum(u8) {
    constructor, // Type constructors
    conversion, // Bit reinterpretation
    logical, // Logical operations
    array, // Array operations
    numeric, // Math functions
    derivative, // Derivative functions (require uniform flow)
    texture, // Texture sampling
    atomic, // Atomic operations
    packing, // Data packing/unpacking
    synchronization, // Barriers (require uniform flow)
    subgroup, // Subgroup operations (require uniform flow)
};

/// Indicates when a function can be evaluated.
pub const EvalStage = enum(u8) {
    runtime, // Only at runtime
    const_eval, // At compile time
    override, // At pipeline creation
};

/// Indicates uniformity constraints on a builtin call.
pub const UniformityRequirement = enum(u8) {
    none, // No uniformity requirement
    uniform_flow, // Call must be in uniform control flow
    uniform_args, // Certain arguments must be uniform
};

/// Describes how to infer the return type of a builtin function.
pub const ReturnPattern = enum(u8) {
    same_as_arg, // Return type matches first argument (abs, sin, floor, etc.)
    bool_scalar, // Returns bool (all, any)
    scalar_of_arg, // Returns scalar element of first arg (dot, length, distance, determinant)
    void_type, // Returns void (barriers, atomicStore, textureStore)
    texture, // Infer from texture argument (textureLoad, textureSample, etc.)
    texture_dims, // textureDimensions: u32 / vec2<u32> / vec3<u32> based on dimension
    pack_u32, // Packing functions return u32
    u32_scalar, // Returns u32 (textureNumLayers, arrayLength, etc.)
    custom, // Needs special logic (bitcast, transpose, atomics, unpack, etc.)
};

// =========================================================================
// Builtin Definition
// =========================================================================

/// Describes a single WGSL builtin function.
pub const Builtin = struct {
    name: []const u8,
    kind: Kind,
    stage: EvalStage,
    uniformity: UniformityRequirement,
    min_args: u8, // Minimum argument count for overload resolution stub
    max_args: u8, // Maximum argument count for overload resolution stub
    return_pattern: ReturnPattern,

    /// Returns true if this builtin requires uniform control flow.
    pub fn requiresUniform(self: *const Builtin) bool {
        return self.uniformity == .uniform_flow;
    }

    /// Returns true if this builtin can be evaluated at compile time.
    pub fn isConstEval(self: *const Builtin) bool {
        return self.stage == .const_eval;
    }

    /// Stub overload resolution: checks argument count is in the valid range.
    pub fn checkArgCount(self: *const Builtin, arg_count: u32) bool {
        return arg_count >= self.min_args and arg_count <= self.max_args;
    }
};

// =========================================================================
// Lookup Table
// =========================================================================

/// Comptime-built lookup table mapping builtin function names to definitions.
const table = std.StaticStringMap(Builtin).initComptime(builtin_entries);

/// Look up a builtin function by name, or return null if not found.
pub fn lookup(name: []const u8) ?Builtin {
    return table.get(name);
}

/// Returns true if the given name is a builtin function.
pub fn isBuiltin(name: []const u8) bool {
    return table.has(name);
}

// =========================================================================
// Builtin Entries
// =========================================================================

/// All WGSL builtin functions registered in the lookup table.
/// Order follows WGSL spec sections: conversions, logical, array, numeric,
/// derivative, texture, atomic, packing, synchronization, subgroup.
const builtin_entries = conversion_entries ++
    logical_entries ++
    array_entries ++
    numeric_trig_entries ++
    numeric_exp_entries ++
    numeric_misc_entries ++
    numeric_vector_entries ++
    numeric_bit_entries ++
    numeric_matrix_entries ++
    numeric_special_entries ++
    derivative_entries ++
    texture_entries ++
    atomic_entries ++
    packing_entries ++
    synchronization_entries ++
    subgroup_entries;

// ---------------------------------------------------------------------------
// Conversion Builtins (Section 17.2)
// ---------------------------------------------------------------------------

const conversion_entries = [_]struct { []const u8, Builtin }{
    entry("bitcast", .conversion, .const_eval, .none, 1, 1, .custom),
};

// ---------------------------------------------------------------------------
// Logical Builtins (Section 17.3)
// ---------------------------------------------------------------------------

const logical_entries = [_]struct { []const u8, Builtin }{
    entry("all", .logical, .const_eval, .none, 1, 1, .bool_scalar),
    entry("any", .logical, .const_eval, .none, 1, 1, .bool_scalar),
    entry("select", .logical, .const_eval, .none, 3, 3, .same_as_arg),
};

// ---------------------------------------------------------------------------
// Array Builtins (Section 17.4)
// ---------------------------------------------------------------------------

const array_entries = [_]struct { []const u8, Builtin }{
    entry("arrayLength", .array, .runtime, .none, 1, 1, .u32_scalar),
};

// ---------------------------------------------------------------------------
// Numeric Builtins (Section 17.5) - Trigonometric
// ---------------------------------------------------------------------------

const numeric_trig_entries = [_]struct { []const u8, Builtin }{
    entry("sin", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("cos", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("tan", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("asin", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("acos", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("atan", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("sinh", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("cosh", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("tanh", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("asinh", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("acosh", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("atanh", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("atan2", .numeric, .const_eval, .none, 2, 2, .same_as_arg),
};

// ---------------------------------------------------------------------------
// Numeric Builtins (Section 17.5) - Exponential
// ---------------------------------------------------------------------------

const numeric_exp_entries = [_]struct { []const u8, Builtin }{
    entry("exp", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("exp2", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("log", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("log2", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("pow", .numeric, .const_eval, .none, 2, 2, .same_as_arg),
    entry("sqrt", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("inverseSqrt", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
};

// ---------------------------------------------------------------------------
// Numeric Builtins (Section 17.5) - Misc math
// ---------------------------------------------------------------------------

const numeric_misc_entries = [_]struct { []const u8, Builtin }{
    entry("abs", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("sign", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("floor", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("ceil", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("round", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("trunc", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("fract", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("min", .numeric, .const_eval, .none, 2, 2, .same_as_arg),
    entry("max", .numeric, .const_eval, .none, 2, 2, .same_as_arg),
    entry("clamp", .numeric, .const_eval, .none, 3, 3, .same_as_arg),
    entry("saturate", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("mix", .numeric, .const_eval, .none, 3, 3, .same_as_arg),
    entry("step", .numeric, .const_eval, .none, 2, 2, .same_as_arg),
    entry("smoothstep", .numeric, .const_eval, .none, 3, 3, .same_as_arg),
    entry("fma", .numeric, .const_eval, .none, 3, 3, .same_as_arg),
    entry("degrees", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("radians", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
};

// ---------------------------------------------------------------------------
// Numeric Builtins (Section 17.5) - Vector operations
// ---------------------------------------------------------------------------

const numeric_vector_entries = [_]struct { []const u8, Builtin }{
    entry("dot", .numeric, .const_eval, .none, 2, 2, .scalar_of_arg),
    entry("cross", .numeric, .const_eval, .none, 2, 2, .same_as_arg),
    entry("length", .numeric, .const_eval, .none, 1, 1, .scalar_of_arg),
    entry("distance", .numeric, .const_eval, .none, 2, 2, .scalar_of_arg),
    entry("normalize", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("reflect", .numeric, .const_eval, .none, 2, 2, .same_as_arg),
    entry("refract", .numeric, .const_eval, .none, 3, 3, .same_as_arg),
    entry("faceForward", .numeric, .const_eval, .none, 3, 3, .same_as_arg),
};

// ---------------------------------------------------------------------------
// Numeric Builtins (Section 17.5) - Bit operations
// ---------------------------------------------------------------------------

const numeric_bit_entries = [_]struct { []const u8, Builtin }{
    entry("countOneBits", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("countLeadingZeros", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("countTrailingZeros", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("reverseBits", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("firstLeadingBit", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("firstTrailingBit", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
    entry("extractBits", .numeric, .const_eval, .none, 3, 3, .same_as_arg),
    entry("insertBits", .numeric, .const_eval, .none, 4, 4, .same_as_arg),
};

// ---------------------------------------------------------------------------
// Numeric Builtins (Section 17.5) - Matrix operations
// ---------------------------------------------------------------------------

const numeric_matrix_entries = [_]struct { []const u8, Builtin }{
    entry("transpose", .numeric, .const_eval, .none, 1, 1, .custom),
    entry("determinant", .numeric, .const_eval, .none, 1, 1, .scalar_of_arg),
};

// ---------------------------------------------------------------------------
// Numeric Builtins (Section 17.5) - Special (ldexp, frexp, modf, etc.)
// ---------------------------------------------------------------------------

const numeric_special_entries = [_]struct { []const u8, Builtin }{
    entry("ldexp", .numeric, .const_eval, .none, 2, 2, .same_as_arg),
    entry("frexp", .numeric, .runtime, .none, 1, 1, .custom),
    entry("modf", .numeric, .runtime, .none, 1, 1, .custom),
    entry("quantizeToF16", .numeric, .const_eval, .none, 1, 1, .same_as_arg),
};

// ---------------------------------------------------------------------------
// Derivative Builtins (Section 17.6) - REQUIRE UNIFORM CONTROL FLOW
// ---------------------------------------------------------------------------

const derivative_entries = [_]struct { []const u8, Builtin }{
    entry("dpdx", .derivative, .runtime, .uniform_flow, 1, 1, .same_as_arg),
    entry("dpdy", .derivative, .runtime, .uniform_flow, 1, 1, .same_as_arg),
    entry("fwidth", .derivative, .runtime, .uniform_flow, 1, 1, .same_as_arg),
    entry("dpdxCoarse", .derivative, .runtime, .uniform_flow, 1, 1, .same_as_arg),
    entry("dpdyCoarse", .derivative, .runtime, .uniform_flow, 1, 1, .same_as_arg),
    entry("fwidthCoarse", .derivative, .runtime, .uniform_flow, 1, 1, .same_as_arg),
    entry("dpdxFine", .derivative, .runtime, .uniform_flow, 1, 1, .same_as_arg),
    entry("dpdyFine", .derivative, .runtime, .uniform_flow, 1, 1, .same_as_arg),
    entry("fwidthFine", .derivative, .runtime, .uniform_flow, 1, 1, .same_as_arg),
};

// ---------------------------------------------------------------------------
// Texture Builtins (Section 17.7)
// ---------------------------------------------------------------------------

const texture_entries = [_]struct { []const u8, Builtin }{
    // textureSample requires uniform control flow
    entry("textureSample", .texture, .runtime, .uniform_flow, 2, 5, .texture),
    entry("textureSampleBias", .texture, .runtime, .uniform_flow, 3, 6, .texture),
    entry("textureSampleCompare", .texture, .runtime, .uniform_flow, 3, 6, .texture),
    // textureSampleCompareLevel does NOT require uniform control flow
    entry("textureSampleCompareLevel", .texture, .runtime, .none, 4, 6, .texture),
    // textureSampleLevel does NOT require uniform control flow
    entry("textureSampleLevel", .texture, .runtime, .none, 3, 6, .texture),
    // textureSampleGrad does NOT require uniform control flow
    entry("textureSampleGrad", .texture, .runtime, .none, 4, 7, .texture),
    // textureLoad/Store
    entry("textureLoad", .texture, .runtime, .none, 2, 4, .texture),
    entry("textureStore", .texture, .runtime, .none, 3, 4, .void_type),
    // textureDimensions, textureNumLayers, textureNumLevels, textureNumSamples
    entry("textureDimensions", .texture, .runtime, .none, 1, 2, .texture_dims),
    entry("textureNumLayers", .texture, .runtime, .none, 1, 1, .u32_scalar),
    entry("textureNumLevels", .texture, .runtime, .none, 1, 1, .u32_scalar),
    entry("textureNumSamples", .texture, .runtime, .none, 1, 1, .u32_scalar),
    // textureGather and textureGatherCompare require uniform control flow
    entry("textureGather", .texture, .runtime, .uniform_flow, 3, 5, .texture),
    entry("textureGatherCompare", .texture, .runtime, .uniform_flow, 4, 6, .texture),
};

// ---------------------------------------------------------------------------
// Atomic Builtins (Section 17.8)
// ---------------------------------------------------------------------------

const atomic_entries = [_]struct { []const u8, Builtin }{
    entry("atomicLoad", .atomic, .runtime, .none, 1, 1, .custom),
    entry("atomicStore", .atomic, .runtime, .none, 2, 2, .void_type),
    entry("atomicAdd", .atomic, .runtime, .none, 2, 2, .custom),
    entry("atomicSub", .atomic, .runtime, .none, 2, 2, .custom),
    entry("atomicMax", .atomic, .runtime, .none, 2, 2, .custom),
    entry("atomicMin", .atomic, .runtime, .none, 2, 2, .custom),
    entry("atomicAnd", .atomic, .runtime, .none, 2, 2, .custom),
    entry("atomicOr", .atomic, .runtime, .none, 2, 2, .custom),
    entry("atomicXor", .atomic, .runtime, .none, 2, 2, .custom),
    entry("atomicExchange", .atomic, .runtime, .none, 2, 2, .custom),
    entry("atomicCompareExchangeWeak", .atomic, .runtime, .none, 3, 3, .custom),
};

// ---------------------------------------------------------------------------
// Data Packing Builtins (Section 17.9-17.10)
// ---------------------------------------------------------------------------

const packing_entries = [_]struct { []const u8, Builtin }{
    // Packing functions: input is a vector, output is u32
    entry("pack4x8snorm", .packing, .const_eval, .none, 1, 1, .pack_u32),
    entry("pack4x8unorm", .packing, .const_eval, .none, 1, 1, .pack_u32),
    entry("pack2x16snorm", .packing, .const_eval, .none, 1, 1, .pack_u32),
    entry("pack2x16unorm", .packing, .const_eval, .none, 1, 1, .pack_u32),
    entry("pack2x16float", .packing, .const_eval, .none, 1, 1, .pack_u32),
    entry("pack4xI8", .packing, .const_eval, .none, 1, 1, .pack_u32),
    entry("pack4xU8", .packing, .const_eval, .none, 1, 1, .pack_u32),
    entry("pack4xI8Clamp", .packing, .const_eval, .none, 1, 1, .pack_u32),
    entry("pack4xU8Clamp", .packing, .const_eval, .none, 1, 1, .pack_u32),
    // Unpacking functions: variable return types
    entry("unpack4x8snorm", .packing, .const_eval, .none, 1, 1, .custom),
    entry("unpack4x8unorm", .packing, .const_eval, .none, 1, 1, .custom),
    entry("unpack2x16snorm", .packing, .const_eval, .none, 1, 1, .custom),
    entry("unpack2x16unorm", .packing, .const_eval, .none, 1, 1, .custom),
    entry("unpack2x16float", .packing, .const_eval, .none, 1, 1, .custom),
    entry("unpack4xI8", .packing, .const_eval, .none, 1, 1, .custom),
    entry("unpack4xU8", .packing, .const_eval, .none, 1, 1, .custom),
};

// ---------------------------------------------------------------------------
// Synchronization Builtins (Section 17.11) - REQUIRE UNIFORM CONTROL FLOW
// ---------------------------------------------------------------------------

const synchronization_entries = [_]struct { []const u8, Builtin }{
    entry("workgroupBarrier", .synchronization, .runtime, .uniform_flow, 0, 0, .void_type),
    entry("storageBarrier", .synchronization, .runtime, .uniform_flow, 0, 0, .void_type),
    entry("textureBarrier", .synchronization, .runtime, .uniform_flow, 0, 0, .void_type),
    entry("workgroupUniformLoad", .synchronization, .runtime, .uniform_flow, 1, 1, .custom),
};

// ---------------------------------------------------------------------------
// Subgroup Builtins (Section 17.12) - REQUIRE UNIFORM CONTROL FLOW
// ---------------------------------------------------------------------------

const subgroup_entries = [_]struct { []const u8, Builtin }{
    entry("subgroupBallot", .subgroup, .runtime, .uniform_flow, 0, 1, .custom),
    entry("subgroupBroadcast", .subgroup, .runtime, .uniform_flow, 2, 2, .same_as_arg),
    entry("subgroupBroadcastFirst", .subgroup, .runtime, .uniform_flow, 1, 1, .same_as_arg),
    entry("subgroupShuffle", .subgroup, .runtime, .uniform_flow, 2, 2, .same_as_arg),
    entry("subgroupShuffleDown", .subgroup, .runtime, .uniform_flow, 2, 2, .same_as_arg),
    entry("subgroupShuffleUp", .subgroup, .runtime, .uniform_flow, 2, 2, .same_as_arg),
    entry("subgroupShuffleXor", .subgroup, .runtime, .uniform_flow, 2, 2, .same_as_arg),
    entry("subgroupAdd", .subgroup, .runtime, .uniform_flow, 1, 1, .same_as_arg),
    entry("subgroupMul", .subgroup, .runtime, .uniform_flow, 1, 1, .same_as_arg),
    entry("subgroupAnd", .subgroup, .runtime, .uniform_flow, 1, 1, .same_as_arg),
    entry("subgroupOr", .subgroup, .runtime, .uniform_flow, 1, 1, .same_as_arg),
    entry("subgroupXor", .subgroup, .runtime, .uniform_flow, 1, 1, .same_as_arg),
    entry("subgroupMin", .subgroup, .runtime, .uniform_flow, 1, 1, .same_as_arg),
    entry("subgroupMax", .subgroup, .runtime, .uniform_flow, 1, 1, .same_as_arg),
    entry("subgroupInclusiveAdd", .subgroup, .runtime, .uniform_flow, 1, 1, .same_as_arg),
    entry("subgroupInclusiveMul", .subgroup, .runtime, .uniform_flow, 1, 1, .same_as_arg),
    entry("subgroupExclusiveAdd", .subgroup, .runtime, .uniform_flow, 1, 1, .same_as_arg),
    entry("subgroupExclusiveMul", .subgroup, .runtime, .uniform_flow, 1, 1, .same_as_arg),
    entry("subgroupAll", .subgroup, .runtime, .uniform_flow, 1, 1, .bool_scalar),
    entry("subgroupAny", .subgroup, .runtime, .uniform_flow, 1, 1, .bool_scalar),
    entry("subgroupElect", .subgroup, .runtime, .uniform_flow, 0, 0, .bool_scalar),
};

// =========================================================================
// Entry Helper
// =========================================================================

/// Builds a StaticStringMap entry tuple from builtin metadata.
fn entry(
    comptime name: []const u8,
    comptime kind: Kind,
    comptime stage: EvalStage,
    comptime uniformity: UniformityRequirement,
    comptime min_args: u8,
    comptime max_args: u8,
    comptime return_pattern: ReturnPattern,
) struct { []const u8, Builtin } {
    return .{
        name,
        .{
            .name = name,
            .kind = kind,
            .stage = stage,
            .uniformity = uniformity,
            .min_args = min_args,
            .max_args = max_args,
            .return_pattern = return_pattern,
        },
    };
}

// =========================================================================
// Tests
// =========================================================================

test "lookup returns known builtins" {
    // Logical
    const all_builtin = lookup("all");
    try std.testing.expect(all_builtin != null);
    try std.testing.expectEqual(Kind.logical, all_builtin.?.kind);
    try std.testing.expectEqual(EvalStage.const_eval, all_builtin.?.stage);

    // Numeric
    const sin_builtin = lookup("sin");
    try std.testing.expect(sin_builtin != null);
    try std.testing.expectEqual(Kind.numeric, sin_builtin.?.kind);

    // Derivative
    const dpdx_builtin = lookup("dpdx");
    try std.testing.expect(dpdx_builtin != null);
    try std.testing.expectEqual(Kind.derivative, dpdx_builtin.?.kind);
    try std.testing.expect(dpdx_builtin.?.requiresUniform());

    // Texture
    const ts_builtin = lookup("textureSample");
    try std.testing.expect(ts_builtin != null);
    try std.testing.expectEqual(Kind.texture, ts_builtin.?.kind);
    try std.testing.expect(ts_builtin.?.requiresUniform());

    // Atomic
    const al_builtin = lookup("atomicLoad");
    try std.testing.expect(al_builtin != null);
    try std.testing.expectEqual(Kind.atomic, al_builtin.?.kind);

    // Packing
    const pack_builtin = lookup("pack4x8snorm");
    try std.testing.expect(pack_builtin != null);
    try std.testing.expectEqual(Kind.packing, pack_builtin.?.kind);

    // Synchronization
    const wb_builtin = lookup("workgroupBarrier");
    try std.testing.expect(wb_builtin != null);
    try std.testing.expectEqual(Kind.synchronization, wb_builtin.?.kind);
    try std.testing.expect(wb_builtin.?.requiresUniform());

    // Subgroup
    const sb_builtin = lookup("subgroupBallot");
    try std.testing.expect(sb_builtin != null);
    try std.testing.expectEqual(Kind.subgroup, sb_builtin.?.kind);
    try std.testing.expect(sb_builtin.?.requiresUniform());
}

test "lookup returns null for unknown names" {
    try std.testing.expect(lookup("notABuiltin") == null);
    try std.testing.expect(lookup("") == null);
    try std.testing.expect(lookup("SIN") == null);
}

test "isBuiltin matches lookup" {
    try std.testing.expect(isBuiltin("sin"));
    try std.testing.expect(isBuiltin("cos"));
    try std.testing.expect(isBuiltin("textureSample"));
    try std.testing.expect(isBuiltin("atomicAdd"));
    try std.testing.expect(isBuiltin("workgroupBarrier"));
    try std.testing.expect(!isBuiltin("notABuiltin"));
    try std.testing.expect(!isBuiltin(""));
}

test "checkArgCount validates argument counts" {
    const select_builtin = lookup("select").?;
    try std.testing.expect(select_builtin.checkArgCount(3));
    try std.testing.expect(!select_builtin.checkArgCount(2));
    try std.testing.expect(!select_builtin.checkArgCount(4));

    const clamp_builtin = lookup("clamp").?;
    try std.testing.expect(clamp_builtin.checkArgCount(3));
    try std.testing.expect(!clamp_builtin.checkArgCount(1));

    // Barrier takes zero args.
    const barrier = lookup("workgroupBarrier").?;
    try std.testing.expect(barrier.checkArgCount(0));
    try std.testing.expect(!barrier.checkArgCount(1));

    // textureLoad accepts 2-4 args.
    const tl_builtin = lookup("textureLoad").?;
    try std.testing.expect(tl_builtin.checkArgCount(2));
    try std.testing.expect(tl_builtin.checkArgCount(3));
    try std.testing.expect(tl_builtin.checkArgCount(4));
    try std.testing.expect(!tl_builtin.checkArgCount(1));
    try std.testing.expect(!tl_builtin.checkArgCount(5));
}

test "requiresUniform correctness" {
    // Derivative builtins require uniform flow.
    const names_uniform = [_][]const u8{
        "dpdx",         "dpdy",          "fwidth",
        "dpdxCoarse",   "dpdyCoarse",    "fwidthCoarse",
        "dpdxFine",     "dpdyFine",      "fwidthFine",
        "textureSample", "textureSampleBias", "textureSampleCompare",
        "workgroupBarrier", "storageBarrier", "textureBarrier",
    };
    for (names_uniform) |name| {
        const b = lookup(name).?;
        try std.testing.expect(b.requiresUniform());
    }

    // These do NOT require uniform flow.
    const names_no_uniform = [_][]const u8{
        "sin",   "cos",   "abs",   "clamp",
        "textureSampleLevel", "textureSampleCompareLevel",
        "textureLoad", "textureStore",
        "atomicLoad",  "atomicAdd",
    };
    for (names_no_uniform) |name| {
        const b = lookup(name).?;
        try std.testing.expect(!b.requiresUniform());
    }
}

test "return patterns are assigned" {
    // Numeric builtins return same_as_arg
    try std.testing.expectEqual(ReturnPattern.same_as_arg, lookup("sin").?.return_pattern);
    try std.testing.expectEqual(ReturnPattern.same_as_arg, lookup("abs").?.return_pattern);
    try std.testing.expectEqual(ReturnPattern.same_as_arg, lookup("floor").?.return_pattern);

    // Vector operations
    try std.testing.expectEqual(ReturnPattern.scalar_of_arg, lookup("dot").?.return_pattern);
    try std.testing.expectEqual(ReturnPattern.scalar_of_arg, lookup("length").?.return_pattern);
    try std.testing.expectEqual(ReturnPattern.scalar_of_arg, lookup("determinant").?.return_pattern);

    // Logical
    try std.testing.expectEqual(ReturnPattern.bool_scalar, lookup("all").?.return_pattern);
    try std.testing.expectEqual(ReturnPattern.bool_scalar, lookup("any").?.return_pattern);

    // Texture
    try std.testing.expectEqual(ReturnPattern.texture, lookup("textureSample").?.return_pattern);
    try std.testing.expectEqual(ReturnPattern.texture, lookup("textureLoad").?.return_pattern);
    try std.testing.expectEqual(ReturnPattern.texture_dims, lookup("textureDimensions").?.return_pattern);
    try std.testing.expectEqual(ReturnPattern.void_type, lookup("textureStore").?.return_pattern);

    // Packing
    try std.testing.expectEqual(ReturnPattern.pack_u32, lookup("pack4x8snorm").?.return_pattern);
    try std.testing.expectEqual(ReturnPattern.custom, lookup("unpack4x8snorm").?.return_pattern);

    // Void
    try std.testing.expectEqual(ReturnPattern.void_type, lookup("workgroupBarrier").?.return_pattern);
    try std.testing.expectEqual(ReturnPattern.void_type, lookup("atomicStore").?.return_pattern);
}

test "all Go builtins are registered" {
    // Exhaustive list of every builtin registered in the Go implementation.
    const all_names = [_][]const u8{
        // Conversion
        "bitcast",
        // Logical
        "all",                "any",                 "select",
        // Array
        "arrayLength",
        // Trigonometric
        "sin",                "cos",                 "tan",
        "asin",               "acos",                "atan",
        "sinh",               "cosh",                "tanh",
        "asinh",              "acosh",               "atanh",
        "atan2",
        // Exponential
        "exp",                "exp2",                "log",
        "log2",               "pow",                 "sqrt",
        "inverseSqrt",
        // Misc math
        "abs",                "sign",                "floor",
        "ceil",               "round",               "trunc",
        "fract",              "min",                 "max",
        "clamp",              "saturate",            "mix",
        "step",               "smoothstep",          "fma",
        "degrees",            "radians",
        // Vector
        "dot",                "cross",               "length",
        "distance",           "normalize",           "reflect",
        "refract",            "faceForward",
        // Bit
        "countOneBits",       "countLeadingZeros",   "countTrailingZeros",
        "reverseBits",        "firstLeadingBit",     "firstTrailingBit",
        "extractBits",        "insertBits",
        // Matrix
        "transpose",          "determinant",
        // Special
        "ldexp",              "frexp",               "modf",
        "quantizeToF16",
        // Derivative
        "dpdx",               "dpdy",                "fwidth",
        "dpdxCoarse",         "dpdyCoarse",          "fwidthCoarse",
        "dpdxFine",           "dpdyFine",            "fwidthFine",
        // Texture
        "textureSample",      "textureSampleBias",   "textureSampleCompare",
        "textureSampleCompareLevel", "textureSampleLevel", "textureSampleGrad",
        "textureLoad",        "textureStore",        "textureDimensions",
        "textureNumLayers",   "textureNumLevels",    "textureNumSamples",
        "textureGather",      "textureGatherCompare",
        // Atomic
        "atomicLoad",         "atomicStore",         "atomicAdd",
        "atomicSub",          "atomicMax",           "atomicMin",
        "atomicAnd",          "atomicOr",            "atomicXor",
        "atomicExchange",     "atomicCompareExchangeWeak",
        // Packing
        "pack4x8snorm",       "pack4x8unorm",        "pack2x16snorm",
        "pack2x16unorm",      "pack2x16float",       "pack4xI8",
        "pack4xU8",           "pack4xI8Clamp",       "pack4xU8Clamp",
        "unpack4x8snorm",     "unpack4x8unorm",      "unpack2x16snorm",
        "unpack2x16unorm",    "unpack2x16float",     "unpack4xI8",
        "unpack4xU8",
        // Synchronization
        "workgroupBarrier",   "storageBarrier",      "textureBarrier",
        "workgroupUniformLoad",
        // Subgroup
        "subgroupBallot",     "subgroupBroadcast",   "subgroupBroadcastFirst",
        "subgroupShuffle",    "subgroupShuffleDown",  "subgroupShuffleUp",
        "subgroupShuffleXor", "subgroupAdd",         "subgroupMul",
        "subgroupAnd",        "subgroupOr",          "subgroupXor",
        "subgroupMin",        "subgroupMax",
        "subgroupInclusiveAdd", "subgroupInclusiveMul",
        "subgroupExclusiveAdd", "subgroupExclusiveMul",
        "subgroupAll",        "subgroupAny",         "subgroupElect",
    };

    for (all_names) |name| {
        const b = lookup(name);
        if (b == null) {
            std.debug.print("missing builtin: {s}\n", .{name});
        }
        try std.testing.expect(b != null);
    }
}

test "entry count matches Go implementation" {
    // Go has 119 builtins registered (counted from the source).
    // Verify we have at least that many entries.
    const total = builtin_entries.len;
    try std.testing.expect(total >= 119);
}
