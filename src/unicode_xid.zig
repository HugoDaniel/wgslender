//! Unicode XID_Start / XID_Continue lookups for WGSL identifiers.
//!
//! WGSL §2.4 references UAX31-R1: an identifier is XID_Start XID_Continue*.
//! The range tables live in the generated `unicode_xid_data.zig`; this file owns
//! the lookup functions and the table-integrity tests/invariants below.
//!
//! To regenerate the tables for a new Unicode version:
//!   1. edit scripts/ucd.rev, then run scripts/fetch-ucd.sh
//!   2. zig build gen-xid            (rewrites src/unicode_xid_data.zig)
//!   3. bump the pinned counts in the invariants tests below if they changed
//!   4. commit scripts/ucd.rev + src/unicode_xid_data.zig together

const std = @import("std");
const data = @import("unicode_xid_data.zig");

/// Pinned Unicode version the tables were generated from.
pub const unicode_version = data.unicode_version;

// Slices (not copies) into the generated tables — the lexer hot path and the
// invariants tests share these views.
const xid_start_ranges: []const [2]u32 = &data.xid_start_ranges;
const xid_continue_ranges: []const [2]u32 = &data.xid_continue_ranges;

fn rangeContains(ranges: []const [2]u32, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = ranges[mid];
        if (cp < r[0]) {
            hi = mid;
        } else if (cp > r[1]) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

/// True if `cp` may begin a WGSL identifier (XID_Start, including ASCII letters/`_`).
pub fn isXidStart(cp: u21) bool {
    if (cp < 0x80) {
        return (cp >= 'a' and cp <= 'z') or
            (cp >= 'A' and cp <= 'Z') or
            cp == '_';
    }
    return rangeContains(xid_start_ranges, cp);
}

/// True if `cp` may continue a WGSL identifier (XID_Continue, including ASCII letters/digits/`_`).
pub fn isXidContinue(cp: u21) bool {
    if (cp < 0x80) {
        return (cp >= 'a' and cp <= 'z') or
            (cp >= 'A' and cp <= 'Z') or
            (cp >= '0' and cp <= '9') or
            cp == '_';
    }
    return rangeContains(xid_continue_ranges, cp);
}

// =========================================================================
// Tests
// =========================================================================

test "isXidStart: ASCII letters and underscore" {
    try std.testing.expect(isXidStart('a'));
    try std.testing.expect(isXidStart('Z'));
    try std.testing.expect(isXidStart('_'));
    try std.testing.expect(!isXidStart('0'));
    try std.testing.expect(!isXidStart(' '));
    try std.testing.expect(!isXidStart('$'));
}

test "isXidContinue: ASCII letters/digits/underscore" {
    try std.testing.expect(isXidContinue('a'));
    try std.testing.expect(isXidContinue('Z'));
    try std.testing.expect(isXidContinue('_'));
    try std.testing.expect(isXidContinue('0'));
    try std.testing.expect(isXidContinue('9'));
    try std.testing.expect(!isXidContinue(' '));
}

test "isXidStart: non-ASCII XID characters" {
    try std.testing.expect(isXidStart(0x00E9));   // é
    try std.testing.expect(isXidStart(0x4E2D));   // 中
    try std.testing.expect(isXidStart(0x03B1));   // α (Greek small alpha)
    try std.testing.expect(isXidStart(0x1D400));  // 𝐀 (Mathematical Bold Capital A)
    try std.testing.expect(isXidStart(0x20000));  // 𠀀 (CJK Ideograph Ext B)
}

test "isXidStart: rejects emoji and combining marks" {
    try std.testing.expect(!isXidStart(0x1F389)); // 🎉
    try std.testing.expect(!isXidStart(0x0301));  // combining acute
    try std.testing.expect(!isXidStart(0x200D));  // ZWJ
}

test "isXidContinue: combining marks accepted, emoji rejected" {
    try std.testing.expect(isXidContinue(0x0301));  // combining acute
    try std.testing.expect(isXidContinue(0x4E2D));  // 中
    try std.testing.expect(isXidContinue(0x20000)); // 𠀀
    try std.testing.expect(!isXidContinue(0x1F389)); // 🎉
}

// -------------------------------------------------------------------------
// Table integrity invariants.
//
// `rangeContains` is a binary search: it is correct ONLY if every table is
// sorted and non-overlapping, and it is only ever reached for cp >= 0x80 (the
// lookups short-circuit ASCII first), so the tables must exclude ASCII too.
// These properties were previously unchecked — the tables came from a
// throwaway script that no longer exists. The tests below pin every property
// the search and the generator (`tools/gen_xid.zig`) rely on, so a bad
// regeneration fails the build instead of silently corrupting identifier
// lexing. Kept green by construction; `zig build gen-xid` reproduces the data.

test "xid tables: pinned cardinality and Unicode version" {
    try std.testing.expectEqual(@as(usize, 682), xid_start_ranges.len);
    try std.testing.expectEqual(@as(usize, 796), xid_continue_ranges.len);
    try std.testing.expectEqualStrings("16.0.0", unicode_version);
}

test "xid tables: well-formed, sorted, non-overlapping, merged, ASCII-free" {
    const Table = struct { name: []const u8, ranges: []const [2]u32 };
    for ([_]Table{
        .{ .name = "xid_start_ranges", .ranges = xid_start_ranges },
        .{ .name = "xid_continue_ranges", .ranges = xid_continue_ranges },
    }) |tbl| {
        try std.testing.expect(tbl.ranges.len > 0);
        var prev_hi: ?u32 = null;
        for (tbl.ranges) |r| {
            const lo = r[0];
            const hi = r[1];
            try std.testing.expect(lo <= hi); // well-formed range
            try std.testing.expect(lo >= 0x80); // ASCII handled before the table
            try std.testing.expect(hi <= 0x10FFFF); // within Unicode scalar space
            if (prev_hi) |ph| {
                // Strictly increasing AND fully merged: a correct generator
                // coalesces adjacent ranges, so consecutive ranges leave a gap
                // of >= 1 codepoint. This is stronger than binary search needs
                // (it only needs lo > ph) and also pins the generator's merge.
                try std.testing.expect(lo > ph + 1);
            }
            prev_hi = hi;
        }
    }
}

test "xid invariant: XID_Start is a subset of XID_Continue" {
    // Unicode guarantees XID_Start ⊆ XID_Continue; a generator that swapped or
    // mis-parsed the two property lists would break this. ~141k codepoints, all
    // >= 0x80, so every probe exercises the continue table (not the ASCII path).
    for (xid_start_ranges) |r| {
        var cp: u32 = r[0];
        while (cp <= r[1]) : (cp += 1) {
            try std.testing.expect(isXidContinue(@intCast(cp)));
        }
    }
}
