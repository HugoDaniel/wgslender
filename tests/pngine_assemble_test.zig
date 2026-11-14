//! pngine fragment assembly (pngine-shaders phase 02, Tasks 1–2).
//!
//! The assembler is pure library code: it consumes a phase-01 `Program`
//! plus one text per part, in source order. Nothing here opens a file or
//! touches `std.Io`, so the same suite is what pngine's test process can
//! compile in Task 5.
//!
//! Task 1 pins graph order and refusal: post-order dependencies, one
//! contribution per fragment however many paths reach it, cycle paths,
//! missing sources, and the four pngine bounds.
//!
//! Task 2 pins directive hoisting and byte-exact termination.

const std = @import("std");

const assemble = @import("pngine_assemble");
const Types = assemble.Types;

const testing = std.testing;

/// A `Program` built from static/arena text, plus the aligned source
/// table the assembler consumes. The arena owns every generated name and
/// import list so a part's borrowed slices stay valid.
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

    fn addChain(self: *Fixture, prefix: []const u8, count: usize) ![]const u8 {
        const a = self.arena.allocator();
        const names = try a.alloc([]const u8, count);
        for (names, 0..) |*name, i| name.* = try std.fmt.allocPrint(a, "{s}{d}", .{ prefix, i });
        for (names, 0..) |name, i| {
            const text = try std.fmt.allocPrint(a, "fn {s}() {{}}\n", .{name});
            if (i + 1 < count) {
                const imports = try a.alloc([]const u8, 1);
                imports[0] = names[i + 1];
                _ = try self.add(.wgsl, name, text, imports);
            } else {
                _ = try self.add(.wgsl, name, text, &.{});
            }
        }
        return names[0];
    }

    fn addSiblings(self: *Fixture, count: usize) ![]const []const u8 {
        const a = self.arena.allocator();
        const names = try a.alloc([]const u8, count);
        for (names, 0..) |*name, i| {
            name.* = try std.fmt.allocPrint(a, "s{d}", .{i});
            const text = try std.fmt.allocPrint(a, "fn {s}() {{}}\n", .{name.*});
            _ = try self.add(.wgsl, name.*, text, &.{});
        }
        return names;
    }

    fn missingSource(self: *Fixture, index: u32) void {
        self.sources.items[index] = null;
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
        return .{ .program = 11, .index = index };
    }
};

fn run(f: *const Fixture, root_index: u32, failure: ?*assemble.Failure) !assemble.Assembled {
    var program = f.program();
    return assemble.assemble(
        testing.allocator,
        &program,
        f.sources.items,
        f.rootId(root_index),
        failure,
    );
}

fn expectRow(
    row: assemble.LineRow,
    origin: assemble.OriginKey,
    name: []const u8,
    first_line: u32,
    line_count: u32,
    is_root: bool,
) !void {
    try testing.expectEqual(origin, row.origin);
    try testing.expectEqualStrings(name, row.name);
    try testing.expectEqual(first_line, row.first_line);
    try testing.expectEqual(line_count, row.line_count);
    try testing.expectEqual(@as(u32, 1), row.src_line);
    try testing.expectEqual(is_root, row.is_root);
}

// =========================================================================
// Task 1: graph order and refusal behaviour
// =========================================================================

test "assemble: a dependency chain is emitted post-order with the root last" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const base = try f.add(.wgsl, "base", "fn base() {}\n", &.{});
    const mid = try f.add(.wgsl, "mid", "fn mid() {}\n", &.{"base"});
    const root = try f.addRoot("root", "fn root() {}\n", &.{"mid"});

    var assembled = try run(&f, root, null);
    defer assembled.deinit(testing.allocator);

    try testing.expectEqualStrings(
        "fn base() {}\nfn mid() {}\nfn root() {}\n",
        assembled.text,
    );
    try testing.expectEqual(@as(usize, 3), assembled.rows.len);
    try expectRow(assembled.rows[0], f.rootId(base), "base", 1, 1, false);
    try expectRow(assembled.rows[1], f.rootId(mid), "mid", 2, 1, false);
    try expectRow(assembled.rows[2], f.rootId(root), "root", 3, 1, true);

    // The byte index is built as the output is written: one body segment
    // per newline-terminated part, in the same order as the rows.
    try testing.expectEqual(@as(usize, 3), assembled.segments.len);
    try testing.expectEqual(assemble.SegmentKind.body, assembled.segments[0].kind);
    try testing.expectEqual(assemble.ByteRange{ .start = 0, .end = 13 }, assembled.segments[0].assembled);
    try testing.expectEqual(assemble.ByteRange{ .start = 0, .end = 13 }, assembled.segments[0].source);
    try testing.expectEqual(f.rootId(base), assembled.segments[0].origin);
    try testing.expectEqual(assemble.ByteRange{ .start = 13, .end = 25 }, assembled.segments[1].assembled);
    try testing.expectEqual(assemble.ByteRange{ .start = 25, .end = 38 }, assembled.segments[2].assembled);
}

test "assemble: a diamond emits its shared fragment once, before either dependant" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const shared = try f.add(.wgsl, "shared", "fn shared() {}\n", &.{});
    const left = try f.add(.wgsl, "left", "fn left() {}\n", &.{"shared"});
    const right = try f.add(.wgsl, "right", "fn right() {}\n", &.{"shared"});
    const root = try f.addRoot("root", "fn root() {}\n", &.{ "left", "right" });

    var assembled = try run(&f, root, null);
    defer assembled.deinit(testing.allocator);

    try testing.expectEqualStrings(
        "fn shared() {}\nfn left() {}\nfn right() {}\nfn root() {}\n",
        assembled.text,
    );
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, assembled.text, "fn shared()"));
    try testing.expectEqual(@as(usize, 4), assembled.rows.len);
    try expectRow(assembled.rows[0], f.rootId(shared), "shared", 1, 1, false);
    try expectRow(assembled.rows[1], f.rootId(left), "left", 2, 1, false);
    try expectRow(assembled.rows[2], f.rootId(right), "right", 3, 1, false);
    try expectRow(assembled.rows[3], f.rootId(root), "root", 4, 1, true);
}

test "assemble: a fragment listed twice by the root contributes once" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    _ = try f.add(.wgsl, "base", "fn base() {}\n", &.{});
    const root = try f.addRoot("root", "fn root() {}\n", &.{ "base", "base" });

    var assembled = try run(&f, root, null);
    defer assembled.deinit(testing.allocator);

    try testing.expectEqualStrings("fn base() {}\nfn root() {}\n", assembled.text);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, assembled.text, "fn base()"));
    try testing.expectEqual(@as(usize, 2), assembled.rows.len);
}

test "assemble: the no-import fast path leaves root text untouched and rows empty" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    // No trailing newline, and a leading directive: a single origin needs
    // neither termination nor a hoist, exactly like pngine's fast path.
    const source = "enable f16;\nfn root() {}";
    const root = try f.addRoot("root", source, &.{});

    var assembled = try run(&f, root, null);
    defer assembled.deinit(testing.allocator);

    try testing.expectEqualStrings(source, assembled.text);
    try testing.expectEqual(@as(usize, 0), assembled.rows.len);
    try testing.expectEqual(@as(usize, 1), assembled.segments.len);
    try testing.expectEqual(assemble.SegmentKind.body, assembled.segments[0].kind);
    try testing.expectEqual(assemble.ByteRange{ .start = 0, .end = source.len }, assembled.segments[0].assembled);
    try testing.expectEqual(assemble.ByteRange{ .start = 0, .end = source.len }, assembled.segments[0].source);
    try testing.expectEqual(f.rootId(root), assembled.root);
}

test "assemble: an unknown direct import names the unresolved edge" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const root = try f.addRoot("root", "fn root() {}\n", &.{"nope"});

    var failure: assemble.Failure = undefined;
    try testing.expectError(
        assemble.Error.UnknownFragment,
        run(&f, root, &failure),
    );
    try testing.expectEqual(f.rootId(root), failure.root);
    try testing.expectEqual(root, failure.at.?.index);
    try testing.expectEqualStrings("nope", failure.unknown);
}

test "assemble: an unknown transitive import names the importer that wrote it" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const mid = try f.add(.wgsl, "mid", "fn mid() {}\n", &.{"missing"});
    const root = try f.addRoot("root", "fn root() {}\n", &.{"mid"});

    var failure: assemble.Failure = undefined;
    try testing.expectError(
        assemble.Error.UnknownFragment,
        run(&f, root, &failure),
    );
    try testing.expectEqual(f.rootId(root), failure.root);
    try testing.expectEqual(mid, failure.at.?.index);
    try testing.expectEqualStrings("missing", failure.unknown);
}

test "assemble: a self-import reports me -> me" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const me = try f.add(.wgsl, "me", "fn me() {}\n", &.{"me"});
    const root = try f.addRoot("root", "fn root() {}\n", &.{"me"});

    var failure: assemble.Failure = undefined;
    try testing.expectError(assemble.Error.ImportCycle, run(&f, root, &failure));
    try testing.expectEqual(f.rootId(root), failure.root);
    try testing.expectEqual(me, failure.at.?.index);

    const path = failure.cycle.slice();
    try testing.expectEqual(@as(usize, 2), path.len);
    try testing.expectEqualStrings("me", path[0]);
    try testing.expectEqualStrings("me", path[1]);
}

test "assemble: a multi-node cycle reports the ordered path" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    _ = try f.add(.wgsl, "mesh", "fn mesh() {}\n", &.{"material"});
    _ = try f.add(.wgsl, "material", "fn material() {}\n", &.{"scene"});
    _ = try f.add(.wgsl, "scene", "fn scene() {}\n", &.{"mesh"});
    const root = try f.addRoot("root", "fn root() {}\n", &.{"mesh"});

    var failure: assemble.Failure = undefined;
    try testing.expectError(assemble.Error.ImportCycle, run(&f, root, &failure));

    const path = failure.cycle.slice();
    try testing.expectEqual(@as(usize, 4), path.len);
    try testing.expectEqualStrings("mesh", path[0]);
    try testing.expectEqualStrings("material", path[1]);
    try testing.expectEqualStrings("scene", path[2]);
    try testing.expectEqualStrings("mesh", path[3]);
}

test "assemble: the default depth bound accepts 64 fragments and refuses 65" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const first64 = try f.addChain("a", 64);
    const root64 = try f.addRoot("root64", "fn r() {}\n", &.{first64});

    var accepted = try run(&f, root64, null);
    defer accepted.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 65), accepted.rows.len);

    const first65 = try f.addChain("b", 65);
    const root65 = try f.addRoot("root65", "fn r() {}\n", &.{first65});

    var failure: assemble.Failure = undefined;
    try testing.expectError(assemble.Error.TooDeep, run(&f, root65, &failure));
}

test "assemble: a lowered depth bound refuses the next fragment without recursion" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const first = try f.addChain("c", 4);
    const root = try f.addRoot("root", "fn root() {}\n", &.{first});

    const limits = assemble.Limits{ .max_depth = 4 };
    var program = f.program();
    var accepted = try assemble.assembleWithLimits(
        testing.allocator,
        &program,
        f.sources.items,
        f.rootId(root),
        limits,
        null,
    );
    defer accepted.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 5), accepted.rows.len);

    const shallow = assemble.Limits{ .max_depth = 3 };
    try testing.expectError(
        assemble.Error.TooDeep,
        assemble.assembleWithLimits(
            testing.allocator,
            &program,
            f.sources.items,
            f.rootId(root),
            shallow,
            null,
        ),
    );
}

test "assemble: the fragment-count bound refuses one reached fragment too many" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const names = try f.addSiblings(5);
    const root = try f.addRoot("root", "fn root() {}\n", names);

    const limits = assemble.Limits{ .max_fragments = 4 };
    var program = f.program();
    try testing.expectError(
        assemble.Error.TooDeep,
        assemble.assembleWithLimits(
            testing.allocator,
            &program,
            f.sources.items,
            f.rootId(root),
            limits,
            null,
        ),
    );

    const four = assemble.Limits{ .max_fragments = 5 };
    var accepted = try assemble.assembleWithLimits(
        testing.allocator,
        &program,
        f.sources.items,
        f.rootId(root),
        four,
        null,
    );
    defer accepted.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 6), accepted.rows.len);
}

test "assemble: the imports-per-form bound refuses one import too many" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const names = try f.addSiblings(4);
    const root = try f.addRoot("root", "fn root() {}\n", names);

    var failure: assemble.Failure = undefined;
    const limits = assemble.Limits{ .max_imports = 3 };
    var program = f.program();
    try testing.expectError(
        assemble.Error.TooDeep,
        assemble.assembleWithLimits(
            testing.allocator,
            &program,
            f.sources.items,
            f.rootId(root),
            limits,
            &failure,
        ),
    );
    try testing.expectEqual(root, failure.at.?.index);
}

test "assemble: a reached part with no source is MissingSource" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const frag = try f.add(.wgsl, "base", "fn base() {}\n", &.{});
    const root = try f.addRoot("root", "fn root() {}\n", &.{"base"});
    f.missingSource(frag);

    var failure: assemble.Failure = undefined;
    try testing.expectError(assemble.Error.MissingSource, run(&f, root, &failure));
    try testing.expectEqual(f.rootId(root), failure.root);
    try testing.expectEqual(frag, failure.at.?.index);
}

test "assemble: a root with no source is MissingSource" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    _ = try f.add(.wgsl, "base", "fn base() {}\n", &.{});
    const root = try f.addRoot("root", "fn root() {}\n", &.{"base"});
    f.missingSource(root);

    var failure: assemble.Failure = undefined;
    try testing.expectError(assemble.Error.MissingSource, run(&f, root, &failure));
    try testing.expectEqual(root, failure.at.?.index);
}

test "assemble: an unreferenced part with no source is ignored" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    _ = try f.add(.wgsl, "base", "fn base() {}\n", &.{});
    const unused = try f.add(.wgsl, "unused", "fn unused() {}\n", &.{});
    const root = try f.addRoot("root", "fn root() {}\n", &.{"base"});
    f.missingSource(unused);

    var assembled = try run(&f, root, null);
    defer assembled.deinit(testing.allocator);
    try testing.expectEqualStrings("fn base() {}\nfn root() {}\n", assembled.text);
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, assembled.text, "fn unused()"));
}

fn assembleDiamondUnderOom(gpa: std.mem.Allocator) !void {
    var f = Fixture.init(gpa);
    defer f.deinit();

    _ = try f.add(.wgsl, "shared", "fn shared() {}\n", &.{});
    _ = try f.add(.wgsl, "left", "fn left() {}\n", &.{"shared"});
    _ = try f.add(.wgsl, "right", "fn right() {}\n", &.{"shared"});
    const root = try f.addRoot("root", "fn root() {}\n", &.{ "left", "right" });

    var program = f.program();
    var assembled = try assemble.assemble(gpa, &program, f.sources.items, f.rootId(root), null);
    assembled.deinit(gpa);
}

test "assemble: allocation failure while walking or writing frees every partial" {
    try std.testing.checkAllAllocationFailures(testing.allocator, assembleDiamondUnderOom, .{});
}

// =========================================================================
// Task 2: directive hoist and byte-exact text
// =========================================================================

fn repeatDirective(gpa: std.mem.Allocator, count: usize) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    for (0..count) |_| try text.appendSlice(gpa, "enable f16;\n");
    try text.appendSlice(gpa, "fn root() {}");
    return text.toOwnedSlice(gpa);
}

test "hoist: a root that opens with a directive can import after all" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const frag = try f.add(.wgsl, "a", "fn a() {}", &.{});
    const root = try f.addRoot("root", "enable f16;\nfn root() {}", &.{"a"});

    var assembled = try run(&f, root, null);
    defer assembled.deinit(testing.allocator);

    try testing.expectEqualStrings(
        "enable f16;\n" ++
            "fn a() {}\n" ++
            "           \n" ++
            "fn root() {}\n",
        assembled.text,
    );

    try testing.expectEqual(@as(usize, 3), assembled.rows.len);
    try testing.expectEqual(f.rootId(root), assembled.rows[0].origin);
    try testing.expectEqualStrings("root", assembled.rows[0].name);
    try testing.expectEqual(@as(u32, 1), assembled.rows[0].first_line);
    try testing.expectEqual(@as(u32, 1), assembled.rows[0].line_count);
    try testing.expectEqual(@as(u32, 1), assembled.rows[0].src_line);
    try testing.expect(assembled.rows[0].is_root);

    try expectRow(assembled.rows[1], f.rootId(frag), "a", 2, 1, false);
    try expectRow(assembled.rows[2], f.rootId(root), "root", 3, 2, true);
}

test "hoist: every directive kind, fragment then root, in walk order" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const frag = try f.add(
        .wgsl,
        "a",
        "requires readonly_and_readwrite_storage_textures;\nfn a() {}",
        &.{},
    );
    const root = try f.addRoot(
        "root",
        "diagnostic(off, derivative_uniformity);\nfn root() {}",
        &.{"a"},
    );

    var assembled = try run(&f, root, null);
    defer assembled.deinit(testing.allocator);

    try testing.expectEqualStrings(
        "requires readonly_and_readwrite_storage_textures;\n" ++
            "diagnostic(off, derivative_uniformity);\n" ++
            "                                                 \nfn a() {}\n" ++
            "                                       \nfn root() {}\n",
        assembled.text,
    );

    try testing.expectEqual(@as(usize, 4), assembled.rows.len);
    try testing.expectEqual(f.rootId(frag), assembled.rows[0].origin);
    try testing.expectEqual(@as(u32, 1), assembled.rows[0].first_line);
    try testing.expectEqual(@as(u32, 1), assembled.rows[0].src_line);
    try testing.expect(assembled.rows[0].is_root == false);

    try testing.expectEqual(f.rootId(root), assembled.rows[1].origin);
    try testing.expectEqual(@as(u32, 2), assembled.rows[1].first_line);
    try testing.expectEqual(@as(u32, 1), assembled.rows[1].src_line);
    try testing.expect(assembled.rows[1].is_root);

    try expectRow(assembled.rows[2], f.rootId(frag), "a", 3, 2, false);
    try expectRow(assembled.rows[3], f.rootId(root), "root", 5, 2, true);
}

test "hoist: one copy of a directive spelled with different whitespace, all originals blanked" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    _ = try f.add(.wgsl, "a", "enable f16;\nfn a() {}", &.{});
    _ = try f.add(.wgsl, "b", "enable  f16;\nfn b() {}", &.{});
    const root = try f.addRoot("root", "enable f16;\nfn root() {}", &.{ "a", "b" });

    var assembled = try run(&f, root, null);
    defer assembled.deinit(testing.allocator);

    try testing.expectEqualStrings(
        "enable f16;\n" ++
            "           \nfn a() {}\n" ++
            "            \nfn b() {}\n" ++
            "           \nfn root() {}\n",
        assembled.text,
    );
    // One hoist row, three body rows.
    try testing.expectEqual(@as(usize, 4), assembled.rows.len);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, assembled.text, "enable"));
}

test "hoist: directives differing only by a comment are not equal" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    _ = try f.add(.wgsl, "a", "enable /* a */ f16;\nfn a() {}", &.{});
    _ = try f.add(.wgsl, "b", "enable /* b */ f16;\nfn b() {}", &.{});
    const root = try f.addRoot("root", "fn root() {}", &.{ "a", "b" });

    var assembled = try run(&f, root, null);
    defer assembled.deinit(testing.allocator);

    try testing.expect(std.mem.startsWith(
        u8,
        assembled.text,
        "enable /* a */ f16;\nenable /* b */ f16;\n",
    ));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, assembled.text, "enable /*"));
    // Two hoist rows plus the three part rows.
    try testing.expectEqual(@as(usize, 5), assembled.rows.len);
}

test "hoist: a directive after a declaration is left exactly where it is" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    _ = try f.add(.wgsl, "a", "fn a() {}", &.{});
    const root = try f.addRoot("root", "fn root() {}\nenable f16;", &.{"a"});

    var assembled = try run(&f, root, null);
    defer assembled.deinit(testing.allocator);

    try testing.expectEqualStrings(
        "fn a() {}\nfn root() {}\nenable f16;\n",
        assembled.text,
    );
    try testing.expectEqual(@as(usize, 2), assembled.rows.len);
}

test "hoist: an unterminated directive is left alone" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    _ = try f.add(.wgsl, "a", "fn a() {}", &.{});
    const root = try f.addRoot("root", "enable f16", &.{"a"});

    var assembled = try run(&f, root, null);
    defer assembled.deinit(testing.allocator);

    try testing.expectEqualStrings("fn a() {}\nenable f16\n", assembled.text);
    try testing.expectEqual(@as(usize, 2), assembled.rows.len);
}

test "hoist: a semicolon inside a line comment does not end the directive" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    _ = try f.add(.wgsl, "a", "fn a() {}", &.{});
    const directive = "enable // ; not the end\nf16;";
    const root = try f.addRoot(
        "root",
        directive ++ "\nfn root() {}",
        &.{"a"},
    );

    var assembled = try run(&f, root, null);
    defer assembled.deinit(testing.allocator);

    try testing.expect(std.mem.startsWith(
        u8,
        assembled.text,
        directive ++ "\n",
    ));
    // The directive spans two authored lines, which the row records.
    try testing.expectEqual(@as(u32, 2), assembled.rows[0].line_count);
    try testing.expectEqual(@as(u32, 1), assembled.rows[0].src_line);
}

test "hoist: nested leading comments are trivia and a nested comment's semicolon is skipped" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    _ = try f.add(.wgsl, "a", "fn a() {}", &.{});
    const root = try f.addRoot(
        "root",
        "/* outer /* inner ; */ outer */ enable /* ; */ f16;\nfn root() {}",
        &.{"a"},
    );

    var assembled = try run(&f, root, null);
    defer assembled.deinit(testing.allocator);

    // The leading comment stays where it was written; the directive is
    // lifted out from below it, with its own inner comment intact.
    try testing.expect(std.mem.startsWith(
        u8,
        assembled.text,
        "enable /* ; */ f16;\n",
    ));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, assembled.text, "enable"));
}

test "hoist: an unterminated leading block comment swallows the would-be directive" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    _ = try f.add(.wgsl, "a", "fn a() {}", &.{});
    const source = "/* enable f16;\nfn root() {}";
    const root = try f.addRoot("root", source, &.{"a"});

    var assembled = try run(&f, root, null);
    defer assembled.deinit(testing.allocator);

    try testing.expectEqualStrings("fn a() {}\n" ++ source ++ "\n", assembled.text);
}

test "hoist: directive-looking text in a comment is not hoisted" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const frag = try f.add(.wgsl, "a", "// enable f16;\nfn a() {}", &.{});
    const root = try f.addRoot("root", "fn root() {}", &.{"a"});

    var assembled = try run(&f, root, null);
    defer assembled.deinit(testing.allocator);

    try testing.expectEqualStrings(
        "// enable f16;\nfn a() {}\nfn root() {}\n",
        assembled.text,
    );
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, assembled.text, "enable"));
    try expectRow(assembled.rows[0], f.rootId(frag), "a", 1, 2, false);
}

test "hoist: a directive and a declaration on one line keep the declaration's column" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    _ = try f.add(.wgsl, "a", "fn a() {}", &.{});
    const root = try f.addRoot("root", "enable f16; fn root() {}", &.{"a"});

    var assembled = try run(&f, root, null);
    defer assembled.deinit(testing.allocator);

    try testing.expectEqualStrings(
        "enable f16;\n" ++
            "fn a() {}\n" ++
            "            fn root() {}\n",
        assembled.text,
    );
    // The replacement line is exactly as wide as the author's, so the
    // declaration still starts in column 13.
    const body_line = "            fn root() {}";
    try testing.expectEqual(
        "enable f16; fn root() {}".len,
        body_line.len,
    );
}

test "hoist: a multiline directive hoists with its full line count" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const frag = try f.add(.wgsl, "a", "fn a() {}", &.{});
    const root = try f.addRoot("root", "enable\n    f16;\nfn root() {}", &.{"a"});

    var assembled = try run(&f, root, null);
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
    try testing.expectEqual(@as(u32, 1), assembled.rows[0].first_line);
    try testing.expectEqual(@as(u32, 2), assembled.rows[0].line_count);
    try testing.expectEqual(@as(u32, 1), assembled.rows[0].src_line);
    try expectRow(assembled.rows[1], f.rootId(frag), "a", 3, 1, false);
    try expectRow(assembled.rows[2], f.rootId(root), "root", 4, 3, true);
}

test "hoist: a hoisted row remembers the author's line below leading trivia" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    _ = try f.add(.wgsl, "a", "fn a() {}", &.{});
    const root = try f.addRoot("root", "// c\nenable f16;\nfn root() {}", &.{"a"});

    var assembled = try run(&f, root, null);
    defer assembled.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 2), assembled.rows[0].src_line);
    try testing.expectEqual(@as(u32, 3), assembled.rows[2].line_count);
}

test "assemble: an empty fragment owns one output line and one row" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const empty = try f.add(.wgsl, "empty", "", &.{});
    const root = try f.addRoot("root", "fn root() {}", &.{"empty"});

    var assembled = try run(&f, root, null);
    defer assembled.deinit(testing.allocator);

    try testing.expectEqualStrings("\nfn root() {}\n", assembled.text);
    try testing.expectEqual(@as(usize, 2), assembled.rows.len);
    try expectRow(assembled.rows[0], f.rootId(empty), "empty", 1, 1, false);
    try expectRow(assembled.rows[1], f.rootId(root), "root", 2, 1, true);
    try testing.expectEqual(@as(usize, 3), assembled.segments.len);
    try testing.expectEqual(assemble.SegmentKind.terminator, assembled.segments[0].kind);
    try testing.expectEqual(assemble.ByteRange{ .start = 0, .end = 0 }, assembled.segments[0].source);
    try testing.expectEqual(assemble.SegmentKind.body, assembled.segments[1].kind);
    try testing.expectEqual(assemble.SegmentKind.terminator, assembled.segments[2].kind);
}

test "assemble: every unterminated part starts the next on a fresh line" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const a = try f.add(.wgsl, "a", "fn a() {}", &.{});
    const b = try f.add(.wgsl, "b", "fn b() {}", &.{});
    const root = try f.addRoot("root", "fn root() {}", &.{ "a", "b" });

    var assembled = try run(&f, root, null);
    defer assembled.deinit(testing.allocator);

    try testing.expectEqualStrings(
        "fn a() {}\nfn b() {}\nfn root() {}\n",
        assembled.text,
    );
    try expectRow(assembled.rows[0], f.rootId(a), "a", 1, 1, false);
    try expectRow(assembled.rows[1], f.rootId(b), "b", 2, 1, false);
    try expectRow(assembled.rows[2], f.rootId(root), "root", 3, 1, true);

    // body + synthetic terminator for each part.
    try testing.expectEqual(@as(usize, 6), assembled.segments.len);
    for (assembled.segments, 0..) |segment, i| {
        const expected = if (i % 2 == 0) assemble.SegmentKind.body else assemble.SegmentKind.terminator;
        try testing.expectEqual(expected, segment.kind);
        if (segment.kind == .terminator) {
            try testing.expectEqual(segment.source.start, segment.source.end);
        }
    }
}

test "assemble: CRLF bytes survive; only the mandated newline is added" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const a = try f.add(.wgsl, "a", "enable f16;\r\nfn a() {}\r\n", &.{});
    const root = try f.addRoot("root", "fn root() {}\n", &.{"a"});

    var assembled = try run(&f, root, null);
    defer assembled.deinit(testing.allocator);

    try testing.expectEqualStrings(
        "enable f16;\n" ++
            "           \r\nfn a() {}\r\n" ++
            "fn root() {}\n",
        assembled.text,
    );
    try testing.expectEqual(@as(u32, 1), assembled.rows[0].line_count);
    try expectRow(assembled.rows[1], f.rootId(a), "a", 2, 2, false);
    try expectRow(assembled.rows[2], f.rootId(root), "root", 4, 1, true);
}

test "hoist: exactly MAX_DIRECTIVES fits; one more is TooDeep" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    _ = try f.add(.wgsl, "a", "fn a() {}", &.{});

    const fits = try repeatDirective(f.arena.allocator(), assemble.MAX_DIRECTIVES);
    const root_ok = try f.addRoot("root_ok", fits, &.{"a"});

    var assembled = try run(&f, root_ok, null);
    defer assembled.deinit(testing.allocator);

    // All 64 spellings are the same directive: one line hoisted, 64
    // originals blanked, so the root body still has 65 lines.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, assembled.text, "enable f16;"));
    try testing.expectEqual(@as(usize, 3), assembled.rows.len);
    try testing.expectEqual(@as(u32, 65), assembled.rows[2].line_count);

    const overflow = try repeatDirective(f.arena.allocator(), assemble.MAX_DIRECTIVES + 1);
    const root_bad = try f.addRoot("root_bad", overflow, &.{"a"});

    var failure: assemble.Failure = undefined;
    try testing.expectError(assemble.Error.TooDeep, run(&f, root_bad, &failure));
    try testing.expectEqual(root_bad, failure.at.?.index);
}

test "hoist: the no-import fast path never hoists the single origin" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const source = "enable f16;\nfn root() {}";
    const root = try f.addRoot("root", source, &.{});

    var assembled = try run(&f, root, null);
    defer assembled.deinit(testing.allocator);

    try testing.expectEqualStrings(source, assembled.text);
    try testing.expectEqual(@as(usize, 0), assembled.rows.len);
}

fn assembleHoistUnderOom(gpa: std.mem.Allocator) !void {
    var f = Fixture.init(gpa);
    defer f.deinit();

    // Two spellings of the same directive force a duplicate blank plus a
    // reallocating row list — the handoff window pngine found (§437).
    _ = try f.add(.wgsl, "a", "enable f16;\nfn a() {}", &.{});
    _ = try f.add(.wgsl, "b", "enable  f16;\nfn b() {}", &.{});
    const root = try f.addRoot("root", "enable f16;\nfn root() {}", &.{ "a", "b" });

    var program = f.program();
    var assembled = try assemble.assemble(gpa, &program, f.sources.items, f.rootId(root), null);
    assembled.deinit(gpa);
}

test "hoist: allocation failure across the text/rows handoff frees every partial" {
    try std.testing.checkAllAllocationFailures(testing.allocator, assembleHoistUnderOom, .{});
}
