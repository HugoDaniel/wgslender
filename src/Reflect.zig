//! WGSL shader reflection.
//!
//! Extracts binding information, struct layouts, and entry points from a
//! parsed WGSL module. All layout computations follow the WGSL specification
//! for alignment and size rules.

const std = @import("std");
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
    pub fn deinit(self: *ReflectResult, allocator: std.mem.Allocator) void {
        if (self._arena) |_| {
            var arena = self._arena.?;
            arena.deinit();
            self._arena = null;
        } else {
            self.bindings.deinit(allocator);
            self.structs.deinit(allocator);
            self.entry_points.deinit(allocator);
            self.errors.deinit(allocator);
        }
    }

    /// Serialize the reflect result to JSON.
    pub fn toJson(self: *const ReflectResult, buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) void {
        appendStr(buf, allocator, "{\"bindings\":[");
        for (self.bindings.items, 0..) |*b, i| {
            if (i > 0) appendStr(buf, allocator, ",");
            writeBindingJson(buf, allocator, b);
        }
        appendStr(buf, allocator, "],\"structs\":{");
        var struct_iter = self.structs.iterator();
        var first_struct = true;
        while (struct_iter.next()) |entry| {
            if (!first_struct) appendStr(buf, allocator, ",");
            first_struct = false;
            appendJsonStr(buf, allocator, entry.key_ptr.*);
            appendStr(buf, allocator, ":");
            writeStructLayoutJson(buf, allocator, &entry.value_ptr.*);
        }
        appendStr(buf, allocator, "},\"entryPoints\":[");
        for (self.entry_points.items, 0..) |*ep, i| {
            if (i > 0) appendStr(buf, allocator, ",");
            writeEntryPointJson(buf, allocator, ep);
        }
        appendStr(buf, allocator, "]");
        if (self.errors.items.len > 0) {
            appendStr(buf, allocator, ",\"errors\":[");
            for (self.errors.items, 0..) |err, i| {
                if (i > 0) appendStr(buf, allocator, ",");
                appendJsonStr(buf, allocator, err);
            }
            appendStr(buf, allocator, "]");
        }
        appendStr(buf, allocator, "}");
    }

    /// Serialize the reflect result to pretty-printed JSON (2-space indent).
    pub fn toJsonPretty(self: *const ReflectResult, buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) void {
        var compact: std.ArrayListUnmanaged(u8) = .empty;
        self.toJson(&compact, allocator);
        prettyPrintJson(buf, allocator, compact.items);
    }
};

fn prettyPrintJson(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, json: []const u8) void {
    var depth: u32 = 0;
    var in_string = false;
    var i: usize = 0;

    while (i < json.len) {
        const c = json[i];
        if (in_string) {
            buf.append(allocator, c) catch {};
            if (c == '\\' and i + 1 < json.len) {
                i += 1;
                buf.append(allocator, json[i]) catch {};
            } else if (c == '"') {
                in_string = false;
            }
            i += 1;
            continue;
        }
        switch (c) {
            '"' => {
                in_string = true;
                buf.append(allocator, c) catch {};
            },
            '{', '[' => {
                buf.append(allocator, c) catch {};
                // Collapse empty containers ({} / []) onto one line.
                if (i + 1 < json.len and (json[i + 1] == '}' or json[i + 1] == ']')) {
                    i += 1;
                    buf.append(allocator, json[i]) catch {};
                } else {
                    depth += 1;
                    buf.append(allocator, '\n') catch {};
                    writeIndent(buf, allocator, depth);
                }
            },
            '}', ']' => {
                if (depth > 0) depth -= 1;
                buf.append(allocator, '\n') catch {};
                writeIndent(buf, allocator, depth);
                buf.append(allocator, c) catch {};
            },
            ',' => {
                buf.append(allocator, ',') catch {};
                buf.append(allocator, '\n') catch {};
                writeIndent(buf, allocator, depth);
            },
            ':' => {
                buf.appendSlice(allocator, ": ") catch {};
            },
            else => buf.append(allocator, c) catch {},
        }
        i += 1;
    }
}

fn writeIndent(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, depth: u32) void {
    for (0..depth) |_| {
        buf.appendSlice(allocator, "  ") catch {};
    }
}

pub const BindingInfo = struct {
    group: i32,
    binding: i32,
    name: []const u8,
    name_mapped: []const u8,
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
    typ: []const u8,
    type_mapped: []const u8,
    offset: u32,
    size: u32,
    alignment: u32,
    layout: ?StructLayout = null,
};

pub const EntryPointInfo = struct {
    name: []const u8,
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
pub fn reflect(allocator: std.mem.Allocator, module: *Ast.Module) ReflectResult {
    return reflectWithRenamer(allocator, module, null);
}

/// Extract reflection information from a parsed module, using an optional
/// renamer for mapped (minified) names.
pub fn reflectWithRenamer(
    allocator: std.mem.Allocator,
    module: *Ast.Module,
    renamer: ?*const Printer.Renamer,
) ReflectResult {
    var result = ReflectResult{};

    var lc = LayoutComputer.init(allocator, module, renamer);

    // First pass: collect all struct definitions.
    for (module.declarations.items) |decl| {
        switch (decl) {
            .@"struct" => |struct_decl| {
                const name = lc.getSymbolName(struct_decl.name);
                if (name.len > 0) {
                    const layout = lc.computeStructLayout(struct_decl);
                    result.structs.put(allocator, name, layout) catch {};
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
                    result.bindings.append(allocator, b) catch {};
                }
            },
            .function => |fn_decl| {
                if (extractEntryPoint(fn_decl, module.symbols.items)) |ep| {
                    result.entry_points.append(allocator, ep) catch {};
                }
            },
            else => {},
        }
    }

    return result;
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

    var info = BindingInfo{
        .group = group,
        .binding = binding,
        .name = name,
        .name_mapped = mapped_name,
        .address_space = addressSpaceToString(address_space),
        .typ = if (var_decl.typ) |t| lc.typeToStringMapped(t, false) else "",
        .type_mapped = if (var_decl.typ) |t| lc.typeToStringMapped(t, true) else "",
    };

    // Add access mode for storage bindings.
    if (var_decl.access_mode != .none) {
        info.access_mode = var_decl.access_mode.string();
    }

    // Handle array types.
    if (var_decl.typ) |t| {
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
        if (var_decl.typ) |t| {
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

const LayoutComputer = struct {
    allocator: std.mem.Allocator,
    module: *Ast.Module,
    struct_cache: std.StringHashMapUnmanaged(StructLayout),
    renamer: ?*const Printer.Renamer,
    /// Scratch buffer for typeToStringMapped.
    fmt_buf: std.ArrayListUnmanaged(u8) = .empty,

    fn init(
        allocator: std.mem.Allocator,
        module: *Ast.Module,
        renamer: ?*const Printer.Renamer,
    ) LayoutComputer {
        return .{
            .allocator = allocator,
            .module = module,
            .struct_cache = .{},
            .renamer = renamer,
        };
    }

    // -----------------------------------------------------------------
    // Type layout computation
    // -----------------------------------------------------------------

    /// Iteratively computes type layout, unwrapping atomic wrappers.
    fn computeTypeLayout(self: *LayoutComputer, t: Ast.Type) TypeLayout {
        var current = t;
        while (true) {
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
                .atomic => |at| current = at.elem_type,
                .sampler, .texture, .ptr => return .{},
            }
        }
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

    fn evaluateConstExpr(_: *LayoutComputer, expr: Ast.Expr) i32 {
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

    // -----------------------------------------------------------------
    // Struct layout
    // -----------------------------------------------------------------

    fn getStructLayout(self: *LayoutComputer, ref: Ast.SymbolIndex) ?StructLayout {
        if (!ref.isValid()) return null;
        const idx = ref.index();
        if (idx >= self.module.symbols.items.len) return null;

        const sym = &self.module.symbols.items[idx];
        if (sym.kind != .@"struct") return null;

        if (self.struct_cache.get(sym.original_name)) |cached| return cached;

        for (self.module.declarations.items) |decl| {
            switch (decl) {
                .@"struct" => |struct_decl| {
                    if (struct_decl.name == ref) {
                        return self.computeStructLayout(struct_decl);
                    }
                },
                else => {},
            }
        }
        return null;
    }

    fn computeStructLayout(self: *LayoutComputer, decl: *Ast.StructDecl) StructLayout {
        const name = self.getSymbolName(decl.name);

        if (self.struct_cache.get(name)) |cached| return cached;

        // Pre-allocate fields with expected capacity.
        var fields: std.ArrayListUnmanaged(FieldInfo) = .empty;
        fields.ensureTotalCapacity(self.allocator, decl.members.items.len) catch {};

        var layout = StructLayout{
            .size = 0,
            .alignment = 0,
            .fields = fields,
        };
        // Insert placeholder to handle recursive types.
        self.struct_cache.put(self.allocator, name, layout) catch {};

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
                .typ = self.typeToStringMapped(member_type, false),
                .type_mapped = self.typeToStringMapped(member_type, true),
                .offset = offset,
                .size = member_layout.size,
                .alignment = member_layout.alignment,
            };

            // Nested struct layout.
            switch (member_type) {
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
                        switch (et) {
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

            layout.fields.append(self.allocator, field) catch {};

            offset += member_layout.size;
            if (member_layout.alignment > max_align) max_align = member_layout.alignment;
        }

        layout.alignment = max_align;
        layout.size = roundUp(offset, max_align);

        // Update cache with final layout.
        self.struct_cache.put(self.allocator, name, layout) catch {};

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

        // Struct element layout.
        switch (et) {
            .ident => |ident_type| {
                if (ident_type.ref.isValid()) {
                    if (self.getStructLayout(ident_type.ref)) |sl| {
                        info.element_layout = sl;
                    }
                }
            },
            .array => |nested_arr| {
                const nested = self.allocator.create(ArrayInfo) catch return info;
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
    /// Returns a slice allocated from self.allocator (or a string literal).
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

    /// Format a string, allocating from self.allocator.
    fn fmtAlloc(self: *LayoutComputer, comptime fmt: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(self.allocator, fmt, args) catch "";
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

// =========================================================================
// JSON serialization helpers
// =========================================================================

fn appendStr(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, s: []const u8) void {
    buf.appendSlice(allocator, s) catch {};
}

fn appendInt(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: anytype) void {
    var tmp: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch return;
    appendStr(buf, allocator, s);
}

fn appendJsonStr(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, s: []const u8) void {
    buf.append(allocator, '"') catch {};
    for (s) |c| {
        switch (c) {
            '"' => appendStr(buf, allocator, "\\\""),
            '\\' => appendStr(buf, allocator, "\\\\"),
            '\n' => appendStr(buf, allocator, "\\n"),
            '\r' => appendStr(buf, allocator, "\\r"),
            '\t' => appendStr(buf, allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    var tmp: [6]u8 = undefined;
                    const hex = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch continue;
                    appendStr(buf, allocator, hex);
                } else {
                    buf.append(allocator, c) catch {};
                }
            },
        }
    }
    buf.append(allocator, '"') catch {};
}

fn writeBindingJson(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, b: *const BindingInfo) void {
    appendStr(buf, allocator, "{\"group\":");
    appendInt(buf, allocator, b.group);
    appendStr(buf, allocator, ",\"binding\":");
    appendInt(buf, allocator, b.binding);
    appendStr(buf, allocator, ",\"name\":");
    appendJsonStr(buf, allocator, b.name);
    appendStr(buf, allocator, ",\"nameMapped\":");
    appendJsonStr(buf, allocator, b.name_mapped);
    appendStr(buf, allocator, ",\"addressSpace\":");
    appendJsonStr(buf, allocator, b.address_space);
    if (b.access_mode.len > 0) {
        appendStr(buf, allocator, ",\"accessMode\":");
        appendJsonStr(buf, allocator, b.access_mode);
    }
    appendStr(buf, allocator, ",\"type\":");
    appendJsonStr(buf, allocator, b.typ);
    appendStr(buf, allocator, ",\"typeMapped\":");
    appendJsonStr(buf, allocator, b.type_mapped);
    if (b.layout) |*layout| {
        appendStr(buf, allocator, ",\"layout\":");
        writeStructLayoutJson(buf, allocator, layout);
    }
    if (b.array) |*arr| {
        appendStr(buf, allocator, ",\"array\":");
        writeArrayInfoJson(buf, allocator, arr);
    }
    appendStr(buf, allocator, "}");
}

fn writeStructLayoutJson(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, layout: *const StructLayout) void {
    appendStr(buf, allocator, "{\"size\":");
    appendInt(buf, allocator, layout.size);
    appendStr(buf, allocator, ",\"alignment\":");
    appendInt(buf, allocator, layout.alignment);
    appendStr(buf, allocator, ",\"fields\":[");
    for (layout.fields.items, 0..) |*f, i| {
        if (i > 0) appendStr(buf, allocator, ",");
        writeFieldInfoJson(buf, allocator, f);
    }
    appendStr(buf, allocator, "]}");
}

fn writeFieldInfoJson(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, f: *const FieldInfo) void {
    appendStr(buf, allocator, "{\"name\":");
    appendJsonStr(buf, allocator, f.name);
    appendStr(buf, allocator, ",\"nameMapped\":");
    appendJsonStr(buf, allocator, f.name_mapped);
    appendStr(buf, allocator, ",\"type\":");
    appendJsonStr(buf, allocator, f.typ);
    appendStr(buf, allocator, ",\"typeMapped\":");
    appendJsonStr(buf, allocator, f.type_mapped);
    appendStr(buf, allocator, ",\"offset\":");
    appendInt(buf, allocator, f.offset);
    appendStr(buf, allocator, ",\"size\":");
    appendInt(buf, allocator, f.size);
    appendStr(buf, allocator, ",\"alignment\":");
    appendInt(buf, allocator, f.alignment);
    if (f.layout) |*layout| {
        appendStr(buf, allocator, ",\"layout\":");
        writeStructLayoutJson(buf, allocator, layout);
    }
    appendStr(buf, allocator, "}");
}

fn writeArrayInfoJson(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, arr: *const ArrayInfo) void {
    appendStr(buf, allocator, "{\"depth\":");
    appendInt(buf, allocator, arr.depth);
    appendStr(buf, allocator, ",\"elementCount\":");
    if (arr.element_count) |count| {
        appendInt(buf, allocator, count);
    } else {
        appendStr(buf, allocator, "null");
    }
    appendStr(buf, allocator, ",\"elementStride\":");
    appendInt(buf, allocator, arr.element_stride);
    appendStr(buf, allocator, ",\"totalSize\":");
    if (arr.total_size) |size| {
        appendInt(buf, allocator, size);
    } else {
        appendStr(buf, allocator, "null");
    }
    appendStr(buf, allocator, ",\"elementType\":");
    appendJsonStr(buf, allocator, arr.element_type);
    appendStr(buf, allocator, ",\"elementTypeMapped\":");
    appendJsonStr(buf, allocator, arr.element_type_mapped);
    if (arr.element_layout) |*layout| {
        appendStr(buf, allocator, ",\"elementLayout\":");
        writeStructLayoutJson(buf, allocator, layout);
    }
    if (arr.nested) |nested| {
        appendStr(buf, allocator, ",\"array\":");
        writeArrayInfoJson(buf, allocator, nested);
    }
    appendStr(buf, allocator, "}");
}

fn writeEntryPointJson(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, ep: *const EntryPointInfo) void {
    appendStr(buf, allocator, "{\"name\":");
    appendJsonStr(buf, allocator, ep.name);
    appendStr(buf, allocator, ",\"stage\":");
    appendJsonStr(buf, allocator, ep.stage);
    if (ep.has_workgroup_size) {
        appendStr(buf, allocator, ",\"workgroupSize\":[");
        appendInt(buf, allocator, ep.workgroup_size[0]);
        appendStr(buf, allocator, ",");
        appendInt(buf, allocator, ep.workgroup_size[1]);
        appendStr(buf, allocator, ",");
        appendInt(buf, allocator, ep.workgroup_size[2]);
        appendStr(buf, allocator, "]");
    } else {
        appendStr(buf, allocator, ",\"workgroupSize\":null");
    }
    appendStr(buf, allocator, "}");
}

// =========================================================================
// Tests
// =========================================================================

test "roundUp basic cases" {
    const testing = std.testing;
    try testing.expectEqual(@as(u32, 0), roundUp(0, 4));
    try testing.expectEqual(@as(u32, 4), roundUp(1, 4));
    try testing.expectEqual(@as(u32, 4), roundUp(4, 4));
    try testing.expectEqual(@as(u32, 8), roundUp(5, 4));
    try testing.expectEqual(@as(u32, 16), roundUp(12, 16));
    try testing.expectEqual(@as(u32, 16), roundUp(13, 16));
    try testing.expectEqual(@as(u32, 5), roundUp(5, 0));
}

test "primitive layout lookup" {
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

test "computeVecLayout" {
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

test "computeMatLayout" {
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

test "isHandleType sampler ident" {
    var ident = Ast.IdentType{ .name = "sampler" };
    try std.testing.expect(isHandleType(.{ .ident = &ident }));

    var non_handle = Ast.IdentType{ .name = "f32" };
    try std.testing.expect(!isHandleType(.{ .ident = &non_handle }));
}

test "isHandleType sampler type" {
    var s = Ast.SamplerType{ .comparison = false };
    try std.testing.expect(isHandleType(.{ .sampler = &s }));
}

test "parseWorkgroupSize" {
    const testing = std.testing;
    // Empty args -> default
    const empty = parseWorkgroupSize(&.{});
    try testing.expectEqual([3]u32{ 1, 1, 1 }, empty);
}

test "getSymbolName valid ref" {
    const symbols = [_]Ast.Symbol{
        .{ .original_name = "foo", .kind = .function, .flags = .{} },
        .{ .original_name = "bar", .kind = .@"var", .flags = .{} },
    };
    try std.testing.expectEqualStrings("foo", getSymbolName(@enumFromInt(0), &symbols));
    try std.testing.expectEqualStrings("bar", getSymbolName(@enumFromInt(1), &symbols));
}

test "getSymbolName invalid ref" {
    const symbols = [_]Ast.Symbol{
        .{ .original_name = "foo", .kind = .function, .flags = .{} },
    };
    try std.testing.expectEqualStrings("", getSymbolName(Ast.SymbolIndex.none, &symbols));
}

test "getSymbolName out of bounds" {
    const symbols = [_]Ast.Symbol{
        .{ .original_name = "foo", .kind = .function, .flags = .{} },
    };
    try std.testing.expectEqualStrings("", getSymbolName(@enumFromInt(10), &symbols));
}

test "getSymbolName empty symbols" {
    const symbols = [_]Ast.Symbol{};
    try std.testing.expectEqualStrings("", getSymbolName(@enumFromInt(0), &symbols));
}

test "parseIntAttr literal" {
    var lit = Ast.LiteralExpr{ .kind = .int_literal, .value = "42" };
    try std.testing.expectEqual(@as(i32, 42), parseIntAttr(.{ .literal = &lit }));
}

test "parseIntAttr non-integer literal" {
    var lit = Ast.LiteralExpr{ .kind = .float_literal, .value = "1.5" };
    try std.testing.expectEqual(@as(i32, -1), parseIntAttr(.{ .literal = &lit }));
}

test "parseIntAttr non-literal expr" {
    var ident = Ast.IdentExpr{ .name = "someConst" };
    try std.testing.expectEqual(@as(i32, -1), parseIntAttr(.{ .ident = &ident }));
}

test "addressSpaceToString" {
    try std.testing.expectEqualStrings("uniform", addressSpaceToString(.uniform));
    try std.testing.expectEqualStrings("storage", addressSpaceToString(.storage));
    try std.testing.expectEqualStrings("handle", addressSpaceToString(.handle));
    try std.testing.expectEqualStrings("", addressSpaceToString(.none));
}

test "isHandleType texture type" {
    var tex = Ast.TextureType{ .kind = .sampled, .dimension = .@"2d" };
    try std.testing.expect(isHandleType(.{ .texture = &tex }));
}

test "isHandleType non-handle types" {
    var vec = Ast.VecType{ .size = 3 };
    try std.testing.expect(!isHandleType(.{ .vec = &vec }));

    var mat = Ast.MatType{ .cols = 4, .rows = 4 };
    try std.testing.expect(!isHandleType(.{ .mat = &mat }));

    var arr = Ast.ArrayType{};
    try std.testing.expect(!isHandleType(.{ .array = &arr }));
}

test "isHandleType various sampler/texture ident types" {
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

test "roundUp zero alignment" {
    try std.testing.expectEqual(@as(u32, 10), roundUp(10, 0));
}

test "roundUp various values" {
    try std.testing.expectEqual(@as(u32, 0), roundUp(0, 4));
    try std.testing.expectEqual(@as(u32, 4), roundUp(1, 4));
    try std.testing.expectEqual(@as(u32, 4), roundUp(4, 4));
    try std.testing.expectEqual(@as(u32, 8), roundUp(5, 4));
    try std.testing.expectEqual(@as(u32, 16), roundUp(12, 16));
    try std.testing.expectEqual(@as(u32, 16), roundUp(16, 16));
    try std.testing.expectEqual(@as(u32, 32), roundUp(17, 16));
}

test "computeVecLayout edge cases" {
    // vec3<f32>: size=12, align=16
    const v3 = computeVecLayout(3, 4);
    try std.testing.expectEqual(@as(u32, 12), v3.size);
    try std.testing.expectEqual(@as(u32, 16), v3.alignment);

    // Invalid size returns zero layout
    const invalid = computeVecLayout(5, 4);
    try std.testing.expectEqual(@as(u32, 0), invalid.size);
    try std.testing.expectEqual(@as(u32, 0), invalid.alignment);
}

test "computeMatLayout mat2x2" {
    const m = computeMatLayout(2, 2, 4);
    try std.testing.expectEqual(@as(u32, 16), m.size);
    try std.testing.expectEqual(@as(u32, 8), m.alignment);
}

test "computeMatLayout mat3x3" {
    const m = computeMatLayout(3, 3, 4);
    try std.testing.expectEqual(@as(u32, 48), m.size);
    try std.testing.expectEqual(@as(u32, 16), m.alignment);
}
