//! Source map generation for the WGSL minifier.
//!
//! Implements the Source Map v3 format as specified at:
//! https://sourcemaps.info/spec.html
//!
//! Provides VLQ encoding/decoding, a LineIndex for byte-offset to line/column
//! conversion (with UTF-16 column support), and a Generator that builds
//! source maps incrementally with delta compression.

const std = @import("std");

const SourceMap = @This();

// =========================================================================
// VLQ encoding / decoding
// =========================================================================

/// Base64 alphabet used for VLQ encoding in source maps.
const base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Lookup table for decoding base64 characters. 0xff means invalid.
const base64_values: [128]u8 = blk: {
    var table: [128]u8 = .{0xff} ** 128;
    for (base64_alphabet, 0..) |c, i| {
        table[c] = @intCast(i);
    }
    break :blk table;
};

const vlq_base_shift: u5 = 5;
const vlq_base: u32 = 1 << vlq_base_shift; // 32
const vlq_base_mask: u32 = vlq_base - 1; // 31
const vlq_continuation_bit: u32 = vlq_base; // 32
const vlq_sign_bit: u32 = 1;

/// Maximum number of base64 digits a single VLQ value can produce.
/// A 32-bit value needs at most ceil(32/5) + 1 = 8 digits.
const vlq_max_digits = 8;

/// Encode a signed integer as a VLQ base64 sequence, appending to `buf`.
pub fn encodeVlq(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: i32) void {
    // Convert to VLQ signed representation:
    //   positive: value << 1
    //   negative: ((-value) << 1) | 1
    var vlq: u32 = if (value < 0)
        (@as(u32, @intCast(-value)) << 1) | vlq_sign_bit
    else
        @as(u32, @intCast(value)) << 1;

    // Emit base64 digits with continuation bits.
    while (true) {
        var digit = vlq & vlq_base_mask;
        vlq >>= vlq_base_shift;

        if (vlq > 0) {
            digit |= vlq_continuation_bit;
        }

        buf.append(allocator, base64_alphabet[digit]) catch {};

        if (vlq == 0) break;
    }
}

pub const VlqSingleResult = struct { buf: [vlq_max_digits]u8, len: u8 };

/// Encode a single VLQ value and return it as a short stack-allocated string slice.
pub fn encodeVlqSingle(value: i32) VlqSingleResult {
    var result = VlqSingleResult{ .buf = undefined, .len = 0 };

    var vlq: u32 = if (value < 0)
        (@as(u32, @intCast(-value)) << 1) | vlq_sign_bit
    else
        @as(u32, @intCast(value)) << 1;

    while (true) {
        var digit = vlq & vlq_base_mask;
        vlq >>= vlq_base_shift;

        if (vlq > 0) {
            digit |= vlq_continuation_bit;
        }

        result.buf[result.len] = base64_alphabet[digit];
        result.len += 1;

        if (vlq == 0) break;
    }

    return result;
}

/// Decode a VLQ value from `input`. Returns the decoded value and the number
/// of bytes consumed, or `null` if the input is empty or invalid.
pub fn decodeVlq(input: []const u8) ?struct { value: i32, consumed: usize } {
    if (input.len == 0) return null;

    var vlq: u32 = 0;
    var shift: u5 = 0;
    var consumed: usize = 0;

    for (input) |c| {
        if (c >= 128) return null;

        const digit = base64_values[c];
        if (digit == 0xff) return null;

        const continuation = (digit & @as(u8, @truncate(vlq_continuation_bit))) != 0;
        const payload: u32 = digit & @as(u8, @truncate(vlq_base_mask));

        vlq |= payload << shift;
        shift +|= vlq_base_shift;
        consumed += 1;

        if (!continuation) {
            // Convert from VLQ signed representation.
            const negative = (vlq & vlq_sign_bit) != 0;
            vlq >>= 1;

            return .{
                .value = if (negative) -@as(i32, @intCast(vlq)) else @as(i32, @intCast(vlq)),
                .consumed = consumed,
            };
        }
    }

    // Truncated: continuation bit set but no more data.
    return null;
}

// =========================================================================
// LineIndex
// =========================================================================

/// Pre-computed line-start byte offsets for O(log n) byte-offset to
/// line/column conversion. Standalone from Diagnostic.LineIndex so the
/// source-map module stays self-contained.
pub const LineIndex = struct {
    line_starts: std.ArrayListUnmanaged(u32),

    /// Build a line index by scanning `source` for newlines.
    pub fn init(allocator: std.mem.Allocator, source: []const u8) LineIndex {
        var starts: std.ArrayListUnmanaged(u32) = .empty;
        starts.append(allocator, 0) catch {};

        var i: usize = 0;
        while (i < source.len) : (i += 1) {
            const c = source[i];
            if (c == '\n') {
                const next: u32 = @intCast(i + 1);
                if (next < source.len) {
                    starts.append(allocator, next) catch {};
                }
            } else if (c == '\r') {
                if (i + 1 < source.len and source[i + 1] == '\n') {
                    const next: u32 = @intCast(i + 2);
                    if (next < source.len) {
                        starts.append(allocator, next) catch {};
                    }
                    i += 1; // skip LF
                } else {
                    const next: u32 = @intCast(i + 1);
                    if (next < source.len) {
                        starts.append(allocator, next) catch {};
                    }
                }
            }
        }

        return .{ .line_starts = starts };
    }

    pub fn deinit(self: *LineIndex, allocator: std.mem.Allocator) void {
        self.line_starts.deinit(allocator);
    }

    /// Number of lines in the source.
    pub fn lineCount(self: *const LineIndex) u32 {
        return @intCast(self.line_starts.items.len);
    }

    /// Convert byte offset to 0-based (line, col) where col is in bytes.
    pub fn byteOffsetToLineColumn(self: *const LineIndex, offset: u32) struct { line: u32, col: u32 } {
        const starts = self.line_starts.items;
        if (starts.len == 0) return .{ .line = 0, .col = 0 };

        // Binary search: find last start <= offset.
        var lo: usize = 0;
        var hi: usize = starts.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (starts[mid] > offset) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        const line: u32 = if (lo > 0) @intCast(lo - 1) else 0;
        const col: u32 = offset - starts[line];
        return .{ .line = line, .col = col };
    }

    /// Convert byte offset to 0-based (line, col) where col is in UTF-16
    /// code units, as required by the source map v3 spec.
    pub fn byteOffsetToLineColumnUtf16(self: *const LineIndex, source: []const u8, offset: u32) struct { line: u32, col: u32 } {
        const starts = self.line_starts.items;
        if (starts.len == 0) return .{ .line = 0, .col = 0 };

        const clamped: u32 = if (offset > source.len) @intCast(source.len) else offset;

        // Binary search for the line.
        var lo: usize = 0;
        var hi: usize = starts.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (starts[mid] > clamped) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        const line: u32 = if (lo > 0) @intCast(lo - 1) else 0;
        const line_start = starts[line];

        // Calculate UTF-16 column.
        const col = utf8ToUtf16Column(source[line_start..], clamped - line_start);
        return .{ .line = line, .col = col };
    }

    /// Convert a 0-based (line, col) to byte offset. Col is in bytes.
    pub fn lineColumnToByteOffset(self: *const LineIndex, source_len: u32, line: u32, col: u32) u32 {
        const starts = self.line_starts.items;
        const clamped_line: usize = if (line >= starts.len) starts.len - 1 else line;
        const offset = starts[clamped_line] + col;
        return if (offset > source_len) source_len else offset;
    }
};

/// Count UTF-16 code units for `byte_len` bytes of UTF-8 text.
fn utf8ToUtf16Column(text: []const u8, byte_len: u32) u32 {
    if (byte_len == 0) return 0;
    const end: usize = if (byte_len > text.len) text.len else byte_len;

    var col: u32 = 0;
    var i: usize = 0;
    while (i < end) {
        const byte = text[i];
        const cp_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            // Invalid UTF-8, treat as single byte.
            col += 1;
            i += 1;
            continue;
        };

        if (i + cp_len > end) {
            // Truncated sequence, count remaining bytes individually.
            col += @intCast(end - i);
            break;
        }

        const cp = std.unicode.utf8Decode(text[i..][0..cp_len]) catch {
            col += 1;
            i += 1;
            continue;
        };

        // Supplementary plane codepoints need a surrogate pair (2 UTF-16 units).
        if (cp >= 0x10000) {
            col += 2;
        } else {
            col += 1;
        }

        i += cp_len;
    }

    return col;
}

// =========================================================================
// Mapping
// =========================================================================

/// A single decoded source map mapping.
pub const Mapping = struct {
    gen_line: u32 = 0, // Generated line (0-indexed)
    gen_col: u32 = 0, // Generated column (0-indexed)
    src_index: u32 = 0, // Source file index
    src_line: u32 = 0, // Source line (0-indexed)
    src_col: u32 = 0, // Source column (0-indexed)
    name_index: i32 = -1, // Name index (-1 if no name)
    has_name: bool = false,
};

// =========================================================================
// Generator
// =========================================================================

/// Builds a source map incrementally.
pub const Generator = struct {
    source: []const u8,
    line_index: LineIndex,
    mappings: std.ArrayListUnmanaged(Mapping),
    names: std.StringHashMapUnmanaged(u32),
    names_list: std.ArrayListUnmanaged([]const u8),
    encoded_buf: std.ArrayListUnmanaged(u8),
    file: []const u8,
    source_name: []const u8,
    include_source: bool,
    cover_lines_without_mappings: bool,
    allocator: std.mem.Allocator,
    // Heap-allocated single-element arrays for Result slices
    sources_buf: [][]const u8 = &.{},
    sources_content_buf: [][]const u8 = &.{},

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Generator {
        return .{
            .source = source,
            .line_index = LineIndex.init(allocator, source),
            .mappings = .empty,
            .names = .{},
            .names_list = .empty,
            .encoded_buf = .empty,
            .file = "",
            .source_name = "",
            .include_source = false,
            .cover_lines_without_mappings = true,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Generator) void {
        self.line_index.deinit(self.allocator);
        self.mappings.deinit(self.allocator);
        self.names.deinit(self.allocator);
        self.names_list.deinit(self.allocator);
        self.encoded_buf.deinit(self.allocator);
        if (self.sources_buf.len > 0) self.allocator.free(self.sources_buf);
        if (self.sources_content_buf.len > 0) self.allocator.free(self.sources_content_buf);
    }

    /// Set the generated file name.
    pub fn setFile(self: *Generator, file: []const u8) void {
        self.file = file;
    }

    /// Set the original source file name.
    pub fn setSourceName(self: *Generator, name: []const u8) void {
        self.source_name = name;
    }

    /// Set whether to include original source in sourcesContent.
    pub fn setIncludeSource(self: *Generator, include: bool) void {
        self.include_source = include;
    }

    /// Enable or disable the line-coverage workaround for Mozilla compatibility.
    pub fn setCoverLinesWithoutMappings(self: *Generator, cover: bool) void {
        self.cover_lines_without_mappings = cover;
    }

    /// Add a mapping from generated position to source position.
    /// `gen_line` and `gen_col` are 0-indexed positions in the generated output.
    /// `src_offset` is the byte offset in the original source.
    /// `name` is the original name (empty slice if no name mapping needed).
    pub fn addMapping(self: *Generator, gen_line: u32, gen_col: u32, src_offset: u32, name: []const u8) void {
        const pos = self.line_index.byteOffsetToLineColumnUtf16(self.source, src_offset);

        var m = Mapping{
            .gen_line = gen_line,
            .gen_col = gen_col,
            .src_index = 0, // Single source file.
            .src_line = pos.line,
            .src_col = pos.col,
            .name_index = -1,
            .has_name = false,
        };

        if (name.len > 0) {
            const gop = self.names.getOrPut(self.allocator, name) catch return;
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(self.names_list.items.len);
                self.names_list.append(self.allocator, name) catch {};
            }
            m.name_index = @intCast(gop.value_ptr.*);
            m.has_name = true;
        }

        self.mappings.append(self.allocator, m) catch {};
    }

    /// Encode all mappings as a VLQ string with delta compression.
    /// The returned slice is owned by the Generator and valid until the
    /// next call to `encodeMappings` or `deinit`.
    pub fn encodeMappings(self: *Generator) []const u8 {
        if (self.mappings.items.len == 0) return "";

        self.encoded_buf.clearRetainingCapacity();
        const buf = &self.encoded_buf;

        // Delta encoding state.
        var prev_gen_col: i32 = 0;
        var prev_src_index: i32 = 0;
        var prev_src_line: i32 = 0;
        var prev_src_col: i32 = 0;
        var prev_name_index: i32 = 0;

        var current_line: u32 = 0;
        var first_on_line: bool = true;

        var last_mapping: ?*const Mapping = null;

        for (self.mappings.items) |*m| {
            // Emit semicolons for skipped lines.
            while (current_line < m.gen_line) {
                buf.append(self.allocator, ';') catch {};
                current_line += 1;
                prev_gen_col = 0;
                first_on_line = true;

                // Line coverage workaround: fill empty lines with a mapping at col 0.
                if (current_line < m.gen_line and self.cover_lines_without_mappings) {
                    if (last_mapping) |lm| {
                        encodeVlq(buf, self.allocator, 0 - prev_gen_col);
                        prev_gen_col = 0;
                        encodeVlq(buf, self.allocator, @as(i32, @intCast(lm.src_index)) - prev_src_index);
                        prev_src_index = @intCast(lm.src_index);
                        encodeVlq(buf, self.allocator, @as(i32, @intCast(lm.src_line)) - prev_src_line);
                        prev_src_line = @intCast(lm.src_line);
                        encodeVlq(buf, self.allocator, @as(i32, @intCast(lm.src_col)) - prev_src_col);
                        prev_src_col = @intCast(lm.src_col);
                        first_on_line = false;
                    }
                }
            }

            // Comma separator between segments on the same line.
            if (!first_on_line) {
                buf.append(self.allocator, ',') catch {};
            }
            first_on_line = false;

            // Field 1: generated column (delta).
            encodeVlq(buf, self.allocator, @as(i32, @intCast(m.gen_col)) - prev_gen_col);
            prev_gen_col = @intCast(m.gen_col);

            // Field 2: source index (delta).
            encodeVlq(buf, self.allocator, @as(i32, @intCast(m.src_index)) - prev_src_index);
            prev_src_index = @intCast(m.src_index);

            // Field 3: source line (delta).
            encodeVlq(buf, self.allocator, @as(i32, @intCast(m.src_line)) - prev_src_line);
            prev_src_line = @intCast(m.src_line);

            // Field 4: source column (delta).
            encodeVlq(buf, self.allocator, @as(i32, @intCast(m.src_col)) - prev_src_col);
            prev_src_col = @intCast(m.src_col);

            // Field 5: name index (delta, only if has name).
            if (m.has_name) {
                encodeVlq(buf, self.allocator, m.name_index - prev_name_index);
                prev_name_index = m.name_index;
            }

            last_mapping = m;
        }

        return buf.items;
    }

    /// Produce the final SourceMap result. The returned Result borrows
    /// data from the Generator; it is valid until the Generator is
    /// deinitialized or `encodeMappings`/`generate` is called again.
    pub fn generate(self: *Generator) Result {
        const mappings_str = self.encodeMappings();

        // Build heap-allocated sources array
        if (self.source_name.len > 0) {
            if (self.allocator.alloc([]const u8, 1)) |buf| {
                buf[0] = self.source_name;
                self.sources_buf = buf;
            } else |_| {}
        }

        // Build heap-allocated sourcesContent array
        if (self.include_source and self.source.len > 0) {
            if (self.allocator.alloc([]const u8, 1)) |buf| {
                buf[0] = self.source;
                self.sources_content_buf = buf;
            } else |_| {}
        }

        return .{
            .version = 3,
            .file = self.file,
            .sources = self.sources_buf,
            .sources_content = self.sources_content_buf,
            .names = self.names_list.items,
            .mappings = mappings_str,
        };
    }
};

// =========================================================================
// Result (Source Map v3)
// =========================================================================

/// A Source Map v3 structure.
pub const Result = struct {
    version: u32 = 3,
    file: []const u8 = "",
    sources: []const []const u8 = &.{},
    sources_content: []const []const u8 = &.{},
    names: []const []const u8 = &.{},
    mappings: []const u8 = "",

    /// Serialize to JSON, appending to `buf`.
    pub fn toJson(self: *const Result, buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) void {
        appendStr(buf, allocator, "{\"version\":");
        appendInt(buf, allocator, self.version);

        if (self.file.len > 0) {
            appendStr(buf, allocator, ",\"file\":");
            appendJsonString(buf, allocator, self.file);
        }

        appendStr(buf, allocator, ",\"sources\":");
        appendJsonStringArray(buf, allocator, self.sources);

        if (self.sources_content.len > 0) {
            appendStr(buf, allocator, ",\"sourcesContent\":");
            appendJsonStringArray(buf, allocator, self.sources_content);
        }

        appendStr(buf, allocator, ",\"names\":");
        appendJsonStringArray(buf, allocator, self.names);

        appendStr(buf, allocator, ",\"mappings\":");
        appendJsonString(buf, allocator, self.mappings);

        appendStr(buf, allocator, "}");
    }

    /// Serialize to a data URI (`data:application/json;base64,...`).
    pub fn toDataUri(self: *const Result, buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) void {
        // First produce the JSON into a temporary buffer.
        var json_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer json_buf.deinit(allocator);
        self.toJson(&json_buf, allocator);

        appendStr(buf, allocator, "data:application/json;base64,");

        // Base64-encode the JSON.
        const encoder = std.base64.standard.Encoder;
        const encoded_len = encoder.calcSize(json_buf.items.len);
        buf.ensureTotalCapacity(allocator, buf.items.len + encoded_len) catch {};
        const dest = buf.items.ptr[buf.items.len .. buf.items.len + encoded_len];
        _ = encoder.encode(dest, json_buf.items);
        buf.items.len += encoded_len;
    }

    /// Return a source-mapping comment for appending to generated code.
    /// When `inline_uri` is true, emits a data URI; otherwise emits a file reference.
    pub fn toComment(self: *const Result, buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, inline_uri: bool) void {
        appendStr(buf, allocator, "//# sourceMappingURL=");
        if (inline_uri) {
            self.toDataUri(buf, allocator);
        } else {
            appendStr(buf, allocator, self.file);
            appendStr(buf, allocator, ".map");
        }
    }
};

// =========================================================================
// Decode mappings
// =========================================================================

/// Result of decoding a mappings string. Call `deinit` to free.
pub const DecodedMappings = struct {
    items: []Mapping,
    list: std.ArrayListUnmanaged(Mapping),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DecodedMappings) void {
        self.list.deinit(self.allocator);
    }
};

/// Decode a VLQ-encoded mappings string into a list of Mapping values.
pub fn decodeMappings(allocator: std.mem.Allocator, mappings: []const u8) DecodedMappings {
    if (mappings.len == 0) return .{ .items = &.{}, .list = .empty, .allocator = allocator };

    var result: std.ArrayListUnmanaged(Mapping) = .empty;

    // Delta state.
    var gen_col: i32 = 0;
    var src_index: i32 = 0;
    var src_line: i32 = 0;
    var src_col: i32 = 0;
    var name_index: i32 = 0;

    var gen_line: u32 = 0;
    var i: usize = 0;

    while (i < mappings.len) {
        const c = mappings[i];
        if (c == ';') {
            gen_line += 1;
            gen_col = 0;
            i += 1;
            continue;
        }
        if (c == ',') {
            i += 1;
            continue;
        }

        // Decode segment fields.
        var field_count: u32 = 0;
        var fields: [5]i32 = .{ 0, 0, 0, 0, 0 };

        while (i < mappings.len and mappings[i] != ';' and mappings[i] != ',') {
            if (field_count >= 5) break;
            if (decodeVlq(mappings[i..])) |decoded| {
                fields[field_count] = decoded.value;
                field_count += 1;
                i += decoded.consumed;
            } else {
                // Skip invalid byte.
                i += 1;
                break;
            }
        }

        if (field_count == 0) continue;

        gen_col += fields[0];
        var m = Mapping{
            .gen_line = gen_line,
            .gen_col = @intCast(@as(u32, @bitCast(gen_col))),
            .name_index = -1,
            .has_name = false,
        };

        if (field_count >= 4) {
            src_index += fields[1];
            src_line += fields[2];
            src_col += fields[3];
            m.src_index = @intCast(@as(u32, @bitCast(src_index)));
            m.src_line = @intCast(@as(u32, @bitCast(src_line)));
            m.src_col = @intCast(@as(u32, @bitCast(src_col)));
        }

        if (field_count >= 5) {
            name_index += fields[4];
            m.name_index = name_index;
            m.has_name = true;
        }

        result.append(allocator, m) catch {};
    }

    return .{ .items = result.items, .list = result, .allocator = allocator };
}

// =========================================================================
// JSON helpers
// =========================================================================

fn appendStr(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, s: []const u8) void {
    buf.appendSlice(allocator, s) catch {};
}

fn appendInt(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u32) void {
    var tmp: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch return;
    appendStr(buf, allocator, s);
}

fn appendJsonString(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, s: []const u8) void {
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
                    // Control character — emit \u00XX.
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

fn appendJsonStringArray(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, items: []const []const u8) void {
    buf.append(allocator, '[') catch {};
    for (items, 0..) |item, idx| {
        if (idx > 0) buf.append(allocator, ',') catch {};
        appendJsonString(buf, allocator, item);
    }
    buf.append(allocator, ']') catch {};
}

// =========================================================================
// Tests
// =========================================================================

test "VLQ encode/decode round-trip" {
    const allocator = std.testing.allocator;
    const test_values = [_]i32{ 0, 1, -1, 5, -5, 15, -15, 16, -16, 31, 100, -100, 1000, -1000, 100000, -100000 };

    for (test_values) |val| {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);

        encodeVlq(&buf, allocator, val);

        const decoded = decodeVlq(buf.items) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(val, decoded.value);
        try std.testing.expectEqual(buf.items.len, decoded.consumed);
    }
}

test "VLQ encode known values" {
    const allocator = std.testing.allocator;

    // 0 -> 'A' (vlq=0, digit=0)
    {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        encodeVlq(&buf, allocator, 0);
        try std.testing.expectEqualStrings("A", buf.items);
    }
    // 1 -> 'C' (vlq=2, digit=2)
    {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        encodeVlq(&buf, allocator, 1);
        try std.testing.expectEqualStrings("C", buf.items);
    }
    // -1 -> 'D' (vlq=3, digit=3)
    {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        encodeVlq(&buf, allocator, -1);
        try std.testing.expectEqualStrings("D", buf.items);
    }
}

test "VLQ decode invalid input" {
    try std.testing.expect(decodeVlq("") == null);
    try std.testing.expect(decodeVlq("!!!") == null);
}

test "LineIndex basic" {
    const allocator = std.testing.allocator;
    var li = LineIndex.init(allocator, "abc\ndef\nghi");
    defer li.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 3), li.lineCount());

    // Line 0: "abc\n"
    const pos0 = li.byteOffsetToLineColumn(0);
    try std.testing.expectEqual(@as(u32, 0), pos0.line);
    try std.testing.expectEqual(@as(u32, 0), pos0.col);

    const pos1 = li.byteOffsetToLineColumn(2);
    try std.testing.expectEqual(@as(u32, 0), pos1.line);
    try std.testing.expectEqual(@as(u32, 2), pos1.col);

    // Line 1: "def\n"
    const pos2 = li.byteOffsetToLineColumn(4);
    try std.testing.expectEqual(@as(u32, 1), pos2.line);
    try std.testing.expectEqual(@as(u32, 0), pos2.col);

    // Line 2: "ghi"
    const pos3 = li.byteOffsetToLineColumn(8);
    try std.testing.expectEqual(@as(u32, 2), pos3.line);
    try std.testing.expectEqual(@as(u32, 0), pos3.col);
}

test "LineIndex single line" {
    const allocator = std.testing.allocator;
    var li = LineIndex.init(allocator, "hello");
    defer li.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), li.lineCount());

    const pos = li.byteOffsetToLineColumn(3);
    try std.testing.expectEqual(@as(u32, 0), pos.line);
    try std.testing.expectEqual(@as(u32, 3), pos.col);
}

test "LineIndex empty source" {
    const allocator = std.testing.allocator;
    var li = LineIndex.init(allocator, "");
    defer li.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), li.lineCount());
    const pos = li.byteOffsetToLineColumn(0);
    try std.testing.expectEqual(@as(u32, 0), pos.line);
    try std.testing.expectEqual(@as(u32, 0), pos.col);
}

test "LineIndex UTF-16 column for ASCII" {
    const allocator = std.testing.allocator;
    const source = "abc\ndef";
    var li = LineIndex.init(allocator, source);
    defer li.deinit(allocator);

    // ASCII: UTF-16 column == byte column.
    const pos = li.byteOffsetToLineColumnUtf16(source, 5);
    try std.testing.expectEqual(@as(u32, 1), pos.line);
    try std.testing.expectEqual(@as(u32, 1), pos.col);
}

test "Generator produces valid mappings" {
    const allocator = std.testing.allocator;
    const source = "fn main() {}";
    var gen = Generator.init(allocator, source);
    defer gen.deinit();

    gen.setFile("out.wgsl");
    gen.setSourceName("in.wgsl");

    // Map generated 0:0 to source offset 0.
    gen.addMapping(0, 0, 0, "");
    // Map generated 0:3 to source offset 3.
    gen.addMapping(0, 3, 3, "");

    const result = gen.generate();
    try std.testing.expectEqual(@as(u32, 3), result.version);
    try std.testing.expectEqualStrings("out.wgsl", result.file);
    try std.testing.expect(result.mappings.len > 0);
}

test "Result toJson" {
    const allocator = std.testing.allocator;
    const result = Result{
        .version = 3,
        .file = "out.wgsl",
        .sources = &.{"in.wgsl"},
        .names = &.{},
        .mappings = "AAAA",
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    result.toJson(&buf, allocator);

    // Should be valid JSON with expected fields.
    const json = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"version\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"file\":\"out.wgsl\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mappings\":\"AAAA\"") != null);
}

test "Result toDataUri" {
    const allocator = std.testing.allocator;
    const result = Result{
        .version = 3,
        .mappings = "AAAA",
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    result.toDataUri(&buf, allocator);

    try std.testing.expect(std.mem.startsWith(u8, buf.items, "data:application/json;base64,"));
}

test "decodeMappings round-trip" {
    const allocator = std.testing.allocator;
    const source = "fn main() {\n  return;\n}";
    var gen = Generator.init(allocator, source);
    defer gen.deinit();

    gen.setSourceName("test.wgsl");
    gen.setCoverLinesWithoutMappings(false);

    gen.addMapping(0, 0, 0, "");
    gen.addMapping(0, 3, 3, "main");
    gen.addMapping(1, 2, 14, "");
    gen.addMapping(2, 0, 22, "");

    const result = gen.generate();
    var decoded = decodeMappings(allocator, result.mappings);
    defer decoded.deinit();

    // Should have at least 4 mappings.
    try std.testing.expect(decoded.items.len >= 4);

    // First mapping: gen 0:0 -> src 0:0
    try std.testing.expectEqual(@as(u32, 0), decoded.items[0].gen_line);
    try std.testing.expectEqual(@as(u32, 0), decoded.items[0].gen_col);
    try std.testing.expectEqual(@as(u32, 0), decoded.items[0].src_line);
    try std.testing.expectEqual(@as(u32, 0), decoded.items[0].src_col);
}

// =========================================================================
// Additional VLQ tests
// =========================================================================

test "VLQ large values" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    // Large positive
    encodeVlq(&buf, std.testing.allocator, 100000);
    const d1 = decodeVlq(buf.items);
    try std.testing.expect(d1 != null);
    try std.testing.expectEqual(@as(i32, 100000), d1.?.value);

    // Large negative
    buf.clearRetainingCapacity();
    encodeVlq(&buf, std.testing.allocator, -100000);
    const d2 = decodeVlq(buf.items);
    try std.testing.expect(d2 != null);
    try std.testing.expectEqual(@as(i32, -100000), d2.?.value);
}

test "VLQ base64 alphabet covers 64 chars" {
    try std.testing.expectEqual(@as(usize, 64), base64_alphabet.len);
}

test "VLQ fast path small positive via encode/decode" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    // Value 0 should encode to single char 'A'
    encodeVlq(&buf, std.testing.allocator, 0);
    try std.testing.expectEqual(@as(usize, 1), buf.items.len);
    try std.testing.expectEqual(@as(u8, 'A'), buf.items[0]);
}

test "VLQ fast path small negative via encode/decode" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    encodeVlq(&buf, std.testing.allocator, -1);
    try std.testing.expectEqual(@as(usize, 1), buf.items.len);
    try std.testing.expectEqual(@as(u8, 'D'), buf.items[0]);
}

test "VLQ boundary value 15" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    encodeVlq(&buf, std.testing.allocator, 15);
    try std.testing.expectEqual(@as(usize, 1), buf.items.len);
}

test "VLQ decode invalid high byte" {
    const result = decodeVlq(&[_]u8{0xFF});
    try std.testing.expect(result == null);
}

test "VLQ decode invalid base64 char" {
    const result = decodeVlq(&[_]u8{'!'});
    try std.testing.expect(result == null);
}

test "VLQ decode sequence" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    // Encode multiple values
    encodeVlq(&buf, std.testing.allocator, 5);
    encodeVlq(&buf, std.testing.allocator, -3);
    encodeVlq(&buf, std.testing.allocator, 0);

    // Decode sequentially
    var offset: usize = 0;
    const d1 = decodeVlq(buf.items[offset..]);
    try std.testing.expect(d1 != null);
    try std.testing.expectEqual(@as(i32, 5), d1.?.value);
    offset += d1.?.consumed;

    const d2 = decodeVlq(buf.items[offset..]);
    try std.testing.expect(d2 != null);
    try std.testing.expectEqual(@as(i32, -3), d2.?.value);
    offset += d2.?.consumed;

    const d3 = decodeVlq(buf.items[offset..]);
    try std.testing.expect(d3 != null);
    try std.testing.expectEqual(@as(i32, 0), d3.?.value);
}

// =========================================================================
// Additional LineIndex / Position tests
// =========================================================================

test "LineIndex CRLF newlines" {
    const allocator = std.testing.allocator;
    const source = "line1\r\nline2\r\nline3";
    const li = LineIndex.init(allocator, source);
    defer @constCast(&li).line_starts.deinit(allocator);

    // Should have 3 lines
    try std.testing.expectEqual(@as(usize, 3), li.line_starts.items.len);
}

test "LineIndex CR-only newlines" {
    const allocator = std.testing.allocator;
    const source = "line1\rline2\rline3";
    const li = LineIndex.init(allocator, source);
    defer @constCast(&li).line_starts.deinit(allocator);

    // Should have 3 lines
    try std.testing.expectEqual(@as(usize, 3), li.line_starts.items.len);
}

test "LineIndex UTF-8 multibyte" {
    const allocator = std.testing.allocator;
    // "héllo" has a 2-byte character
    const source = "h\xc3\xa9llo\nworld";
    const li = LineIndex.init(allocator, source);
    defer @constCast(&li).line_starts.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), li.line_starts.items.len);
    // First line starts at 0, second at byte after \n
    try std.testing.expectEqual(@as(u32, 0), li.line_starts.items[0]);
}

test "LineIndex byteOffsetToLineColumn out of bounds" {
    const allocator = std.testing.allocator;
    const source = "hello";
    const li = LineIndex.init(allocator, source);
    defer @constCast(&li).line_starts.deinit(allocator);

    // Out of bounds offset should clamp
    const pos = li.byteOffsetToLineColumn(1000);
    // Should not crash, return something reasonable
    _ = pos;
}

test "LineIndex many lines" {
    const allocator = std.testing.allocator;
    // Build a source with many lines
    var buf: [1000]u8 = undefined;
    var i: usize = 0;
    var line_count: usize = 0;
    while (i + 2 < buf.len) {
        buf[i] = 'a';
        buf[i + 1] = '\n';
        i += 2;
        line_count += 1;
    }

    const li = LineIndex.init(allocator, buf[0..i]);
    defer @constCast(&li).line_starts.deinit(allocator);

    try std.testing.expectEqual(line_count, li.line_starts.items.len);
}

test "LineIndex reverse lookup" {
    const allocator = std.testing.allocator;
    const source = "fn main() {\n  return;\n}";
    const li = LineIndex.init(allocator, source);
    defer @constCast(&li).line_starts.deinit(allocator);

    // Byte offset 0 -> line 0, col 0
    const pos0 = li.byteOffsetToLineColumn(0);
    try std.testing.expectEqual(@as(u32, 0), pos0.line);
    try std.testing.expectEqual(@as(u32, 0), pos0.col);

    // Byte offset at start of "return" (14) -> line 1
    const pos1 = li.byteOffsetToLineColumn(14);
    try std.testing.expectEqual(@as(u32, 1), pos1.line);
}

// =========================================================================
// Additional Generator / decodeMappings tests
// =========================================================================

test "Generator name deduplication" {
    const allocator = std.testing.allocator;
    const source = "fn foo() { let x = foo(); }";
    var gen = Generator.init(allocator, source);
    defer gen.deinit();

    gen.addMapping(0, 0, 0, "foo");
    gen.addMapping(0, 19, 19, "foo"); // same name again

    const result = gen.generate();
    // "foo" should appear only once in names array
    try std.testing.expectEqual(@as(usize, 1), result.names.len);
}

test "Generator mapping without name" {
    const allocator = std.testing.allocator;
    const source = "fn foo() {}";
    var gen = Generator.init(allocator, source);
    defer gen.deinit();

    gen.addMapping(0, 0, 0, "");
    gen.addMapping(0, 3, 3, "");

    const result = gen.generate();
    // No names when all mappings have empty name
    try std.testing.expectEqual(@as(usize, 0), result.names.len);
}

test "Generator empty source" {
    const allocator = std.testing.allocator;
    var gen = Generator.init(allocator, "");
    defer gen.deinit();

    const result = gen.generate();
    try std.testing.expectEqual(@as(u32, 3), result.version);
}

test "Generator file and sources content" {
    const allocator = std.testing.allocator;
    const source = "fn foo() {}";
    var gen = Generator.init(allocator, source);
    defer gen.deinit();

    gen.setFile("shader.min.wgsl");
    gen.setSourceName("shader.wgsl");
    gen.setIncludeSource(true);

    const result = gen.generate();
    try std.testing.expectEqualStrings("shader.min.wgsl", result.file);
    try std.testing.expect(result.sources.len > 0);
    try std.testing.expect(result.sources_content.len > 0);
}

test "decodeMappings empty" {
    const decoded = decodeMappings(std.testing.allocator, "");
    defer @constCast(&decoded).deinit();
    try std.testing.expectEqual(@as(usize, 0), decoded.items.len);
}

test "decodeMappings semicolons produce line breaks" {
    const decoded = decodeMappings(std.testing.allocator, "AAAA;AACA");
    defer @constCast(&decoded).deinit();
    // Should have entries on different lines
    try std.testing.expect(decoded.items.len >= 2);
    if (decoded.items.len >= 2) {
        try std.testing.expectEqual(@as(u32, 0), decoded.items[0].gen_line);
        try std.testing.expectEqual(@as(u32, 1), decoded.items[1].gen_line);
    }
}

test "decodeMappings with name index" {
    // AAAA has 4 segments: gen_col=0, src_idx=0, src_line=0, src_col=0
    // AAAAA has 5 segments: gen_col=0, src_idx=0, src_line=0, src_col=0, name_idx=0
    const decoded = decodeMappings(std.testing.allocator, "AAAAA");
    defer @constCast(&decoded).deinit();
    try std.testing.expect(decoded.items.len >= 1);
    try std.testing.expectEqual(@as(i32, 0), decoded.items[0].name_index);
}

// =========================================================================
// VLQ encode known positive values (from Go TestVLQEncodePositive)
// =========================================================================

test "VLQ encode known positive values" {
    const allocator = std.testing.allocator;
    const cases = .{
        .{ @as(i32, 2), "E" },
        .{ @as(i32, 3), "G" },
        .{ @as(i32, 15), "e" },
        .{ @as(i32, 16), "gB" },
        .{ @as(i32, 31), "+B" },
        .{ @as(i32, 32), "gC" },
        .{ @as(i32, 100), "oG" },
        .{ @as(i32, 1000), "w+B" },
    };

    inline for (cases) |c| {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        encodeVlq(&buf, allocator, c[0]);
        try std.testing.expectEqualStrings(c[1], buf.items);
    }
}

test "VLQ encode known negative values" {
    const allocator = std.testing.allocator;
    const cases = .{
        .{ @as(i32, -2), "F" },
        .{ @as(i32, -15), "f" },
        .{ @as(i32, -16), "hB" },
        .{ @as(i32, -31), "/B" },
        .{ @as(i32, -32), "hC" },
        .{ @as(i32, -100), "pG" },
        .{ @as(i32, -1000), "x+B" },
    };

    inline for (cases) |c| {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        encodeVlq(&buf, allocator, c[0]);
        try std.testing.expectEqualStrings(c[1], buf.items);
    }
}

// =========================================================================
// VLQ fast path: values 0-15 produce single char, 16 needs two
// =========================================================================

test "VLQ fast path small positive all single char" {
    const allocator = std.testing.allocator;
    var v: i32 = 0;
    while (v <= 15) : (v += 1) {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        encodeVlq(&buf, allocator, v);
        try std.testing.expectEqual(@as(usize, 1), buf.items.len);
    }
}

test "VLQ fast path small negative all single char" {
    const allocator = std.testing.allocator;
    var v: i32 = -1;
    while (v >= -15) : (v -= 1) {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        encodeVlq(&buf, allocator, v);
        try std.testing.expectEqual(@as(usize, 1), buf.items.len);
    }
}

test "VLQ fast path boundary 16 needs two digits" {
    const allocator = std.testing.allocator;
    {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        encodeVlq(&buf, allocator, 16);
        try std.testing.expectEqual(@as(usize, 2), buf.items.len);
    }
    {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        encodeVlq(&buf, allocator, -16);
        try std.testing.expectEqual(@as(usize, 2), buf.items.len);
    }
}

// =========================================================================
// VLQ decode edge cases
// =========================================================================

test "VLQ decode multiple invalid base64 chars" {
    const invalid = [_][]const u8{ "@", "#", "$", "%", "^", "&", "*", "(", ")", "-", "_" };
    for (invalid) |ch| {
        try std.testing.expect(decodeVlq(ch) == null);
    }
}

test "VLQ decode truncated continuation" {
    // 'g' is index 32, which has the continuation bit set. Alone it is truncated.
    try std.testing.expect(decodeVlq("g") == null);
}

// =========================================================================
// LineIndex detailed multi-line positions (from Go TestLineIndexMultiLine)
// =========================================================================

test "LineIndex multi-line detailed positions" {
    const allocator = std.testing.allocator;
    const source = "const x = 1;\nconst y = 2;\nconst z = 3;";
    var li = LineIndex.init(allocator, source);
    defer li.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 3), li.lineCount());

    // Line 0
    {
        const p = li.byteOffsetToLineColumn(0);
        try std.testing.expectEqual(@as(u32, 0), p.line);
        try std.testing.expectEqual(@as(u32, 0), p.col);
    }
    {
        const p = li.byteOffsetToLineColumn(6);
        try std.testing.expectEqual(@as(u32, 0), p.line);
        try std.testing.expectEqual(@as(u32, 6), p.col);
    }
    {
        const p = li.byteOffsetToLineColumn(12);
        try std.testing.expectEqual(@as(u32, 0), p.line);
        try std.testing.expectEqual(@as(u32, 12), p.col);
    }
    // Line 1 (starts at byte 13 after \n)
    {
        const p = li.byteOffsetToLineColumn(13);
        try std.testing.expectEqual(@as(u32, 1), p.line);
        try std.testing.expectEqual(@as(u32, 0), p.col);
    }
    {
        const p = li.byteOffsetToLineColumn(19);
        try std.testing.expectEqual(@as(u32, 1), p.line);
        try std.testing.expectEqual(@as(u32, 6), p.col);
    }
    // Line 2 (starts at byte 26)
    {
        const p = li.byteOffsetToLineColumn(26);
        try std.testing.expectEqual(@as(u32, 2), p.line);
        try std.testing.expectEqual(@as(u32, 0), p.col);
    }
    {
        const p = li.byteOffsetToLineColumn(32);
        try std.testing.expectEqual(@as(u32, 2), p.line);
        try std.testing.expectEqual(@as(u32, 6), p.col);
    }
}

// =========================================================================
// LineIndex CRLF detailed positions (from Go TestLineIndexCRLFPositions)
// =========================================================================

test "LineIndex CRLF detailed positions" {
    const allocator = std.testing.allocator;
    // "ab\r\ncd\r\nef"
    const source = "ab\r\ncd\r\nef";
    var li = LineIndex.init(allocator, source);
    defer li.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 3), li.lineCount());

    // 'a' at byte 0 -> line 0, col 0
    {
        const p = li.byteOffsetToLineColumn(0);
        try std.testing.expectEqual(@as(u32, 0), p.line);
        try std.testing.expectEqual(@as(u32, 0), p.col);
    }
    // 'b' at byte 1 -> line 0, col 1
    {
        const p = li.byteOffsetToLineColumn(1);
        try std.testing.expectEqual(@as(u32, 0), p.line);
        try std.testing.expectEqual(@as(u32, 1), p.col);
    }
    // 'c' at byte 4 -> line 1, col 0
    {
        const p = li.byteOffsetToLineColumn(4);
        try std.testing.expectEqual(@as(u32, 1), p.line);
        try std.testing.expectEqual(@as(u32, 0), p.col);
    }
    // 'd' at byte 5 -> line 1, col 1
    {
        const p = li.byteOffsetToLineColumn(5);
        try std.testing.expectEqual(@as(u32, 1), p.line);
        try std.testing.expectEqual(@as(u32, 1), p.col);
    }
    // 'e' at byte 8 -> line 2, col 0
    {
        const p = li.byteOffsetToLineColumn(8);
        try std.testing.expectEqual(@as(u32, 2), p.line);
        try std.testing.expectEqual(@as(u32, 0), p.col);
    }
}

// =========================================================================
// LineIndex UTF-16 emoji/multibyte tests (from Go position_test.go)
// =========================================================================

test "LineIndex UTF-16 emoji column" {
    const allocator = std.testing.allocator;
    // "a😀b" - 😀 is 4 UTF-8 bytes, 2 UTF-16 code units
    const source = "a\xf0\x9f\x98\x80b";
    var li = LineIndex.init(allocator, source);
    defer li.deinit(allocator);

    // 'a' at byte 0 -> UTF-16 col 0
    {
        const p = li.byteOffsetToLineColumnUtf16(source, 0);
        try std.testing.expectEqual(@as(u32, 0), p.col);
    }
    // 😀 at byte 1 -> UTF-16 col 1
    {
        const p = li.byteOffsetToLineColumnUtf16(source, 1);
        try std.testing.expectEqual(@as(u32, 1), p.col);
    }
    // 'b' at byte 5 -> UTF-16 col 3 (1 for 'a' + 2 for 😀)
    {
        const p = li.byteOffsetToLineColumnUtf16(source, 5);
        try std.testing.expectEqual(@as(u32, 3), p.col);
    }
}

test "LineIndex UTF-16 multiple emojis" {
    const allocator = std.testing.allocator;
    // "a👍👎b" - each emoji is 4 UTF-8 bytes, 2 UTF-16 code units
    const source = "a\xf0\x9f\x91\x8d\xf0\x9f\x91\x8eb";
    var li = LineIndex.init(allocator, source);
    defer li.deinit(allocator);

    // 'a' at byte 0 -> col 0
    {
        const p = li.byteOffsetToLineColumnUtf16(source, 0);
        try std.testing.expectEqual(@as(u32, 0), p.col);
    }
    // 👍 at byte 1 -> col 1
    {
        const p = li.byteOffsetToLineColumnUtf16(source, 1);
        try std.testing.expectEqual(@as(u32, 1), p.col);
    }
    // 👎 at byte 5 -> col 3
    {
        const p = li.byteOffsetToLineColumnUtf16(source, 5);
        try std.testing.expectEqual(@as(u32, 3), p.col);
    }
    // 'b' at byte 9 -> col 5
    {
        const p = li.byteOffsetToLineColumnUtf16(source, 9);
        try std.testing.expectEqual(@as(u32, 5), p.col);
    }
}

test "LineIndex UTF-16 mixed BMP content" {
    const allocator = std.testing.allocator;
    // "café" - 'é' is 2 UTF-8 bytes but 1 UTF-16 code unit (BMP)
    const source = "caf\xc3\xa9";
    var li = LineIndex.init(allocator, source);
    defer li.deinit(allocator);

    // 'c' byte 0 -> col 0
    {
        const p = li.byteOffsetToLineColumnUtf16(source, 0);
        try std.testing.expectEqual(@as(u32, 0), p.col);
    }
    // 'a' byte 1 -> col 1
    {
        const p = li.byteOffsetToLineColumnUtf16(source, 1);
        try std.testing.expectEqual(@as(u32, 1), p.col);
    }
    // 'f' byte 2 -> col 2
    {
        const p = li.byteOffsetToLineColumnUtf16(source, 2);
        try std.testing.expectEqual(@as(u32, 2), p.col);
    }
    // 'é' byte 3 -> col 3
    {
        const p = li.byteOffsetToLineColumnUtf16(source, 3);
        try std.testing.expectEqual(@as(u32, 3), p.col);
    }
}

test "LineIndex UTF-16 clamp out of bounds" {
    const allocator = std.testing.allocator;
    const source = "abc";
    var li = LineIndex.init(allocator, source);
    defer li.deinit(allocator);

    const pos = li.byteOffsetToLineColumnUtf16(source, 100);
    try std.testing.expectEqual(@as(u32, 0), pos.line);
    try std.testing.expectEqual(@as(u32, 3), pos.col);
}

test "LineIndex UTF-16 empty source" {
    const allocator = std.testing.allocator;
    const source = "";
    var li = LineIndex.init(allocator, source);
    defer li.deinit(allocator);

    const pos = li.byteOffsetToLineColumnUtf16(source, 0);
    try std.testing.expectEqual(@as(u32, 0), pos.line);
    try std.testing.expectEqual(@as(u32, 0), pos.col);
}

// =========================================================================
// LineIndex lineColumnToByteOffset (from Go TestLineColumnToByteOffset*)
// =========================================================================

test "LineIndex lineColumnToByteOffset basic" {
    const allocator = std.testing.allocator;
    const source = "const x = 1;\nconst y = 2;\n";
    var li = LineIndex.init(allocator, source);
    defer li.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 0), li.lineColumnToByteOffset(@intCast(source.len), 0, 0));
    try std.testing.expectEqual(@as(u32, 6), li.lineColumnToByteOffset(@intCast(source.len), 0, 6));
    try std.testing.expectEqual(@as(u32, 13), li.lineColumnToByteOffset(@intCast(source.len), 1, 0));
    try std.testing.expectEqual(@as(u32, 19), li.lineColumnToByteOffset(@intCast(source.len), 1, 6));
}

test "LineIndex lineColumnToByteOffset line out of bounds clamp" {
    const allocator = std.testing.allocator;
    const source = "abc\ndef\n";
    var li = LineIndex.init(allocator, source);
    defer li.deinit(allocator);

    // Line 100 should clamp to last line (line 1 starts at byte 4)
    const offset = li.lineColumnToByteOffset(@intCast(source.len), 100, 0);
    try std.testing.expectEqual(@as(u32, 4), offset);
}

test "LineIndex lineColumnToByteOffset column out of bounds clamp" {
    const allocator = std.testing.allocator;
    const source = "abc";
    var li = LineIndex.init(allocator, source);
    defer li.deinit(allocator);

    // Column 100 should clamp to source length
    const offset = li.lineColumnToByteOffset(@intCast(source.len), 0, 100);
    try std.testing.expectEqual(@as(u32, 3), offset);
}

// =========================================================================
// Generator single mapping with decode verification
// (from Go TestSourceMapSingleMapping)
// =========================================================================

test "Generator single mapping decode verification" {
    const allocator = std.testing.allocator;
    const source = "const x = 1;";
    var gen = Generator.init(allocator, source);
    defer gen.deinit();

    gen.addMapping(0, 6, 6, "x");

    const result = gen.generate();
    try std.testing.expectEqual(@as(usize, 1), result.names.len);
    try std.testing.expectEqualStrings("x", result.names[0]);
    try std.testing.expect(result.mappings.len > 0);

    var decoded = decodeMappings(allocator, result.mappings);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(usize, 1), decoded.items.len);

    const m = decoded.items[0];
    try std.testing.expectEqual(@as(u32, 0), m.gen_line);
    try std.testing.expectEqual(@as(u32, 6), m.gen_col);
    try std.testing.expectEqual(@as(u32, 0), m.src_line);
    try std.testing.expectEqual(@as(u32, 6), m.src_col);
    try std.testing.expect(m.has_name);
    try std.testing.expectEqual(@as(i32, 0), m.name_index);
}

// =========================================================================
// Generator multiple mappings same line
// (from Go TestSourceMapMultipleMappingsSameLine)
// =========================================================================

test "Generator multiple mappings same line" {
    const allocator = std.testing.allocator;
    const source = "const a = b + c;";
    var gen = Generator.init(allocator, source);
    defer gen.deinit();

    gen.addMapping(0, 6, 6, "a");
    gen.addMapping(0, 10, 10, "b");
    gen.addMapping(0, 14, 14, "c");

    const result = gen.generate();
    try std.testing.expectEqual(@as(usize, 3), result.names.len);

    // Single line: should not contain semicolons, should contain commas
    try std.testing.expect(std.mem.indexOf(u8, result.mappings, ";") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.mappings, ",") != null);
}

// =========================================================================
// Generator multiple lines
// (from Go TestSourceMapMultipleLines)
// =========================================================================

test "Generator multiple lines semicolons" {
    const allocator = std.testing.allocator;
    const source = "const a = 1;\nconst b = 2;\nconst c = 3;";
    var gen = Generator.init(allocator, source);
    defer gen.deinit();

    gen.setCoverLinesWithoutMappings(false);

    gen.addMapping(0, 0, 0, "");
    gen.addMapping(1, 0, 13, "");
    gen.addMapping(2, 0, 26, "");

    const result = gen.generate();

    // Count semicolons: 3 lines should have 2 semicolons
    var semicolons: usize = 0;
    for (result.mappings) |c| {
        if (c == ';') semicolons += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), semicolons);
}

// =========================================================================
// Generator delta encoding verification
// (from Go TestSourceMapDeltaEncoding)
// =========================================================================

test "Generator delta encoding" {
    const allocator = std.testing.allocator;
    const source = "const abc = 1;\nconst def = 2;";
    var gen = Generator.init(allocator, source);
    defer gen.deinit();

    gen.setCoverLinesWithoutMappings(false);

    gen.addMapping(0, 6, 6, "abc");
    gen.addMapping(1, 6, 21, "def");

    const result = gen.generate();

    var decoded = decodeMappings(allocator, result.mappings);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(usize, 2), decoded.items.len);

    // First mapping
    try std.testing.expectEqual(@as(u32, 0), decoded.items[0].gen_line);
    try std.testing.expectEqual(@as(u32, 6), decoded.items[0].gen_col);

    // Second mapping
    try std.testing.expectEqual(@as(u32, 1), decoded.items[1].gen_line);
    try std.testing.expectEqual(@as(u32, 6), decoded.items[1].gen_col);
}

// =========================================================================
// Generator mappings format verification
// (from Go TestSourceMapMappingsFormat)
// =========================================================================

test "Generator mappings format" {
    const allocator = std.testing.allocator;
    const source = "a\nb\nc";
    var gen = Generator.init(allocator, source);
    defer gen.deinit();

    gen.setCoverLinesWithoutMappings(false);

    gen.addMapping(0, 0, 0, "");
    gen.addMapping(1, 0, 2, "");
    gen.addMapping(2, 0, 4, "");

    const result = gen.generate();

    // Should have format "segment;segment;segment" (3 parts)
    var parts: usize = 1;
    for (result.mappings) |c| {
        if (c == ';') parts += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), parts);
}

// =========================================================================
// Line coverage workaround tests
// (from Go TestLineCoverageWorkaround, etc.)
// =========================================================================

test "Generator line coverage fills gap lines" {
    const allocator = std.testing.allocator;
    const source = "line1\nline2\nline3\n";
    var gen = Generator.init(allocator, source);
    defer gen.deinit();

    gen.setSourceName("test.wgsl");

    // Only add mapping on line 0 and line 2, skip line 1
    gen.addMapping(0, 5, 0, "");
    gen.addMapping(2, 5, 12, "");

    const result = gen.generate();
    var decoded = decodeMappings(allocator, result.mappings);
    defer decoded.deinit();

    // Line 1 should have a mapping at column 0 from the coverage workaround
    var has_line1_col0 = false;
    for (decoded.items) |m| {
        if (m.gen_line == 1 and m.gen_col == 0) {
            has_line1_col0 = true;
        }
    }
    try std.testing.expect(has_line1_col0);
}

test "Generator line coverage not duplicated when line has col 0" {
    const allocator = std.testing.allocator;
    const source = "line1\nline2\n";
    var gen = Generator.init(allocator, source);
    defer gen.deinit();

    gen.setSourceName("test.wgsl");

    gen.addMapping(0, 0, 0, "");
    gen.addMapping(1, 0, 6, ""); // Line 1 already has col 0

    const result = gen.generate();
    var decoded = decodeMappings(allocator, result.mappings);
    defer decoded.deinit();

    // Count mappings on line 1
    var line1_count: usize = 0;
    for (decoded.items) |m| {
        if (m.gen_line == 1) line1_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), line1_count);
}

test "Generator line coverage multiple gaps" {
    const allocator = std.testing.allocator;
    const source = "a\nb\nc\nd\ne\n";
    var gen = Generator.init(allocator, source);
    defer gen.deinit();

    gen.setSourceName("test.wgsl");

    gen.addMapping(0, 0, 0, "");
    gen.addMapping(4, 0, 8, ""); // skip lines 1, 2, 3

    const result = gen.generate();
    var decoded = decodeMappings(allocator, result.mappings);
    defer decoded.deinit();

    // All lines 0..4 should have at least one mapping
    var covered: [5]bool = .{ false, false, false, false, false };
    for (decoded.items) |m| {
        if (m.gen_line < 5) covered[m.gen_line] = true;
    }

    var line: u32 = 0;
    while (line <= 4) : (line += 1) {
        try std.testing.expect(covered[line]);
    }
}

test "Generator line coverage disabled" {
    const allocator = std.testing.allocator;
    const source = "line1\nline2\nline3\n";
    var gen = Generator.init(allocator, source);
    defer gen.deinit();

    gen.setSourceName("test.wgsl");
    gen.setCoverLinesWithoutMappings(false);

    gen.addMapping(0, 5, 0, "");
    gen.addMapping(2, 5, 12, "");

    const result = gen.generate();
    var decoded = decodeMappings(allocator, result.mappings);
    defer decoded.deinit();

    // Line 1 should NOT have a mapping
    var has_line1 = false;
    for (decoded.items) |m| {
        if (m.gen_line == 1) has_line1 = true;
    }
    try std.testing.expect(!has_line1);
}

// =========================================================================
// Result toComment (from Go TestToCommentInline / TestToCommentExternal)
// =========================================================================

test "Result toComment inline" {
    const allocator = std.testing.allocator;
    const result = Result{
        .version = 3,
        .file = "test.wgsl",
        .mappings = "AAAA",
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    result.toComment(&buf, allocator, true);

    try std.testing.expect(std.mem.startsWith(u8, buf.items, "//# sourceMappingURL=data:application/json;base64,"));
}

test "Result toComment external" {
    const allocator = std.testing.allocator;
    const result = Result{
        .version = 3,
        .file = "test.wgsl",
        .mappings = "AAAA",
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    result.toComment(&buf, allocator, false);

    try std.testing.expectEqualStrings("//# sourceMappingURL=test.wgsl.map", buf.items);
}

// =========================================================================
// decodeMappings edge cases
// (from Go TestDecodeMappings* edge case tests)
// =========================================================================

test "decodeMappings multiple segments same line" {
    // "AAAA,CACA" = two segments on same line
    var decoded = decodeMappings(std.testing.allocator, "AAAA,CACA");
    defer decoded.deinit();

    try std.testing.expectEqual(@as(usize, 2), decoded.items.len);
    // First: col 0
    try std.testing.expectEqual(@as(u32, 0), decoded.items[0].gen_col);
    // Second: col 1 (delta of C=1)
    try std.testing.expectEqual(@as(u32, 1), decoded.items[1].gen_col);
}

test "decodeMappings three lines" {
    // "AAAA;CACA;EAEA" = one mapping per line
    var decoded = decodeMappings(std.testing.allocator, "AAAA;CACA;EAEA");
    defer decoded.deinit();

    try std.testing.expectEqual(@as(usize, 3), decoded.items.len);
    try std.testing.expectEqual(@as(u32, 0), decoded.items[0].gen_line);
    try std.testing.expectEqual(@as(u32, 1), decoded.items[1].gen_line);
    try std.testing.expectEqual(@as(u32, 2), decoded.items[2].gen_line);
}

test "decodeMappings empty segment skipped" {
    // "AAAA,,CACA" - empty segment between commas
    var decoded = decodeMappings(std.testing.allocator, "AAAA,,CACA");
    defer decoded.deinit();

    try std.testing.expectEqual(@as(usize, 2), decoded.items.len);
}

test "decodeMappings empty lines increment line counter" {
    // "AAAA;;;CACA" - lines 1 and 2 are empty
    var decoded = decodeMappings(std.testing.allocator, "AAAA;;;CACA");
    defer decoded.deinit();

    try std.testing.expectEqual(@as(usize, 2), decoded.items.len);
    try std.testing.expectEqual(@as(u32, 0), decoded.items[0].gen_line);
    try std.testing.expectEqual(@as(u32, 3), decoded.items[1].gen_line);
}

test "decodeMappings invalid VLQ segment skipped" {
    // "g" has continuation bit set, alone it is invalid. Should be skipped.
    // "AAAA" that follows should decode fine.
    var decoded = decodeMappings(std.testing.allocator, "g,AAAA");
    defer decoded.deinit();

    // The 'g' segment should be skipped, AAAA should decode
    try std.testing.expectEqual(@as(usize, 1), decoded.items.len);
}

test "decodeMappings segment with only column" {
    // "C" is a single VLQ value (1), no source info
    var decoded = decodeMappings(std.testing.allocator, "C");
    defer decoded.deinit();

    try std.testing.expectEqual(@as(usize, 1), decoded.items.len);
    try std.testing.expectEqual(@as(u32, 1), decoded.items[0].gen_col);
}

// =========================================================================
// utf8ToUtf16Column direct tests
// =========================================================================

test "utf8ToUtf16Column zero length" {
    try std.testing.expectEqual(@as(u32, 0), utf8ToUtf16Column("abc", 0));
}

test "utf8ToUtf16Column beyond string" {
    try std.testing.expectEqual(@as(u32, 3), utf8ToUtf16Column("abc", 100));
}

test "utf8ToUtf16Column invalid UTF-8" {
    // \xff is not valid UTF-8, should be counted as 1 unit
    const s = "a\xffb";
    const col = utf8ToUtf16Column(s, 2);
    try std.testing.expectEqual(@as(u32, 2), col);
}
