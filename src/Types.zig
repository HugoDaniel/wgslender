//! WGSL type system for semantic validation.
//!
//! Implements the type system as defined in WGSL spec section 6,
//! supporting type inference, type checking, and overload resolution.

const std = @import("std");
const Ast = @import("Ast.zig");
const Allocator = std.mem.Allocator;

// =========================================================================
// Type (tagged union replacing Go's Type interface)
// =========================================================================

/// Represents a WGSL type. This tagged union replaces Go's interface pattern.
pub const Type = union(enum) {
    scalar: *const Scalar,
    vector: *const Vector,
    matrix: *const Matrix,
    array: *const Array,
    @"struct": *Struct,
    pointer: *const Pointer,
    reference: *const Reference,
    atomic: *const Atomic,
    sampler: *const Sampler,
    texture: *const Texture,
    function: *const Function,
    void_type: void,

    /// Returns the WGSL syntax for this type.
    pub fn string(self: Type) []const u8 {
        return switch (self) {
            .scalar => |s| s.string(),
            .vector => |v| v.string(),
            .matrix => |m| m.string(),
            .array => |a| a.string(),
            .@"struct" => |s| s.name,
            .pointer => |p| p.string(),
            .reference => |r| r.string(),
            .atomic => |a| a.string(),
            .sampler => |s| s.string(),
            .texture => |t| t.string(),
            .function => |f| f.string(),
            .void_type => "void",
        };
    }

    /// Returns true if this type equals another type.
    /// Iteratively compares two types for equality, following element chains.
    pub fn eql(self: Type, other: Type) bool {
        var a = self;
        var b = other;
        for (0..32) |_| {
            const a_tag = std.meta.activeTag(a);
            const b_tag = std.meta.activeTag(b);
            if (a_tag != b_tag) return false;

            switch (a) {
                .scalar => |s| return s.kind == b.scalar.kind,
                .vector => |v| return v.width == b.vector.width and v.element.kind == b.vector.element.kind,
                .matrix => |m| return m.cols == b.matrix.cols and m.rows == b.matrix.rows and m.element.kind == b.matrix.element.kind,
                .array => |ar| {
                    if (ar.count != b.array.count) return false;
                    a = ar.element;
                    b = b.array.element;
                },
                .@"struct" => |s| return std.mem.eql(u8, s.name, b.@"struct".name),
                .pointer => |p| {
                    if (p.address_space != b.pointer.address_space or p.access_mode != b.pointer.access_mode) return false;
                    a = p.element;
                    b = b.pointer.element;
                },
                .reference => |r| {
                    if (r.address_space != b.reference.address_space or r.access_mode != b.reference.access_mode) return false;
                    a = r.element;
                    b = b.reference.element;
                },
                .atomic => |at| return at.element.kind == b.atomic.element.kind,
                .sampler => |s| return s.comparison == b.sampler.comparison,
                .texture => |t| return t.eqlTexture(b.texture),
                .function => |f| return f.eqlFunction(b.function),
                .void_type => return true,
            }
        } else unreachable;
    }

    /// Returns true if this type is a runtime-sized array.
    pub fn isRuntimeSizedArray(self: Type) bool {
        return switch (self) {
            .array => |a| a.isRuntimeSized(),
            else => false,
        };
    }

    /// Returns true if values of this type can be constructed.
    /// Follows array element chains iteratively.
    pub fn isConstructible(self: Type) bool {
        var current = self;
        for (0..32) |_| {
            switch (current) {
                .scalar => |s| return s.isConcrete(),
                .vector => |v| return v.element.isConcrete(),
                .matrix => |m| return m.element.isConcrete(),
                .array => |a| {
                    if (a.count == 0) return false;
                    current = a.element;
                },
                .@"struct" => |s| return s.isConstructibleStruct(),
                .pointer, .reference, .atomic, .sampler, .texture, .function, .void_type => return false,
            }
        } else unreachable;
    }

    /// Returns true if this is not an abstract type.
    /// Follows array element chains iteratively.
    pub fn isConcrete(self: Type) bool {
        var current = self;
        for (0..32) |_| {
            switch (current) {
                .scalar => |s| return s.isConcrete(),
                .vector => |v| return v.element.isConcrete(),
                .matrix => |m| return m.element.isConcrete(),
                .array => |a| current = a.element,
                .@"struct" => |s| return s.isConcreteStruct(),
                .pointer, .reference, .atomic, .sampler, .texture, .function, .void_type => return true,
            }
        } else unreachable;
    }

    /// Returns true if values can be stored in memory.
    /// Follows array element chains iteratively.
    pub fn isStorable(self: Type) bool {
        var current = self;
        for (0..32) |_| {
            switch (current) {
                .scalar => |s| return s.isConcrete(),
                .vector => |v| return v.element.isConcrete(),
                .matrix => |m| return m.element.isConcrete(),
                .array => |a| current = a.element,
                .@"struct" => |s| return s.isStorableStruct(),
                .atomic => return true,
                .pointer, .reference, .sampler, .texture, .function, .void_type => return false,
            }
        } else unreachable;
    }

    /// Returns true if this type can cross the CPU/GPU boundary.
    /// Follows array element chains iteratively.
    pub fn isHostShareable(self: Type) bool {
        var current = self;
        for (0..32) |_| {
            switch (current) {
                .scalar => |s| return s.kind != .bool and s.isConcrete(),
                .vector => |v| return v.element.kind != .bool and v.element.isConcrete(),
                .matrix => |m| return m.element.isConcrete(),
                .array => |a| current = a.element,
                .@"struct" => |s| return s.isHostShareableStruct(),
                .atomic => return true,
                .pointer, .reference, .sampler, .texture, .function, .void_type => return false,
            }
        } else unreachable;
    }

    /// Returns the size in bytes (0 for unsized types).
    pub fn size(self: Type) u32 {
        return switch (self) {
            .scalar => |s| s.size(),
            .vector => |v| v.size(),
            .matrix => |m| m.size(),
            .array => |a| a.sizeBytes(),
            .@"struct" => |s| s.size_bytes,
            .atomic => |a| a.element.size(),
            .pointer, .reference, .sampler, .texture, .function, .void_type => 0,
        };
    }

    /// Returns the alignment in bytes.
    pub fn alignment(self: Type) u32 {
        return switch (self) {
            .scalar => |s| s.size(),
            .vector => |v| v.alignment(),
            .matrix => |m| m.alignment(),
            .array => |a| a.element.alignment(),
            .@"struct" => |s| s.align_bytes,
            .atomic => |a| a.element.size(),
            .pointer, .reference, .sampler, .texture, .function, .void_type => 0,
        };
    }
};

// =========================================================================
// Scalar Types
// =========================================================================

/// Represents the kind of scalar type.
pub const ScalarKind = enum(u8) {
    bool,
    i32,
    u32,
    f32,
    f16,
    abstract_int,
    abstract_float,
};

/// Represents a scalar type (bool, i32, u32, f32, f16, abstract-int, abstract-float).
pub const Scalar = struct {
    kind: ScalarKind,

    pub fn string(self: *const Scalar) []const u8 {
        return switch (self.kind) {
            .bool => "bool",
            .i32 => "i32",
            .u32 => "u32",
            .f32 => "f32",
            .f16 => "f16",
            .abstract_int => "abstract-int",
            .abstract_float => "abstract-float",
        };
    }

    /// Returns true if this is not an abstract type.
    pub fn isConcrete(self: *const Scalar) bool {
        return self.kind != .abstract_int and self.kind != .abstract_float;
    }

    /// Returns true if this is a numeric scalar type (not bool).
    pub fn isNumeric(self: *const Scalar) bool {
        return self.kind != .bool;
    }

    /// Returns true if this is an integer type.
    pub fn isInteger(self: *const Scalar) bool {
        return self.kind == .i32 or self.kind == .u32 or self.kind == .abstract_int;
    }

    /// Returns true if this is a floating-point type.
    pub fn isFloat(self: *const Scalar) bool {
        return self.kind == .f32 or self.kind == .f16 or self.kind == .abstract_float;
    }

    /// Returns the size in bytes (0 for abstract types).
    pub fn size(self: *const Scalar) u32 {
        return switch (self.kind) {
            .bool, .i32, .u32, .f32 => 4,
            .f16 => 2,
            .abstract_int, .abstract_float => 0,
        };
    }
};

// =========================================================================
// Vector Types
// =========================================================================

/// Represents vec2<T>, vec3<T>, vec4<T>.
pub const Vector = struct {
    width: u8, // 2, 3, or 4
    element: *const Scalar,

    // Pre-formatted strings for common vector types to avoid runtime formatting.
    // Indexed by [width_idx][kind], where width_idx = width - 2.
    const string_table = init: {
        @setEvalBranchQuota(100_000);
        var table: [3][7][]const u8 = undefined;
        const widths = [_]u8{ 2, 3, 4 };
        const kind_names = [_][]const u8{ "bool", "i32", "u32", "f32", "f16", "abstract-int", "abstract-float" };
        for (widths, 0..) |w, wi| {
            for (kind_names, 0..) |kn, ki| {
                table[wi][ki] = std.fmt.comptimePrint("vec{d}<{s}>", .{ w, kn });
            }
        }
        break :init table;
    };

    pub fn string(self: *const Vector) []const u8 {
        if (self.width >= 2 and self.width <= 4) {
            return string_table[self.width - 2][@intFromEnum(self.element.kind)];
        }
        return "vec?<?>";
    }

    pub fn size(self: *const Vector) u32 {
        return self.element.size() * @as(u32, self.width);
    }

    /// vec2 aligns to 2*element, vec3 and vec4 align to 4*element.
    pub fn alignment(self: *const Vector) u32 {
        if (self.width == 2) {
            return self.element.size() * 2;
        }
        return self.element.size() * 4;
    }
};

// =========================================================================
// Matrix Types
// =========================================================================

/// Represents matCxR<T>.
pub const Matrix = struct {
    cols: u8, // 2, 3, or 4
    rows: u8, // 2, 3, or 4
    element: *const Scalar,

    // Pre-formatted strings for common matrix types.
    // Indexed by [col_idx][row_idx][kind], col_idx = cols - 2, row_idx = rows - 2.
    const string_table = init: {
        @setEvalBranchQuota(200_000);
        var table: [3][3][7][]const u8 = undefined;
        const dims = [_]u8{ 2, 3, 4 };
        const kind_names = [_][]const u8{ "bool", "i32", "u32", "f32", "f16", "abstract-int", "abstract-float" };
        for (dims, 0..) |c, ci| {
            for (dims, 0..) |r, ri| {
                for (kind_names, 0..) |kn, ki| {
                    table[ci][ri][ki] = std.fmt.comptimePrint("mat{d}x{d}<{s}>", .{ c, r, kn });
                }
            }
        }
        break :init table;
    };

    pub fn string(self: *const Matrix) []const u8 {
        if (self.cols >= 2 and self.cols <= 4 and self.rows >= 2 and self.rows <= 4) {
            return string_table[self.cols - 2][self.rows - 2][@intFromEnum(self.element.kind)];
        }
        return "mat?x?<?>";
    }

    /// Matrix size is column_vector_align * cols.
    pub fn size(self: *const Matrix) u32 {
        return self.columnVectorAlign() * @as(u32, self.cols);
    }

    /// Matrix aligns to column vector alignment.
    pub fn alignment(self: *const Matrix) u32 {
        return self.columnVectorAlign();
    }

    fn columnVectorAlign(self: *const Matrix) u32 {
        // Column vector alignment: vec2 -> 2*elem, vec3/vec4 -> 4*elem.
        if (self.rows == 2) {
            return self.element.size() * 2;
        }
        return self.element.size() * 4;
    }
};

// =========================================================================
// Array Types
// =========================================================================

/// Represents array<T, N> or array<T> (runtime-sized).
pub const Array = struct {
    element: Type,
    count: u32, // 0 for runtime-sized arrays

    pub fn string(self: *const Array) []const u8 {
        _ = self;
        // Arrays have parametric types; the full string depends on element type.
        // The caller (printer) should format this directly.
        return "array";
    }

    /// Returns true if this is a runtime-sized array.
    pub fn isRuntimeSized(self: *const Array) bool {
        return self.count == 0;
    }

    /// Array stride is element size rounded up to element alignment.
    pub fn sizeBytes(self: *const Array) u32 {
        if (self.count == 0) return 0;
        const elem_size = self.element.size();
        const elem_align = self.element.alignment();
        if (elem_align == 0) return 0;
        const stride = ((elem_size + elem_align - 1) / elem_align) * elem_align;
        return stride * self.count;
    }
};

// =========================================================================
// Struct Types
// =========================================================================

/// Represents a struct member.
pub const StructField = struct {
    name: []const u8,
    typ: Type,
    offset: u32, // Computed during layout
};

/// Represents a user-defined struct type.
pub const Struct = struct {
    name: []const u8,
    fields: []StructField,
    size_bytes: u32,
    align_bytes: u32,
    has_runtime_array: bool,

    /// Computes field offsets, struct size, and alignment.
    pub fn computeLayout(self: *Struct) void {
        var offset: u32 = 0;
        var max_align: u32 = 1;

        for (self.fields) |*f| {
            const field_align = f.typ.alignment();
            if (field_align > max_align) {
                max_align = field_align;
            }

            // Align the offset.
            if (field_align > 0) {
                offset = ((offset + field_align - 1) / field_align) * field_align;
            }
            f.offset = offset;

            // Check for runtime-sized array (only valid as last field).
            if (f.typ == .array) {
                if (f.typ.array.isRuntimeSized()) {
                    self.has_runtime_array = true;
                }
            }

            offset += f.typ.size();
        }

        // Struct size is rounded up to alignment.
        self.align_bytes = max_align;
        self.size_bytes = ((offset + max_align - 1) / max_align) * max_align;
    }

    /// Returns the field with the given name, or null.
    pub fn getField(self: *const Struct, name: []const u8) ?*const StructField {
        for (self.fields) |*f| {
            if (std.mem.eql(u8, f.name, name)) {
                return f;
            }
        }
        return null;
    }

    fn isConstructibleStruct(self: *const Struct) bool {
        if (self.has_runtime_array) return false;
        for (self.fields) |f| {
            if (!f.typ.isConstructible()) return false;
        }
        return true;
    }

    fn isConcreteStruct(self: *const Struct) bool {
        for (self.fields) |f| {
            if (!f.typ.isConcrete()) return false;
        }
        return true;
    }

    fn isStorableStruct(self: *const Struct) bool {
        for (self.fields) |f| {
            if (!f.typ.isStorable()) return false;
        }
        return true;
    }

    fn isHostShareableStruct(self: *const Struct) bool {
        for (self.fields) |f| {
            if (!f.typ.isHostShareable()) return false;
        }
        return true;
    }
};

// =========================================================================
// Pointer Types
// =========================================================================

/// Represents ptr<space, T, access>.
pub const Pointer = struct {
    address_space: Ast.AddressSpace,
    element: Type,
    access_mode: Ast.AccessMode,

    pub fn string(self: *const Pointer) []const u8 {
        _ = self;
        // Full formatting deferred to printer.
        return "ptr";
    }
};

// =========================================================================
// Reference Types
// =========================================================================

/// Represents a reference type (implicit pointer).
pub const Reference = struct {
    address_space: Ast.AddressSpace,
    element: Type,
    access_mode: Ast.AccessMode,

    pub fn string(self: *const Reference) []const u8 {
        _ = self;
        return "ref";
    }
};

// =========================================================================
// Atomic Types
// =========================================================================

/// Represents atomic<T>. Element must be i32 or u32.
pub const Atomic = struct {
    element: *const Scalar,

    pub fn string(self: *const Atomic) []const u8 {
        _ = self;
        return "atomic";
    }
};

// =========================================================================
// Sampler Types
// =========================================================================

/// Represents sampler or sampler_comparison.
pub const Sampler = struct {
    comparison: bool,

    pub fn string(self: *const Sampler) []const u8 {
        if (self.comparison) return "sampler_comparison";
        return "sampler";
    }
};

// =========================================================================
// Texture Types
// =========================================================================

/// Indicates the texture category.
pub const TextureKind = enum(u8) {
    sampled,
    multisampled,
    storage,
    depth,
    depth_multisampled,
    external,
};

/// Indicates texture dimensionality.
pub const TextureDimension = enum(u8) {
    @"1d",
    @"2d",
    @"2d_array",
    @"3d",
    cube,
    cube_array,

    pub fn string(self: TextureDimension) []const u8 {
        return switch (self) {
            .@"1d" => "1d",
            .@"2d" => "2d",
            .@"2d_array" => "2d_array",
            .@"3d" => "3d",
            .cube => "cube",
            .cube_array => "cube_array",
        };
    }
};

/// Represents texture types.
pub const Texture = struct {
    kind: TextureKind,
    dimension: TextureDimension,
    sampled_type: ?*const Scalar, // For sampled textures.
    texel_format: []const u8, // For storage textures.
    access_mode: Ast.AccessMode,

    /// Renders the WGSL surface syntax for this texture type:
    /// `texture_2d<f32>`, `texture_storage_2d<rgba8unorm, write>`,
    /// `texture_depth_cube`, etc. Output goes into a small rotating
    /// static buffer pool (4 slots) so multiple `string()` calls in a
    /// single format expression don't overwrite each other. Not thread-
    /// safe — wgslender processes each document on one thread.
    pub fn string(self: *const Texture) []const u8 {
        const S = struct {
            var slots: [4][96]u8 = undefined;
            var next: usize = 0;
        };
        const buf = &S.slots[S.next];
        S.next = (S.next + 1) % S.slots.len;
        return formatInto(self, buf) catch "texture";
    }

    fn formatInto(self: *const Texture, buf: []u8) std.fmt.BufPrintError![]const u8 {
        const dim = self.dimension.string();
        return switch (self.kind) {
            .sampled => std.fmt.bufPrint(buf, "texture_{s}<{s}>", .{
                dim,
                if (self.sampled_type) |s| s.string() else "f32",
            }),
            .multisampled => std.fmt.bufPrint(buf, "texture_multisampled_{s}<{s}>", .{
                dim,
                if (self.sampled_type) |s| s.string() else "f32",
            }),
            .storage => if (self.access_mode == .none)
                std.fmt.bufPrint(buf, "texture_storage_{s}<{s}>", .{ dim, self.texel_format })
            else
                std.fmt.bufPrint(buf, "texture_storage_{s}<{s}, {s}>", .{
                    dim,
                    self.texel_format,
                    self.access_mode.string(),
                }),
            .depth => std.fmt.bufPrint(buf, "texture_depth_{s}", .{dim}),
            .depth_multisampled => std.fmt.bufPrint(buf, "texture_depth_multisampled_{s}", .{dim}),
            .external => "texture_external",
        };
    }

    fn eqlTexture(self: *const Texture, other: *const Texture) bool {
        if (self.kind != other.kind) return false;
        if (self.dimension != other.dimension) return false;
        if (self.sampled_type != null and other.sampled_type != null) {
            if (self.sampled_type.?.kind != other.sampled_type.?.kind) return false;
        } else if (self.sampled_type != null or other.sampled_type != null) {
            return false;
        }
        if (!std.mem.eql(u8, self.texel_format, other.texel_format)) return false;
        return self.access_mode == other.access_mode;
    }
};

// =========================================================================
// Function Types
// =========================================================================

/// Represents a function type signature.
pub const Function = struct {
    parameters: []const Type,
    return_type: ?Type, // null for void

    pub fn string(self: *const Function) []const u8 {
        _ = self;
        // Full formatting deferred to printer.
        return "fn";
    }

    fn eqlFunction(self: *const Function, other: *const Function) bool {
        if (self.parameters.len != other.parameters.len) return false;
        for (self.parameters, other.parameters) |a, b| {
            if (!a.eql(b)) return false;
        }
        if (self.return_type == null and other.return_type == null) return true;
        if (self.return_type == null or other.return_type == null) return false;
        return self.return_type.?.eql(other.return_type.?);
    }
};

// =========================================================================
// Singleton Type Instances
// =========================================================================

pub const Bool: Type = .{ .scalar = &scalar_bool };
pub const I32: Type = .{ .scalar = &scalar_i32 };
pub const U32: Type = .{ .scalar = &scalar_u32 };
pub const F32: Type = .{ .scalar = &scalar_f32 };
pub const F16: Type = .{ .scalar = &scalar_f16 };
pub const AbstractInt: Type = .{ .scalar = &scalar_abstract_int };
pub const AbstractFloat: Type = .{ .scalar = &scalar_abstract_float };
pub const Void: Type = .{ .void_type = {} };

const scalar_bool = Scalar{ .kind = .bool };
const scalar_i32 = Scalar{ .kind = .i32 };
const scalar_u32 = Scalar{ .kind = .u32 };
const scalar_f32 = Scalar{ .kind = .f32 };
const scalar_f16 = Scalar{ .kind = .f16 };
const scalar_abstract_int = Scalar{ .kind = .abstract_int };
const scalar_abstract_float = Scalar{ .kind = .abstract_float };

// Singleton scalar pointers for use in constructor helpers.
pub const scalar_bool_ptr: *const Scalar = &scalar_bool;
pub const scalar_i32_ptr: *const Scalar = &scalar_i32;
pub const scalar_u32_ptr: *const Scalar = &scalar_u32;
pub const scalar_f32_ptr: *const Scalar = &scalar_f32;
pub const scalar_f16_ptr: *const Scalar = &scalar_f16;
pub const scalar_abstract_int_ptr: *const Scalar = &scalar_abstract_int;
pub const scalar_abstract_float_ptr: *const Scalar = &scalar_abstract_float;

// =========================================================================
// Constructor Helpers
// =========================================================================

/// Creates a vector type. Caller must ensure the returned pointer lives long enough.
pub fn vec(allocator: Allocator, width: u8, elem: *const Scalar) Allocator.Error!Type {
    std.debug.assert(width >= 2 and width <= 4);
    const v = try allocator.create(Vector);
    v.* = .{ .width = width, .element = elem };
    return .{ .vector = v };
}

/// Creates a matrix type.
pub fn mat(allocator: Allocator, cols: u8, rows: u8, elem: *const Scalar) Allocator.Error!Type {
    std.debug.assert(cols >= 2 and cols <= 4);
    std.debug.assert(rows >= 2 and rows <= 4);
    const m = try allocator.create(Matrix);
    m.* = .{ .cols = cols, .rows = rows, .element = elem };
    return .{ .matrix = m };
}

/// Creates a fixed-size array type.
pub fn arr(allocator: Allocator, elem: Type, count: u32) Allocator.Error!Type {
    std.debug.assert(count > 0);
    const a = try allocator.create(Array);
    a.* = .{ .element = elem, .count = count };
    return .{ .array = a };
}

/// Creates a runtime-sized array type.
pub fn runtimeArray(allocator: Allocator, elem: Type) Allocator.Error!Type {
    const a = try allocator.create(Array);
    a.* = .{ .element = elem, .count = 0 };
    return .{ .array = a };
}

/// Creates a pointer type.
pub fn ptr(allocator: Allocator, space: Ast.AddressSpace, elem: Type, access: Ast.AccessMode) Allocator.Error!Type {
    const p = try allocator.create(Pointer);
    p.* = .{ .address_space = space, .element = elem, .access_mode = access };
    return .{ .pointer = p };
}

/// Creates a reference type.
pub fn ref(allocator: Allocator, space: Ast.AddressSpace, elem: Type, access: Ast.AccessMode) Allocator.Error!Type {
    const r = try allocator.create(Reference);
    r.* = .{ .address_space = space, .element = elem, .access_mode = access };
    return .{ .reference = r };
}

/// Creates an atomic type.
pub fn atomicType(allocator: Allocator, elem: *const Scalar) Allocator.Error!Type {
    const a = try allocator.create(Atomic);
    a.* = .{ .element = elem };
    return .{ .atomic = a };
}

/// Creates a sampler type.
pub fn samplerType(allocator: Allocator, comparison: bool) Allocator.Error!Type {
    const s = try allocator.create(Sampler);
    s.* = .{ .comparison = comparison };
    return .{ .sampler = s };
}

/// Creates a struct type. Caller provides the fields slice.
pub fn structType(allocator: Allocator, name: []const u8, fields: []StructField) Allocator.Error!Type {
    const s = try allocator.create(Struct);
    s.* = .{
        .name = name,
        .fields = fields,
        .size_bytes = 0,
        .align_bytes = 0,
        .has_runtime_array = false,
    };
    return .{ .@"struct" = s };
}

/// Creates a function type.
pub fn functionType(allocator: Allocator, parameters: []const Type, return_type: ?Type) Allocator.Error!Type {
    const f = try allocator.create(Function);
    f.* = .{ .parameters = parameters, .return_type = return_type };
    return .{ .function = f };
}

/// Creates a texture type.
pub fn textureType(
    allocator: Allocator,
    kind: TextureKind,
    dimension: TextureDimension,
    sampled_type_scalar: ?*const Scalar,
    texel_format: []const u8,
    access_mode: Ast.AccessMode,
) Allocator.Error!Type {
    const t = try allocator.create(Texture);
    t.* = .{
        .kind = kind,
        .dimension = dimension,
        .sampled_type = sampled_type_scalar,
        .texel_format = texel_format,
        .access_mode = access_mode,
    };
    return .{ .texture = t };
}

// =========================================================================
// Type Query Functions
// =========================================================================

/// Returns true if t is a scalar type.
pub fn isScalar(t: Type) bool {
    return t == .scalar;
}

/// Returns true if t is a vector type.
pub fn isVector(t: Type) bool {
    return t == .vector;
}

/// Returns true if t is a matrix type.
pub fn isMatrix(t: Type) bool {
    return t == .matrix;
}

/// Returns true if t is an array type.
pub fn isArray(t: Type) bool {
    return t == .array;
}

/// Returns true if t is a struct type.
pub fn isStruct(t: Type) bool {
    return t == .@"struct";
}

/// Returns true if t is a pointer type.
pub fn isPointer(t: Type) bool {
    return t == .pointer;
}

/// Returns true if t is a reference type.
pub fn isReference(t: Type) bool {
    return t == .reference;
}

/// Returns true if t is a texture type.
pub fn isTexture(t: Type) bool {
    return t == .texture;
}

/// Returns true if t is a sampler type.
pub fn isSampler(t: Type) bool {
    return t == .sampler;
}

/// Returns true if t is a numeric type (scalar or vector of numeric).
pub fn isNumeric(t: Type) bool {
    return switch (t) {
        .scalar => |s| s.isNumeric(),
        .vector => |v| v.element.isNumeric(),
        else => false,
    };
}

/// Returns true if t is an integer type (scalar or vector of integer).
pub fn isInteger(t: Type) bool {
    return switch (t) {
        .scalar => |s| s.isInteger(),
        .vector => |v| v.element.isInteger(),
        else => false,
    };
}

/// Returns true if t is a floating-point type.
pub fn isFloat(t: Type) bool {
    return switch (t) {
        .scalar => |s| s.isFloat(),
        .vector => |v| v.element.isFloat(),
        else => false,
    };
}

/// Returns the scalar element type of a composite type, or null.
pub fn scalarOf(t: Type) ?Type {
    return switch (t) {
        .scalar => t,
        .vector => |v| .{ .scalar = v.element },
        .matrix => |m| .{ .scalar = m.element },
        else => null,
    };
}

/// Maps a WGSL texel format string to its scalar type.
pub fn texelFormatToScalar(format: []const u8) *const Scalar {
    if (format.len == 0) return scalar_f32_ptr;
    if (std.mem.endsWith(u8, format, "uint")) return scalar_u32_ptr;
    if (std.mem.endsWith(u8, format, "sint")) return scalar_i32_ptr;
    return scalar_f32_ptr; // unorm, snorm, float formats
}

/// Returns the element type of composite types, or null.
pub fn elementType(allocator: Allocator, t: Type) Allocator.Error!?Type {
    return switch (t) {
        .vector => |v| .{ .scalar = v.element },
        .matrix => |m| try vec(allocator, m.rows, m.element),
        .array => |a| a.element,
        .pointer => |p| p.element,
        .reference => |r| r.element,
        .atomic => |a| .{ .scalar = a.element },
        else => null,
    };
}

// =========================================================================
// Type Conversion and Inference
// =========================================================================

/// Returns the WGSL ConversionRank from `src` to `dst` per spec §8.2
/// (bikeshed lines 2436+). Lower ranks are more desirable; `null` means
/// the conversion is infeasible. Identity and the load-rule are rank 0.
/// Abstract cascade follows the 9-rule table exactly. Vectors, matrices
/// and fixed-size arrays inherit their element rank.
pub fn conversionRank(src: Type, dst: Type) ?u32 {
    if (src.eql(dst)) return 0;

    // Load rule: ref<AS, T, AM> → T when AM is read or read_write.
    if (src == .reference) {
        const r = src.reference;
        if (r.access_mode == .read or r.access_mode == .read_write) {
            return conversionRank(r.element, dst);
        }
        return null;
    }

    if (src == .scalar and dst == .scalar) {
        return scalarConversionRank(src.scalar.kind, dst.scalar.kind);
    }

    if (src == .vector and dst == .vector) {
        const sv = src.vector;
        const dv = dst.vector;
        if (sv.width != dv.width) return null;
        return scalarConversionRank(sv.element.kind, dv.element.kind);
    }

    if (src == .matrix and dst == .matrix) {
        const sm = src.matrix;
        const dm = dst.matrix;
        if (sm.cols != dm.cols or sm.rows != dm.rows) return null;
        return scalarConversionRank(sm.element.kind, dm.element.kind);
    }

    if (src == .array and dst == .array) {
        const sa = src.array;
        const da = dst.array;
        // Runtime-sized arrays (count == 0) cannot carry abstract element
        // types per the spec note, so no conversion between them applies.
        if (sa.count == 0 or da.count == 0) return null;
        if (sa.count != da.count) return null;
        return conversionRank(sa.element, da.element);
    }

    return null;
}

/// Rank table for scalar-to-scalar conversions per spec §8.2.
fn scalarConversionRank(src: ScalarKind, dst: ScalarKind) ?u32 {
    if (src == dst) return 0;
    return switch (src) {
        .abstract_float => switch (dst) {
            .f32 => 1,
            .f16 => 2,
            else => null,
        },
        .abstract_int => switch (dst) {
            .i32 => 3,
            .u32 => 4,
            .abstract_float => 5,
            .f32 => 6,
            .f16 => 7,
            else => null,
        },
        else => null,
    };
}

/// Returns true if src can be implicitly converted to dst.
/// Iteratively follows type element chains.
pub fn canConvertTo(src: Type, dst: Type) bool {
    var s = src;
    var d = dst;
    for (0..32) |_| {
        if (s.eql(d)) return true;

        // Abstract scalar types can convert to concrete scalar types.
        if (s == .scalar and d == .scalar) {
            const src_s = s.scalar;
            const dst_s = d.scalar;
            if (src_s.kind == .abstract_int) {
                return dst_s.kind == .i32 or
                    dst_s.kind == .u32 or
                    dst_s.kind == .f32 or
                    dst_s.kind == .f16 or
                    dst_s.kind == .abstract_float;
            }
            if (src_s.kind == .abstract_float) {
                return dst_s.kind == .f32 or dst_s.kind == .f16;
            }
            return false;
        }

        // Vector of abstract can convert to vector of concrete.
        if (s == .vector and d == .vector) {
            const sv = s.vector;
            const dv = d.vector;
            if (sv.width != dv.width) return false;
            s = .{ .scalar = sv.element };
            d = .{ .scalar = dv.element };
            continue;
        }

        // Pointer compatibility: same address space and compatible element type.
        if (s == .pointer and d == .pointer) {
            const sp = s.pointer;
            const dp = d.pointer;
            if (sp.address_space != dp.address_space) return false;
            if (sp.element.eql(dp.element)) return true;
            s = sp.element;
            d = dp.element;
            continue;
        }

        // Matrix of abstract can convert to matrix of concrete.
        if (s == .matrix and d == .matrix) {
            const sm = s.matrix;
            const dm = d.matrix;
            if (sm.cols != dm.cols or sm.rows != dm.rows) return false;
            s = .{ .scalar = sm.element };
            d = .{ .scalar = dm.element };
            continue;
        }

        return false;
    } else unreachable;
}

/// Returns the common type of two types for binary operations, or null.
pub fn commonType(a: Type, b: Type) ?Type {
    if (a.eql(b)) return a;

    // If one can convert to the other, use the target.
    if (canConvertTo(a, b)) return b;
    if (canConvertTo(b, a)) return a;

    // Both abstract - prefer AbstractFloat over AbstractInt.
    if (a == .scalar and b == .scalar) {
        if (a.scalar.kind == .abstract_int and b.scalar.kind == .abstract_float) return b;
        if (b.scalar.kind == .abstract_int and a.scalar.kind == .abstract_float) return a;
    }

    return null;
}

/// Returns the result type of a * b, or null if invalid.
/// Handles all WGSL multiplication cases including matrix-vector products.
pub fn multiplyResultType(allocator: Allocator, left: Type, right: Type) Allocator.Error!?Type {
    // Try common type first (handles scalar*scalar, vec*vec, mat*mat with same types).
    if (commonType(left, right)) |common| return common;

    // Get concrete types for abstract handling.
    const left_conc = concreteType(left);
    const right_conc = concreteType(right);

    // Matrix * Vector: mat<C,R> * vec<C> -> vec<R>
    if (left_conc == .matrix and right_conc == .vector) {
        const m = left_conc.matrix;
        const v = right_conc.vector;
        if (m.cols == v.width) {
            if (commonScalarType(m.element, v.element)) |elem| {
                return try vec(allocator, m.rows, elem);
            }
        }
    }

    // Vector * Matrix: vec<R> * mat<C,R> -> vec<C>
    if (left_conc == .vector and right_conc == .matrix) {
        const v = left_conc.vector;
        const m = right_conc.matrix;
        if (v.width == m.rows) {
            if (commonScalarType(v.element, m.element)) |elem| {
                return try vec(allocator, m.cols, elem);
            }
        }
    }

    // Scalar * Vector or Vector * Scalar
    if (left_conc == .scalar and right_conc == .vector) {
        const v = right_conc.vector;
        if (commonScalarType(left_conc.scalar, v.element)) |elem| {
            return try vec(allocator, v.width, elem);
        }
    }
    if (left_conc == .vector and right_conc == .scalar) {
        const v = left_conc.vector;
        if (commonScalarType(v.element, right_conc.scalar)) |elem| {
            return try vec(allocator, v.width, elem);
        }
    }

    // Scalar * Matrix or Matrix * Scalar
    if (left_conc == .scalar and right_conc == .matrix) {
        const m = right_conc.matrix;
        if (commonScalarType(left_conc.scalar, m.element)) |elem| {
            return try mat(allocator, m.cols, m.rows, elem);
        }
    }
    if (left_conc == .matrix and right_conc == .scalar) {
        const m = left_conc.matrix;
        if (commonScalarType(m.element, right_conc.scalar)) |elem| {
            return try mat(allocator, m.cols, m.rows, elem);
        }
    }

    return null;
}

/// Returns the result type of a +/- b, or null if invalid.
pub fn addSubResultType(allocator: Allocator, left: Type, right: Type) Allocator.Error!?Type {
    // Common type handles most cases.
    if (commonType(left, right)) |common| return common;

    // Get concrete types.
    const left_conc = concreteType(left);
    const right_conc = concreteType(right);

    // Vector +/- Vector with compatible element types.
    if (left_conc == .vector and right_conc == .vector) {
        const lv = left_conc.vector;
        const rv = right_conc.vector;
        if (lv.width == rv.width) {
            if (commonScalarType(lv.element, rv.element)) |elem| {
                return try vec(allocator, lv.width, elem);
            }
        }
    }

    // Vector +/- Scalar (scalar broadcast)
    if (left_conc == .vector and right_conc == .scalar) {
        const v = left_conc.vector;
        if (commonScalarType(v.element, right_conc.scalar)) |elem| {
            return try vec(allocator, v.width, elem);
        }
    }
    if (left_conc == .scalar and right_conc == .vector) {
        const v = right_conc.vector;
        if (commonScalarType(left_conc.scalar, v.element)) |elem| {
            return try vec(allocator, v.width, elem);
        }
    }

    // Matrix +/- Matrix with compatible element types.
    if (left_conc == .matrix and right_conc == .matrix) {
        const lm = left_conc.matrix;
        const rm = right_conc.matrix;
        if (lm.cols == rm.cols and lm.rows == rm.rows) {
            if (commonScalarType(lm.element, rm.element)) |elem| {
                return try mat(allocator, lm.cols, lm.rows, elem);
            }
        }
    }

    return null;
}

/// Returns the result type of a / b, or null if invalid.
pub fn divResultType(allocator: Allocator, left: Type, right: Type) Allocator.Error!?Type {
    // Common type handles scalar/scalar and vec/vec.
    if (commonType(left, right)) |common| return common;

    const left_conc = concreteType(left);
    const right_conc = concreteType(right);

    // Vector / Scalar
    if (left_conc == .vector and right_conc == .scalar) {
        const v = left_conc.vector;
        if (commonScalarType(v.element, right_conc.scalar)) |elem| {
            return try vec(allocator, v.width, elem);
        }
    }

    // Scalar / Vector (broadcasts scalar)
    if (left_conc == .scalar and right_conc == .vector) {
        const v = right_conc.vector;
        if (commonScalarType(left_conc.scalar, v.element)) |elem| {
            return try vec(allocator, v.width, elem);
        }
    }

    return null;
}

/// Returns the common scalar type between two scalars, or null.
fn commonScalarType(a: *const Scalar, b: *const Scalar) ?*const Scalar {
    if (a.kind == b.kind) return a;

    // Abstract types can convert to concrete.
    if (a.kind == .abstract_float or a.kind == .abstract_int) {
        if (b.isNumeric()) return b;
    }
    if (b.kind == .abstract_float or b.kind == .abstract_int) {
        if (a.isNumeric()) return a;
    }

    return null;
}

/// Returns the concrete version of an abstract type.
/// For abstract-float returns f32, for abstract-int returns i32.
/// For vectors/matrices with abstract elements, returns concrete element versions.
/// For already concrete types, returns the type unchanged.
pub fn concreteType(t: Type) Type {
    return switch (t) {
        .scalar => |s| switch (s.kind) {
            .abstract_float => F32,
            .abstract_int => I32,
            else => t,
        },
        .vector => |v| {
            if (v.element.kind == .abstract_float) {
                // Use comptime-generated singleton to avoid allocation.
                return concreteVectorSingleton(v.width, .f32);
            }
            if (v.element.kind == .abstract_int) {
                return concreteVectorSingleton(v.width, .i32);
            }
            return t;
        },
        .matrix => |m| {
            if (m.element.kind == .abstract_float) {
                return concreteMatrixSingleton(m.cols, m.rows);
            }
            return t;
        },
        // Note: Array concretization would require allocation. The caller
        // should handle that case separately if needed.
        else => t,
    };
}

// Comptime-generated singleton vectors for concreteType to avoid allocation.
const concrete_vectors = init: {
    // [kind_idx][width_idx], kind: {f32=0, i32=1}, width: 2,3,4
    var table: [2][3]Vector = undefined;
    const scalars = [_]*const Scalar{ &scalar_f32, &scalar_i32 };
    const widths = [_]u8{ 2, 3, 4 };
    for (scalars, 0..) |s, ki| {
        for (widths, 0..) |w, wi| {
            table[ki][wi] = .{ .width = w, .element = s };
        }
    }
    break :init table;
};

fn concreteVectorSingleton(width: u8, target_kind: ScalarKind) Type {
    const kind_idx: usize = switch (target_kind) {
        .f32 => 0,
        .i32 => 1,
        else => return .{ .void_type = {} },
    };
    if (width >= 2 and width <= 4) {
        return .{ .vector = &concrete_vectors[kind_idx][width - 2] };
    }
    return .{ .void_type = {} };
}

// Comptime-generated singleton matrices for concreteType (abstract-float -> f32).
const concrete_matrices = init: {
    // [col_idx][row_idx], only f32
    var table: [3][3]Matrix = undefined;
    const dims = [_]u8{ 2, 3, 4 };
    for (dims, 0..) |c, ci| {
        for (dims, 0..) |r, ri| {
            table[ci][ri] = .{ .cols = c, .rows = r, .element = &scalar_f32 };
        }
    }
    break :init table;
};

fn concreteMatrixSingleton(cols: u8, rows: u8) Type {
    if (cols >= 2 and cols <= 4 and rows >= 2 and rows <= 4) {
        return .{ .matrix = &concrete_matrices[cols - 2][rows - 2] };
    }
    return .{ .void_type = {} };
}

// =========================================================================
// Tests
// =========================================================================

test "types: scalar singleton equality" {
    try std.testing.expect(Bool.eql(Bool));
    try std.testing.expect(I32.eql(I32));
    try std.testing.expect(F32.eql(F32));
    try std.testing.expect(!I32.eql(F32));
    try std.testing.expect(!Bool.eql(I32));
}

test "types: scalar properties" {
    // Bool is concrete, not numeric, not host-shareable.
    try std.testing.expect(Bool.isConcrete());
    try std.testing.expect(Bool.isConstructible());
    try std.testing.expect(!Bool.isHostShareable());
    try std.testing.expectEqual(@as(u32, 4), Bool.size());

    // AbstractInt is not concrete.
    try std.testing.expect(!AbstractInt.isConcrete());
    try std.testing.expect(!AbstractInt.isConstructible());
    try std.testing.expectEqual(@as(u32, 0), AbstractInt.size());

    // F16 size is 2.
    try std.testing.expectEqual(@as(u32, 2), F16.size());
}

test "types: scalar string" {
    try std.testing.expectEqualStrings("bool", Bool.string());
    try std.testing.expectEqualStrings("i32", I32.string());
    try std.testing.expectEqualStrings("f32", F32.string());
    try std.testing.expectEqualStrings("f16", F16.string());
    try std.testing.expectEqualStrings("abstract-int", AbstractInt.string());
    try std.testing.expectEqualStrings("abstract-float", AbstractFloat.string());
}

test "types: vector type" {
    const allocator = std.testing.allocator;

    const v2f = try vec(allocator, 2, scalar_f32_ptr);
    defer allocator.destroy(v2f.vector);

    try std.testing.expectEqualStrings("vec2<f32>", v2f.string());
    try std.testing.expectEqual(@as(u32, 8), v2f.size());
    try std.testing.expectEqual(@as(u32, 8), v2f.alignment());
    try std.testing.expect(v2f.isConcrete());
    try std.testing.expect(v2f.isConstructible());

    const v3i = try vec(allocator, 3, scalar_i32_ptr);
    defer allocator.destroy(v3i.vector);

    try std.testing.expectEqualStrings("vec3<i32>", v3i.string());
    try std.testing.expectEqual(@as(u32, 12), v3i.size());
    try std.testing.expectEqual(@as(u32, 16), v3i.alignment()); // vec3 aligns to 4*element

    try std.testing.expect(!v2f.eql(v3i));
}

test "types: matrix type" {
    const allocator = std.testing.allocator;

    const m4x4 = try mat(allocator, 4, 4, scalar_f32_ptr);
    defer allocator.destroy(m4x4.matrix);

    try std.testing.expectEqualStrings("mat4x4<f32>", m4x4.string());
    // mat4x4<f32>: column is vec4<f32>, align=16, size = 16*4 = 64.
    try std.testing.expectEqual(@as(u32, 64), m4x4.size());
    try std.testing.expectEqual(@as(u32, 16), m4x4.alignment());

    const m2x3 = try mat(allocator, 2, 3, scalar_f32_ptr);
    defer allocator.destroy(m2x3.matrix);

    try std.testing.expectEqualStrings("mat2x3<f32>", m2x3.string());
    // Column is vec3<f32>, align=16, size = 16*2 = 32.
    try std.testing.expectEqual(@as(u32, 32), m2x3.size());
}

test "types: canConvertTo" {
    // Same type.
    try std.testing.expect(canConvertTo(I32, I32));

    // AbstractInt -> concrete.
    try std.testing.expect(canConvertTo(AbstractInt, I32));
    try std.testing.expect(canConvertTo(AbstractInt, U32));
    try std.testing.expect(canConvertTo(AbstractInt, F32));
    try std.testing.expect(canConvertTo(AbstractInt, F16));
    try std.testing.expect(canConvertTo(AbstractInt, AbstractFloat));

    // AbstractFloat -> concrete float.
    try std.testing.expect(canConvertTo(AbstractFloat, F32));
    try std.testing.expect(canConvertTo(AbstractFloat, F16));

    // Cannot convert concrete to abstract.
    try std.testing.expect(!canConvertTo(I32, AbstractInt));
    try std.testing.expect(!canConvertTo(F32, AbstractFloat));

    // Cannot convert between concrete types.
    try std.testing.expect(!canConvertTo(I32, U32));
    try std.testing.expect(!canConvertTo(I32, F32));
}

test "types: commonType" {
    // Same type.
    try std.testing.expect(commonType(I32, I32).?.eql(I32));

    // Abstract with concrete.
    try std.testing.expect(commonType(AbstractInt, I32).?.eql(I32));
    try std.testing.expect(commonType(I32, AbstractInt).?.eql(I32));
    try std.testing.expect(commonType(AbstractFloat, F32).?.eql(F32));

    // Both abstract: prefer AbstractFloat.
    try std.testing.expect(commonType(AbstractInt, AbstractFloat).?.eql(AbstractFloat));

    // Incompatible concrete types.
    try std.testing.expect(commonType(I32, F32) == null);
}

test "types: concreteType" {
    try std.testing.expect(concreteType(AbstractInt).eql(I32));
    try std.testing.expect(concreteType(AbstractFloat).eql(F32));
    try std.testing.expect(concreteType(I32).eql(I32));
    try std.testing.expect(concreteType(F32).eql(F32));
}

test "types: void type" {
    try std.testing.expect(Void.eql(Void));
    try std.testing.expectEqualStrings("void", Void.string());
    try std.testing.expect(!Void.isConstructible());
    try std.testing.expect(Void.isConcrete());
    try std.testing.expectEqual(@as(u32, 0), Void.size());
}

test "types: type query functions" {
    try std.testing.expect(isScalar(I32));
    try std.testing.expect(!isScalar(Void));
    try std.testing.expect(isNumeric(I32));
    try std.testing.expect(isNumeric(F32));
    try std.testing.expect(!isNumeric(Bool));
    try std.testing.expect(isInteger(I32));
    try std.testing.expect(isInteger(U32));
    try std.testing.expect(!isInteger(F32));
    try std.testing.expect(isFloat(F32));
    try std.testing.expect(isFloat(F16));
    try std.testing.expect(!isFloat(I32));
}

test "types: scalarOf extracts element type" {
    const allocator = std.testing.allocator;

    // Scalar returns itself.
    try std.testing.expect(scalarOf(F32).?.eql(F32));
    try std.testing.expect(scalarOf(I32).?.eql(I32));

    // Vector returns its element scalar.
    const v2f = try vec(allocator, 2, scalar_f32_ptr);
    defer allocator.destroy(v2f.vector);
    try std.testing.expect(scalarOf(v2f).?.eql(F32));

    // Matrix returns its element scalar.
    const m4x4 = try mat(allocator, 4, 4, scalar_f32_ptr);
    defer allocator.destroy(m4x4.matrix);
    try std.testing.expect(scalarOf(m4x4).?.eql(F32));

    // Bool is a scalar, so scalarOf returns it as-is.
    try std.testing.expect(scalarOf(Bool).?.eql(Bool));

    // Non-composite, non-scalar types return null.
    try std.testing.expect(scalarOf(Void) == null);
}

test "types: texelFormatToScalar maps formats correctly" {
    // Float formats (unorm, snorm, float) → f32.
    try std.testing.expectEqual(ScalarKind.f32, texelFormatToScalar("rgba8unorm").kind);
    try std.testing.expectEqual(ScalarKind.f32, texelFormatToScalar("rgba8snorm").kind);
    try std.testing.expectEqual(ScalarKind.f32, texelFormatToScalar("rgba16float").kind);
    try std.testing.expectEqual(ScalarKind.f32, texelFormatToScalar("r32float").kind);

    // Unsigned integer formats → u32.
    try std.testing.expectEqual(ScalarKind.u32, texelFormatToScalar("rgba8uint").kind);
    try std.testing.expectEqual(ScalarKind.u32, texelFormatToScalar("rgba32uint").kind);

    // Signed integer formats → i32.
    try std.testing.expectEqual(ScalarKind.i32, texelFormatToScalar("rgba8sint").kind);
    try std.testing.expectEqual(ScalarKind.i32, texelFormatToScalar("r32sint").kind);

    // Empty format defaults to f32.
    try std.testing.expectEqual(ScalarKind.f32, texelFormatToScalar("").kind);
}

test "types: Texture.string renders WGSL surface syntax" {
    // Sampled textures print element type in angle brackets.
    const sampled_2d_f32 = Texture{
        .kind = .sampled,
        .dimension = .@"2d",
        .sampled_type = scalar_f32_ptr,
        .texel_format = "",
        .access_mode = .none,
    };
    try std.testing.expectEqualStrings("texture_2d<f32>", sampled_2d_f32.string());

    const sampled_cube_i32 = Texture{
        .kind = .sampled,
        .dimension = .cube,
        .sampled_type = scalar_i32_ptr,
        .texel_format = "",
        .access_mode = .none,
    };
    try std.testing.expectEqualStrings("texture_cube<i32>", sampled_cube_i32.string());

    // Multisampled.
    const ms_2d_u32 = Texture{
        .kind = .multisampled,
        .dimension = .@"2d",
        .sampled_type = scalar_u32_ptr,
        .texel_format = "",
        .access_mode = .none,
    };
    try std.testing.expectEqualStrings("texture_multisampled_2d<u32>", ms_2d_u32.string());

    // Storage textures include texel format and access mode.
    const storage_2d = Texture{
        .kind = .storage,
        .dimension = .@"2d",
        .sampled_type = null,
        .texel_format = "rgba8unorm",
        .access_mode = .write,
    };
    try std.testing.expectEqualStrings("texture_storage_2d<rgba8unorm, write>", storage_2d.string());

    const storage_3d_rw = Texture{
        .kind = .storage,
        .dimension = .@"3d",
        .sampled_type = null,
        .texel_format = "r32uint",
        .access_mode = .read_write,
    };
    try std.testing.expectEqualStrings("texture_storage_3d<r32uint, read_write>", storage_3d_rw.string());

    // Depth textures have neither element nor format.
    const depth_cube = Texture{
        .kind = .depth,
        .dimension = .cube,
        .sampled_type = null,
        .texel_format = "",
        .access_mode = .read,
    };
    try std.testing.expectEqualStrings("texture_depth_cube", depth_cube.string());

    const depth_ms_2d = Texture{
        .kind = .depth_multisampled,
        .dimension = .@"2d",
        .sampled_type = null,
        .texel_format = "",
        .access_mode = .read,
    };
    try std.testing.expectEqualStrings("texture_depth_multisampled_2d", depth_ms_2d.string());

    // External textures are parameterless.
    const ext = Texture{
        .kind = .external,
        .dimension = .@"2d",
        .sampled_type = null,
        .texel_format = "",
        .access_mode = .read,
    };
    try std.testing.expectEqualStrings("texture_external", ext.string());

    // Rotating buffer: two concurrent calls in one expression must both
    // survive long enough to compare.
    const a = sampled_2d_f32.string();
    const b = storage_2d.string();
    try std.testing.expectEqualStrings("texture_2d<f32>", a);
    try std.testing.expectEqualStrings("texture_storage_2d<rgba8unorm, write>", b);
}

test "types: canConvertTo pointer compatibility" {
    const allocator = std.testing.allocator;

    // Same pointer type is compatible.
    const p1 = try ptr(allocator, .function, F32, .read_write);
    defer allocator.destroy(p1.pointer);
    const p2 = try ptr(allocator, .function, F32, .read);
    defer allocator.destroy(p2.pointer);

    try std.testing.expect(canConvertTo(p1, p2));

    // Different address space is not compatible.
    const p3 = try ptr(allocator, .storage, F32, .read);
    defer allocator.destroy(p3.pointer);
    try std.testing.expect(!canConvertTo(p1, p3));
}

test "types: sampler type" {
    const allocator = std.testing.allocator;

    const s = try samplerType(allocator, false);
    defer allocator.destroy(s.sampler);

    try std.testing.expectEqualStrings("sampler", s.string());
    try std.testing.expect(!s.isConstructible());
    try std.testing.expect(s.isConcrete());

    const sc = try samplerType(allocator, true);
    defer allocator.destroy(sc.sampler);

    try std.testing.expectEqualStrings("sampler_comparison", sc.string());
    try std.testing.expect(!s.eql(sc));
}

test "types: pointer and reference types" {
    const allocator = std.testing.allocator;

    const p = try ptr(allocator, .function, I32, .read_write);
    defer allocator.destroy(p.pointer);

    try std.testing.expect(!p.isConstructible());
    try std.testing.expect(p.isConcrete());
    try std.testing.expect(!p.isStorable());
    try std.testing.expectEqual(@as(u32, 0), p.size());

    const r = try ref(allocator, .storage, F32, .read);
    defer allocator.destroy(r.reference);

    try std.testing.expect(!r.isConstructible());
    try std.testing.expect(r.isConcrete());
    try std.testing.expect(!r.isStorable());
}

test "types: atomic type" {
    const allocator = std.testing.allocator;

    const a = try atomicType(allocator, scalar_i32_ptr);
    defer allocator.destroy(a.atomic);

    try std.testing.expect(!a.isConstructible());
    try std.testing.expect(a.isConcrete());
    try std.testing.expect(a.isStorable());
    try std.testing.expect(a.isHostShareable());
    try std.testing.expectEqual(@as(u32, 4), a.size());
    try std.testing.expectEqual(@as(u32, 4), a.alignment());
}

test "types: array type" {
    const allocator = std.testing.allocator;

    const a = try arr(allocator, F32, 4);
    defer allocator.destroy(a.array);

    try std.testing.expect(a.isConstructible());
    try std.testing.expect(a.isConcrete());
    try std.testing.expect(a.isStorable());
    try std.testing.expect(a.isHostShareable());
    // array<f32, 4>: stride = 4 (f32 size), 4 elements = 16 bytes.
    try std.testing.expectEqual(@as(u32, 16), a.size());

    // Runtime-sized array.
    const ra = try runtimeArray(allocator, I32);
    defer allocator.destroy(ra.array);

    try std.testing.expect(!ra.isConstructible());
    try std.testing.expectEqual(@as(u32, 0), ra.size());
}

test "types: multiplyResultType for 6 cases" {
    const allocator = std.testing.allocator;

    // mat4x4 * vec4 -> vec4
    const mat44 = try mat(allocator, 4, 4, &scalar_f32);
    defer allocator.destroy(mat44.matrix);
    const vec4 = try vec(allocator, 4, &scalar_f32);
    defer allocator.destroy(vec4.vector);

    const mat_vec = try multiplyResultType(allocator, mat44, vec4);
    try std.testing.expect(mat_vec != null);
    try std.testing.expect(mat_vec.? == .vector);
    defer allocator.destroy(mat_vec.?.vector);
    try std.testing.expectEqual(@as(u8, 4), mat_vec.?.vector.width);

    // vec4 * mat4x4 -> vec4
    const vec_mat = try multiplyResultType(allocator, vec4, mat44);
    try std.testing.expect(vec_mat != null);
    try std.testing.expect(vec_mat.? == .vector);
    defer allocator.destroy(vec_mat.?.vector);

    // scalar * vec -> vec
    const scalar_vec = try multiplyResultType(allocator, F32, vec4);
    try std.testing.expect(scalar_vec != null);
    try std.testing.expect(scalar_vec.? == .vector);
    defer allocator.destroy(scalar_vec.?.vector);

    // scalar * mat -> mat
    const scalar_mat = try multiplyResultType(allocator, F32, mat44);
    try std.testing.expect(scalar_mat != null);
    try std.testing.expect(scalar_mat.? == .matrix);
    defer allocator.destroy(scalar_mat.?.matrix);

    // mat * mat (same dims) -> mat
    const mat_mat = try multiplyResultType(allocator, mat44, mat44);
    try std.testing.expect(mat_mat != null);

    // mat * scalar -> mat
    const mat_scalar = try multiplyResultType(allocator, mat44, F32);
    try std.testing.expect(mat_scalar != null);
    try std.testing.expect(mat_scalar.? == .matrix);
    defer allocator.destroy(mat_scalar.?.matrix);
}

test "types: struct layout" {
    const allocator = std.testing.allocator;

    var fields = [_]StructField{
        .{ .name = "x", .typ = F32, .offset = 0 },
        .{ .name = "y", .typ = F32, .offset = 0 },
        .{ .name = "z", .typ = F32, .offset = 0 },
    };

    const s = try structType(allocator, "MyVec3", &fields);
    defer allocator.destroy(s.@"struct");

    s.@"struct".computeLayout();

    try std.testing.expectEqual(@as(u32, 0), fields[0].offset);
    try std.testing.expectEqual(@as(u32, 4), fields[1].offset);
    try std.testing.expectEqual(@as(u32, 8), fields[2].offset);
    try std.testing.expectEqual(@as(u32, 12), s.size());
    try std.testing.expectEqual(@as(u32, 4), s.alignment());
}
