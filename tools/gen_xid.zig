//! Generator for `src/unicode_xid_data.zig`.
//!
//! Parses a Unicode Character Database `DerivedCoreProperties.txt` and emits
//! the `XID_Start` / `XID_Continue` range tables the lexer uses to validate
//! WGSL identifiers (WGSL §2.4 → UAX31-R1). ASCII codepoints (< 0x80) are
//! dropped — the lexer short-circuits ASCII before ever consulting a table.
//!
//! Usage — `zig build gen-xid [-- <ucd-path> [out-path]]`:
//!   ucd-path   path to DerivedCoreProperties.txt
//!              (default: tests/testdata/ucd/DerivedCoreProperties.txt,
//!               fetched by scripts/fetch-ucd.sh)
//!   out-path   destination (default: src/unicode_xid_data.zig)
//!
//! Writes the data file in place (a side-effecting build step, so `zig build
//! gen-xid` always re-runs). The output is byte-for-byte reproducible: same UCD
//! input → same file. Commit the data file and scripts/ucd.rev together.

const std = @import("std");
const File = std.Io.File;

const default_ucd_path = "tests/testdata/ucd/DerivedCoreProperties.txt";
const default_out_path = "src/unicode_xid_data.zig";

pub const Property = enum {
    xid_start,
    xid_continue,

    fn ucdName(self: Property) []const u8 {
        return switch (self) {
            .xid_start => "XID_Start",
            .xid_continue => "XID_Continue",
        };
    }

    fn zigName(self: Property) []const u8 {
        return switch (self) {
            .xid_start => "xid_start_ranges",
            .xid_continue => "xid_continue_ranges",
        };
    }
};

pub const Range = struct { lo: u32, hi: u32 };

/// Parse one UCD line as a range for `want`. Returns null for blank/comment
/// lines and lines assigning a different property. UCD data lines look like:
///   `00AA          ; XID_Start # Lo  FEMININE ORDINAL INDICATOR`
///   `00C0..00D6    ; XID_Start # L&  [23] ...`
pub fn parseLine(line: []const u8, want: Property) ?Range {
    // Strip the trailing `# ...` comment, then require a `;` separator.
    const code_part = line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse line.len];
    const semi = std.mem.indexOfScalar(u8, code_part, ';') orelse return null;
    const prop = std.mem.trim(u8, code_part[semi + 1 ..], " \t\r\n");
    if (!std.mem.eql(u8, prop, want.ucdName())) return null;

    const cps = std.mem.trim(u8, code_part[0..semi], " \t\r\n");
    if (std.mem.indexOf(u8, cps, "..")) |dot| {
        const lo = std.fmt.parseInt(u32, cps[0..dot], 16) catch return null;
        const hi = std.fmt.parseInt(u32, cps[dot + 2 ..], 16) catch return null;
        return .{ .lo = lo, .hi = hi };
    }
    const cp = std.fmt.parseInt(u32, cps, 16) catch return null;
    return .{ .lo = cp, .hi = cp };
}

/// Parse the Unicode version from the header line
/// `# DerivedCoreProperties-16.0.0.txt`.
pub fn parseVersion(text: []const u8) ?[]const u8 {
    const marker = "DerivedCoreProperties-";
    const start = std.mem.indexOf(u8, text, marker) orelse return null;
    const rest = text[start + marker.len ..];
    const end = std.mem.indexOf(u8, rest, ".txt") orelse return null;
    return rest[0..end];
}

fn lessByLo(_: void, a: Range, b: Range) bool {
    return a.lo < b.lo;
}

/// Collect every range for `want`: drop ASCII (< 0x80), sort by low bound, and
/// coalesce overlapping or adjacent ranges into a maximal, gap-separated set.
pub fn collect(alloc: std.mem.Allocator, text: []const u8, want: Property) ![]Range {
    var raw: std.ArrayListUnmanaged(Range) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const r = parseLine(line, want) orelse continue;
        if (r.hi < 0x80) continue; // wholly ASCII — handled before the table
        try raw.append(alloc, .{ .lo = @max(r.lo, 0x80), .hi = r.hi });
    }

    std.sort.block(Range, raw.items, {}, lessByLo);

    var merged: std.ArrayListUnmanaged(Range) = .empty;
    for (raw.items) |r| {
        if (merged.items.len > 0) {
            const last = &merged.items[merged.items.len - 1];
            if (r.lo <= last.hi + 1) { // overlapping or adjacent
                last.hi = @max(last.hi, r.hi);
                continue;
            }
        }
        try merged.append(alloc, r);
    }
    return merged.items;
}

const banner_fmt =
    \\//! Unicode XID_Start / XID_Continue derived property tables.
    \\//!
    \\//! GENERATED FILE — do not edit by hand. Regenerate with `zig build gen-xid`
    \\//! (see tools/gen_xid.zig; input fetched by scripts/fetch-ucd.sh). Consumed by
    \\//! src/unicode_xid.zig, which owns the lookup functions, tests, and invariants.
    \\//!
    \\//! Source: https://www.unicode.org/Public/{s}/ucd/DerivedCoreProperties.txt
    \\//! ASCII codepoints (< 0x80) are excluded — the lexer short-circuits ASCII
    \\//! before consulting these tables.
    \\
    \\pub const unicode_version = "{s}";
    \\
    \\
;

fn emitTable(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, want: Property, ranges: []const Range) !void {
    try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "pub const {s}: [{d}][2]u32 = .{{\n", .{ want.zigName(), ranges.len }));
    for (ranges) |r| {
        try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "    .{{ 0x{X:0>5}, 0x{X:0>5} }},\n", .{ r.lo, r.hi }));
    }
    try out.appendSlice(alloc, "};\n");
}

/// Render the full contents of `src/unicode_xid_data.zig`.
pub fn emit(alloc: std.mem.Allocator, version: []const u8, start: []const Range, cont: []const Range) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, banner_fmt, .{ version, version }));
    try emitTable(&out, alloc, .xid_start, start);
    try out.appendSlice(alloc, "\n");
    try emitTable(&out, alloc, .xid_continue, cont);
    return out.items;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var argv = std.process.Args.Iterator.init(init.minimal.args);
    _ = argv.skip(); // program name
    const ucd_path = argv.next() orelse default_ucd_path;
    const out_path = argv.next() orelse default_out_path;

    const text = std.Io.Dir.cwd().readFileAlloc(io, ucd_path, arena, .unlimited) catch {
        try File.stderr().writeStreamingAll(io, try std.fmt.allocPrint(arena,
            "gen-xid: could not read UCD file '{s}'\n" ++
            "  run scripts/fetch-ucd.sh first, or pass a path: zig build gen-xid -- <path>\n", .{ucd_path}));
        std.process.exit(1);
    };

    const version = parseVersion(text) orelse {
        try File.stderr().writeStreamingAll(io, "gen-xid: could not find 'DerivedCoreProperties-<version>.txt' header\n");
        std.process.exit(1);
    };
    const start = try collect(arena, text, .xid_start);
    const cont = try collect(arena, text, .xid_continue);
    const rendered = try emit(arena, version, start, cont);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = rendered });
    try File.stderr().writeStreamingAll(io, try std.fmt.allocPrint(arena,
        "gen-xid: wrote {s} (Unicode {s}: {d} start ranges, {d} continue ranges)\n", .{ out_path, version, start.len, cont.len }));
}

// ---------------------------------------------------------------------------
// Tests (pure; no UCD file needed — the always-on gate for generator logic).
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseLine: single codepoint and range for the wanted property" {
    try testing.expectEqual(Range{ .lo = 0xAA, .hi = 0xAA }, parseLine("00AA          ; XID_Start # Lo  X", .xid_start).?);
    try testing.expectEqual(Range{ .lo = 0xC0, .hi = 0xD6 }, parseLine("00C0..00D6    ; XID_Start # L&  [23] X", .xid_start).?);
    try testing.expectEqual(Range{ .lo = 0x300, .hi = 0x374 }, parseLine("0300..0374    ; XID_Continue # Mn X", .xid_continue).?);
}

test "parseLine: ignores comments, blanks, and other properties" {
    try testing.expect(parseLine("# a comment", .xid_start) == null);
    try testing.expect(parseLine("", .xid_start) == null);
    try testing.expect(parseLine("00AA          ; XID_Continue # Lo", .xid_start) == null);
    // A property whose name is a prefix of the wanted one must not match.
    try testing.expect(parseLine("00AA          ; XID_Sta # Lo", .xid_start) == null);
}

test "parseVersion: reads the header marker" {
    try testing.expectEqualStrings("16.0.0", parseVersion("# DerivedCoreProperties-16.0.0.txt\n# Date: ...\n").?);
    try testing.expect(parseVersion("no version here") == null);
}

test "collect: drops ASCII, sorts, merges overlapping and adjacent" {
    // collect/emit are arena-oriented one-shot generator functions (see main);
    // exercise them the same way rather than bolt per-line frees onto them.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ucd =
        \\0061..007A    ; XID_Start # wholly ASCII, dropped
        \\0100..0100    ; XID_Start # adjacent to next -> merged
        \\0101..0110    ; XID_Start # merges with prev
        \\00C0..00D6    ; XID_Start # out of order -> sorted before 0100
        \\00D6..00E0    ; XID_Start # overlaps 00C0..00D6 -> merged
        \\0300..0300    ; XID_Continue # different property, ignored here
    ;
    const got = try collect(arena.allocator(), ucd, .xid_start);
    try testing.expectEqualSlices(Range, &.{
        .{ .lo = 0xC0, .hi = 0xE0 }, // 00C0..00D6 ∪ 00D6..00E0
        .{ .lo = 0x100, .hi = 0x110 }, // 0100 ∪ 0101..0110
    }, got);
}

test "emit: byte-exact data-file format" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try emit(
        arena.allocator(),
        "16.0.0",
        &.{.{ .lo = 0xAA, .hi = 0xAA }},
        &.{.{ .lo = 0xAA, .hi = 0xAA }, .{ .lo = 0x1D7CE, .hi = 0x1D7FF }},
    );
    try testing.expect(std.mem.indexOf(u8, out, "pub const unicode_version = \"16.0.0\";") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub const xid_start_ranges: [1][2]u32 = .{\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "    .{ 0x000AA, 0x000AA },\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub const xid_continue_ranges: [2][2]u32 = .{\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "    .{ 0x1D7CE, 0x1D7FF },\n") != null);
    try testing.expect(std.mem.endsWith(u8, out, "};\n"));
}
