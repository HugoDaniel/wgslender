//! Whole-unit lint semantics for pngine shader projects (pngine-shaders
//! phase 03, Task 4).
//!
//! The red-first contract:
//!   * `W0001`/`W0002`/`W0003` are judged on the assembled unit and reported
//!     only when they hold in every root that contains the origin part — a
//!     symbol used by one root is not globally unused;
//!   * a fragment only two of four roots reach reports through those two;
//!   * purely local style findings fire once per origin, not once per root;
//!   * the module-size M-rule runs only when the part has one unambiguous
//!     root context;
//!   * a quick fix survives only when every edit byte is inside the
//!     requested author file and no other root offers a different rewrite
//!     for the same range;
//!   * the standalone lint path is untouched (same registry, same defaults).
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

fn countMessage(diags: []const Handler.LspDiagnostic, needle: []const u8) usize {
    var n: usize = 0;
    for (diags) |d| {
        if (std.mem.indexOf(u8, d.message, needle) != null) n += 1;
    }
    return n;
}

fn findMessage(diags: []const Handler.LspDiagnostic, needle: []const u8) ?Handler.LspDiagnostic {
    for (diags) |d| {
        if (std.mem.indexOf(u8, d.message, needle) != null) return d;
    }
    return null;
}

fn countRelatedPrefix(diag: Handler.LspDiagnostic, prefix: []const u8) usize {
    var n: usize = 0;
    for (diag.related) |r| {
        if (std.mem.startsWith(u8, r.message, prefix)) n += 1;
    }
    return n;
}

fn expectRelatedRoots(diag: Handler.LspDiagnostic, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, countRelatedRoots(diag));
    var seen: usize = 0;
    for (diag.related) |rel| {
        if (!std.mem.startsWith(u8, rel.message, "root '")) continue;
        const want = try std.fmt.allocPrint(testing.allocator, "root '{s}'", .{expected[seen]});
        defer testing.allocator.free(want);
        try testing.expectEqualStrings(want, rel.message);
        try testing.expectEqualStrings("file:///ws/program.sjon", rel.uri);
        seen += 1;
    }
}

fn countRelatedRoots(diag: Handler.LspDiagnostic) usize {
    return countRelatedPrefix(diag, "root '");
}

fn rootByName(store: *Store, program_id: Types.ProgramId, name: []const u8) Types.PartId {
    const program = store.program(program_id) orelse unreachable;
    for (program.parts, 0..) |part, index| {
        if (!part.isRoot()) continue;
        if (std.mem.eql(u8, part.name, name)) {
            return .{ .program = program_id, .index = @intCast(index) };
        }
    }
    unreachable;
}

fn partFor(store: *Store, program_id: Types.ProgramId, name: []const u8) Types.PartId {
    const program = store.program(program_id) orelse unreachable;
    const index = program.findFragment(name) orelse unreachable;
    return .{ .program = program_id, .index = index };
}

fn membershipFor(store: *Store, path: []const u8) !Types.MembershipSet {
    var buffer: [512]u8 = undefined;
    return store.membershipsFor(try fileUri(&buffer, path));
}

fn assembledRange(
    assembled: *const pngine.Assembled,
    origin: Types.PartId,
    start: u32,
    end: u32,
) wgslender.Diagnostic.Range {
    const mapped = assembled.fromOrigin(origin, .{ .start = start, .end = end }) orelse unreachable;
    return .{
        .start = .{ .offset = mapped.start },
        .end = .{ .offset = mapped.end },
    };
}

// =========================================================================
// Fixture — four roots, one shared library, one partial-only fragment, a
// style fragment, a fixable fragment and one inline part.
// =========================================================================

const fixture_program =
    \\(wgsl :name shared :file "shared.wgsl")
    \\(wgsl :name partial :file "partial.wgsl")
    \\(wgsl :name style :file "style.wgsl")
    \\(wgsl :name fixes :file "fixes.wgsl")
    \\(wgsl :name inlinepart :code "fn inlineFixTarget() -> f32 { return 6.0; }")
    \\(shader-module :name r1 :file "r1.wgsl" :imports [shared fixes inlinepart])
    \\(shader-module :name r2 :file "r2.wgsl" :imports [shared style fixes])
    \\(shader-module :name r3 :file "r3.wgsl" :imports [shared partial style fixes])
    \\(shader-module :name r4 :file "r4.wgsl" :imports [shared partial])
;

const fixture_shared =
    \\fn sharedUsedByOne() -> f32 { return 1.0; }
    \\fn sharedNeverUsed() -> f32 { return 2.0; }
    \\fn deadRootUsedByOne() -> f32 { return deadLeafUsedByOne(); }
    \\fn deadLeafUsedByOne() -> f32 { return 3.0; }
    \\fn deadRootNeverUsed() -> f32 { return deadLeafNeverUsed(); }
    \\fn deadLeafNeverUsed() -> f32 { return 4.0; }
    \\
    \\@group(0) @binding(0) var<uniform> usedBinding: f32;
    \\@group(0) @binding(1) var<uniform> neverUsedBinding: f32;
;

const fixture_partial = "fn partialNeverUsed() -> f32 { return 5.0; }";

const fixture_style =
    \\fn Bad_Name() -> f32 { return 42.0; }
    \\fn styleProbe() -> f32 { return Bad_Name(); }
;

const fixture_fixes =
    \\fn fixProbe() -> f32 {
    \\  var x = 1.0;
    \\  x = x;
    \\  return x;
    \\}
;

const fixture_r1 =
    \\@fragment
    \\fn r1_main() -> @location(0) vec4<f32> {
    \\  return vec4<f32>(sharedUsedByOne() + deadRootUsedByOne() + usedBinding + inlineFixTarget());
    \\}
;

const fixture_r2 =
    \\@fragment
    \\fn r2_main() -> @location(0) vec4<f32> {
    \\  return vec4<f32>(fixProbe() + styleProbe());
    \\}
;

const fixture_r3 =
    \\@fragment
    \\fn r3_main() -> @location(0) vec4<f32> {
    \\  return vec4<f32>(fixProbe() + styleProbe());
    \\}
;

const fixture_r4 =
    \\@fragment
    \\fn r4_main() -> @location(0) vec4<f32> {
    \\  return vec4<f32>(1.0);
    \\}
;

const Fixture = struct {
    fake: FakeProvider,
    store: Store,
    handler: Handler,

    fn init(self: *Fixture) !void {
        self.fake = FakeProvider.init(testing.allocator);
        try self.fake.addFile("/ws/program.sjon", fixture_program);
        try self.fake.addFile("/ws/shared.wgsl", fixture_shared);
        try self.fake.addFile("/ws/partial.wgsl", fixture_partial);
        try self.fake.addFile("/ws/style.wgsl", fixture_style);
        try self.fake.addFile("/ws/fixes.wgsl", fixture_fixes);
        try self.fake.addFile("/ws/r1.wgsl", fixture_r1);
        try self.fake.addFile("/ws/r2.wgsl", fixture_r2);
        try self.fake.addFile("/ws/r3.wgsl", fixture_r3);
        try self.fake.addFile("/ws/r4.wgsl", fixture_r4);

        self.store = Store.init(testing.allocator, self.fake.sourceProvider());
        const roots = [_][]const u8{"/ws"};
        try self.store.setWorkspaceRoots(&roots);
        self.handler = Handler.init(testing.allocator);
        self.handler.setPngineStore(&self.store);
    }

    fn deinit(self: *Fixture) void {
        self.handler.deinit();
        self.store.deinit();
        self.fake.deinit();
    }

    fn setConfig(self: *Fixture, json: []const u8) !void {
        self.handler.project_config.deinit(testing.allocator);
        self.handler.project_config = try wgslender.Config.parseJson(testing.allocator, json);
    }
};

// =========================================================================
// 1. W0001/W0002/W0003 are intersected across every containing root.
// =========================================================================

test "unused and dead findings require every root that contains the fragment" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var buffer: [256]u8 = undefined;
    const uri = try fileUri(&buffer, "/ws/shared.wgsl");
    try fixture.handler.openDocument(uri, fixture_shared, 1);

    const diags = try fixture.handler.validatePngineDocument(uri, .{});
    defer Handler.freeDiagnostics(testing.allocator, diags);

    // Used by exactly one of four roots: unused nowhere.
    try testing.expectEqual(@as(usize, 0), countMessage(diags, "'sharedUsedByOne'"));
    try testing.expectEqual(@as(usize, 0), countMessage(diags, "'deadRootUsedByOne'"));
    try testing.expectEqual(@as(usize, 0), countMessage(diags, "'deadLeafUsedByOne'"));
    try testing.expectEqual(@as(usize, 0), countMessage(diags, "'usedBinding'"));

    // Unused by every root: reported once, naming every containing root.
    const never_used = findMessage(diags, "'sharedNeverUsed'") orelse return error.TestExpectedUnused;
    try testing.expectEqualStrings("W0001", never_used.code);
    try expectRelatedRoots(never_used, &.{ "r1", "r2", "r3", "r4" });

    const dead_root = findMessage(diags, "'deadRootNeverUsed'") orelse return error.TestExpectedDead;
    try testing.expectEqualStrings("W0001", dead_root.code);
    try expectRelatedRoots(dead_root, &.{ "r1", "r2", "r3", "r4" });

    const dead_leaf = findMessage(diags, "'deadLeafNeverUsed'") orelse return error.TestExpectedDead;
    try testing.expectEqualStrings("W0002", dead_leaf.code);
    try expectRelatedRoots(dead_leaf, &.{ "r1", "r2", "r3", "r4" });

    const unused_binding = findMessage(diags, "'neverUsedBinding'") orelse return error.TestExpectedBinding;
    try testing.expectEqualStrings("W0003", unused_binding.code);
    try expectRelatedRoots(unused_binding, &.{ "r1", "r2", "r3", "r4" });
}

// =========================================================================
// 2. A fragment only two roots reach reports through those two.
// =========================================================================

test "a fragment reached by two of four roots reports only those roots" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var buffer: [256]u8 = undefined;
    const uri = try fileUri(&buffer, "/ws/partial.wgsl");
    try fixture.handler.openDocument(uri, fixture_partial, 1);

    const diags = try fixture.handler.validatePngineDocument(uri, .{});
    defer Handler.freeDiagnostics(testing.allocator, diags);

    const diag = findMessage(diags, "'partialNeverUsed'") orelse return error.TestExpectedUnused;
    try testing.expectEqualStrings("W0001", diag.code);
    try expectRelatedRoots(diag, &.{ "r3", "r4" });
    try testing.expectEqual(@as(usize, 2), countRelatedRoots(diag));
}

// =========================================================================
// 3. Local style rules fire once per origin, never once per root.
// =========================================================================

test "style findings dedupe to one author-local finding across roots" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.setConfig(
        \\{"rules":{"naming-convention":"warn","no-magic-numbers":"warn"}}
    );

    var buffer: [256]u8 = undefined;
    const uri = try fileUri(&buffer, "/ws/style.wgsl");
    try fixture.handler.openDocument(uri, fixture_style, 1);

    const diags = try fixture.handler.validatePngineDocument(uri, .{});
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 1), countCode(diags, "W0200"));
    try testing.expectEqual(@as(usize, 1), countCode(diags, "W0202"));

    const naming = findMessage(diags, "'Bad_Name'") orelse return error.TestExpectedNaming;
    try testing.expectEqualStrings("W0200", naming.code);
    try expectRelatedRoots(naming, &.{ "r2", "r3" });

    const magic = findMessage(diags, "'42.0'") orelse return error.TestExpectedMagic;
    try testing.expectEqualStrings("W0202", magic.code);
    try expectRelatedRoots(magic, &.{ "r2", "r3" });
}

// =========================================================================
// 4. Module-size findings need one unambiguous root context.
// =========================================================================

const sized_program =
    \\(wgsl :name sizedShared :file "sized_shared.wgsl")
    \\(shader-module :name sizedA :file "sized_a.wgsl" :imports [sizedShared])
    \\(shader-module :name sizedB :file "sized_b.wgsl" :imports [sizedShared])
    \\(shader-module :name sizedRoot :file "sized_root.wgsl")
;

const sized_root =
    \\const SIZED_ROOT_CONST: f32 = 1.0;
    \\@fragment
    \\fn sized_main() -> @location(0) vec4<f32> {
    \\  return vec4<f32>(0.0);
    \\}
;

const sized_shared = "fn sizedHelper() -> f32 { return 1.0; }";

const sized_a =
    \\@fragment
    \\fn a_main() -> @location(0) vec4<f32> {
    \\  return vec4<f32>(0.0);
    \\}
;

const sized_b =
    \\const B_PADDING: f32 = 2.0;
    \\@fragment
    \\fn b_main() -> @location(0) vec4<f32> {
    \\  return vec4<f32>(B_PADDING);
    \\}
;

fn initSized(fake: *FakeProvider, store: *Store, handler: *Handler) !void {
    fake.* = FakeProvider.init(testing.allocator);
    try fake.addFile("/ws/program.sjon", sized_program);
    try fake.addFile("/ws/sized_root.wgsl", sized_root);
    try fake.addFile("/ws/sized_shared.wgsl", sized_shared);
    try fake.addFile("/ws/sized_a.wgsl", sized_a);
    try fake.addFile("/ws/sized_b.wgsl", sized_b);

    store.* = Store.init(testing.allocator, fake.sourceProvider());
    const roots = [_][]const u8{"/ws"};
    try store.setWorkspaceRoots(&roots);
    handler.* = Handler.init(testing.allocator);
    handler.setPngineStore(store);

    handler.project_config.deinit(testing.allocator);
    handler.project_config = try wgslender.Config.parseJson(
        testing.allocator,
        "{\"lsp\":{\"minifyMode\":\"strict\",\"minifyLints\":{\"budgetBytes\":1}}}",
    );
}

test "module-size finding fires on a unique root and honors the minify flag" {
    var fake: FakeProvider = undefined;
    var store: Store = undefined;
    var handler: Handler = undefined;
    try initSized(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();
    defer fake.deinit();

    var buffer: [256]u8 = undefined;
    const uri = try fileUri(&buffer, "/ws/sized_root.wgsl");
    try handler.openDocument(uri, sized_root, 1);

    const estimates_before = wgslender.MinifyEstimator.estimate_count;
    const full = try handler.validateDocumentFull(uri);
    defer Handler.freeDiagnostics(testing.allocator, full);
    try testing.expectEqual(@as(usize, 1), countCode(full, "M0500"));
    const size = findMessage(full, "exceeds configured budget of 1 bytes") orelse
        return error.TestExpectedSizeFinding;
    try testing.expectEqualStrings("M0500", size.code);
    const estimates_after_first = wgslender.MinifyEstimator.estimate_count;
    try testing.expect(estimates_after_first > estimates_before);

    // A repeat full request reuses the root analysis's estimate slot.
    const again = try handler.validateDocumentFull(uri);
    defer Handler.freeDiagnostics(testing.allocator, again);
    try testing.expectEqual(@as(usize, 1), countCode(again, "M0500"));
    try testing.expectEqual(estimates_after_first, wgslender.MinifyEstimator.estimate_count);

    // The cheap path never carries the estimator-backed M-rule.
    const cheap = try handler.validateDocumentCheap(uri);
    defer Handler.freeDiagnostics(testing.allocator, cheap);
    try testing.expectEqual(@as(usize, 0), countCode(cheap, "M0500"));
}

test "module-size finding suppresses when several roots share the part" {
    var fake: FakeProvider = undefined;
    var store: Store = undefined;
    var handler: Handler = undefined;
    try initSized(&fake, &store, &handler);
    defer handler.deinit();
    defer store.deinit();
    defer fake.deinit();

    var buffer: [256]u8 = undefined;
    const uri = try fileUri(&buffer, "/ws/sized_shared.wgsl");
    try handler.openDocument(uri, sized_shared, 1);

    const diags = try handler.validatePngineDocument(uri, .{ .include_minify_lints = true });
    defer Handler.freeDiagnostics(testing.allocator, diags);

    // Lint did run on the assembled unit; only the ambiguous size claim
    // was withheld.
    try testing.expectEqual(@as(usize, 1), countMessage(diags, "'sizedHelper'"));

    // Two roots assemble different modules around the same part. Neither
    // root's byte count is a property of the shared fragment, so the rule
    // must not pick one.
    try testing.expectEqual(@as(usize, 0), countCode(diags, "M0500"));
}

// =========================================================================
// 5. Quick fixes: one author file, no inline part, no conflicting rewrite.
// =========================================================================

test "a lint finding and a validator finding at one range stay distinct" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var buffer: [256]u8 = undefined;
    const uri = try fileUri(&buffer, "/ws/shared.wgsl");
    try fixture.handler.openDocument(uri, fixture_shared, 1);

    var set = try membershipFor(&fixture.store, "/ws/shared.wgsl");
    defer set.deinit(testing.allocator);
    const program_id = set.items[0].program;
    const root = rootByName(&fixture.store, program_id, "r1");
    const analysis = try fixture.handler.analyzeRoot(root);
    const shared_part = partFor(&fixture.store, program_id, "shared");
    const range = assembledRange(analysis.assembled, shared_part, 0, 1);

    var report = PngineDiagnostics.Report.init(testing.allocator, &fixture.store, uri, set.items);
    defer report.deinit();

    const validator_entry = wgslender.Diagnostic.Entry{
        .code = "E0200",
        .message = "validator finding",
        .range = range,
    };
    const lint_entry = wgslender.Diagnostic.Entry{
        .code = "W0216",
        .message = "lint finding",
        .range = range,
    };
    try report.addFromRoot(analysis.assembled, root, &validator_entry);
    try report.addLintFromRoot(analysis.assembled, root, &lint_entry);

    const diags = try report.finish();
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 2), diags.len);
    try testing.expectEqualStrings("E0200", diags[0].code);
    try testing.expectEqualStrings("W0216", diags[1].code);
}

test "a real lint fix survives on a shared fragment at its author range" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var buffer: [256]u8 = undefined;
    const uri = try fileUri(&buffer, "/ws/fixes.wgsl");
    try fixture.handler.openDocument(uri, fixture_fixes, 1);

    const diags = try fixture.handler.validatePngineDocument(uri, .{});
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 1), countCode(diags, "W0214"));
    const fix = findMessage(diags, "assigning a reference to itself") orelse
        return error.TestExpectedSelfAssign;
    try testing.expect(fix.data == .lint_fix);
    try testing.expectEqualStrings("", fix.data.lint_fix.text);
}

test "a fix that leaves the requested file is withheld, the diagnostic stays" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var buffer: [256]u8 = undefined;
    const uri = try fileUri(&buffer, "/ws/shared.wgsl");
    try fixture.handler.openDocument(uri, fixture_shared, 1);

    var set = try membershipFor(&fixture.store, "/ws/shared.wgsl");
    defer set.deinit(testing.allocator);
    const program_id = set.items[0].program;
    const root = rootByName(&fixture.store, program_id, "r3");
    const analysis = try fixture.handler.analyzeRoot(root);

    const shared_part = partFor(&fixture.store, program_id, "shared");
    const partial_part = partFor(&fixture.store, program_id, "partial");
    const primary = assembledRange(analysis.assembled, shared_part, 0, 1);
    const foreign_fix = assembledRange(analysis.assembled, partial_part, 0, 1);

    var report = PngineDiagnostics.Report.init(testing.allocator, &fixture.store, uri, set.items);
    defer report.deinit();

    const fix = wgslender.Diagnostic.Fix{ .range = foreign_fix, .text = "X" };
    const entry = wgslender.Diagnostic.Entry{
        .code = "W0214",
        .message = "cross-part fix",
        .range = primary,
        .fix = &fix,
    };
    try report.addLintFromRoot(analysis.assembled, root, &entry);

    const diags = try report.finish();
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expect(diags[0].data == .none);
    try testing.expectEqualStrings("cross-part fix", diags[0].message);
}

test "a fix into inline code is withheld, the diagnostic stays" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var buffer: [256]u8 = undefined;
    const uri = try fileUri(&buffer, "/ws/shared.wgsl");
    try fixture.handler.openDocument(uri, fixture_shared, 1);

    var set = try membershipFor(&fixture.store, "/ws/shared.wgsl");
    defer set.deinit(testing.allocator);
    const program_id = set.items[0].program;
    const root = rootByName(&fixture.store, program_id, "r1");
    const analysis = try fixture.handler.analyzeRoot(root);

    const shared_part = partFor(&fixture.store, program_id, "shared");
    const inline_part = partFor(&fixture.store, program_id, "inlinepart");
    const primary = assembledRange(analysis.assembled, shared_part, 0, 1);
    const inline_fix = assembledRange(analysis.assembled, inline_part, 0, 1);

    var report = PngineDiagnostics.Report.init(testing.allocator, &fixture.store, uri, set.items);
    defer report.deinit();

    const fix = wgslender.Diagnostic.Fix{ .range = inline_fix, .text = "X" };
    const entry = wgslender.Diagnostic.Entry{
        .code = "W0214",
        .message = "inline fix",
        .range = primary,
        .fix = &fix,
    };
    try report.addLintFromRoot(analysis.assembled, root, &entry);

    const diags = try report.finish();
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expect(diags[0].data == .none);
    try testing.expectEqualStrings("inline fix", diags[0].message);
}

test "conflicting fixes for one range are dropped, the diagnostic remains" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var buffer: [256]u8 = undefined;
    const uri = try fileUri(&buffer, "/ws/shared.wgsl");
    try fixture.handler.openDocument(uri, fixture_shared, 1);

    var set = try membershipFor(&fixture.store, "/ws/shared.wgsl");
    defer set.deinit(testing.allocator);
    const program_id = set.items[0].program;
    const root_a = rootByName(&fixture.store, program_id, "r1");
    const root_b = rootByName(&fixture.store, program_id, "r3");
    const analysis_a = try fixture.handler.analyzeRoot(root_a);
    const analysis_b = try fixture.handler.analyzeRoot(root_b);

    const shared_part = partFor(&fixture.store, program_id, "shared");
    const primary_a = assembledRange(analysis_a.assembled, shared_part, 0, 1);
    const primary_b = assembledRange(analysis_b.assembled, shared_part, 0, 1);
    try testing.expectEqualDeep(primary_a, primary_b);

    var report = PngineDiagnostics.Report.init(testing.allocator, &fixture.store, uri, set.items);
    defer report.deinit();

    const fix_a = wgslender.Diagnostic.Fix{ .range = primary_a, .text = "AAA" };
    const fix_b = wgslender.Diagnostic.Fix{ .range = primary_b, .text = "BBB" };
    const entry_a = wgslender.Diagnostic.Entry{
        .code = "W0214",
        .message = "competing fix",
        .range = primary_a,
        .fix = &fix_a,
    };
    const entry_b = wgslender.Diagnostic.Entry{
        .code = "W0214",
        .message = "competing fix",
        .range = primary_b,
        .fix = &fix_b,
    };
    try report.addLintFromRoot(analysis_a.assembled, root_a, &entry_a);
    try report.addLintFromRoot(analysis_b.assembled, root_b, &entry_b);

    const diags = try report.finish();
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expect(diags[0].data == .none);
}

test "different diagnostics offering different fixes for one range lose both fixes" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var buffer: [256]u8 = undefined;
    const uri = try fileUri(&buffer, "/ws/shared.wgsl");
    try fixture.handler.openDocument(uri, fixture_shared, 1);

    var set = try membershipFor(&fixture.store, "/ws/shared.wgsl");
    defer set.deinit(testing.allocator);
    const program_id = set.items[0].program;
    const root_a = rootByName(&fixture.store, program_id, "r1");
    const root_b = rootByName(&fixture.store, program_id, "r3");
    const analysis_a = try fixture.handler.analyzeRoot(root_a);
    const analysis_b = try fixture.handler.analyzeRoot(root_b);

    const shared_part = partFor(&fixture.store, program_id, "shared");
    const primary_a = assembledRange(analysis_a.assembled, shared_part, 0, 1);
    const primary_b = assembledRange(analysis_b.assembled, shared_part, 0, 1);

    var report = PngineDiagnostics.Report.init(testing.allocator, &fixture.store, uri, set.items);
    defer report.deinit();

    const fix_a = wgslender.Diagnostic.Fix{ .range = primary_a, .text = "AAA" };
    const fix_b = wgslender.Diagnostic.Fix{ .range = primary_b, .text = "BBB" };
    const entry_a = wgslender.Diagnostic.Entry{
        .code = "W0214",
        .message = "first rewrite",
        .range = primary_a,
        .fix = &fix_a,
    };
    const entry_b = wgslender.Diagnostic.Entry{
        .code = "W0216",
        .message = "second rewrite",
        .range = primary_b,
        .fix = &fix_b,
    };
    try report.addLintFromRoot(analysis_a.assembled, root_a, &entry_a);
    try report.addLintFromRoot(analysis_b.assembled, root_b, &entry_b);

    const diags = try report.finish();
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 2), diags.len);
    for (diags) |diag| try testing.expect(diag.data == .none);
}

test "identical fixes for one range from every root may be kept" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var buffer: [256]u8 = undefined;
    const uri = try fileUri(&buffer, "/ws/shared.wgsl");
    try fixture.handler.openDocument(uri, fixture_shared, 1);

    var set = try membershipFor(&fixture.store, "/ws/shared.wgsl");
    defer set.deinit(testing.allocator);
    const program_id = set.items[0].program;
    const root_a = rootByName(&fixture.store, program_id, "r1");
    const root_b = rootByName(&fixture.store, program_id, "r3");
    const analysis_a = try fixture.handler.analyzeRoot(root_a);
    const analysis_b = try fixture.handler.analyzeRoot(root_b);

    const shared_part = partFor(&fixture.store, program_id, "shared");
    const primary_a = assembledRange(analysis_a.assembled, shared_part, 0, 1);
    const primary_b = assembledRange(analysis_b.assembled, shared_part, 0, 1);

    var report = PngineDiagnostics.Report.init(testing.allocator, &fixture.store, uri, set.items);
    defer report.deinit();

    const fix_a = wgslender.Diagnostic.Fix{ .range = primary_a, .text = "SAME" };
    const fix_b = wgslender.Diagnostic.Fix{ .range = primary_b, .text = "SAME" };
    const entry_a = wgslender.Diagnostic.Entry{
        .code = "W0214",
        .message = "agreed fix",
        .range = primary_a,
        .fix = &fix_a,
    };
    const entry_b = wgslender.Diagnostic.Entry{
        .code = "W0214",
        .message = "agreed fix",
        .range = primary_b,
        .fix = &fix_b,
    };
    try report.addLintFromRoot(analysis_a.assembled, root_a, &entry_a);
    try report.addLintFromRoot(analysis_b.assembled, root_b, &entry_b);

    const diags = try report.finish();
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expect(diags[0].data == .lint_fix);
    try testing.expectEqualStrings("SAME", diags[0].data.lint_fix.text);
}

// =========================================================================
// 6. The standalone lint path and its registry are untouched.
// =========================================================================

test "standalone lint path keeps the same rule set and result" {
    try testing.expectEqual(@as(usize, 31), wgslender.Linter.registry.all.len);
    try testing.expectEqual(
        wgslender.Diagnostic.Severity.warning,
        wgslender.Linter.registry.byId("no-unused-vars").?.meta.default_severity,
    );
    try testing.expectEqual(
        wgslender.Diagnostic.Severity.warning,
        wgslender.Linter.registry.byId("no-dead-code").?.meta.default_severity,
    );

    var handler = Handler.init(testing.allocator);
    defer handler.deinit();
    const uri = "test://standalone-lint.wgsl";
    try handler.openDocument(uri, "fn unused_fn() {}", 1);

    const diags = try handler.validateDocumentFull(uri);
    defer Handler.freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqualStrings("W0001", diags[0].code);
    try testing.expectEqualStrings("'unused_fn' is declared but never used", diags[0].message);
    try testing.expectEqual(Handler.DiagnosticSeverity.warning, diags[0].severity);
}
