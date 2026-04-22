//! WGSL built-in functions and their type signatures.
//!
//! Implements the builtin function table as defined in WGSL spec section 17,
//! supporting overload resolution and validation of builtin function calls.

const std = @import("std");
const Overload = @import("Overload.zig");
const Types = @import("Types.zig");

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
    must_use: bool, // Return value must be consumed (not called as statement)
    /// Declarative overload signatures. Every callable builtin populates
    /// this table; `Validator.checkBuiltinCall` asserts non-empty and
    /// routes through `Overload.resolve`. `bitcast` is the only exception
    /// — it dispatches from its own block with template-seeded bindings
    /// (see `bitcast_to_*_sigs` below), so its `lookup().overloads` is
    /// intentionally empty.
    overloads: []const Overload.OverloadSig = &.{},

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

/// Side table of declarative overload signatures. Kept separate from
/// `table` so the core entries remain simple tuples; `lookup()` merges
/// in the signatures when present. See `Overload.zig` for the signature
/// DSL and solver.
const sig_table = std.StaticStringMap([]const Overload.OverloadSig).initComptime(sig_entries);

/// Look up a builtin function by name, or return null if not found.
pub fn lookup(name: []const u8) ?Builtin {
    var b = table.get(name) orelse return null;
    if (sig_table.get(name)) |sigs| {
        b.overloads = sigs;
    }
    return b;
}

/// Returns true if the given name is a builtin function.
pub fn isBuiltin(name: []const u8) bool {
    return table.has(name);
}

/// Returns a slice of all builtin function name strings.
pub fn names() []const []const u8 {
    return table.keys();
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
    entry("dot4I8Packed", .numeric, .const_eval, .none, 2, 2, .custom),
    entry("dot4U8Packed", .numeric, .const_eval, .none, 2, 2, .custom),
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
    entry("textureSampleBaseClampToEdge", .texture, .runtime, .none, 3, 3, .texture),
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
    // Quad operations (Section 17.13)
    entry("quadBroadcast", .subgroup, .runtime, .uniform_flow, 2, 2, .same_as_arg),
    entry("quadSwapDiagonal", .subgroup, .runtime, .uniform_flow, 1, 1, .same_as_arg),
    entry("quadSwapX", .subgroup, .runtime, .uniform_flow, 1, 1, .same_as_arg),
    entry("quadSwapY", .subgroup, .runtime, .uniform_flow, 1, 1, .same_as_arg),
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
            // Per WGSL spec, all builtin functions with a return value are @must_use.
            .must_use = return_pattern != .void_type,
        },
    };
}

// =========================================================================
// Documentation Table (for LSP hover)
// =========================================================================

/// Documentation for a WGSL builtin function, used by the LSP hover feature.
pub const BuiltinDoc = struct {
    /// Generic signature from the WGSL spec (e.g., "fn sin(e: T) -> T").
    signature: []const u8,
    /// One-line description of the function.
    description: []const u8,
    /// Type constraint or overload info (e.g., "T is f32, f16, vecN<f32>, or vecN<f16>").
    type_constraint: []const u8,
};

/// Look up documentation for a builtin function by name.
pub fn doc(name: []const u8) ?BuiltinDoc {
    return doc_table.get(name);
}

const doc_table = std.StaticStringMap(BuiltinDoc).initComptime(doc_entries);

const doc_entries = conversion_doc ++
    logical_doc ++
    array_doc ++
    numeric_trig_doc ++
    numeric_exp_doc ++
    numeric_misc_doc ++
    numeric_vector_doc ++
    numeric_bit_doc ++
    numeric_matrix_doc ++
    numeric_special_doc ++
    derivative_doc ++
    texture_doc ++
    atomic_doc ++
    packing_doc ++
    synchronization_doc ++
    subgroup_doc;

fn docEntry(
    comptime name: []const u8,
    comptime signature: []const u8,
    comptime description: []const u8,
    comptime type_constraint: []const u8,
) struct { []const u8, BuiltinDoc } {
    return .{ name, .{ .signature = signature, .description = description, .type_constraint = type_constraint } };
}

const T_FLOAT = "T is f32, f16, vecN<f32>, or vecN<f16>";
const T_FLOAT_INT = "T is f32, f16, i32, u32, vecN<f32>, vecN<f16>, vecN<i32>, or vecN<u32>";
const T_INT = "T is i32, u32, vecN<i32>, or vecN<u32>";
const T_NUMERIC = "T is f32, f16, i32, u32, or vecN of these";

// --- Conversion ---
const conversion_doc = [_]struct { []const u8, BuiltinDoc }{
    docEntry("bitcast", "fn bitcast<T>(e: S) -> T", "Reinterprets the bits of the value as the target type.", "T and S must have the same bit width"),
};

// --- Logical ---
const logical_doc = [_]struct { []const u8, BuiltinDoc }{
    docEntry("all", "fn all(e: vecN<bool>) -> bool", "Returns true if every component of e is true.", ""),
    docEntry("any", "fn any(e: vecN<bool>) -> bool", "Returns true if any component of e is true.", ""),
    docEntry("select", "fn select(f: T, t: T, cond: bool) -> T", "Returns t when cond is true, and f otherwise.", T_NUMERIC),
};

// --- Array ---
const array_doc = [_]struct { []const u8, BuiltinDoc }{
    docEntry("arrayLength", "fn arrayLength(p: ptr<storage, array<T>>) -> u32", "Returns the number of elements in the runtime-sized array.", ""),
};

// --- Numeric: Trigonometric ---
const numeric_trig_doc = [_]struct { []const u8, BuiltinDoc }{
    docEntry("sin", "fn sin(e: T) -> T", "Returns the sine of e (radians).", T_FLOAT),
    docEntry("cos", "fn cos(e: T) -> T", "Returns the cosine of e (radians).", T_FLOAT),
    docEntry("tan", "fn tan(e: T) -> T", "Returns the tangent of e (radians).", T_FLOAT),
    docEntry("asin", "fn asin(e: T) -> T", "Returns the arc sine of e. Result in [-pi/2, pi/2].", T_FLOAT),
    docEntry("acos", "fn acos(e: T) -> T", "Returns the arc cosine of e. Result in [0, pi].", T_FLOAT),
    docEntry("atan", "fn atan(e: T) -> T", "Returns the arc tangent of e. Result in [-pi/2, pi/2].", T_FLOAT),
    docEntry("sinh", "fn sinh(e: T) -> T", "Returns the hyperbolic sine of e.", T_FLOAT),
    docEntry("cosh", "fn cosh(e: T) -> T", "Returns the hyperbolic cosine of e.", T_FLOAT),
    docEntry("tanh", "fn tanh(e: T) -> T", "Returns the hyperbolic tangent of e.", T_FLOAT),
    docEntry("asinh", "fn asinh(e: T) -> T", "Returns the inverse hyperbolic sine of e.", T_FLOAT),
    docEntry("acosh", "fn acosh(e: T) -> T", "Returns the inverse hyperbolic cosine of e.", T_FLOAT),
    docEntry("atanh", "fn atanh(e: T) -> T", "Returns the inverse hyperbolic tangent of e.", T_FLOAT),
    docEntry("atan2", "fn atan2(y: T, x: T) -> T", "Returns the arc tangent of y/x. Result in [-pi, pi].", T_FLOAT),
};

// --- Numeric: Exponential ---
const numeric_exp_doc = [_]struct { []const u8, BuiltinDoc }{
    docEntry("exp", "fn exp(e: T) -> T", "Returns the natural exponentiation e^e.", T_FLOAT),
    docEntry("exp2", "fn exp2(e: T) -> T", "Returns 2 raised to the power e.", T_FLOAT),
    docEntry("log", "fn log(e: T) -> T", "Returns the natural logarithm of e.", T_FLOAT),
    docEntry("log2", "fn log2(e: T) -> T", "Returns the base-2 logarithm of e.", T_FLOAT),
    docEntry("pow", "fn pow(base: T, exponent: T) -> T", "Returns base raised to the power exponent.", T_FLOAT),
    docEntry("sqrt", "fn sqrt(e: T) -> T", "Returns the square root of e.", T_FLOAT),
    docEntry("inverseSqrt", "fn inverseSqrt(e: T) -> T", "Returns the reciprocal of the square root of e.", T_FLOAT),
};

// --- Numeric: Misc math ---
const numeric_misc_doc = [_]struct { []const u8, BuiltinDoc }{
    docEntry("abs", "fn abs(e: T) -> T", "Returns the absolute value of e.", T_FLOAT_INT),
    docEntry("sign", "fn sign(e: T) -> T", "Returns the sign of e: -1, 0, or 1.", T_FLOAT_INT),
    docEntry("floor", "fn floor(e: T) -> T", "Returns the floor of e (largest integer <= e).", T_FLOAT),
    docEntry("ceil", "fn ceil(e: T) -> T", "Returns the ceiling of e (smallest integer >= e).", T_FLOAT),
    docEntry("round", "fn round(e: T) -> T", "Returns e rounded to the nearest integer.", T_FLOAT),
    docEntry("trunc", "fn trunc(e: T) -> T", "Returns the integer part of e, removing fractional digits.", T_FLOAT),
    docEntry("fract", "fn fract(e: T) -> T", "Returns the fractional part of e (e - floor(e)).", T_FLOAT),
    docEntry("min", "fn min(e1: T, e2: T) -> T", "Returns the minimum of e1 and e2.", T_FLOAT_INT),
    docEntry("max", "fn max(e1: T, e2: T) -> T", "Returns the maximum of e1 and e2.", T_FLOAT_INT),
    docEntry("clamp", "fn clamp(e: T, low: T, high: T) -> T", "Restricts e to the range [low, high].", T_FLOAT_INT),
    docEntry("saturate", "fn saturate(e: T) -> T", "Clamps e to the range [0.0, 1.0].", T_FLOAT),
    docEntry("mix", "fn mix(e1: T, e2: T, e3: T) -> T", "Returns the linear blend e1*(1-e3) + e2*e3.", T_FLOAT),
    docEntry("step", "fn step(edge: T, x: T) -> T", "Returns 0.0 if x < edge, otherwise 1.0.", T_FLOAT),
    docEntry("smoothstep", "fn smoothstep(low: T, high: T, x: T) -> T", "Returns smooth Hermite interpolation between 0 and 1.", T_FLOAT),
    docEntry("fma", "fn fma(e1: T, e2: T, e3: T) -> T", "Returns e1 * e2 + e3 (fused multiply-add).", T_FLOAT),
    docEntry("degrees", "fn degrees(e: T) -> T", "Converts radians to degrees.", T_FLOAT),
    docEntry("radians", "fn radians(e: T) -> T", "Converts degrees to radians.", T_FLOAT),
};

// --- Numeric: Vector ---
const numeric_vector_doc = [_]struct { []const u8, BuiltinDoc }{
    docEntry("dot", "fn dot(e1: vecN<T>, e2: vecN<T>) -> T", "Returns the dot product of e1 and e2.", "T is f32, f16"),
    docEntry("dot4I8Packed", "fn dot4I8Packed(e1: u32, e2: u32) -> i32", "Interprets inputs as vectors of four 8-bit signed integers and returns the signed dot product.", "Requires packed_4x8_integer_dot_product"),
    docEntry("dot4U8Packed", "fn dot4U8Packed(e1: u32, e2: u32) -> u32", "Interprets inputs as vectors of four 8-bit unsigned integers and returns the unsigned dot product.", "Requires packed_4x8_integer_dot_product"),
    docEntry("cross", "fn cross(e1: vec3<T>, e2: vec3<T>) -> vec3<T>", "Returns the cross product of e1 and e2.", "T is f32, f16"),
    docEntry("length", "fn length(e: vecN<T>) -> T", "Returns the length (magnitude) of e.", "T is f32, f16"),
    docEntry("distance", "fn distance(e1: vecN<T>, e2: vecN<T>) -> T", "Returns the distance between e1 and e2.", "T is f32, f16"),
    docEntry("normalize", "fn normalize(e: vecN<T>) -> vecN<T>", "Returns the unit vector in the direction of e.", "T is f32, f16"),
    docEntry("reflect", "fn reflect(e1: vecN<T>, e2: vecN<T>) -> vecN<T>", "Returns the reflection direction for incident e1 and normal e2.", "T is f32, f16"),
    docEntry("refract", "fn refract(e1: vecN<T>, e2: vecN<T>, e3: T) -> vecN<T>", "Returns the refraction vector for incident e1, normal e2, and ratio e3.", "T is f32, f16"),
    docEntry("faceForward", "fn faceForward(e1: vecN<T>, e2: vecN<T>, e3: vecN<T>) -> vecN<T>", "Returns e1 if dot(e2,e3) < 0, otherwise -e1.", "T is f32, f16"),
};

// --- Numeric: Bit operations ---
const numeric_bit_doc = [_]struct { []const u8, BuiltinDoc }{
    docEntry("countOneBits", "fn countOneBits(e: T) -> T", "Returns the number of 1 bits in the binary representation of e.", T_INT),
    docEntry("countLeadingZeros", "fn countLeadingZeros(e: T) -> T", "Returns the number of leading zero bits in e.", T_INT),
    docEntry("countTrailingZeros", "fn countTrailingZeros(e: T) -> T", "Returns the number of trailing zero bits in e.", T_INT),
    docEntry("reverseBits", "fn reverseBits(e: T) -> T", "Returns e with its bits reversed.", T_INT),
    docEntry("firstLeadingBit", "fn firstLeadingBit(e: T) -> T", "Returns the bit position of the most significant 1 bit, or -1/0xFFFFFFFF.", T_INT),
    docEntry("firstTrailingBit", "fn firstTrailingBit(e: T) -> T", "Returns the bit position of the least significant 1 bit, or -1/0xFFFFFFFF.", T_INT),
    docEntry("extractBits", "fn extractBits(e: T, offset: u32, count: u32) -> T", "Extracts count bits from e starting at offset.", T_INT),
    docEntry("insertBits", "fn insertBits(e: T, newbits: T, offset: u32, count: u32) -> T", "Replaces count bits in e starting at offset with bits from newbits.", T_INT),
};

// --- Numeric: Matrix ---
const numeric_matrix_doc = [_]struct { []const u8, BuiltinDoc }{
    docEntry("transpose", "fn transpose(e: matRxC<T>) -> matCxR<T>", "Returns the transpose of the matrix.", "T is f32, f16"),
    docEntry("determinant", "fn determinant(e: matNxN<T>) -> T", "Returns the determinant of the square matrix.", "T is f32, f16"),
};

// --- Numeric: Special ---
const numeric_special_doc = [_]struct { []const u8, BuiltinDoc }{
    docEntry("ldexp", "fn ldexp(e1: T, e2: I) -> T", "Returns e1 * 2^e2.", "T is f32, f16; I is i32 or vecN<i32>"),
    docEntry("frexp", "fn frexp(e: T) -> __frexp_result", "Splits e into a significand in [0.5,1.0) and an exponent.", T_FLOAT),
    docEntry("modf", "fn modf(e: T) -> __modf_result", "Splits e into integer and fractional parts.", T_FLOAT),
    docEntry("quantizeToF16", "fn quantizeToF16(e: T) -> T", "Quantizes e to IEEE-754 binary16 then converts back.", "T is f32 or vecN<f32>"),
};

// --- Derivative ---
const derivative_doc = [_]struct { []const u8, BuiltinDoc }{
    docEntry("dpdx", "fn dpdx(e: T) -> T", "Returns the partial derivative of e with respect to window x.", T_FLOAT),
    docEntry("dpdy", "fn dpdy(e: T) -> T", "Returns the partial derivative of e with respect to window y.", T_FLOAT),
    docEntry("fwidth", "fn fwidth(e: T) -> T", "Returns abs(dpdx(e)) + abs(dpdy(e)).", T_FLOAT),
    docEntry("dpdxCoarse", "fn dpdxCoarse(e: T) -> T", "Returns a coarse partial derivative of e w.r.t. window x.", T_FLOAT),
    docEntry("dpdyCoarse", "fn dpdyCoarse(e: T) -> T", "Returns a coarse partial derivative of e w.r.t. window y.", T_FLOAT),
    docEntry("fwidthCoarse", "fn fwidthCoarse(e: T) -> T", "Returns abs(dpdxCoarse(e)) + abs(dpdyCoarse(e)).", T_FLOAT),
    docEntry("dpdxFine", "fn dpdxFine(e: T) -> T", "Returns a fine partial derivative of e w.r.t. window x.", T_FLOAT),
    docEntry("dpdyFine", "fn dpdyFine(e: T) -> T", "Returns a fine partial derivative of e w.r.t. window y.", T_FLOAT),
    docEntry("fwidthFine", "fn fwidthFine(e: T) -> T", "Returns abs(dpdxFine(e)) + abs(dpdyFine(e)).", T_FLOAT),
};

// --- Texture ---
const texture_doc = [_]struct { []const u8, BuiltinDoc }{
    docEntry("textureSample", "fn textureSample(t: texture, s: sampler, coords: vecN<f32>, ...) -> vec4<f32>", "Samples a texture using implicit level of detail.", "Requires uniform control flow"),
    docEntry("textureSampleBias", "fn textureSampleBias(t: texture, s: sampler, coords: vecN<f32>, bias: f32, ...) -> vec4<f32>", "Samples a texture with a bias applied to the mip level.", "Requires uniform control flow"),
    docEntry("textureSampleCompare", "fn textureSampleCompare(t: texture_depth, s: sampler_comparison, coords: vecN<f32>, depth_ref: f32, ...) -> f32", "Samples a depth texture and compares against a reference value.", "Requires uniform control flow"),
    docEntry("textureSampleCompareLevel", "fn textureSampleCompareLevel(t: texture_depth, s: sampler_comparison, coords: vecN<f32>, depth_ref: f32, ...) -> f32", "Samples a depth texture at mip level 0 and compares against a reference value.", ""),
    docEntry("textureSampleLevel", "fn textureSampleLevel(t: texture, s: sampler, coords: vecN<f32>, level: f32, ...) -> vec4<f32>", "Samples a texture at an explicit mip level.", ""),
    docEntry("textureSampleGrad", "fn textureSampleGrad(t: texture, s: sampler, coords: vecN<f32>, ddx: vecN<f32>, ddy: vecN<f32>, ...) -> vec4<f32>", "Samples a texture using explicit gradients.", ""),
    docEntry("textureLoad", "fn textureLoad(t: texture, coords: vecN<i32/u32>, ...) -> vec4<T>", "Reads a single texel from a texture without sampling.", ""),
    docEntry("textureStore", "fn textureStore(t: texture_storage, coords: vecN<i32/u32>, value: vec4<T>)", "Writes a single texel to a storage texture.", ""),
    docEntry("textureDimensions", "fn textureDimensions(t: texture, ...) -> vecN<u32>", "Returns the dimensions of the texture in texels.", ""),
    docEntry("textureNumLayers", "fn textureNumLayers(t: texture_array) -> u32", "Returns the number of layers in an arrayed texture.", ""),
    docEntry("textureNumLevels", "fn textureNumLevels(t: texture) -> u32", "Returns the number of mip levels in the texture.", ""),
    docEntry("textureNumSamples", "fn textureNumSamples(t: texture_multisampled) -> u32", "Returns the number of samples per texel in a multisampled texture.", ""),
    docEntry("textureGather", "fn textureGather(component: i32, t: texture, s: sampler, coords: vecN<f32>, ...) -> vec4<T>", "Gathers the component from four texels in a 2x2 footprint.", "Requires uniform control flow"),
    docEntry("textureGatherCompare", "fn textureGatherCompare(t: texture_depth, s: sampler_comparison, coords: vec2<f32>, depth_ref: f32, ...) -> vec4<f32>", "Gathers depth comparison results from four texels.", "Requires uniform control flow"),
    docEntry("textureSampleBaseClampToEdge", "fn textureSampleBaseClampToEdge(t: texture_2d<f32>, s: sampler, coords: vec2<f32>) -> vec4<f32>", "Samples a texture at base level, clamping coordinates to avoid edge wrapping.", "T is texture_2d<f32> or texture_external"),
};

// --- Atomic ---
const atomic_doc = [_]struct { []const u8, BuiltinDoc }{
    docEntry("atomicLoad", "fn atomicLoad(p: ptr<AS, atomic<T>>) -> T", "Atomically loads the value pointed to by p.", "T is i32 or u32"),
    docEntry("atomicStore", "fn atomicStore(p: ptr<AS, atomic<T>>, v: T)", "Atomically stores v into the value pointed to by p.", "T is i32 or u32"),
    docEntry("atomicAdd", "fn atomicAdd(p: ptr<AS, atomic<T>>, v: T) -> T", "Atomically adds v to *p and returns the original value.", "T is i32 or u32"),
    docEntry("atomicSub", "fn atomicSub(p: ptr<AS, atomic<T>>, v: T) -> T", "Atomically subtracts v from *p and returns the original value.", "T is i32 or u32"),
    docEntry("atomicMax", "fn atomicMax(p: ptr<AS, atomic<T>>, v: T) -> T", "Atomically stores max(*p, v) and returns the original value.", "T is i32 or u32"),
    docEntry("atomicMin", "fn atomicMin(p: ptr<AS, atomic<T>>, v: T) -> T", "Atomically stores min(*p, v) and returns the original value.", "T is i32 or u32"),
    docEntry("atomicAnd", "fn atomicAnd(p: ptr<AS, atomic<T>>, v: T) -> T", "Atomically stores (*p & v) and returns the original value.", "T is i32 or u32"),
    docEntry("atomicOr", "fn atomicOr(p: ptr<AS, atomic<T>>, v: T) -> T", "Atomically stores (*p | v) and returns the original value.", "T is i32 or u32"),
    docEntry("atomicXor", "fn atomicXor(p: ptr<AS, atomic<T>>, v: T) -> T", "Atomically stores (*p ^ v) and returns the original value.", "T is i32 or u32"),
    docEntry("atomicExchange", "fn atomicExchange(p: ptr<AS, atomic<T>>, v: T) -> T", "Atomically replaces *p with v and returns the original value.", "T is i32 or u32"),
    docEntry("atomicCompareExchangeWeak", "fn atomicCompareExchangeWeak(p: ptr<AS, atomic<T>>, expected: T, v: T) -> __atomic_compare_exchange_result<T>", "Atomically compares *p with expected and exchanges with v if equal.", "T is i32 or u32"),
};

// --- Packing ---
const packing_doc = [_]struct { []const u8, BuiltinDoc }{
    docEntry("pack4x8snorm", "fn pack4x8snorm(e: vec4<f32>) -> u32", "Packs four normalized f32 values into a u32 as signed bytes.", ""),
    docEntry("pack4x8unorm", "fn pack4x8unorm(e: vec4<f32>) -> u32", "Packs four normalized f32 values into a u32 as unsigned bytes.", ""),
    docEntry("pack2x16snorm", "fn pack2x16snorm(e: vec2<f32>) -> u32", "Packs two normalized f32 values into a u32 as signed 16-bit integers.", ""),
    docEntry("pack2x16unorm", "fn pack2x16unorm(e: vec2<f32>) -> u32", "Packs two normalized f32 values into a u32 as unsigned 16-bit integers.", ""),
    docEntry("pack2x16float", "fn pack2x16float(e: vec2<f32>) -> u32", "Packs two f32 values into a u32 as f16 values.", ""),
    docEntry("pack4xI8", "fn pack4xI8(e: vec4<i32>) -> u32", "Packs four i32 values into a u32 as signed bytes.", ""),
    docEntry("pack4xU8", "fn pack4xU8(e: vec4<u32>) -> u32", "Packs four u32 values into a u32 as unsigned bytes.", ""),
    docEntry("pack4xI8Clamp", "fn pack4xI8Clamp(e: vec4<i32>) -> u32", "Packs four i32 values into a u32 as signed bytes, clamping to [-128, 127].", ""),
    docEntry("pack4xU8Clamp", "fn pack4xU8Clamp(e: vec4<u32>) -> u32", "Packs four u32 values into a u32 as unsigned bytes, clamping to [0, 255].", ""),
    docEntry("unpack4x8snorm", "fn unpack4x8snorm(e: u32) -> vec4<f32>", "Unpacks a u32 into four normalized f32 values as signed bytes.", ""),
    docEntry("unpack4x8unorm", "fn unpack4x8unorm(e: u32) -> vec4<f32>", "Unpacks a u32 into four normalized f32 values as unsigned bytes.", ""),
    docEntry("unpack2x16snorm", "fn unpack2x16snorm(e: u32) -> vec2<f32>", "Unpacks a u32 into two normalized f32 values as signed 16-bit integers.", ""),
    docEntry("unpack2x16unorm", "fn unpack2x16unorm(e: u32) -> vec2<f32>", "Unpacks a u32 into two normalized f32 values as unsigned 16-bit integers.", ""),
    docEntry("unpack2x16float", "fn unpack2x16float(e: u32) -> vec2<f32>", "Unpacks a u32 into two f32 values from f16 values.", ""),
    docEntry("unpack4xI8", "fn unpack4xI8(e: u32) -> vec4<i32>", "Unpacks a u32 into four i32 values as signed bytes.", ""),
    docEntry("unpack4xU8", "fn unpack4xU8(e: u32) -> vec4<u32>", "Unpacks a u32 into four u32 values as unsigned bytes.", ""),
};

// --- Synchronization ---
const synchronization_doc = [_]struct { []const u8, BuiltinDoc }{
    docEntry("workgroupBarrier", "fn workgroupBarrier()", "Synchronizes all invocations in the workgroup. Requires uniform control flow.", ""),
    docEntry("storageBarrier", "fn storageBarrier()", "Ensures all storage memory accesses are visible. Requires uniform control flow.", ""),
    docEntry("textureBarrier", "fn textureBarrier()", "Ensures all texture memory accesses are visible. Requires uniform control flow.", ""),
    docEntry("workgroupUniformLoad", "fn workgroupUniformLoad(p: ptr<workgroup, T>) -> T", "Loads a value from workgroup memory after synchronization.", "Requires uniform control flow"),
};

// --- Subgroup ---
const subgroup_doc = [_]struct { []const u8, BuiltinDoc }{
    docEntry("subgroupBallot", "fn subgroupBallot(pred: bool) -> vec4<u32>", "Returns a bitmask of which invocations have pred true.", "Requires enable subgroups"),
    docEntry("subgroupBroadcast", "fn subgroupBroadcast(e: T, id: u32) -> T", "Broadcasts the value of e from the invocation with the given id.", T_NUMERIC),
    docEntry("subgroupBroadcastFirst", "fn subgroupBroadcastFirst(e: T) -> T", "Broadcasts the value of e from the invocation with the lowest active id.", T_NUMERIC),
    docEntry("subgroupShuffle", "fn subgroupShuffle(e: T, id: u32) -> T", "Returns the value of e from the invocation with the given id.", T_NUMERIC),
    docEntry("subgroupShuffleDown", "fn subgroupShuffleDown(e: T, delta: u32) -> T", "Returns the value of e from the invocation at current id + delta.", T_NUMERIC),
    docEntry("subgroupShuffleUp", "fn subgroupShuffleUp(e: T, delta: u32) -> T", "Returns the value of e from the invocation at current id - delta.", T_NUMERIC),
    docEntry("subgroupShuffleXor", "fn subgroupShuffleXor(e: T, mask: u32) -> T", "Returns the value of e from the invocation at current id XOR mask.", T_NUMERIC),
    docEntry("subgroupAdd", "fn subgroupAdd(e: T) -> T", "Returns the sum of e across all active invocations.", T_NUMERIC),
    docEntry("subgroupMul", "fn subgroupMul(e: T) -> T", "Returns the product of e across all active invocations.", T_NUMERIC),
    docEntry("subgroupAnd", "fn subgroupAnd(e: T) -> T", "Returns the bitwise AND of e across all active invocations.", T_INT),
    docEntry("subgroupOr", "fn subgroupOr(e: T) -> T", "Returns the bitwise OR of e across all active invocations.", T_INT),
    docEntry("subgroupXor", "fn subgroupXor(e: T) -> T", "Returns the bitwise XOR of e across all active invocations.", T_INT),
    docEntry("subgroupMin", "fn subgroupMin(e: T) -> T", "Returns the minimum of e across all active invocations.", T_NUMERIC),
    docEntry("subgroupMax", "fn subgroupMax(e: T) -> T", "Returns the maximum of e across all active invocations.", T_NUMERIC),
    docEntry("subgroupInclusiveAdd", "fn subgroupInclusiveAdd(e: T) -> T", "Returns the inclusive prefix sum of e.", T_NUMERIC),
    docEntry("subgroupInclusiveMul", "fn subgroupInclusiveMul(e: T) -> T", "Returns the inclusive prefix product of e.", T_NUMERIC),
    docEntry("subgroupExclusiveAdd", "fn subgroupExclusiveAdd(e: T) -> T", "Returns the exclusive prefix sum of e.", T_NUMERIC),
    docEntry("subgroupExclusiveMul", "fn subgroupExclusiveMul(e: T) -> T", "Returns the exclusive prefix product of e.", T_NUMERIC),
    docEntry("subgroupAll", "fn subgroupAll(e: bool) -> bool", "Returns true if e is true for all active invocations.", ""),
    docEntry("subgroupAny", "fn subgroupAny(e: bool) -> bool", "Returns true if e is true for any active invocation.", ""),
    docEntry("subgroupElect", "fn subgroupElect() -> bool", "Returns true for exactly one active invocation in the subgroup.", ""),
    // Quad operations
    docEntry("quadBroadcast", "fn quadBroadcast(e: T, id: u32) -> T", "Broadcasts the value of e from the quad invocation with the given id.", T_NUMERIC),
    docEntry("quadSwapDiagonal", "fn quadSwapDiagonal(e: T) -> T", "Returns the value of e from the diagonally opposite quad invocation.", T_NUMERIC),
    docEntry("quadSwapX", "fn quadSwapX(e: T) -> T", "Returns the value of e from the horizontally adjacent quad invocation.", T_NUMERIC),
    docEntry("quadSwapY", "fn quadSwapY(e: T) -> T", "Returns the value of e from the vertically adjacent quad invocation.", T_NUMERIC),
};

// =========================================================================
// Overload Signatures
// =========================================================================
//
// Declarative overload sets covering every callable WGSL builtin. Each
// entry is keyed by the builtin's name and contains one or more
// `Overload.OverloadSig` values. The validator calls `Overload.resolve`
// unconditionally — `Validator.checkBuiltinCall` asserts that every
// lookup hits a non-empty table, and a test further down enforces the
// invariant (`bitcast` is the only exempt name; see its block below).

// Common alias to keep signature tables short and readable.
const O = Overload;

/// Builds a single-overload `(ptr<AS, atomic<T>, AM>) -> T` signature,
/// used by `atomicLoad` (the only one-arg atomic).
const atomic_load_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 3,
        .params = &.{
            .{ .tparam_ptr_atomic = .{ .as_idx = 1, .am_idx = 2, .elem_idx = 0, .elem_family = .integer } },
        },
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    },
};

/// `(ptr<AS, atomic<T>, AM>, T) -> T` for atomicAdd/Sub/Max/Min/And/Or/Xor/Exchange.
const atomic_rmw_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 3,
        .params = &.{
            .{ .tparam_ptr_atomic = .{ .as_idx = 1, .am_idx = 2, .elem_idx = 0, .elem_family = .integer } },
            .{ .bound_scalar = 0 },
        },
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    },
};

/// `(ptr<AS, atomic<T>, AM>, T, T) -> __atomic_compare_exchange_result<T>`.
const atomic_cmp_xchg_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 3,
        .params = &.{
            .{ .tparam_ptr_atomic = .{ .as_idx = 1, .am_idx = 2, .elem_idx = 0, .elem_family = .integer } },
            .{ .bound_scalar = 0 },
            .{ .bound_scalar = 0 },
        },
        .result = .{ .synth_atomic_cmp_xchg = 0 },
    },
};

/// `(ptr<AS, atomic<T>, AM>, T) -> void` for atomicStore. Same shape as
/// atomic_rmw_sigs but the result is fixed Void — atomicStore is the only
/// atomic operation that doesn't return T.
const atomic_store_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 3,
        .params = &.{
            .{ .tparam_ptr_atomic = .{ .as_idx = 1, .am_idx = 2, .elem_idx = 0, .elem_family = .integer } },
            .{ .bound_scalar = 0 },
        },
        .result = .{ .fixed = Types.Void },
    },
};

/// `(ptr<AS, array<E>, AM>) -> u32` for arrayLength. AS and AM bind freely;
/// the only structural constraint is that the pointee is a runtime-sized
/// array. See `Pattern.tparam_ptr_runtime_array` for the rationale.
const array_length_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 2,
        .params = &.{
            .{ .tparam_ptr_runtime_array = .{ .as_idx = 0, .am_idx = 1 } },
        },
        .result = .{ .fixed = Types.U32 },
    },
};

/// `() -> void` — shared by workgroupBarrier / storageBarrier /
/// textureBarrier. The uniform-control-flow requirement is enforced
/// separately in `Validator.checkCallExpr` via `Builtin.uniformity`.
const barrier_sigs = &[_]O.OverloadSig{
    .{ .tparam_count = 0, .params = &.{}, .result = .{ .fixed = Types.Void } },
};

/// frexp / modf — scalar and vector float forms. The validator's
/// `synthesizeFrexpResult` / `synthesizeModfResult` build the result
/// struct from the bound element type + (for vectors) bound width.
const frexp_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 1,
        .params = &.{.{ .tparam_scalar = .{ .idx = 0, .family = .float } }},
        .result = .{ .synth_frexp = 0 },
    },
    .{
        .tparam_count = 2,
        .params = &.{.{ .tparam_vector = .{ .elem_idx = 0, .elem_family = .float, .n_idx = 1 } }},
        .result = .{ .synth_frexp = 0 },
    },
};

const modf_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 1,
        .params = &.{.{ .tparam_scalar = .{ .idx = 0, .family = .float } }},
        .result = .{ .synth_modf = 0 },
    },
    .{
        .tparam_count = 2,
        .params = &.{.{ .tparam_vector = .{ .elem_idx = 0, .elem_family = .float, .n_idx = 1 } }},
        .result = .{ .synth_modf = 0 },
    },
};

/// Packed-format unpacks — each returns a fixed vector type. These vector
/// singletons have static storage so `.{ .vector = &...}` is always valid.
const vec4_i32_singleton = Types.Vector{ .width = 4, .element = Types.scalar_i32_ptr };
const vec4_u32_singleton = Types.Vector{ .width = 4, .element = Types.scalar_u32_ptr };
const vec4_f32_singleton = Types.Vector{ .width = 4, .element = Types.scalar_f32_ptr };
const vec2_f32_singleton = Types.Vector{ .width = 2, .element = Types.scalar_f32_ptr };

const vec2_f16_singleton = Types.Vector{ .width = 2, .element = Types.scalar_f16_ptr };
const vec4_f16_singleton = Types.Vector{ .width = 4, .element = Types.scalar_f16_ptr };
const vec2_i32_singleton = Types.Vector{ .width = 2, .element = Types.scalar_i32_ptr };
const vec3_i32_singleton = Types.Vector{ .width = 3, .element = Types.scalar_i32_ptr };
const vec2_u32_singleton = Types.Vector{ .width = 2, .element = Types.scalar_u32_ptr };
const vec3_u32_singleton = Types.Vector{ .width = 3, .element = Types.scalar_u32_ptr };

const vec4_i32_type: Types.Type = .{ .vector = &vec4_i32_singleton };
const vec4_u32_type: Types.Type = .{ .vector = &vec4_u32_singleton };
const vec4_f32_type: Types.Type = .{ .vector = &vec4_f32_singleton };
const vec2_f32_type: Types.Type = .{ .vector = &vec2_f32_singleton };
pub const vec2_f16_type: Types.Type = .{ .vector = &vec2_f16_singleton };
pub const vec4_f16_type: Types.Type = .{ .vector = &vec4_f16_singleton };
const vec2_i32_type: Types.Type = .{ .vector = &vec2_i32_singleton };
const vec3_i32_type: Types.Type = .{ .vector = &vec3_i32_singleton };
const vec2_u32_type: Types.Type = .{ .vector = &vec2_u32_singleton };
const vec3_u32_type: Types.Type = .{ .vector = &vec3_u32_singleton };

const unpack4xI8_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 0,
        .params = &.{.{ .concrete = Types.U32 }},
        .result = .{ .fixed = vec4_i32_type },
    },
};
const unpack4xU8_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 0,
        .params = &.{.{ .concrete = Types.U32 }},
        .result = .{ .fixed = vec4_u32_type },
    },
};
const unpack4x8_float_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 0,
        .params = &.{.{ .concrete = Types.U32 }},
        .result = .{ .fixed = vec4_f32_type },
    },
};
const unpack2x16_float_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 0,
        .params = &.{.{ .concrete = Types.U32 }},
        .result = .{ .fixed = vec2_f32_type },
    },
};

/// dot4I8Packed / dot4U8Packed (§17.5.20): `(u32, u32) -> i32 / u32`.
/// Inputs are interpreted as four packed 8-bit ints. No tparams — both
/// params and the return are concrete, so this mirrors the shape of the
/// `unpack4xI8` / `unpack4xU8` sigs above.
const dot4I8Packed_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 0,
        .params = &.{ .{ .concrete = Types.U32 }, .{ .concrete = Types.U32 } },
        .result = .{ .fixed = Types.I32 },
    },
};
const dot4U8Packed_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 0,
        .params = &.{ .{ .concrete = Types.U32 }, .{ .concrete = Types.U32 } },
        .result = .{ .fixed = Types.U32 },
    },
};

/// Bitcast (§17.9.5) — template-seeded overload dispatch.
///
/// Bitcast is the only template-taking builtin: the caller writes
/// `bitcast<T>(e)`, and the template T is already resolved to a concrete
/// type before the solver runs. The validator pre-seeds slot 0 with T's
/// element scalar kind and (for vector templates) slot 1 with T's width,
/// then calls `Overload.resolveSeeded` against the sig array matching
/// T's shape. Slot 2 is the solver-bound source scalar S.
///
/// Post-resolution, the validator runs a size-compatibility check so the
/// cross-shape sigs (vecN<32>↔vec4<f16> etc.) can't produce an
/// ill-sized pair even when the solver considers them feasible.
///
/// The four arrays here are `pub` because bitcast dispatches from a
/// bespoke block in `Validator.checkExprCall` (template-shape selection
/// is local to that call site) rather than via `builtin_fn.overloads`.
pub const bitcast_to_scalar_sigs = &[_]O.OverloadSig{
    // (scalar S) → T, S ∈ {i32, u32, f32}
    .{
        .tparam_count = 3,
        .params = &.{.{ .tparam_scalar = .{ .idx = 2, .family = .concrete_32 } }},
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    },
    // (vec2<f16>) → T
    .{
        .tparam_count = 3,
        .params = &.{.{ .concrete = vec2_f16_type }},
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    },
};

pub const bitcast_to_vecN_32_sigs = &[_]O.OverloadSig{
    // (vecN<S>) → vecN<T>, N seeded, S ∈ {i32, u32, f32}
    .{
        .tparam_count = 3,
        .params = &.{.{ .tparam_vector = .{ .elem_idx = 2, .elem_family = .concrete_32, .n_idx = 1 } }},
        .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_idx = 1 } } },
    },
    // (vec4<f16>) → vec2<T>. Solver accepts regardless of seeded N; the
    // validator's post-resolution size check rejects N≠2 (96/128 ≠ 64 bits).
    .{
        .tparam_count = 3,
        .params = &.{.{ .concrete = vec4_f16_type }},
        .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_idx = 1 } } },
    },
};

pub const bitcast_to_vec2_f16_sigs = &[_]O.OverloadSig{
    // (scalar S) → vec2<f16>, S ∈ {i32, u32, f32}
    .{
        .tparam_count = 3,
        .params = &.{.{ .tparam_scalar = .{ .idx = 2, .family = .concrete_32 } }},
        .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_idx = 1 } } },
    },
};

pub const bitcast_to_vec4_f16_sigs = &[_]O.OverloadSig{
    // (vec2<S>) → vec4<f16>, S ∈ {i32, u32, f32}
    .{
        .tparam_count = 3,
        .params = &.{.{ .tparam_vector = .{ .elem_idx = 2, .elem_family = .concrete_32, .n_fixed = 2 } }},
        .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_idx = 1 } } },
    },
};

/// subgroupBallot: `()` or `(bool) -> vec4<u32>`.
const subgroup_ballot_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 0,
        .params = &.{},
        .result = .{ .fixed = vec4_u32_type },
    },
    .{
        .tparam_count = 0,
        .params = &.{.{ .concrete = Types.Bool }},
        .result = .{ .fixed = vec4_u32_type },
    },
};

/// workgroupUniformLoad: `(ptr<workgroup, T, read_write>) -> T`.
const wg_uniform_load_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 2,
        .params = &.{.{ .tparam_ptr = .{ .as_fixed = .workgroup, .am_idx = 1, .elem_idx = 0 } }},
        .result = .{ .bound_scalar_as_type = 0 },
    },
};

/// transpose: `matCxR<T>` → `matRxC<T>` with T ∈ float family.
const transpose_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 3,
        .params = &.{.{ .tparam_matrix = .{ .elem_idx = 0, .elem_family = .float, .cols_idx = 1, .rows_idx = 2 } }},
        .result = .{ .pattern = .{ .bound_matrix_transposed = .{ .elem_idx = 0, .cols_idx = 1, .rows_idx = 2 } } },
    },
};

// =========================================================================
// Texture query overloads (§17.6.x)
// =========================================================================
//
// Declarative signatures for textureLoad, textureStore, textureDimensions,
// textureNumLayers, textureNumLevels, and textureNumSamples. The sampling
// and gather families (textureSample*, textureGather*) live in the block
// further below. Every texture builtin resolves through this engine.
//
// Convention for ancillary integer args (coord, level, array_index,
// sample_index): we don't bind their scalar kind to a tparam slot; we
// only want family filtering (.integer accepts i32, u32, abstract_int).
// The `no_tparam` sentinel for `tparam_scalar.idx` / `tparam_vector.elem_idx`
// turns bindScalar into a no-op that still does the family check.
//
// Slot 0 always holds the texture's element scalar (T in texture_kind_dim<T>
// for sampled/multisampled, or the channel type derived from texel_format
// for storage). Depth/external textures have no element, so their sigs
// set `elem_idx = no_tparam` on the texture pattern and use a fixed result.

const no_tp: u8 = O.Pattern.no_tparam;

/// textureLoad coordinate patterns — integer scalar/vector, family-only
/// (no slot binding). All share the `.integer` ScalarFamily so i32, u32,
/// and abstract_int are accepted uniformly.
const coord_1d: O.Pattern = .{ .tparam_scalar = .{ .idx = no_tp, .family = .integer } };
const coord_2d: O.Pattern = .{ .tparam_vector = .{ .elem_idx = no_tp, .elem_family = .integer, .n_fixed = 2 } };
const coord_3d: O.Pattern = .{ .tparam_vector = .{ .elem_idx = no_tp, .elem_family = .integer, .n_fixed = 3 } };
/// Ancillary integer scalar arg (level, array_index, sample_index).
const int_scalar: O.Pattern = .{ .tparam_scalar = .{ .idx = no_tp, .family = .integer } };

/// Result pattern for sampled/storage textureLoad: vec4<T> where T is
/// bound at slot 0 by the texture pattern.
const vec4_of_slot0: O.ResultRule = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_fixed = 4 } } };

/// textureLoad (§17.6.6) — 13 overloads covering every texture kind that
/// supports indexed loads. Coord shape + mip/sample/array-index arity is
/// dimension-dependent.
const textureLoad_sigs = &[_]O.OverloadSig{
    // --- Sampled textures: vec4<T> ---
    .{
        .tparam_count = 1,
        .params = &.{
            .{ .tparam_texture = .{ .kind = .sampled, .dimension = .@"1d", .elem_idx = 0 } },
            coord_1d,
            int_scalar,
        },
        .result = vec4_of_slot0,
    },
    .{
        .tparam_count = 1,
        .params = &.{
            .{ .tparam_texture = .{ .kind = .sampled, .dimension = .@"2d", .elem_idx = 0 } },
            coord_2d,
            int_scalar,
        },
        .result = vec4_of_slot0,
    },
    .{
        .tparam_count = 1,
        .params = &.{
            .{ .tparam_texture = .{ .kind = .sampled, .dimension = .@"2d_array", .elem_idx = 0 } },
            coord_2d,
            int_scalar, // array_index
            int_scalar, // level
        },
        .result = vec4_of_slot0,
    },
    .{
        .tparam_count = 1,
        .params = &.{
            .{ .tparam_texture = .{ .kind = .sampled, .dimension = .@"3d", .elem_idx = 0 } },
            coord_3d,
            int_scalar,
        },
        .result = vec4_of_slot0,
    },

    // --- Multisampled texture: vec4<T>, sample_index instead of level ---
    .{
        .tparam_count = 1,
        .params = &.{
            .{ .tparam_texture = .{ .kind = .multisampled, .dimension = .@"2d", .elem_idx = 0 } },
            coord_2d,
            int_scalar,
        },
        .result = vec4_of_slot0,
    },

    // --- Depth textures: f32 (no element parameter) ---
    .{
        .tparam_count = 0,
        .params = &.{
            .{ .tparam_texture = .{ .kind = .depth, .dimension = .@"2d" } },
            coord_2d,
            int_scalar,
        },
        .result = .{ .fixed = Types.F32 },
    },
    .{
        .tparam_count = 0,
        .params = &.{
            .{ .tparam_texture = .{ .kind = .depth, .dimension = .@"2d_array" } },
            coord_2d,
            int_scalar, // array_index
            int_scalar, // level
        },
        .result = .{ .fixed = Types.F32 },
    },
    .{
        .tparam_count = 0,
        .params = &.{
            .{ .tparam_texture = .{ .kind = .depth_multisampled, .dimension = .@"2d" } },
            coord_2d,
            int_scalar,
        },
        .result = .{ .fixed = Types.F32 },
    },

    // --- External texture: vec4<f32>, no level ---
    .{
        .tparam_count = 0,
        .params = &.{
            .{ .tparam_texture = .{ .kind = .external, .dimension = .@"2d" } },
            coord_2d,
        },
        .result = .{ .fixed = vec4_f32_type },
    },

    // --- Storage textures: vec4<CF>, CF derived from texel_format ---
    .{
        .tparam_count = 1,
        .params = &.{
            .{ .tparam_texture = .{ .kind = .storage, .dimension = .@"1d", .elem_idx = 0 } },
            coord_1d,
        },
        .result = vec4_of_slot0,
    },
    .{
        .tparam_count = 1,
        .params = &.{
            .{ .tparam_texture = .{ .kind = .storage, .dimension = .@"2d", .elem_idx = 0 } },
            coord_2d,
        },
        .result = vec4_of_slot0,
    },
    .{
        .tparam_count = 1,
        .params = &.{
            .{ .tparam_texture = .{ .kind = .storage, .dimension = .@"2d_array", .elem_idx = 0 } },
            coord_2d,
            int_scalar, // array_index
        },
        .result = vec4_of_slot0,
    },
    .{
        .tparam_count = 1,
        .params = &.{
            .{ .tparam_texture = .{ .kind = .storage, .dimension = .@"3d", .elem_idx = 0 } },
            coord_3d,
        },
        .result = vec4_of_slot0,
    },
};

/// Value-arg pattern for textureStore: vec4<CF> where CF = slot 0 (the
/// texture's texel-format channel type). Uses `tparam_vector` on an
/// already-bound slot — bindScalar's "already bound → check equality"
/// branch enforces value.element == texture-channel.
const store_value: O.Pattern = .{ .tparam_vector = .{ .elem_idx = 0, .elem_family = .numeric, .n_fixed = 4 } };

/// textureStore (§17.6.9) — storage textures only. Returns void. The
/// access-mode side check (`Validator.zig` — textureStore requires
/// `write` or `read_write`) still fires pre-resolution.
const textureStore_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 1,
        .params = &.{
            .{ .tparam_texture = .{ .kind = .storage, .dimension = .@"1d", .elem_idx = 0 } },
            coord_1d,
            store_value,
        },
        .result = .{ .fixed = Types.Void },
    },
    .{
        .tparam_count = 1,
        .params = &.{
            .{ .tparam_texture = .{ .kind = .storage, .dimension = .@"2d", .elem_idx = 0 } },
            coord_2d,
            store_value,
        },
        .result = .{ .fixed = Types.Void },
    },
    .{
        .tparam_count = 1,
        .params = &.{
            .{ .tparam_texture = .{ .kind = .storage, .dimension = .@"2d_array", .elem_idx = 0 } },
            coord_2d,
            int_scalar, // array_index
            store_value,
        },
        .result = .{ .fixed = Types.Void },
    },
    .{
        .tparam_count = 1,
        .params = &.{
            .{ .tparam_texture = .{ .kind = .storage, .dimension = .@"3d", .elem_idx = 0 } },
            coord_3d,
            store_value,
        },
        .result = .{ .fixed = Types.Void },
    },
};

/// textureDimensions (§17.6.1) — returns u32 / vec2<u32> / vec3<u32> per
/// dimension. Level arg is permitted only on mippable textures (sampled
/// and depth; NOT multisampled, storage, external).
fn dimsResult(dim: Types.TextureDimension) O.ResultRule {
    return switch (dim) {
        .@"1d" => .{ .fixed = Types.U32 },
        .@"3d" => .{ .fixed = vec3_u32_type },
        .@"2d", .@"2d_array", .cube, .cube_array => .{ .fixed = vec2_u32_type },
    };
}

const textureDimensions_sigs = &[_]O.OverloadSig{
    // Sampled: arity 1 (no level) and arity 2 (with level).
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .sampled, .dimension = .@"1d" } }}, .result = dimsResult(.@"1d") },
    .{ .tparam_count = 0, .params = &.{ .{ .tparam_texture = .{ .kind = .sampled, .dimension = .@"1d" } }, int_scalar }, .result = dimsResult(.@"1d") },
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .sampled, .dimension = .@"2d" } }}, .result = dimsResult(.@"2d") },
    .{ .tparam_count = 0, .params = &.{ .{ .tparam_texture = .{ .kind = .sampled, .dimension = .@"2d" } }, int_scalar }, .result = dimsResult(.@"2d") },
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .sampled, .dimension = .@"2d_array" } }}, .result = dimsResult(.@"2d_array") },
    .{ .tparam_count = 0, .params = &.{ .{ .tparam_texture = .{ .kind = .sampled, .dimension = .@"2d_array" } }, int_scalar }, .result = dimsResult(.@"2d_array") },
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .sampled, .dimension = .@"3d" } }}, .result = dimsResult(.@"3d") },
    .{ .tparam_count = 0, .params = &.{ .{ .tparam_texture = .{ .kind = .sampled, .dimension = .@"3d" } }, int_scalar }, .result = dimsResult(.@"3d") },
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .sampled, .dimension = .cube } }}, .result = dimsResult(.cube) },
    .{ .tparam_count = 0, .params = &.{ .{ .tparam_texture = .{ .kind = .sampled, .dimension = .cube } }, int_scalar }, .result = dimsResult(.cube) },
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .sampled, .dimension = .cube_array } }}, .result = dimsResult(.cube_array) },
    .{ .tparam_count = 0, .params = &.{ .{ .tparam_texture = .{ .kind = .sampled, .dimension = .cube_array } }, int_scalar }, .result = dimsResult(.cube_array) },

    // Multisampled: no level arg (spec).
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .multisampled, .dimension = .@"2d" } }}, .result = dimsResult(.@"2d") },

    // Depth: arity 1 and 2.
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .depth, .dimension = .@"2d" } }}, .result = dimsResult(.@"2d") },
    .{ .tparam_count = 0, .params = &.{ .{ .tparam_texture = .{ .kind = .depth, .dimension = .@"2d" } }, int_scalar }, .result = dimsResult(.@"2d") },
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .depth, .dimension = .@"2d_array" } }}, .result = dimsResult(.@"2d_array") },
    .{ .tparam_count = 0, .params = &.{ .{ .tparam_texture = .{ .kind = .depth, .dimension = .@"2d_array" } }, int_scalar }, .result = dimsResult(.@"2d_array") },
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .depth, .dimension = .cube } }}, .result = dimsResult(.cube) },
    .{ .tparam_count = 0, .params = &.{ .{ .tparam_texture = .{ .kind = .depth, .dimension = .cube } }, int_scalar }, .result = dimsResult(.cube) },
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .depth, .dimension = .cube_array } }}, .result = dimsResult(.cube_array) },
    .{ .tparam_count = 0, .params = &.{ .{ .tparam_texture = .{ .kind = .depth, .dimension = .cube_array } }, int_scalar }, .result = dimsResult(.cube_array) },

    // Depth multisampled: no level.
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .depth_multisampled, .dimension = .@"2d" } }}, .result = dimsResult(.@"2d") },

    // Storage: no level.
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .storage, .dimension = .@"1d" } }}, .result = dimsResult(.@"1d") },
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .storage, .dimension = .@"2d" } }}, .result = dimsResult(.@"2d") },
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .storage, .dimension = .@"2d_array" } }}, .result = dimsResult(.@"2d_array") },
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .storage, .dimension = .@"3d" } }}, .result = dimsResult(.@"3d") },

    // External: no level.
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .external, .dimension = .@"2d" } }}, .result = dimsResult(.@"2d") },
};

/// textureNumLayers (§17.6.2) — array-capable textures only. Returns u32.
const textureNumLayers_sigs = &[_]O.OverloadSig{
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .sampled, .dimension = .@"2d_array" } }}, .result = .{ .fixed = Types.U32 } },
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .sampled, .dimension = .cube_array } }}, .result = .{ .fixed = Types.U32 } },
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .depth, .dimension = .@"2d_array" } }}, .result = .{ .fixed = Types.U32 } },
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .depth, .dimension = .cube_array } }}, .result = .{ .fixed = Types.U32 } },
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .storage, .dimension = .@"2d_array" } }}, .result = .{ .fixed = Types.U32 } },
};

/// textureNumLevels (§17.6.3) — mippable textures only. Excludes
/// multisampled, depth_multisampled, external, and storage per spec.
const textureNumLevels_sigs = &[_]O.OverloadSig{
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .sampled, .dimension = .@"1d" } }}, .result = .{ .fixed = Types.U32 } },
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .sampled, .dimension = .@"2d" } }}, .result = .{ .fixed = Types.U32 } },
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .sampled, .dimension = .@"2d_array" } }}, .result = .{ .fixed = Types.U32 } },
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .sampled, .dimension = .@"3d" } }}, .result = .{ .fixed = Types.U32 } },
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .sampled, .dimension = .cube } }}, .result = .{ .fixed = Types.U32 } },
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .sampled, .dimension = .cube_array } }}, .result = .{ .fixed = Types.U32 } },
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .depth, .dimension = .@"2d" } }}, .result = .{ .fixed = Types.U32 } },
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .depth, .dimension = .@"2d_array" } }}, .result = .{ .fixed = Types.U32 } },
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .depth, .dimension = .cube } }}, .result = .{ .fixed = Types.U32 } },
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .depth, .dimension = .cube_array } }}, .result = .{ .fixed = Types.U32 } },
};

/// textureNumSamples (§17.6.4) — multisampled textures only. Returns u32.
const textureNumSamples_sigs = &[_]O.OverloadSig{
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .multisampled, .dimension = .@"2d" } }}, .result = .{ .fixed = Types.U32 } },
    .{ .tparam_count = 0, .params = &.{.{ .tparam_texture = .{ .kind = .depth_multisampled, .dimension = .@"2d" } }}, .result = .{ .fixed = Types.U32 } },
};

// =========================================================================
// Sampling / gather overloads (§17.7.11–17.7.19)
// =========================================================================
//
// Declarative signatures for the sample / gather families. Uses
// `Pattern.tparam_texture` for kind+dimension matching, slot 0 for the
// sampled element scalar, and fixed results for depth/external. Sampler
// args are matched as concrete types against static singletons so
// `sampler_comparison` cannot stand in for `sampler` and vice versa.
//
// Offset is modeled as a shape-only `.concrete = vec2<i32>/vec3<i32>` —
// the spec's const-expression requirement is a pre-resolution side check
// not expressible via Pattern, and is not currently enforced. Landing
// that is orthogonal to overload dispatch.

const coord_2d_f32: O.Pattern = .{ .tparam_vector = .{ .elem_idx = no_tp, .elem_family = .float, .n_fixed = 2 } };
const coord_3d_f32: O.Pattern = .{ .tparam_vector = .{ .elem_idx = no_tp, .elem_family = .float, .n_fixed = 3 } };
const f32_scalar: O.Pattern = .{ .tparam_scalar = .{ .idx = no_tp, .family = .float } };
const offset_2d_i32: O.Pattern = .{ .concrete = vec2_i32_type };
const offset_3d_i32: O.Pattern = .{ .concrete = vec3_i32_type };

const sampler_noncmp_singleton = Types.Sampler{ .comparison = false };
const sampler_cmp_singleton = Types.Sampler{ .comparison = true };
const sampler_type: Types.Type = .{ .sampler = &sampler_noncmp_singleton };
const sampler_cmp_type: Types.Type = .{ .sampler = &sampler_cmp_singleton };
const sampler_pat: O.Pattern = .{ .concrete = sampler_type };
const sampler_cmp_pat: O.Pattern = .{ .concrete = sampler_cmp_type };

/// Build a `.tparam_texture` pattern binding slot 0 to the sampled
/// texture's element scalar. Used by sample/gather sampled overloads
/// whose result is `vec4<T>`.
fn sampledTex(comptime dim: Types.TextureDimension) O.Pattern {
    return .{ .tparam_texture = .{ .kind = .sampled, .dimension = dim, .elem_idx = 0 } };
}

fn depthTex(comptime dim: Types.TextureDimension) O.Pattern {
    return .{ .tparam_texture = .{ .kind = .depth, .dimension = dim } };
}

/// textureSample (§17.7.14) — sampled returns vec4<T>, depth returns f32.
/// Offsets valid on 2d / 2d_array / 3d (and their depth counterparts).
const textureSample_sigs = &[_]O.OverloadSig{
    // --- Sampled ---
    .{ .tparam_count = 1, .params = &.{ sampledTex(.@"2d"), sampler_pat, coord_2d_f32 }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ sampledTex(.@"2d"), sampler_pat, coord_2d_f32, offset_2d_i32 }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ sampledTex(.@"2d_array"), sampler_pat, coord_2d_f32, int_scalar }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ sampledTex(.@"2d_array"), sampler_pat, coord_2d_f32, int_scalar, offset_2d_i32 }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ sampledTex(.@"3d"), sampler_pat, coord_3d_f32 }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ sampledTex(.@"3d"), sampler_pat, coord_3d_f32, offset_3d_i32 }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ sampledTex(.cube), sampler_pat, coord_3d_f32 }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ sampledTex(.cube_array), sampler_pat, coord_3d_f32, int_scalar }, .result = vec4_of_slot0 },
    // --- Depth ---
    .{ .tparam_count = 0, .params = &.{ depthTex(.@"2d"), sampler_pat, coord_2d_f32 }, .result = .{ .fixed = Types.F32 } },
    .{ .tparam_count = 0, .params = &.{ depthTex(.@"2d"), sampler_pat, coord_2d_f32, offset_2d_i32 }, .result = .{ .fixed = Types.F32 } },
    .{ .tparam_count = 0, .params = &.{ depthTex(.@"2d_array"), sampler_pat, coord_2d_f32, int_scalar }, .result = .{ .fixed = Types.F32 } },
    .{ .tparam_count = 0, .params = &.{ depthTex(.@"2d_array"), sampler_pat, coord_2d_f32, int_scalar, offset_2d_i32 }, .result = .{ .fixed = Types.F32 } },
    .{ .tparam_count = 0, .params = &.{ depthTex(.cube), sampler_pat, coord_3d_f32 }, .result = .{ .fixed = Types.F32 } },
    .{ .tparam_count = 0, .params = &.{ depthTex(.cube_array), sampler_pat, coord_3d_f32, int_scalar }, .result = .{ .fixed = Types.F32 } },
};

/// textureSampleBias (§17.7.15) — sampled textures only. Bias is f32.
const textureSampleBias_sigs = &[_]O.OverloadSig{
    .{ .tparam_count = 1, .params = &.{ sampledTex(.@"2d"), sampler_pat, coord_2d_f32, f32_scalar }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ sampledTex(.@"2d"), sampler_pat, coord_2d_f32, f32_scalar, offset_2d_i32 }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ sampledTex(.@"2d_array"), sampler_pat, coord_2d_f32, int_scalar, f32_scalar }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ sampledTex(.@"2d_array"), sampler_pat, coord_2d_f32, int_scalar, f32_scalar, offset_2d_i32 }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ sampledTex(.@"3d"), sampler_pat, coord_3d_f32, f32_scalar }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ sampledTex(.@"3d"), sampler_pat, coord_3d_f32, f32_scalar, offset_3d_i32 }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ sampledTex(.cube), sampler_pat, coord_3d_f32, f32_scalar }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ sampledTex(.cube_array), sampler_pat, coord_3d_f32, int_scalar, f32_scalar }, .result = vec4_of_slot0 },
};

/// textureSampleGrad (§17.7.16) — sampled textures only. ddx/ddy share the
/// coord's vec-width (vec2 for 2d/2d_array, vec3 for 3d/cube/cube_array).
const textureSampleGrad_sigs = &[_]O.OverloadSig{
    .{ .tparam_count = 1, .params = &.{ sampledTex(.@"2d"), sampler_pat, coord_2d_f32, coord_2d_f32, coord_2d_f32 }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ sampledTex(.@"2d"), sampler_pat, coord_2d_f32, coord_2d_f32, coord_2d_f32, offset_2d_i32 }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ sampledTex(.@"2d_array"), sampler_pat, coord_2d_f32, int_scalar, coord_2d_f32, coord_2d_f32 }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ sampledTex(.@"2d_array"), sampler_pat, coord_2d_f32, int_scalar, coord_2d_f32, coord_2d_f32, offset_2d_i32 }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ sampledTex(.@"3d"), sampler_pat, coord_3d_f32, coord_3d_f32, coord_3d_f32 }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ sampledTex(.@"3d"), sampler_pat, coord_3d_f32, coord_3d_f32, coord_3d_f32, offset_3d_i32 }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ sampledTex(.cube), sampler_pat, coord_3d_f32, coord_3d_f32, coord_3d_f32 }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ sampledTex(.cube_array), sampler_pat, coord_3d_f32, int_scalar, coord_3d_f32, coord_3d_f32 }, .result = vec4_of_slot0 },
};

/// textureSampleLevel (§17.7.17) — sampled (level: f32) and depth (level: i32).
const textureSampleLevel_sigs = &[_]O.OverloadSig{
    // --- Sampled (level: f32) ---
    .{ .tparam_count = 1, .params = &.{ sampledTex(.@"2d"), sampler_pat, coord_2d_f32, f32_scalar }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ sampledTex(.@"2d"), sampler_pat, coord_2d_f32, f32_scalar, offset_2d_i32 }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ sampledTex(.@"2d_array"), sampler_pat, coord_2d_f32, int_scalar, f32_scalar }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ sampledTex(.@"2d_array"), sampler_pat, coord_2d_f32, int_scalar, f32_scalar, offset_2d_i32 }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ sampledTex(.@"3d"), sampler_pat, coord_3d_f32, f32_scalar }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ sampledTex(.@"3d"), sampler_pat, coord_3d_f32, f32_scalar, offset_3d_i32 }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ sampledTex(.cube), sampler_pat, coord_3d_f32, f32_scalar }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ sampledTex(.cube_array), sampler_pat, coord_3d_f32, int_scalar, f32_scalar }, .result = vec4_of_slot0 },
    // --- Depth (level: i32) ---
    .{ .tparam_count = 0, .params = &.{ depthTex(.@"2d"), sampler_pat, coord_2d_f32, int_scalar }, .result = .{ .fixed = Types.F32 } },
    .{ .tparam_count = 0, .params = &.{ depthTex(.@"2d"), sampler_pat, coord_2d_f32, int_scalar, offset_2d_i32 }, .result = .{ .fixed = Types.F32 } },
    .{ .tparam_count = 0, .params = &.{ depthTex(.@"2d_array"), sampler_pat, coord_2d_f32, int_scalar, int_scalar }, .result = .{ .fixed = Types.F32 } },
    .{ .tparam_count = 0, .params = &.{ depthTex(.@"2d_array"), sampler_pat, coord_2d_f32, int_scalar, int_scalar, offset_2d_i32 }, .result = .{ .fixed = Types.F32 } },
    .{ .tparam_count = 0, .params = &.{ depthTex(.cube), sampler_pat, coord_3d_f32, int_scalar }, .result = .{ .fixed = Types.F32 } },
    .{ .tparam_count = 0, .params = &.{ depthTex(.cube_array), sampler_pat, coord_3d_f32, int_scalar, int_scalar }, .result = .{ .fixed = Types.F32 } },
};

/// textureSampleCompare (§17.7.18) — depth textures + sampler_comparison.
/// Returns f32. Offsets valid on depth_2d / depth_2d_array.
const textureSampleCompare_sigs = &[_]O.OverloadSig{
    .{ .tparam_count = 0, .params = &.{ depthTex(.@"2d"), sampler_cmp_pat, coord_2d_f32, f32_scalar }, .result = .{ .fixed = Types.F32 } },
    .{ .tparam_count = 0, .params = &.{ depthTex(.@"2d"), sampler_cmp_pat, coord_2d_f32, f32_scalar, offset_2d_i32 }, .result = .{ .fixed = Types.F32 } },
    .{ .tparam_count = 0, .params = &.{ depthTex(.@"2d_array"), sampler_cmp_pat, coord_2d_f32, int_scalar, f32_scalar }, .result = .{ .fixed = Types.F32 } },
    .{ .tparam_count = 0, .params = &.{ depthTex(.@"2d_array"), sampler_cmp_pat, coord_2d_f32, int_scalar, f32_scalar, offset_2d_i32 }, .result = .{ .fixed = Types.F32 } },
    .{ .tparam_count = 0, .params = &.{ depthTex(.cube), sampler_cmp_pat, coord_3d_f32, f32_scalar }, .result = .{ .fixed = Types.F32 } },
    .{ .tparam_count = 0, .params = &.{ depthTex(.cube_array), sampler_cmp_pat, coord_3d_f32, int_scalar, f32_scalar }, .result = .{ .fixed = Types.F32 } },
};

/// textureSampleCompareLevel (§17.7.19) — same arities as Compare. Returns f32.
const textureSampleCompareLevel_sigs = textureSampleCompare_sigs;

/// textureGather (§17.7.12) — sampled prepends `component: i32/u32`, returns
/// vec4<T>. Depth has no component arg and returns vec4<f32>. 1d / 3d /
/// multisampled / storage / external textures are not permitted.
const textureGather_sigs = &[_]O.OverloadSig{
    // --- Sampled (component prepended) ---
    .{ .tparam_count = 1, .params = &.{ int_scalar, sampledTex(.@"2d"), sampler_pat, coord_2d_f32 }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ int_scalar, sampledTex(.@"2d"), sampler_pat, coord_2d_f32, offset_2d_i32 }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ int_scalar, sampledTex(.@"2d_array"), sampler_pat, coord_2d_f32, int_scalar }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ int_scalar, sampledTex(.@"2d_array"), sampler_pat, coord_2d_f32, int_scalar, offset_2d_i32 }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ int_scalar, sampledTex(.cube), sampler_pat, coord_3d_f32 }, .result = vec4_of_slot0 },
    .{ .tparam_count = 1, .params = &.{ int_scalar, sampledTex(.cube_array), sampler_pat, coord_3d_f32, int_scalar }, .result = vec4_of_slot0 },
    // --- Depth (no component) ---
    .{ .tparam_count = 0, .params = &.{ depthTex(.@"2d"), sampler_pat, coord_2d_f32 }, .result = .{ .fixed = vec4_f32_type } },
    .{ .tparam_count = 0, .params = &.{ depthTex(.@"2d"), sampler_pat, coord_2d_f32, offset_2d_i32 }, .result = .{ .fixed = vec4_f32_type } },
    .{ .tparam_count = 0, .params = &.{ depthTex(.@"2d_array"), sampler_pat, coord_2d_f32, int_scalar }, .result = .{ .fixed = vec4_f32_type } },
    .{ .tparam_count = 0, .params = &.{ depthTex(.@"2d_array"), sampler_pat, coord_2d_f32, int_scalar, offset_2d_i32 }, .result = .{ .fixed = vec4_f32_type } },
    .{ .tparam_count = 0, .params = &.{ depthTex(.cube), sampler_pat, coord_3d_f32 }, .result = .{ .fixed = vec4_f32_type } },
    .{ .tparam_count = 0, .params = &.{ depthTex(.cube_array), sampler_pat, coord_3d_f32, int_scalar }, .result = .{ .fixed = vec4_f32_type } },
};

/// textureGatherCompare (§17.7.13) — depth + sampler_comparison + depth_ref.
/// Returns vec4<f32>.
const textureGatherCompare_sigs = &[_]O.OverloadSig{
    .{ .tparam_count = 0, .params = &.{ depthTex(.@"2d"), sampler_cmp_pat, coord_2d_f32, f32_scalar }, .result = .{ .fixed = vec4_f32_type } },
    .{ .tparam_count = 0, .params = &.{ depthTex(.@"2d"), sampler_cmp_pat, coord_2d_f32, f32_scalar, offset_2d_i32 }, .result = .{ .fixed = vec4_f32_type } },
    .{ .tparam_count = 0, .params = &.{ depthTex(.@"2d_array"), sampler_cmp_pat, coord_2d_f32, int_scalar, f32_scalar }, .result = .{ .fixed = vec4_f32_type } },
    .{ .tparam_count = 0, .params = &.{ depthTex(.@"2d_array"), sampler_cmp_pat, coord_2d_f32, int_scalar, f32_scalar, offset_2d_i32 }, .result = .{ .fixed = vec4_f32_type } },
    .{ .tparam_count = 0, .params = &.{ depthTex(.cube), sampler_cmp_pat, coord_3d_f32, f32_scalar }, .result = .{ .fixed = vec4_f32_type } },
    .{ .tparam_count = 0, .params = &.{ depthTex(.cube_array), sampler_cmp_pat, coord_3d_f32, int_scalar, f32_scalar }, .result = .{ .fixed = vec4_f32_type } },
};

/// textureSampleBaseClampToEdge (§17.7.11) — texture_2d<f32> or
/// texture_external. Returns vec4<f32>. Restricting to f32-element
/// sampled textures uses the slot-0 family filter.
const textureSampleBaseClampToEdge_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 1,
        .params = &.{
            .{ .tparam_texture = .{ .kind = .sampled, .dimension = .@"2d", .elem_idx = 0, .elem_family = .float } },
            sampler_pat,
            coord_2d_f32,
        },
        .result = .{ .fixed = vec4_f32_type },
    },
    .{
        .tparam_count = 0,
        .params = &.{
            .{ .tparam_texture = .{ .kind = .external, .dimension = .@"2d" } },
            sampler_pat,
            coord_2d_f32,
        },
        .result = .{ .fixed = vec4_f32_type },
    },
};

// =========================================================================
// Same-as-arg overload families (§17.3 / §17.5 / §17.6 / §17.12)
// =========================================================================
//
// Declarative signatures for every numeric/derivative/subgroup builtin
// whose return type matches its first argument. Each shape (scalar,
// vecN<T>) is a separate overload; the solver picks the lowest-rank
// match. Where the shared shapes appear many times they're factored
// into the helpers below to keep the per-builtin lines short.
//
// Notation:
//   - `T` = scalar tparam (slot 0)
//   - `N` = vector-width tparam (slot 1)
//   - cols / rows for matrices occupy slots 1-2 (2 when square via same slot).

/// Single-param pattern `tparam_scalar{idx=0, family}`.
fn scalarParam(comptime family: O.ScalarFamily) O.Pattern {
    return .{ .tparam_scalar = .{ .idx = 0, .family = family } };
}

/// Single-param pattern `tparam_vector{elem=0, family, n_idx=1}`.
fn vectorParam(comptime family: O.ScalarFamily) O.Pattern {
    return .{ .tparam_vector = .{ .elem_idx = 0, .elem_family = family, .n_idx = 1 } };
}

fn vectorParamFixed(comptime family: O.ScalarFamily, comptime n: u8) O.Pattern {
    return .{ .tparam_vector = .{ .elem_idx = 0, .elem_family = family, .n_fixed = n } };
}

/// `(T) -> T` and `(vecN<T>) -> vecN<T>` for a given scalar family.
fn unarySigs(comptime family: O.ScalarFamily) []const O.OverloadSig {
    return &.{
        .{
            .tparam_count = 1,
            .params = &.{scalarParam(family)},
            .result = .{ .pattern = .{ .bound_scalar = 0 } },
        },
        .{
            .tparam_count = 2,
            .params = &.{vectorParam(family)},
            .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_idx = 1 } } },
        },
    };
}

/// `(T, T) -> T` and `(vecN<T>, vecN<T>) -> vecN<T>`. Every arg unifies to T.
fn binarySigs(comptime family: O.ScalarFamily) []const O.OverloadSig {
    return &.{
        .{
            .tparam_count = 1,
            .params = &.{ scalarParam(family), scalarParam(family) },
            .result = .{ .pattern = .{ .bound_scalar = 0 } },
        },
        .{
            .tparam_count = 2,
            .params = &.{ vectorParam(family), vectorParam(family) },
            .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_idx = 1 } } },
        },
    };
}

/// `(T, T, T) -> T` and `(vecN<T>, vecN<T>, vecN<T>) -> vecN<T>`.
fn ternarySigs(comptime family: O.ScalarFamily) []const O.OverloadSig {
    return &.{
        .{
            .tparam_count = 1,
            .params = &.{ scalarParam(family), scalarParam(family), scalarParam(family) },
            .result = .{ .pattern = .{ .bound_scalar = 0 } },
        },
        .{
            .tparam_count = 2,
            .params = &.{ vectorParam(family), vectorParam(family), vectorParam(family) },
            .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_idx = 1 } } },
        },
    };
}

// -------------------------------------------------------------------------
// Built from the helpers above. One `const` per shape × family combination
// the spec actually uses.
// -------------------------------------------------------------------------

const unary_float_sigs = unarySigs(.float);
const unary_int_sigs = unarySigs(.integer);
const unary_numeric_sigs = unarySigs(.numeric);
const binary_float_sigs = binarySigs(.float);
const binary_numeric_sigs = binarySigs(.numeric);
const ternary_float_sigs = ternarySigs(.float);
const ternary_numeric_sigs = ternarySigs(.numeric);

/// mix has a third overload where the blend factor is a scalar that
/// matches the vectors' element type: `(vecN<T>, vecN<T>, T) -> vecN<T>`.
const mix_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 1,
        .params = &.{ scalarParam(.float), scalarParam(.float), scalarParam(.float) },
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    },
    .{
        .tparam_count = 2,
        .params = &.{ vectorParam(.float), vectorParam(.float), vectorParam(.float) },
        .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_idx = 1 } } },
    },
    .{
        .tparam_count = 2,
        .params = &.{ vectorParam(.float), vectorParam(.float), .{ .bound_scalar = 0 } },
        .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_idx = 1 } } },
    },
};

/// `length(T) -> T` and `length(vecN<T>) -> T` (T ∈ float).
const length_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 1,
        .params = &.{scalarParam(.float)},
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    },
    .{
        .tparam_count = 2,
        .params = &.{vectorParam(.float)},
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    },
};

/// `distance(T, T) -> T` and `distance(vecN<T>, vecN<T>) -> T` (T ∈ float).
const distance_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 1,
        .params = &.{ scalarParam(.float), scalarParam(.float) },
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    },
    .{
        .tparam_count = 2,
        .params = &.{ vectorParam(.float), vectorParam(.float) },
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    },
};

/// `dot(vecN<T>, vecN<T>) -> T` — numeric-any per §17.5.15; no scalar form.
const dot_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 2,
        .params = &.{ vectorParam(.numeric), vectorParam(.numeric) },
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    },
};

/// `cross(vec3<T>, vec3<T>) -> vec3<T>` — float only, width pinned to 3.
const cross_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 1,
        .params = &.{ vectorParamFixed(.float, 3), vectorParamFixed(.float, 3) },
        .result = .{ .pattern = vectorParamFixed(.float, 3) },
    },
};

/// `normalize(vecN<T>) -> vecN<T>` — vector-only float.
const normalize_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 2,
        .params = &.{vectorParam(.float)},
        .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_idx = 1 } } },
    },
};

/// `reflect(vecN<T>, vecN<T>) -> vecN<T>` — float, vector-only.
const reflect_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 2,
        .params = &.{ vectorParam(.float), vectorParam(.float) },
        .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_idx = 1 } } },
    },
};

/// `refract(vecN<T>, vecN<T>, T) -> vecN<T>` — float, third arg is scalar eta.
const refract_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 2,
        .params = &.{ vectorParam(.float), vectorParam(.float), .{ .bound_scalar = 0 } },
        .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_idx = 1 } } },
    },
};

/// `faceForward(vecN<T>, vecN<T>, vecN<T>) -> vecN<T>` — float only.
const faceForward_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 2,
        .params = &.{ vectorParam(.float), vectorParam(.float), vectorParam(.float) },
        .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_idx = 1 } } },
    },
};

/// `determinant(matNxN<T>) -> T` — square float matrix. Squareness is
/// enforced by binding cols and rows to the same tparam slot: the second
/// `bindWidth` call fails if cols != rows.
const determinant_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 2,
        .params = &.{.{ .tparam_matrix = .{ .elem_idx = 0, .elem_family = .float, .cols_idx = 1, .rows_idx = 1 } }},
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    },
};

/// `ldexp(T, J) -> T` where T ∈ float and J ∈ int. Spec is stricter (J must
/// be i32/abstract-int, not u32) but WGSL let-default will concretize an
/// abstract-int arg to i32 at the use site, so .integer family is a safe
/// over-approximation here.
const ldexp_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 2, // slot 0 = T float, slot 1 = J int
        .params = &.{
            scalarParam(.float),
            .{ .tparam_scalar = .{ .idx = 1, .family = .integer } },
        },
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    },
    .{
        .tparam_count = 3, // slot 0 = T float, slot 1 = N, slot 2 = J int
        .params = &.{
            vectorParam(.float),
            .{ .tparam_vector = .{ .elem_idx = 2, .elem_family = .integer, .n_idx = 1 } },
        },
        .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_idx = 1 } } },
    },
};

/// `extractBits(e: T, offset: u32, count: u32) -> T` where T ∈ int.
const extractBits_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 1,
        .params = &.{ scalarParam(.integer), .{ .concrete = Types.U32 }, .{ .concrete = Types.U32 } },
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    },
    .{
        .tparam_count = 2,
        .params = &.{ vectorParam(.integer), .{ .concrete = Types.U32 }, .{ .concrete = Types.U32 } },
        .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_idx = 1 } } },
    },
};

/// `insertBits(e: T, newbits: T, offset: u32, count: u32) -> T` where T ∈ int.
const insertBits_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 1,
        .params = &.{
            scalarParam(.integer),
            .{ .bound_scalar = 0 },
            .{ .concrete = Types.U32 },
            .{ .concrete = Types.U32 },
        },
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    },
    .{
        .tparam_count = 2,
        .params = &.{
            vectorParam(.integer),
            .{ .tparam_vector = .{ .elem_idx = 0, .elem_family = .integer, .n_idx = 1 } },
            .{ .concrete = Types.U32 },
            .{ .concrete = Types.U32 },
        },
        .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_idx = 1 } } },
    },
};

/// `select(a: T, b: T, cond: bool) -> T` — any scalar or vecN of any scalar.
/// Vector forms also accept `vecN<bool>` for componentwise selection.
const select_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 1,
        .params = &.{ scalarParam(.any), scalarParam(.any), .{ .concrete = Types.Bool } },
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    },
    .{
        .tparam_count = 2,
        .params = &.{ vectorParam(.any), vectorParam(.any), .{ .concrete = Types.Bool } },
        .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_idx = 1 } } },
    },
    .{
        .tparam_count = 2,
        .params = &.{
            vectorParam(.any),
            vectorParam(.any),
            .{ .tparam_vector = .{ .elem_idx = O.Pattern.no_tparam, .elem_family = .bool, .n_idx = 1 } },
        },
        .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_idx = 1 } } },
    },
};

/// Subgroup / quad ops taking one numeric scalar-or-vector arg. Same shape
/// as `unarySigs(.numeric)` plus accept-bool variants where the spec needs
/// them. The numeric-only forms cover Add/Mul/And/Or/Xor/Min/Max/Inclusive*/
/// Exclusive* and quadSwap*.
const subgroup_unary_numeric_sigs = unary_numeric_sigs;

/// `subgroupBroadcast(e: T, id: u32) -> T` / `subgroupShuffle*(e, id-or-mask)`.
/// T ∈ {numeric scalar, numeric vector}; id is u32.
const subgroup_shuffle_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 1,
        .params = &.{ scalarParam(.numeric), .{ .concrete = Types.U32 } },
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    },
    .{
        .tparam_count = 2,
        .params = &.{ vectorParam(.numeric), .{ .concrete = Types.U32 } },
        .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 0, .n_idx = 1 } } },
    },
};

/// `quadBroadcast(e: T, id: u32) -> T` with T ∈ numeric. Shape identical
/// to subgroupBroadcast.
const quad_broadcast_sigs = subgroup_shuffle_sigs;

/// `all(bool) -> bool`, `all(vecN<bool>) -> bool` — same shape for `any`
/// and the subgroup reductions.
const bool_reduce_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 0,
        .params = &.{.{ .concrete = Types.Bool }},
        .result = .{ .fixed = Types.Bool },
    },
    .{
        .tparam_count = 1,
        .params = &.{.{ .tparam_vector = .{ .elem_idx = O.Pattern.no_tparam, .elem_family = .bool, .n_idx = 0 } }},
        .result = .{ .fixed = Types.Bool },
    },
};

/// `subgroupElect() -> bool` / `subgroupAll(bool) -> bool` / `subgroupAny(bool)`.
const subgroup_bool_reduce_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 0,
        .params = &.{.{ .concrete = Types.Bool }},
        .result = .{ .fixed = Types.Bool },
    },
};

const subgroup_elect_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 0,
        .params = &.{},
        .result = .{ .fixed = Types.Bool },
    },
};

/// pack2x16* take vec2<f32>; pack4x8* take vec4<f32>; pack4xI8* take
/// vec4<i32>; pack4xU8* take vec4<u32>. Static vec-type singletons are
/// reused from the unpack table above.
const pack_vec2_f32_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 0,
        .params = &.{.{ .concrete = vec2_f32_type }},
        .result = .{ .fixed = Types.U32 },
    },
};
const pack_vec4_f32_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 0,
        .params = &.{.{ .concrete = vec4_f32_type }},
        .result = .{ .fixed = Types.U32 },
    },
};
const pack_vec4_i32_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 0,
        .params = &.{.{ .concrete = vec4_i32_type }},
        .result = .{ .fixed = Types.U32 },
    },
};
const pack_vec4_u32_sigs = &[_]O.OverloadSig{
    .{
        .tparam_count = 0,
        .params = &.{.{ .concrete = vec4_u32_type }},
        .result = .{ .fixed = Types.U32 },
    },
};

/// Side-table entries — built at comptime to keep lookup O(1).
const sig_entries = [_]struct { []const u8, []const O.OverloadSig }{
    // Atomic operations (§17.9)
    .{ "atomicLoad", atomic_load_sigs },
    .{ "atomicAdd", atomic_rmw_sigs },
    .{ "atomicSub", atomic_rmw_sigs },
    .{ "atomicMax", atomic_rmw_sigs },
    .{ "atomicMin", atomic_rmw_sigs },
    .{ "atomicAnd", atomic_rmw_sigs },
    .{ "atomicOr", atomic_rmw_sigs },
    .{ "atomicXor", atomic_rmw_sigs },
    .{ "atomicExchange", atomic_rmw_sigs },
    .{ "atomicCompareExchangeWeak", atomic_cmp_xchg_sigs },
    .{ "atomicStore", atomic_store_sigs },

    // Array (§17.14)
    .{ "arrayLength", array_length_sigs },

    // Numeric special (§17.5)
    .{ "frexp", frexp_sigs },
    .{ "modf", modf_sigs },
    .{ "transpose", transpose_sigs },

    // Packing (§17.10)
    .{ "unpack4xI8", unpack4xI8_sigs },
    .{ "unpack4xU8", unpack4xU8_sigs },
    .{ "unpack4x8snorm", unpack4x8_float_sigs },
    .{ "unpack4x8unorm", unpack4x8_float_sigs },
    .{ "unpack2x16snorm", unpack2x16_float_sigs },
    .{ "unpack2x16unorm", unpack2x16_float_sigs },
    .{ "unpack2x16float", unpack2x16_float_sigs },

    // Packed dot product (§17.5.20)
    .{ "dot4I8Packed", dot4I8Packed_sigs },
    .{ "dot4U8Packed", dot4U8Packed_sigs },

    // Texture builtins (§17.6.x / §17.7.x) — Phases 3c + 3d. Every
    // texture builtin resolves through the declarative engine.
    .{ "textureLoad", textureLoad_sigs },
    .{ "textureStore", textureStore_sigs },
    .{ "textureDimensions", textureDimensions_sigs },
    .{ "textureNumLayers", textureNumLayers_sigs },
    .{ "textureNumLevels", textureNumLevels_sigs },
    .{ "textureNumSamples", textureNumSamples_sigs },
    .{ "textureSample", textureSample_sigs },
    .{ "textureSampleBias", textureSampleBias_sigs },
    .{ "textureSampleGrad", textureSampleGrad_sigs },
    .{ "textureSampleLevel", textureSampleLevel_sigs },
    .{ "textureSampleCompare", textureSampleCompare_sigs },
    .{ "textureSampleCompareLevel", textureSampleCompareLevel_sigs },
    .{ "textureGather", textureGather_sigs },
    .{ "textureGatherCompare", textureGatherCompare_sigs },
    .{ "textureSampleBaseClampToEdge", textureSampleBaseClampToEdge_sigs },

    // Synchronization (§17.11)
    .{ "workgroupUniformLoad", wg_uniform_load_sigs },
    .{ "workgroupBarrier", barrier_sigs },
    .{ "storageBarrier", barrier_sigs },
    .{ "textureBarrier", barrier_sigs },

    // Subgroup (§17.12)
    .{ "subgroupBallot", subgroup_ballot_sigs },

    // -------------------------------------------------------------------
    // Same-as-arg family (§17.3 / §17.5 / §17.6 / §17.12)
    // -------------------------------------------------------------------

    // Logical (§17.3) — select is polymorphic across any scalar.
    .{ "select", select_sigs },

    // Trigonometric (§17.5.1–17.5.6, §17.5.44–17.5.49).
    .{ "sin", unary_float_sigs },
    .{ "cos", unary_float_sigs },
    .{ "tan", unary_float_sigs },
    .{ "asin", unary_float_sigs },
    .{ "acos", unary_float_sigs },
    .{ "atan", unary_float_sigs },
    .{ "sinh", unary_float_sigs },
    .{ "cosh", unary_float_sigs },
    .{ "tanh", unary_float_sigs },
    .{ "asinh", unary_float_sigs },
    .{ "acosh", unary_float_sigs },
    .{ "atanh", unary_float_sigs },
    .{ "atan2", binary_float_sigs },

    // Exponential (§17.5.16–17.5.18, §17.5.37, §17.5.45).
    .{ "exp", unary_float_sigs },
    .{ "exp2", unary_float_sigs },
    .{ "log", unary_float_sigs },
    .{ "log2", unary_float_sigs },
    .{ "pow", binary_float_sigs },
    .{ "sqrt", unary_float_sigs },
    .{ "inverseSqrt", unary_float_sigs },

    // Misc math (§17.5 — abs/sign/floor/ceil/round/trunc/fract/min/max/clamp/
    // saturate/mix/step/smoothstep/fma/degrees/radians).
    .{ "abs", unary_numeric_sigs },
    .{ "sign", unary_numeric_sigs },
    .{ "floor", unary_float_sigs },
    .{ "ceil", unary_float_sigs },
    .{ "round", unary_float_sigs },
    .{ "trunc", unary_float_sigs },
    .{ "fract", unary_float_sigs },
    .{ "min", binary_numeric_sigs },
    .{ "max", binary_numeric_sigs },
    .{ "clamp", ternary_numeric_sigs },
    .{ "saturate", unary_float_sigs },
    .{ "mix", mix_sigs },
    .{ "step", binary_float_sigs },
    .{ "smoothstep", ternary_float_sigs },
    .{ "fma", ternary_float_sigs },
    .{ "degrees", unary_float_sigs },
    .{ "radians", unary_float_sigs },

    // Vector operations (§17.5.15, §17.5.19, §17.5.22–17.5.24, §17.5.37–39).
    .{ "dot", dot_sigs },
    .{ "cross", cross_sigs },
    .{ "length", length_sigs },
    .{ "distance", distance_sigs },
    .{ "normalize", normalize_sigs },
    .{ "reflect", reflect_sigs },
    .{ "refract", refract_sigs },
    .{ "faceForward", faceForward_sigs },

    // Bit manipulation (§17.5.10–17.5.14, §17.5.22–23, §17.5.41).
    .{ "countOneBits", unary_int_sigs },
    .{ "countLeadingZeros", unary_int_sigs },
    .{ "countTrailingZeros", unary_int_sigs },
    .{ "reverseBits", unary_int_sigs },
    .{ "firstLeadingBit", unary_int_sigs },
    .{ "firstTrailingBit", unary_int_sigs },
    .{ "extractBits", extractBits_sigs },
    .{ "insertBits", insertBits_sigs },

    // Matrix-reducing (§17.5.21).
    .{ "determinant", determinant_sigs },

    // Special (§17.5.32, §17.5.40).
    .{ "ldexp", ldexp_sigs },
    .{ "quantizeToF16", unary_float_sigs },

    // Derivatives (§17.6).
    .{ "dpdx", unary_float_sigs },
    .{ "dpdy", unary_float_sigs },
    .{ "fwidth", unary_float_sigs },
    .{ "dpdxCoarse", unary_float_sigs },
    .{ "dpdyCoarse", unary_float_sigs },
    .{ "fwidthCoarse", unary_float_sigs },
    .{ "dpdxFine", unary_float_sigs },
    .{ "dpdyFine", unary_float_sigs },
    .{ "fwidthFine", unary_float_sigs },

    // Subgroup / quad ops (§17.12 / §17.13).
    .{ "subgroupBroadcast", subgroup_shuffle_sigs },
    .{ "subgroupBroadcastFirst", subgroup_unary_numeric_sigs },
    .{ "subgroupShuffle", subgroup_shuffle_sigs },
    .{ "subgroupShuffleDown", subgroup_shuffle_sigs },
    .{ "subgroupShuffleUp", subgroup_shuffle_sigs },
    .{ "subgroupShuffleXor", subgroup_shuffle_sigs },
    .{ "subgroupAdd", subgroup_unary_numeric_sigs },
    .{ "subgroupMul", subgroup_unary_numeric_sigs },
    .{ "subgroupAnd", subgroup_unary_numeric_sigs },
    .{ "subgroupOr", subgroup_unary_numeric_sigs },
    .{ "subgroupXor", subgroup_unary_numeric_sigs },
    .{ "subgroupMin", subgroup_unary_numeric_sigs },
    .{ "subgroupMax", subgroup_unary_numeric_sigs },
    .{ "subgroupInclusiveAdd", subgroup_unary_numeric_sigs },
    .{ "subgroupInclusiveMul", subgroup_unary_numeric_sigs },
    .{ "subgroupExclusiveAdd", subgroup_unary_numeric_sigs },
    .{ "subgroupExclusiveMul", subgroup_unary_numeric_sigs },
    .{ "quadBroadcast", quad_broadcast_sigs },
    .{ "quadSwapDiagonal", subgroup_unary_numeric_sigs },
    .{ "quadSwapX", subgroup_unary_numeric_sigs },
    .{ "quadSwapY", subgroup_unary_numeric_sigs },

    // Logical reductions (§17.3).
    .{ "all", bool_reduce_sigs },
    .{ "any", bool_reduce_sigs },
    .{ "subgroupAll", subgroup_bool_reduce_sigs },
    .{ "subgroupAny", subgroup_bool_reduce_sigs },
    .{ "subgroupElect", subgroup_elect_sigs },

    // Data packing (§17.9).
    .{ "pack2x16snorm", pack_vec2_f32_sigs },
    .{ "pack2x16unorm", pack_vec2_f32_sigs },
    .{ "pack2x16float", pack_vec2_f32_sigs },
    .{ "pack4x8snorm", pack_vec4_f32_sigs },
    .{ "pack4x8unorm", pack_vec4_f32_sigs },
    .{ "pack4xI8", pack_vec4_i32_sigs },
    .{ "pack4xI8Clamp", pack_vec4_i32_sigs },
    .{ "pack4xU8", pack_vec4_u32_sigs },
    .{ "pack4xU8Clamp", pack_vec4_u32_sigs },
};

// =========================================================================
// Tests
// =========================================================================

test "builtins: lookup returns known builtins" {
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

test "builtins: lookup returns null for unknown names" {
    try std.testing.expect(lookup("notABuiltin") == null);
    try std.testing.expect(lookup("") == null);
    try std.testing.expect(lookup("SIN") == null);
}

test "builtins: isBuiltin matches lookup" {
    try std.testing.expect(isBuiltin("sin"));
    try std.testing.expect(isBuiltin("cos"));
    try std.testing.expect(isBuiltin("textureSample"));
    try std.testing.expect(isBuiltin("atomicAdd"));
    try std.testing.expect(isBuiltin("workgroupBarrier"));
    try std.testing.expect(!isBuiltin("notABuiltin"));
    try std.testing.expect(!isBuiltin(""));
}

test "builtins: checkArgCount validates argument counts" {
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

test "builtins: requiresUniform correctness" {
    // Derivative builtins require uniform flow.
    const names_uniform = [_][]const u8{
        "dpdx",             "dpdy",              "fwidth",
        "dpdxCoarse",       "dpdyCoarse",        "fwidthCoarse",
        "dpdxFine",         "dpdyFine",          "fwidthFine",
        "textureSample",    "textureSampleBias", "textureSampleCompare",
        "workgroupBarrier", "storageBarrier",    "textureBarrier",
        "quadBroadcast",    "quadSwapDiagonal",  "quadSwapX",          "quadSwapY",
    };
    for (names_uniform) |name| {
        const b = lookup(name).?;
        try std.testing.expect(b.requiresUniform());
    }

    // These do NOT require uniform flow.
    const names_no_uniform = [_][]const u8{
        "sin",                "cos",                       "abs",         "clamp",
        "textureSampleLevel", "textureSampleCompareLevel", "textureLoad", "textureStore",
        "atomicLoad",         "atomicAdd",
    };
    for (names_no_uniform) |name| {
        const b = lookup(name).?;
        try std.testing.expect(!b.requiresUniform());
    }
}

test "builtins: return patterns are assigned" {
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

test "builtins: every callable entry has declarative overloads" {
    // `Validator.checkBuiltinCall` asserts `overloads.len > 0` before
    // dispatching to the solver. This test enforces the invariant at the
    // table level so a missing sig table shows up here, not as an assert
    // failure on the first call at validation time. `bitcast` is exempt:
    // it dispatches through the dedicated `Validator.checkBitcastCall`
    // block which seeds tparams from the template type and selects from
    // `Builtins.bitcast_to_*_sigs` directly, so its `lookup().overloads`
    // is intentionally empty.
    for (table.keys()) |name| {
        if (std.mem.eql(u8, name, "bitcast")) continue;
        const b = lookup(name).?;
        if (b.overloads.len == 0) {
            std.debug.print("missing overloads: {s}\n", .{name});
            try std.testing.expect(false);
        }
    }
}

test "builtins: all Go builtins are registered" {
    // Exhaustive list of every builtin registered in the Go implementation.
    const all_names = [_][]const u8{
        // Conversion
        "bitcast",
        // Logical
        "all",
        "any",
        "select",
        // Array
        "arrayLength",
        // Trigonometric
        "sin",
        "cos",
        "tan",
        "asin",
        "acos",
        "atan",
        "sinh",
        "cosh",
        "tanh",
        "asinh",
        "acosh",
        "atanh",
        "atan2",
        // Exponential
        "exp",
        "exp2",
        "log",
        "log2",
        "pow",
        "sqrt",
        "inverseSqrt",
        // Misc math
        "abs",
        "sign",
        "floor",
        "ceil",
        "round",
        "trunc",
        "fract",
        "min",
        "max",
        "clamp",
        "saturate",
        "mix",
        "step",
        "smoothstep",
        "fma",
        "degrees",
        "radians",
        // Vector
        "dot",
        "dot4I8Packed",
        "dot4U8Packed",
        "cross",
        "length",
        "distance",
        "normalize",
        "reflect",
        "refract",
        "faceForward",
        // Bit
        "countOneBits",
        "countLeadingZeros",
        "countTrailingZeros",
        "reverseBits",
        "firstLeadingBit",
        "firstTrailingBit",
        "extractBits",
        "insertBits",
        // Matrix
        "transpose",
        "determinant",
        // Special
        "ldexp",
        "frexp",
        "modf",
        "quantizeToF16",
        // Derivative
        "dpdx",
        "dpdy",
        "fwidth",
        "dpdxCoarse",
        "dpdyCoarse",
        "fwidthCoarse",
        "dpdxFine",
        "dpdyFine",
        "fwidthFine",
        // Texture
        "textureSample",
        "textureSampleBias",
        "textureSampleCompare",
        "textureSampleCompareLevel",
        "textureSampleLevel",
        "textureSampleGrad",
        "textureLoad",
        "textureStore",
        "textureDimensions",
        "textureNumLayers",
        "textureNumLevels",
        "textureNumSamples",
        "textureGather",
        "textureGatherCompare",
        "textureSampleBaseClampToEdge",
        // Atomic
        "atomicLoad",
        "atomicStore",
        "atomicAdd",
        "atomicSub",
        "atomicMax",
        "atomicMin",
        "atomicAnd",
        "atomicOr",
        "atomicXor",
        "atomicExchange",
        "atomicCompareExchangeWeak",
        // Packing
        "pack4x8snorm",
        "pack4x8unorm",
        "pack2x16snorm",
        "pack2x16unorm",
        "pack2x16float",
        "pack4xI8",
        "pack4xU8",
        "pack4xI8Clamp",
        "pack4xU8Clamp",
        "unpack4x8snorm",
        "unpack4x8unorm",
        "unpack2x16snorm",
        "unpack2x16unorm",
        "unpack2x16float",
        "unpack4xI8",
        "unpack4xU8",
        // Synchronization
        "workgroupBarrier",
        "storageBarrier",
        "textureBarrier",
        "workgroupUniformLoad",
        // Subgroup
        "subgroupBallot",
        "subgroupBroadcast",
        "subgroupBroadcastFirst",
        "subgroupShuffle",
        "subgroupShuffleDown",
        "subgroupShuffleUp",
        "subgroupShuffleXor",
        "subgroupAdd",
        "subgroupMul",
        "subgroupAnd",
        "subgroupOr",
        "subgroupXor",
        "subgroupMin",
        "subgroupMax",
        "subgroupInclusiveAdd",
        "subgroupInclusiveMul",
        "subgroupExclusiveAdd",
        "subgroupExclusiveMul",
        "subgroupAll",
        "subgroupAny",
        "subgroupElect",
        // Quad
        "quadBroadcast",
        "quadSwapDiagonal",
        "quadSwapX",
        "quadSwapY",
    };

    for (all_names) |name| {
        const b = lookup(name);
        if (b == null) {
            std.debug.print("missing builtin: {s}\n", .{name});
        }
        try std.testing.expect(b != null);
    }
}

test "builtins: entry count matches Go implementation" {
    // Go has 119 builtins registered (counted from the source).
    // Verify we have at least that many entries.
    const total = builtin_entries.len;
    try std.testing.expect(total >= 126);
}

test "builtins: all builtins have documentation" {
    for (table.keys()) |name| {
        const has_doc = doc_table.has(name);
        if (!has_doc) {
            std.debug.print("Missing doc for builtin: {s}\n", .{name});
        }
        try std.testing.expect(has_doc);
    }
}

test "builtins: doc returns valid entries" {
    const sin_doc = doc("sin");
    try std.testing.expect(sin_doc != null);
    try std.testing.expect(sin_doc.?.signature.len > 0);
    try std.testing.expect(sin_doc.?.description.len > 0);

    const barrier_doc = doc("workgroupBarrier");
    try std.testing.expect(barrier_doc != null);

    try std.testing.expect(doc("notABuiltin") == null);
}
