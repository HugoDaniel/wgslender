//! Completion: produce candidate items for `@`, `.`, and global trigger
//! contexts. Owns the static lists of WGSL builtin type names and
//! attribute names.

const std = @import("std");
const wgslender = @import("wgslender");

const Handler = @import("../Handler.zig");
const Position = Handler.Position;
const Builtins = wgslender.Builtins;
const Lexer = wgslender.Lexer;

pub const CompletionItem = struct {
    label: []const u8,
    kind: CompletionKind,
    detail: []const u8 = "",
};

pub const CompletionKind = enum(u8) {
    variable,
    function,
    struct_type,
    field,
    keyword,
    builtin,
    type_name,
    attribute,
};

const wgsl_type_names = [_][]const u8{
    "bool",               "i32",                      "u32",                           "f32",                     "f16",
    "vec2",               "vec3",                     "vec4",                          "vec2i",                   "vec3i",
    "vec4i",              "vec2u",                    "vec3u",                         "vec4u",                   "vec2f",
    "vec3f",              "vec4f",                    "vec2h",                         "vec3h",                   "vec4h",
    "mat2x2",             "mat2x3",                   "mat2x4",                        "mat3x2",                  "mat3x3",
    "mat3x4",             "mat4x2",                   "mat4x3",                        "mat4x4",                  "mat2x2f",
    "mat2x3f",            "mat2x4f",                  "mat3x2f",                       "mat3x3f",                 "mat3x4f",
    "mat4x2f",            "mat4x3f",                  "mat4x4f",                       "mat2x2h",                 "mat2x3h",
    "mat2x4h",            "mat3x2h",                  "mat3x3h",                       "mat3x4h",                 "mat4x2h",
    "mat4x3h",            "mat4x4h",                  "array",                         "atomic",                  "ptr",
    "sampler",            "sampler_comparison",       "texture_1d",                    "texture_2d",              "texture_2d_array",
    "texture_3d",         "texture_cube",             "texture_cube_array",            "texture_multisampled_2d", "texture_storage_1d",
    "texture_storage_2d", "texture_storage_2d_array", "texture_storage_3d",            "texture_depth_2d",        "texture_depth_2d_array",
    "texture_depth_cube", "texture_depth_cube_array", "texture_depth_multisampled_2d",
};

const wgsl_attributes = [_][]const u8{
    "align",    "binding",     "builtin",   "compute",
    "const",    "diagnostic",  "fragment",  "group",
    "id",       "interpolate", "invariant", "location",
    "must_use", "size",        "vertex",    "workgroup_size",
};

pub fn computeCompletion(handler: *Handler, uri: []const u8, position: Position) ![]CompletionItem {
    const doc = handler.documents.getPtr(uri) orelse return &.{};
    const source = doc.source;
    const offset: u32 = @intCast(Handler.lspPositionToOffset(source, position) orelse return &.{});

    // Check trigger context
    if (offset > 0 and source[offset - 1] == '@') {
        return attributeCompletion(handler);
    }

    if (offset > 0 and source[offset - 1] == '.') {
        return memberCompletion(handler, uri, source, offset);
    }

    return generalCompletion(handler, uri);
}

fn attributeCompletion(handler: *Handler) ![]CompletionItem {
    const items = try handler.gpa.alloc(CompletionItem, wgsl_attributes.len);
    for (wgsl_attributes, 0..) |attr, i| {
        items[i] = .{ .label = attr, .kind = .attribute };
    }
    return items;
}

fn memberCompletion(handler: *Handler, uri: []const u8, source: []const u8, dot_offset: u32) ![]CompletionItem {
    // Find the identifier before the dot
    var start = dot_offset - 1;
    if (start > 0 and source[start] == '.') start -= 1; // skip the dot
    while (start > 0 and (std.ascii.isAlphanumeric(source[start - 1]) or source[start - 1] == '_')) start -= 1;
    const base_name = source[start .. dot_offset - 1];
    if (base_name.len == 0) return &.{};

    // Try to resolve the base type via analysis
    const analysis = handler.analyzeDocument(uri) catch return &.{};
    const module = analysis.module orelse return &.{};

    // Find the symbol for base_name and its type
    var base_type: ?wgslender.Types.Type = null;
    for (module.symbols.items, 0..) |sym, idx| {
        if (std.mem.eql(u8, sym.original_name, base_name)) {
            base_type = analysis.symbol_types.get(@intCast(idx));
            break;
        }
    }

    if (base_type) |bt| {
        switch (bt) {
            .@"struct" => |st| {
                const items = try handler.gpa.alloc(CompletionItem, st.fields.len);
                for (st.fields, 0..) |field, i| {
                    items[i] = .{ .label = field.name, .kind = .field, .detail = field.typ.string() };
                }
                return items;
            },
            .vector => {
                // Vector swizzle components
                const swizzles = [_][]const u8{ "x", "y", "z", "w", "r", "g", "b", "a" };
                const items = try handler.gpa.alloc(CompletionItem, swizzles.len);
                for (swizzles, 0..) |s, i| {
                    items[i] = .{ .label = s, .kind = .field };
                }
                return items;
            },
            else => {},
        }
    }

    return &.{};
}

fn generalCompletion(handler: *Handler, uri: []const u8) ![]CompletionItem {
    var items: std.ArrayList(CompletionItem) = .empty;
    defer items.deinit(handler.gpa);

    // Module-level symbols from analysis
    if (handler.analyzeDocument(uri)) |analysis| {
        if (analysis.module) |module| {
            for (module.symbols.items, 0..) |sym, idx| {
                if (sym.original_name.len == 0) continue;
                const kind: CompletionKind = switch (sym.kind) {
                    .function => .function,
                    .@"struct" => .struct_type,
                    .parameter, .let, .@"var" => .variable,
                    .@"const", .override => .variable,
                    else => continue,
                };
                const detail = if (analysis.symbol_types.get(@intCast(idx))) |t| t.string() else "";
                try items.append(handler.gpa, .{ .label = sym.original_name, .kind = kind, .detail = detail });
            }
        }
    } else |_| {}

    // Builtin functions
    for (Builtins.names()) |name| {
        try items.append(handler.gpa, .{ .label = name, .kind = .builtin });
    }

    // Keywords
    for (Lexer.keywords_map.keys()) |kw| {
        try items.append(handler.gpa, .{ .label = kw, .kind = .keyword });
    }

    // Built-in type names
    for (&wgsl_type_names) |tn| {
        try items.append(handler.gpa, .{ .label = tn, .kind = .type_name });
    }

    return try handler.gpa.dupe(CompletionItem, items.items);
}
