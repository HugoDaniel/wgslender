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
const directives = @import("Directives.zig");
const mapping = @import("Mapping.zig");

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

/// Module-scope directives hoisted into one assembled module. pngine's
/// `MAX_DIRECTIVES`; duplicates count against the bound.
pub const MAX_DIRECTIVES: u32 = directives.MAX_DIRECTIVES;

/// Bidirectional origin mapping and its shared coordinate vocabulary.
pub const Mapping = mapping;

/// A root's stable identity: `(program slot, source-order part index)`.
pub const RootId = mapping.RootId;

/// The part an assembled range came from. Byte ranges are local to that
/// part's own author text, never to the assembled module.
pub const OriginKey = mapping.OriginKey;

/// A half-open byte range. `end` is exclusive.
pub const ByteRange = mapping.ByteRange;

/// One row of the assembled line table: which part wrote assembled lines
/// `[first_line, first_line + line_count)`.
pub const LineRow = mapping.LineRow;

/// What a byte segment represents.
pub const SegmentKind = mapping.SegmentKind;

/// One ordered piece of the assembled text and the author range it came
/// from.
pub const Segment = mapping.Segment;

/// A located line: pngine's `locate` answer.
pub const LocatedLine = mapping.LocatedLine;

/// A byte range plus the author part it belongs to.
pub const OriginRange = mapping.OriginRange;

/// An author-local byte offset and the part it belongs to.
pub const OriginOffset = mapping.OriginOffset;

/// An assembled module: the text wgslender analyzes, the pngine-compatible
/// line table, and the byte segments Task 3 converts in both directions.
pub const Assembled = struct {
    text: []const u8,
    rows: []const LineRow,
    segments: []const Segment,
    root: RootId,
    /// The root form's name. Borrowed from the `Program`; it answers
    /// `locateLine` on the no-rows fast path, where there is no row to
    /// carry it.
    root_name: []const u8,

    /// Release the text and every table. Safe on every successfully
    /// returned value, including the no-import fast path.
    pub fn deinit(self: *Assembled, gpa: Allocator) void {
        gpa.free(@constCast(self.text));
        if (self.rows.len > 0) gpa.free(@constCast(self.rows));
        if (self.segments.len > 0) gpa.free(@constCast(self.segments));
        self.* = undefined;
    }

    /// Map a 1-based assembled line back to the part and line that wrote
    /// it. Mirrors pngine's `locate`, including the last-row fallback past
    /// EOF. Allocation-free.
    pub fn locateLine(self: *const Assembled, line: u32) LocatedLine {
        return mapping.locateLine(self.rows, self.root, self.root_name, line);
    }

    /// Map an assembled byte range to one contiguous author range, or
    /// `null` when no single author range represents it. Allocation-free.
    pub fn toOrigin(self: *const Assembled, range: ByteRange) ?OriginRange {
        return mapping.toOrigin(self.text.len, self.segments, self.root, range);
    }

    /// Map an author-local range to its assembled range. `null` covers both
    /// "no author representation" and duplicate blanked directives with no
    /// semantic copy. Allocation-free.
    pub fn fromOrigin(self: *const Assembled, origin: OriginKey, range: ByteRange) ?ByteRange {
        return mapping.fromOrigin(self.segments, origin, range);
    }

    /// Map one assembled byte offset to its author part and local offset.
    /// At or past assembled EOF this is the root's author EOF.
    pub fn offsetToOrigin(self: *const Assembled, offset: u32) ?OriginOffset {
        return mapping.offsetToOrigin(self.text.len, self.segments, self.root, offset);
    }

    /// Map one author-local offset to its assembled offset. Allocation-free.
    pub fn offsetFromOrigin(self: *const Assembled, origin: OriginOffset) ?u32 {
        return mapping.offsetFromOrigin(self.segments, origin);
    }
};

/// One hoisted directive plus the part position it came from. Internal:
/// callers see only the resulting rows and segments.
const Hoisted = struct {
    /// Position in the post-order fragment list, or `order.len` for the
    /// root's own text.
    part: u32,
    directive: directives.Directive,
    /// False when an identical directive was already hoisted from an
    /// earlier part. It is still blanked where it was written, but it
    /// contributes no line to the hoist block.
    first: bool,
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
    if (root_part.imports.len == 0) return fastPath(gpa, sources, root, root_part.name, failure);

    if (root_part.imports.len > limits.max_imports) {
        if (failure) |f| f.at = root;
        return error.TooDeep;
    }

    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(gpa);
    try postOrder(gpa, program, root, root_part.imports, limits, &order, failure);

    // THE DIRECTIVE HOIST, first half: scan every reached part's leading
    // region in walk order, before a byte is written. A part whose text is
    // missing fails here, so no partial unit is returned.
    var hoisted: std.ArrayList(Hoisted) = .empty;
    defer hoisted.deinit(gpa);
    var part_directives: std.ArrayList(directives.Directive) = .empty;
    defer part_directives.deinit(gpa);
    for (order.items, 0..) |part_index, position| {
        const text = sourceAt(sources, part_index) orelse {
            if (failure) |f| f.at = partId(root, part_index);
            return error.MissingSource;
        };
        try scanPart(gpa, text, @intCast(position), part_index, &part_directives, &hoisted, root, failure);
    }
    const root_text = sourceAt(sources, root.index) orelse {
        if (failure) |f| f.at = root;
        return error.MissingSource;
    };
    try scanPart(
        gpa,
        root_text,
        @intCast(order.items.len),
        root.index,
        &part_directives,
        &hoisted,
        root,
        failure,
    );

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var rows: std.ArrayList(LineRow) = .empty;
    errdefer rows.deinit(gpa);
    var segments: std.ArrayList(Segment) = .empty;
    errdefer segments.deinit(gpa);

    var line: u32 = 1;

    // The hoist block, in the order the parts were walked. WGSL lets the
    // three directive kinds interleave, so nothing is sorted: what the
    // author wrote is what ships, minus the repeats.
    for (hoisted.items) |h| {
        if (!h.first) continue;
        const part_index = if (h.part == order.items.len) root.index else order.items[h.part];
        const origin = partId(root, part_index);
        const part = program.parts[part_index];
        const start: u32 = @intCast(out.items.len);
        out.appendSlice(gpa, h.directive.text) catch return error.OutOfMemory;
        out.append(gpa, '\n') catch return error.OutOfMemory;
        const text_end: u32 = @intCast(out.items.len - 1);
        try rows.append(gpa, .{
            .origin = origin,
            .name = part.name,
            .first_line = line,
            .line_count = h.directive.lines,
            .src_line = h.directive.line,
            .is_root = part.isRoot(),
        });
        try segments.append(gpa, .{
            .assembled = .{ .start = start, .end = text_end },
            .origin = origin,
            .source = .{ .start = @intCast(h.directive.start), .end = @intCast(h.directive.end) },
            .kind = .hoisted,
        });
        try segments.append(gpa, .{
            .assembled = .{ .start = text_end, .end = text_end + 1 },
            .origin = origin,
            .source = .{ .start = @intCast(h.directive.end), .end = @intCast(h.directive.end) },
            .kind = .terminator,
        });
        line += h.directive.lines;
    }

    for (order.items, 0..) |part_index, position| {
        const part = program.parts[part_index];
        const text = sourceAt(sources, part_index).?;
        const origin = partId(root, part_index);
        const count = try appendPart(gpa, &out, &segments, origin, text, hoisted.items, @intCast(position));
        try rows.append(gpa, .{
            .origin = origin,
            .name = part.name,
            .first_line = line,
            .line_count = count,
            .is_root = false,
        });
        line += count;
    }

    const count = try appendPart(
        gpa,
        &out,
        &segments,
        root,
        root_text,
        hoisted.items,
        @intCast(order.items.len),
    );
    try rows.append(gpa, .{
        .origin = root,
        .name = root_part.name,
        .first_line = line,
        .line_count = count,
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
        .root_name = root_part.name,
    };
}

fn fastPath(
    gpa: Allocator,
    sources: []const ?[]const u8,
    root: RootId,
    root_name: []const u8,
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
        .root_name = root_name,
    };
}

/// Scan one part's leading directives into `part_directives`, then merge
/// them into the global `hoisted` list with pngine's deduplication.
/// `limit` is the global remaining capacity, so a part cannot push the
/// total past `MAX_DIRECTIVES`.
fn scanPart(
    gpa: Allocator,
    text: []const u8,
    position: u32,
    part_index: u32,
    part_directives: *std.ArrayList(directives.Directive),
    hoisted: *std.ArrayList(Hoisted),
    root: RootId,
    failure: ?*Failure,
) Error!void {
    part_directives.clearRetainingCapacity();
    const remaining: u32 = MAX_DIRECTIVES - @as(u32, @intCast(hoisted.items.len));
    directives.scan(gpa, text, part_directives, remaining) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooManyDirectives => {
            if (failure) |f| f.at = partId(root, part_index);
            return error.TooDeep;
        },
    };

    for (part_directives.items) |directive| {
        var first = true;
        for (hoisted.items) |previous| {
            if (directives.eql(previous.directive.text, directive.text)) {
                first = false;
                break;
            }
        }
        hoisted.append(gpa, .{
            .part = position,
            .directive = directive,
            .first = first,
        }) catch return error.OutOfMemory;
    }
}

/// Append one part with its hoisted directives blanked out, guaranteeing
/// the output ends on a newline, and return how many assembled lines it
/// occupies. Mirrors pngine's `appendTerminated` / `appendBlanked`.
///
/// Blanking writes a space over every non-newline byte of a directive
/// and keeps its newlines, so the part occupies the same lines AND the
/// same columns it did before the hoist. A part with no trailing newline
/// gets one appended, so the next part cannot share its last line.
fn appendPart(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    segments: *std.ArrayList(Segment),
    origin: OriginKey,
    text: []const u8,
    hoisted: []const Hoisted,
    part_position: u32,
) Error!u32 {
    if (text.len == 0) {
        const start: u32 = @intCast(out.items.len);
        out.append(gpa, '\n') catch return error.OutOfMemory;
        try segments.append(gpa, .{
            .assembled = .{ .start = start, .end = start + 1 },
            .origin = origin,
            .source = .{ .start = 0, .end = 0 },
            .kind = .terminator,
        });
        return 1;
    }

    var cursor: usize = 0;
    for (hoisted) |h| {
        if (h.part != part_position) continue;
        const directive = h.directive;
        std.debug.assert(directive.start >= cursor); // scanned left to right, once
        std.debug.assert(directive.end <= text.len);
        if (directive.start > cursor) {
            try appendRange(gpa, out, segments, origin, text, cursor, directive.start, .body);
        }
        const out_start: u32 = @intCast(out.items.len);
        for (text[directive.start..directive.end]) |c| {
            out.append(gpa, if (c == '\n') '\n' else ' ') catch return error.OutOfMemory;
        }
        try segments.append(gpa, .{
            .assembled = .{ .start = out_start, .end = @intCast(out.items.len) },
            .origin = origin,
            .source = .{ .start = @intCast(directive.start), .end = @intCast(directive.end) },
            .kind = .blanked,
        });
        cursor = directive.end;
    }
    if (cursor < text.len) {
        try appendRange(gpa, out, segments, origin, text, cursor, text.len, .body);
    }

    // Counted from the part text, not from what was appended: blanking is
    // length- and newline-preserving, so the two agree by construction.
    const lines = lineCount(text);
    if (text[text.len - 1] != '\n') {
        const start: u32 = @intCast(out.items.len);
        out.append(gpa, '\n') catch return error.OutOfMemory;
        try segments.append(gpa, .{
            .assembled = .{ .start = start, .end = start + 1 },
            .origin = origin,
            .source = .{ .start = @intCast(text.len), .end = @intCast(text.len) },
            .kind = .terminator,
        });
    }
    return lines;
}

fn appendRange(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    segments: *std.ArrayList(Segment),
    origin: OriginKey,
    text: []const u8,
    from: usize,
    to: usize,
    kind: SegmentKind,
) Error!void {
    if (from == to) return;
    const start: u32 = @intCast(out.items.len);
    out.appendSlice(gpa, text[from..to]) catch return error.OutOfMemory;
    try segments.append(gpa, .{
        .assembled = .{ .start = start, .end = @intCast(out.items.len) },
        .origin = origin,
        .source = .{ .start = @intCast(from), .end = @intCast(to) },
        .kind = kind,
    });
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
    root: RootId,
    root_imports: []const types.ImportRef,
    limits: Limits,
    out: *std.ArrayList(u32),
    failure: ?*Failure,
) Error!void {
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

        // Loop guard: each reached fragment is pushed at most once, and
        // each frame advances at most `max_imports` child slots plus the
        // final emit. pngine uses `MAX_DEPTH * MAX_IMPORTS * MAX_IMPORTS`;
        // this form stays correct when a caller lowers the limits.
        const max_steps: u64 = @as(u64, limits.max_fragments) *
            (@as(u64, limits.max_imports) + 1) + 1;
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
