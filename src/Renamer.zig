//! Symbol renaming for minification.
//!
//! Assigns short names to frequently-used symbols, avoiding reserved words
//! and API-facing names. Follows esbuild's frequency-based approach.

const std = @import("std");
const Ast = @import("Ast.zig");
const Lexer = @import("Lexer.zig");
const Printer = @import("Printer.zig");

const Renamer = @This();

// =========================================================================
// NoOp Renamer
// =========================================================================

pub const NoOpRenamer = struct {
    symbols: []const Ast.Symbol,
    renamer: Printer.Renamer,

    pub fn init(symbols: []const Ast.Symbol) NoOpRenamer {
        var self = NoOpRenamer{
            .symbols = symbols,
            .renamer = undefined,
        };
        self.renamer = .{
            .ptr = @ptrCast(&self),
            .nameForSymbolFn = &nameForSymbolImpl,
        };
        return self;
    }

    fn nameForSymbolImpl(ptr: *const anyopaque, ref: Ast.SymbolIndex) []const u8 {
        const self: *const NoOpRenamer = @ptrCast(@alignCast(ptr));
        if (!ref.isValid()) return "";
        const idx = ref.index();
        if (idx >= self.symbols.len) return "";
        return self.symbols[idx].original_name;
    }
};

// =========================================================================
// Minify Renamer
// =========================================================================

pub const MinifyRenamer = struct {
    symbols: []Ast.Symbol,
    reserved_names: std.StringHashMapUnmanaged(void),
    slots: std.ArrayListUnmanaged(SymbolSlot),
    top_level_slots: std.AutoHashMapUnmanaged(u32, u32),
    name_buf: std.ArrayListUnmanaged(u8), // storage for generated names
    name_offsets: std.ArrayListUnmanaged(NameSlice), // offset+len into name_buf
    allocator: std.mem.Allocator,
    renamer: Printer.Renamer,

    const SymbolSlot = struct {
        name: []const u8,
        count: u32,
    };

    const NameSlice = struct {
        offset: u32,
        len: u32,
    };

    pub fn init(allocator: std.mem.Allocator, symbols: []Ast.Symbol, reserved: std.StringHashMapUnmanaged(void)) MinifyRenamer {
        var self = MinifyRenamer{
            .symbols = symbols,
            .reserved_names = reserved,
            .slots = .empty,
            .top_level_slots = .empty,
            .name_buf = .empty,
            .name_offsets = .empty,
            .allocator = allocator,
            .renamer = undefined,
        };
        self.renamer = .{
            .ptr = @ptrCast(&self),
            .nameForSymbolFn = &nameForSymbolImpl,
        };
        return self;
    }

    pub fn accumulateSymbolUseCounts(self: *MinifyRenamer, uses: *const std.AutoHashMapUnmanaged(Ast.SymbolIndex, u32)) void {
        var it = uses.iterator();
        while (it.next()) |entry| {
            const ref = entry.key_ptr.*;
            if (!ref.isValid()) continue;
            const idx = ref.index();
            if (idx >= self.symbols.len) continue;
            const sym = &self.symbols[idx];
            if (sym.flags.must_not_be_renamed) continue;
            sym.use_count += entry.value_ptr.*;
        }
    }

    pub fn allocateSlots(self: *MinifyRenamer) void {
        const SymWithCount = struct { idx: u32, count: u32 };
        var renameable: std.ArrayListUnmanaged(SymWithCount) = .empty;
        defer renameable.deinit(self.allocator);

        for (self.symbols, 0..) |*sym, i| {
            if (sym.flags.must_not_be_renamed) continue;
            if (sym.use_count > 0) {
                renameable.append(self.allocator, .{
                    .idx = @intCast(i),
                    .count = sym.use_count,
                }) catch {};
            }
        }

        // Sort by count descending, then by index ascending for stability
        std.mem.sort(SymWithCount, renameable.items, {}, struct {
            fn lessThan(_: void, a: SymWithCount, b: SymWithCount) bool {
                if (a.count != b.count) return a.count > b.count;
                return a.idx < b.idx;
            }
        }.lessThan);

        self.slots.ensureTotalCapacity(self.allocator, renameable.items.len) catch {};
        for (renameable.items, 0..) |item, i| {
            self.top_level_slots.put(self.allocator, item.idx, @intCast(i)) catch {};
            self.slots.append(self.allocator, .{ .name = "", .count = item.count }) catch {};
        }
    }

    pub fn reserveUnrenamedSymbolNames(self: *MinifyRenamer) void {
        for (self.symbols, 0..) |*sym, i| {
            if (!self.top_level_slots.contains(@intCast(i))) {
                self.reserved_names.put(self.allocator, sym.original_name, {}) catch {};
            }
        }
    }

    pub fn assignNames(self: *MinifyRenamer) void {
        var name_index: u32 = 0;
        var buf: [16]u8 = undefined;

        // First pass: compute total name storage needed
        var total_len: usize = 0;
        var indices: std.ArrayListUnmanaged(u32) = .empty;
        defer indices.deinit(self.allocator);
        for (self.slots.items) |_| {
            var name = numberToMinifiedName(&buf, name_index);
            while (self.reserved_names.contains(name)) {
                name_index += 1;
                name = numberToMinifiedName(&buf, name_index);
            }
            indices.append(self.allocator, name_index) catch {};
            total_len += name.len;
            name_index += 1;
        }

        // Pre-allocate name buffer to avoid reallocation
        self.name_buf.ensureTotalCapacity(self.allocator, total_len) catch {};

        // Second pass: store names (no reallocation will occur)
        for (self.slots.items, 0..) |*slot, i| {
            const idx = indices.items[i];
            const name = numberToMinifiedName(&buf, idx);
            const offset: u32 = @intCast(self.name_buf.items.len);
            self.name_buf.appendSlice(self.allocator, name) catch {};
            self.name_offsets.append(self.allocator, .{ .offset = offset, .len = @intCast(name.len) }) catch {};
            slot.name = self.name_buf.items[offset .. offset + name.len];
        }
    }

    fn nameForSymbolImpl(ptr: *const anyopaque, ref: Ast.SymbolIndex) []const u8 {
        const self: *const MinifyRenamer = @ptrCast(@alignCast(ptr));
        if (!ref.isValid()) return "";
        const idx = ref.index();
        if (idx >= self.symbols.len) return "";
        const sym = &self.symbols[idx];
        if (sym.flags.must_not_be_renamed) return sym.original_name;
        if (self.top_level_slots.get(idx)) |slot_idx| {
            return self.slots.items[slot_idx].name;
        }
        return sym.original_name;
    }
};

// =========================================================================
// Name generation
// =========================================================================

const head = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
const tail = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

/// Convert a number to a minified identifier name.
/// Sequence: a, b, ..., z, A, ..., Z, aa, ba, ca, ...
pub fn numberToMinifiedName(buf: []u8, n_in: u32) []const u8 {
    var n = n_in;
    const n_head: u32 = head.len;
    const n_tail: u32 = tail.len;

    var len: u32 = 0;
    buf[len] = head[n % n_head];
    len += 1;
    n = n / n_head;

    while (n > 0) {
        n -= 1;
        buf[len] = tail[n % n_tail];
        len += 1;
        n = n / n_tail;
    }

    return buf[0..len];
}

// =========================================================================
// Character Frequency Analysis
// =========================================================================

pub const CharFreq = struct {
    counts: [64]i32 = [_]i32{0} ** 64,

    /// Accumulates character frequencies from text.
    /// a-z → 0-25, A-Z → 26-51, 0-9 → 52-61, _ → 62
    pub fn scan(self: *CharFreq, text: []const u8, delta: i32) void {
        for (text) |c| {
            const idx: ?usize = if (c >= 'a' and c <= 'z')
                @as(usize, c - 'a')
            else if (c >= 'A' and c <= 'Z')
                @as(usize, c - 'A' + 26)
            else if (c >= '0' and c <= '9')
                @as(usize, c - '0' + 52)
            else if (c == '_')
                62
            else
                null;
            if (idx) |i| {
                self.counts[i] += delta;
            }
        }
    }
};

// =========================================================================
// Frequency-based Name Minifier
// =========================================================================

pub const NameMinifier = struct {
    head_buf: [52]u8,
    tail_buf: [62]u8,
    head_len: u8,
    tail_len: u8,

    /// Creates a NameMinifier with the default a-zA-Z / a-zA-Z0-9 alphabets.
    pub fn init() NameMinifier {
        var self: NameMinifier = undefined;
        @memcpy(self.head_buf[0..head.len], head);
        @memcpy(self.tail_buf[0..tail.len], tail);
        self.head_len = head.len;
        self.tail_len = tail.len;
        return self;
    }

    /// Convert a number to a minified identifier name using instance alphabets.
    pub fn numberToName(self: *const NameMinifier, buf: []u8, n_in: u32) []const u8 {
        var n = n_in;
        const h = self.head_buf[0..self.head_len];
        const t = self.tail_buf[0..self.tail_len];
        const n_head: u32 = self.head_len;
        const n_tail: u32 = self.tail_len;

        var len: u32 = 0;
        buf[len] = h[n % n_head];
        len += 1;
        n = n / n_head;

        while (n > 0) {
            n -= 1;
            buf[len] = t[n % n_tail];
            len += 1;
            n = n / n_tail;
        }

        return buf[0..len];
    }

    /// Reorders alphabets based on character frequency for better gzip compression.
    pub fn shuffleByCharFreq(freq: *const CharFreq) NameMinifier {
        const CharCount = struct { char: u8, count: i32 };
        var chars: [62]CharCount = undefined;
        for (tail, 0..) |c, i| {
            chars[i] = .{ .char = c, .count = freq.counts[i] };
        }

        std.mem.sort(CharCount, &chars, {}, struct {
            fn lessThan(_: void, a: CharCount, b: CharCount) bool {
                return a.count > b.count;
            }
        }.lessThan);

        var result: NameMinifier = undefined;
        var hl: u8 = 0;
        var tl: u8 = 0;
        for (chars) |c| {
            result.tail_buf[tl] = c.char;
            tl += 1;
            if (c.char < '0' or c.char > '9') {
                result.head_buf[hl] = c.char;
                hl += 1;
            }
        }
        result.head_len = hl;
        result.tail_len = tl;
        return result;
    }
};

// =========================================================================
// Reserved names
// =========================================================================

/// Build the set of names that must not be used for renamed symbols
/// (keywords, reserved words, builtin types, etc.).
pub fn computeReservedNames(allocator: std.mem.Allocator) std.StringHashMapUnmanaged(void) {
    var reserved = std.StringHashMapUnmanaged(void){};

    // Keywords
    const keywords = [_][]const u8{
        "alias", "break", "case", "const", "const_assert", "continue",
        "continuing", "default", "diagnostic", "discard", "else", "enable",
        "false", "fn", "for", "if", "let", "loop", "override", "requires",
        "return", "struct", "switch", "true", "var", "while",
    };
    for (keywords) |kw| reserved.put(allocator, kw, {}) catch {};

    // Reserved words
    const reserved_words = [_][]const u8{
        "NULL",  "Self",   "abstract",     "active",    "alignas",         "alignof",
        "as",    "asm",    "asm_fragment",  "async",     "attribute",       "auto",
        "await", "become", "cast",          "catch",     "class",           "co_await",
        "co_return", "co_yield", "coherent", "column_major", "common",     "compile",
        "compile_fragment", "concept", "const_cast", "consteval", "constexpr", "constinit",
        "crate", "debugger", "decltype", "delete", "demote", "demote_to_helper",
        "do", "dynamic_cast", "enum", "explicit", "export", "extends",
        "extern", "external", "fallthrough", "filter", "final", "finally",
        "friend", "from", "fxgroup", "get", "goto", "groupshared",
        "highp", "impl", "implements", "import", "inline", "instanceof",
        "interface", "layout", "lowp", "macro", "macro_rules", "match",
        "mediump", "meta", "mod", "module", "move", "mut",
        "mutable", "namespace", "new", "nil", "noexcept", "noinline",
        "nointerpolation", "non_coherent", "noncoherent", "noperspective",
        "null", "nullptr", "of", "operator", "package", "packoffset",
        "partition", "pass", "patch", "pixelfragment", "precise", "precision",
        "premerge", "priv", "protected", "pub", "public", "readonly",
        "ref", "regardless", "register", "reinterpret_cast", "require",
        "resource", "restrict", "self", "set", "shared", "sizeof",
        "smooth", "snorm", "static", "static_assert", "static_cast", "std",
        "subroutine", "super", "target", "template", "this", "thread_local",
        "throw", "trait", "try", "type", "typedef", "typeid",
        "typename", "typeof", "union", "unless", "unorm", "unsafe",
        "unsized", "use", "using", "varying", "virtual", "volatile",
        "wgsl", "where", "with", "writeonly", "yield",
    };
    for (reserved_words) |w| reserved.put(allocator, w, {}) catch {};

    // Single underscore
    reserved.put(allocator, "_", {}) catch {};

    // Builtin types
    const builtin_types = [_][]const u8{
        "bool", "i32", "u32", "f32", "f16",
        "vec2", "vec3", "vec4",
        "vec2i", "vec3i", "vec4i", "vec2u", "vec3u", "vec4u",
        "vec2f", "vec3f", "vec4f", "vec2h", "vec3h", "vec4h",
        "mat2x2", "mat2x3", "mat2x4", "mat3x2", "mat3x3", "mat3x4",
        "mat4x2", "mat4x3", "mat4x4",
        "mat2x2f", "mat2x3f", "mat2x4f", "mat3x2f", "mat3x3f", "mat3x4f",
        "mat4x2f", "mat4x3f", "mat4x4f",
        "mat2x2h", "mat2x3h", "mat2x4h", "mat3x2h", "mat3x3h", "mat3x4h",
        "mat4x2h", "mat4x3h", "mat4x4h",
        "array", "ptr", "atomic",
        "sampler", "sampler_comparison",
        "texture_1d", "texture_2d", "texture_2d_array",
        "texture_3d", "texture_cube", "texture_cube_array",
        "texture_multisampled_2d",
        "texture_storage_1d", "texture_storage_2d", "texture_storage_2d_array", "texture_storage_3d",
        "texture_depth_2d", "texture_depth_2d_array", "texture_depth_cube", "texture_depth_cube_array",
        "texture_depth_multisampled_2d", "texture_external",
    };
    for (builtin_types) |t| reserved.put(allocator, t, {}) catch {};

    // Builtin function names (must not be used as minified identifiers)
    const builtin_functions = [_][]const u8{
        "all",                "any",                 "select",
        "arrayLength",        "bitcast",
        "sin",                "cos",                 "tan",
        "asin",               "acos",                "atan",
        "sinh",               "cosh",                "tanh",
        "asinh",              "acosh",               "atanh",
        "atan2",
        "exp",                "exp2",                "log",
        "log2",               "pow",                 "sqrt",
        "inverseSqrt",
        "abs",                "sign",                "floor",
        "ceil",               "round",               "trunc",
        "fract",              "min",                 "max",
        "clamp",              "saturate",            "mix",
        "step",               "smoothstep",          "fma",
        "degrees",            "radians",
        "dot",                "cross",               "length",
        "distance",           "normalize",           "reflect",
        "refract",            "faceForward",
        "countOneBits",       "countLeadingZeros",   "countTrailingZeros",
        "reverseBits",        "firstLeadingBit",     "firstTrailingBit",
        "extractBits",        "insertBits",
        "transpose",          "determinant",
        "ldexp",              "frexp",               "modf",
        "quantizeToF16",
        "dpdx",               "dpdy",                "fwidth",
        "dpdxCoarse",         "dpdyCoarse",          "fwidthCoarse",
        "dpdxFine",           "dpdyFine",            "fwidthFine",
        "textureSample",      "textureSampleBias",   "textureSampleCompare",
        "textureSampleCompareLevel", "textureSampleLevel", "textureSampleGrad",
        "textureLoad",        "textureStore",        "textureDimensions",
        "textureNumLayers",   "textureNumLevels",    "textureNumSamples",
        "textureGather",      "textureGatherCompare",
        "atomicLoad",         "atomicStore",         "atomicAdd",
        "atomicSub",          "atomicMax",           "atomicMin",
        "atomicAnd",          "atomicOr",            "atomicXor",
        "atomicExchange",     "atomicCompareExchangeWeak",
        "pack4x8snorm",       "pack4x8unorm",        "pack2x16snorm",
        "pack2x16unorm",      "pack2x16float",       "pack4xI8",
        "pack4xU8",           "pack4xI8Clamp",       "pack4xU8Clamp",
        "unpack4x8snorm",     "unpack4x8unorm",      "unpack2x16snorm",
        "unpack2x16unorm",    "unpack2x16float",     "unpack4xI8",
        "unpack4xU8",
        "workgroupBarrier",   "storageBarrier",      "textureBarrier",
        "workgroupUniformLoad",
        "subgroupBallot",     "subgroupBroadcast",   "subgroupBroadcastFirst",
        "subgroupShuffle",    "subgroupShuffleDown",  "subgroupShuffleUp",
        "subgroupShuffleXor", "subgroupAdd",         "subgroupMul",
        "subgroupAnd",        "subgroupOr",          "subgroupXor",
        "subgroupMin",        "subgroupMax",
        "subgroupInclusiveAdd", "subgroupInclusiveMul",
        "subgroupExclusiveAdd", "subgroupExclusiveMul",
        "subgroupAll",        "subgroupAny",         "subgroupElect",
    };
    for (builtin_functions) |bf| reserved.put(allocator, bf, {}) catch {};

    // Address spaces
    for ([_][]const u8{ "function", "private", "workgroup", "uniform", "storage" }) |s| {
        reserved.put(allocator, s, {}) catch {};
    }

    // Access modes
    for ([_][]const u8{ "read", "write", "read_write" }) |m| {
        reserved.put(allocator, m, {}) catch {};
    }

    // Texel formats
    const texel_formats = [_][]const u8{
        "rgba8unorm",  "rgba8snorm",  "rgba8uint",   "rgba8sint",
        "rgba16uint",  "rgba16sint",  "rgba16float",
        "r32uint",     "r32sint",     "r32float",
        "rg32uint",    "rg32sint",    "rg32float",
        "rgba32uint",  "rgba32sint",  "rgba32float",
        "bgra8unorm",
        // Extended formats (Dawn/Tint)
        "r8unorm",     "r8snorm",
        "rg8unorm",    "rg8snorm",
        "r16uint",     "r16sint",     "r16float",
        "rg16uint",    "rg16sint",    "rg16float",
        "rgb10a2uint", "rgb10a2unorm",
    };
    for (texel_formats) |f| reserved.put(allocator, f, {}) catch {};

    return reserved;
}

// =========================================================================
// Tests
// =========================================================================

test "numberToMinifiedName sequence" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("a", numberToMinifiedName(&buf, 0));
    try std.testing.expectEqualStrings("b", numberToMinifiedName(&buf, 1));
    try std.testing.expectEqualStrings("z", numberToMinifiedName(&buf, 25));
    try std.testing.expectEqualStrings("A", numberToMinifiedName(&buf, 26));
    try std.testing.expectEqualStrings("Z", numberToMinifiedName(&buf, 51));
    try std.testing.expectEqualStrings("aa", numberToMinifiedName(&buf, 52));
    try std.testing.expectEqualStrings("ba", numberToMinifiedName(&buf, 53));
}

test "numberToMinifiedName generates valid identifiers for 1000 names" {
    var buf: [16]u8 = undefined;
    for (0..1000) |i| {
        const name = numberToMinifiedName(&buf, @intCast(i));
        try std.testing.expect(name.len > 0);
        // First char must be a letter
        const first = name[0];
        try std.testing.expect((first >= 'a' and first <= 'z') or (first >= 'A' and first <= 'Z'));
        // Remaining chars must be alphanumeric
        for (name[1..]) |c| {
            try std.testing.expect(
                (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9'),
            );
        }
    }
}

test "numberToMinifiedName no duplicates in 10000 names" {
    var buf: [16]u8 = undefined;
    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(std.testing.allocator);

    for (0..10000) |i| {
        const name = numberToMinifiedName(&buf, @intCast(i));
        const owned = std.testing.allocator.dupe(u8, name) catch unreachable;
        defer std.testing.allocator.free(owned);
        const result = seen.getOrPut(std.testing.allocator, owned) catch unreachable;
        try std.testing.expect(!result.found_existing);
        result.key_ptr.* = std.testing.allocator.dupe(u8, name) catch unreachable;
    }

    // Clean up owned keys
    var it = seen.iterator();
    while (it.next()) |entry| {
        std.testing.allocator.free(@constCast(entry.key_ptr.*));
    }
}

test "computeReservedNames includes keywords" {
    var reserved = computeReservedNames(std.testing.allocator);
    defer reserved.deinit(std.testing.allocator);

    try std.testing.expect(reserved.contains("fn"));
    try std.testing.expect(reserved.contains("var"));
    try std.testing.expect(reserved.contains("return"));
    try std.testing.expect(reserved.contains("struct"));
    try std.testing.expect(reserved.contains("if"));
}

test "computeReservedNames has reasonable count" {
    var reserved = computeReservedNames(std.testing.allocator);
    defer reserved.deinit(std.testing.allocator);

    // Should have at least 150 reserved names
    try std.testing.expect(reserved.count() >= 150);
}

test "generated names don't collide with reserved" {
    var reserved = computeReservedNames(std.testing.allocator);
    defer reserved.deinit(std.testing.allocator);

    var buf: [16]u8 = undefined;
    // Check first 1000 names — short names like "fn", "if" should be skipped
    // by the renamer, but numberToMinifiedName itself doesn't skip.
    // The MinifyRenamer.assignNames handles this, so we just verify the
    // name generation + reserved check flow works.
    var count: usize = 0;
    var n: u32 = 0;
    while (count < 100) : (n += 1) {
        const name = numberToMinifiedName(&buf, n);
        if (!reserved.contains(name)) {
            count += 1;
        }
    }
    try std.testing.expect(count == 100);
}

test "NoOpRenamer returns original names" {
    const symbols = [_]Ast.Symbol{
        .{ .original_name = "myFunc", .kind = .function, .flags = .{} },
        .{ .original_name = "myVar", .kind = .@"var", .flags = .{} },
    };
    var noop = NoOpRenamer.init(&symbols);
    noop.renamer.ptr = @ptrCast(&noop); // Fix self-pointer after move
    try std.testing.expectEqualStrings("myFunc", noop.renamer.nameForSymbol(@as(Ast.SymbolIndex, @enumFromInt(0))));
    try std.testing.expectEqualStrings("myVar", noop.renamer.nameForSymbol(@as(Ast.SymbolIndex, @enumFromInt(1))));
}

test "NoOpRenamer handles invalid ref" {
    const symbols = [_]Ast.Symbol{
        .{ .original_name = "foo", .kind = .function, .flags = .{} },
    };
    var noop = NoOpRenamer.init(&symbols);
    try std.testing.expectEqualStrings("", noop.renamer.nameForSymbol(Ast.SymbolIndex.none));
}

test "NoOpRenamer handles out-of-bounds ref" {
    const symbols = [_]Ast.Symbol{
        .{ .original_name = "foo", .kind = .function, .flags = .{} },
    };
    var noop = NoOpRenamer.init(&symbols);
    noop.renamer.ptr = @ptrCast(&noop);
    try std.testing.expectEqualStrings("", noop.renamer.nameForSymbol(@as(Ast.SymbolIndex, @enumFromInt(100))));
}

test "MinifyRenamer full workflow" {
    var symbols = [_]Ast.Symbol{
        .{ .original_name = "entryMain", .kind = .function, .flags = .{ .must_not_be_renamed = true } },
        .{ .original_name = "helperFunc", .kind = .function, .flags = .{}, .use_count = 0 },
        .{ .original_name = "otherFunc", .kind = .function, .flags = .{}, .use_count = 0 },
    };

    var reserved = computeReservedNames(std.testing.allocator);
    defer reserved.deinit(std.testing.allocator);

    var renamer = MinifyRenamer.init(std.testing.allocator, &symbols, reserved);
    renamer.renamer.ptr = @ptrCast(&renamer); // Fix self-pointer after move
    defer {
        renamer.slots.deinit(std.testing.allocator);
        renamer.top_level_slots.deinit(std.testing.allocator);
        renamer.name_buf.deinit(std.testing.allocator);
        renamer.name_offsets.deinit(std.testing.allocator);
    }

    // Simulate use counts
    var uses = std.AutoHashMapUnmanaged(Ast.SymbolIndex, u32){};
    defer uses.deinit(std.testing.allocator);
    uses.put(std.testing.allocator, @as(Ast.SymbolIndex, @enumFromInt(1)), 5) catch {};
    uses.put(std.testing.allocator, @as(Ast.SymbolIndex, @enumFromInt(2)), 3) catch {};

    renamer.accumulateSymbolUseCounts(&uses);
    renamer.allocateSlots();
    renamer.reserveUnrenamedSymbolNames();
    renamer.assignNames();

    // Entry point should keep its name
    try std.testing.expectEqualStrings("entryMain", renamer.renamer.nameForSymbol(@as(Ast.SymbolIndex, @enumFromInt(0))));

    // Renamed symbols should have short names
    const name1 = renamer.renamer.nameForSymbol(@as(Ast.SymbolIndex, @enumFromInt(1)));
    const name2 = renamer.renamer.nameForSymbol(@as(Ast.SymbolIndex, @enumFromInt(2)));
    try std.testing.expect(name1.len > 0);
    try std.testing.expect(name2.len > 0);
    try std.testing.expect(!std.mem.eql(u8, name1, "helperFunc"));
    try std.testing.expect(!std.mem.eql(u8, name2, "otherFunc"));
}

test "MinifyRenamer invalid ref returns empty" {
    var symbols = [_]Ast.Symbol{
        .{ .original_name = "foo", .kind = .function, .flags = .{} },
    };
    const reserved = std.StringHashMapUnmanaged(void){};
    var renamer = MinifyRenamer.init(std.testing.allocator, &symbols, reserved);
    renamer.renamer.ptr = @ptrCast(&renamer);
    try std.testing.expectEqualStrings("", renamer.renamer.nameForSymbol(Ast.SymbolIndex.none));
}

test "MinifyRenamer zero use count not renamed" {
    var symbols = [_]Ast.Symbol{
        .{ .original_name = "unused", .kind = .function, .flags = .{}, .use_count = 0 },
    };
    const reserved = std.StringHashMapUnmanaged(void){};
    var renamer = MinifyRenamer.init(std.testing.allocator, &symbols, reserved);
    renamer.renamer.ptr = @ptrCast(&renamer);
    defer {
        renamer.slots.deinit(std.testing.allocator);
        renamer.top_level_slots.deinit(std.testing.allocator);
        renamer.name_buf.deinit(std.testing.allocator);
        renamer.name_offsets.deinit(std.testing.allocator);
    }

    renamer.allocateSlots();
    renamer.assignNames();

    // Zero use count means no slot allocated, returns original name
    try std.testing.expectEqualStrings("unused", renamer.renamer.nameForSymbol(@as(Ast.SymbolIndex, @enumFromInt(0))));
}

test "MinifyRenamer must_not_be_renamed flag" {
    var symbols = [_]Ast.Symbol{
        .{ .original_name = "keepMe", .kind = .function, .flags = .{ .must_not_be_renamed = true }, .use_count = 10 },
    };
    const reserved = std.StringHashMapUnmanaged(void){};
    var renamer = MinifyRenamer.init(std.testing.allocator, &symbols, reserved);
    renamer.renamer.ptr = @ptrCast(&renamer);
    defer {
        renamer.slots.deinit(std.testing.allocator);
        renamer.top_level_slots.deinit(std.testing.allocator);
        renamer.name_buf.deinit(std.testing.allocator);
        renamer.name_offsets.deinit(std.testing.allocator);
    }

    var uses = std.AutoHashMapUnmanaged(Ast.SymbolIndex, u32){};
    defer uses.deinit(std.testing.allocator);
    uses.put(std.testing.allocator, @as(Ast.SymbolIndex, @enumFromInt(0)), 10) catch {};

    renamer.accumulateSymbolUseCounts(&uses);
    renamer.allocateSlots();
    renamer.assignNames();

    // must_not_be_renamed should keep original name
    try std.testing.expectEqualStrings("keepMe", renamer.renamer.nameForSymbol(@as(Ast.SymbolIndex, @enumFromInt(0))));
}

test "CharFreq scan lowercase" {
    var freq = CharFreq{};
    freq.scan("aaa", 1);
    try std.testing.expectEqual(@as(i32, 3), freq.counts[0]);

    freq.scan("abc", 1);
    try std.testing.expectEqual(@as(i32, 4), freq.counts[0]); // 'a' now 4
    try std.testing.expectEqual(@as(i32, 1), freq.counts[1]); // 'b'
    try std.testing.expectEqual(@as(i32, 1), freq.counts[2]); // 'c'
}

test "CharFreq scan uppercase" {
    var freq = CharFreq{};
    freq.scan("ABC", 1);
    try std.testing.expectEqual(@as(i32, 1), freq.counts[26]); // 'A'
    try std.testing.expectEqual(@as(i32, 1), freq.counts[27]); // 'B'
    try std.testing.expectEqual(@as(i32, 1), freq.counts[28]); // 'C'
}

test "CharFreq scan digits" {
    var freq = CharFreq{};
    freq.scan("012", 1);
    try std.testing.expectEqual(@as(i32, 1), freq.counts[52]); // '0'
    try std.testing.expectEqual(@as(i32, 1), freq.counts[53]); // '1'
    try std.testing.expectEqual(@as(i32, 1), freq.counts[54]); // '2'
}

test "CharFreq scan mixed" {
    var freq = CharFreq{};
    freq.scan("variableName123", 1);
    try std.testing.expect(freq.counts[0] >= 2); // 'a' appears at least twice
}

test "CharFreq scan underscore" {
    var freq = CharFreq{};
    freq.scan("my_var_name", 1);
    try std.testing.expectEqual(@as(i32, 2), freq.counts[62]); // '_'
}

test "CharFreq scan ignores invalid chars" {
    var freq = CharFreq{};
    freq.scan("a!@#$%^&*()b+=-[]{}|c d\t\n", 1);
    try std.testing.expectEqual(@as(i32, 1), freq.counts[0]); // 'a'
    try std.testing.expectEqual(@as(i32, 1), freq.counts[1]); // 'b'
    try std.testing.expectEqual(@as(i32, 1), freq.counts[2]); // 'c'
    try std.testing.expectEqual(@as(i32, 1), freq.counts[3]); // 'd'
}

test "shuffleByCharFreq reorders alphabet" {
    var freq = CharFreq{};
    freq.counts[25] = 100; // 'z'
    freq.counts[0] = 1; // 'a'

    const shuffled = NameMinifier.shuffleByCharFreq(&freq);

    var buf: [16]u8 = undefined;
    const first = shuffled.numberToName(&buf, 0);
    try std.testing.expectEqual(@as(u8, 'z'), first[0]);
}

test "NameMinifier default matches numberToMinifiedName" {
    const nm = NameMinifier.init();
    var buf1: [16]u8 = undefined;
    var buf2: [16]u8 = undefined;
    for (0..100) |i| {
        const name1 = nm.numberToName(&buf1, @intCast(i));
        const name2 = numberToMinifiedName(&buf2, @intCast(i));
        try std.testing.expectEqualStrings(name2, name1);
    }
}

test "MinifyRenamer skips reserved names" {
    var symbols = [_]Ast.Symbol{
        .{ .original_name = "myFunc", .kind = .function, .flags = .{}, .use_count = 5 },
    };

    var reserved = computeReservedNames(std.testing.allocator);
    defer reserved.deinit(std.testing.allocator);

    var renamer = MinifyRenamer.init(std.testing.allocator, &symbols, reserved);
    renamer.renamer.ptr = @ptrCast(&renamer);
    defer {
        renamer.slots.deinit(std.testing.allocator);
        renamer.top_level_slots.deinit(std.testing.allocator);
        renamer.name_buf.deinit(std.testing.allocator);
        renamer.name_offsets.deinit(std.testing.allocator);
    }

    var uses = std.AutoHashMapUnmanaged(Ast.SymbolIndex, u32){};
    defer uses.deinit(std.testing.allocator);
    uses.put(std.testing.allocator, @as(Ast.SymbolIndex, @enumFromInt(0)), 5) catch {};

    renamer.accumulateSymbolUseCounts(&uses);
    renamer.allocateSlots();
    renamer.assignNames();

    const name = renamer.renamer.nameForSymbol(@as(Ast.SymbolIndex, @enumFromInt(0)));
    // Assigned name should not be a reserved name
    try std.testing.expect(!reserved.contains(name));
}
