//! Bidirectional origin mapping for assembled pngine WGSL
//! (pngine-shaders phase 02, Task 3).
//!
//! The assembler writes the text, one ordered `Segment` per copied, blanked,
//! hoisted, or synthetic byte run, and a pngine-compatible `LineRow` per
//! contributing part. This module reads those two tables; it never rescans
//! the text to guess where a byte came from. That is what keeps the line
//! contract and the byte index in agreement by construction.
//!
//! Two coordinate domains meet here:
//!
//! - **assembled** offsets are local to one `Assembled.text`;
//! - **origin** offsets are local to the author text of the part named by
//!   `OriginKey` (a `:code` string or a `:file`'s contents — irrelevant to
//!   mapping, which only needs the part identity).
//!
//! A value never mixes them: `ByteRange` in an assembled argument is
//! assembled-local, `OriginRange.range` is origin-local.
//!
//! ## Rules
//!
//! - Body and hoisted bytes map linearly and exactly. A hoisted directive's
//!   copy is byte-for-byte the author's directive, so a diagnostic on it
//!   lands on the author's own line and column.
//! - A blanked directive's assembled bytes are spaces with no author
//!   counterpart: assembled→origin refuses them. Origin→assembled maps the
//!   FIRST occurrence's bytes to its same-origin/same-source hoisted twin.
//!   A duplicate blanked directive has no copy of its own and declines
//!   rather than pointing at another occurrence.
//! - The synthetic newline that terminates a part maps to a zero-width
//!   location at that part's EOF.
//! - Assembled positions at or past the end collapse to the root's EOF,
//!   mirroring pngine's `locate` last-row fallback.
//! - A range is only mappable when one contiguous origin range represents
//!   all of it. Ranges crossing parts, blanked bytes, or the synthetic
//!   newline return `null`; callers split or refuse, and no range is ever
//!   silently clamped.
//!
//! ## Cost
//!
//! Every function is allocation-free and bounded by the segment count
//! (`parts + hoisted directives + terminators`, under a few thousand for a
//! maximal program). `locateLine` is O(rows), mirroring pngine.
//!
//! This is pure library code: no `build_options`, no `std.Io`, no filesystem,
//! no `Store`. The same module compiles inside pngine's test process.

const std = @import("std");

const types = @import("Types.zig");

/// A half-open byte range. `end` is exclusive.
pub const ByteRange = struct {
    start: u32,
    end: u32,
};

/// A root's stable identity: `(program slot, source-order part index)`.
pub const RootId = types.PartId;

/// The part an assembled range came from. Byte ranges are local to that
/// part's own author text, never to the assembled module.
pub const OriginKey = types.PartId;

/// One row of the assembled line table: which part wrote assembled lines
/// `[first_line, first_line + line_count)`.
pub const LineRow = struct {
    /// The part the lines came from.
    origin: OriginKey,
    /// That part's form name, so a diagnostic can name its origin without
    /// a second lookup.
    name: []const u8,
    /// 1-based first line in the assembled text.
    first_line: u32,
    /// How many assembled lines this row covers. At least one.
    line_count: u32,
    /// 1-based line in the origin's own text where this row starts. A body
    /// row is always 1; a hoisted directive row is the line the author
    /// wrote it on.
    src_line: u32 = 1,
    /// True for the row holding the root module's own text.
    is_root: bool = false,
};

/// What a byte segment represents.
pub const SegmentKind = enum {
    /// Author body bytes copied unchanged.
    body,
    /// A hoisted directive's copy at the top of the assembled text.
    hoisted,
    /// An original directive blanked in place: its bytes became spaces,
    /// newlines kept, so later columns did not move.
    blanked,
    /// A newline appended because a part did not end with one. Its source
    /// range is zero-width at that part's EOF.
    terminator,
};

/// One ordered piece of the assembled text and the author range it came
/// from. Segments are the byte-offset half of mapping; `LineRow` remains
/// the parity contract with pngine.
pub const Segment = struct {
    /// Range in the assembled text.
    assembled: ByteRange,
    /// Part whose author text this piece represents.
    origin: OriginKey,
    /// Range in that part's own text. Zero-width for a `.terminator`.
    source: ByteRange,
    kind: SegmentKind,
};

/// A located line: pngine's `locate` answer.
pub const LocatedLine = struct {
    origin: OriginKey,
    /// The contributing part's name.
    name: []const u8,
    /// 1-based line in the origin's own author text.
    line: u32,
    is_root: bool,
};

/// A byte range plus the author part it belongs to. `range` is local to
/// that origin's text, never to the assembled module.
pub const OriginRange = struct {
    origin: OriginKey,
    range: ByteRange,
};

/// An author-local byte offset and the part it belongs to.
pub const OriginOffset = struct {
    origin: OriginKey,
    offset: u32,
};

/// Map a 1-based line of the assembled text to its origin and local line.
///
/// Mirrors pngine's `Assembled.locate` exactly, including its fallback:
/// a line below the last row is attributed to the last row's origin (the
/// root, whose row is always last). On the no-import fast path there are no
/// rows and the answer is the root itself, unchanged.
///
/// Complexity: O(rows), bounded by `MAX_FRAGMENTS + 1 + hoisted`.
pub fn locateLine(
    rows: []const LineRow,
    root: RootId,
    root_name: []const u8,
    line: u32,
) LocatedLine {
    std.debug.assert(line >= 1);
    if (rows.len == 0) {
        return .{ .origin = root, .name = root_name, .line = line, .is_root = true };
    }
    for (rows) |row| {
        if (line < row.first_line) continue;
        if (line >= row.first_line + row.line_count) continue;
        return .{
            .origin = row.origin,
            .name = row.name,
            .line = line - row.first_line + row.src_line,
            .is_root = row.is_root,
        };
    }
    // Past the end: pngine attributes an unterminated block reported on the
    // line after the last to the last row, which is always the root's.
    const last = rows[rows.len - 1];
    return .{
        .origin = last.origin,
        .name = last.name,
        .line = line - last.first_line + last.src_line,
        .is_root = last.is_root,
    };
}

/// Map an assembled byte range to one contiguous author range.
///
/// Returns `null` when no single origin range represents the input:
/// a range crossing parts, one that touches blanked synthetic bytes, or one
/// that starts inside the text but extends past the assembled EOF. An empty
/// range maps the byte position under it, so a cursor works like a
/// zero-width diagnostic. A range wholly on a synthetic terminating newline
/// maps to a zero-width location at that part's EOF.
pub fn toOrigin(
    text_len: usize,
    segments: []const Segment,
    root: RootId,
    range: ByteRange,
) ?OriginRange {
    if (range.start > range.end) return null;

    // Past the assembled end: all positions collapse to the root's author
    // EOF, exactly like pngine's last-row locate fallback.
    if (@as(usize, range.start) >= text_len) {
        const eof = originEnd(segments, root) orelse 0;
        return .{ .origin = root, .range = .{ .start = eof, .end = eof } };
    }

    if (range.start == range.end) {
        const mapped = offsetToOrigin(text_len, segments, root, range.start) orelse return null;
        return .{ .origin = mapped.origin, .range = .{ .start = mapped.offset, .end = mapped.offset } };
    }

    // A range that begins inside the text but ends beyond it cannot be
    // represented; clamping it would invent author bytes.
    if (@as(usize, range.end) > text_len) return null;

    const seg = segmentAt(segments, range.start) orelse return null;
    if (range.end > seg.assembled.end) return null;

    return switch (seg.kind) {
        // Blanking replaced author bytes with spaces. There is no honest
        // origin for these assembled bytes.
        .blanked => null,
        // The synthetic newline belongs to no author line; collapse it.
        .terminator => .{
            .origin = seg.origin,
            .range = .{ .start = seg.source.start, .end = seg.source.start },
        },
        .body, .hoisted => .{
            .origin = seg.origin,
            .range = .{
                .start = seg.source.start + (range.start - seg.assembled.start),
                .end = seg.source.start + (range.end - seg.assembled.start),
            },
        },
    };
}

/// Map an assembled byte offset to its author-local offset.
///
/// `offset >= text_len` is the root's author EOF. Blanked bytes, which are
/// synthetic spaces, have no answer.
pub fn offsetToOrigin(
    text_len: usize,
    segments: []const Segment,
    root: RootId,
    offset: u32,
) ?OriginOffset {
    if (@as(usize, offset) >= text_len) {
        const eof = originEnd(segments, root) orelse 0;
        return .{ .origin = root, .offset = eof };
    }
    const seg = segmentAt(segments, offset) orelse return null;
    return switch (seg.kind) {
        .body, .hoisted => .{
            .origin = seg.origin,
            .offset = seg.source.start + (offset - seg.assembled.start),
        },
        .terminator => .{ .origin = seg.origin, .offset = seg.source.start },
        .blanked => null,
    };
}

/// Map an author-local range to one contiguous assembled range.
///
/// A range on a first-occurrence blanked directive maps to that directive's
/// hoisted copy; a duplicate directive with no same-origin/same-source copy
/// returns `null`. A range split between a hoisted copy and the part body
/// (for example one covering the directive plus the next declaration) also
/// returns `null`: no single assembled range represents it.
pub fn fromOrigin(
    segments: []const Segment,
    origin: OriginKey,
    range: ByteRange,
) ?ByteRange {
    const end = originEnd(segments, origin) orelse return null;
    if (range.start > range.end or range.end > end) return null;

    if (range.start == range.end) {
        const mapped = offsetFromOrigin(segments, .{ .origin = origin, .offset = range.start }) orelse return null;
        return .{ .start = mapped, .end = mapped };
    }

    // Body and hoisted copies map linearly.
    for (segments) |seg| {
        if (!sameOrigin(seg.origin, origin)) continue;
        if (seg.kind != .body and seg.kind != .hoisted) continue;
        if (range.start < seg.source.start or range.end > seg.source.end) continue;
        return .{
            .start = seg.assembled.start + (range.start - seg.source.start),
            .end = seg.assembled.start + (range.end - seg.source.start),
        };
    }

    // A blanked original maps to its semantic copy, but only the copy that
    // carries this exact origin and source span. A duplicate declines.
    for (segments) |seg| {
        if (!sameOrigin(seg.origin, origin)) continue;
        if (seg.kind != .blanked) continue;
        if (range.start < seg.source.start or range.end > seg.source.end) continue;
        const twin = hoistedTwin(segments, seg) orelse return null;
        return .{
            .start = twin.assembled.start + (range.start - twin.source.start),
            .end = twin.assembled.start + (range.end - twin.source.start),
        };
    }

    return null;
}

/// Map an author-local offset to an assembled offset.
///
/// Inside a first-occurrence directive, the hoisted copy wins: that is the
/// token the compiler sees. A duplicate blanked directive has no copy and
/// returns `null`. The offset just past the origin's own text maps to the
/// end of that origin's contribution (the synthetic newline's start).
pub fn offsetFromOrigin(segments: []const Segment, at: OriginOffset) ?u32 {
    const end = originEnd(segments, at.origin) orelse return null;
    if (at.offset > end) return null;

    // Hoisted copies first: a request on an original directive must reach
    // the copy the compiler sees.
    for (segments) |seg| {
        if (!sameOrigin(seg.origin, at.origin)) continue;
        if (seg.kind != .hoisted) continue;
        if (at.offset < seg.source.start or at.offset >= seg.source.end) continue;
        return seg.assembled.start + (at.offset - seg.source.start);
    }

    for (segments) |seg| {
        if (!sameOrigin(seg.origin, at.origin)) continue;
        if (seg.kind != .body) continue;
        if (at.offset < seg.source.start or at.offset >= seg.source.end) continue;
        return seg.assembled.start + (at.offset - seg.source.start);
    }

    for (segments) |seg| {
        if (!sameOrigin(seg.origin, at.origin)) continue;
        if (seg.kind != .blanked) continue;
        if (at.offset < seg.source.start or at.offset >= seg.source.end) continue;
        const twin = hoistedTwin(segments, seg) orelse return null;
        return twin.assembled.start + (at.offset - twin.source.start);
    }

    // Just past the origin's text: the end of its own contribution, which
    // is the synthetic newline's start when one was appended.
    if (at.offset == end) {
        return originAssembledEof(segments, at.origin) orelse return null;
    }

    // A zero-width boundary (for example the newline after a hoisted
    // directive, or a directive's end where no body follows).
    for (segments) |seg| {
        if (!sameOrigin(seg.origin, at.origin)) continue;
        if (seg.kind == .blanked) continue;
        if (seg.source.start == at.offset) return seg.assembled.start;
    }

    return null;
}

// =========================================================================
// Internals
// =========================================================================

fn sameOrigin(a: OriginKey, b: OriginKey) bool {
    return a.program == b.program and a.index == b.index;
}

fn segmentAt(segments: []const Segment, offset: u32) ?Segment {
    for (segments) |seg| {
        if (offset >= seg.assembled.start and offset < seg.assembled.end) return seg;
    }
    return null;
}

/// The highest author offset this origin contributes, i.e. its text length.
/// `null` when the origin has no segment at all.
fn originEnd(segments: []const Segment, origin: OriginKey) ?u32 {
    var found = false;
    var end: u32 = 0;
    for (segments) |seg| {
        if (!sameOrigin(seg.origin, origin)) continue;
        found = true;
        if (seg.source.end > end) end = seg.source.end;
    }
    return if (found) end else null;
}

/// The assembled offset that stands for this origin's EOF. A trailing
/// synthetic newline has no author bytes, so its START is EOF; a part that
/// ended with an authored newline ends at the body's end.
fn originAssembledEof(segments: []const Segment, origin: OriginKey) ?u32 {
    var found = false;
    var best: Segment = undefined;
    for (segments) |seg| {
        if (!sameOrigin(seg.origin, origin)) continue;
        if (!found or seg.assembled.end >= best.assembled.end) {
            best = seg;
            found = true;
        }
    }
    if (!found) return null;
    return if (best.kind == .terminator) best.assembled.start else best.assembled.end;
}

fn hoistedTwin(segments: []const Segment, blanked: Segment) ?Segment {
    for (segments) |seg| {
        if (seg.kind != .hoisted) continue;
        if (!sameOrigin(seg.origin, blanked.origin)) continue;
        if (seg.source.start != blanked.source.start) continue;
        if (seg.source.end != blanked.source.end) continue;
        return seg;
    }
    return null;
}
