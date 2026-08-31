//! WGSL memory-layout computation for reflect results.
//!
//! This is the `layout ↔ everything` seam of `Reflect.zig` — the largest of
//! the split. It owns `LayoutComputer`, the one stateful engine that walks AST
//! types and produces the wire vocabulary Reflect exposes: `StructLayout`,
//! `FieldInfo`, `ArrayInfo`, and the structured `TypeInfo` tree, plus the
//! WGSL §6.2.10 size/alignment rules (`primitive_layouts`, `computeVecLayout`,
//! `computeMatLayout`, `roundUp`).
//!
//! `Reflect.zig` stays the façade: it owns the public data structs this file
//! fills, drives a `LayoutComputer` through the binding/entry-point extraction
//! free-fns, and re-exports this file as `Reflect.Layout`. The `pub` methods
//! below are exactly the ones the driver / extraction path calls across the
//! file boundary; everything else is private plumbing.
//!
//! The single const-evaluation seam is `LayoutComputer.evaluateConstExpr`,
//! which drives the shared `ConstEval` in **wrapping** mode with the
//! `LayoutComputer` itself as the resolver (`resolveIdent` / `resolveMember`).
//! Contrast with the Validator's saturating int-only path; both are pinned by
//! `tests/const_eval_test.zig`.
//!
//! ⚠ There is a *second*, independent layout engine in `Types.zig`
//! (`Types.Struct.computeLayout`) that mirrors the struct-layout algorithm
//! here for the resolved-`Types.Type` domain the validator works in. The two
//! are deliberately not unified — this one runs directly on the AST so
//! reflection works on any parse, without type resolution. Keep the numeric
//! rules in sync by hand; see the cross-reference on `computeStructLayout`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("../Ast.zig");
const Printer = @import("../Printer.zig");
const ConstEval = @import("../ConstEval.zig");
const Reflect = @import("../Reflect.zig");

// Public reflect vocabulary this file *builds* — `Reflect.zig` stays the
// façade that owns these types. Aliased so the moved bodies read exactly as
// they did in Reflect.zig (same trick as `reflect/CallGraph.zig`).
const TypeInfo = Reflect.TypeInfo;
const TextureInfo = Reflect.TextureInfo;
const StructLayout = Reflect.StructLayout;
const FieldInfo = Reflect.FieldInfo;
const ArrayInfo = Reflect.ArrayInfo;
const getSymbolLoc = Reflect.getSymbolLoc;

// =========================================================================
// TypeLayout — internal layout computation result
// =========================================================================

const TypeLayout = struct {
    size: u32 = 0,
    alignment: u32 = 0,
    stride: u32 = 0, // for arrays only
};

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

pub const LayoutComputer = struct {
    arena: Allocator,
    module: *Ast.Module,
    struct_cache: std.StringHashMapUnmanaged(StructLayout),
    renamer: ?*const Printer.Renamer,
    /// Scratch buffer for typeToStringMapped.
    fmt_buf: std.ArrayList(u8) = .empty,
    /// Cache of evaluated const declarations keyed by `SymbolIndex.index()`.
    /// Speeds up repeated identifier lookups and breaks cycles.
    const_cache: std.AutoHashMapUnmanaged(u32, ?ConstEval.Value) = .{},

    pub fn init(
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
    pub fn resolveAliasType(self: *const LayoutComputer, t: Ast.Type) Ast.Type {
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
    pub fn resolveAliasRefToStruct(self: *const LayoutComputer, ref: Ast.SymbolIndex) ?Ast.SymbolIndex {
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

    // -----------------------------------------------------------------
    // TypeInfo construction
    // -----------------------------------------------------------------

    /// Build a structured `TypeInfo` tree for `t`. The returned pointer is
    /// allocated from `self.arena` and lives as long as the reflect
    /// arena; safe to embed in `BindingInfo.type_info` / `FieldInfo.type_info`.
    /// Aliases are followed (so a binding declared as `var<uniform> u: MyAlias`
    /// gets the underlying form). Returns `null` on allocation failure.
    pub fn buildTypeInfo(self: *LayoutComputer, t: Ast.Type) ?*const TypeInfo {
        return self.buildTypeInfoImpl(t, 0);
    }

    fn buildTypeInfoImpl(self: *LayoutComputer, t: Ast.Type, depth: u32) ?*const TypeInfo {
        // Cap recursion to match other walkers in this file.
        if (depth > 64) return null;
        const resolved = self.resolveAliasType(t);
        switch (resolved) {
            .ident => |ident| {
                if (primitive_layouts.get(ident.name)) |pl| {
                    return self.buildPrimitiveTypeInfo(ident.name, pl);
                }
                // Handle-ident types: the parser surfaces sampler /
                // texture spellings as `.ident` (with the full name in
                // `ident.name`) rather than `.sampler` / `.texture`. Map
                // them to the corresponding structured TypeInfo arm.
                if (handleIdentToTypeInfo(ident.name)) |ti| {
                    return self.alloc(ti);
                }
                if (ident.ref.isValid()) {
                    if (self.getStructLayout(ident.ref)) |sl| {
                        return self.alloc(TypeInfo{ .@"struct" = .{
                            .name = ident.name,
                            .size = sl.size,
                            .alignment = sl.alignment,
                        } });
                    }
                }
                // Unknown ident — not a builtin, not a handle spelling,
                // not a struct in this module. Callers still get a node,
                // but one that says so: a zero-size `scalar` was a shape
                // no real scalar has, and a host switching on `kind` read
                // it as a scalar named `Missing` and believed it.
                return self.alloc(TypeInfo{ .unresolved = .{ .name = ident.name } });
            },
            .vec => |vec| return self.buildVecTypeInfo(vec, depth),
            .mat => |mat| return self.buildMatTypeInfo(mat, depth),
            .array => |arr| return self.buildArrayTypeInfo(arr, depth),
            .atomic => |at| {
                const layout = self.computeTypeLayout(.{ .atomic = at });
                const inner = self.buildTypeInfoImpl(at.elem_type, depth + 1) orelse return null;
                return self.alloc(TypeInfo{ .atomic = .{
                    .format = inner,
                    .size = layout.size,
                    .alignment = layout.alignment,
                } });
            },
            .sampler => |s| return self.alloc(TypeInfo{ .sampler = .{ .comparison = s.comparison } }),
            .texture => |tex| return self.buildTextureTypeInfo(tex),
            .ptr => |p| {
                const inner = self.buildTypeInfoImpl(p.elem_type, depth + 1) orelse return null;
                return self.alloc(TypeInfo{ .ptr = .{
                    .address_space = p.address_space,
                    .format = inner,
                    .access = p.access_mode,
                } });
            },
        }
    }

    fn buildPrimitiveTypeInfo(self: *LayoutComputer, name: []const u8, pl: PrimitiveLayout) ?*const TypeInfo {
        // Detect the vec/mat shorthand spellings (vec3f / mat4x4f / …) so
        // they get a structured `vec`/`mat` node rather than a scalar one.
        if (parseVecShorthand(name)) |info| {
            const elem_pl = primitive_layouts.get(info.elem_name) orelse return self.alloc(TypeInfo{ .scalar = .{
                .name = name,
                .size = pl.size,
                .alignment = pl.alignment,
            } });
            const elem = self.alloc(TypeInfo{ .scalar = .{
                .name = info.elem_name,
                .size = elem_pl.size,
                .alignment = elem_pl.alignment,
            } }) orelse return null;
            return self.alloc(TypeInfo{ .vec = .{
                .width = info.width,
                .format = elem,
                .size = pl.size,
                .alignment = pl.alignment,
            } });
        }
        if (parseMatShorthand(name)) |info| {
            const elem_pl = primitive_layouts.get(info.elem_name) orelse return self.alloc(TypeInfo{ .scalar = .{
                .name = name,
                .size = pl.size,
                .alignment = pl.alignment,
            } });
            const elem = self.alloc(TypeInfo{ .scalar = .{
                .name = info.elem_name,
                .size = elem_pl.size,
                .alignment = elem_pl.alignment,
            } }) orelse return null;
            const col_layout = computeVecLayout(info.rows, elem_pl.size);
            const stride = roundUp(col_layout.size, col_layout.alignment);
            return self.alloc(TypeInfo{ .mat = .{
                .cols = info.cols,
                .rows = info.rows,
                .format = elem,
                .size = pl.size,
                .alignment = pl.alignment,
                .stride = stride,
            } });
        }
        return self.alloc(TypeInfo{ .scalar = .{
            .name = name,
            .size = pl.size,
            .alignment = pl.alignment,
        } });
    }

    fn buildVecTypeInfo(self: *LayoutComputer, vec: *Ast.VecType, depth: u32) ?*const TypeInfo {
        const layout = self.computeVecTypeLayout(vec);
        const elem_t: Ast.Type = vec.elem_type orelse {
            // Shorthand without explicit element type — infer from suffix.
            if (vec.shorthand.len > 0) {
                if (parseVecShorthand(vec.shorthand)) |info| {
                    if (primitive_layouts.get(info.elem_name)) |epl| {
                        const elem = self.alloc(TypeInfo{ .scalar = .{
                            .name = info.elem_name,
                            .size = epl.size,
                            .alignment = epl.alignment,
                        } }) orelse return null;
                        return self.alloc(TypeInfo{ .vec = .{
                            .width = vec.size,
                            .format = elem,
                            .size = layout.size,
                            .alignment = layout.alignment,
                        } });
                    }
                }
            }
            // Fall through: unknown element — emit a sentinel scalar leaf.
            const sentinel = self.alloc(TypeInfo{ .scalar = .{ .name = "", .size = 0, .alignment = 0 } }) orelse return null;
            return self.alloc(TypeInfo{ .vec = .{
                .width = vec.size,
                .format = sentinel,
                .size = layout.size,
                .alignment = layout.alignment,
            } });
        };
        const elem = self.buildTypeInfoImpl(elem_t, depth + 1) orelse return null;
        return self.alloc(TypeInfo{ .vec = .{
            .width = vec.size,
            .format = elem,
            .size = layout.size,
            .alignment = layout.alignment,
        } });
    }

    fn buildMatTypeInfo(self: *LayoutComputer, mat: *Ast.MatType, depth: u32) ?*const TypeInfo {
        const layout = self.computeMatTypeLayout(mat);
        var elem_size: u32 = 4;
        const elem: *const TypeInfo = blk: {
            if (mat.elem_type) |et| {
                const inner = self.buildTypeInfoImpl(et, depth + 1) orelse return null;
                if (sizeOfTypeInfo(inner)) |s| elem_size = s;
                break :blk inner;
            }
            // Shorthand: derive element from suffix.
            if (mat.shorthand.len > 0) {
                if (parseMatShorthand(mat.shorthand)) |info| {
                    if (primitive_layouts.get(info.elem_name)) |epl| {
                        elem_size = epl.size;
                        const ti = self.alloc(TypeInfo{ .scalar = .{
                            .name = info.elem_name,
                            .size = epl.size,
                            .alignment = epl.alignment,
                        } }) orelse return null;
                        break :blk ti;
                    }
                }
            }
            const sentinel = self.alloc(TypeInfo{ .scalar = .{ .name = "", .size = 0, .alignment = 0 } }) orelse return null;
            break :blk sentinel;
        };
        const col_layout = computeVecLayout(mat.rows, elem_size);
        const stride = roundUp(col_layout.size, col_layout.alignment);
        return self.alloc(TypeInfo{ .mat = .{
            .cols = mat.cols,
            .rows = mat.rows,
            .format = elem,
            .size = layout.size,
            .alignment = layout.alignment,
            .stride = stride,
        } });
    }

    fn buildArrayTypeInfo(self: *LayoutComputer, arr: *Ast.ArrayType, depth: u32) ?*const TypeInfo {
        const layout = self.computeArrayTypeLayout(arr);
        const et = arr.elem_type orelse {
            const sentinel = self.alloc(TypeInfo{ .scalar = .{ .name = "", .size = 0, .alignment = 0 } }) orelse return null;
            return self.alloc(TypeInfo{ .array = .{
                .format = sentinel,
                .count = null,
                .size = null,
                .stride = layout.stride,
                .alignment = layout.alignment,
            } });
        };
        const elem = self.buildTypeInfoImpl(et, depth + 1) orelse return null;
        var count: ?u32 = null;
        var total_size: ?u32 = null;
        if (arr.size) |size_expr| {
            const c = self.evaluateConstExpr(size_expr);
            if (c >= 0) {
                count = @intCast(c);
                total_size = @as(u32, @intCast(c)) * layout.stride;
            }
        }
        return self.alloc(TypeInfo{ .array = .{
            .format = elem,
            .count = count,
            .size = total_size,
            .stride = layout.stride,
            .alignment = layout.alignment,
        } });
    }

    fn buildTextureTypeInfo(self: *LayoutComputer, tex: *Ast.TextureType) ?*const TypeInfo {
        var info = TextureInfo{
            .dim = tex.dimension,
            .kind = tex.kind,
            .format = tex.texel_format,
            .access = tex.access_mode,
        };
        if (tex.kind == .sampled or tex.kind == .multisampled) {
            if (tex.sampled_type) |st| {
                info.sample_type = self.typeToStringMapped(st, false);
            }
        }
        return self.alloc(TypeInfo{ .texture = info });
    }

    fn alloc(self: *LayoutComputer, value: TypeInfo) ?*const TypeInfo {
        const ptr = self.arena.create(TypeInfo) catch return null;
        ptr.* = value;
        return ptr;
    }

    // -----------------------------------------------------------------
    // Member layout-attribute scanning
    // -----------------------------------------------------------------

    const LayoutAttrOverrides = struct {
        @"align": ?u32 = null,
        size: ?u32 = null,
        stride: ?u32 = null,
    };

    /// Scan a struct member's attributes for `@align(N)`, `@size(N)`, and
    /// `@stride(N)`. Each attribute's argument must be a const-expression
    /// reducing to a positive integer; otherwise that attribute is
    /// ignored at the reflection layer (Validator emits diagnostics).
    fn collectMemberLayoutAttrs(self: *LayoutComputer, member: Ast.StructMember) LayoutAttrOverrides {
        var out = LayoutAttrOverrides{};
        for (member.attributes.items) |attr| {
            if (attr.args.items.len == 0) continue;
            const v = self.evaluateConstExpr(attr.args.items[0]);
            if (v <= 0) continue;
            const u: u32 = @intCast(v);
            if (std.mem.eql(u8, attr.name, "align")) out.@"align" = u;
            if (std.mem.eql(u8, attr.name, "size")) out.size = u;
            if (std.mem.eql(u8, attr.name, "stride")) out.stride = u;
        }
        return out;
    }

    /// Build the structured `TypeInfo` for a struct member, propagating
    /// `@align`/`@size`/`@stride` overrides into the resulting nodes so
    /// downstream consumers see the actual bytes-laid-out values rather
    /// than the natural ones.
    fn buildFieldTypeInfo(self: *LayoutComputer, t: Ast.Type, overrides: LayoutAttrOverrides) ?*const TypeInfo {
        const ti = self.buildTypeInfo(t) orelse return null;
        if (overrides.@"align" == null and overrides.size == null and overrides.stride == null) return ti;
        // The TypeInfo tree is otherwise shared / immutable; clone the
        // top-level node before patching so overrides on this member
        // don't bleed into other fields with the same source type.
        const patched = self.arena.create(TypeInfo) catch return ti;
        patched.* = ti.*;
        switch (patched.*) {
            .scalar => |*s| {
                if (overrides.@"align") |a| if (isPow2(a) and a >= s.alignment) {
                    s.alignment = a;
                };
                if (overrides.size) |sz| if (sz >= s.size) {
                    s.size = sz;
                };
            },
            .vec => |*v| {
                if (overrides.@"align") |a| if (isPow2(a) and a >= v.alignment) {
                    v.alignment = a;
                };
                if (overrides.size) |sz| if (sz >= v.size) {
                    v.size = sz;
                };
            },
            .mat => |*m| {
                if (overrides.@"align") |a| if (isPow2(a) and a >= m.alignment) {
                    m.alignment = a;
                };
                if (overrides.size) |sz| if (sz >= m.size) {
                    m.size = sz;
                };
            },
            .array => |*a| {
                if (overrides.@"align") |al| if (isPow2(al) and al >= a.alignment) {
                    a.alignment = al;
                };
                if (overrides.stride) |st| if (st >= 1) {
                    a.stride = st;
                    if (a.count) |c| a.size = c * st;
                };
                if (overrides.size) |sz| if (a.size == null or sz >= a.size.?) {
                    a.size = sz;
                };
            },
            .@"struct" => |*s| {
                if (overrides.@"align") |a| if (isPow2(a) and a >= s.alignment) {
                    s.alignment = a;
                };
                if (overrides.size) |sz| if (sz >= s.size) {
                    s.size = sz;
                };
            },
            .atomic => |*a| {
                if (overrides.@"align") |al| if (isPow2(al) and al >= a.alignment) {
                    a.alignment = al;
                };
                if (overrides.size) |sz| if (sz >= a.size) {
                    a.size = sz;
                };
            },
            // Nothing to patch: a handle has no host-side layout, a
            // pointer is not a member type, and an unresolved name has
            // no size or alignment for `@align` / `@size` to raise.
            .sampler, .texture, .ptr, .unresolved => {},
        }
        return patched;
    }

    /// Evaluate a const-expression to an `i32` (positive — array sizes,
    /// workgroup_size args, attribute values are all required to be a
    /// non-negative integer).  Returns `-1` if the expression doesn't
    /// reduce to a finite non-negative integer at compile time.
    ///
    /// The single seam onto the shared evaluator: every layout / extraction
    /// call site goes through this i32 wrapper. Reflect drives `ConstEval`
    /// in **wrapping** mode (`.wrap`) and supplies `LayoutComputer` itself as
    /// the resolver — see `resolveIdent` / `resolveMember` below. Contrast
    /// with the Validator's `.saturate` mode + int-only resolver
    /// (`docs/deferred/consteval-extraction.md`). Characterization pins:
    /// `tests/const_eval_test.zig`.
    pub fn evaluateConstExpr(self: *LayoutComputer, expr: Ast.Expr) i32 {
        const v = ConstEval.eval(self, .wrap, expr, 0) orelse return -1;
        const i = v.toI64() orelse return -1;
        if (i < 0 or i > std.math.maxInt(i32)) return -1;
        return @intCast(i);
    }

    /// `ConstEval` resolver hook for `.ident` — map a bound symbol reference
    /// to the value of its `const` declaration, or `null` when the reference
    /// is unbound / out of range / not a const. Lazy + memoized via
    /// `evalConstSymbol`.
    pub fn resolveIdent(self: *LayoutComputer, ref: Ast.SymbolIndex) ?ConstEval.Value {
        if (!ref.isValid()) return null;
        const idx = ref.index();
        if (idx >= self.module.symbols.items.len) return null;
        const sym = &self.module.symbols.items[idx];
        if (sym.kind != .@"const") return null;
        return self.evalConstSymbol(idx);
    }

    /// Evaluate the initializer of the `const` declaration whose name
    /// resolves to `sym_idx`. Memoised to avoid redundant work and to
    /// short-circuit recursive cycles (which the parser should already
    /// reject, but we belt-and-brace).
    fn evalConstSymbol(self: *LayoutComputer, sym_idx: u32) ?ConstEval.Value {
        if (self.const_cache.get(sym_idx)) |cached| return cached;
        // Mark as in-progress (`null`) to break cycles.
        self.const_cache.put(self.arena, sym_idx, null) catch return null;

        for (self.module.declarations.items) |decl| {
            switch (decl) {
                .@"const" => |c| {
                    if (c.name.isValid() and c.name.index() == sym_idx) {
                        const init_expr = c.initializer orelse return null;
                        const v = ConstEval.eval(self, .wrap, init_expr, 0);
                        self.const_cache.put(self.arena, sym_idx, v) catch {};
                        return v;
                    }
                },
                else => {},
            }
        }
        return null;
    }

    /// `ConstEval` resolver hook for `.member` — `a.x` on a const symbol
    /// whose initializer is a struct constructor (e.g. `const a = Foo(2,
    /// 10.5); a.x`). Find the field index by name in the struct decl and
    /// evaluate the matching constructor argument back through `ConstEval`.
    /// Needs the module's declarations + symbol naming, so it lives with the
    /// resolver rather than in the shared core.
    pub fn resolveMember(self: *LayoutComputer, m: *Ast.MemberExpr, depth: u32) ?ConstEval.Value {
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
                    return ConstEval.eval(self, .wrap, ctor.args.items[i], depth);
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
    //
    // NOTE: `computeStructLayout` below is mirrored by a second, independent
    // engine — `Types.Struct.computeLayout` (`src/Types.zig`) — that lays out
    // resolved `Types.Type` for the validator. This one walks the AST directly
    // so reflection works on any parse. Deliberately not unified; keep the
    // §6.2.10 numeric rules in sync by hand.
    // -----------------------------------------------------------------

    pub fn getStructLayout(self: *LayoutComputer, ref: Ast.SymbolIndex) ?StructLayout {
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

    pub fn computeStructLayout(self: *LayoutComputer, decl: *Ast.StructDecl) Allocator.Error!StructLayout {
        const name = self.getSymbolName(decl.name);

        if (self.struct_cache.get(name)) |cached| return cached;

        // Pre-allocate fields with expected capacity.
        var fields: std.ArrayList(FieldInfo) = .empty;
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

            // Honor @align(N), @size(N), @stride(N) member attributes.
            // Only applied if validity-checkable here (positive, ≥ natural,
            // power-of-2 for @align). Validator emits diagnostics on
            // violations; reflection silently keeps the natural value so
            // a partially-invalid input still produces sensible output.
            const overrides = self.collectMemberLayoutAttrs(member);
            if (overrides.@"align") |a| {
                if (isPow2(a) and a >= member_layout.alignment) {
                    member_layout.alignment = a;
                }
            }
            if (overrides.size) |s| {
                if (s >= member_layout.size) member_layout.size = s;
            }
            if (overrides.stride) |st| {
                // @stride only changes layout for array members; override
                // the element stride and recompute the array's total size.
                const resolved = self.resolveAliasType(member_type);
                if (resolved == .array) {
                    const arr = resolved.array;
                    if (arr.size) |size_expr| {
                        const count = self.evaluateConstExpr(size_expr);
                        if (count >= 0 and st >= 1) {
                            member_layout.stride = st;
                            member_layout.size = @as(u32, @intCast(count)) * st;
                        }
                    } else if (st >= 1) {
                        member_layout.stride = st;
                    }
                }
            }

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
                .type_info = self.buildFieldTypeInfo(member_type, overrides),
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

    pub fn extractArrayInfo(self: *LayoutComputer, array_type: *Ast.ArrayType, depth: u32) ArrayInfo {
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

    pub fn getSymbolName(self: *const LayoutComputer, ref: Ast.SymbolIndex) []const u8 {
        if (!ref.isValid()) return "";
        const idx = ref.index();
        if (idx >= self.module.symbols.items.len) return "";
        return self.module.symbols.items[idx].original_name;
    }

    pub fn getMappedName(self: *const LayoutComputer, ref: Ast.SymbolIndex) []const u8 {
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
    pub fn typeToStringMapped(self: *LayoutComputer, t: Ast.Type, mapped: bool) []const u8 {
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
                // The access mode is written only when the author wrote one
                // (`.none` otherwise). Dropping an explicit `read_write`
                // would leave a string that re-reads as the default `read`;
                // inventing one where there was none would spell
                // `ptr<function, T, read>`, which WGSL permits only on
                // `storage`.
                if (p.access_mode == .none) {
                    return self.fmtAlloc("ptr<{s}, {s}>", .{ p.address_space.string(), elem_str });
                }
                return self.fmtAlloc("ptr<{s}, {s}, {s}>", .{
                    p.address_space.string(),
                    elem_str,
                    p.access_mode.string(),
                });
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
/// Private to Layout after R4 (grep-verified zero external callers).
fn roundUp(x: u32, alignment: u32) u32 {
    if (alignment == 0) return x;
    return ((x + alignment - 1) / alignment) * alignment;
}

/// True iff `x` is a power of two (1, 2, 4, …). Zero is not a power of two.
fn isPow2(x: u32) bool {
    return x > 0 and (x & (x - 1)) == 0;
}

// =========================================================================
// Vec/mat shorthand parsers + TypeInfo helpers
// =========================================================================

const VecShorthand = struct {
    width: u8,
    elem_name: []const u8,
};

/// Parse a vec shorthand spelling (vec2i, vec3f, vec4h, vec2u, vec3b, …)
/// into width + element-type name. Returns `null` if `name` isn't a
/// shorthand recognised in `primitive_layouts`.
fn parseVecShorthand(name: []const u8) ?VecShorthand {
    if (name.len != 5) return null;
    if (name[0] != 'v' or name[1] != 'e' or name[2] != 'c') return null;
    const width: u8 = switch (name[3]) {
        '2' => 2,
        '3' => 3,
        '4' => 4,
        else => return null,
    };
    const elem_name: []const u8 = switch (name[4]) {
        'i' => "i32",
        'u' => "u32",
        'f' => "f32",
        'h' => "f16",
        'b' => "bool",
        else => return null,
    };
    return .{ .width = width, .elem_name = elem_name };
}

const MatShorthand = struct {
    cols: u8,
    rows: u8,
    elem_name: []const u8,
};

/// Parse a mat shorthand spelling (mat2x2f, mat4x4h, …) into cols/rows
/// plus element-type name.
fn parseMatShorthand(name: []const u8) ?MatShorthand {
    // matCxRT — 7 chars exactly (e.g. mat2x2f).
    if (name.len != 7) return null;
    if (name[0] != 'm' or name[1] != 'a' or name[2] != 't') return null;
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
    const elem_name: []const u8 = switch (name[6]) {
        'f' => "f32",
        'h' => "f16",
        else => return null,
    };
    return .{ .cols = cols, .rows = rows, .elem_name = elem_name };
}

/// Pull the size out of a built `TypeInfo` node. Used to size stride
/// computations when descending into a child element type.
fn sizeOfTypeInfo(t: *const TypeInfo) ?u32 {
    return switch (t.*) {
        .scalar => |s| s.size,
        .vec => |v| v.size,
        .mat => |m| m.size,
        .array => |a| a.size,
        .@"struct" => |s| s.size,
        .atomic => |a| a.size,
        // No size: a handle is opaque, a pointer is not a member type,
        // and an unresolved name was never measured.
        .sampler, .texture, .ptr, .unresolved => null,
    };
}

/// Map a sampler / texture spelling that the parser surfaces as
/// `.ident` to a structured `TypeInfo` value. Returns `null` for any
/// other ident.
fn handleIdentToTypeInfo(name: []const u8) ?TypeInfo {
    if (std.mem.eql(u8, name, "sampler")) return .{ .sampler = .{ .comparison = false } };
    if (std.mem.eql(u8, name, "sampler_comparison")) return .{ .sampler = .{ .comparison = true } };
    // Texture spellings carry no template args at this site — that path is
    // handled by `buildTextureTypeInfo`. Here we cover only the no-arg
    // forms (e.g. `texture_external` and the depth/depth-array variants).
    const Tk = Ast.TextureKind;
    const Td = Ast.TextureDimension;
    const TexEntry = struct { name: []const u8, dim: Td, kind: Tk };
    const handle_textures = [_]TexEntry{
        .{ .name = "texture_external", .dim = .@"2d", .kind = .external },
        .{ .name = "texture_depth_2d", .dim = .@"2d", .kind = .depth },
        .{ .name = "texture_depth_2d_array", .dim = .@"2d_array", .kind = .depth },
        .{ .name = "texture_depth_cube", .dim = .cube, .kind = .depth },
        .{ .name = "texture_depth_cube_array", .dim = .cube_array, .kind = .depth },
        .{ .name = "texture_depth_multisampled_2d", .dim = .@"2d", .kind = .depth_multisampled },
    };
    for (handle_textures) |h| {
        if (std.mem.eql(u8, name, h.name)) {
            return .{ .texture = .{ .dim = h.dim, .kind = h.kind } };
        }
    }
    return null;
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
