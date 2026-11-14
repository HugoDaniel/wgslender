//! Pure pngine fragment assembly (pngine-shaders phase 02, Tasks 1–3).
//!
//! pngine's WGSL preprocessor treats a root as its transitive imports in
//! post-order, each fragment exactly once, followed by the root's own
//! text. This module reproduces that walk over the phase-01 `Program`
//! graph. It is *pure library code*: the caller supplies every part's
//! text, the assembler never opens a file and never touches `std.Io`.
//! That is what lets the same module compile inside pngine's test
//! process for the Task 5 parity gate, where neither `build_options`
//! nor the project `Store` exists.
//!
//! Task 1 establishes the `Assembled` shape and builds the line rows and
//! byte segments while the output is written. Task 2 adds the directive
//! hoist and newline termination on top of the same append loop; nothing
//! here rescans the output afterwards.
//!
//! ## Invariants
//!
//! - The import graph is acyclic; a cycle is reported with its ordered
//!   path instead of looping.
//! - Each fragment contributes its text exactly once per root, however
//!   many import paths reach it.
//! - The walk is an explicit stack with a bounded loop. No recursion, so
//!   a malformed document cannot exhaust the Zig stack.
//! - A root with no imports allocates no rows: with one origin there is
//!   nothing to disambiguate, mirroring pngine's fast path.

const std = @import("std");

const types = @import("Types.zig");

const Allocator = std.mem.Allocator;

/// Re-exported so a consumer (including pngine's parity test process)
/// needs only this module to name the graph it consumes.
pub const Types = types;

/// Fragments per document. Matches pngine's `MAX_FRAGMENTS` and the
/// schema's module-count ceiling.
pub const MAX_FRAGMENTS: u32 = 1024;

/// Imports per form. Matches pngine's `MAX_IMPORTS` and the schema's
/// `wgsl-ref-list` bound.
pub const MAX_IMPORTS: u32 = 64;

/// Depth of the assembly walk. The root's own text is not a depth level;
/// a chain of 64 fragments is accepted, 65 is refused.
pub const MAX_DEPTH: u32 = 64;

/// A root's stable identity: `(program slot, source-order part index)`.
pub const RootId = types.PartId;

/// The part an assembled range came from. Byte ranges are local to that
/// part's own author text, never to the assembled module.
pub const OriginKey = types.PartId;

/// A half-open byte range. `end` is exclusive.
pub const ByteRange = struct {
    start: u32,
    end: u32,
};

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

/// An assembled module: the text wgslender analyzes, the pngine-compatible
/// line table, and the byte segments Task 3 converts in both directions.
pub const Assembled = struct {
    text: []const u8,
    rows: []const LineRow,
    segments: []const Segment,
    root: RootId,

    /// Release the text and every table. Safe on every successfully
    /// returned value, including the no-import fast path.
    pub fn deinit(self: *Assembled, gpa: Allocator) void {
        gpa.free(@constCast(self.text));
        if (self.rows.len > 0) gpa.free(@constCast(self.rows));
        if (self.segments.len > 0) gpa.free(@constCast(self.segments));
        self.* = undefined;
    }
};

/// Bounds for one assembly. The defaults are pngine's published limits;
/// tests lower them to exercise each boundary without building a
/// thousand-file fixture.
pub const Limits = struct {
    max_fragments: u32 = MAX_FRAGMENTS,
    max_imports: u32 = MAX_IMPORTS,
    max_depth: u32 = MAX_DEPTH,
};

/// Names of the fragments on the walk's current path when a cycle was
/// found, filled on `error.ImportCycle`. Read it as
/// `mesh -> material -> mesh`.
pub const CyclePath = struct {
    pub const MAX = MAX_DEPTH + 1;

    names: [MAX][]const u8 = undefined,
    len: u32 = 0,

    pub fn slice(self: *const CyclePath) []const []const u8 {
        return self.names[0..self.len];
    }
};

/// Located detail for a graph refusal. Error values in Zig carry no
/// payload, so a caller that needs to report *which* edge failed passes
/// one of these; `at`, `unknown`, and `cycle` are meaningful only for the
/// errors named in their doc comments.
pub const Failure = struct {
    /// The root whose assembly was requested.
    root: RootId,
    /// `UnknownFragment`: the part whose `:imports` list held the bad
    /// name. `MissingSource`: the part whose text was absent.
    /// `TooDeep`: the part that crossed a bound.
    at: ?types.PartId = null,
    /// `UnknownFragment`: the unresolved import spelling, borrowed from
    /// the program.
    unknown: []const u8 = &.{},
    /// `ImportCycle`: the ordered path, ending with the repeated name.
    cycle: CyclePath = .{},
};

/// Why one root could not be assembled.
pub const Error = error{
    /// The import graph has a cycle. `Failure.cycle` names it.
    ImportCycle,
    /// An `:imports` entry names no `wgsl` fragment in this program.
    UnknownFragment,
    /// More than `max_depth` levels or `max_fragments` reached, or an
    /// `:imports` list longer than `max_imports`.
    TooDeep,
    /// A reached part has no source text. The assembler never substitutes
    /// an empty document for a missing file.
    MissingSource,
    OutOfMemory,
};

/// Assemble one root with pngine's published bounds.
///
/// `sources` is indexed by source-order part index; `null` means the
/// caller could not resolve that part's text. Unreached parts are never
/// inspected, so a broken unrelated part cannot fail this root.
pub fn assemble(
    gpa: Allocator,
    program: *const types.Program,
    sources: []const ?[]const u8,
    root: RootId,
    failure: ?*Failure,
) Error!Assembled {
    return assembleWithLimits(gpa, program, sources, root, .{}, failure);
}

/// `assemble` with explicit bounds. Production callers use the defaults;
/// tests lower `max_depth`, `max_fragments`, or `max_imports` to reach a
/// boundary without a large fixture.
pub fn assembleWithLimits(
    gpa: Allocator,
    program: *const types.Program,
    sources: []const ?[]const u8,
    root: RootId,
    limits: Limits,
    failure: ?*Failure,
) Error!Assembled {
    std.debug.assert(limits.max_depth > 0);
    std.debug.assert(limits.max_fragments > 0);
    std.debug.assert(limits.max_imports > 0);
    std.debug.assert(root.index < program.parts.len);
    if (failure) |f| f.* = .{ .root = root };

    const root_part = program.parts[root.index];
    std.debug.assert(root_part.isRoot());

    // The fast path: no imports means the root's own text IS the module.
    // No rows, mirroring pngine's empty line table; one body segment so
    // byte mapping still has an origin without special-casing callers.
    if (root_part.imports.len == 0) return fastPath(gpa, sources, root, failure);

    if (root_part.imports.len > limits.max_imports) {
        if (failure) |f| f.at = root;
        return error.TooDeep;
    }

    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(gpa);
    try postOrder(gpa, program, sources, root, root_part.imports, limits, &order, failure);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var rows: std.ArrayList(LineRow) = .empty;
    errdefer rows.deinit(gpa);
    var segments: std.ArrayList(Segment) = .empty;
    errdefer segments.deinit(gpa);

    var line: u32 = 1;
    for (order.items) |part_index| {
        const part = program.parts[part_index];
        const text = sourceAt(sources, part_index) orelse {
            if (failure) |f| f.at = .{ .program = root.program, .index = part_index };
            return error.MissingSource;
        };
        try appendBody(gpa, &out, &segments, partId(root, part_index), text);
        const count = lineCount(text);
        try rows.append(gpa, .{
            .origin = partId(root, part_index),
            .name = part.name,
            .first_line = line,
            .line_count = count,
            .is_root = false,
        });
        line += count;
    }

    const root_text = sourceAt(sources, root.index) orelse {
        if (failure) |f| f.at = root;
        return error.MissingSource;
    };
    try appendBody(gpa, &out, &segments, root, root_text);
    try rows.append(gpa, .{
        .origin = root,
        .name = root_part.name,
        .first_line = line,
        .line_count = lineCount(root_text),
        .is_root = true,
    });

    // Taken one at a time with an `errdefer` between them: after the
    // first `toOwnedSlice` succeeds, the source list no longer owns its
    // buffer, so a later allocation failure must free it here.
    const text = out.toOwnedSlice(gpa) catch return error.OutOfMemory;
    errdefer gpa.free(text);
    const row_slice = rows.toOwnedSlice(gpa) catch return error.OutOfMemory;
    errdefer gpa.free(row_slice);
    const segment_slice = segments.toOwnedSlice(gpa) catch return error.OutOfMemory;

    return .{
        .text = text,
        .rows = row_slice,
        .segments = segment_slice,
        .root = root,
    };
}

fn fastPath(
    gpa: Allocator,
    sources: []const ?[]const u8,
    root: RootId,
    failure: ?*Failure,
) Error!Assembled {
    const source = sourceAt(sources, root.index) orelse {
        if (failure) |f| f.at = root;
        return error.MissingSource;
    };
    const text = gpa.dupe(u8, source) catch return error.OutOfMemory;
    errdefer gpa.free(text);
    const segment_slice = gpa.alloc(Segment, 1) catch return error.OutOfMemory;
    segment_slice[0] = .{
        .assembled = .{ .start = 0, .end = @intCast(source.len) },
        .origin = root,
        .source = .{ .start = 0, .end = @intCast(source.len) },
        .kind = .body,
    };
    return .{
        .text = text,
        .rows = &.{},
        .segments = segment_slice,
        .root = root,
    };
}

fn appendBody(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    segments: *std.ArrayList(Segment),
    origin: OriginKey,
    text: []const u8,
) Error!void {
    if (text.len == 0) return;
    const start: u32 = @intCast(out.items.len);
    out.appendSlice(gpa, text) catch return error.OutOfMemory;
    segments.append(gpa, .{
        .assembled = .{ .start = start, .end = @intCast(out.items.len) },
        .origin = origin,
        .source = .{ .start = 0, .end = @intCast(text.len) },
        .kind = .body,
    }) catch return error.OutOfMemory;
}

/// How many assembled lines `text` occupies, counting like pngine's
/// `appendTerminated` (without the termination Task 2 adds): an empty
/// part is one line, and a closing newline does not start another.
fn lineCount(text: []const u8) u32 {
    var lines: u32 = 1;
    for (text) |c| {
        if (c == '\n') lines += 1;
    }
    if (text.len > 0 and text[text.len - 1] == '\n') lines -= 1;
    return lines;
}

fn sourceAt(sources: []const ?[]const u8, part_index: u32) ?[]const u8 {
    if (part_index >= sources.len) return null;
    return sources[part_index];
}

fn partId(root: RootId, part_index: u32) types.PartId {
    return .{ .program = root.program, .index = part_index };
}

/// Depth-first post-order over the import graph, visiting each fragment
/// once. Explicit stack, bounded loop, no recursion. Mirrors pngine's
/// `postOrder` (`pngine/src/dsl_sjon/fragments.zig:789-880`).
fn postOrder(
    gpa: Allocator,
    program: *const types.Program,
    sources: []const ?[]const u8,
    root: RootId,
    root_imports: []const types.ImportRef,
    limits: Limits,
    out: *std.ArrayList(u32),
    failure: ?*Failure,
) Error!void {
    _ = sources;

    const Frame = struct {
        part: u32,
        /// Index into that part's `imports` of the next child to descend.
        next: u32,
    };
    var stack: [MAX_DEPTH]Frame = undefined;
    var depth: u32 = 0;

    // `on_path` mirrors the stack for the cycle test; `done` records what
    // has already been emitted so a diamond contributes once.
    var on_path: std.ArrayList(u32) = .empty;
    defer on_path.deinit(gpa);
    var done: std.ArrayList(u32) = .empty;
    defer done.deinit(gpa);

    for (root_imports) |root_import| {
        const start = program.findFragment(root_import.name) orelse {
            if (failure) |f| {
                f.at = root;
                f.unknown = root_import.name;
            }
            return error.UnknownFragment;
        };
        if (contains(done.items, start)) continue;

        if (program.parts[start].imports.len > limits.max_imports) {
            if (failure) |f| f.at = partId(root, start);
            return error.TooDeep;
        }

        depth = 1;
        stack[0] = .{ .part = start, .next = 0 };
        on_path.append(gpa, start) catch return error.OutOfMemory;

        // pngine's loop bound: every frame consumes at most `max_imports`
        // iterations, and at most `max_depth` frames are live at once.
        const max_steps: u64 = @as(u64, limits.max_depth) *
            @as(u64, limits.max_imports) *
            @as(u64, limits.max_imports);
        var steps: u64 = 0;

        while (depth > 0) {
            steps += 1;
            if (steps > max_steps) return error.TooDeep;

            const top = &stack[depth - 1];
            const top_part = program.parts[top.part];
            if (top.next < top_part.imports.len) {
                const child_name = top_part.imports[top.next].name;
                top.next += 1;

                const child = program.findFragment(child_name) orelse {
                    if (failure) |f| {
                        f.at = partId(root, top.part);
                        f.unknown = child_name;
                    }
                    return error.UnknownFragment;
                };
                if (contains(done.items, child)) continue;
                if (contains(on_path.items, child)) {
                    if (failure) |f| {
                        f.at = partId(root, child);
                        fillCycle(&f.cycle, program, on_path.items, child);
                    }
                    return error.ImportCycle;
                }
                if (depth >= limits.max_depth) {
                    if (failure) |f| f.at = partId(root, child);
                    return error.TooDeep;
                }
                if (program.parts[child].imports.len > limits.max_imports) {
                    if (failure) |f| f.at = partId(root, child);
                    return error.TooDeep;
                }
                stack[depth] = .{ .part = child, .next = 0 };
                depth += 1;
                on_path.append(gpa, child) catch return error.OutOfMemory;
                continue;
            }

            // Children exhausted: emit this one and pop.
            if (out.items.len >= limits.max_fragments) {
                if (failure) |f| f.at = partId(root, top.part);
                return error.TooDeep;
            }
            out.append(gpa, top.part) catch return error.OutOfMemory;
            done.append(gpa, top.part) catch return error.OutOfMemory;
            _ = on_path.pop();
            depth -= 1;
        }
    }
}

fn contains(haystack: []const u32, needle: u32) bool {
    for (haystack) |item| {
        if (item == needle) return true;
    }
    return false;
}

/// Record the path from where `closing` first appears on the stack to the
/// end, plus `closing` again, so it reads `mesh -> material -> mesh`.
fn fillCycle(
    cycle: *CyclePath,
    program: *const types.Program,
    path: []const u32,
    closing: u32,
) void {
    var start: usize = 0;
    for (path, 0..) |part, i| {
        if (part == closing) {
            start = i;
            break;
        }
    }
    cycle.len = 0;
    for (path[start..]) |part| {
        if (cycle.len == CyclePath.MAX) return;
        cycle.names[cycle.len] = program.parts[part].name;
        cycle.len += 1;
    }
    if (cycle.len < CyclePath.MAX) {
        cycle.names[cycle.len] = program.parts[closing].name;
        cycle.len += 1;
    }
}
