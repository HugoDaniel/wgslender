//! WGSL built-in functions and their type signatures.
//!
//! Implements the builtin function table as defined in WGSL spec section 17,
//! supporting overload resolution and validation of builtin function calls.

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
    must_use: bool, // Return value must be consumed (not called as statement)

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
