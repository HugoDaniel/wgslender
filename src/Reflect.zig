//! WGSL shader reflection.
//!
//! Extracts binding information, struct layouts, and entry points from a
//! parsed WGSL module. All layout computations follow the WGSL specification
//! for alignment and size rules.
//!
//! Invariants:
//!   - Every reported binding has non-negative `(group, binding)` — the
//!     WGSL parser permits any int there, but `extractBinding` filters
//!     entries with negative values. Asserted in `reflectWithRenamer`.
//!   - Struct layouts follow WGSL §6.2.10 (host-shareable layout rules);
//!     `align_of` is always a power of two and `size` is always rounded
//!     up to a multiple of `align_of` for the struct itself.
//!   - With a `MinifyRenamer` provided, `name_mapped` and `type_mapped`
//!     fields reflect the post-rename names; without one they equal the
//!     original names.

const std = @import("std");
const StableId = @import("StableId.zig");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Printer = @import("Printer.zig");

// =========================================================================
// Public types
// =========================================================================

pub const ReflectResult = struct {
    bindings: std.ArrayListUnmanaged(BindingInfo) = .empty,
    structs: std.StringHashMapUnmanaged(StructLayout) = .{},
    entry_points: std.ArrayListUnmanaged(EntryPointInfo) = .empty,
    errors: std.ArrayListUnmanaged([]const u8) = .empty,
    _arena: ?std.heap.ArenaAllocator = null,

    /// Free all memory owned by this result. If this result was created
    /// through the public API (root.zig), deinits the internal arena.
    /// After calling deinit, all slices and pointers in the result are invalid.
    pub fn deinit(self: *ReflectResult, arena: Allocator) void {
        if (self._arena) |_| {
            var owned_arena = self._arena.?;
            owned_arena.deinit();
            self._arena = null;
        } else {
            self.bindings.deinit(arena);
            self.structs.deinit(arena);
            self.entry_points.deinit(arena);
            self.errors.deinit(arena);
        }
    }

    /// Serialize the reflect result to JSON.
    pub fn toJson(self: *const ReflectResult, buf: *std.ArrayListUnmanaged(u8), arena: Allocator) Allocator.Error!void {
        try appendStr(buf, arena, "{\"bindings\":[");
        for (self.bindings.items, 0..) |*b, i| {
            if (i > 0) try appendStr(buf, arena, ",");
            try writeBindingJson(buf, arena, b);
        }
        try appendStr(buf, arena, "],\"structs\":{");
        var struct_iter = self.structs.iterator();
        var first_struct = true;
        while (struct_iter.next()) |entry| {
            if (!first_struct) try appendStr(buf, arena, ",");
            first_struct = false;
            try appendJsonStr(buf, arena, entry.key_ptr.*);
            try appendStr(buf, arena, ":");
            try writeStructLayoutJson(buf, arena, &entry.value_ptr.*);
        }
        try appendStr(buf, arena, "},\"entryPoints\":[");
        for (self.entry_points.items, 0..) |*ep, i| {
            if (i > 0) try appendStr(buf, arena, ",");
            try writeEntryPointJson(buf, arena, ep);
        }
        try appendStr(buf, arena, "]");
        if (self.errors.items.len > 0) {
            try appendStr(buf, arena, ",\"errors\":[");
            for (self.errors.items, 0..) |err, i| {
                if (i > 0) try appendStr(buf, arena, ",");
                try appendJsonStr(buf, arena, err);
            }
            try appendStr(buf, arena, "]");
        }
        try appendStr(buf, arena, "}");
    }

    /// Serialize the reflect result to pretty-printed JSON (2-space indent).
    pub fn toJsonPretty(self: *const ReflectResult, buf: *std.ArrayListUnmanaged(u8), arena: Allocator) Allocator.Error!void {
        var compact: std.ArrayListUnmanaged(u8) = .empty;
        try self.toJson(&compact, arena);
        try prettyPrintJson(buf, arena, compact.items);
    }
};

fn prettyPrintJson(buf: *std.ArrayListUnmanaged(u8), arena: Allocator, json: []const u8) Allocator.Error!void {
    var depth: u32 = 0;
    var in_string = false;
    var i: usize = 0;

    while (i < json.len) {
        const c = json[i];
        if (in_string) {
            try buf.append(arena, c);
            if (c == '\\' and i + 1 < json.len) {
                i += 1;
                try buf.append(arena, json[i]);
            } else if (c == '"') {
                in_string = false;
            }
            i += 1;
            continue;
        }
        switch (c) {
            '"' => {
                in_string = true;
                try buf.append(arena, c);
            },
            '{', '[' => {
                try buf.append(arena, c);
                // Collapse empty containers ({} / []) onto one line.
                if (i + 1 < json.len and (json[i + 1] == '}' or json[i + 1] == ']')) {
                    i += 1;
                    try buf.append(arena, json[i]);
                } else {
                    depth += 1;
                    try buf.append(arena, '\n');
                    try writeIndent(buf, arena, depth);
                }
            },
            '}', ']' => {
                if (depth > 0) depth -= 1;
                try buf.append(arena, '\n');
                try writeIndent(buf, arena, depth);
                try buf.append(arena, c);
            },
            ',' => {
                try buf.append(arena, ',');
                try buf.append(arena, '\n');
                try writeIndent(buf, arena, depth);
            },
            ':' => {
                try buf.appendSlice(arena, ": ");
            },
            else => try buf.append(arena, c),
        }
        i += 1;
    }
}

fn writeIndent(buf: *std.ArrayListUnmanaged(u8), arena: Allocator, depth: u32) Allocator.Error!void {
    for (0..depth) |_| {
        try buf.appendSlice(arena, "  ");
    }
}

pub const SpanInfo = struct {
    start: u32 = 0,
    end: u32 = 0,

    pub fn present(self: SpanInfo) bool {
        return self.end > self.start;
    }
};

pub const BindingInfo = struct {
    group: i32,
    binding: i32,
    name: []const u8,
    name_mapped: []const u8,
    /// Byte offset of the declared name in the original source, or 0 if unknown.
    name_offset: u32 = 0,
    /// Reparse-stable identifier for this binding's var symbol. See
    /// `StableId`. Empty if not computed.
    stable_id: []const u8 = "",
    /// Byte range of the full declaration (attributes through `;`), or
    /// an absent span if unknown.
    decl_span: SpanInfo = .{},
    /// Byte range of the binding's type annotation (e.g. the `Uniforms`
    /// in `var<uniform> u: Uniforms;`), or an absent span if the
    /// declaration has no type annotation.
    type_span: SpanInfo = .{},
    address_space: []const u8,
    access_mode: []const u8 = "",
    typ: []const u8,
    type_mapped: []const u8,
    layout: ?StructLayout = null,
    array: ?ArrayInfo = null,
};

pub const ArrayInfo = struct {
    depth: u32,
    element_count: ?i32 = null, // null for runtime-sized arrays
    element_stride: u32,
    total_size: ?i32 = null, // null for runtime-sized arrays
    element_type: []const u8,
    element_type_mapped: []const u8,
    element_layout: ?StructLayout = null,
    nested: ?*ArrayInfo = null, // nested array info
};

pub const StructLayout = struct {
    size: u32,
    alignment: u32,
    fields: std.ArrayListUnmanaged(FieldInfo) = .empty,
};

pub const FieldInfo = struct {
    name: []const u8,
    name_mapped: []const u8,
    /// Byte offset of the declared field name in the original source, or 0 if unknown.
    name_offset: u32 = 0,
    /// Reparse-stable identifier for this struct member. See `StableId`.
    /// Empty if not computed.
    stable_id: []const u8 = "",
    /// Byte range of the member's type annotation, or an absent span if
    /// unknown.
    type_span: SpanInfo = .{},
    typ: []const u8,
    type_mapped: []const u8,
    offset: u32,
    size: u32,
    alignment: u32,
    layout: ?StructLayout = null,
};

pub const EntryPointInfo = struct {
    name: []const u8,
    /// Byte offset of the declared function name in the original source, or 0 if unknown.
    name_offset: u32 = 0,
    /// Reparse-stable identifier for this function symbol. See `StableId`.
    /// Empty if not computed.
    stable_id: []const u8 = "",
    /// Byte range of the full function declaration (leading attributes
    /// through the closing `}`), or an absent span if unknown.
    decl_span: SpanInfo = .{},
    stage: []const u8,
    workgroup_size: [3]u32 = .{ 1, 1, 1 },
    has_workgroup_size: bool = false,
};

// =========================================================================
// TypeLayout — internal layout computation result
// =========================================================================

const TypeLayout = struct {
    size: u32 = 0,
    alignment: u32 = 0,
    stride: u32 = 0, // for arrays only
};

// =========================================================================
// Public API
// =========================================================================

/// Extract reflection information from a parsed module.
pub fn reflect(arena: Allocator, module: *Ast.Module) Allocator.Error!ReflectResult {
    return try reflectWithRenamer(arena, module, null);
}

/// Extract reflection information from a parsed module, using an optional
/// renamer for mapped (minified) names.
pub fn reflectWithRenamer(
    arena: Allocator,
    module: *Ast.Module,
    renamer: ?*const Printer.Renamer,
) Allocator.Error!ReflectResult {
    // Pre: module came from a parse — its scope tree must be rooted, and
    // the symbol table must fit u32 (StableId encoding + Diagnostic offsets
    // both index by u32).
    std.debug.assert(module.scope.parent == null);
    std.debug.assert(module.symbols.items.len <= std.math.maxInt(u32));

    // Drain any deferred incremental-splice bias so `.loc` and `.span`
    // reads below see current coordinates.
    module.absorbInteriors();

    var result = ReflectResult{};

    var lc = LayoutComputer.init(arena, module, renamer);

    // First pass: collect all struct definitions.
    for (module.declarations.items) |decl| {
        switch (decl) {
            .@"struct" => |struct_decl| {
                const name = lc.getSymbolName(struct_decl.name);
                if (name.len > 0) {
                    const layout = try lc.computeStructLayout(struct_decl);
                    try result.structs.put(arena, name, layout);
                }
            },
            else => {},
        }
    }

    // Second pass: collect bindings and entry points.
    for (module.declarations.items) |decl| {
        switch (decl) {
            .@"var" => |var_decl| {
                if (extractBinding(var_decl, module.symbols.items, &lc)) |b| {
                    var info = b;
                    if (StableId.stableIdFor(arena, module, var_decl.name)) |maybe_id| {
                        if (maybe_id) |id| info.stable_id = id.bytes;
                    } else |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.IdTooLong => {}, // leave stable_id empty
                    }
                    info.decl_span = spanInfoFromAst(var_decl.decl_span);
                    if (var_decl.typ) |t| info.type_span = spanInfoFromAst(t.span());
                    try result.bindings.append(arena, info);
                }
            },
            .function => |fn_decl| {
                if (extractEntryPoint(fn_decl, module.symbols.items)) |ep| {
                    var info = ep;
                    if (StableId.stableIdFor(arena, module, fn_decl.name)) |maybe_id| {
                        if (maybe_id) |id| info.stable_id = id.bytes;
                    } else |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.IdTooLong => {},
                    }
                    info.decl_span = spanInfoFromAst(fn_decl.decl_span);
                    try result.entry_points.append(arena, info);
                }
            },
            else => {},
        }
    }

    // Third pass: annotate struct-layout fields with stable IDs and
    // the byte span of their type annotations.
    for (module.declarations.items) |decl| switch (decl) {
        .@"struct" => |st| {
            const name = lc.getSymbolName(st.name);
            if (name.len == 0) continue;
            const layout_ptr = result.structs.getPtr(name) orelse continue;
            for (layout_ptr.fields.items, 0..) |*f, i| {
                if (i >= st.members.items.len) break;
                const m = st.members.items[i];
                if (StableId.stableIdFor(arena, module, m.name)) |maybe_id| {
                    if (maybe_id) |id| f.stable_id = id.bytes;
                } else |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.IdTooLong => {},
                }
                f.type_span = spanInfoFromAst(m.typ.span());
            }
        },
        else => {},
    };

    // Post: every binding has a non-negative (group, binding) — extractBinding
    // would have returned null otherwise — and entry points are tagged with
    // valid stages.
    for (result.bindings.items) |b| {
        std.debug.assert(b.group >= 0);
        std.debug.assert(b.binding >= 0);
    }

    return result;
}

fn spanInfoFromAst(span: Ast.Span) SpanInfo {
    return .{ .start = span.start, .end = span.end };
}

// =========================================================================
// Binding / entry-point extraction (free functions)
// =========================================================================

fn extractBinding(
    var_decl: *Ast.VarDecl,
    symbols: []const Ast.Symbol,
    lc: *LayoutComputer,
) ?BindingInfo {
    var group: i32 = -1;
    var binding: i32 = -1;

    for (var_decl.attributes.items) |attr| {
        if (std.mem.eql(u8, attr.name, "group") and attr.args.items.len > 0) {
            group = parseIntAttr(attr.args.items[0]);
        }
        if (std.mem.eql(u8, attr.name, "binding") and attr.args.items.len > 0) {
            binding = parseIntAttr(attr.args.items[0]);
        }
    }

    if (group < 0 or binding < 0) return null;

    // Determine address space — infer "handle" for texture/sampler types.
    var address_space = var_decl.address_space;
    if (address_space == .none) {
        if (var_decl.typ) |t| {
            if (isHandleType(t)) {
                address_space = .handle;
            }
        }
    }

    const name = getSymbolName(var_decl.name, symbols);
    const mapped_name = lc.getMappedName(var_decl.name);
    const name_offset = getSymbolLoc(var_decl.name, symbols);

    var info = BindingInfo{
        .group = group,
        .binding = binding,
        .name = name,
        .name_mapped = mapped_name,
        .name_offset = name_offset,
        .address_space = addressSpaceToString(address_space),
        .typ = if (var_decl.typ) |t| lc.typeToStringMapped(t, false) else "",
        .type_mapped = if (var_decl.typ) |t| lc.typeToStringMapped(t, true) else "",
    };

    // Add access mode for storage bindings.
    if (var_decl.access_mode != .none) {
        info.access_mode = var_decl.access_mode.string();
    }

    // Resolve alias chains so aliased arrays/structs get the same
    // treatment as their underlying types.
    const resolved_typ: ?Ast.Type = if (var_decl.typ) |t| lc.resolveAliasType(t) else null;

    // Handle array types.
    if (resolved_typ) |t| {
        switch (t) {
            .array => |array_type| {
                if (var_decl.address_space == .uniform or var_decl.address_space == .storage) {
                    info.array = lc.extractArrayInfo(array_type, 1);
                }
                return info;
            },
            else => {},
        }
    }

    // Add layout for non-array struct types (uniform/storage only).
    if (var_decl.address_space == .uniform or var_decl.address_space == .storage) {
        if (resolved_typ) |t| {
            switch (t) {
                .ident => |ident_type| {
                    if (ident_type.ref.isValid()) {
                        if (lc.getStructLayout(ident_type.ref)) |layout| {
                            info.layout = layout;
                        }
                    }
                },
                else => {},
            }
        }
    }

    return info;
}

fn extractEntryPoint(
    fn_decl: *Ast.FunctionDecl,
    symbols: []const Ast.Symbol,
) ?EntryPointInfo {
    var stage: []const u8 = "";
    var workgroup_size: [3]u32 = .{ 1, 1, 1 };
    var has_workgroup_size = false;

    for (fn_decl.attributes.items) |attr| {
        if (std.mem.eql(u8, attr.name, "vertex")) {
            stage = "vertex";
        } else if (std.mem.eql(u8, attr.name, "fragment")) {
            stage = "fragment";
        } else if (std.mem.eql(u8, attr.name, "compute")) {
            stage = "compute";
        } else if (std.mem.eql(u8, attr.name, "workgroup_size")) {
            has_workgroup_size = true;
            workgroup_size = parseWorkgroupSize(attr.args.items);
        }
    }

    if (stage.len == 0) return null;

    return .{
        .name = getSymbolName(fn_decl.name, symbols),
        .name_offset = getSymbolLoc(fn_decl.name, symbols),
        .stage = stage,
        .workgroup_size = workgroup_size,
        .has_workgroup_size = has_workgroup_size,
    };
}

fn parseIntAttr(expr: Ast.Expr) i32 {
    switch (expr) {
        .literal => |lit| {
            if (lit.kind == .int_literal) {
                return std.fmt.parseInt(i32, lit.value, 10) catch -1;
            }
        },
        else => {},
    }
    return -1;
}

fn parseWorkgroupSize(args: []const Ast.Expr) [3]u32 {
    var result: [3]u32 = .{ 1, 1, 1 };
    for (args, 0..) |arg, i| {
        if (i >= 3) break;
        const val = parseIntAttr(arg);
        result[i] = if (val >= 0) @intCast(val) else 1;
    }
    return result;
}

fn getSymbolName(ref: Ast.SymbolIndex, symbols: []const Ast.Symbol) []const u8 {
    if (!ref.isValid()) return "";
    const idx = ref.index();
    if (idx >= symbols.len) return "";
    return symbols[idx].original_name;
}

fn getSymbolLoc(ref: Ast.SymbolIndex, symbols: []const Ast.Symbol) u32 {
    if (!ref.isValid()) return 0;
    const idx = ref.index();
    if (idx >= symbols.len) return 0;
    return symbols[idx].loc;
}

fn addressSpaceToString(as: Ast.AddressSpace) []const u8 {
    return switch (as) {
        .handle => "handle",
        else => as.string(),
    };
}

fn isHandleType(t: Ast.Type) bool {
    switch (t) {
        .sampler => return true,
        .texture => return true,
        .ident => |ident| {
            const handle_names = std.StaticStringMap(void).initComptime(.{
                .{ "sampler", {} },
                .{ "sampler_comparison", {} },
                .{ "texture_1d", {} },
                .{ "texture_2d", {} },
                .{ "texture_2d_array", {} },
                .{ "texture_3d", {} },
                .{ "texture_cube", {} },
                .{ "texture_cube_array", {} },
                .{ "texture_multisampled_2d", {} },
                .{ "texture_storage_1d", {} },
                .{ "texture_storage_2d", {} },
                .{ "texture_storage_2d_array", {} },
                .{ "texture_storage_3d", {} },
                .{ "texture_depth_2d", {} },
                .{ "texture_depth_2d_array", {} },
                .{ "texture_depth_cube", {} },
                .{ "texture_depth_cube_array", {} },
                .{ "texture_depth_multisampled_2d", {} },
                .{ "texture_external", {} },
            });
            return handle_names.has(ident.name);
        },
        else => return false,
    }
}

// =========================================================================
// Primitive type layouts (WGSL spec alignment/size rules)
// =========================================================================

const PrimitiveLayout = struct { size: u32, alignment: u32 };

const L = PrimitiveLayout;
const primitive_layouts = std.StaticStringMap(PrimitiveLayout).initComptime(.{
    // Scalars
    .{ "bool", L{ .size = 4, .alignment = 4 } },
    .{ "i32", L{ .size = 4, .alignment = 4 } },
    .{ "u32", L{ .size = 4, .alignment = 4 } },
    .{ "f32", L{ .size = 4, .alignment = 4 } },
    .{ "f16", L{ .size = 2, .alignment = 2 } },
    // Vectors — 32-bit element types
    .{ "vec2i", L{ .size = 8, .alignment = 8 } },
    .{ "vec3i", L{ .size = 12, .alignment = 16 } },
    .{ "vec4i", L{ .size = 16, .alignment = 16 } },
    .{ "vec2u", L{ .size = 8, .alignment = 8 } },
    .{ "vec3u", L{ .size = 12, .alignment = 16 } },
    .{ "vec4u", L{ .size = 16, .alignment = 16 } },
    .{ "vec2f", L{ .size = 8, .alignment = 8 } },
    .{ "vec3f", L{ .size = 12, .alignment = 16 } },
    .{ "vec4f", L{ .size = 16, .alignment = 16 } },
    .{ "vec2b", L{ .size = 8, .alignment = 8 } },
    .{ "vec3b", L{ .size = 12, .alignment = 16 } },
    .{ "vec4b", L{ .size = 16, .alignment = 16 } },
    // Vectors — 16-bit element types (f16)
    .{ "vec2h", L{ .size = 4, .alignment = 4 } },
    .{ "vec3h", L{ .size = 6, .alignment = 8 } },
    .{ "vec4h", L{ .size = 8, .alignment = 8 } },
    // Matrices — f32
    .{ "mat2x2f", L{ .size = 16, .alignment = 8 } },
    .{ "mat2x3f", L{ .size = 32, .alignment = 16 } },
    .{ "mat2x4f", L{ .size = 32, .alignment = 16 } },
    .{ "mat3x2f", L{ .size = 24, .alignment = 8 } },
    .{ "mat3x3f", L{ .size = 48, .alignment = 16 } },
    .{ "mat3x4f", L{ .size = 48, .alignment = 16 } },
    .{ "mat4x2f", L{ .size = 32, .alignment = 8 } },
    .{ "mat4x3f", L{ .size = 64, .alignment = 16 } },
    .{ "mat4x4f", L{ .size = 64, .alignment = 16 } },
    // Matrices — f16
    .{ "mat2x2h", L{ .size = 8, .alignment = 4 } },
    .{ "mat2x3h", L{ .size = 16, .alignment = 8 } },
    .{ "mat2x4h", L{ .size = 16, .alignment = 8 } },
    .{ "mat3x2h", L{ .size = 12, .alignment = 4 } },
    .{ "mat3x3h", L{ .size = 24, .alignment = 8 } },
    .{ "mat3x4h", L{ .size = 24, .alignment = 8 } },
    .{ "mat4x2h", L{ .size = 16, .alignment = 4 } },
    .{ "mat4x3h", L{ .size = 32, .alignment = 8 } },
    .{ "mat4x4h", L{ .size = 32, .alignment = 8 } },
});

// =========================================================================
// LayoutComputer
// =========================================================================

/// Tagged numeric value produced by const-expression evaluation. WGSL
/// const-exprs include integer arithmetic (used for array sizes /
/// workgroup_size args / @binding values) AND floating-point arithmetic
/// (e.g. `sin(radians(90))`); the latter only matters when the result
/// flows through a cast back to an integer (see wgsl_reflect's `const2`
/// test). `bool` covers logical-op intermediates.
const ConstValue = union(enum) {
    int: i64,
    float: f64,
    bool: bool,

    fn toI64(self: ConstValue) ?i64 {
        return switch (self) {
            .int => |v| v,
            .float => |v| if (std.math.isFinite(v)) @intFromFloat(@trunc(v)) else null,
            .bool => |v| @intFromBool(v),
        };
    }

    fn toF64(self: ConstValue) f64 {
        return switch (self) {
            .int => |v| @floatFromInt(v),
            .float => |v| v,
            .bool => |v| if (v) 1.0 else 0.0,
        };
    }
};

const LayoutComputer = struct {
    arena: Allocator,
    module: *Ast.Module,
    struct_cache: std.StringHashMapUnmanaged(StructLayout),
    renamer: ?*const Printer.Renamer,
    /// Scratch buffer for typeToStringMapped.
    fmt_buf: std.ArrayListUnmanaged(u8) = .empty,
    /// Cache of evaluated const declarations keyed by `SymbolIndex.index()`.
    /// Speeds up repeated identifier lookups and breaks cycles.
    const_cache: std.AutoHashMapUnmanaged(u32, ?ConstValue) = .{},

    fn init(
        arena: Allocator,
        module: *Ast.Module,
        renamer: ?*const Printer.Renamer,
    ) LayoutComputer {
        return .{
            .arena = arena,
            .module = module,
            .struct_cache = .{},
            .renamer = renamer,
        };
    }

    // -----------------------------------------------------------------
    // Type layout computation
    // -----------------------------------------------------------------

    /// Iteratively computes type layout, unwrapping atomic wrappers and
    /// following alias chains.
    fn computeTypeLayout(self: *LayoutComputer, t: Ast.Type) TypeLayout {
        var current = self.resolveAliasType(t);
        for (0..32) |_| {
            switch (current) {
                .ident => |ident| {
                    if (primitive_layouts.get(ident.name)) |pl| {
                        return .{ .size = pl.size, .alignment = pl.alignment };
                    }
                    if (self.struct_cache.get(ident.name)) |cached| {
                        return .{ .size = cached.size, .alignment = cached.alignment };
                    }
                    if (ident.ref.isValid()) {
                        if (self.getStructLayout(ident.ref)) |sl| {
                            return .{ .size = sl.size, .alignment = sl.alignment };
                        }
                    }
                    return .{};
                },
                .vec => |vec| return self.computeVecTypeLayout(vec),
                .mat => |mat| return self.computeMatTypeLayout(mat),
                .array => |arr| return self.computeArrayTypeLayout(arr),
                .atomic => |at| {
                    current = self.resolveAliasType(at.elem_type);
                    continue;
                },
                .sampler, .texture, .ptr => return .{},
            }
        } else unreachable;
    }

    /// Follow alias chains. If `t` is an `ident` whose symbol is an
    /// `alias`, walk the chain to the underlying non-alias type. Capped
    /// at 32 hops; returns the input on cycle / unresolved ref.
    fn resolveAliasType(self: *const LayoutComputer, t: Ast.Type) Ast.Type {
        var current = t;
        var hops: u32 = 0;
        while (hops < 32) : (hops += 1) {
            const ident = switch (current) {
                .ident => |i| i,
                else => return current,
            };
            if (!ident.ref.isValid()) return current;
            const idx = ident.ref.index();
            if (idx >= self.module.symbols.items.len) return current;
            if (self.module.symbols.items[idx].kind != .alias) return current;
            const target = self.findAliasType(ident.ref) orelse return current;
            current = target;
        }
        return current;
    }

    /// Find the target type of an alias declaration by symbol index.
    fn findAliasType(self: *const LayoutComputer, ref: Ast.SymbolIndex) ?Ast.Type {
        for (self.module.declarations.items) |decl| {
            switch (decl) {
                .alias => |a| if (a.name == ref) return a.typ,
                else => {},
            }
        }
        return null;
    }

    /// Walk alias chain for a SymbolIndex. If `ref` points to an alias
    /// whose final target is a struct, returns that struct's
    /// `SymbolIndex`. Returns `ref` unchanged if it already points at a
    /// struct. Returns null on non-struct targets, cycles, or unresolved
    /// refs.
    fn resolveAliasRefToStruct(self: *const LayoutComputer, ref: Ast.SymbolIndex) ?Ast.SymbolIndex {
        var current = ref;
        var hops: u32 = 0;
        while (hops < 32) : (hops += 1) {
            const idx = current.index();
            if (idx >= self.module.symbols.items.len) return null;
            const sym = &self.module.symbols.items[idx];
            switch (sym.kind) {
                .@"struct" => return current,
                .alias => {
                    const target = self.findAliasType(current) orelse return null;
                    switch (target) {
                        .ident => |ident| {
                            if (!ident.ref.isValid()) return null;
                            current = ident.ref;
                        },
                        else => return null,
                    }
                },
                else => return null,
            }
        }
        return null;
    }

    fn computeVecTypeLayout(self: *LayoutComputer, vec: *Ast.VecType) TypeLayout {
        if (vec.shorthand.len > 0) {
            if (primitive_layouts.get(vec.shorthand)) |pl| {
                return .{ .size = pl.size, .alignment = pl.alignment };
            }
        }
        var elem_size: u32 = 4;
        if (vec.elem_type) |et| {
            const el = self.computeTypeLayout(et);
            if (el.size > 0) elem_size = el.size;
        }
        return computeVecLayout(vec.size, elem_size);
    }

    fn computeMatTypeLayout(self: *LayoutComputer, mat: *Ast.MatType) TypeLayout {
        if (mat.shorthand.len > 0) {
            if (primitive_layouts.get(mat.shorthand)) |pl| {
                return .{ .size = pl.size, .alignment = pl.alignment };
            }
        }
        var elem_size: u32 = 4;
        if (mat.elem_type) |et| {
            const el = self.computeTypeLayout(et);
            if (el.size > 0) elem_size = el.size;
        }
        return computeMatLayout(mat.cols, mat.rows, elem_size);
    }

    fn computeArrayTypeLayout(self: *LayoutComputer, arr: *Ast.ArrayType) TypeLayout {
        const et = arr.elem_type orelse return .{};
        const elem = self.computeTypeLayout(et);
        if (elem.size == 0 or elem.alignment == 0) return .{};

        const stride = roundUp(elem.size, elem.alignment);

        // Runtime-sized array.
        const size_expr = arr.size orelse return .{
            .size = 0,
            .alignment = elem.alignment,
            .stride = stride,
        };

        const count = self.evaluateConstExpr(size_expr);
        if (count < 0) return .{
            .size = 0,
            .alignment = elem.alignment,
            .stride = stride,
        };

        return .{
            .size = @as(u32, @intCast(count)) * stride,
            .alignment = elem.alignment,
            .stride = stride,
        };
    }

    /// Evaluate a const-expression to an `i32` (positive — array sizes,
    /// workgroup_size args, attribute values are all required to be a
    /// non-negative integer).  Returns `-1` if the expression doesn't
    /// reduce to a finite non-negative integer at compile time.
    fn evaluateConstExpr(self: *LayoutComputer, expr: Ast.Expr) i32 {
        const v = self.evalConst(expr, 0) orelse return -1;
        const i = v.toI64() orelse return -1;
        if (i < 0 or i > std.math.maxInt(i32)) return -1;
        return @intCast(i);
    }

    /// Recursive const-expression evaluator. Returns `null` if the
    /// expression isn't a const-expression or evaluation fails (overflow,
    /// div-by-zero, unresolved identifier, …). Capped at depth 64 to
    /// guard pathological asts.
    fn evalConst(self: *LayoutComputer, expr: Ast.Expr, depth: u32) ?ConstValue {
        if (depth > 64) return null;
        return switch (expr) {
            .literal => |lit| evalLiteral(lit),
            .paren => |p| self.evalConst(p.expr, depth + 1),
            .unary => |u| {
                const v = self.evalConst(u.operand, depth + 1) orelse return null;
                return switch (u.op) {
                    .neg => switch (v) {
                        .int => |x| ConstValue{ .int = 0 -% x },
                        .float => |x| ConstValue{ .float = -x },
                        .bool => null,
                    },
                    .bit_not => switch (v) {
                        .int => |x| ConstValue{ .int = ~x },
                        else => null,
                    },
                    .not => switch (v) {
                        .bool => |x| ConstValue{ .bool = !x },
                        else => null,
                    },
                    else => null,
                };
            },
            .binary => |b| self.evalBinary(b, depth + 1),
            .ident => |id| self.evalIdent(id),
            .call => |c| self.evalCall(c, depth + 1),
            .member => |m| self.evalMember(m, depth + 1),
            else => null,
        };
    }

    fn evalBinary(self: *LayoutComputer, b: *Ast.BinaryExpr, depth: u32) ?ConstValue {
        const l = self.evalConst(b.left, depth) orelse return null;
        const r = self.evalConst(b.right, depth) orelse return null;
        // Promote to float if either side is float.
        const both_int = l == .int and r == .int;
        if (both_int) {
            const li = l.int;
            const ri = r.int;
            return switch (b.op) {
                .add => .{ .int = li +% ri },
                .sub => .{ .int = li -% ri },
                .mul => .{ .int = li *% ri },
                .div => if (ri == 0) null else .{ .int = @divTrunc(li, ri) },
                .mod => if (ri == 0) null else .{ .int = @mod(li, ri) },
                .@"and" => .{ .int = li & ri },
                .@"or" => .{ .int = li | ri },
                .xor => .{ .int = li ^ ri },
                .shl => if (ri >= 0 and ri < 64) .{ .int = li << @intCast(ri) } else null,
                .shr => if (ri >= 0 and ri < 64) .{ .int = li >> @intCast(ri) } else null,
                .eq => .{ .bool = li == ri },
                .ne => .{ .bool = li != ri },
                .lt => .{ .bool = li < ri },
                .le => .{ .bool = li <= ri },
                .gt => .{ .bool = li > ri },
                .ge => .{ .bool = li >= ri },
                .logical_and, .logical_or => null,
            };
        }
        // Bitwise / shift ops require integer operands.
        switch (b.op) {
            .@"and", .@"or", .xor, .shl, .shr, .mod => return null,
            else => {},
        }
        const lf = l.toF64();
        const rf = r.toF64();
        return switch (b.op) {
            .add => .{ .float = lf + rf },
            .sub => .{ .float = lf - rf },
            .mul => .{ .float = lf * rf },
            .div => if (rf == 0) null else .{ .float = lf / rf },
            .eq => .{ .bool = lf == rf },
            .ne => .{ .bool = lf != rf },
            .lt => .{ .bool = lf < rf },
            .le => .{ .bool = lf <= rf },
            .gt => .{ .bool = lf > rf },
            .ge => .{ .bool = lf >= rf },
            else => null,
        };
    }

    fn evalIdent(self: *LayoutComputer, id: *Ast.IdentExpr) ?ConstValue {
        if (!id.ref.isValid()) return null;
        const idx = id.ref.index();
        if (idx >= self.module.symbols.items.len) return null;
        const sym = &self.module.symbols.items[idx];
        if (sym.kind != .@"const") return null;
        return self.evalConstSymbol(idx);
    }

    /// Evaluate the initializer of the `const` declaration whose name
    /// resolves to `sym_idx`. Memoised to avoid redundant work and to
    /// short-circuit recursive cycles (which the parser should already
    /// reject, but we belt-and-brace).
    fn evalConstSymbol(self: *LayoutComputer, sym_idx: u32) ?ConstValue {
        if (self.const_cache.get(sym_idx)) |cached| return cached;
        // Mark as in-progress (`null`) to break cycles.
        self.const_cache.put(self.arena, sym_idx, null) catch return null;

        for (self.module.declarations.items) |decl| {
            switch (decl) {
                .@"const" => |c| {
                    if (c.name.isValid() and c.name.index() == sym_idx) {
                        const init_expr = c.initializer orelse return null;
                        const v = self.evalConst(init_expr, 0);
                        self.const_cache.put(self.arena, sym_idx, v) catch {};
                        return v;
                    }
                },
                else => {},
            }
        }
        return null;
    }

    fn evalCall(self: *LayoutComputer, c: *Ast.CallExpr, depth: u32) ?ConstValue {
        const func = c.func orelse return null;
        const callee_name = switch (func) {
            .ident => |i| i.name,
            else => return null,
        };

        // Constructor casts to scalar types — convert the single argument.
        if (c.args.items.len == 1) {
            const arg = self.evalConst(c.args.items[0], depth) orelse return null;
            if (std.mem.eql(u8, callee_name, "u32") or
                std.mem.eql(u8, callee_name, "i32"))
            {
                const v = arg.toI64() orelse return null;
                return .{ .int = v };
            }
            if (std.mem.eql(u8, callee_name, "f32") or
                std.mem.eql(u8, callee_name, "f16"))
            {
                return .{ .float = arg.toF64() };
            }
            if (std.mem.eql(u8, callee_name, "bool")) {
                return switch (arg) {
                    .int => |v| ConstValue{ .bool = v != 0 },
                    .float => |v| ConstValue{ .bool = v != 0.0 },
                    .bool => arg,
                };
            }
        }

        // Const-evaluable builtin functions.
        if (std.mem.eql(u8, callee_name, "radians") and c.args.items.len == 1) {
            const a = self.evalConst(c.args.items[0], depth) orelse return null;
            return .{ .float = a.toF64() * std.math.pi / 180.0 };
        }
        if (std.mem.eql(u8, callee_name, "degrees") and c.args.items.len == 1) {
            const a = self.evalConst(c.args.items[0], depth) orelse return null;
            return .{ .float = a.toF64() * 180.0 / std.math.pi };
        }
        if (c.args.items.len == 1) {
            const a = self.evalConst(c.args.items[0], depth) orelse return null;
            // `abs` preserves int vs float kind.
            if (std.mem.eql(u8, callee_name, "abs")) {
                return switch (a) {
                    .int => |v| ConstValue{ .int = if (v < 0) 0 -% v else v },
                    .float => |v| ConstValue{ .float = @abs(v) },
                    .bool => null,
                };
            }
            const f = a.toF64();
            const single_arg_builtins = std.StaticStringMap(*const fn (f64) f64).initComptime(.{
                .{ "sin", &builtinSin },
                .{ "cos", &builtinCos },
                .{ "tan", &builtinTan },
                .{ "asin", &builtinAsin },
                .{ "acos", &builtinAcos },
                .{ "atan", &builtinAtan },
                .{ "floor", &builtinFloor },
                .{ "ceil", &builtinCeil },
                .{ "round", &builtinRound },
                .{ "trunc", &builtinTrunc },
                .{ "sqrt", &builtinSqrt },
                .{ "exp", &builtinExp },
                .{ "log", &builtinLog },
            });
            if (single_arg_builtins.get(callee_name)) |fp| {
                return .{ .float = fp(f) };
            }
        }
        if (c.args.items.len == 2) {
            const a = self.evalConst(c.args.items[0], depth) orelse return null;
            const b = self.evalConst(c.args.items[1], depth) orelse return null;
            if (std.mem.eql(u8, callee_name, "min")) {
                if (a == .int and b == .int) return .{ .int = @min(a.int, b.int) };
                return .{ .float = @min(a.toF64(), b.toF64()) };
            }
            if (std.mem.eql(u8, callee_name, "max")) {
                if (a == .int and b == .int) return .{ .int = @max(a.int, b.int) };
                return .{ .float = @max(a.toF64(), b.toF64()) };
            }
            if (std.mem.eql(u8, callee_name, "pow")) {
                return .{ .float = std.math.pow(f64, a.toF64(), b.toF64()) };
            }
        }
        if (c.args.items.len == 3 and std.mem.eql(u8, callee_name, "clamp")) {
            const x = self.evalConst(c.args.items[0], depth) orelse return null;
            const lo = self.evalConst(c.args.items[1], depth) orelse return null;
            const hi = self.evalConst(c.args.items[2], depth) orelse return null;
            if (x == .int and lo == .int and hi == .int) {
                return .{ .int = @max(lo.int, @min(hi.int, x.int)) };
            }
            return .{ .float = @max(lo.toF64(), @min(hi.toF64(), x.toF64())) };
        }

        return null;
    }

    /// `member` on a const symbol whose initializer is a struct
    /// constructor (e.g. `const a = Foo(2, 10.5); a.x`). Find the field
    /// index by name in the struct decl, evaluate the matching arg.
    fn evalMember(self: *LayoutComputer, m: *Ast.MemberExpr, depth: u32) ?ConstValue {
        // Resolve the base to a const declaration.
        const base_ident = switch (m.base) {
            .ident => |i| i,
            else => return null,
        };
        if (!base_ident.ref.isValid()) return null;
        const base_idx = base_ident.ref.index();
        if (base_idx >= self.module.symbols.items.len) return null;
        const base_sym = &self.module.symbols.items[base_idx];
        if (base_sym.kind != .@"const") return null;

        // Find the matching ConstDecl.
        for (self.module.declarations.items) |decl| {
            if (decl != .@"const") continue;
            const c = decl.@"const";
            if (!c.name.isValid() or c.name.index() != base_idx) continue;
            const init_expr = c.initializer orelse return null;
            // Initializer must be a struct constructor `StructName(args...)`.
            const ctor = switch (init_expr) {
                .call => |cc| cc,
                else => return null,
            };
            const ctor_func = ctor.func orelse return null;
            const struct_name_ident = switch (ctor_func) {
                .ident => |i| i,
                else => return null,
            };
            // Look up the struct declaration to find member index.
            const struct_idx = self.findStructDeclByName(struct_name_ident) orelse return null;
            for (struct_idx.members.items, 0..) |sm, i| {
                const member_name = self.getSymbolName(sm.name);
                if (std.mem.eql(u8, member_name, m.member_name)) {
                    if (i >= ctor.args.items.len) return null;
                    return self.evalConst(ctor.args.items[i], depth);
                }
            }
            return null;
        }
        return null;
    }

    fn findStructDeclByName(self: *const LayoutComputer, ident: *Ast.IdentExpr) ?*Ast.StructDecl {
        if (ident.ref.isValid()) {
            const struct_ref = self.resolveAliasRefToStruct(ident.ref);
            if (struct_ref) |sref| {
                for (self.module.declarations.items) |decl| {
                    if (decl == .@"struct" and decl.@"struct".name == sref) return decl.@"struct";
                }
            }
        }
        // Fallback: name-based lookup (works when ref isn't bound, e.g. attribute args).
        for (self.module.declarations.items) |decl| {
            if (decl != .@"struct") continue;
            const sd = decl.@"struct";
            if (std.mem.eql(u8, self.getSymbolName(sd.name), ident.name)) return sd;
        }
        return null;
    }

    // -----------------------------------------------------------------
    // Struct layout
    // -----------------------------------------------------------------

    fn getStructLayout(self: *LayoutComputer, ref: Ast.SymbolIndex) ?StructLayout {
        if (!ref.isValid()) return null;

        // Follow alias chains: a binding type or struct member may name
        // an alias whose final target is a struct.
        const struct_ref = self.resolveAliasRefToStruct(ref) orelse return null;
        const idx = struct_ref.index();
        if (idx >= self.module.symbols.items.len) return null;

        const sym = &self.module.symbols.items[idx];
        if (sym.kind != .@"struct") return null;

        if (self.struct_cache.get(sym.original_name)) |cached| return cached;

        for (self.module.declarations.items) |decl| {
            switch (decl) {
                .@"struct" => |struct_decl| {
                    if (struct_decl.name == struct_ref) {
                        return self.computeStructLayout(struct_decl) catch return null;
                    }
                },
                else => {},
            }
        }
        return null;
    }

    fn computeStructLayout(self: *LayoutComputer, decl: *Ast.StructDecl) Allocator.Error!StructLayout {
        const name = self.getSymbolName(decl.name);

        if (self.struct_cache.get(name)) |cached| return cached;

        // Pre-allocate fields with expected capacity.
        var fields: std.ArrayListUnmanaged(FieldInfo) = .empty;
        try fields.ensureTotalCapacity(self.arena, decl.members.items.len);

        var layout = StructLayout{
            .size = 0,
            .alignment = 0,
            .fields = fields,
        };
        // Insert placeholder to handle recursive types.
        try self.struct_cache.put(self.arena, name, layout);

        var offset: u32 = 0;
        var max_align: u32 = 1;

        for (decl.members.items) |member| {
            const member_type = member.typ;
            var member_layout = self.computeTypeLayout(member_type);
            if (member_layout.alignment == 0) member_layout.alignment = 1;

            offset = roundUp(offset, member_layout.alignment);

            var field = FieldInfo{
                .name = self.getSymbolName(member.name),
                .name_mapped = self.getMappedName(member.name),
                .name_offset = getSymbolLoc(member.name, self.module.symbols.items),
                .typ = self.typeToStringMapped(member_type, false),
                .type_mapped = self.typeToStringMapped(member_type, true),
                .offset = offset,
                .size = member_layout.size,
                .alignment = member_layout.alignment,
            };

            // Nested struct layout. Resolve aliases so members typed
            // through alias chains still get their layout attached.
            const resolved_member_type = self.resolveAliasType(member_type);
            switch (resolved_member_type) {
                .ident => |ident_type| {
                    if (ident_type.ref.isValid()) {
                        if (self.getStructLayout(ident_type.ref)) |nested| {
                            field.layout = nested;
                        }
                    }
                },
                .array => |array_type| {
                    // Array of structs — attach struct layout.
                    if (array_type.elem_type) |et| {
                        const resolved_et = self.resolveAliasType(et);
                        switch (resolved_et) {
                            .ident => |ident_type| {
                                if (ident_type.ref.isValid()) {
                                    if (self.getStructLayout(ident_type.ref)) |nested| {
                                        field.layout = nested;
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }

            try layout.fields.append(self.arena, field);

            offset += member_layout.size;
            if (member_layout.alignment > max_align) max_align = member_layout.alignment;
        }

        layout.alignment = max_align;
        layout.size = roundUp(offset, max_align);

        // Update cache with final layout.
        try self.struct_cache.put(self.arena, name, layout);

        return layout;
    }

    // -----------------------------------------------------------------
    // Array info extraction
    // -----------------------------------------------------------------

    fn extractArrayInfo(self: *LayoutComputer, array_type: *Ast.ArrayType, depth: u32) ArrayInfo {
        const array_layout = self.computeArrayTypeLayout(array_type);

        var element_count: ?i32 = null;
        var total_size: ?i32 = null;
        if (array_type.size) |size_expr| {
            const count = self.evaluateConstExpr(size_expr);
            if (count >= 0) {
                element_count = count;
                total_size = count * @as(i32, @intCast(array_layout.stride));
            }
        }

        const et = array_type.elem_type orelse return .{
            .depth = depth,
            .element_stride = array_layout.stride,
            .element_type = "",
            .element_type_mapped = "",
        };

        var info = ArrayInfo{
            .depth = depth,
            .element_count = element_count,
            .element_stride = array_layout.stride,
            .total_size = total_size,
            .element_type = self.typeToStringMapped(et, false),
            .element_type_mapped = self.typeToStringMapped(et, true),
        };

        // Struct element layout. Resolve alias chains so an
        // `alias LightArray = array<Light, 3>` element is recognised as
        // a struct (or as a nested array).
        const resolved_et = self.resolveAliasType(et);
        switch (resolved_et) {
            .ident => |ident_type| {
                if (ident_type.ref.isValid()) {
                    if (self.getStructLayout(ident_type.ref)) |sl| {
                        info.element_layout = sl;
                    }
                }
            },
            .array => |nested_arr| {
                const nested = self.arena.create(ArrayInfo) catch return info;
                nested.* = self.extractArrayInfo(nested_arr, depth + 1);
                info.nested = nested;
            },
            else => {},
        }

        return info;
    }

    // -----------------------------------------------------------------
    // Name helpers
    // -----------------------------------------------------------------

    fn getSymbolName(self: *const LayoutComputer, ref: Ast.SymbolIndex) []const u8 {
        if (!ref.isValid()) return "";
        const idx = ref.index();
        if (idx >= self.module.symbols.items.len) return "";
        return self.module.symbols.items[idx].original_name;
    }

    fn getMappedName(self: *const LayoutComputer, ref: Ast.SymbolIndex) []const u8 {
        if (self.renamer) |ren| {
            if (ref.isValid()) {
                return ren.nameForSymbol(ref);
            }
        }
        return self.getSymbolName(ref);
    }

    // -----------------------------------------------------------------
    // Type-to-string conversion
    // -----------------------------------------------------------------

    /// Convert an AST type to its string representation.
    /// When `mapped` is true, user-defined type names go through the renamer.
    /// Returns a slice allocated from self.arena (or a string literal).
    fn typeToStringMapped(self: *LayoutComputer, t: Ast.Type, mapped: bool) []const u8 {
        switch (t) {
            .ident => |ident| {
                if (mapped and ident.ref.isValid()) {
                    return self.getMappedName(ident.ref);
                }
                return ident.name;
            },
            .vec => |vec| {
                if (vec.shorthand.len > 0) return vec.shorthand;
                const et = vec.elem_type orelse return "";
                const elem_str = self.typeToStringMapped(et, mapped);
                return self.fmtAlloc("vec{d}<{s}>", .{ vec.size, elem_str });
            },
            .mat => |mat| {
                if (mat.shorthand.len > 0) return mat.shorthand;
                const et = mat.elem_type orelse return "";
                const elem_str = self.typeToStringMapped(et, mapped);
                return self.fmtAlloc("mat{d}x{d}<{s}>", .{ mat.cols, mat.rows, elem_str });
            },
            .array => |arr| {
                const et = arr.elem_type orelse return "array";
                const elem_str = self.typeToStringMapped(et, mapped);
                if (arr.size) |size_expr| {
                    const size_val = self.evaluateConstExpr(size_expr);
                    if (size_val >= 0) {
                        return self.fmtAlloc("array<{s}, {d}>", .{ elem_str, size_val });
                    }
                }
                return self.fmtAlloc("array<{s}>", .{elem_str});
            },
            .atomic => |at| {
                const elem_str = self.typeToStringMapped(at.elem_type, mapped);
                return self.fmtAlloc("atomic<{s}>", .{elem_str});
            },
            .sampler => |s| {
                return if (s.comparison) "sampler_comparison" else "sampler";
            },
            .texture => |tex| return self.textureTypeToString(tex),
            .ptr => |p| {
                const elem_str = self.typeToStringMapped(p.elem_type, mapped);
                return self.fmtAlloc("ptr<{s}, {s}>", .{ p.address_space.string(), elem_str });
            },
        }
    }

    fn textureTypeToString(self: *LayoutComputer, tex: *Ast.TextureType) []const u8 {
        const prefix: []const u8 = switch (tex.kind) {
            .sampled => "texture",
            .multisampled => "texture_multisampled",
            .storage => "texture_storage",
            .depth => "texture_depth",
            .depth_multisampled => "texture_depth_multisampled",
            .external => return "texture_external",
        };

        const dim: []const u8 = switch (tex.dimension) {
            .@"1d" => "_1d",
            .@"2d" => "_2d",
            .@"2d_array" => "_2d_array",
            .@"3d" => "_3d",
            .cube => "_cube",
            .cube_array => "_cube_array",
        };

        // Sampled textures: texture_Xd<T>
        if (tex.kind == .sampled) {
            if (tex.sampled_type) |st| {
                const type_str = self.typeToStringMapped(st, false);
                return self.fmtAlloc("{s}{s}<{s}>", .{ prefix, dim, type_str });
            }
        }

        // Storage textures: texture_storage_Xd<format, access>
        if (tex.kind == .storage and tex.texel_format.len > 0) {
            if (tex.access_mode != .none) {
                return self.fmtAlloc("{s}{s}<{s}, {s}>", .{
                    prefix,
                    dim,
                    tex.texel_format,
                    tex.access_mode.string(),
                });
            }
            return self.fmtAlloc("{s}{s}<{s}>", .{ prefix, dim, tex.texel_format });
        }

        return self.fmtAlloc("{s}{s}", .{ prefix, dim });
    }

    /// Format a string, allocating from self.arena.
    fn fmtAlloc(self: *LayoutComputer, comptime fmt: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(self.arena, fmt, args) catch "";
    }
};

// =========================================================================
// Layout math helpers
// =========================================================================

/// Compute vector layout from component count and element size.
fn computeVecLayout(size: u8, elem_size: u32) TypeLayout {
    return switch (size) {
        2 => .{ .size = elem_size * 2, .alignment = elem_size * 2 },
        3 => .{ .size = elem_size * 3, .alignment = elem_size * 4 },
        4 => .{ .size = elem_size * 4, .alignment = elem_size * 4 },
        else => .{},
    };
}

/// Compute matrix layout: C columns of vecR<T>.
fn computeMatLayout(cols: u8, rows: u8, elem_size: u32) TypeLayout {
    const col_vec = computeVecLayout(rows, elem_size);
    const stride = roundUp(col_vec.size, col_vec.alignment);
    return .{
        .size = @as(u32, cols) * stride,
        .alignment = col_vec.alignment,
    };
}

/// WGSL roundUp(x, align) — rounds x up to the nearest multiple of align.
pub fn roundUp(x: u32, alignment: u32) u32 {
    if (alignment == 0) return x;
    return ((x + alignment - 1) / alignment) * alignment;
}

// Literal parsing for const-expression evaluation.

fn evalLiteral(lit: *Ast.LiteralExpr) ?ConstValue {
    if (lit.value.len == 0) return null;
    return switch (lit.kind) {
        .int_literal => parseIntLiteral(lit.value),
        .float_literal => parseFloatLiteral(lit.value),
        .true_literal => .{ .bool = true },
        .false_literal => .{ .bool = false },
        else => null,
    };
}

fn parseIntLiteral(s: []const u8) ?ConstValue {
    var v = s;
    if (v.len == 0) return null;
    if (v[v.len - 1] == 'i' or v[v.len - 1] == 'u') v = v[0 .. v.len - 1];
    const i = std.fmt.parseInt(i64, v, 0) catch return null;
    return .{ .int = i };
}

fn parseFloatLiteral(s: []const u8) ?ConstValue {
    var v = s;
    if (v.len == 0) return null;
    // Strip suffixes: f32 = 'f', f16 = 'h'.
    if (v[v.len - 1] == 'f' or v[v.len - 1] == 'h') v = v[0 .. v.len - 1];
    const f = std.fmt.parseFloat(f64, v) catch return null;
    return .{ .float = f };
}

// f64 wrappers for std.math functions so we can hand them to a comptime map.

fn builtinSin(x: f64) f64 {
    return std.math.sin(x);
}
fn builtinCos(x: f64) f64 {
    return std.math.cos(x);
}
fn builtinTan(x: f64) f64 {
    return std.math.tan(x);
}
fn builtinAsin(x: f64) f64 {
    return std.math.asin(x);
}
fn builtinAcos(x: f64) f64 {
    return std.math.acos(x);
}
fn builtinAtan(x: f64) f64 {
    return std.math.atan(x);
}
fn builtinFloor(x: f64) f64 {
    return @floor(x);
}
fn builtinCeil(x: f64) f64 {
    return @ceil(x);
}
fn builtinRound(x: f64) f64 {
    return @round(x);
}
fn builtinTrunc(x: f64) f64 {
    return @trunc(x);
}
fn builtinSqrt(x: f64) f64 {
    return @sqrt(x);
}
fn builtinExp(x: f64) f64 {
    return @exp(x);
}
fn builtinLog(x: f64) f64 {
    return @log(x);
}

// =========================================================================
// JSON serialization helpers
// =========================================================================

fn appendStr(buf: *std.ArrayListUnmanaged(u8), arena: Allocator, s: []const u8) Allocator.Error!void {
    try buf.appendSlice(arena, s);
}

fn appendInt(buf: *std.ArrayListUnmanaged(u8), arena: Allocator, value: anytype) Allocator.Error!void {
    var scratch: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&scratch, "{d}", .{value}) catch return;
    try appendStr(buf, arena, s);
}

fn appendJsonStr(buf: *std.ArrayListUnmanaged(u8), arena: Allocator, s: []const u8) Allocator.Error!void {
    try buf.append(arena, '"');
    for (s) |c| {
        switch (c) {
            '"' => try appendStr(buf, arena, "\\\""),
            '\\' => try appendStr(buf, arena, "\\\\"),
            '\n' => try appendStr(buf, arena, "\\n"),
            '\r' => try appendStr(buf, arena, "\\r"),
            '\t' => try appendStr(buf, arena, "\\t"),
            else => {
                if (c < 0x20) {
                    var scratch: [6]u8 = undefined;
                    const hex = std.fmt.bufPrint(&scratch, "\\u{x:0>4}", .{c}) catch continue;
                    try appendStr(buf, arena, hex);
                } else {
                    try buf.append(arena, c);
                }
            },
        }
    }
    try buf.append(arena, '"');
}

fn writeSpanField(
    buf: *std.ArrayListUnmanaged(u8),
    arena: Allocator,
    name: []const u8,
    span: SpanInfo,
) Allocator.Error!void {
    if (!span.present()) return;
    try buf.append(arena, ',');
    try buf.append(arena, '"');
    try appendStr(buf, arena, name);
    try appendStr(buf, arena, "\":{\"start\":");
    try appendInt(buf, arena, span.start);
    try appendStr(buf, arena, ",\"end\":");
    try appendInt(buf, arena, span.end);
    try appendStr(buf, arena, "}");
}

fn writeBindingJson(buf: *std.ArrayListUnmanaged(u8), arena: Allocator, b: *const BindingInfo) Allocator.Error!void {
    try appendStr(buf, arena, "{\"group\":");
    try appendInt(buf, arena, b.group);
    try appendStr(buf, arena, ",\"binding\":");
    try appendInt(buf, arena, b.binding);
    try appendStr(buf, arena, ",\"name\":");
    try appendJsonStr(buf, arena, b.name);
    try appendStr(buf, arena, ",\"nameMapped\":");
    try appendJsonStr(buf, arena, b.name_mapped);
    try appendStr(buf, arena, ",\"nameOffset\":");
    try appendInt(buf, arena, b.name_offset);
    if (b.stable_id.len > 0) {
        try appendStr(buf, arena, ",\"stableId\":");
        try appendJsonStr(buf, arena, b.stable_id);
    }
    try writeSpanField(buf, arena, "declSpan", b.decl_span);
    try writeSpanField(buf, arena, "typeSpan", b.type_span);
    try appendStr(buf, arena, ",\"addressSpace\":");
    try appendJsonStr(buf, arena, b.address_space);
    if (b.access_mode.len > 0) {
        try appendStr(buf, arena, ",\"accessMode\":");
        try appendJsonStr(buf, arena, b.access_mode);
    }
    try appendStr(buf, arena, ",\"type\":");
    try appendJsonStr(buf, arena, b.typ);
    try appendStr(buf, arena, ",\"typeMapped\":");
    try appendJsonStr(buf, arena, b.type_mapped);
    if (b.layout) |*layout| {
        try appendStr(buf, arena, ",\"layout\":");
        try writeStructLayoutJson(buf, arena, layout);
    }
    if (b.array) |*arr| {
        try appendStr(buf, arena, ",\"array\":");
        try writeArrayInfoJson(buf, arena, arr);
    }
    try appendStr(buf, arena, "}");
}

fn writeStructLayoutJson(buf: *std.ArrayListUnmanaged(u8), arena: Allocator, layout: *const StructLayout) Allocator.Error!void {
    try appendStr(buf, arena, "{\"size\":");
    try appendInt(buf, arena, layout.size);
    try appendStr(buf, arena, ",\"alignment\":");
    try appendInt(buf, arena, layout.alignment);
    try appendStr(buf, arena, ",\"fields\":[");
    for (layout.fields.items, 0..) |*f, i| {
        if (i > 0) try appendStr(buf, arena, ",");
        try writeFieldInfoJson(buf, arena, f);
    }
    try appendStr(buf, arena, "]}");
}

fn writeFieldInfoJson(buf: *std.ArrayListUnmanaged(u8), arena: Allocator, f: *const FieldInfo) Allocator.Error!void {
    try appendStr(buf, arena, "{\"name\":");
    try appendJsonStr(buf, arena, f.name);
    try appendStr(buf, arena, ",\"nameMapped\":");
    try appendJsonStr(buf, arena, f.name_mapped);
    try appendStr(buf, arena, ",\"nameOffset\":");
    try appendInt(buf, arena, f.name_offset);
    if (f.stable_id.len > 0) {
        try appendStr(buf, arena, ",\"stableId\":");
        try appendJsonStr(buf, arena, f.stable_id);
    }
    try writeSpanField(buf, arena, "typeSpan", f.type_span);
    try appendStr(buf, arena, ",\"type\":");
    try appendJsonStr(buf, arena, f.typ);
    try appendStr(buf, arena, ",\"typeMapped\":");
    try appendJsonStr(buf, arena, f.type_mapped);
    try appendStr(buf, arena, ",\"offset\":");
    try appendInt(buf, arena, f.offset);
    try appendStr(buf, arena, ",\"size\":");
    try appendInt(buf, arena, f.size);
    try appendStr(buf, arena, ",\"alignment\":");
    try appendInt(buf, arena, f.alignment);
    if (f.layout) |*layout| {
        try appendStr(buf, arena, ",\"layout\":");
        try writeStructLayoutJson(buf, arena, layout);
    }
    try appendStr(buf, arena, "}");
}

fn writeArrayInfoJson(buf: *std.ArrayListUnmanaged(u8), arena: Allocator, arr: *const ArrayInfo) Allocator.Error!void {
    try appendStr(buf, arena, "{\"depth\":");
    try appendInt(buf, arena, arr.depth);
    try appendStr(buf, arena, ",\"elementCount\":");
    if (arr.element_count) |count| {
        try appendInt(buf, arena, count);
    } else {
        try appendStr(buf, arena, "null");
    }
    try appendStr(buf, arena, ",\"elementStride\":");
    try appendInt(buf, arena, arr.element_stride);
    try appendStr(buf, arena, ",\"totalSize\":");
    if (arr.total_size) |size| {
        try appendInt(buf, arena, size);
    } else {
        try appendStr(buf, arena, "null");
    }
    try appendStr(buf, arena, ",\"elementType\":");
    try appendJsonStr(buf, arena, arr.element_type);
    try appendStr(buf, arena, ",\"elementTypeMapped\":");
    try appendJsonStr(buf, arena, arr.element_type_mapped);
    if (arr.element_layout) |*layout| {
        try appendStr(buf, arena, ",\"elementLayout\":");
        try writeStructLayoutJson(buf, arena, layout);
    }
    if (arr.nested) |nested| {
        try appendStr(buf, arena, ",\"array\":");
        try writeArrayInfoJson(buf, arena, nested);
    }
    try appendStr(buf, arena, "}");
}

fn writeEntryPointJson(buf: *std.ArrayListUnmanaged(u8), arena: Allocator, ep: *const EntryPointInfo) Allocator.Error!void {
    try appendStr(buf, arena, "{\"name\":");
    try appendJsonStr(buf, arena, ep.name);
    try appendStr(buf, arena, ",\"nameOffset\":");
    try appendInt(buf, arena, ep.name_offset);
    if (ep.stable_id.len > 0) {
        try appendStr(buf, arena, ",\"stableId\":");
        try appendJsonStr(buf, arena, ep.stable_id);
    }
    try writeSpanField(buf, arena, "declSpan", ep.decl_span);
    try appendStr(buf, arena, ",\"stage\":");
    try appendJsonStr(buf, arena, ep.stage);
    if (ep.has_workgroup_size) {
        try appendStr(buf, arena, ",\"workgroupSize\":[");
        try appendInt(buf, arena, ep.workgroup_size[0]);
        try appendStr(buf, arena, ",");
        try appendInt(buf, arena, ep.workgroup_size[1]);
        try appendStr(buf, arena, ",");
        try appendInt(buf, arena, ep.workgroup_size[2]);
        try appendStr(buf, arena, "]");
    } else {
        try appendStr(buf, arena, ",\"workgroupSize\":null");
    }
    try appendStr(buf, arena, "}");
}

// =========================================================================
// Tests
// =========================================================================

test "reflect: roundUp basic cases" {
    const testing = std.testing;
    try testing.expectEqual(@as(u32, 0), roundUp(0, 4));
    try testing.expectEqual(@as(u32, 4), roundUp(1, 4));
    try testing.expectEqual(@as(u32, 4), roundUp(4, 4));
    try testing.expectEqual(@as(u32, 8), roundUp(5, 4));
    try testing.expectEqual(@as(u32, 16), roundUp(12, 16));
    try testing.expectEqual(@as(u32, 16), roundUp(13, 16));
    try testing.expectEqual(@as(u32, 5), roundUp(5, 0));
}

test "reflect: primitive layout lookup" {
    const testing = std.testing;
    const f32_layout = primitive_layouts.get("f32").?;
    try testing.expectEqual(@as(u32, 4), f32_layout.size);
    try testing.expectEqual(@as(u32, 4), f32_layout.alignment);

    const vec3f_layout = primitive_layouts.get("vec3f").?;
    try testing.expectEqual(@as(u32, 12), vec3f_layout.size);
    try testing.expectEqual(@as(u32, 16), vec3f_layout.alignment);

    const mat4x4f_layout = primitive_layouts.get("mat4x4f").?;
    try testing.expectEqual(@as(u32, 64), mat4x4f_layout.size);
    try testing.expectEqual(@as(u32, 16), mat4x4f_layout.alignment);
}

test "reflect: computeVecLayout" {
    const testing = std.testing;
    const v2 = computeVecLayout(2, 4);
    try testing.expectEqual(@as(u32, 8), v2.size);
    try testing.expectEqual(@as(u32, 8), v2.alignment);

    const v3 = computeVecLayout(3, 4);
    try testing.expectEqual(@as(u32, 12), v3.size);
    try testing.expectEqual(@as(u32, 16), v3.alignment);

    const v4 = computeVecLayout(4, 4);
    try testing.expectEqual(@as(u32, 16), v4.size);
    try testing.expectEqual(@as(u32, 16), v4.alignment);
}

test "reflect: computeMatLayout" {
    const testing = std.testing;
    // mat4x4f: 4 columns of vec4f
    const m = computeMatLayout(4, 4, 4);
    try testing.expectEqual(@as(u32, 64), m.size);
    try testing.expectEqual(@as(u32, 16), m.alignment);

    // mat2x3f: 2 columns of vec3f (align 16, size 12, stride 16)
    const m2 = computeMatLayout(2, 3, 4);
    try testing.expectEqual(@as(u32, 32), m2.size);
    try testing.expectEqual(@as(u32, 16), m2.alignment);
}

test "reflect: isHandleType sampler ident" {
    var ident = Ast.IdentType{ .name = "sampler" };
    try std.testing.expect(isHandleType(.{ .ident = &ident }));

    var non_handle = Ast.IdentType{ .name = "f32" };
    try std.testing.expect(!isHandleType(.{ .ident = &non_handle }));
}

test "reflect: isHandleType sampler type" {
    var s = Ast.SamplerType{ .comparison = false };
    try std.testing.expect(isHandleType(.{ .sampler = &s }));
}

test "reflect: parseWorkgroupSize" {
    const testing = std.testing;
    // Empty args -> default
    const empty = parseWorkgroupSize(&.{});
    try testing.expectEqual([3]u32{ 1, 1, 1 }, empty);
}

test "reflect: getSymbolName valid ref" {
    const symbols = [_]Ast.Symbol{
        .{ .original_name = "foo", .kind = .function, .flags = .{} },
        .{ .original_name = "bar", .kind = .@"var", .flags = .{} },
    };
    try std.testing.expectEqualStrings("foo", getSymbolName(@enumFromInt(0), &symbols));
    try std.testing.expectEqualStrings("bar", getSymbolName(@enumFromInt(1), &symbols));
}

test "reflect: getSymbolName invalid ref" {
    const symbols = [_]Ast.Symbol{
        .{ .original_name = "foo", .kind = .function, .flags = .{} },
    };
    try std.testing.expectEqualStrings("", getSymbolName(Ast.SymbolIndex.none, &symbols));
}

test "reflect: getSymbolName out of bounds" {
    const symbols = [_]Ast.Symbol{
        .{ .original_name = "foo", .kind = .function, .flags = .{} },
    };
    try std.testing.expectEqualStrings("", getSymbolName(@enumFromInt(10), &symbols));
}

test "reflect: getSymbolName empty symbols" {
    const symbols = [_]Ast.Symbol{};
    try std.testing.expectEqualStrings("", getSymbolName(@enumFromInt(0), &symbols));
}

test "reflect: parseIntAttr literal" {
    var lit = Ast.LiteralExpr{ .kind = .int_literal, .value = "42" };
    try std.testing.expectEqual(@as(i32, 42), parseIntAttr(.{ .literal = &lit }));
}

test "reflect: parseIntAttr non-integer literal" {
    var lit = Ast.LiteralExpr{ .kind = .float_literal, .value = "1.5" };
    try std.testing.expectEqual(@as(i32, -1), parseIntAttr(.{ .literal = &lit }));
}

test "reflect: parseIntAttr non-literal expr" {
    var ident = Ast.IdentExpr{ .name = "someConst" };
    try std.testing.expectEqual(@as(i32, -1), parseIntAttr(.{ .ident = &ident }));
}

test "reflect: addressSpaceToString" {
    try std.testing.expectEqualStrings("uniform", addressSpaceToString(.uniform));
    try std.testing.expectEqualStrings("storage", addressSpaceToString(.storage));
    try std.testing.expectEqualStrings("handle", addressSpaceToString(.handle));
    try std.testing.expectEqualStrings("", addressSpaceToString(.none));
}

test "reflect: isHandleType texture type" {
    var tex = Ast.TextureType{ .kind = .sampled, .dimension = .@"2d" };
    try std.testing.expect(isHandleType(.{ .texture = &tex }));
}

test "reflect: isHandleType non-handle types" {
    var vec = Ast.VecType{ .size = 3 };
    try std.testing.expect(!isHandleType(.{ .vec = &vec }));

    var mat = Ast.MatType{ .cols = 4, .rows = 4 };
    try std.testing.expect(!isHandleType(.{ .mat = &mat }));

    var arr = Ast.ArrayType{};
    try std.testing.expect(!isHandleType(.{ .array = &arr }));
}

test "reflect: isHandleType various sampler/texture ident types" {
    const handle_names = [_][]const u8{
        "sampler",          "sampler_comparison",
        "texture_1d",       "texture_2d",
        "texture_2d_array", "texture_3d",
        "texture_cube",     "texture_cube_array",
        "texture_external",
    };
    for (handle_names) |name| {
        var ident = Ast.IdentType{ .name = name };
        try std.testing.expect(isHandleType(.{ .ident = &ident }));
    }
}

test "reflect: roundUp zero alignment" {
    try std.testing.expectEqual(@as(u32, 10), roundUp(10, 0));
}

test "reflect: roundUp various values" {
    try std.testing.expectEqual(@as(u32, 0), roundUp(0, 4));
    try std.testing.expectEqual(@as(u32, 4), roundUp(1, 4));
    try std.testing.expectEqual(@as(u32, 4), roundUp(4, 4));
    try std.testing.expectEqual(@as(u32, 8), roundUp(5, 4));
    try std.testing.expectEqual(@as(u32, 16), roundUp(12, 16));
    try std.testing.expectEqual(@as(u32, 16), roundUp(16, 16));
    try std.testing.expectEqual(@as(u32, 32), roundUp(17, 16));
}

test "reflect: computeVecLayout edge cases" {
    // vec3<f32>: size=12, align=16
    const v3 = computeVecLayout(3, 4);
    try std.testing.expectEqual(@as(u32, 12), v3.size);
    try std.testing.expectEqual(@as(u32, 16), v3.alignment);

    // Invalid size returns zero layout
    const invalid = computeVecLayout(5, 4);
    try std.testing.expectEqual(@as(u32, 0), invalid.size);
    try std.testing.expectEqual(@as(u32, 0), invalid.alignment);
}

test "reflect: computeMatLayout mat2x2" {
    const m = computeMatLayout(2, 2, 4);
    try std.testing.expectEqual(@as(u32, 16), m.size);
    try std.testing.expectEqual(@as(u32, 8), m.alignment);
}

test "reflect: computeMatLayout mat3x3" {
    const m = computeMatLayout(3, 3, 4);
    try std.testing.expectEqual(@as(u32, 48), m.size);
    try std.testing.expectEqual(@as(u32, 16), m.alignment);
}
