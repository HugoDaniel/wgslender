//! Composed diagnostic projection (pngine-shaders phase 03, Task 2).
//!
//! The red-first contract:
//!   * a validator entry on a fragment's body lands on that fragment's URI
//!     and its own line/column, never the root's;
//!   * an error on a hoisted directive lands on the author's directive line;
//!   * a diagnostic on a synthetic part terminator is a zero-width range at
//!     that part's EOF;
//!   * a range crossing parts is dropped and the report carries exactly one
//!     `P0001`;
//!   * related information keeps the other file's URI and range while the
//!     primary diagnostic stays in the requested document's report;
//!   * a past-EOF diagnostic collapses to the root's EOF;
//!   * a quick fix survives only when its range maps to the requested
//!     document; otherwise the diagnostic survives without the textual fix.
//!
//! Every test drives `Handler` and the in-memory `SourceProvider` from
//! `pngine_test_provider.zig`; no test reads project text from the host
//! filesystem.

const std = @import("std");
const Handler = @import("Handler");
const wgslender = @import("wgslender");
const provider_mod = @import("pngine_test_provider.zig");

const pngine = wgslender.Pngine;
const Types = pngine.Types;
const Store = pngine.Store;
const FakeProvider = provider_mod.FakeProvider;
const PngineDiagnostics = Handler.PngineDiagnostics;

const testing = std.testing;

fn fileUri(buffer: []u8, path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "file://{s}", .{path});
}

fn countCode(diags: []const Handler.LspDiagnostic, code: []const u8) usize {
    var n: usize = 0;
    for (diags) |d| {
        if (std.mem.eql(u8, d.code, code)) n += 1;
    }
    return n;
}

fn findCode(diags: []const Handler.LspDiagnostic, code: []const u8) ?Handler.LspDiagnostic {
    for (diags) |d| {
        if (std.mem.eql(u8, d.code, code)) return d;
    }
    return null;
}

fn expectedRange(source: []const u8, start: u32, end: u32) Handler.Range {
    return Handler.offsetRangeToLspRange(source, start, end) orelse unreachable;
}

fn rangeOf(source: []const u8, needle: []const u8) Handler.Range {
    const start = std.mem.indexOf(u8, source, needle) orelse unreachable;
    return expectedRange(source, @intCast(start), @intCast(start + needle.len));
}

fn firstSegmentOfKind(assembled: *const pngine.Assembled, kind: pngine.Assemble.SegmentKind, origin: pngine.OriginKey) pngine.Assemble.Segment {
    for (assembled.segments) |segment| {
        if (segment.kind != kind) continue;
        if (segment.origin.program != origin.program or segment.origin.index != origin.index) continue;
        return segment;
    }
    unreachable;
}

fn partFor(store: *Store, program: Types.ProgramId, name: []const u8) Types.PartId {
    const program_value = store.program(program) orelse unreachable;
    const index = program_value.findFragment(name) orelse unreachable;
    return .{ .program = program, .index = index };
}

// =========================================================================
// Fixture — three fragments (two file-backed, one inline) and one root.
// =========================================================================

const fixture_program =
    \\(wgsl :name lib :file "lib.wgsl")
    \\(wgsl :name inlinepart :code "fn inline_value() -> f32 { return 3.0; }")
    \\(wgsl :name use :file "use.wgsl" :imports [lib inlinepart])
    \\(shader-module :name main :file "root.wgsl" :imports [use])
;

const fixture_lib = "fn shade() -> f32 { return 1.0; }";
const fixture_use = "fn lit() -> f32 { return shade() + inline_value(); }";

const fixture_root =
    \\@fragment
    \\fn fs_main() -> @location(0) vec4<f32> {
    \\  return vec4<f32>(shade() + inline_value());
    \\}
;

fn addFixture(fake: *FakeProvider) !void {
    try fake.addFile("/ws/program.sjon", fixture_program);
    try fake.addFile("/ws/lib.wgsl", fixture_lib);
    try fake.addFile("/ws/use.wgsl", fixture_use);
    try fake.addFile("/ws/root.wgsl", fixture_root);
}

fn bindStore(fake: *FakeProvider, store: *Store, handler: *Handler) !void {
    store.* = Store.init(testing.allocator, fake.sourceProvider());
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);
    handler.* = Handler.init(testing.allocator);
    handler.setPngineStore(store);
}

const Fixture = struct {
    fake: FakeProvider,
    store: Store,
    handler: Handler,

    fn init(self: *Fixture) !void {
        self.fake = FakeProvider.init(testing.allocator);
        try addFixture(&self.fake);
        try bindStore(&self.fake, &self.store, &self.handler);
    }

    fn deinit(self: *Fixture) void {
        self.handler.deinit();
        self.store.deinit();
        self.fake.deinit();
    }
};

fn membershipFor(store: *Store, path: []const u8) !Types.MembershipSet {
    var buffer: [512]u8 = undefined;
    return store.membershipsFor(try fileUri(&buffer, path));
}

fn rootOf(set: *const Types.MembershipSet, part: Types.PartId) !Types.PartId {
    for (set.items) |membership| {
        if (membership.part.program == part.program and membership.part.index == part.index) {
            if (membership.containing_roots.len == 0) return error.MissingRoot;
            return .{ .program = membership.program, .index = membership.containing_roots[0] };
        }
    }
    return error.MissingMembership;
}

// =========================================================================
// T1 — a body diagnostic in a non-root fragment keeps that fragment's URI
// and its own line/column.
// =========================================================================

test "T1 fragment body diagnostic projects to the fragment URI, not the root" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var lib_buffer: [256]u8 = undefined;
    const lib_uri = try fileUri(&lib_buffer, "/ws/lib.wgsl");

    const broken_lib = "fn shade() -> f32 { return missing_value; }";
    try fixture.handler.openDocument(lib_uri, broken_lib, 1);

    const diags = try fixture.handler.validatePngineDocument(lib_uri, .{});
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 1), countCode(diags, "E0100"));
    const diag = findCode(diags, "E0100").?;
    try testing.expectEqualDeep(rangeOf(broken_lib, "missing_value"), diag.range);
    // The root's own text never declared this name, so a root-local range
    // would have been a silent cross-file leak.
    try testing.expect(diag.range.start.character >= 24);
}

// =========================================================================
// T2 — an error on a hoisted directive lands on the author's directive.
// =========================================================================

test "T2 hoisted directive diagnostic projects to the author's directive line" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var use_buffer: [256]u8 = undefined;
    const use_uri = try fileUri(&use_buffer, "/ws/use.wgsl");

    const use_with_enable = "enable bogus;\nfn lit() -> f32 { return shade() + inline_value(); }";
    try fixture.handler.openDocument(use_uri, use_with_enable, 1);

    const diags = try fixture.handler.validatePngineDocument(use_uri, .{});
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 1), countCode(diags, "E0901"));
    const diag = findCode(diags, "E0901").?;
    // The validator reports this at assembled offset 0; that is the hoisted
    // copy of the author's first directive line.
    try testing.expectEqual(@as(u32, 0), diag.range.start.line);
    try testing.expectEqual(@as(u32, 0), diag.range.start.character);
}

// =========================================================================
// T3 — a synthetic part terminator maps to a zero-width author EOF.
// =========================================================================

test "T3 diagnostic on a part terminator is zero-width at that part's EOF" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var use_buffer: [256]u8 = undefined;
    const use_uri = try fileUri(&use_buffer, "/ws/use.wgsl");
    var set = try membershipFor(&fixture.store, "/ws/use.wgsl");
    defer set.deinit(testing.allocator);

    const root = try rootOf(&set, .{ .program = set.items[0].program, .index = set.items[0].part.index });
    const analysis = try fixture.handler.analyzeRoot(root);
    const use_part = partFor(&fixture.store, root.program, "use");
    const terminator = firstSegmentOfKind(analysis.assembled, .terminator, use_part);

    var report = PngineDiagnostics.Report.init(testing.allocator, &fixture.store, use_uri, set.items);
    defer report.deinit();
    const entry = wgslender.Diagnostic.Entry{
        .code = "E0100",
        .message = "synthetic boundary",
        .range = .{
            .start = .{ .offset = terminator.assembled.start },
            .end = .{ .offset = terminator.assembled.end },
        },
    };
    try report.add(analysis.assembled, &entry);

    const diags = try report.finish();
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(@as(usize, 0), countCode(diags, "P0001"));
    try testing.expectEqualDeep(
        expectedRange(fixture_use, fixture_use.len, fixture_use.len),
        diags[0].range,
    );
    try testing.expectEqual(diags[0].range.start, diags[0].range.end);
}

// =========================================================================
// T4 — a range crossing parts is dropped; exactly one P0001 per report.
// =========================================================================

test "T4 crossing ranges drop and produce exactly one P0001" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var use_buffer: [256]u8 = undefined;
    const use_uri = try fileUri(&use_buffer, "/ws/use.wgsl");
    var set = try membershipFor(&fixture.store, "/ws/use.wgsl");
    defer set.deinit(testing.allocator);

    const root = try rootOf(&set, .{ .program = set.items[0].program, .index = set.items[0].part.index });
    const analysis = try fixture.handler.analyzeRoot(root);

    var first: ?pngine.Assemble.Segment = null;
    var second: ?pngine.Assemble.Segment = null;
    for (analysis.assembled.segments) |segment| {
        if (segment.kind != .body and segment.kind != .hoisted) continue;
        if (first == null) {
            first = segment;
            continue;
        }
        if (segment.origin.program != first.?.origin.program or segment.origin.index != first.?.origin.index) {
            second = segment;
            break;
        }
    }
    try testing.expect(first != null and second != null);

    var report = PngineDiagnostics.Report.init(testing.allocator, &fixture.store, use_uri, set.items);
    defer report.deinit();

    // Two unmappable entries must still produce one report-level P0001.
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        const entry = wgslender.Diagnostic.Entry{
            .code = "E0100",
            .message = "crosses parts",
            .range = .{
                .start = .{ .offset = first.?.assembled.start },
                .end = .{ .offset = second.?.assembled.end },
            },
        };
        try report.add(analysis.assembled, &entry);
    }

    const diags = try report.finish();
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 1), countCode(diags, "P0001"));
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Handler.DiagnosticSeverity.warning, diags[0].severity);
    try testing.expect(std.mem.startsWith(u8, diags[0].message, "pngine project context is incomplete:"));
}

// =========================================================================
// T5 — related info on another file keeps that file's URI and range, while
// the primary diagnostic never leaves the requested document's report.
// =========================================================================

test "T5 related information keeps its own URI and primaries stay put" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var lib_buffer: [256]u8 = undefined;
    const lib_uri = try fileUri(&lib_buffer, "/ws/lib.wgsl");
    var use_buffer: [256]u8 = undefined;
    const use_uri = try fileUri(&use_buffer, "/ws/use.wgsl");

    const lib_text =
        \\const unrelated: f32 = 0.0;
        \\@group(0) @binding(0) var<uniform> first: f32;
    ;
    const use_text = "@group(0) @binding(0) var<uniform> second: f32;";
    try fixture.handler.openDocument(lib_uri, lib_text, 1);
    try fixture.handler.openDocument(use_uri, use_text, 1);

    // Requesting the second declaration's file yields the primary and a
    // related entry pointing at the first declaration in lib.wgsl.
    const use_diags = try fixture.handler.validatePngineDocument(use_uri, .{});
    defer Handler.freeDiagnostics(testing.allocator, use_diags);

    try testing.expectEqual(@as(usize, 1), countCode(use_diags, "E0804"));
    const primary = findCode(use_diags, "E0804").?;
    try testing.expectEqual(@as(u32, 0), primary.range.start.line);
    try testing.expectEqual(@as(usize, 1), primary.related.len);
    try testing.expectEqualStrings(lib_uri, primary.related[0].uri);
    try testing.expectEqual(@as(u32, 1), primary.related[0].range.start.line);

    // The primary range is in use.wgsl, so lib.wgsl's report must not carry
    // the duplicate finding at all.
    const lib_diags = try fixture.handler.validatePngineDocument(lib_uri, .{});
    defer Handler.freeDiagnostics(testing.allocator, lib_diags);
    try testing.expectEqual(@as(usize, 0), countCode(lib_diags, "E0804"));
}

// =========================================================================
// T8 — an inline `:code` origin has no file URI yet, so it degrades.
// =========================================================================

test "T8 an inline-code origin drops with one P0001" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var use_buffer: [256]u8 = undefined;
    const use_uri = try fileUri(&use_buffer, "/ws/use.wgsl");
    var set = try membershipFor(&fixture.store, "/ws/use.wgsl");
    defer set.deinit(testing.allocator);

    const root = try rootOf(&set, .{ .program = set.items[0].program, .index = set.items[0].part.index });
    const analysis = try fixture.handler.analyzeRoot(root);
    const inline_part = partFor(&fixture.store, root.program, "inlinepart");
    const inline_body = firstSegmentOfKind(analysis.assembled, .body, inline_part);

    var report = PngineDiagnostics.Report.init(testing.allocator, &fixture.store, use_uri, set.items);
    defer report.deinit();
    const entry = wgslender.Diagnostic.Entry{
        .code = "E0100",
        .message = "inside inline code",
        .range = .{
            .start = .{ .offset = inline_body.assembled.start },
            .end = .{ .offset = inline_body.assembled.start + 1 },
        },
    };
    try report.add(analysis.assembled, &entry);

    const diags = try report.finish();
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(@as(usize, 1), countCode(diags, "P0001"));
}

// =========================================================================
// T9 — the Handler path reports exactly one P0001 for dropped entries.
// =========================================================================

test "T9 validatePngineDocument reports one P0001 for an inline-only failure" {
    const inline_program =
        \\(wgsl :name inlinebad :code "fn broken() { let x = ; }")
        \\(shader-module :name main :file "root.wgsl" :imports [inlinebad])
    ;
    const root_text =
        \\@fragment
        \\fn fs_main() -> @location(0) vec4<f32> {
        \\  return vec4<f32>(1.0);
        \\}
    ;

    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", inline_program);
    try fake.addFile("/ws/root.wgsl", root_text);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindStore(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var root_buffer: [256]u8 = undefined;
    const root_uri = try fileUri(&root_buffer, "/ws/root.wgsl");
    try handler.openDocument(root_uri, root_text, 1);

    const diags = try handler.validatePngineDocument(root_uri, .{});
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 1), countCode(diags, "P0001"));
    try testing.expectEqual(@as(usize, 1), diags.len);
}

// =========================================================================
// T6 — a past-EOF diagnostic lands on the root's EOF.
// =========================================================================

test "T6 a past-EOF diagnostic collapses to the root's EOF" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var root_buffer: [256]u8 = undefined;
    const root_uri = try fileUri(&root_buffer, "/ws/root.wgsl");
    var set = try membershipFor(&fixture.store, "/ws/root.wgsl");
    defer set.deinit(testing.allocator);

    const root = try rootOf(&set, .{ .program = set.items[0].program, .index = set.items[0].part.index });
    const analysis = try fixture.handler.analyzeRoot(root);

    var report = PngineDiagnostics.Report.init(testing.allocator, &fixture.store, root_uri, set.items);
    defer report.deinit();
    const entry = wgslender.Diagnostic.Entry{
        .code = "E0001",
        .message = "unexpected end of file",
        .range = .{
            .start = .{ .offset = @intCast(analysis.assembled.text.len + 7) },
            .end = .{ .offset = @intCast(analysis.assembled.text.len + 9) },
        },
    };
    try report.add(analysis.assembled, &entry);

    const diags = try report.finish();
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqualDeep(
        expectedRange(fixture_root, fixture_root.len, fixture_root.len),
        diags[0].range,
    );
}

// =========================================================================
// T7 — a quick fix survives only when its range maps to the requested file.
// =========================================================================

test "T7 quick fixes survive only when every range maps to the requested file" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var lib_buffer: [256]u8 = undefined;
    const lib_uri = try fileUri(&lib_buffer, "/ws/lib.wgsl");
    var set = try membershipFor(&fixture.store, "/ws/lib.wgsl");
    defer set.deinit(testing.allocator);

    const root = try rootOf(&set, .{ .program = set.items[0].program, .index = set.items[0].part.index });
    const analysis = try fixture.handler.analyzeRoot(root);

    const lib_part = partFor(&fixture.store, root.program, "lib");
    const use_part = partFor(&fixture.store, root.program, "use");
    const lib_body = firstSegmentOfKind(analysis.assembled, .body, lib_part);
    const use_body = firstSegmentOfKind(analysis.assembled, .body, use_part);

    var report = PngineDiagnostics.Report.init(testing.allocator, &fixture.store, lib_uri, set.items);
    defer report.deinit();

    // Primary maps to lib; the fix points into use, so the diagnostic stays
    // but the textual fix is withheld.
    const cross_fix = wgslender.Diagnostic.Fix{
        .range = .{
            .start = .{ .offset = use_body.assembled.start },
            .end = .{ .offset = use_body.assembled.start + 1 },
        },
        .text = "X",
    };
    const cross_entry = wgslender.Diagnostic.Entry{
        .code = "W0001",
        .message = "unused",
        .range = .{
            .start = .{ .offset = lib_body.assembled.start },
            .end = .{ .offset = lib_body.assembled.start + 1 },
        },
        .fix = &cross_fix,
    };
    try report.add(analysis.assembled, &cross_entry);

    // Primary and fix both map to lib, so the fix survives with lib-local
    // coordinates.
    const local_fix = wgslender.Diagnostic.Fix{
        .range = .{
            .start = .{ .offset = lib_body.assembled.start },
            .end = .{ .offset = lib_body.assembled.start + 2 },
        },
        .text = "Y",
    };
    const local_entry = wgslender.Diagnostic.Entry{
        .code = "W0001",
        .message = "unused locally",
        .range = .{
            .start = .{ .offset = lib_body.assembled.start },
            .end = .{ .offset = lib_body.assembled.start + 1 },
        },
        .fix = &local_fix,
    };
    try report.add(analysis.assembled, &local_entry);

    const diags = try report.finish();
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 2), diags.len);
    try testing.expectEqual(wgslender.Diagnostic.QuickFixHint.none, diags[0].data);
    try testing.expect(diags[1].data == .lint_fix);
    const hint = diags[1].data.lint_fix;
    const fix_range = expectedRange(fixture_lib, 0, 2);
    try testing.expectEqual(fix_range.start.line, hint.start_line);
    try testing.expectEqual(fix_range.start.character, hint.start_character);
    try testing.expectEqual(fix_range.end.line, hint.end_line);
    try testing.expectEqual(fix_range.end.character, hint.end_character);
    try testing.expectEqualStrings("Y", hint.text);
}

// =========================================================================
// Task 3 — multi-root union, graph errors, requirement holes, pass
// boundaries and broken-program isolation.
// =========================================================================

fn countRelatedPrefix(diag: Handler.LspDiagnostic, prefix: []const u8) usize {
    var n: usize = 0;
    for (diag.related) |r| {
        if (std.mem.startsWith(u8, r.message, prefix)) n += 1;
    }
    return n;
}

fn findRelatedPrefix(diag: Handler.LspDiagnostic, prefix: []const u8) ?Handler.LspRelatedInfo {
    for (diag.related) |r| {
        if (std.mem.startsWith(u8, r.message, prefix)) return r;
    }
    return null;
}

fn bindFixture(
    fake: *FakeProvider,
    store: *Store,
    handler: *Handler,
) !void {
    try bindStore(fake, store, handler);
}

// =========================================================================
// T10 — the same finding in four roots is one diagnostic, and its related
// information names every failing root in stable postorder.
// =========================================================================

test "T10 identical findings in four roots dedupe once and name every root" {
    const program =
        \\(wgsl :name shared :file "shared.wgsl")
        \\(shader-module :name rootA :file "a.wgsl" :imports [shared])
        \\(shader-module :name rootB :file "b.wgsl" :imports [shared])
        \\(shader-module :name rootC :file "c.wgsl" :imports [shared])
        \\(shader-module :name rootD :file "d.wgsl" :imports [shared])
    ;
    const shared_text = "const bad: i32 = 1.5;";

    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", program);
    try fake.addFile("/ws/shared.wgsl", shared_text);
    try fake.addFile("/ws/a.wgsl", "// a");
    try fake.addFile("/ws/b.wgsl", "// b");
    try fake.addFile("/ws/c.wgsl", "// c");
    try fake.addFile("/ws/d.wgsl", "// d");

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindFixture(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var shared_buffer: [256]u8 = undefined;
    const shared_uri = try fileUri(&shared_buffer, "/ws/shared.wgsl");
    try handler.openDocument(shared_uri, shared_text, 1);

    const diags = try handler.validatePngineDocument(shared_uri, .{});
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 1), countCode(diags, "E0200"));
    try testing.expectEqual(@as(usize, 0), countCode(diags, "E0100"));
    const diag = findCode(diags, "E0200").?;
    try testing.expectEqual(@as(u32, 0), diag.range.start.line);

    try testing.expectEqual(@as(usize, 4), countRelatedPrefix(diag, "root '"));
    const expected_roots = [_][]const u8{ "rootA", "rootB", "rootC", "rootD" };
    var seen: usize = 0;
    for (diag.related) |rel| {
        if (!std.mem.startsWith(u8, rel.message, "root '")) continue;
        const expected = try std.fmt.allocPrint(
            testing.allocator,
            "root '{s}'",
            .{expected_roots[seen]},
        );
        defer testing.allocator.free(expected);
        try testing.expectEqualStrings(expected, rel.message);
        try testing.expectEqualStrings("file:///ws/program.sjon", rel.uri);
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 4), seen);
}

// =========================================================================
// T11 — a name resolved in root A but not root B reports only on B and
// names B.
// =========================================================================

test "T11 unresolved name in one root reports only that root" {
    const program =
        \\(wgsl :name shared :file "shared.wgsl")
        \\(shader-module :name withSecret :file "a.wgsl" :imports [shared])
        \\(shader-module :name withoutSecret :file "b.wgsl" :imports [shared])
    ;
    const shared_text = "fn use_value() -> f32 { return secret; }";

    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", program);
    try fake.addFile("/ws/shared.wgsl", shared_text);
    try fake.addFile("/ws/a.wgsl", "const secret: f32 = 1.0;");
    try fake.addFile("/ws/b.wgsl", "// b");

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindFixture(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var shared_buffer: [256]u8 = undefined;
    const shared_uri = try fileUri(&shared_buffer, "/ws/shared.wgsl");
    try handler.openDocument(shared_uri, shared_text, 1);

    const diags = try handler.validatePngineDocument(shared_uri, .{});
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 1), countCode(diags, "E0100"));
    const diag = findCode(diags, "E0100").?;
    try testing.expectEqualDeep(rangeOf(shared_text, "secret"), diag.range);
    try testing.expect(std.mem.endsWith(
        u8,
        diag.message,
        " — declared nowhere in pngine module 'withoutSecret'",
    ));
    try testing.expect(std.mem.indexOf(u8, diag.message, "withSecret") == null);
    try testing.expectEqual(@as(usize, 1), countRelatedPrefix(diag, "root '"));
    try testing.expectEqualStrings("root 'withoutSecret'", findRelatedPrefix(diag, "root '").?.message);
}

// =========================================================================
// T12 — a cycle is P0002 with the ordered path in related information.
// =========================================================================

test "T12 import cycle is P0002 with the ordered cycle path" {
    const program =
        \\(wgsl :name cyc_a :file "cyc_a.wgsl" :imports [cyc_b])
        \\(wgsl :name cyc_b :file "cyc_b.wgsl" :imports [cyc_a])
        \\(shader-module :name main :file "root.wgsl" :imports [cyc_a])
    ;

    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", program);
    try fake.addFile("/ws/cyc_a.wgsl", "fn a() {}");
    try fake.addFile("/ws/cyc_b.wgsl", "fn b() {}");
    try fake.addFile("/ws/root.wgsl", "// root");

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindFixture(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var buffer: [256]u8 = undefined;
    const uri = try fileUri(&buffer, "/ws/cyc_a.wgsl");
    try handler.openDocument(uri, "fn a() {}", 1);

    const diags = try handler.validatePngineDocument(uri, .{});
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 1), countCode(diags, "P0002"));
    const diag = findCode(diags, "P0002").?;
    try testing.expect(std.mem.indexOf(u8, diag.message, "cannot be assembled") != null);
    try testing.expect(std.mem.indexOf(u8, diag.message, "cyc_a -> cyc_b -> cyc_a") != null);
    try testing.expectEqual(@as(usize, 0), countCode(diags, "E0100"));

    var cycle_related: usize = 0;
    var first_range: ?Handler.Range = null;
    var last_range: ?Handler.Range = null;
    for (diag.related) |rel| {
        if (std.mem.indexOf(u8, rel.message, "import cycle") == null) continue;
        try testing.expect(std.mem.indexOf(u8, rel.message, "cyc_a -> cyc_b -> cyc_a") != null);
        if (first_range == null) first_range = rel.range;
        last_range = rel.range;
        cycle_related += 1;
    }
    try testing.expectEqual(@as(usize, 3), cycle_related);
    try testing.expectEqualDeep(first_range.?, last_range.?);
}

// =========================================================================
// T13 — an unknown import is P0002 naming the unresolved edge.
// =========================================================================

test "T13 unknown import is P0002 naming the unresolved edge" {
    const program =
        \\(wgsl :name lib :file "lib.wgsl")
        \\(shader-module :name main :file "root.wgsl" :imports [lib nope])
    ;

    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", program);
    try fake.addFile("/ws/lib.wgsl", "fn lib_fn() {}");
    try fake.addFile("/ws/root.wgsl", "// root");

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindFixture(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var buffer: [256]u8 = undefined;
    const uri = try fileUri(&buffer, "/ws/root.wgsl");
    try handler.openDocument(uri, "// root", 1);

    const diags = try handler.validatePngineDocument(uri, .{});
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 1), countCode(diags, "P0002"));
    const diag = findCode(diags, "P0002").?;
    try testing.expect(std.mem.indexOf(u8, diag.message, "unknown import 'nope'") != null);
    try testing.expect(std.mem.indexOf(u8, diag.message, "'main'") != null);
    try testing.expectEqual(@as(usize, 1), countRelatedPrefix(diag, "unknown import"));
    try testing.expectEqualStrings("unknown import 'nope'", findRelatedPrefix(diag, "unknown import").?.message);
    try testing.expectEqual(@as(usize, 0), countCode(diags, "E0100"));
}

// =========================================================================
// T14 — a missing file is P0002 naming the part, with no invented text.
// =========================================================================

test "T14 missing source is P0002 naming the part without inventing text" {
    const program =
        \\(wgsl :name ghost :file "ghost.wgsl")
        \\(shader-module :name main :file "root.wgsl" :imports [ghost])
    ;

    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", program);
    try fake.addFile("/ws/root.wgsl", "// root");

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindFixture(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var buffer: [256]u8 = undefined;
    const uri = try fileUri(&buffer, "/ws/root.wgsl");
    try handler.openDocument(uri, "// root", 1);

    const diags = try handler.validatePngineDocument(uri, .{});
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 1), countCode(diags, "P0002"));
    const diag = findCode(diags, "P0002").?;
    try testing.expect(std.mem.indexOf(u8, diag.message, "missing source") != null);
    try testing.expect(std.mem.indexOf(u8, diag.message, "'ghost'") != null);
    try testing.expect(std.mem.indexOf(u8, diag.message, "ghost.wgsl") != null);
    try testing.expectEqual(@as(usize, 1), countRelatedPrefix(diag, "missing source"));
    try testing.expectEqualStrings(
        "missing source 'ghost.wgsl'",
        findRelatedPrefix(diag, "missing source").?.message,
    );
    try testing.expectEqual(@as(usize, 0), countCode(diags, "E0100"));
}

// =========================================================================
// T15 — a :requires hole with no parsed module declaration is P0003.
// Comments and satisfied sibling declarations prove the check is AST-based.
// =========================================================================

test "T15 missing requirement is P0003 judged on parsed declarations" {
    const program =
        \\(wgsl :name holey :file "holey.wgsl" :requires [noise supplied])
        \\(wgsl :name supplier :file "supplier.wgsl")
        \\(shader-module :name main :file "root.wgsl" :imports [holey supplier])
    ;
    const holey_text = "fn holey_value() -> f32 { return 1.0; } // noise is only a comment";

    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", program);
    try fake.addFile("/ws/holey.wgsl", holey_text);
    try fake.addFile("/ws/supplier.wgsl", "const supplied: f32 = 2.0;");
    try fake.addFile("/ws/root.wgsl", "// root");

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindFixture(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var buffer: [256]u8 = undefined;
    const uri = try fileUri(&buffer, "/ws/holey.wgsl");
    try handler.openDocument(uri, holey_text, 1);

    const diags = try handler.validatePngineDocument(uri, .{});
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 1), countCode(diags, "P0003"));
    const diag = findCode(diags, "P0003").?;
    try testing.expectEqualStrings(
        "fragment 'holey' requires 'noise', declared nowhere in pngine module 'main'",
        diag.message,
    );
    try testing.expectEqual(@as(usize, 0), countCode(diags, "P0002"));

    try testing.expectEqual(@as(usize, 1), countRelatedPrefix(diag, "requirement '"));
    try testing.expectEqualStrings(
        "requirement 'noise'",
        findRelatedPrefix(diag, "requirement '").?.message,
    );
    try testing.expectEqual(@as(usize, 1), countRelatedPrefix(diag, "root '"));
    const req_rel = findRelatedPrefix(diag, "requirement '").?;
    const root_rel = findRelatedPrefix(diag, "root '").?;
    try testing.expectEqualStrings("file:///ws/program.sjon", req_rel.uri);
    try testing.expectEqualStrings("file:///ws/program.sjon", root_rel.uri);
    // The requirement relation starts on the `noise` token itself.
    const noise_start = std.mem.indexOf(u8, program, "noise").?;
    const program_range = expectedRange(program, @intCast(noise_start), @intCast(noise_start + "noise".len));
    try testing.expectEqualDeep(program_range, req_rel.range);
}

// =========================================================================
// T16 — the standalone E0100 wording is untouched by the composed suffix.
// =========================================================================

test "T16 standalone E0100 keeps its original wording" {
    var handler = Handler.init(testing.allocator);
    defer handler.deinit();

    const source = "fn f() -> f32 { return missing; }";
    const diags = try Handler.validateDocument(&handler, source);
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 1), countCode(diags, "E0100"));
    const diag = findCode(diags, "E0100").?;
    try testing.expectEqualStrings("use of undeclared identifier 'missing'", diag.message);
    try testing.expectEqual(@as(usize, 0), diag.related.len);
}

// =========================================================================
// T17 — a pass-only fragment gets P0004, not a standalone semantic claim.
// =========================================================================

test "T17 pass-only fragment reports P0004 and no unresolved noise" {
    const program =
        \\(wgsl :name passlib :file "passlib.wgsl")
        \\(pass :name mainPass :code "@compute @workgroup_size(1) fn main() {}" :imports [passlib])
    ;
    const passlib_text = "fn helper() -> f32 { return generated_prelude_value; }";

    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", program);
    try fake.addFile("/ws/passlib.wgsl", passlib_text);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindFixture(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var buffer: [256]u8 = undefined;
    const uri = try fileUri(&buffer, "/ws/passlib.wgsl");
    try handler.openDocument(uri, passlib_text, 1);

    const diags = try handler.validatePngineDocument(uri, .{});
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 1), countCode(diags, "P0004"));
    const diag = findCode(diags, "P0004").?;
    try testing.expectEqualStrings(
        "pngine pass 'mainPass' requires generated bindings; semantic validation is unavailable for this context",
        diag.message,
    );
    try testing.expectEqual(@as(usize, 0), countCode(diags, "E0100"));
    try testing.expectEqual(@as(usize, 0), countCode(diags, "P0001"));
}

// =========================================================================
// T18 — pass-only local syntax is still reported alongside P0004.
// =========================================================================

test "T18 pass-only fragment keeps its local syntax diagnostics" {
    const program =
        \\(wgsl :name passlib :file "passlib.wgsl")
        \\(pass :name mainPass :code "@compute @workgroup_size(1) fn main() {}" :imports [passlib])
    ;
    const broken = "fn broken( {";

    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", program);
    try fake.addFile("/ws/passlib.wgsl", broken);

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindFixture(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var buffer: [256]u8 = undefined;
    const uri = try fileUri(&buffer, "/ws/passlib.wgsl");
    try handler.openDocument(uri, broken, 1);

    const diags = try handler.validatePngineDocument(uri, .{});
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 1), countCode(diags, "P0004"));
    var syntax: usize = 0;
    for (diags) |diag| {
        if (!std.mem.startsWith(u8, diag.code, "P0")) syntax += 1;
    }
    try testing.expect(syntax > 0);
    try testing.expectEqual(@as(usize, 0), countCode(diags, "E0100"));
}

// =========================================================================
// T19 — a known fragment in no root gets local syntax plus one P0001.
// =========================================================================

test "T19 orphan fragment gets one P0001 and no project semantics" {
    const program =
        \\(wgsl :name orphan :file "orphan.wgsl" :requires [noise])
        \\(shader-module :name main :file "root.wgsl")
    ;
    const orphan_text = "fn orphan_value() -> f32 { return 1.0; }";

    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", program);
    try fake.addFile("/ws/orphan.wgsl", orphan_text);
    try fake.addFile("/ws/root.wgsl", "// root");

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindFixture(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var buffer: [256]u8 = undefined;
    const uri = try fileUri(&buffer, "/ws/orphan.wgsl");
    try handler.openDocument(uri, orphan_text, 1);

    const diags = try handler.validatePngineDocument(uri, .{});
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 1), countCode(diags, "P0001"));
    try testing.expectEqualStrings(
        "pngine project context is incomplete: no shader-module root contains this file; only local syntax is reported",
        findCode(diags, "P0001").?.message,
    );
    try testing.expectEqual(@as(usize, 0), countCode(diags, "P0003"));
    try testing.expectEqual(@as(usize, 0), countCode(diags, "E0100"));
}

// =========================================================================
// T20 — a broken program does not suppress a valid program's diagnostics.
// =========================================================================

test "T20 a broken root does not suppress a valid program's diagnostics" {
    const one =
        \\(wgsl :name shared :file "shared.wgsl")
        \\(shader-module :name bad :file "bad.wgsl" :imports [shared nope])
    ;
    const two =
        \\(wgsl :name shared :file "shared.wgsl")
        \\(shader-module :name good :file "good.wgsl" :imports [shared])
    ;
    const shared_text = "const bad: i32 = 1.5;";

    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/one.sjon", one);
    try fake.addFile("/ws/two.sjon", two);
    try fake.addFile("/ws/shared.wgsl", shared_text);
    try fake.addFile("/ws/bad.wgsl", "// bad");
    try fake.addFile("/ws/good.wgsl", "// good");

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindFixture(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var buffer: [256]u8 = undefined;
    const uri = try fileUri(&buffer, "/ws/shared.wgsl");
    try handler.openDocument(uri, shared_text, 1);

    const diags = try handler.validatePngineDocument(uri, .{});
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 1), countCode(diags, "P0002"));
    try testing.expect(std.mem.indexOf(u8, findCode(diags, "P0002").?.message, "'bad'") != null);
    try testing.expectEqual(@as(usize, 1), countCode(diags, "E0200"));
    const valid_diag = findCode(diags, "E0200").?;
    try testing.expectEqual(@as(usize, 1), countRelatedPrefix(valid_diag, "root '"));
    try testing.expectEqualStrings("root 'good'", findRelatedPrefix(valid_diag, "root '").?.message);
    try testing.expectEqual(@as(usize, 0), countCode(diags, "P0001"));
}

// =========================================================================
// T21 — E0204 is preserved verbatim, never rewritten as "declared nowhere".
// =========================================================================

test "T21 not-callable keeps E0204 wording" {
    const program =
        \\(wgsl :name lib :file "lib.wgsl")
        \\(shader-module :name main :file "root.wgsl" :imports [lib])
    ;
    const lib_text = "const loose: f32 = 1.0;\nfn invokes() -> f32 { return loose(); }";

    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", program);
    try fake.addFile("/ws/lib.wgsl", lib_text);
    try fake.addFile("/ws/root.wgsl", "// root");

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindFixture(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var buffer: [256]u8 = undefined;
    const uri = try fileUri(&buffer, "/ws/lib.wgsl");
    try handler.openDocument(uri, lib_text, 1);

    const diags = try handler.validatePngineDocument(uri, .{});
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 1), countCode(diags, "E0204"));
    const diag = findCode(diags, "E0204").?;
    try testing.expect(std.mem.indexOf(u8, diag.message, "declared nowhere") == null);
    try testing.expect(std.mem.indexOf(u8, diag.message, "loose") != null);
}

// =========================================================================
// T22 — a depth overflow is P0002 identifying the violated bound.
// =========================================================================

test "T22 import depth overflow is P0002 naming the bound" {
    var program: std.ArrayList(u8) = .empty;
    defer program.deinit(testing.allocator);

    const fragment_count = 66;
    var i: usize = 0;
    while (i < fragment_count) : (i += 1) {
        if (i + 1 < fragment_count) {
            const line = try std.fmt.allocPrint(
                testing.allocator,
                "(wgsl :name f{d} :file \"f{d}.wgsl\" :imports [f{d}])\n",
                .{ i, i, i + 1 },
            );
            defer testing.allocator.free(line);
            try program.appendSlice(testing.allocator, line);
        } else {
            const line = try std.fmt.allocPrint(
                testing.allocator,
                "(wgsl :name f{d} :file \"f{d}.wgsl\")\n",
                .{ i, i },
            );
            defer testing.allocator.free(line);
            try program.appendSlice(testing.allocator, line);
        }
    }
    const root_line = "(shader-module :name main :file \"root.wgsl\" :imports [f0])\n";
    try program.appendSlice(testing.allocator, root_line);

    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", program.items);
    i = 0;
    while (i < fragment_count) : (i += 1) {
        const text = try std.fmt.allocPrint(testing.allocator, "// f{d}", .{i});
        defer testing.allocator.free(text);
        const path = try std.fmt.allocPrint(testing.allocator, "/ws/f{d}.wgsl", .{i});
        defer testing.allocator.free(path);
        try fake.addFile(path, text);
    }
    try fake.addFile("/ws/root.wgsl", "// root");

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindFixture(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var buffer: [256]u8 = undefined;
    const uri = try fileUri(&buffer, "/ws/root.wgsl");
    try handler.openDocument(uri, "// root", 1);

    const diags = try handler.validatePngineDocument(uri, .{});
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 1), countCode(diags, "P0002"));
    const diag = findCode(diags, "P0002").?;
    try testing.expect(std.mem.indexOf(u8, diag.message, "bound") != null);
}

// =========================================================================
// T23 — mixed pass and shader-module membership: shader diagnostics plus
// one explicit pause limitation and no duplicated local syntax.
// =========================================================================

test "T23 mixed membership adds P0004 without duplicating local syntax" {
    const program =
        \\(wgsl :name mixed :file "mixed.wgsl")
        \\(shader-module :name sm :file "sm.wgsl" :imports [mixed])
        \\(pass :name ps :code "@compute @workgroup_size(1) fn main() {}" :imports [mixed])
    ;
    const mixed_text = "const bad: i32 = 1.5;";

    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", program);
    try fake.addFile("/ws/mixed.wgsl", mixed_text);
    try fake.addFile("/ws/sm.wgsl", "// sm");

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindFixture(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var buffer: [256]u8 = undefined;
    const uri = try fileUri(&buffer, "/ws/mixed.wgsl");
    try handler.openDocument(uri, mixed_text, 1);

    const diags = try handler.validatePngineDocument(uri, .{});
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 1), countCode(diags, "E0200"));
    try testing.expectEqual(@as(usize, 1), countCode(diags, "P0004"));
    var syntax: usize = 0;
    for (diags) |diag| {
        if (diag.code.len == 0) syntax += 1;
    }
    try testing.expectEqual(@as(usize, 0), syntax);
    try testing.expectEqual(@as(usize, 0), countCode(diags, "P0001"));
}

// =========================================================================
// T24 — an unresolved name missing from all four roots stays one
// diagnostic; the rewrite keys on the original validator message.
// =========================================================================

test "T24 shared unresolved name dedupes before the E0100 rewrite" {
    const program =
        \\(wgsl :name shared :file "shared.wgsl")
        \\(shader-module :name rootA :file "a.wgsl" :imports [shared])
        \\(shader-module :name rootB :file "b.wgsl" :imports [shared])
        \\(shader-module :name rootC :file "c.wgsl" :imports [shared])
        \\(shader-module :name rootD :file "d.wgsl" :imports [shared])
    ;
    const shared_text = "fn use_value() -> f32 { return secret; }";

    var fake = FakeProvider.init(testing.allocator);
    defer fake.deinit();
    try fake.addFile("/ws/program.sjon", program);
    try fake.addFile("/ws/shared.wgsl", shared_text);
    try fake.addFile("/ws/a.wgsl", "// a");
    try fake.addFile("/ws/b.wgsl", "// b");
    try fake.addFile("/ws/c.wgsl", "// c");
    try fake.addFile("/ws/d.wgsl", "// d");

    var store: Store = undefined;
    var handler: Handler = undefined;
    try bindFixture(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();

    var buffer: [256]u8 = undefined;
    const uri = try fileUri(&buffer, "/ws/shared.wgsl");
    try handler.openDocument(uri, shared_text, 1);

    const diags = try handler.validatePngineDocument(uri, .{});
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 1), countCode(diags, "E0100"));
    const diag = findCode(diags, "E0100").?;
    try testing.expectEqualDeep(rangeOf(shared_text, "secret"), diag.range);
    try testing.expect(std.mem.endsWith(
        u8,
        diag.message,
        " — declared nowhere in pngine module 'rootA'",
    ));
    try testing.expectEqual(@as(usize, 4), countRelatedPrefix(diag, "root '"));
}
