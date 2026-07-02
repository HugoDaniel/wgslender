//! Tint expected-file verdict oracle (corpus-free classifier).
//!
//! Google's Dawn `test/tint` corpus ships each `<name>.wgsl` shader with a
//! sibling `<name>.wgsl.expected.wgsl` holding Tint's own output. When Tint
//! *rejects* a shader the expected file starts with a `SKIP: <reason>` marker
//! instead of WGSL. This module turns that convention into a `Verdict` our
//! validator's accept/reject can be measured against:
//!
//!   * `SKIP: FAILED`             → Tint rejected it              → .rejects
//!   * `SKIP: INVALID|TIMEOUT|…`  → other-backend skip / unknown  → .unknown
//!   * anything else (incl. empty, real WGSL) → Tint accepted     → .accepts
//!   * expected file absent / unreadable                          → .unknown
//!
//! Everything here is pure (no validator dependency) so it unit-tests
//! corpus-free in default CI; the corpus walk (Block 2) feeds it real entries.

const std = @import("std");

pub const Verdict = enum { accepts, rejects, unknown };

/// UTF-8 BOM some expected files carry; stripped before classification.
const utf8_bom = "\xEF\xBB\xBF";

/// The first line of `bytes` with a leading UTF-8 BOM and a trailing `\r`
/// removed (handles CRLF expected files). No allocation — borrows `bytes`.
pub fn firstLine(bytes: []const u8) []const u8 {
    var s = bytes;
    if (std.mem.startsWith(u8, s, utf8_bom)) s = s[utf8_bom.len..];
    const end = std.mem.indexOfScalar(u8, s, '\n') orelse s.len;
    var line = s[0..end];
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    return line;
}

/// Classify an already-cleaned first line (see `firstLine`).
pub fn classifyFirstLine(line: []const u8) Verdict {
    if (std.mem.startsWith(u8, line, "SKIP: FAILED")) return .rejects;
    if (std.mem.startsWith(u8, line, "SKIP")) return .unknown;
    return .accepts;
}

/// Classify the raw bytes of a `<shader>.wgsl.expected.wgsl` file.
pub fn verdictForExpectedBytes(bytes: []const u8) Verdict {
    return classifyFirstLine(firstLine(bytes));
}

/// Expected-file basename for a shader: `foo.wgsl` → `foo.wgsl.expected.wgsl`.
pub fn expectedBasename(alloc: std.mem.Allocator, shader_basename: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}.expected.wgsl", .{shader_basename});
}

/// The Tint reason text of a rejected expected file: everything after the
/// `SKIP: …` marker line, blank-trimmed. Empty when `bytes` is not a SKIP file.
pub fn tintReason(bytes: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, firstLine(bytes), "SKIP")) return "";
    var s = bytes;
    if (std.mem.startsWith(u8, s, utf8_bom)) s = s[utf8_bom.len..];
    const nl = std.mem.indexOfScalar(u8, s, '\n') orelse return "";
    return std.mem.trim(u8, s[nl + 1 ..], " \t\r\n");
}

/// Read a shader's sibling expected file from `dir` and classify it. A missing
/// or unreadable expected file is conservatively `.unknown` (never `.rejects`).
pub fn verdictForEntry(
    io: std.Io,
    dir: std.Io.Dir,
    shader_basename: []const u8,
    alloc: std.mem.Allocator,
) Verdict {
    const name = expectedBasename(alloc, shader_basename) catch return .unknown;
    const bytes = dir.readFileAlloc(io, name, alloc, .unlimited) catch return .unknown;
    return verdictForExpectedBytes(bytes);
}

/// Files exercising features the validator doesn't model yet. Skipped so they
/// don't add noise to the corpus pin / triage. Canonical copy — the corpus
/// pinning test switches to this in Block 2; `tests/tint_test.zig` keeps its
/// own independent copy.
pub const unsupported_features = [_][]const u8{
    "enable f16",
    "enable chromium",
    "enable subgroups",
    "diagnostic(off",
    "diagnostic(warning",
    "diagnostic(error",
    "@diagnostic",
};

pub fn containsUnsupported(source: []const u8) bool {
    for (unsupported_features) |f| {
        if (std.mem.indexOf(u8, source, f) != null) return true;
    }
    return false;
}

/// Triage bucket for a diagnostic we emit, relative to Tint's verdict on the
/// shader: fp = we flag a shader Tint *accepts* (false-positive candidate for
/// E-codes), tp = we flag one Tint *rejects*, unk = Tint's verdict unknown.
/// Shared by the triage golden and the `tint-triage` tool.
pub const Bucket = enum { fp, tp, unk };

pub fn bucketOf(v: Verdict) Bucket {
    return switch (v) {
        .accepts => .fp,
        .rejects => .tp,
        .unknown => .unk,
    };
}

pub fn bucketName(b: Bucket) []const u8 {
    return switch (b) {
        .fp => "fp",
        .tp => "tp",
        .unk => "unk",
    };
}

pub fn bucketFromStr(s: []const u8) ?Bucket {
    if (std.mem.eql(u8, s, "fp")) return .fp;
    if (std.mem.eql(u8, s, "tp")) return .tp;
    if (std.mem.eql(u8, s, "unk")) return .unk;
    return null;
}

// ---------------------------------------------------------------------------
// Tests (corpus-free; table-driven so new cases are one-line additions).
// ---------------------------------------------------------------------------

const testing = std.testing;

test "classifyFirstLine: SKIP markers vs plain WGSL" {
    const cases = [_]struct { line: []const u8, want: Verdict }{
        .{ .line = "SKIP: FAILED", .want = .rejects },
        .{ .line = "SKIP: FAILED because of parser recursion", .want = .rejects },
        .{ .line = "SKIP: INVALID", .want = .unknown },
        .{ .line = "SKIP: TIMEOUT", .want = .unknown },
        .{ .line = "SKIP: SOMETHING_NEW", .want = .unknown },
        .{ .line = "SKIP", .want = .unknown },
        .{ .line = "@group(0) @binding(0) var<storage> s : i32;", .want = .accepts },
        .{ .line = "// a comment", .want = .accepts },
        .{ .line = "", .want = .accepts },
    };
    for (cases) |c| try testing.expectEqual(c.want, classifyFirstLine(c.line));
}

test "verdictForExpectedBytes: raw bytes incl. CRLF, BOM, multi-line, empty" {
    const cases = [_]struct { bytes: []const u8, want: Verdict }{
        .{ .bytes = "SKIP: FAILED\n\n<dawn>/x.wgsl:1:1 error: boom\n", .want = .rejects },
        .{ .bytes = "SKIP: FAILED\r\ntint error\r\n", .want = .rejects },
        .{ .bytes = utf8_bom ++ "SKIP: FAILED\n", .want = .rejects },
        .{ .bytes = "SKIP: INVALID\n...\n", .want = .unknown },
        .{ .bytes = "SKIP: TIMEOUT\n", .want = .unknown },
        .{ .bytes = utf8_bom ++ "@group(0) @binding(0) var<uniform> u : f32;\n", .want = .accepts },
        .{ .bytes = "fn main() {}\r\n", .want = .accepts },
        .{ .bytes = "", .want = .accepts },
    };
    for (cases) |c| try testing.expectEqual(c.want, verdictForExpectedBytes(c.bytes));
}

test "firstLine strips BOM and trailing CR" {
    try testing.expectEqualStrings("SKIP: FAILED", firstLine("SKIP: FAILED\r\nrest"));
    try testing.expectEqualStrings("SKIP: FAILED", firstLine(utf8_bom ++ "SKIP: FAILED\nrest"));
    try testing.expectEqualStrings("hello", firstLine("hello"));
    try testing.expectEqualStrings("", firstLine(""));
}

test "expectedBasename appends .expected.wgsl" {
    const got = try expectedBasename(testing.allocator, "1395241.wgsl");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("1395241.wgsl.expected.wgsl", got);
}

test "tintReason returns error text after the SKIP marker" {
    try testing.expectEqualStrings(
        "<dawn>/x.wgsl:2:145 error: maximum parser recursive depth reached",
        tintReason("SKIP: FAILED\n\n<dawn>/x.wgsl:2:145 error: maximum parser recursive depth reached\n"),
    );
    try testing.expectEqualStrings("", tintReason("@group(0) var<uniform> u : f32;\n"));
    try testing.expectEqualStrings("", tintReason(""));
}

test "containsUnsupported flags enable/diagnostic features" {
    try testing.expect(containsUnsupported("enable f16;\nfn f(){}"));
    try testing.expect(containsUnsupported("@diagnostic(off, derivative_uniformity) fn f(){}"));
    try testing.expect(!containsUnsupported("@group(0) @binding(0) var<uniform> u : f32;"));
    try testing.expect(!containsUnsupported(""));
}

test "bucketOf maps verdict to triage bucket" {
    try testing.expectEqual(Bucket.fp, bucketOf(.accepts));
    try testing.expectEqual(Bucket.tp, bucketOf(.rejects));
    try testing.expectEqual(Bucket.unk, bucketOf(.unknown));
}

test "bucketName / bucketFromStr round-trip + rejects unknown strings" {
    const all = [_]Bucket{ .fp, .tp, .unk };
    for (all) |b| try testing.expectEqual(b, bucketFromStr(bucketName(b)).?);
    try testing.expectEqualStrings("fp", bucketName(.fp));
    try testing.expectEqualStrings("tp", bucketName(.tp));
    try testing.expectEqualStrings("unk", bucketName(.unk));
    try testing.expect(bucketFromStr("nope") == null);
    try testing.expect(bucketFromStr("") == null);
}
