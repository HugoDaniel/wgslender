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
const ConstEval = @import("ConstEval.zig");

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
        try Json.writeResult(self, buf, arena, version);
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
        try Json.prettyPrint(buf, arena, compact.items);
    }
};

/// JSON serialization (`toJson*`) lives in this sub-namespace; the
/// `ReflectResult.toJson*` methods above are thin delegators onto it.
pub const Json = @import("reflect/Json.zig");

/// Call-graph + resource-attribution passes (`buildCallGraph`,
/// `propagateEntryReachability`) live in this sub-namespace; `reflect`
/// drives them after binding/entry-point extraction.
pub const CallGraph = @import("reflect/CallGraph.zig");

/// Memory-layout computation — `LayoutComputer` plus the WGSL §6.2.10
/// size/alignment rules, struct/array/TypeInfo builders, and type-to-string —
/// lives in this sub-namespace; the driver + extraction free-fns below run a
/// `LayoutComputer` through it to fill the public structs above.
pub const Layout = @import("reflect/Layout.zig");

/// The driver and extraction free-fns spell `LayoutComputer` unqualified;
/// alias the engine so those references resolve without churn.
const LayoutComputer = Layout.LayoutComputer;

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
    try CallGraph.buildCallGraph(arena, module, &result);
    // Compute transitive resources / overrides per entry point and
    // mark `in_use` on every reachable function.
    try CallGraph.propagateEntryReachability(arena, &result);

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

/// `pub` for the `reflect/CallGraph.zig` seam, which stamps `decl_span` on
/// each `FunctionInfo` it builds.
pub fn spanInfoFromAst(span: Ast.Span) SpanInfo {
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

/// `pub` for the `reflect/CallGraph.zig` seam, which names each function it
/// records. (Also used pervasively within this file.)
pub fn getSymbolName(ref: Ast.SymbolIndex, symbols: []const Ast.Symbol) []const u8 {
    if (!ref.isValid()) return "";
    const idx = ref.index();
    if (idx >= symbols.len) return "";
    return symbols[idx].original_name;
}

/// `pub` for the `reflect/CallGraph.zig` seam (see `getSymbolName`).
pub fn getSymbolLoc(ref: Ast.SymbolIndex, symbols: []const Ast.Symbol) u32 {
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

// =========================================================================
// Tests
// =========================================================================

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
