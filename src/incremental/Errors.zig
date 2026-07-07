//! Error-list plumbing for the incremental hot path.
//!
//! Four helpers cooperate around the splice boundary:
//!
//!   - `fixupErrors` reshapes a previous parse's error list across an
//!     anchor edit: drops entries that belonged to the old subtree and
//!     shifts every entry strictly after the anchor by `delta`.
//!   - `filterNonVisitErrors` / `filterVisitErrors` split a
//!     Parser-collected list into its two internally-sorted runs — the
//!     Pass-1 grammar errors and the Pass-2 visit errors (E0102) — which
//!     `parseFull` then re-joins by position.
//!   - `mergeErrorsByPos` is a two-pointer merge that joins two
//!     source-ordered ParseError slices into a single fresh slice.
//!
//! All allocate from the caller-provided arena and never mutate their
//! inputs. The fixup/merge pair is the canonical way to assemble
//! `ReparseResult.errors` after every successful in-place splice; the
//! filter-pair/merge is the equivalent for `parseFull`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("../Ast.zig");
const Parser = @import("../Parser.zig");

/// Splice prev's error list across the anchor edit. Drops entries that
/// belonged to the old subtree (they're about to be replaced by the
/// add-walk's output) and shifts downstream entries by `delta`.
///
/// Allocates a new slice in `arena`; does not mutate `prev_errors`.
/// Both `pos` and `end` are shifted; an error whose `[pos, end)`
/// straddles `old_anchor.start` is dropped because its end no longer
/// describes a valid byte span after the splice.
///
/// Decision table:
///
/// | position vs old_anchor                         | action                |
/// |------------------------------------------------|-----------------------|
/// | pos < start AND end <= start                   | keep, unshifted       |
/// | pos < start AND end > start (straddles)        | drop                  |
/// | start <= pos < end (inside)                    | drop                  |
/// | pos >= end                                     | keep, shift by delta  |
pub fn fixupErrors(
    arena: Allocator,
    prev_errors: []const Parser.ParseError,
    old_anchor: Ast.Span,
    delta: i64,
) Allocator.Error![]Parser.ParseError {
    var out: std.ArrayList(Parser.ParseError) = .empty;
    try out.ensureTotalCapacity(arena, prev_errors.len);
    for (prev_errors) |e| {
        if (e.pos < old_anchor.start) {
            // Strictly before the anchor. Drop only if a recorded
            // `end` straddles into the deleted region (`end == 0` is
            // the "no end recorded" sentinel — leave those alone).
            if (e.end != 0 and e.end > old_anchor.start) continue;
            out.appendAssumeCapacity(e);
        } else if (e.pos < old_anchor.end) {
            // Inside the deleted anchor. Belonged to the old subtree.
            continue;
        } else {
            // Strictly after the anchor. Shift `pos`; shift `end` only
            // when it was actually recorded (non-zero) so we don't turn
            // the sentinel into a spurious offset.
            const new_pos: i64 = @as(i64, e.pos) + delta;
            const new_end: u32 = if (e.end == 0)
                0
            else
                @intCast(@as(i64, e.end) + delta);
            out.appendAssumeCapacity(.{
                .message = e.message,
                .pos = @intCast(new_pos),
                .end = new_end,
                .code = e.code,
            });
        }
    }
    return out.toOwnedSlice(arena);
}

/// Keep the parser's Pass-1 grammar/redeclaration errors
/// (E0001/E0004/E0101/E0401, plus codeless recovery entries), dropping
/// its Pass-2 visit errors (E0102). Paired with `filterVisitErrors`:
/// `Parser.parse` appends every Pass-2 (E0102) entry after all Pass-1
/// entries, so its raw `errors` list is two internally source-ordered
/// runs. Splitting on E0102 recovers those runs; `mergeErrorsByPos`
/// then joins them into one position-ordered list for `parseFull`.
pub fn filterNonVisitErrors(
    arena: Allocator,
    in: []const Parser.ParseError,
) Allocator.Error![]Parser.ParseError {
    var out: std.ArrayList(Parser.ParseError) = .empty;
    try out.ensureTotalCapacity(arena, in.len);
    for (in) |e| {
        if (std.mem.eql(u8, e.code, "E0102")) continue;
        out.appendAssumeCapacity(e);
    }
    return out.toOwnedSlice(arena);
}

/// The complement of `filterNonVisitErrors`: keep only the parser's
/// Pass-2 visit errors (E0102), dropping every Pass-1 grammar entry.
/// See `filterNonVisitErrors` for why `parseFull` splits the list.
pub fn filterVisitErrors(
    arena: Allocator,
    in: []const Parser.ParseError,
) Allocator.Error![]Parser.ParseError {
    var out: std.ArrayList(Parser.ParseError) = .empty;
    try out.ensureTotalCapacity(arena, in.len);
    for (in) |e| {
        if (std.mem.eql(u8, e.code, "E0102")) out.appendAssumeCapacity(e);
    }
    return out.toOwnedSlice(arena);
}

/// Two-pointer merge of two source-ordered ParseError lists into a
/// freshly arena-allocated slice, also in source order. Used to combine
/// (a) the parser's Pass-1 grammar run with its Pass-2 visit run after a
/// full parse, and (b) prev's spliced-through errors with the hot path's
/// add-walk output. Both inputs may be empty.
pub fn mergeErrorsByPos(
    arena: Allocator,
    a: []const Parser.ParseError,
    b: []const Parser.ParseError,
) Allocator.Error![]Parser.ParseError {
    if (a.len == 0 and b.len == 0) return &.{};
    var out = try arena.alloc(Parser.ParseError, a.len + b.len);
    var i: usize = 0;
    var j: usize = 0;
    var k: usize = 0;
    while (i < a.len and j < b.len) : (k += 1) {
        if (a[i].pos <= b[j].pos) {
            out[k] = a[i];
            i += 1;
        } else {
            out[k] = b[j];
            j += 1;
        }
    }
    while (i < a.len) : ({
        i += 1;
        k += 1;
    }) out[k] = a[i];
    while (j < b.len) : ({
        j += 1;
        k += 1;
    }) out[k] = b[j];
    return out;
}
