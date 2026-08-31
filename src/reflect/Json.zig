//! JSON serialization for reflect results.
//!
//! This is the `JSON ↔ everything` seam of `Reflect.zig`: every function here
//! reads only the already-materialized public data structs (`ReflectResult`,
//! `BindingInfo`, `TypeInfo`, …) exported from `Reflect.zig`. It never calls
//! the layout computer, the const-expr interpreter, or the call-graph builder.
//!
//! `ReflectResult.toJson*` in `Reflect.zig` are thin delegators onto
//! `writeResult` / `prettyPrint` here; the module stays the façade.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("../Ast.zig");
const Reflect = @import("../Reflect.zig");

const ReflectResult = Reflect.ReflectResult;
const JsonVersion = Reflect.JsonVersion;
const SpanInfo = Reflect.SpanInfo;
const BindingInfo = Reflect.BindingInfo;
const ArrayInfo = Reflect.ArrayInfo;
const StructLayout = Reflect.StructLayout;
const FieldInfo = Reflect.FieldInfo;
const TypeInfo = Reflect.TypeInfo;
const EntryPointInfo = Reflect.EntryPointInfo;
const InputOutputInfo = Reflect.InputOutputInfo;
const FunctionInfo = Reflect.FunctionInfo;
const ParamInfo = Reflect.ParamInfo;
const AliasInfo = Reflect.AliasInfo;
const OverrideInfo = Reflect.OverrideInfo;

// =========================================================================
// Result serialization (drives JsonVersion.v1 / v2)
// =========================================================================

/// Serialize a reflect result to compact JSON at the requested schema version.
/// Backs `ReflectResult.toJson` / `toJsonVersion`.
pub fn writeResult(
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
        try writeFunctionJson(buf, arena, f, version);
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

// =========================================================================
// Pretty-printer
// =========================================================================

/// Re-indent compact JSON with a 2-space indent. Backs
/// `ReflectResult.toJsonPretty` / `toJsonPrettyVersion`.
pub fn prettyPrint(buf: *std.ArrayList(u8), arena: Allocator, json: []const u8) Allocator.Error!void {
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

/// `params` / `returnType` are v2-only. `functions[]` itself is written in
/// both versions, and v1 is the frozen wgsl_reflect-parity shape, so the
/// new keys are gated rather than the array.
fn writeFunctionJson(
    buf: *std.ArrayList(u8),
    arena: Allocator,
    f: *const FunctionInfo,
    version: JsonVersion,
) Allocator.Error!void {
    try appendStr(buf, arena, "{\"name\":");
    try appendJsonStr(buf, arena, f.name);
    // Omitted when it matches `name`, which is the contract the npm types
    // state: "absent when no renamer was applied".
    if (f.name_mapped.len > 0 and !std.mem.eql(u8, f.name_mapped, f.name)) {
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
    try appendStr(buf, arena, "]");
    if (version == .v2) {
        try appendStr(buf, arena, ",\"params\":[");
        for (f.params.items, 0..) |*p, i| {
            if (i > 0) try appendStr(buf, arena, ",");
            try writeParamJson(buf, arena, p);
        }
        // `null`, not `""`, for a function with no `-> T` clause —
        // matching `"id": null` and `"workgroupSize": null` above.
        try appendStr(buf, arena, "],\"returnType\":");
        if (f.return_type.len > 0) {
            try appendJsonStr(buf, arena, f.return_type);
            if (!std.mem.eql(u8, f.return_type_mapped, f.return_type)) {
                try appendStr(buf, arena, ",\"returnTypeMapped\":");
                try appendJsonStr(buf, arena, f.return_type_mapped);
            }
            if (f.return_type_info) |ti| {
                try appendStr(buf, arena, ",\"returnTypeInfo\":");
                try writeTypeInfoJson(buf, arena, ti);
            }
        } else {
            try appendStr(buf, arena, "null");
        }
    }
    try appendStr(buf, arena, "}");
}

fn writeParamJson(buf: *std.ArrayList(u8), arena: Allocator, p: *const ParamInfo) Allocator.Error!void {
    try appendStr(buf, arena, "{\"name\":");
    try appendJsonStr(buf, arena, p.name);
    try appendStr(buf, arena, ",\"type\":");
    try appendJsonStr(buf, arena, p.typ);
    // Mapped renderings are omitted when they match, the rule
    // `writeFunctionJson` already applies to `nameMapped`.
    if (!std.mem.eql(u8, p.name_mapped, p.name)) {
        try appendStr(buf, arena, ",\"nameMapped\":");
        try appendJsonStr(buf, arena, p.name_mapped);
    }
    if (!std.mem.eql(u8, p.type_mapped, p.typ)) {
        try appendStr(buf, arena, ",\"typeMapped\":");
        try appendJsonStr(buf, arena, p.type_mapped);
    }
    if (p.type_info) |ti| {
        try appendStr(buf, arena, ",\"typeInfo\":");
        try writeTypeInfoJson(buf, arena, ti);
    }
    try appendStr(buf, arena, "}");
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
        // No `size` / `alignment`: nothing was measured, and writing 0
        // for them is what made this indistinguishable from a scalar.
        .unresolved => |u| {
            try appendStr(buf, arena, "{\"kind\":\"unresolved\",\"name\":");
            try appendJsonStr(buf, arena, u.name);
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
