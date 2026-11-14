//! pngine bidirectional origin mapping (pngine-shaders phase 02, Task 3).
//!
//! The assembler built the line rows and byte segments while it wrote the
//! text; this suite pins the conversions that read them. Each test names
//! the inventory row it covers. The mapping is pure: every call below runs
//! without an allocator, so nothing it returns can outlive its inputs or
//! leak when construction fails.

const std = @import("std");

const assemble = @import("pngine_assemble");
const Types = assemble.Types;

const testing = std.testing;

/// A `Program` built from arena text plus the source table alignment the
/// assembler consumes. Identical in shape to the assembly suite's fixture
/// so both suites pin the same graph construction.
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    parts: std.ArrayList(Types.Part) = .empty,
    root_indices: std.ArrayList(u32) = .empty,
    sources: std.ArrayList(?[]const u8) = .empty,

    fn init(backing: std.mem.Allocator) Fixture {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn add(
        self: *Fixture,
        kind: Types.PartKind,
        name: []const u8,
        text: []const u8,
        imports: []const []const u8,
    ) !u32 {
        const a = self.arena.allocator();
        const refs = try a.alloc(Types.ImportRef, imports.len);
        for (imports, 0..) |import_name, i| {
            refs[i] = .{
                .name = import_name,
                .span = .{ .start = 0, .end = @intCast(import_name.len) },
            };
        }

        const index: u32 = @intCast(self.parts.items.len);
        try self.parts.append(a, .{
            .kind = kind,
            .name = name,
            .name_span = .{ .start = 0, .end = @intCast(name.len) },
            .form_span = .{ .start = 0, .end = 0 },
            .origin = .{ .inline_code = .{
                .code = text,
                .span = .{ .start = 0, .end = @intCast(text.len) },
            } },
            .imports = refs,
        });
        try self.sources.append(a, text);
        if (kind != .wgsl) try self.root_indices.append(a, index);
        return index;
    }

    fn addRoot(self: *Fixture, name: []const u8, text: []const u8, imports: []const []const u8) !u32 {
        return self.add(.shader_module, name, text, imports);
    }

    fn textOf(self: *const Fixture, index: u32) []const u8 {
        return self.sources.items[index].?;
    }

    fn program(self: *const Fixture) Types.Program {
        return .{
            .document_path = "/project/program.sjon",
            .parts = self.parts.items,
            .roots = self.root_indices.items,
            .diagnostics = &.{},
        };
    }

    fn rootId(self: *const Fixture, index: u32) assemble.RootId {
        _ = self;
        return .{ .program = 17, .index = index };
    }
};

fn run(f: *const Fixture, root_index: u32) !assemble.Assembled {
    var program = f.program();
    return assemble.assemble(testing.allocator, &program, f.sources.items, f.rootId(root_index), null);
}

// ── small assertion helpers ────────────────────────────────────────────────

fn expectOriginRange(
    got: ?assemble.OriginRange,
    origin: assemble.OriginKey,
    start: u32,
    end: u32,
) !void {
    const value = got orelse return error.ExpectedOriginRange;
    try testing.expectEqual(origin, value.origin);
    try testing.expectEqual(assemble.ByteRange{ .start = start, .end = end }, value.range);
}

fn expectByteRange(got: ?assemble.ByteRange, start: u32, end: u32) !void {
    const value = got orelse return error.ExpectedByteRange;
    try testing.expectEqual(assemble.ByteRange{ .start = start, .end = end }, value);
}

fn expectOriginOffset(
    got: ?assemble.OriginOffset,
    origin: assemble.OriginKey,
    offset: u32,
) !void {
    const value = got orelse return error.ExpectedOriginOffset;
    try testing.expectEqual(origin, value.origin);
    try testing.expectEqual(offset, value.offset);
}

/// The range of the first occurrence of `needle`.
fn spanOf(haystack: []const u8, needle: []const u8) !assemble.ByteRange {
    const start = std.mem.indexOf(u8, haystack, needle) orelse return error.NeedleNotFound;
    return .{ .start = @intCast(start), .end = @intCast(start + needle.len) };
}

/// Count UTF-16 code units in `text[0..byte_offset]`. Used by A38 to prove
/// the conversion runs over the ORIGIN's text: the assembled copy of a
/// blanked directive is spaces, so its unit count would differ.
fn utf16Column(text: []const u8, byte_offset: usize) u32 {
    var units: u32 = 0;
    var i: usize = 0;
    while (i < byte_offset) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            units += 1;
            i += 1;
            continue;
        };
        if (i + len > byte_offset) {
            units += @intCast(byte_offset - i);
            break;
        }
        const cp = std.unicode.utf8Decode(text[i..][0..len]) catch {
            units += 1;
            i += 1;
            continue;
        };
        units += if (cp >= 0x10000) 2 else 1;
        i += len;
    }
    return units;
}

// =========================================================================
// A31 — body range → author file/inline range
// =========================================================================

test "A31 body bytes map to the same author range, in both directions" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const a = try f.add(.wgsl, "a", "fn a() {}\n", &.{});
    const root = try f.addRoot("root", "fn root() {}\n", &.{"a"});

    var assembled = try run(&f, root);
    defer assembled.deinit(testing.allocator);

    try testing.expectEqualStrings("fn a() {}\nfn root() {}\n", assembled.text);

    // `fn a()` in the fragment's body.
    try expectOriginRange(assembled.toOrigin(.{ .start = 0, .end = 6 }), f.rootId(a), 0, 6);
    // `fn root()` in the root's body, at an assembled offset that is not 0.
    try expectOriginRange(assembled.toOrigin(.{ .start = 10, .end = 18 }), f.rootId(root), 0, 8);
    // The newline that ends the fragment is author text too.
    try expectOriginRange(assembled.toOrigin(.{ .start = 9, .end = 10 }), f.rootId(a), 9, 10);

    try expectByteRange(assembled.fromOrigin(f.rootId(a), .{ .start = 0, .end = 10 }), 0, 10);
    try expectByteRange(assembled.fromOrigin(f.rootId(root), .{ .start = 0, .end = 12 }), 10, 22);
}

// =========================================================================
// A32 — a diagnostic on a hoisted directive maps to the author's own line
// =========================================================================

test "A32 a hoisted directive maps to its original line and column" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    _ = try f.add(.wgsl, "a", "fn a() {}\n", &.{});
    const root_text = "// c\nenable f16;\nfn root() {}\n";
    const root = try f.addRoot("root", root_text, &.{"a"});

    var assembled = try run(&f, root);
    defer assembled.deinit(testing.allocator);

    // The directive is lifted to assembled line 1 but was written on line 2.
    const at = assembled.locateLine(1);
    try testing.expectEqual(f.rootId(root), at.origin);
    try testing.expectEqualStrings("root", at.name);
    try testing.expectEqual(@as(u32, 2), at.line);
    try testing.expect(at.is_root);

    // The whole directive, including the author's leading comment line,
    // still maps to the directive's own bytes.
    try expectOriginRange(assembled.toOrigin(.{ .start = 0, .end = 11 }), f.rootId(root), 5, 16);

    // A token inside the hoisted copy maps to its exact author column: the
    // directive starts at byte 5 (column 0 of author line 2), `f16` at
    // byte 12 (column 7).
    try expectOriginRange(assembled.toOrigin(.{ .start = 7, .end = 10 }), f.rootId(root), 12, 15);
    const directive = try spanOf(root_text, "enable f16;");
    const token = try spanOf(root_text, "f16");
    try testing.expectEqual(@as(u32, 5), directive.start);
    try testing.expectEqual(@as(u32, 0), directive.start - 5);
    try testing.expectEqual(@as(u32, 7), token.start - 5);
}

// =========================================================================
// A33 — original directive request → hoisted token
// =========================================================================

test "A33 a request on an original directive maps to the hoisted token" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    _ = try f.add(.wgsl, "a", "fn a() {}\n", &.{});
    const root = try f.addRoot("root", "// c\nenable f16;\nfn root() {}\n", &.{"a"});

    var assembled = try run(&f, root);
    defer assembled.deinit(testing.allocator);

    // The request covers the directive as the author wrote it.
    try expectByteRange(assembled.fromOrigin(f.rootId(root), .{ .start = 5, .end = 16 }), 0, 11);
    // A request on one token maps to the same token in the hoisted copy.
    try expectByteRange(assembled.fromOrigin(f.rootId(root), .{ .start = 12, .end = 15 }), 7, 10);
    // `f16` starts at author offset 12 and at assembled offset 7.
    try testing.expectEqual(
        @as(?u32, 7),
        assembled.offsetFromOrigin(.{ .origin = f.rootId(root), .offset = 12 }),
    );
}

// =========================================================================
// A34 — duplicate blanked directives have no semantic copy of their own
// =========================================================================

test "A34 a duplicate blanked directive declines instead of using another copy" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const a = try f.add(
        .wgsl,
        "a",
        "enable f16;\nenable  f16;\nfn a() {}\n",
        &.{},
    );
    const b = try f.add(.wgsl, "b", "enable f16;\nfn b() {}\n", &.{});
    const root = try f.addRoot("root", "fn root() {}\n", &.{ "a", "b" });

    var assembled = try run(&f, root);
    defer assembled.deinit(testing.allocator);

    // Only the first spelling is hoisted.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, assembled.text, "enable f16;"));

    // The FIRST occurrence has a same-origin/same-source hoisted twin.
    try expectByteRange(assembled.fromOrigin(f.rootId(a), .{ .start = 0, .end = 11 }), 0, 11);
    try testing.expectEqual(
        @as(?u32, 0),
        assembled.offsetFromOrigin(.{ .origin = f.rootId(a), .offset = 0 }),
    );

    // The second, blanked spelling in the same part has no twin of its own.
    try testing.expectEqual(@as(?assemble.ByteRange, null), assembled.fromOrigin(
        f.rootId(a),
        .{ .start = 12, .end = 24 },
    ));
    try testing.expectEqual(@as(?u32, null), assembled.offsetFromOrigin(.{
        .origin = f.rootId(a),
        .offset = 12,
    }));

    // Another part's identical spelling is a duplicate too: same source
    // range, different origin, and no hoisted copy with that origin.
    try testing.expectEqual(@as(?assemble.ByteRange, null), assembled.fromOrigin(
        f.rootId(b),
        .{ .start = 0, .end = 11 },
    ));
    try testing.expectEqual(@as(?u32, null), assembled.offsetFromOrigin(.{
        .origin = f.rootId(b),
        .offset = 0,
    }));
}

// =========================================================================
// A35 — a range crossing two parts is refused, never clamped
// =========================================================================

test "A35 a range crossing a part boundary returns null" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const a = try f.add(.wgsl, "a", "fn a() {}\n", &.{});
    const b = try f.add(.wgsl, "b", "fn b() {}\n", &.{"a"});
    const root = try f.addRoot("root", "fn root() {}\n", &.{"b"});

    var assembled = try run(&f, root);
    defer assembled.deinit(testing.allocator);

    try testing.expectEqualStrings("fn a() {}\nfn b() {}\nfn root() {}\n", assembled.text);

    // Each side maps; the range that spans the boundary does not.
    try expectOriginRange(assembled.toOrigin(.{ .start = 9, .end = 10 }), f.rootId(a), 9, 10);
    try expectOriginRange(assembled.toOrigin(.{ .start = 10, .end = 11 }), f.rootId(b), 0, 1);
    try testing.expectEqual(@as(?assemble.OriginRange, null), assembled.toOrigin(.{ .start = 9, .end = 11 }));
    try testing.expectEqual(@as(?assemble.OriginRange, null), assembled.toOrigin(.{ .start = 0, .end = 22 }));
}

// =========================================================================
// A36 — the synthetic part-terminating newline is that part's EOF
// =========================================================================

test "A36 the synthetic terminating newline maps to zero-width part EOF" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const a = try f.add(.wgsl, "a", "fn a() {}", &.{});
    const root = try f.addRoot("root", "fn root() {}\n", &.{"a"});

    var assembled = try run(&f, root);
    defer assembled.deinit(testing.allocator);

    // The fragment has no newline, so assembly appends one at byte 9.
    try testing.expectEqualStrings("fn a() {}\nfn root() {}\n", assembled.text);
    try expectOriginRange(assembled.toOrigin(.{ .start = 9, .end = 10 }), f.rootId(a), 9, 9);
    try expectOriginOffset(assembled.offsetToOrigin(9), f.rootId(a), 9);
    // A zero-width compiled position at the newline is the same EOF.
    try expectOriginRange(assembled.toOrigin(.{ .start = 9, .end = 9 }), f.rootId(a), 9, 9);
    // And the reverse: the fragment's EOF is the synthetic newline's start.
    try expectByteRange(assembled.fromOrigin(f.rootId(a), .{ .start = 9, .end = 9 }), 9, 9);
}

// =========================================================================
// A37 — past assembled EOF is the root's EOF
// =========================================================================

test "A37 a position past assembled EOF maps to root EOF" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    _ = try f.add(.wgsl, "a", "fn a() {}\n", &.{});
    const root_text = "fn root() {}";
    const root = try f.addRoot("root", root_text, &.{"a"});

    var assembled = try run(&f, root);
    defer assembled.deinit(testing.allocator);

    // `fn a() {}\n` (10) + the root's text (12) + its synthetic newline.
    try testing.expectEqual(@as(usize, 23), assembled.text.len);
    try testing.expectEqual(@as(usize, 12), root_text.len);

    // Any offset at or past the end collapses to the root's author EOF.
    try expectOriginOffset(assembled.offsetToOrigin(23), f.rootId(root), 12);
    try expectOriginOffset(assembled.offsetToOrigin(99), f.rootId(root), 12);
    try expectOriginRange(assembled.toOrigin(.{ .start = 23, .end = 23 }), f.rootId(root), 12, 12);
    try expectOriginRange(assembled.toOrigin(.{ .start = 23, .end = 30 }), f.rootId(root), 12, 12);

    // `locateLine` mirrors pngine's last-row fallback, which is the root's
    // row: 3 - root.first_line(2) + root.src_line(1) == 2.
    const past = assembled.locateLine(3);
    try testing.expectEqual(f.rootId(root), past.origin);
    try testing.expectEqualStrings("root", past.name);
    try testing.expectEqual(@as(u32, 2), past.line);
    try testing.expect(past.is_root);
}

// =========================================================================
// A21 — blanking preserves every later column on the same line
// =========================================================================

test "A21 a declaration after a blanked directive keeps its author column" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    _ = try f.add(.wgsl, "a", "fn a() {}\n", &.{});
    const root_text = "enable f16; fn root() {}\n";
    const root = try f.addRoot("root", root_text, &.{"a"});

    var assembled = try run(&f, root);
    defer assembled.deinit(testing.allocator);

    try testing.expectEqualStrings(
        "enable f16;\n" ++
            "fn a() {}\n" ++
            "            fn root() {}\n",
        assembled.text,
    );

    const body = try spanOf(assembled.text, "fn root() {}");
    const author = try spanOf(root_text, "fn root() {}");
    // Byte column 12 in both domains: the blank is exactly as wide as the
    // directive it replaced.
    try testing.expectEqual(@as(u32, 12), body.start - 22);
    try testing.expectEqual(@as(u32, 12), author.start);
    try expectOriginRange(
        assembled.toOrigin(body),
        f.rootId(root),
        author.start,
        author.end,
    );
    try expectOriginOffset(assembled.offsetToOrigin(body.start), f.rootId(root), author.start);
}

// =========================================================================
// A22 — a multiline directive row and per-line mapping inside it
// =========================================================================

test "A22 a multiline directive records its source line, count, and maps per line" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    _ = try f.add(.wgsl, "a", "fn a() {}\n", &.{});
    const root_text = "enable\n    f16;\nfn root() {}\n";
    const root = try f.addRoot("root", root_text, &.{"a"});

    var assembled = try run(&f, root);
    defer assembled.deinit(testing.allocator);

    try testing.expectEqualStrings(
        "enable\n" ++
            "    f16;\n" ++
            "fn a() {}\n" ++
            "      \n" ++
            "        \n" ++
            "fn root() {}\n",
        assembled.text,
    );

    try testing.expectEqual(@as(usize, 1), assembled.rows.len - 2); // one hoist row
    try testing.expectEqual(@as(u32, 1), assembled.rows[0].first_line);
    try testing.expectEqual(@as(u32, 2), assembled.rows[0].line_count);
    try testing.expectEqual(@as(u32, 1), assembled.rows[0].src_line);

    // Line 1 of the hoist block is author line 1; line 2 is author line 2.
    try testing.expectEqual(@as(u32, 1), assembled.locateLine(1).line);
    try testing.expectEqual(@as(u32, 2), assembled.locateLine(2).line);

    // Both authored lines of the directive map back to their own bytes.
    try expectOriginRange(assembled.toOrigin(.{ .start = 0, .end = 6 }), f.rootId(root), 0, 6);
    const f16_range = try spanOf(assembled.text, "f16");
    const author_f16 = try spanOf(root_text, "f16");
    try expectOriginRange(assembled.toOrigin(f16_range), f.rootId(root), author_f16.start, author_f16.end);
}

// =========================================================================
// A26 — CRLF and mixed newlines preserve bytes and columns
// =========================================================================

test "A26 CRLF survives blanking and a CRLF boundary does not shift a column" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const a = try f.add(.wgsl, "a", "enable f16;\r\nfn a() {}\r\n", &.{});
    const root_text = "fn root() {}\n";
    const root = try f.addRoot("root", root_text, &.{"a"});

    var assembled = try run(&f, root);
    defer assembled.deinit(testing.allocator);

    try testing.expectEqualStrings(
        "enable f16;\n" ++
            "           \r\nfn a() {}\r\n" ++
            "fn root() {}\n",
        assembled.text,
    );

    // Line rows count `\n`, so the blanked line and the declaration line
    // are the fragment's author lines 1 and 2.
    try testing.expectEqual(@as(u32, 1), assembled.locateLine(1).line);
    try testing.expectEqual(@as(u32, 1), assembled.locateLine(2).line);
    try testing.expectEqual(@as(u32, 2), assembled.locateLine(3).line);
    try testing.expectEqual(@as(u32, 1), assembled.locateLine(4).line);

    // `fn a` is at byte 13 of the author text (after `\r\n`) and byte 25
    // of the assembled text; both are column 0 of their line.
    const body = try spanOf(assembled.text, "fn a() {}");
    const author = try spanOf(f.textOf(a), "fn a() {}");
    try testing.expectEqual(@as(u32, 25), body.start);
    try testing.expectEqual(@as(u32, 13), author.start);
    try expectOriginRange(assembled.toOrigin(body), f.rootId(a), author.start, author.end);
    try expectOriginOffset(assembled.offsetToOrigin(body.start), f.rootId(a), author.start);
}

// =========================================================================
// A38 — non-ASCII before a diagnostic: bytes stay right, UTF-16 uses origin
// =========================================================================

test "A38 a non-ASCII directive prefix maps by author bytes, and UTF-16 uses origin text" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    _ = try f.add(.wgsl, "a", "fn a() {}\n", &.{});
    // The directive carries a 2-byte `é` and a 4-byte `😀`; blanking the
    // original turns both into spaces, so the assembled prefix has a
    // different UTF-16 width even though its BYTE width is unchanged.
    const root_text = "enable /* é😀 */ f16; fn root() {}\n";
    const root = try f.addRoot("root", root_text, &.{"a"});

    var assembled = try run(&f, root);
    defer assembled.deinit(testing.allocator);

    const body = try spanOf(assembled.text, "fn root() {}");
    const author = try spanOf(root_text, "fn root() {}");
    try testing.expectEqual(@as(u32, 60), body.start);
    try testing.expectEqual(@as(u32, 25), author.start);

    try expectOriginRange(assembled.toOrigin(body), f.rootId(root), author.start, author.end);
    try expectOriginOffset(assembled.offsetToOrigin(body.start), f.rootId(root), author.start);

    // Byte columns agree; the LSP column is UTF-16 and must be computed
    // over the ORIGIN's bytes.
    const origin_col = utf16Column(root_text, author.start);
    try testing.expectEqual(@as(u32, 22), origin_col);
    const assembled_line_start = std.mem.lastIndexOfScalar(u8, assembled.text[0..body.start], '\n').? + 1;
    const assembled_col = body.start - assembled_line_start; // 25 ASCII spaces
    try testing.expectEqual(@as(u32, 25), assembled_col);
    try testing.expect(origin_col != assembled_col);
}

// =========================================================================
// A39 — one fragment shared by four roots, independent assembled offsets
// =========================================================================

test "A39 a shared fragment maps to the same author range in every root" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const shared_text = "fn shared() {}\n";
    const shared = try f.add(.wgsl, "shared", shared_text, &.{});

    const directives = [_][]const u8{
        "enable f16;",
        "requires alpha;",
        "diagnostic(off, beta);",
        "requires gamma_delta;",
    };
    var roots: [4]u32 = undefined;
    for (directives, 0..) |directive, i| {
        const text = try std.fmt.allocPrint(f.arena.allocator(), "{s}\nfn root{d}() {{}}\n", .{ directive, i });
        roots[i] = try f.addRoot(try std.fmt.allocPrint(f.arena.allocator(), "root{d}", .{i}), text, &.{"shared"});
    }

    const author = try spanOf(shared_text, "fn shared() {}");
    var assembled_starts: [4]u32 = undefined;
    for (roots, 0..) |root, i| {
        var assembled = try run(&f, root);
        defer assembled.deinit(testing.allocator);

        const body = try spanOf(assembled.text, "fn shared() {}");
        assembled_starts[i] = body.start;
        // Same origin and same author-local range in every assembly.
        try expectOriginRange(
            assembled.toOrigin(body),
            f.rootId(shared),
            author.start,
            author.end,
        );
        try expectByteRange(
            assembled.fromOrigin(f.rootId(shared), author),
            body.start,
            body.end,
        );
    }

    // The hoist block's length differs per root, so the shared body's
    // assembled offset is independent of the origin range.
    for (assembled_starts, 0..) |start, i| {
        for (assembled_starts[0..i]) |previous| {
            try testing.expect(start != previous);
        }
    }
}

// =========================================================================
// Line mapping: every line, and the no-import fast path
// =========================================================================

test "locateLine maps every assembled line to its author line" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    _ = try f.add(.wgsl, "a", "a1\na2\na3", &.{});
    _ = try f.add(.wgsl, "b", "b1\nb2", &.{"a"});
    const root = try f.addRoot("r", "r1\nr2", &.{"b"});

    var assembled = try run(&f, root);
    defer assembled.deinit(testing.allocator);

    try testing.expectEqualStrings("a1\na2\na3\nb1\nb2\nr1\nr2\n", assembled.text);
    const expected = [_]struct { name: []const u8, line: u32 }{
        .{ .name = "a", .line = 1 },
        .{ .name = "a", .line = 2 },
        .{ .name = "a", .line = 3 },
        .{ .name = "b", .line = 1 },
        .{ .name = "b", .line = 2 },
        .{ .name = "r", .line = 1 },
        .{ .name = "r", .line = 2 },
    };
    for (expected, 0..) |want, i| {
        const at = assembled.locateLine(@intCast(i + 1));
        try testing.expectEqualStrings(want.name, at.name);
        try testing.expectEqual(want.line, at.line);
        try testing.expectEqual(i >= expected.len - 2, at.is_root);
    }
}

test "locateLine on the no-import fast path answers with the root itself" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const root = try f.addRoot("solo", "enable f16;\nfn solo() {}\n", &.{});

    var assembled = try run(&f, root);
    defer assembled.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), assembled.rows.len);
    const at = assembled.locateLine(7);
    try testing.expectEqual(f.rootId(root), at.origin);
    try testing.expectEqualStrings("solo", at.name);
    try testing.expectEqual(@as(u32, 7), at.line);
    try testing.expect(at.is_root);
}

// =========================================================================
// Blanked assembled bytes have no author representation
// =========================================================================

test "blanked assembled bytes do not pretend to be author text" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    _ = try f.add(.wgsl, "a", "fn a() {}\n", &.{});
    const root = try f.addRoot("root", "enable f16;\nfn root() {}\n", &.{"a"});

    var assembled = try run(&f, root);
    defer assembled.deinit(testing.allocator);

    // The root line 2 begins with eleven spaces that used to be the
    // directive. A range inside them has no honest author range: it is
    // synthetic text, and callers must refuse it rather than point at the
    // hoisted copy or the body.
    try testing.expectEqual(@as(?assemble.OriginRange, null), assembled.toOrigin(.{ .start = 22, .end = 26 }));
    try testing.expectEqual(@as(?assemble.OriginOffset, null), assembled.offsetToOrigin(22));
    // The reverse path still reaches the hoisted copy from the directive's
    // own bytes, which is the A33 rule.
    try expectByteRange(assembled.fromOrigin(f.rootId(root), .{ .start = 0, .end = 11 }), 0, 11);
}

// =========================================================================
// A42 — allocation-failure sweep
// =========================================================================

fn mapUnderAllocationFailure(gpa: std.mem.Allocator) !void {
    var f = Fixture.init(gpa);
    defer f.deinit();

    _ = try f.add(.wgsl, "shared", "fn shared() {}\n", &.{});
    _ = try f.add(.wgsl, "a", "enable f16;\nfn a() {}", &.{"shared"});
    _ = try f.add(.wgsl, "b", "enable  f16;\nfn b() {}", &.{"shared"});
    const root = try f.addRoot("root", "enable f16;\nfn root() {}\n", &.{ "a", "b" });

    var program = f.program();
    var assembled = try assemble.assemble(gpa, &program, f.sources.items, f.rootId(root), null);
    defer assembled.deinit(gpa);

    const body = try spanOf(assembled.text, "fn shared() {}");
    const mapped = assembled.toOrigin(body) orelse return error.ExpectedOriginRange;
    _ = assembled.locateLine(1);
    _ = assembled.fromOrigin(mapped.origin, mapped.range);
    _ = assembled.offsetToOrigin(body.start);
    _ = assembled.offsetFromOrigin(.{ .origin = mapped.origin, .offset = mapped.range.start });
}

test "A42 every mapping result survives an allocation-failure sweep" {
    // Mapping takes no allocator. The sweep still walks every assembly
    // failure window with the conversions called on each successful unit:
    // no leak, no double free, and no partially built return.
    try std.testing.checkAllAllocationFailures(testing.allocator, mapUnderAllocationFailure, .{});
}
