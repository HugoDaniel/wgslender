//! WASM binary format writer.
//!
//! Generates valid WASM modules by writing sections in the correct order.
//! Used by the Compiler to assemble output .wasm files from hand-emitted
//! printer code sections and serialized AST data sections.
//!
//! All write operations propagate `Allocator.Error` — no silent failures.
//! The caller is responsible for providing a reliable allocator (typically
//! an arena allocator that bulk-frees on deinit).

const std = @import("std");
const Allocator = std.mem.Allocator;

// =========================================================================
// Constants
// =========================================================================

/// WASM magic number: '\0asm'
pub const magic = [_]u8{ 0x00, 0x61, 0x73, 0x6D };
/// WASM version 1
pub const wasm_version = [_]u8{ 0x01, 0x00, 0x00, 0x00 };

/// WASM section IDs (must appear in this order in the binary).
pub const SectionId = enum(u8) {
    type_section = 1,
    function = 3,
    memory = 5,
    global = 6,
    export_section = 7,
    code = 10,
    data = 11,
};

/// WASM value types.
pub const ValType = enum(u8) {
    i32 = 0x7F,
    i64 = 0x7E,
    f32 = 0x7D,
    f64 = 0x7C,
};

/// WASM export descriptor kinds.
pub const ExportKind = enum(u8) {
    func = 0x00,
    table = 0x01,
    memory = 0x02,
    global = 0x03,
};

// =========================================================================
// LEB128 encoding
// =========================================================================

pub fn writeUleb128(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, value: u32) Allocator.Error!void {
    var v = value;
    for (0..5) |_| { // ceil(32/7) = 5 bytes max for u32 LEB128
        const byte: u8 = @truncate(v & 0x7F);
        v >>= 7;
        if (v == 0) {
            try buf.append(allocator, byte);
            break;
        }
        try buf.append(allocator, byte | 0x80);
    } else unreachable;
}

pub fn writeSleb128(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, value: i32) Allocator.Error!void {
    var v = value;
    for (0..5) |_| { // ceil(32/7) = 5 bytes max for i32 SLEB128
        const byte: u8 = @truncate(@as(u32, @bitCast(v)) & 0x7F);
        v >>= 7;
        const done = (v == 0 and byte & 0x40 == 0) or (v == -1 and byte & 0x40 != 0);
        if (done) {
            try buf.append(allocator, byte);
            break;
        }
        try buf.append(allocator, byte | 0x80);
    } else unreachable;
}

// =========================================================================
// Section writing
// =========================================================================

/// Write a raw section: [section_id] [uleb128 size] [content].
fn writeSection(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, section_id: SectionId, content: []const u8) Allocator.Error!void {
    try buf.append(allocator, @intFromEnum(section_id));
    try writeUleb128(buf, allocator, @intCast(content.len));
    try buf.appendSlice(allocator, content);
}

/// Write a Type section with a single function type: () -> (i32).
pub fn writeTypeSectionSingleI32Return(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator) Allocator.Error!void {
    const content = [_]u8{
        0x01, // 1 type entry
        0x60, // func type marker
        0x00, // 0 parameters
        0x01, 0x7F, // 1 result: i32
    };
    try writeSection(buf, allocator, .type_section, &content);
}

pub const FuncType = struct {
    params: []const ValType,
    results: []const ValType,
};

/// Write a Type section with custom function type entries.
pub fn writeTypeSection(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, types: []const FuncType) Allocator.Error!void {
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(allocator);

    try writeUleb128(&content, allocator, @intCast(types.len));
    for (types) |ft| {
        try content.append(allocator, 0x60); // func type marker
        try writeUleb128(&content, allocator, @intCast(ft.params.len));
        for (ft.params) |p| try content.append(allocator, @intFromEnum(p));
        try writeUleb128(&content, allocator, @intCast(ft.results.len));
        for (ft.results) |r| try content.append(allocator, @intFromEnum(r));
    }
    try writeSection(buf, allocator, .type_section, content.items);
}

/// Write a Function section mapping N functions to type index 0.
pub fn writeFunctionSection(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, func_count: u32) Allocator.Error!void {
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(allocator);

    try writeUleb128(&content, allocator, func_count);
    for (0..func_count) |_| {
        try writeUleb128(&content, allocator, 0); // type index 0
    }
    try writeSection(buf, allocator, .function, content.items);
}

/// Write a Function section mapping functions to specific type indices.
pub fn writeFunctionSectionTyped(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, type_indices: []const u32) Allocator.Error!void {
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(allocator);

    try writeUleb128(&content, allocator, @intCast(type_indices.len));
    for (type_indices) |idx| {
        try writeUleb128(&content, allocator, idx);
    }
    try writeSection(buf, allocator, .function, content.items);
}

/// Write a Memory section with min pages and no max.
pub fn writeMemorySection(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, min_pages: u32) Allocator.Error!void {
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(allocator);

    try writeUleb128(&content, allocator, 1); // 1 memory
    try content.append(allocator, 0x00); // flags: no max
    try writeUleb128(&content, allocator, min_pages);
    try writeSection(buf, allocator, .memory, content.items);
}

pub const GlobalType = struct {
    val_type: ValType,
    mutable: bool,
    init_value: i32,
};

/// Write a Global section with mutable i32 globals.
pub fn writeGlobalSection(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, globals: []const GlobalType) Allocator.Error!void {
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(allocator);

    try writeUleb128(&content, allocator, @intCast(globals.len));
    for (globals) |g| {
        try content.append(allocator, @intFromEnum(g.val_type));
        try content.append(allocator, if (g.mutable) @as(u8, 0x01) else @as(u8, 0x00));
        try content.append(allocator, 0x41); // i32.const
        try writeSleb128(&content, allocator, g.init_value);
        try content.append(allocator, 0x0B); // end
    }
    try buf.append(allocator, @intFromEnum(SectionId.global));
    try writeUleb128(buf, allocator, @intCast(content.items.len));
    try buf.appendSlice(allocator, content.items);
}

pub const Export = struct {
    name: []const u8,
    kind: ExportKind,
    index: u32,
};

/// Write an Export section.
pub fn writeExportSection(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, exports: []const Export) Allocator.Error!void {
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(allocator);

    try writeUleb128(&content, allocator, @intCast(exports.len));
    for (exports) |exp| {
        try writeUleb128(&content, allocator, @intCast(exp.name.len));
        try content.appendSlice(allocator, exp.name);
        try content.append(allocator, @intFromEnum(exp.kind));
        try writeUleb128(&content, allocator, exp.index);
    }
    try writeSection(buf, allocator, .export_section, content.items);
}

/// Write a Code section with pre-built function bodies.
/// Each body is the raw bytes INSIDE the function (locals + instructions),
/// NOT including the body size prefix.
pub fn writeCodeSection(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, bodies: []const []const u8) Allocator.Error!void {
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(allocator);

    try writeUleb128(&content, allocator, @intCast(bodies.len));
    for (bodies) |body| {
        try writeUleb128(&content, allocator, @intCast(body.len));
        try content.appendSlice(allocator, body);
    }
    try writeSection(buf, allocator, .code, content.items);
}

/// Write a Code section from raw section content (already includes func count + bodies).
pub fn writeCodeSectionRaw(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, raw_content: []const u8) Allocator.Error!void {
    try writeSection(buf, allocator, .code, raw_content);
}

pub const DataSegment = struct {
    offset: u32,
    data: []const u8,
};

/// Write a Data section with active segments at specified offsets.
pub fn writeDataSection(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, segments: []const DataSegment) Allocator.Error!void {
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(allocator);

    try writeUleb128(&content, allocator, @intCast(segments.len));
    for (segments) |seg| {
        try content.append(allocator, 0x00); // active, memory 0
        try content.append(allocator, 0x41); // i32.const
        try writeSleb128(&content, allocator, @intCast(seg.offset));
        try content.append(allocator, 0x0B); // end
        try writeUleb128(&content, allocator, @intCast(seg.data.len));
        try content.appendSlice(allocator, seg.data);
    }
    try writeSection(buf, allocator, .data, content.items);
}

// =========================================================================
// Module assembly
// =========================================================================

/// Assemble a complete WASM module. Caller must call `allocator.free()` on the result.
pub fn writeModule(
    allocator: Allocator,
    type_section: ?[]const u8,
    function_section: ?[]const u8,
    memory_min_pages: u32,
    exports: []const Export,
    code_section_content: []const u8,
    data_segments: []const DataSegment,
) Allocator.Error![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, &magic);
    try buf.appendSlice(allocator, &wasm_version);

    if (type_section) |ts| {
        try buf.appendSlice(allocator, ts);
    } else {
        try writeTypeSectionSingleI32Return(&buf, allocator);
    }

    if (function_section) |fs| {
        try buf.appendSlice(allocator, fs);
    } else {
        try writeFunctionSection(&buf, allocator, 1);
    }

    try writeMemorySection(&buf, allocator, memory_min_pages);
    try writeExportSection(&buf, allocator, exports);
    try writeCodeSectionRaw(&buf, allocator, code_section_content);

    if (data_segments.len > 0) {
        try writeDataSection(&buf, allocator, data_segments);
    }

    return buf.toOwnedSlice(allocator);
}

// =========================================================================
// Section parser (extract sections from existing WASM)
// =========================================================================

/// Parsed section from a WASM binary.
pub const ParsedSection = struct {
    id: u8,
    content: []const u8,
    /// Full section bytes including id + size prefix.
    raw: []const u8,
};

/// Parse all sections from a WASM binary.
/// Returns slices into the original data (no allocation needed).
pub fn parseSections(wasm_data: []const u8) []const ParsedSection {
    const max_sections = 16;
    var sections: [max_sections]ParsedSection = undefined;
    var count: usize = 0;

    if (wasm_data.len < 8) return sections[0..0];
    var pos: usize = 8; // skip magic + version

    while (pos < wasm_data.len and count < max_sections) {
        const section_start = pos;
        const id = wasm_data[pos];
        pos += 1;

        var size: u32 = 0;
        var shift: u5 = 0;
        while (pos < wasm_data.len) {
            const byte = wasm_data[pos];
            pos += 1;
            size |= @as(u32, byte & 0x7F) << shift;
            if (byte & 0x80 == 0) break;
            shift +%= 7;
        }

        if (pos + size > wasm_data.len) break;

        sections[count] = .{
            .id = id,
            .content = wasm_data[pos..][0..size],
            .raw = wasm_data[section_start..][0 .. pos - section_start + size],
        };
        count += 1;
        pos += size;
    }

    return sections[0..count];
}

/// Find a section by ID in parsed sections.
pub fn findSection(sections: []const ParsedSection, id: SectionId) ?ParsedSection {
    for (sections) |s| {
        if (s.id == @intFromEnum(id)) return s;
    }
    return null;
}

// =========================================================================
// WASM instruction emitter
// =========================================================================

/// Emit helpers for writing WASM bytecode instructions into a buffer.
///
/// All methods propagate `Allocator.Error`. Use with an arena allocator
/// for bulk operations where individual error handling is unnecessary.
pub const Emit = struct {
    buf: *std.ArrayListUnmanaged(u8),
    alloc: Allocator,

    pub fn init(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator) Emit {
        return .{ .buf = buf, .alloc = allocator };
    }

    // -- Control flow --

    pub fn block(self: Emit) Allocator.Error!void {
        try self.byte(0x02);
        try self.byte(0x40); // void blocktype
    }

    pub fn loop_(self: Emit) Allocator.Error!void {
        try self.byte(0x03);
        try self.byte(0x40);
    }

    pub fn if_(self: Emit) Allocator.Error!void {
        try self.byte(0x04);
        try self.byte(0x40);
    }

    pub fn else_(self: Emit) Allocator.Error!void {
        try self.byte(0x05);
    }

    pub fn end(self: Emit) Allocator.Error!void {
        try self.byte(0x0B);
    }

    pub fn br(self: Emit, depth: u32) Allocator.Error!void {
        try self.byte(0x0C);
        try self.uleb(depth);
    }

    pub fn br_if(self: Emit, depth: u32) Allocator.Error!void {
        try self.byte(0x0D);
        try self.uleb(depth);
    }

    pub fn @"return"(self: Emit) Allocator.Error!void {
        try self.byte(0x0F);
    }

    pub fn call(self: Emit, func_idx: u32) Allocator.Error!void {
        try self.byte(0x10);
        try self.uleb(func_idx);
    }

    // -- Constants --

    pub fn i32_const(self: Emit, value: i32) Allocator.Error!void {
        try self.byte(0x41);
        try self.sleb(value);
    }

    // -- Variables --

    pub fn local_get(self: Emit, idx: u32) Allocator.Error!void {
        try self.byte(0x20);
        try self.uleb(idx);
    }

    pub fn local_set(self: Emit, idx: u32) Allocator.Error!void {
        try self.byte(0x21);
        try self.uleb(idx);
    }

    pub fn local_tee(self: Emit, idx: u32) Allocator.Error!void {
        try self.byte(0x22);
        try self.uleb(idx);
    }

    pub fn global_get(self: Emit, idx: u32) Allocator.Error!void {
        try self.byte(0x23);
        try self.uleb(idx);
    }

    pub fn global_set(self: Emit, idx: u32) Allocator.Error!void {
        try self.byte(0x24);
        try self.uleb(idx);
    }

    // -- Memory --

    pub fn i32_load(self: Emit) Allocator.Error!void {
        try self.byte(0x28);
        try self.byte(0x02); // align=4
        try self.byte(0x00); // offset=0
    }

    pub fn i32_load8_u(self: Emit) Allocator.Error!void {
        try self.byte(0x2D);
        try self.byte(0x00); // align=1
        try self.byte(0x00); // offset=0
    }

    pub fn i32_load16_u(self: Emit) Allocator.Error!void {
        try self.byte(0x2F);
        try self.byte(0x01); // align=2
        try self.byte(0x00); // offset=0
    }

    pub fn i32_store8(self: Emit) Allocator.Error!void {
        try self.byte(0x3A);
        try self.byte(0x00);
        try self.byte(0x00);
    }

    // -- Arithmetic --

    pub fn i32_eqz(self: Emit) Allocator.Error!void { try self.byte(0x45); }
    pub fn i32_eq(self: Emit) Allocator.Error!void { try self.byte(0x46); }
    pub fn i32_ne(self: Emit) Allocator.Error!void { try self.byte(0x47); }
    pub fn i32_lt_u(self: Emit) Allocator.Error!void { try self.byte(0x49); }
    pub fn i32_gt_u(self: Emit) Allocator.Error!void { try self.byte(0x4B); }
    pub fn i32_ge_u(self: Emit) Allocator.Error!void { try self.byte(0x4F); }
    pub fn i32_add(self: Emit) Allocator.Error!void { try self.byte(0x6A); }
    pub fn i32_sub(self: Emit) Allocator.Error!void { try self.byte(0x6B); }
    pub fn i32_mul(self: Emit) Allocator.Error!void { try self.byte(0x6C); }
    pub fn i32_and(self: Emit) Allocator.Error!void { try self.byte(0x71); }
    pub fn i32_shr_u(self: Emit) Allocator.Error!void { try self.byte(0x76); }
    pub fn drop(self: Emit) Allocator.Error!void { try self.byte(0x1A); }

    // -- Helpers --

    fn byte(self: Emit, b: u8) Allocator.Error!void {
        try self.buf.append(self.alloc, b);
    }

    fn uleb(self: Emit, value: u32) Allocator.Error!void {
        try writeUleb128(self.buf, self.alloc, value);
    }

    fn sleb(self: Emit, value: i32) Allocator.Error!void {
        try writeSleb128(self.buf, self.alloc, value);
    }

    /// Emit a locals declaration: N locals of type i32.
    pub fn localDecl(self: Emit, count: u32) Allocator.Error!void {
        if (count == 0) {
            try self.uleb(0);
        } else {
            try self.uleb(1); // 1 local declaration group
            try self.uleb(count); // N locals
            try self.byte(0x7F); // type: i32
        }
    }
};

// =========================================================================
// Tests
// =========================================================================

test "ULEB128 encoding" {
    const a = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(a);

    try writeUleb128(&buf, a, 0);
    try std.testing.expectEqualSlices(u8, &.{0x00}, buf.items);

    buf.clearRetainingCapacity();
    try writeUleb128(&buf, a, 127);
    try std.testing.expectEqualSlices(u8, &.{0x7F}, buf.items);

    buf.clearRetainingCapacity();
    try writeUleb128(&buf, a, 128);
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x01 }, buf.items);

    buf.clearRetainingCapacity();
    try writeUleb128(&buf, a, 624485);
    try std.testing.expectEqualSlices(u8, &.{ 0xE5, 0x8E, 0x26 }, buf.items);
}

test "SLEB128 encoding" {
    const a = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(a);

    try writeSleb128(&buf, a, 0);
    try std.testing.expectEqualSlices(u8, &.{0x00}, buf.items);

    buf.clearRetainingCapacity();
    try writeSleb128(&buf, a, -1);
    try std.testing.expectEqualSlices(u8, &.{0x7F}, buf.items);

    buf.clearRetainingCapacity();
    try writeSleb128(&buf, a, 4096);
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x20 }, buf.items);
}

test "module has correct magic and version" {
    const a = std.testing.allocator;
    const wasm = try writeModule(a, null, null, 1, &.{
        .{ .name = "memory", .kind = .memory, .index = 0 },
        .{ .name = "generate", .kind = .func, .index = 0 },
    }, &.{
        0x00, // 0 local declarations
        0x41, 0x2A, // i32.const 42
        0x0B, // end
    }, &.{});
    defer a.free(wasm);

    try std.testing.expectEqualSlices(u8, &magic, wasm[0..4]);
    try std.testing.expectEqualSlices(u8, &wasm_version, wasm[4..8]);
}

test "parse sections round-trip" {
    const a = std.testing.allocator;
    const wasm = try writeModule(a, null, null, 1, &.{
        .{ .name = "memory", .kind = .memory, .index = 0 },
    }, &.{
        0x00, 0x41, 0x00, 0x0B,
    }, &.{
        .{ .offset = 0, .data = "hello" },
    });
    defer a.free(wasm);

    const sections = parseSections(wasm);
    try std.testing.expect(sections.len >= 4);
    try std.testing.expect(findSection(sections, .type_section) != null);
    try std.testing.expect(findSection(sections, .memory) != null);
    try std.testing.expect(findSection(sections, .code) != null);
    try std.testing.expect(findSection(sections, .data) != null);
}

test "Emit produces valid instruction sequence" {
    const a = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(a);

    const e = Emit.init(&buf, a);
    try e.localDecl(2);
    try e.i32_const(42);
    try e.local_set(0);
    try e.local_get(0);
    try e.end();

    // Verify: [1 group, 2 locals, i32] [i32.const 42] [local.set 0] [local.get 0] [end]
    try std.testing.expectEqualSlices(u8, &.{
        0x01, 0x02, 0x7F, // locals: 1 group, 2 x i32
        0x41, 0x2A, // i32.const 42
        0x21, 0x00, // local.set 0
        0x20, 0x00, // local.get 0
        0x0B, // end
    }, buf.items);
}
