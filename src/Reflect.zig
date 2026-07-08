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

/// JSON output schema version.
///
/// `v1` is the pre-versioned shape: `{bindings, structs, entryPoints,
/// overrides, functions, errors?}`. `v2` adds a top-level `"version": 2`
/// marker and four subset views — `uniforms[]`, `storage[]`, `textures[]`,
/// `samplers[]` — filtered from `bindings[]` by address space + type, plus
/// a top-level `aliases[]` collected from WGSL `alias T = U;` declarations.
/// The legacy `bindings[]` array is still emitted in v2 as the union.
pub const JsonVersion = enum { v1, v2 };

pub const ReflectResult = struct {
    bindings: std.ArrayList(BindingInfo) = .empty,
    structs: std.StringHashMapUnmanaged(StructLayout) = .{},
    entry_points: std.ArrayList(EntryPointInfo) = .empty,
    overrides: std.ArrayList(OverrideInfo) = .empty,
    functions: std.ArrayList(FunctionInfo) = .empty,
    aliases: std.ArrayList(AliasInfo) = .empty,
    errors: std.ArrayList([]const u8) = .empty,
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
            self.overrides.deinit(arena);
            self.functions.deinit(arena);
            self.aliases.deinit(arena);
            self.errors.deinit(arena);
        }
    }

    /// Serialize the reflect result to JSON. Defaults to v2.
    pub fn toJson(self: *const ReflectResult, buf: *std.ArrayList(u8), arena: Allocator) Allocator.Error!void {
        try self.toJsonVersion(buf, arena, .v2);
    }

    /// Serialize the reflect result to JSON at the requested schema version.
    pub fn toJsonVersion(
        self: *const ReflectResult,
        buf: *std.ArrayList(u8),
        arena: Allocator,
        version: JsonVersion,
    ) Allocator.Error!void {
        try appendStr(buf, arena, "{");
        if (version == .v2) {
            try appendStr(buf, arena, "\"version\":2,");
        }
        try appendStr(buf, arena, "\"bindings\":[");
        for (self.bindings.items, 0..) |*b, i| {
            if (i > 0) try appendStr(buf, arena, ",");
            try writeBindingJson(buf, arena, b);
        }
        try appendStr(buf, arena, "]");

        if (version == .v2) {
            try writeBindingSubset(buf, arena, ",\"uniforms\":", self.bindings.items, isUniformBinding);
            try writeBindingSubset(buf, arena, ",\"storage\":", self.bindings.items, isStorageBinding);
            try writeBindingSubset(buf, arena, ",\"textures\":", self.bindings.items, isTextureBinding);
            try writeBindingSubset(buf, arena, ",\"samplers\":", self.bindings.items, isSamplerBinding);
        }

        try appendStr(buf, arena, ",\"structs\":{");
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
        try appendStr(buf, arena, "],\"overrides\":[");
        for (self.overrides.items, 0..) |*o, i| {
            if (i > 0) try appendStr(buf, arena, ",");
            try writeOverrideJson(buf, arena, o);
        }
        try appendStr(buf, arena, "],\"functions\":[");
        for (self.functions.items, 0..) |*f, i| {
            if (i > 0) try appendStr(buf, arena, ",");
            try writeFunctionJson(buf, arena, f);
        }
        try appendStr(buf, arena, "]");
        if (version == .v2) {
            try appendStr(buf, arena, ",\"aliases\":[");
            for (self.aliases.items, 0..) |*a, i| {
                if (i > 0) try appendStr(buf, arena, ",");
                try writeAliasJson(buf, arena, a);
            }
            try appendStr(buf, arena, "]");
        }
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
    /// Defaults to v2.
    pub fn toJsonPretty(self: *const ReflectResult, buf: *std.ArrayList(u8), arena: Allocator) Allocator.Error!void {
        try self.toJsonPrettyVersion(buf, arena, .v2);
    }

    /// Serialize the reflect result to pretty-printed JSON at the requested
    /// schema version.
    pub fn toJsonPrettyVersion(
        self: *const ReflectResult,
        buf: *std.ArrayList(u8),
        arena: Allocator,
        version: JsonVersion,
    ) Allocator.Error!void {
        var compact: std.ArrayList(u8) = .empty;
        try self.toJsonVersion(&compact, arena, version);
        try prettyPrintJson(buf, arena, compact.items);
    }
};

// =========================================================================
// Subset-view filters (used by JsonVersion.v2)
// =========================================================================
//
// A binding's slot in the v2 subset views is decided by the *binding's
// declared address space + handle type*, not by the resolved struct
// shape. `var<uniform>` → uniforms; `var<storage[, …]>` → storage;
// handle-typed (texture / sampler) bindings → textures or samplers.
// Storage textures are bound with a default address space but use a
// `texture_storage_*` type — they appear in `textures[]`, mirroring what
// the WebGPU bind-group layout sees on the JS side. (wgsl_reflect groups
// storage textures under `storage[]`; we keep them under `textures[]` so
// `samplers[]`/`textures[]` together cover every handle binding.)

fn isUniformBinding(b: *const BindingInfo) bool {
    return std.mem.eql(u8, b.address_space, "uniform");
}

fn isStorageBinding(b: *const BindingInfo) bool {
    return std.mem.eql(u8, b.address_space, "storage");
}

fn isTextureBinding(b: *const BindingInfo) bool {
    if (b.type_info) |ti| return ti.* == .texture;
    return false;
}

fn isSamplerBinding(b: *const BindingInfo) bool {
    if (b.type_info) |ti| return ti.* == .sampler;
    return false;
}

fn writeBindingSubset(
    buf: *std.ArrayList(u8),
    arena: Allocator,
    key: []const u8,
    bindings: []const BindingInfo,
    predicate: *const fn (*const BindingInfo) bool,
) Allocator.Error!void {
    try appendStr(buf, arena, key);
    try appendStr(buf, arena, "[");
    var first = true;
    for (bindings) |*b| {
        if (!predicate(b)) continue;
        if (!first) try appendStr(buf, arena, ",");
        first = false;
        try writeBindingJson(buf, arena, b);
    }
    try appendStr(buf, arena, "]");
}

fn prettyPrintJson(buf: *std.ArrayList(u8), arena: Allocator, json: []const u8) Allocator.Error!void {
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

fn writeIndent(buf: *std.ArrayList(u8), arena: Allocator, depth: u32) Allocator.Error!void {
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
    /// Structured type tree mirroring `typ`. `null` on parse-failure
    /// paths only — every successful binding gets a populated `TypeInfo`.
    type_info: ?*const TypeInfo = null,
    /// Names of related bindings. For a `texture_*` binding, this is the
    /// set of samplers it has been observed paired with in
    /// `textureSample*` / `textureGather*` calls; for a `sampler` it is
    /// the set of textures. Populated bidirectionally. May be empty.
    relations: std.ArrayList([]const u8) = .empty,
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
    fields: std.ArrayList(FieldInfo) = .empty,
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
    /// Structured type description. Walks the same shape as `typ`/`layout`
    /// but as a programmatic tree — siblings of `array`/`atomic`/`ptr`
    /// link to inner `*TypeInfo`. `null` only on parse-failure paths.
    type_info: ?*const TypeInfo = null,
};

// =========================================================================
// TypeInfo — structured (recursive) type description
// =========================================================================
//
// Mirrors the shape of WGSL types programmatically so consumers can walk a
// binding's type tree without reparsing the textual `typ` string. Fields
// with size/alignment/stride are pre-computed during reflection — they
// match the values reported on `BindingInfo.layout` / `FieldInfo` for the
// same physical type.

pub const TypeInfo = union(enum) {
    scalar: ScalarInfo,
    vec: VecInfo,
    mat: MatInfo,
    array: ArrayTypeInfo,
    @"struct": StructTypeRef,
    atomic: AtomicInfo,
    texture: TextureInfo,
    sampler: SamplerInfo,
    ptr: PtrInfo,

    pub const ScalarInfo = struct {
        name: []const u8,
        size: u32,
        alignment: u32,
    };
    pub const VecInfo = struct {
        width: u8,
        format: *const TypeInfo,
        size: u32,
        alignment: u32,
    };
    pub const MatInfo = struct {
        cols: u8,
        rows: u8,
        format: *const TypeInfo,
        size: u32,
        alignment: u32,
        stride: u32,
    };
    pub const ArrayTypeInfo = struct {
        format: *const TypeInfo,
        /// `null` for runtime-sized arrays.
        count: ?u32,
        /// `null` when the element count is not const-known. `count * stride` otherwise.
        size: ?u32,
        stride: u32,
        alignment: u32,
    };
    /// Struct reference by name. Look up the full layout via
    /// `ReflectResult.structs.get(name)`.
    pub const StructTypeRef = struct {
        name: []const u8,
        size: u32,
        alignment: u32,
    };
    pub const AtomicInfo = struct {
        format: *const TypeInfo,
        size: u32,
        alignment: u32,
    };
    pub const SamplerInfo = struct {
        comparison: bool,
    };
    pub const PtrInfo = struct {
        address_space: Ast.AddressSpace,
        format: *const TypeInfo,
        access: Ast.AccessMode,
    };
};

/// Structured texture description. Carries the same information as the
/// WGSL textual form (`texture_storage_2d<rgba8unorm, write>`,
/// `texture_depth_2d`, `texture_2d<f32>`, …) but split into typed fields.
pub const TextureInfo = struct {
    dim: Ast.TextureDimension,
    kind: Ast.TextureKind,
    /// Texel format string (e.g. `"rgba8unorm"`) for storage textures;
    /// empty otherwise.
    format: []const u8 = "",
    access: Ast.AccessMode = .none,
    /// Sample-type leaf for sampled / multisampled textures
    /// (e.g. `"f32"` / `"i32"` / `"u32"`); empty otherwise.
    sample_type: []const u8 = "",
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
    /// Names of `@override` constants referenced from this entry point's
    /// `@workgroup_size(...)` arguments. When an axis is set from an
    /// override, `workgroup_size[i]` is reported as `0` (the runtime
    /// must supply the value). Empty if no overrides drive the size.
    overrides: std.ArrayList([]const u8) = .empty,
    /// One entry per `@location(N)`/`@builtin(name)` carrying input from
    /// the prior pipeline stage. Struct-typed parameters are flattened
    /// into one entry per attributed member.
    inputs: std.ArrayList(InputOutputInfo) = .empty,
    /// One entry per `@location(N)`/`@builtin(name)` produced by this
    /// stage. Struct-typed return types are flattened.
    outputs: std.ArrayList(InputOutputInfo) = .empty,
    /// Names of bindings (module-scope `var`s with `@group/@binding`)
    /// reachable from this entry point's transitive call graph. Order
    /// matches the order in which each binding was first observed,
    /// then deduplicated.
    resources: std.ArrayList([]const u8) = .empty,
};

pub const InputOutputInfo = struct {
    /// The parameter name (or struct member name when flattened from
    /// a struct-typed parameter / return). Empty for a return value
    /// where the type was attributed directly with no member context.
    name: []const u8,
    /// `@location(N)` value, or `null` when bound by `@builtin` instead.
    location: ?u32 = null,
    /// `@builtin(name)` value (e.g. `"position"`, `"vertex_index"`),
    /// empty when bound by `@location`.
    builtin: []const u8 = "",
    /// `@interpolate(type, sampling)`. Always `null` for `@builtin`.
    interpolate: ?InterpolateInfo = null,
    /// Type spelled in source.
    typ: []const u8 = "",
    /// Structured type tree mirroring `typ`.
    type_info: ?*const TypeInfo = null,
};

pub const InterpolateInfo = struct {
    /// `"perspective"`, `"linear"`, or `"flat"` (default `"perspective"`
    /// when omitted; explicit value preserved).
    type: []const u8,
    /// `"center"`, `"centroid"`, `"sample"`, `"first"`, `"either"`, …
    /// Empty when not specified.
    sampling: []const u8 = "",
};

/// Per-function reflection record. Populated for every user-defined
/// `fn` (entry points included). Resources / overrides / calls are
/// captured in source order during a one-pass body walk; the
/// transitive flag is updated after BFS from entry points.
pub const FunctionInfo = struct {
    name: []const u8,
    name_mapped: []const u8 = "",
    name_offset: u32 = 0,
    stable_id: []const u8 = "",
    decl_span: SpanInfo = .{},
    /// Names of user-defined functions called directly from this body.
    calls: std.ArrayList([]const u8) = .empty,
    /// Names of module-scope `var` declarations referenced directly
    /// from this body. Texture / sampler / storage / uniform — all
    /// kinds are included; consumers filter by looking up the
    /// matching `BindingInfo`.
    direct_resources: std.ArrayList([]const u8) = .empty,
    /// Names of `@override` constants referenced directly.
    direct_overrides: std.ArrayList([]const u8) = .empty,
    /// True iff this function is an entry point or transitively
    /// called from one.
    in_use: bool = false,
};

/// Metadata for a top-level WGSL `alias T = U;` declaration. The
/// reflected `typ` / `type_info` resolve any nested aliases to their
/// final form just like a binding's type would. Aliases participate in
/// JSON v2 only.
pub const AliasInfo = struct {
    name: []const u8,
    name_mapped: []const u8,
    /// Byte offset of the declared name in the original source.
    name_offset: u32 = 0,
    /// Reparse-stable identifier for this alias symbol; empty if absent.
    stable_id: []const u8 = "",
    /// Byte range of the full declaration (`alias` keyword through `;`).
    decl_span: SpanInfo = .{},
    /// Right-hand-side type spelled in source (e.g. `"vec3<f32>"`).
    typ: []const u8 = "",
    /// Right-hand-side type with renamer-applied user type names; equal
    /// to `typ` when no renamer is in play.
    type_mapped: []const u8 = "",
    /// Structured tree mirroring `typ`. `null` only on parse-failure paths.
    type_info: ?*const TypeInfo = null,
};

pub const OverrideInfo = struct {
    name: []const u8,
    name_mapped: []const u8,
    /// Byte offset of the declared name in the original source.
    name_offset: u32 = 0,
    /// Reparse-stable identifier for this override symbol; empty if absent.
    stable_id: []const u8 = "",
    /// Byte range of the full declaration (attributes through `;`).
    decl_span: SpanInfo = .{},
    /// `@id(N)` value if specified; `null` for pipeline-name-keyed overrides.
    id: ?u32 = null,
    /// Type spelled in source (e.g. `"f32"`); empty when omitted.
    typ: []const u8 = "",
    /// Structured type tree mirroring `typ`. `null` when type was omitted
    /// or the source was malformed.
    type_info: ?*const TypeInfo = null,
    /// Default-value expression text as written in source, or empty when
    /// no initializer was given.
    default: []const u8 = "",
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

    // Second pass (a): collect type aliases. Aliases don't enter struct
    // layouts or binding extraction — `typeToStringMapped` already follows
    // `Symbol.kind == .alias` chains for nested types — so this pass is
    // pure metadata for v2 consumers (and wgsl_reflect parity).
    for (module.declarations.items) |decl| switch (decl) {
        .alias => |a| {
            const name = lc.getSymbolName(a.name);
            if (name.len == 0) continue;
            var info = AliasInfo{
                .name = name,
                .name_mapped = lc.getMappedName(a.name),
                .name_offset = getSymbolLoc(a.name, module.symbols.items),
                .decl_span = spanInfoFromAst(a.decl_span),
                .typ = lc.typeToStringMapped(a.typ, false),
                .type_mapped = lc.typeToStringMapped(a.typ, true),
                .type_info = lc.buildTypeInfo(a.typ),
            };
            if (StableId.stableIdFor(arena, module, a.name)) |maybe_id| {
                if (maybe_id) |id| info.stable_id = id.bytes;
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.IdTooLong => {},
            }
            try result.aliases.append(arena, info);
        },
        else => {},
    };

    // Second pass (b): collect overrides. Entry-point extraction below uses
    // `Symbol.kind == .override` to detect override-driven workgroup_size,
    // so the actual references happen via SymbolIndex; this pass just
    // surfaces the metadata to consumers.
    for (module.declarations.items) |decl| switch (decl) {
        .override => |o| {
            var info = OverrideInfo{
                .name = lc.getSymbolName(o.name),
                .name_mapped = lc.getMappedName(o.name),
                .name_offset = getSymbolLoc(o.name, module.symbols.items),
                .decl_span = spanInfoFromAst(o.decl_span),
            };
            // @id(N) — pipeline-constant id
            for (o.attributes.items) |attr| {
                if (std.mem.eql(u8, attr.name, "id") and attr.args.items.len > 0) {
                    const v = lc.evaluateConstExpr(attr.args.items[0]);
                    if (v >= 0) info.id = @intCast(v);
                }
            }
            if (o.typ) |t| {
                info.typ = lc.typeToStringMapped(t, false);
                info.type_info = lc.buildTypeInfo(t);
            }
            if (o.initializer) |expr| {
                // Prefer the source slice when the node carries a stamped
                // span; fall back to a small renderer for literals/idents
                // that are left with an empty `expr.span`.
                const sp = expr.span();
                if (sp.end > sp.start and sp.end <= module.source.len) {
                    info.default = module.source[sp.start..sp.end];
                } else {
                    info.default = try renderExprText(arena, expr);
                }
            }
            if (StableId.stableIdFor(arena, module, o.name)) |maybe_id| {
                if (maybe_id) |id| info.stable_id = id.bytes;
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.IdTooLong => {},
            }
            try result.overrides.append(arena, info);
        },
        else => {},
    };

    // Third pass: collect bindings and entry points.
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
                if (try extractEntryPoint(arena, fn_decl, module, &lc)) |ep| {
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

    // Call-graph + resource-attribution pass. Walk every user
    // `FunctionDecl` body, recording direct resource refs, override
    // refs, and outgoing call edges. Texture-sampling builtin calls
    // also stamp bidirectional `relations` on the matching bindings.
    try buildCallGraph(arena, module, &result);
    // Compute transitive resources / overrides per entry point and
    // mark `in_use` on every reachable function.
    try propagateEntryReachability(arena, &result);

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
        .type_info = if (var_decl.typ) |t| lc.buildTypeInfo(t) else null,
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
    arena: Allocator,
    fn_decl: *Ast.FunctionDecl,
    module: *Ast.Module,
    lc: *LayoutComputer,
) Allocator.Error!?EntryPointInfo {
    var stage: []const u8 = "";
    var workgroup_size: [3]u32 = .{ 1, 1, 1 };
    var has_workgroup_size = false;
    var overrides: std.ArrayList([]const u8) = .empty;

    for (fn_decl.attributes.items) |attr| {
        if (std.mem.eql(u8, attr.name, "vertex")) {
            stage = "vertex";
        } else if (std.mem.eql(u8, attr.name, "fragment")) {
            stage = "fragment";
        } else if (std.mem.eql(u8, attr.name, "compute")) {
            stage = "compute";
        } else if (std.mem.eql(u8, attr.name, "workgroup_size")) {
            has_workgroup_size = true;
            try parseWorkgroupSize(arena, attr.args.items, module, lc, &workgroup_size, &overrides);
        }
    }

    if (stage.len == 0) return null;

    var inputs: std.ArrayList(InputOutputInfo) = .empty;
    var outputs: std.ArrayList(InputOutputInfo) = .empty;
    try collectEntryInputs(arena, fn_decl, lc, &inputs);
    try collectEntryOutputs(arena, fn_decl, lc, &outputs);

    return .{
        .name = getSymbolName(fn_decl.name, module.symbols.items),
        .name_offset = getSymbolLoc(fn_decl.name, module.symbols.items),
        .stage = stage,
        .workgroup_size = workgroup_size,
        .has_workgroup_size = has_workgroup_size,
        .overrides = overrides,
        .inputs = inputs,
        .outputs = outputs,
    };
}

fn collectEntryInputs(
    arena: Allocator,
    fn_decl: *Ast.FunctionDecl,
    lc: *LayoutComputer,
    out: *std.ArrayList(InputOutputInfo),
) Allocator.Error!void {
    for (fn_decl.parameters.items) |p| {
        const param_name = lc.getSymbolName(p.name);
        try collectIoFromAttributedSlot(arena, p.attributes.items, p.typ, param_name, lc, out);
    }
}

fn collectEntryOutputs(
    arena: Allocator,
    fn_decl: *Ast.FunctionDecl,
    lc: *LayoutComputer,
    out: *std.ArrayList(InputOutputInfo),
) Allocator.Error!void {
    const ret = fn_decl.return_type orelse return;
    try collectIoFromAttributedSlot(arena, fn_decl.return_attr.items, ret, "", lc, out);
}

/// Shared by parameters and return values. If the slot is a struct
/// (after alias resolve), flatten its members into one `InputOutputInfo`
/// each. Otherwise use the attributes attached to the slot itself.
fn collectIoFromAttributedSlot(
    arena: Allocator,
    attrs: []const Ast.Attribute,
    typ: Ast.Type,
    slot_name: []const u8,
    lc: *LayoutComputer,
    out: *std.ArrayList(InputOutputInfo),
) Allocator.Error!void {
    const resolved = lc.resolveAliasType(typ);
    if (resolved == .ident) {
        const ident = resolved.ident;
        if (ident.ref.isValid()) {
            const idx = ident.ref.index();
            if (idx < lc.module.symbols.items.len and
                lc.module.symbols.items[idx].kind == .@"struct")
            {
                const sym_idx = lc.resolveAliasRefToStruct(ident.ref) orelse {
                    try out.append(arena, makeIoEntry(slot_name, attrs, typ, lc));
                    return;
                };
                for (lc.module.declarations.items) |decl| switch (decl) {
                    .@"struct" => |sd| {
                        if (sd.name == sym_idx) {
                            for (sd.members.items) |m| {
                                const mname = lc.getSymbolName(m.name);
                                try out.append(arena, makeIoEntry(mname, m.attributes.items, m.typ, lc));
                            }
                            return;
                        }
                    },
                    else => {},
                };
                return;
            }
        }
    }
    try out.append(arena, makeIoEntry(slot_name, attrs, typ, lc));
}

fn makeIoEntry(
    name: []const u8,
    attrs: []const Ast.Attribute,
    typ: Ast.Type,
    lc: *LayoutComputer,
) InputOutputInfo {
    var info = InputOutputInfo{
        .name = name,
        .typ = lc.typeToStringMapped(typ, false),
        .type_info = lc.buildTypeInfo(typ),
    };
    for (attrs) |attr| {
        if (std.mem.eql(u8, attr.name, "location") and attr.args.items.len > 0) {
            const v = lc.evaluateConstExpr(attr.args.items[0]);
            if (v >= 0) info.location = @intCast(v);
        } else if (std.mem.eql(u8, attr.name, "builtin") and attr.args.items.len > 0) {
            // @builtin(name) — args[0] is an ident-keyword.
            if (attr.args.items[0] == .ident) {
                info.builtin = attr.args.items[0].ident.name;
            }
        } else if (std.mem.eql(u8, attr.name, "interpolate") and attr.args.items.len > 0) {
            var ii = InterpolateInfo{ .type = "" };
            if (attr.args.items[0] == .ident) ii.type = attr.args.items[0].ident.name;
            if (attr.args.items.len > 1 and attr.args.items[1] == .ident) {
                ii.sampling = attr.args.items[1].ident.name;
            }
            info.interpolate = ii;
        }
    }
    return info;
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

/// Parse `@workgroup_size(...)` arguments. For each axis (up to 3):
/// - `int_literal` → use the value;
/// - `ident` resolving to a `@const` symbol → evaluate via const-expr;
/// - `ident` resolving to an `@override` symbol → axis becomes `0` and
///   the override name is appended to the entry-point's `overrides`
///   list (so consumers know which pipeline constants drive the size);
/// - anything else falls back to `1`.
fn parseWorkgroupSize(
    arena: Allocator,
    args: []const Ast.Expr,
    module: *Ast.Module,
    lc: *LayoutComputer,
    out: *[3]u32,
    overrides: *std.ArrayList([]const u8),
) Allocator.Error!void {
    out.* = .{ 1, 1, 1 };
    for (args, 0..) |arg, i| {
        if (i >= 3) break;
        // Pipeline-override identifier?
        if (arg == .ident) {
            const id = arg.ident;
            if (id.ref.isValid()) {
                const idx = id.ref.index();
                if (idx < module.symbols.items.len) {
                    const sym = &module.symbols.items[idx];
                    if (sym.kind == .override) {
                        out[i] = 0;
                        try overrides.append(arena, sym.original_name);
                        continue;
                    }
                }
            }
        }
        const val = lc.evaluateConstExpr(arg);
        out[i] = if (val >= 0) @intCast(val) else 1;
    }
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
    fmt_buf: std.ArrayList(u8) = .empty,
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

    // -----------------------------------------------------------------
    // TypeInfo construction
    // -----------------------------------------------------------------

    /// Build a structured `TypeInfo` tree for `t`. The returned pointer is
    /// allocated from `self.arena` and lives as long as the reflect
    /// arena; safe to embed in `BindingInfo.type_info` / `FieldInfo.type_info`.
    /// Aliases are followed (so a binding declared as `var<uniform> u: MyAlias`
    /// gets the underlying form). Returns `null` on allocation failure.
    fn buildTypeInfo(self: *LayoutComputer, t: Ast.Type) ?*const TypeInfo {
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
                // Unknown ident — fall back to a nominal scalar entry so
                // callers always see a node. Layout values are 0; consumer
                // can detect via `.size == 0`.
                return self.alloc(TypeInfo{ .scalar = .{
                    .name = ident.name,
                    .size = 0,
                    .alignment = 0,
                } });
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
            .sampler, .texture, .ptr => {},
        }
        return patched;
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

/// True iff `x` is a power of two (1, 2, 4, …). Zero is not a power of two.
fn isPow2(x: u32) bool {
    return x > 0 and (x & (x - 1)) == 0;
}

/// Render an expression to its textual form, allocated from `arena`.
/// Used when `Expr.span` is empty (the legacy parser path doesn't stamp
/// expression spans). Handles literals, idents, unary/binary, paren,
/// call, member, and index — i.e. every form that can appear inside an
/// `@override` initializer or `@id(...)` value.
fn renderExprText(arena: Allocator, expr: Ast.Expr) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try renderExpr(&buf, arena, expr);
    return buf.items;
}

fn renderExpr(buf: *std.ArrayList(u8), arena: Allocator, expr: Ast.Expr) Allocator.Error!void {
    switch (expr) {
        .literal => |lit| try buf.appendSlice(arena, lit.value),
        .ident => |id| try buf.appendSlice(arena, id.name),
        .paren => |p| {
            try buf.append(arena, '(');
            try renderExpr(buf, arena, p.expr);
            try buf.append(arena, ')');
        },
        .unary => |u| {
            const op = unaryOpString(u.op);
            try buf.appendSlice(arena, op);
            try renderExpr(buf, arena, u.operand);
        },
        .binary => |b| {
            try renderExpr(buf, arena, b.left);
            try buf.append(arena, ' ');
            try buf.appendSlice(arena, b.op.string());
            try buf.append(arena, ' ');
            try renderExpr(buf, arena, b.right);
        },
        .call => |c| {
            if (c.func) |f| try renderExpr(buf, arena, f);
            try buf.append(arena, '(');
            for (c.args.items, 0..) |a, i| {
                if (i > 0) try buf.appendSlice(arena, ", ");
                try renderExpr(buf, arena, a);
            }
            try buf.append(arena, ')');
        },
        .member => |m| {
            try renderExpr(buf, arena, m.base);
            try buf.append(arena, '.');
            try buf.appendSlice(arena, m.member_name);
        },
        .index => |ix| {
            try renderExpr(buf, arena, ix.base);
            try buf.append(arena, '[');
            try renderExpr(buf, arena, ix.idx);
            try buf.append(arena, ']');
        },
    }
}

fn unaryOpString(op: Ast.UnaryOp) []const u8 {
    return switch (op) {
        .neg => "-",
        .not => "!",
        .bit_not => "~",
        .deref => "*",
        .addr => "&",
    };
}

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
        .sampler, .texture, .ptr => null,
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
// Call graph + resource attribution
// =========================================================================

/// Builtins that take a texture as `args[0]` and a sampler as `args[1]`.
/// Used to pair textures with their samplers across function bodies.
const sampler_pair_builtins = std.StaticStringMap(void).initComptime(.{
    .{ "textureSample", {} },
    .{ "textureSampleBias", {} },
    .{ "textureSampleCompare", {} },
    .{ "textureSampleCompareLevel", {} },
    .{ "textureSampleGrad", {} },
    .{ "textureSampleLevel", {} },
    .{ "textureGather", {} },
    .{ "textureGatherCompare", {} },
});

/// Walk every user-defined function body once. Populates
/// `result.functions` with one entry per `FunctionDecl`, recording:
///   • direct `var<>` references → `direct_resources`
///   • direct `@override` references → `direct_overrides`
///   • outgoing function calls → `calls`
/// Texture-sampling builtin calls additionally stamp the matching
/// `BindingInfo.relations` lists bidirectionally.
fn buildCallGraph(arena: Allocator, module: *Ast.Module, result: *ReflectResult) Allocator.Error!void {
    for (module.declarations.items) |decl| switch (decl) {
        .function => |fn_decl| {
            var info = FunctionInfo{
                .name = getSymbolName(fn_decl.name, module.symbols.items),
                .name_offset = getSymbolLoc(fn_decl.name, module.symbols.items),
                .decl_span = spanInfoFromAst(fn_decl.decl_span),
            };
            if (fn_decl.body) |body| {
                try walkBody(arena, module, body, &info, result);
            }
            try result.functions.append(arena, info);
        },
        else => {},
    };
}

fn walkBody(
    arena: Allocator,
    module: *Ast.Module,
    body: *Ast.CompoundStmt,
    info: *FunctionInfo,
    result: *ReflectResult,
) Allocator.Error!void {
    for (body.stmts.items) |stmt| {
        try walkStmt(arena, module, stmt, info, result);
    }
}

fn walkStmt(
    arena: Allocator,
    module: *Ast.Module,
    stmt: Ast.Stmt,
    info: *FunctionInfo,
    result: *ReflectResult,
) Allocator.Error!void {
    switch (stmt) {
        .compound => |s| try walkBody(arena, module, s, info, result),
        .@"return" => |s| if (s.value) |v| try walkExpr(arena, module, v, info, result),
        .@"if" => |s| {
            try walkExpr(arena, module, s.condition, info, result);
            try walkBody(arena, module, s.body, info, result);
            if (s.else_branch) |e| try walkStmt(arena, module, e, info, result);
        },
        .@"switch" => |s| {
            try walkExpr(arena, module, s.expr, info, result);
            for (s.cases.items) |c| {
                for (c.selectors.items) |sel| try walkExpr(arena, module, sel, info, result);
                try walkBody(arena, module, c.body, info, result);
            }
        },
        .@"for" => |s| {
            if (s.init_stmt) |i| try walkStmt(arena, module, i, info, result);
            if (s.condition) |c| try walkExpr(arena, module, c, info, result);
            if (s.update) |u| try walkStmt(arena, module, u, info, result);
            try walkBody(arena, module, s.body, info, result);
        },
        .@"while" => |s| {
            try walkExpr(arena, module, s.condition, info, result);
            try walkBody(arena, module, s.body, info, result);
        },
        .loop => |s| {
            try walkBody(arena, module, s.body, info, result);
            if (s.continuing) |c| try walkBody(arena, module, c, info, result);
        },
        .break_if => |s| try walkExpr(arena, module, s.condition, info, result),
        .assign => |s| {
            try walkExpr(arena, module, s.left, info, result);
            try walkExpr(arena, module, s.right, info, result);
        },
        .incr_decr => |s| try walkExpr(arena, module, s.expr, info, result),
        .call => |s| {
            // CallStmt wraps a CallExpr directly.
            try walkExpr(arena, module, .{ .call = s.call }, info, result);
        },
        .decl => |s| try walkDeclStmt(arena, module, s, info, result),
        .@"break", .@"continue", .discard => {},
    }
}

fn walkDeclStmt(
    arena: Allocator,
    module: *Ast.Module,
    s: *Ast.DeclStmt,
    info: *FunctionInfo,
    result: *ReflectResult,
) Allocator.Error!void {
    switch (s.decl) {
        .@"const" => |d| if (d.initializer) |e| try walkExpr(arena, module, e, info, result),
        .let => |d| if (d.initializer) |e| try walkExpr(arena, module, e, info, result),
        .@"var" => |d| if (d.initializer) |e| try walkExpr(arena, module, e, info, result),
        else => {},
    }
}

fn walkExpr(
    arena: Allocator,
    module: *Ast.Module,
    expr: Ast.Expr,
    info: *FunctionInfo,
    result: *ReflectResult,
) Allocator.Error!void {
    switch (expr) {
        .literal => {},
        .ident => |id| try recordIdent(arena, module, id, info),
        .paren => |p| try walkExpr(arena, module, p.expr, info, result),
        .unary => |u| try walkExpr(arena, module, u.operand, info, result),
        .binary => |b| {
            try walkExpr(arena, module, b.left, info, result);
            try walkExpr(arena, module, b.right, info, result);
        },
        .member => |m| try walkExpr(arena, module, m.base, info, result),
        .index => |ix| {
            try walkExpr(arena, module, ix.base, info, result);
            try walkExpr(arena, module, ix.idx, info, result);
        },
        .call => |c| {
            // Callee — record outgoing call if it resolves to a user fn.
            if (c.func) |f| switch (f) {
                .ident => |id| try recordCallee(arena, module, id, c, info, result),
                else => try walkExpr(arena, module, f, info, result),
            };
            for (c.args.items) |arg| try walkExpr(arena, module, arg, info, result);
        },
    }
}

fn recordIdent(
    arena: Allocator,
    module: *Ast.Module,
    id: *Ast.IdentExpr,
    info: *FunctionInfo,
) Allocator.Error!void {
    if (!id.ref.isValid()) return;
    const idx = id.ref.index();
    if (idx >= module.symbols.items.len) return;
    const sym = &module.symbols.items[idx];
    switch (sym.kind) {
        .@"var" => {
            // Only module-scope `@group/@binding var<>` declarations
            // are resources. Function-local `var` shadows the same
            // `kind` but never appears as a resource — the parser
            // flags binding-eligible symbols via `is_external_binding`.
            if (sym.flags.is_external_binding) {
                try appendUnique(arena, &info.direct_resources, sym.original_name);
            }
        },
        .override => try appendUnique(arena, &info.direct_overrides, sym.original_name),
        else => {},
    }
}

fn recordCallee(
    arena: Allocator,
    module: *Ast.Module,
    id: *Ast.IdentExpr,
    call: *Ast.CallExpr,
    info: *FunctionInfo,
    result: *ReflectResult,
) Allocator.Error!void {
    if (!id.ref.isValid()) {
        // Texture sampling builtins resolve via name when ref is unset.
        try maybeRecordTextureSamplerPair(arena, module, id.name, call, result);
        return;
    }
    const idx = id.ref.index();
    if (idx >= module.symbols.items.len) return;
    const sym = &module.symbols.items[idx];
    switch (sym.kind) {
        .function => try appendUnique(arena, &info.calls, sym.original_name),
        .builtin => try maybeRecordTextureSamplerPair(arena, module, id.name, call, result),
        else => {},
    }
}

/// When `name` is a texture-sampling builtin and `args[0..2]` resolve
/// to bindings, record the (texture, sampler) pair on both bindings'
/// `relations` lists.
fn maybeRecordTextureSamplerPair(
    arena: Allocator,
    module: *Ast.Module,
    name: []const u8,
    call: *Ast.CallExpr,
    result: *ReflectResult,
) Allocator.Error!void {
    if (!sampler_pair_builtins.has(name)) return;
    if (call.args.items.len < 2) return;
    const tex_idx = identArgSymIdx(call.args.items[0]) orelse return;
    const samp_idx = identArgSymIdx(call.args.items[1]) orelse return;
    const tex_name = symbolName(module, tex_idx) orelse return;
    const samp_name = symbolName(module, samp_idx) orelse return;

    var tex_binding: ?*BindingInfo = null;
    var samp_binding: ?*BindingInfo = null;
    for (result.bindings.items) |*b| {
        if (std.mem.eql(u8, b.name, tex_name)) tex_binding = b;
        if (std.mem.eql(u8, b.name, samp_name)) samp_binding = b;
    }
    if (tex_binding) |tb| try appendUnique(arena, &tb.relations, samp_name);
    if (samp_binding) |sb| try appendUnique(arena, &sb.relations, tex_name);
}

fn identArgSymIdx(arg: Ast.Expr) ?u32 {
    if (arg != .ident) return null;
    const id = arg.ident;
    if (!id.ref.isValid()) return null;
    return id.ref.index();
}

fn symbolName(module: *Ast.Module, idx: u32) ?[]const u8 {
    if (idx >= module.symbols.items.len) return null;
    return module.symbols.items[idx].original_name;
}

fn appendUnique(arena: Allocator, list: *std.ArrayList([]const u8), name: []const u8) Allocator.Error!void {
    if (name.len == 0) return;
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    try list.append(arena, name);
}

/// BFS from each entry point through `FunctionInfo.calls`. Marks every
/// reachable function `in_use = true`, unions `direct_resources` /
/// `direct_overrides` into the entry point's transitive lists.
fn propagateEntryReachability(arena: Allocator, result: *ReflectResult) Allocator.Error!void {
    if (result.functions.items.len == 0) return;

    // Index functions by name for O(1) call edge lookup.
    var by_name: std.StringHashMapUnmanaged(u32) = .empty;
    defer by_name.deinit(arena);
    for (result.functions.items, 0..) |*f, i| {
        try by_name.put(arena, f.name, @intCast(i));
    }

    for (result.entry_points.items) |*ep| {
        const start_idx = by_name.get(ep.name) orelse continue;
        var visited = try arena.alloc(bool, result.functions.items.len);
        defer arena.free(visited);
        @memset(visited, false);

        var queue: std.ArrayList(u32) = .empty;
        defer queue.deinit(arena);
        try queue.append(arena, start_idx);
        visited[start_idx] = true;

        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const fi = queue.items[head];
            const f = &result.functions.items[fi];
            f.in_use = true;
            for (f.direct_resources.items) |r| try appendUnique(arena, &ep.resources, r);
            for (f.direct_overrides.items) |o| try appendUnique(arena, &ep.overrides, o);
            for (f.calls.items) |callee| {
                if (by_name.get(callee)) |ci| {
                    if (!visited[ci]) {
                        visited[ci] = true;
                        try queue.append(arena, ci);
                    }
                }
            }
        }
    }
}

// =========================================================================
// JSON serialization helpers
// =========================================================================

fn appendStr(buf: *std.ArrayList(u8), arena: Allocator, s: []const u8) Allocator.Error!void {
    try buf.appendSlice(arena, s);
}

fn appendInt(buf: *std.ArrayList(u8), arena: Allocator, value: anytype) Allocator.Error!void {
    var scratch: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&scratch, "{d}", .{value}) catch return;
    try appendStr(buf, arena, s);
}

fn appendJsonStr(buf: *std.ArrayList(u8), arena: Allocator, s: []const u8) Allocator.Error!void {
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
    buf: *std.ArrayList(u8),
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

fn writeBindingJson(buf: *std.ArrayList(u8), arena: Allocator, b: *const BindingInfo) Allocator.Error!void {
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
    if (b.type_info) |ti| {
        try appendStr(buf, arena, ",\"typeInfo\":");
        try writeTypeInfoJson(buf, arena, ti);
    }
    if (b.relations.items.len > 0) {
        try appendStr(buf, arena, ",\"relations\":[");
        for (b.relations.items, 0..) |r, i| {
            if (i > 0) try appendStr(buf, arena, ",");
            try appendJsonStr(buf, arena, r);
        }
        try appendStr(buf, arena, "]");
    }
    try appendStr(buf, arena, "}");
}

fn writeFunctionJson(buf: *std.ArrayList(u8), arena: Allocator, f: *const FunctionInfo) Allocator.Error!void {
    try appendStr(buf, arena, "{\"name\":");
    try appendJsonStr(buf, arena, f.name);
    if (f.name_mapped.len > 0) {
        try appendStr(buf, arena, ",\"nameMapped\":");
        try appendJsonStr(buf, arena, f.name_mapped);
    }
    try appendStr(buf, arena, ",\"nameOffset\":");
    try appendInt(buf, arena, f.name_offset);
    if (f.stable_id.len > 0) {
        try appendStr(buf, arena, ",\"stableId\":");
        try appendJsonStr(buf, arena, f.stable_id);
    }
    try writeSpanField(buf, arena, "declSpan", f.decl_span);
    try appendStr(buf, arena, ",\"inUse\":");
    try appendStr(buf, arena, if (f.in_use) "true" else "false");
    try appendStr(buf, arena, ",\"calls\":[");
    for (f.calls.items, 0..) |c, i| {
        if (i > 0) try appendStr(buf, arena, ",");
        try appendJsonStr(buf, arena, c);
    }
    try appendStr(buf, arena, "],\"directResources\":[");
    for (f.direct_resources.items, 0..) |r, i| {
        if (i > 0) try appendStr(buf, arena, ",");
        try appendJsonStr(buf, arena, r);
    }
    try appendStr(buf, arena, "],\"directOverrides\":[");
    for (f.direct_overrides.items, 0..) |o, i| {
        if (i > 0) try appendStr(buf, arena, ",");
        try appendJsonStr(buf, arena, o);
    }
    try appendStr(buf, arena, "]}");
}

fn writeStructLayoutJson(buf: *std.ArrayList(u8), arena: Allocator, layout: *const StructLayout) Allocator.Error!void {
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

fn writeFieldInfoJson(buf: *std.ArrayList(u8), arena: Allocator, f: *const FieldInfo) Allocator.Error!void {
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
    if (f.type_info) |ti| {
        try appendStr(buf, arena, ",\"typeInfo\":");
        try writeTypeInfoJson(buf, arena, ti);
    }
    try appendStr(buf, arena, "}");
}

fn writeTypeInfoJson(buf: *std.ArrayList(u8), arena: Allocator, t: *const TypeInfo) Allocator.Error!void {
    switch (t.*) {
        .scalar => |s| {
            try appendStr(buf, arena, "{\"kind\":\"scalar\",\"name\":");
            try appendJsonStr(buf, arena, s.name);
            try appendStr(buf, arena, ",\"size\":");
            try appendInt(buf, arena, s.size);
            try appendStr(buf, arena, ",\"alignment\":");
            try appendInt(buf, arena, s.alignment);
            try appendStr(buf, arena, "}");
        },
        .vec => |v| {
            try appendStr(buf, arena, "{\"kind\":\"vec\",\"width\":");
            try appendInt(buf, arena, v.width);
            try appendStr(buf, arena, ",\"format\":");
            try writeTypeInfoJson(buf, arena, v.format);
            try appendStr(buf, arena, ",\"size\":");
            try appendInt(buf, arena, v.size);
            try appendStr(buf, arena, ",\"alignment\":");
            try appendInt(buf, arena, v.alignment);
            try appendStr(buf, arena, "}");
        },
        .mat => |m| {
            try appendStr(buf, arena, "{\"kind\":\"mat\",\"cols\":");
            try appendInt(buf, arena, m.cols);
            try appendStr(buf, arena, ",\"rows\":");
            try appendInt(buf, arena, m.rows);
            try appendStr(buf, arena, ",\"format\":");
            try writeTypeInfoJson(buf, arena, m.format);
            try appendStr(buf, arena, ",\"size\":");
            try appendInt(buf, arena, m.size);
            try appendStr(buf, arena, ",\"alignment\":");
            try appendInt(buf, arena, m.alignment);
            try appendStr(buf, arena, ",\"stride\":");
            try appendInt(buf, arena, m.stride);
            try appendStr(buf, arena, "}");
        },
        .array => |a| {
            try appendStr(buf, arena, "{\"kind\":\"array\",\"format\":");
            try writeTypeInfoJson(buf, arena, a.format);
            try appendStr(buf, arena, ",\"count\":");
            if (a.count) |c| try appendInt(buf, arena, c) else try appendStr(buf, arena, "null");
            try appendStr(buf, arena, ",\"size\":");
            if (a.size) |s| try appendInt(buf, arena, s) else try appendStr(buf, arena, "null");
            try appendStr(buf, arena, ",\"stride\":");
            try appendInt(buf, arena, a.stride);
            try appendStr(buf, arena, ",\"alignment\":");
            try appendInt(buf, arena, a.alignment);
            try appendStr(buf, arena, "}");
        },
        .@"struct" => |s| {
            try appendStr(buf, arena, "{\"kind\":\"struct\",\"name\":");
            try appendJsonStr(buf, arena, s.name);
            try appendStr(buf, arena, ",\"size\":");
            try appendInt(buf, arena, s.size);
            try appendStr(buf, arena, ",\"alignment\":");
            try appendInt(buf, arena, s.alignment);
            try appendStr(buf, arena, "}");
        },
        .atomic => |a| {
            try appendStr(buf, arena, "{\"kind\":\"atomic\",\"format\":");
            try writeTypeInfoJson(buf, arena, a.format);
            try appendStr(buf, arena, ",\"size\":");
            try appendInt(buf, arena, a.size);
            try appendStr(buf, arena, ",\"alignment\":");
            try appendInt(buf, arena, a.alignment);
            try appendStr(buf, arena, "}");
        },
        .sampler => |sm| {
            try appendStr(buf, arena, "{\"kind\":\"sampler\",\"comparison\":");
            try appendStr(buf, arena, if (sm.comparison) "true" else "false");
            try appendStr(buf, arena, "}");
        },
        .texture => |tx| {
            try appendStr(buf, arena, "{\"kind\":\"texture\",\"dim\":");
            try appendJsonStr(buf, arena, textureDimString(tx.dim));
            try appendStr(buf, arena, ",\"texKind\":");
            try appendJsonStr(buf, arena, textureKindString(tx.kind));
            if (tx.format.len > 0) {
                try appendStr(buf, arena, ",\"format\":");
                try appendJsonStr(buf, arena, tx.format);
            }
            if (tx.access != .none) {
                try appendStr(buf, arena, ",\"access\":");
                try appendJsonStr(buf, arena, tx.access.string());
            }
            if (tx.sample_type.len > 0) {
                try appendStr(buf, arena, ",\"sampleType\":");
                try appendJsonStr(buf, arena, tx.sample_type);
            }
            try appendStr(buf, arena, "}");
        },
        .ptr => |p| {
            try appendStr(buf, arena, "{\"kind\":\"ptr\",\"addressSpace\":");
            try appendJsonStr(buf, arena, p.address_space.string());
            try appendStr(buf, arena, ",\"format\":");
            try writeTypeInfoJson(buf, arena, p.format);
            if (p.access != .none) {
                try appendStr(buf, arena, ",\"access\":");
                try appendJsonStr(buf, arena, p.access.string());
            }
            try appendStr(buf, arena, "}");
        },
    }
}

fn textureDimString(dim: Ast.TextureDimension) []const u8 {
    return switch (dim) {
        .@"1d" => "1d",
        .@"2d" => "2d",
        .@"2d_array" => "2d_array",
        .@"3d" => "3d",
        .cube => "cube",
        .cube_array => "cube_array",
    };
}

fn textureKindString(kind: Ast.TextureKind) []const u8 {
    return switch (kind) {
        .sampled => "sampled",
        .multisampled => "multisampled",
        .storage => "storage",
        .depth => "depth",
        .depth_multisampled => "depth_multisampled",
        .external => "external",
    };
}

fn writeArrayInfoJson(buf: *std.ArrayList(u8), arena: Allocator, arr: *const ArrayInfo) Allocator.Error!void {
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

fn writeEntryPointJson(buf: *std.ArrayList(u8), arena: Allocator, ep: *const EntryPointInfo) Allocator.Error!void {
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
    if (ep.overrides.items.len > 0) {
        try appendStr(buf, arena, ",\"overrides\":[");
        for (ep.overrides.items, 0..) |name, i| {
            if (i > 0) try appendStr(buf, arena, ",");
            try appendJsonStr(buf, arena, name);
        }
        try appendStr(buf, arena, "]");
    }
    try appendStr(buf, arena, ",\"inputs\":[");
    for (ep.inputs.items, 0..) |*io, i| {
        if (i > 0) try appendStr(buf, arena, ",");
        try writeIoJson(buf, arena, io);
    }
    try appendStr(buf, arena, "],\"outputs\":[");
    for (ep.outputs.items, 0..) |*io, i| {
        if (i > 0) try appendStr(buf, arena, ",");
        try writeIoJson(buf, arena, io);
    }
    try appendStr(buf, arena, "],\"resources\":[");
    for (ep.resources.items, 0..) |r, i| {
        if (i > 0) try appendStr(buf, arena, ",");
        try appendJsonStr(buf, arena, r);
    }
    try appendStr(buf, arena, "]");
    try appendStr(buf, arena, "}");
}

fn writeIoJson(buf: *std.ArrayList(u8), arena: Allocator, io: *const InputOutputInfo) Allocator.Error!void {
    try appendStr(buf, arena, "{\"name\":");
    try appendJsonStr(buf, arena, io.name);
    if (io.location) |l| {
        try appendStr(buf, arena, ",\"location\":");
        try appendInt(buf, arena, l);
    }
    if (io.builtin.len > 0) {
        try appendStr(buf, arena, ",\"builtin\":");
        try appendJsonStr(buf, arena, io.builtin);
    }
    if (io.interpolate) |ii| {
        try appendStr(buf, arena, ",\"interpolate\":{\"type\":");
        try appendJsonStr(buf, arena, ii.type);
        if (ii.sampling.len > 0) {
            try appendStr(buf, arena, ",\"sampling\":");
            try appendJsonStr(buf, arena, ii.sampling);
        }
        try appendStr(buf, arena, "}");
    }
    if (io.typ.len > 0) {
        try appendStr(buf, arena, ",\"type\":");
        try appendJsonStr(buf, arena, io.typ);
    }
    if (io.type_info) |ti| {
        try appendStr(buf, arena, ",\"typeInfo\":");
        try writeTypeInfoJson(buf, arena, ti);
    }
    try appendStr(buf, arena, "}");
}

fn writeOverrideJson(buf: *std.ArrayList(u8), arena: Allocator, o: *const OverrideInfo) Allocator.Error!void {
    try appendStr(buf, arena, "{\"name\":");
    try appendJsonStr(buf, arena, o.name);
    try appendStr(buf, arena, ",\"nameMapped\":");
    try appendJsonStr(buf, arena, o.name_mapped);
    try appendStr(buf, arena, ",\"nameOffset\":");
    try appendInt(buf, arena, o.name_offset);
    if (o.stable_id.len > 0) {
        try appendStr(buf, arena, ",\"stableId\":");
        try appendJsonStr(buf, arena, o.stable_id);
    }
    try writeSpanField(buf, arena, "declSpan", o.decl_span);
    if (o.id) |id| {
        try appendStr(buf, arena, ",\"id\":");
        try appendInt(buf, arena, id);
    } else {
        try appendStr(buf, arena, ",\"id\":null");
    }
    if (o.typ.len > 0) {
        try appendStr(buf, arena, ",\"type\":");
        try appendJsonStr(buf, arena, o.typ);
    }
    if (o.type_info) |ti| {
        try appendStr(buf, arena, ",\"typeInfo\":");
        try writeTypeInfoJson(buf, arena, ti);
    }
    if (o.default.len > 0) {
        try appendStr(buf, arena, ",\"default\":");
        try appendJsonStr(buf, arena, o.default);
    }
    try appendStr(buf, arena, "}");
}

fn writeAliasJson(buf: *std.ArrayList(u8), arena: Allocator, a: *const AliasInfo) Allocator.Error!void {
    try appendStr(buf, arena, "{\"name\":");
    try appendJsonStr(buf, arena, a.name);
    try appendStr(buf, arena, ",\"nameMapped\":");
    try appendJsonStr(buf, arena, a.name_mapped);
    try appendStr(buf, arena, ",\"nameOffset\":");
    try appendInt(buf, arena, a.name_offset);
    if (a.stable_id.len > 0) {
        try appendStr(buf, arena, ",\"stableId\":");
        try appendJsonStr(buf, arena, a.stable_id);
    }
    try writeSpanField(buf, arena, "declSpan", a.decl_span);
    try appendStr(buf, arena, ",\"type\":");
    try appendJsonStr(buf, arena, a.typ);
    try appendStr(buf, arena, ",\"typeMapped\":");
    try appendJsonStr(buf, arena, a.type_mapped);
    if (a.type_info) |ti| {
        try appendStr(buf, arena, ",\"typeInfo\":");
        try writeTypeInfoJson(buf, arena, ti);
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

// (parseWorkgroupSize now takes a LayoutComputer + override list — its
// behaviour is exercised end-to-end via the `tests/reflect_test.zig`
// override tests rather than a unit fixture here.)

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
