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
