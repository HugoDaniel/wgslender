//! Assembled→author source-map remapping for composed pngine minification
//! (pngine-shaders phase 05, Task 4).
//!
//! The minifier builds its source map against `Assembled.text`: every
//! `Mapping.src_line`/`src_col` is an assembled position, and every
//! `sources[]` entry is the single assembled document. A composed project
//! must publish author origins instead.
//!
//! ## Pipeline
//!
//! 1. Decode the minifier's assembled map (generated line/column, source
//!    line/column, optional name index).
//! 2. Turn each assembled source position into a byte offset and ask the
//!    phase-02 `Assembled.offsetToOrigin` for its part and author offset.
//!    Text is never rescanned to guess an origin.
//! 3. Turn that author offset into the author text's own UTF-16 line and
//!    column, which is what the LSP reports for the same position.
//! 4. Re-encode with one `sources[]` entry per origin. Generated positions
//!    and name indices are copied unchanged; only the source index, line,
//!    and column fields move.
//!
//! ## Drop rule
//!
//! A mapping is dropped only when phase-02 has no honest author origin for
//! it: blanked directive bytes (synthetic spaces), or an origin the caller
//! did not supply. The generated position is never invented and no source
//! index is fabricated. `Result.dropped` counts every drop once; a caller
//! emits a single report-level warning from that count, never one per
//! mapping.
//!
//! ## Naming
//!
//! This module has no Store and no filesystem. The caller supplies each
//! origin's `Source`: the `sources[]` spelling (the user's `:file` text or a
//! stable `wgslender-pngine://` virtual URI) and the author text used for
//! line/column conversion and, when requested, `sourcesContent[]`.
//!
//! This is pure library code: no `build_options`, no `std.Io`, no Store.

const std = @import("std");

const SourceMap = @import("../SourceMap.zig");
const assemble = @import("Assemble.zig");

const Allocator = std.mem.Allocator;

pub const OriginKey = assemble.OriginKey;

/// One author origin as the source map should name it.
pub const Source = struct {
    origin: OriginKey,
    /// `sources[]` spelling: the user's `:file` text, or the inline part's
    /// stable virtual URI.
    name: []const u8,
    /// The author text. Used for UTF-16 line/column conversion, and emitted
    /// in `sourcesContent[]` when `Options.include_sources_content` is set.
    content: []const u8,
};

pub const Options = struct {
    /// The output map's `file` field. Empty keeps the assembled map's own
    /// file name, which the minifier already derived from `-o`.
    file: []const u8 = "",
    /// Emit one `sourcesContent[]` entry per emitted source, aligned by
    /// index. Off by default, matching `--source-map-sources`.
    include_sources_content: bool = false,
};

pub const Result = struct {
    map: SourceMap.Result,
    /// Mappings with no honest author origin. The caller turns this into
    /// exactly one warning.
    dropped: u32 = 0,

    /// Release the arrays this module allocated. `map.names` is borrowed
    /// from the input map and `map.file`/`sources[]` strings are borrowed
    /// from the caller's `Source` values, so neither is freed here.
    pub fn deinit(self: *Result, gpa: Allocator) void {
        if (self.map.sources.len > 0) gpa.free(self.map.sources);
        if (self.map.sources_content.len > 0) gpa.free(self.map.sources_content);
        if (self.map.mappings.len > 0) gpa.free(@constCast(self.map.mappings));
        self.* = undefined;
    }
};

/// Remap `assembled_map` from assembled coordinates to the author origins
/// named by `sources`. The returned map owns its arrays; call `deinit`.
pub fn remap(
    gpa: Allocator,
    assembled: *const assemble.Assembled,
    sources: []const Source,
    assembled_map: *const SourceMap.Result,
    options: Options,
) Allocator.Error!Result {
    const raw = try decode(gpa, assembled_map.mappings);
    defer gpa.free(raw);

    var assembled_index = try SourceMap.LineIndex.init(gpa, assembled.text);
    defer assembled_index.deinit(gpa);

    // Author line indexes are built on first use; only sources a mapping
    // actually reaches pay for one.
    const author_indexes = try gpa.alloc(?SourceMap.LineIndex, sources.len);
    @memset(author_indexes, null);
    defer {
        for (author_indexes) |*slot| {
            if (slot.*) |*line_index| line_index.deinit(gpa);
        }
        gpa.free(author_indexes);
    }

    var translated: std.ArrayList(Mapping) = .empty;
    defer translated.deinit(gpa);
    try translated.ensureTotalCapacity(gpa, raw.len);

    var out_sources: std.ArrayList([]const u8) = .empty;
    errdefer out_sources.deinit(gpa);
    var out_contents: std.ArrayList([]const u8) = .empty;
    errdefer out_contents.deinit(gpa);

    const used = try gpa.alloc(?u32, sources.len);
    @memset(used, null);
    defer gpa.free(used);

    var dropped: u32 = 0;

    for (raw) |entry| {
        if (!entry.has_source) {
            // A generated-only segment has no origin to translate. Keep the
            // generated position exactly as encoded.
            translated.appendAssumeCapacity(.{ .gen_line = entry.gen_line, .gen_col = entry.gen_col });
            continue;
        }

        const assembled_offset = utf16ColumnToByteOffset(
            assembled.text,
            &assembled_index,
            entry.src_line,
            entry.src_col,
        );
        const origin_offset = assembled.offsetToOrigin(assembled_offset) orelse {
            dropped += 1;
            continue;
        };

        const source_index = findSource(sources, origin_offset.origin) orelse {
            dropped += 1;
            continue;
        };

        if (author_indexes[source_index] == null) {
            author_indexes[source_index] = try SourceMap.LineIndex.init(
                gpa,
                sources[source_index].content,
            );
        }
        const position = author_indexes[source_index].?.byteOffsetToLineColumnUtf16(
            sources[source_index].content,
            origin_offset.offset,
        );

        var mapped_source: u32 = undefined;
        if (used[source_index]) |existing| {
            mapped_source = existing;
        } else {
            mapped_source = @intCast(out_sources.items.len);
            used[source_index] = mapped_source;
            try out_sources.append(gpa, sources[source_index].name);
            if (options.include_sources_content) {
                try out_contents.append(gpa, sources[source_index].content);
            }
        }

        translated.appendAssumeCapacity(.{
            .gen_line = entry.gen_line,
            .gen_col = entry.gen_col,
            .has_source = true,
            .src_index = mapped_source,
            .src_line = position.line,
            .src_col = position.col,
            .name_index = entry.name_index,
        });
    }

    const mappings = try encode(gpa, translated.items);
    errdefer gpa.free(mappings);

    return .{
        .map = .{
            .version = 3,
            .file = if (options.file.len > 0) options.file else assembled_map.file,
            .sources = try out_sources.toOwnedSlice(gpa),
            .sources_content = try out_contents.toOwnedSlice(gpa),
            // Names are positional: keeping the input array verbatim keeps
            // every surviving name index consistent.
            .names = assembled_map.names,
            .mappings = mappings,
        },
        .dropped = dropped,
    };
}

/// The one report-level warning for dropped mappings. Never call it inside
/// the mapping loop.
pub fn warningLine(
    gpa: Allocator,
    root_name: []const u8,
    dropped: u32,
) Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "warning: dropped {d} source-map mapping{s} with no honest author origin in pngine module '{s}'\n",
        .{ dropped, if (dropped == 1) "" else "s", root_name },
    );
}

// =========================================================================
// Decoding / encoding
// =========================================================================

const RawMapping = struct {
    gen_line: u32 = 0,
    gen_col: u32 = 0,
    has_source: bool = false,
    src_line: u32 = 0,
    src_col: u32 = 0,
    name_index: ?u32 = null,
};

const Mapping = struct {
    gen_line: u32 = 0,
    gen_col: u32 = 0,
    has_source: bool = false,
    src_index: u32 = 0,
    src_line: u32 = 0,
    src_col: u32 = 0,
    name_index: ?u32 = null,
};

/// Decode a source-map v3 `mappings` string, keeping the field-count
/// distinction `SourceMap.Mapping` loses: a 1–3 field segment has no source.
fn decode(gpa: Allocator, mappings: []const u8) Allocator.Error![]RawMapping {
    var out: std.ArrayList(RawMapping) = .empty;
    errdefer out.deinit(gpa);

    var gen_line: u32 = 0;
    var gen_col: i32 = 0;
    var src_index: i32 = 0;
    var src_line: i32 = 0;
    var src_col: i32 = 0;
    var name_index: i32 = 0;

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

        var fields: [5]i32 = .{ 0, 0, 0, 0, 0 };
        var field_count: u32 = 0;
        while (i < mappings.len and mappings[i] != ';' and mappings[i] != ',') {
            if (field_count >= 5) {
                // A six-field segment is not a source-map v3 mapping; skip
                // the rest of it rather than inventing fields.
                i += 1;
                continue;
            }
            const decoded = SourceMap.decodeVlq(mappings[i..]) orelse {
                i += 1;
                break;
            };
            fields[field_count] = decoded.value;
            field_count += 1;
            i += decoded.consumed;
        }

        if (field_count == 0) continue;

        gen_col +%= fields[0];
        if (gen_col < 0) continue;

        var entry = RawMapping{
            .gen_line = gen_line,
            .gen_col = @intCast(gen_col),
        };

        if (field_count >= 4) {
            src_index +%= fields[1];
            src_line +%= fields[2];
            src_col +%= fields[3];
            if (src_index < 0 or src_line < 0 or src_col < 0) continue;
            entry.has_source = true;
            entry.src_line = @intCast(src_line);
            entry.src_col = @intCast(src_col);
        }
        // Source-less segments keep their generated column; `src_index`
        // stays irrelevant because it is never encoded for them.

        if (field_count >= 5) {
            name_index +%= fields[4];
            // A name index that has no name is dropped, never renumbered:
            // the names array itself is preserved verbatim.
            if (name_index >= 0) entry.name_index = @intCast(name_index);
        }

        try out.append(gpa, entry);
    }

    return out.toOwnedSlice(gpa);
}

/// Encode translated mappings with the same delta rules as
/// `SourceMap.Generator.encodeMappings`. Only surviving mappings are
/// encoded, so a drop removes exactly that segment.
fn encode(gpa: Allocator, mappings: []const Mapping) Allocator.Error![]u8 {
    if (mappings.len == 0) return &.{};

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    var prev_gen_col: i32 = 0;
    var prev_src_index: i32 = 0;
    var prev_src_line: i32 = 0;
    var prev_src_col: i32 = 0;
    var prev_name_index: i32 = 0;

    var current_line: u32 = 0;
    var first_on_line = true;

    for (mappings) |mapping| {
        while (current_line < mapping.gen_line) {
            try buf.append(gpa, ';');
            current_line += 1;
            prev_gen_col = 0;
            first_on_line = true;
        }

        if (!first_on_line) try buf.append(gpa, ',');
        first_on_line = false;

        try SourceMap.encodeVlq(&buf, gpa, @as(i32, @intCast(mapping.gen_col)) - prev_gen_col);
        prev_gen_col = @intCast(mapping.gen_col);

        if (mapping.has_source) {
            try SourceMap.encodeVlq(&buf, gpa, @as(i32, @intCast(mapping.src_index)) - prev_src_index);
            prev_src_index = @intCast(mapping.src_index);
            try SourceMap.encodeVlq(&buf, gpa, @as(i32, @intCast(mapping.src_line)) - prev_src_line);
            prev_src_line = @intCast(mapping.src_line);
            try SourceMap.encodeVlq(&buf, gpa, @as(i32, @intCast(mapping.src_col)) - prev_src_col);
            prev_src_col = @intCast(mapping.src_col);

            if (mapping.name_index) |name_index| {
                try SourceMap.encodeVlq(&buf, gpa, @as(i32, @intCast(name_index)) - prev_name_index);
                prev_name_index = @intCast(name_index);
            }
        }
    }

    return buf.toOwnedSlice(gpa);
}

// =========================================================================
// Coordinate helpers
// =========================================================================

fn findSource(sources: []const Source, origin: OriginKey) ?usize {
    for (sources, 0..) |source, index| {
        if (source.origin.program == origin.program and source.origin.index == origin.index) {
            return index;
        }
    }
    return null;
}

/// Invert `SourceMap.LineIndex.byteOffsetToLineColumnUtf16`: a UTF-16
/// column on an assembled line to the byte offset the phase-02 segments
/// index. A column inside a surrogate pair clamps to that code point's
/// start; a column past the line clamps to its terminator.
fn utf16ColumnToByteOffset(
    text: []const u8,
    line_index: *const SourceMap.LineIndex,
    line: u32,
    col: u32,
) u32 {
    const starts = line_index.line_starts.items;
    if (starts.len == 0) return 0;

    const clamped_line: u32 = if (line >= starts.len) @intCast(starts.len - 1) else line;
    var i: usize = starts[clamped_line];
    var units: u32 = 0;
    while (i < text.len and units < col) {
        const byte = text[i];
        if (byte == '\n' or byte == '\r') break;
        const length = std.unicode.utf8ByteSequenceLength(byte) catch {
            i += 1;
            units += 1;
            continue;
        };
        if (i + length > text.len) break;
        const codepoint = std.unicode.utf8Decode(text[i..][0..length]) catch {
            i += 1;
            units += 1;
            continue;
        };
        const width: u32 = if (codepoint >= 0x10000) 2 else 1;
        if (units + width > col) break;
        units += width;
        i += length;
    }
    return @intCast(i);
}
