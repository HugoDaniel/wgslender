//! Byte offset ↔ LSP position conversion backed by a line-start index.
//!
//! `Handler.offsetToLspPosition` scans `source` from byte 0 on every call.
//! That is fine at one call per request (hover, definition), but every
//! result-producing handler calls it *once per result* — semantic tokens
//! alone convert ~10k offsets per keystroke, which made `computeSemanticTokens`
//! take ~224 ms on a 70 KB shader with ~99% of that inside the scan.
//!
//! Build one mapper per request and the conversion becomes a binary search
//! over the line table plus a scan of the target line only.
//!
//! The UTF-16 arithmetic is deliberately *not* reimplemented here. The two
//! loop bodies from `Handler` live in this file as `scanToPosition` /
//! `scanToCharacter`, seeded at an arbitrary line boundary; the mapper seeds
//! them at the line the binary search found and the free functions in
//! `Handler` seed them at 0. One implementation, two entry points — the
//! CRLF and mid-UTF-8 edge cases cannot drift apart.
//!
//! Positions are emitted in UTF-16 code units, matching the
//! `positionEncoding: utf-16` advertised in `capabilities_json`.

const std = @import("std");

const Handler = @import("Handler.zig");
const Position = Handler.Position;
const Range = Handler.Range;

const PositionMapper = @This();

source: []const u8,
/// Byte offset of the first character of each line. Always holds at least
/// one entry (`0`). `\n`, `\r`, and `\r\n` each open exactly one new line,
/// so a source ending in a line break carries a final entry at
/// `source.len` for the trailing empty line.
line_starts: []const u32,

pub fn init(gpa: std.mem.Allocator, source: []const u8) !PositionMapper {
    var starts: std.ArrayList(u32) = .empty;
    errdefer starts.deinit(gpa);
    try starts.append(gpa, 0);

    var i: usize = 0;
    while (std.mem.indexOfAnyPos(u8, source, i, "\r\n")) |brk| {
        i = brk + 1;
        // `\r\n` is one line break, not two.
        if (source[brk] == '\r' and i < source.len and source[i] == '\n') i += 1;
        try starts.append(gpa, @intCast(i));
    }

    return .{ .source = source, .line_starts = try starts.toOwnedSlice(gpa) };
}

pub fn deinit(self: *PositionMapper, gpa: std.mem.Allocator) void {
    gpa.free(self.line_starts);
    self.* = undefined;
}

/// Convert a byte offset to an LSP position. Same result as
/// `Handler.offsetToLspPosition` for every offset of a well-formed source;
/// see the module doc comment on the malformed-UTF-8 difference.
pub fn position(self: *const PositionMapper, offset: u32) ?Position {
    if (offset > self.source.len) return null;
    const line = self.lineAt(offset);
    return scanToPosition(self.source, self.line_starts[line], line, offset);
}

/// Convert a byte offset range to an LSP range.
pub fn range(self: *const PositionMapper, start: u32, end: u32) ?Range {
    const start_pos = self.position(start) orelse return null;
    const end_pos = self.position(end) orelse return null;
    return .{ .start = start_pos, .end = end_pos };
}

/// Convert an LSP position to a byte offset. Same result as
/// `Handler.lspPositionToOffset`, including its `null` returns for
/// out-of-domain positions and its mid-surrogate-pair snapping.
pub fn offsetOf(self: *const PositionMapper, pos: Position) ?usize {
    // The linear helper walks lines and returns null when it runs out of
    // source before reaching `pos.line`; an out-of-range index here is the
    // same condition.
    if (pos.line >= self.line_starts.len) return null;
    return scanToCharacter(self.source, self.line_starts[pos.line], pos.character);
}

/// Index of the greatest line whose start is `<= offset`. `line_starts[0]`
/// is 0, so this always finds one.
fn lineAt(self: *const PositionMapper, offset: u32) u32 {
    var lo: u32 = 0;
    var hi: u32 = @intCast(self.line_starts.len);
    while (hi - lo > 1) {
        const mid = lo + (hi - lo) / 2;
        if (self.line_starts[mid] <= offset) lo = mid else hi = mid;
    }
    return lo;
}

// =========================================================================
// Seedable scan primitives — the shared bodies
// =========================================================================

/// Walk from `start_i` (which must be a line start, with line number
/// `start_line`) to `offset`, counting lines and UTF-16 code units. This is
/// the body of `Handler.offsetToLspPosition`'s loop with the seed lifted
/// out; that function calls it with `(0, 0)`.
///
/// Returns `null` if `offset` is past end-of-source, lands mid-UTF-8
/// sequence, or the walk crosses a truncated sequence.
pub fn scanToPosition(source: []const u8, start_i: u32, start_line: u32, offset: u32) ?Position {
    if (offset > source.len) return null;
    var line: u32 = start_line;
    var col: u32 = 0;
    var i: u32 = start_i;
    while (i < offset) {
        const c = source[i];
        if (c == '\n') {
            line += 1;
            col = 0;
            i += 1;
            continue;
        }
        if (c == '\r') {
            line += 1;
            col = 0;
            i += 1;
            if (i < offset and i < source.len and source[i] == '\n') i += 1;
            continue;
        }
        const seq_len = std.unicode.utf8ByteSequenceLength(c) catch return null;
        if (i + seq_len > source.len) return null;
        if (i + seq_len > offset) return null;
        col += if (seq_len == 4) 2 else 1;
        i += @intCast(seq_len);
    }
    return .{ .line = line, .character = col };
}

/// Width of `bytes` in UTF-16 code units.
///
/// Positions are not the only thing the protocol counts in the negotiated
/// encoding: a semantic token carries a bare `length`, which is the one
/// place a width travels without a matching end position. Byte lengths
/// overshoot there on every non-ASCII token.
///
/// Total, unlike the scans above. A byte that cannot begin a UTF-8
/// sequence, or one whose sequence runs off the end, counts as a single
/// unit — the width a decoder's U+FFFD substitution occupies. Callers hand
/// over lexer spans and need *some* width; returning null the way a
/// malformed position does would silently drop the token's highlight
/// instead of nudging it.
pub fn utf16Len(bytes: []const u8) u32 {
    var units: u32 = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            units += 1;
            i += 1;
            continue;
        };
        if (i + seq_len > bytes.len) {
            units += 1;
            i += 1;
            continue;
        }
        units += if (seq_len == 4) 2 else 1;
        i += seq_len;
    }
    return units;
}

/// Walk `character` UTF-16 code units forward from `start_i` (a line
/// start), returning the byte offset. This is the body of
/// `Handler.lspPositionToOffset`'s column loop with the seed lifted out.
///
/// Returns `null` when `character` runs past end-of-line or end-of-source,
/// or lands mid-UTF-8-sequence. A `character` landing inside a UTF-16
/// surrogate pair snaps to the boundary before the pair.
pub fn scanToCharacter(source: []const u8, start_i: usize, character: u32) ?usize {
    var col: u32 = 0;
    var i: usize = start_i;
    var snapped = false;
    while (col < character and i < source.len) {
        if (source[i] == '\r' or source[i] == '\n') return null;
        const seq_len = std.unicode.utf8ByteSequenceLength(source[i]) catch return null;
        if (i + seq_len > source.len) return null;
        const units: u32 = if (seq_len == 4) 2 else 1;
        if (col + units > character) {
            // `character` lands mid-surrogate-pair — snap to the boundary
            // before the pair. LSP spec is silent on mid-pair positions;
            // this matches what most servers do.
            snapped = true;
            break;
        }
        col += units;
        i += seq_len;
    }
    if (col != character and !snapped) return null;
    return i;
}
