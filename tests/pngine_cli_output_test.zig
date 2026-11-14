//! Composed CLI validate/lint output (pngine-shaders phase 05, Task 2).
//!
//! The red-first contract:
//!   * a primary diagnostic lands on its own origin file and line/column,
//!     not on the root file named on the command line;
//!   * a shared fragment's root-specific error names the failing root and
//!     validate is invalid when any selected root is invalid;
//!   * unknown imports, cycles, and missing sources surface as P0002 and
//!     exit 1;
//!   * `--strict` escalates warnings, a clean project exits 0;
//!   * quiet hides warnings while `--max-warnings` counts the composed set
//!     once, not once per root;
//!   * fixes operate only on the input part and never print the assembled
//!     module;
//!   * mapped JSON entries carry `file`, `project`, and `root`, and counts
//!     stay consistent with the entries emitted.
//!
//! Every test drives the in-memory `SourceProvider` from
//! `pngine_test_provider.zig`; no test reads project text from disk.

const std = @import("std");
const wgslender = @import("wgslender");
const selection = @import("PngineSelection");
const output = @import("PngineOutput");
const provider_mod = @import("pngine_test_provider.zig");

const pngine = wgslender.Pngine;
const Types = pngine.Types;
const Store = selection.Store;
const FakeProvider = provider_mod.FakeProvider;
const testing = std.testing;

fn findCode(report: *const output.Report, code: []const u8) ?*const pngine.Projection.DiagnosticOut {
    for (report.items()) |*item| {
        if (std.mem.eql(u8, item.code, code)) return item;
    }
    return null;
}

fn countCode(report: *const output.Report, code: []const u8) usize {
    var n: usize = 0;
    for (report.items()) |item| {
        if (std.mem.eql(u8, item.code, code)) n += 1;
    }
    return n;
}

/// One project + store under the in-memory provider. Selection always uses
/// discovery (the same path the CLI takes for a bare file argument).
const File = struct {
    path: []const u8,
    text: []const u8,
};

const Fixture = struct {
    fake: FakeProvider,
    store: Store,

    /// Initialize in place: the fake provider's address is the store's
    /// provider context, so returning a `Fixture` by value would move the
    /// provider out from under the store.
    fn init(self: *Fixture, program: []const u8, files: []const File) !void {
        self.fake = FakeProvider.init(testing.allocator);
        errdefer self.fake.deinit();
        try self.fake.addFile("/ws/program.sjon", program);
        for (files) |file| try self.fake.addFile(file.path, file.text);
        self.store = Store.init(testing.allocator, self.fake.sourceProvider());
    }

    fn deinit(self: *Fixture) void {
        self.store.deinit();
        self.fake.deinit();
    }

    fn select(self: *Fixture, input: []const u8, root: ?[]const u8) !selection.ProjectSelection {
        return selection.selectProjectWithFailure(&self.store, input, null, root, false, null);
    }
};

fn expectTextContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected text to contain '{s}'\n--- text ---\n{s}\n", .{ needle, haystack });
        return error.TestExpectedText;
    }
}

// =========================================================================
// T1 — a fragment body diagnostic keeps its own origin file.
// =========================================================================

test "validate maps a fragment diagnostic to its own origin file" {
    var fixture: Fixture = undefined;
    try fixture.init(
        \\(wgsl :name lib :file "lib.wgsl")
        \\(shader-module :name main :file "root.wgsl" :imports [lib])
    ,
        &.{
            .{ .path = "/ws/lib.wgsl", .text = "fn lib_fn() -> f32 { return missing_value; }" },
            .{ .path = "/ws/root.wgsl", .text = "// root\n" },
        },
    );
    defer fixture.deinit();

    var selected = try fixture.select("/ws/root.wgsl", null);
    defer selected.deinit(testing.allocator);

    var report = try output.run(
        testing.allocator,
        &fixture.store,
        selected.program,
        selected.input_part,
        selected.roots,
        .validate,
        .{ .input_path = "/ws/root.wgsl" },
    );
    defer report.deinit(testing.allocator);

    const item = findCode(&report, "E0100") orelse return error.TestExpectedDiagnostic;
    try testing.expect(item.origin != null);
    try testing.expectEqualStrings("/ws/lib.wgsl", report.originPath(item.origin.?).?);
    try testing.expectEqual(@as(u8, 1), report.exit_code);

    const text = try report.renderText(testing.allocator);
    defer testing.allocator.free(text);
    try expectTextContains(text, "/ws/lib.wgsl:1:");
    // The root file was named on the command line, but it is not the error's
    // origin and must not be used as the prefix.
    try testing.expect(std.mem.indexOf(u8, text, "/ws/root.wgsl:1: error") == null);
    try expectTextContains(text, "missing_value");
}

// =========================================================================
// T2 — a root-specific error in a shared fragment names that root.
// =========================================================================

test "shared fragment root-specific error names the failing root" {
    var fixture: Fixture = undefined;
    try fixture.init(
        \\(wgsl :name shared :file "shared.wgsl")
        \\(shader-module :name withSecret :file "a.wgsl" :imports [shared])
        \\(shader-module :name withoutSecret :file "b.wgsl" :imports [shared])
    ,
        &.{
            .{ .path = "/ws/shared.wgsl", .text = "fn use_value() -> f32 { return secret; }" },
            .{ .path = "/ws/a.wgsl", .text = "const secret: f32 = 1.0;" },
            .{ .path = "/ws/b.wgsl", .text = "// b\n" },
        },
    );
    defer fixture.deinit();

    var selected = try fixture.select("/ws/shared.wgsl", null);
    defer selected.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), selected.roots.len);

    var report = try output.run(
        testing.allocator,
        &fixture.store,
        selected.program,
        selected.input_part,
        selected.roots,
        .validate,
        .{ .input_path = "/ws/shared.wgsl" },
    );
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), countCode(&report, "E0100"));
    const item = findCode(&report, "E0100").?;
    try testing.expect(std.mem.endsWith(u8, item.message, " — declared nowhere in pngine module 'withoutSecret'"));
    try testing.expect(std.mem.indexOf(u8, item.message, "withSecret") == null);
    try testing.expectEqual(@as(u8, 1), report.exit_code);

    const text = try report.renderText(testing.allocator);
    defer testing.allocator.free(text);
    try expectTextContains(text, "declared nowhere in pngine module 'withoutSecret'");
    try expectTextContains(text, "/ws/program.sjon:");
    try expectTextContains(text, "root 'withoutSecret'");
}

test "validate is valid only when every selected root is valid" {
    var fixture: Fixture = undefined;
    try fixture.init(
        \\(wgsl :name shared :file "shared.wgsl")
        \\(wgsl :name broken :file "broken.wgsl")
        \\(shader-module :name cleanRoot :file "clean.wgsl" :imports [shared])
        \\(shader-module :name brokenRoot :file "broken_root.wgsl" :imports [shared broken])
    ,
        &.{
            .{ .path = "/ws/shared.wgsl", .text = "fn shared_fn() -> f32 { return 1.0; }" },
            .{ .path = "/ws/broken.wgsl", .text = "fn broken_fn() -> f32 { return nope; }" },
            .{ .path = "/ws/clean.wgsl", .text = "// clean\n" },
            .{ .path = "/ws/broken_root.wgsl", .text = "// broken root\n" },
        },
    );
    defer fixture.deinit();

    var selected = try fixture.select("/ws/shared.wgsl", null);
    defer selected.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), selected.roots.len);

    var report = try output.run(
        testing.allocator,
        &fixture.store,
        selected.program,
        selected.input_part,
        selected.roots,
        .validate,
        .{ .input_path = "/ws/shared.wgsl" },
    );
    defer report.deinit(testing.allocator);

    const item = findCode(&report, "E0100") orelse return error.TestExpectedDiagnostic;
    // The shared input has no error of its own; the invalid root's sibling
    // file does, and that keeps the whole composed validate invalid.
    try testing.expectEqualStrings("/ws/broken.wgsl", report.originPath(item.origin.?).?);
    try testing.expectEqual(@as(u8, 1), report.exit_code);
}

// =========================================================================
// T3 — graph errors are P0002 with the edge/path, and exit 1.
// =========================================================================

test "unknown import prints P0002 and exits 1" {
    var fixture: Fixture = undefined;
    try fixture.init(
        \\(wgsl :name lib :file "lib.wgsl")
        \\(shader-module :name main :file "root.wgsl" :imports [lib nope])
    ,
        &.{
            .{ .path = "/ws/lib.wgsl", .text = "fn lib_fn() {}" },
            .{ .path = "/ws/root.wgsl", .text = "// root\n" },
        },
    );
    defer fixture.deinit();

    var selected = try fixture.select("/ws/root.wgsl", null);
    defer selected.deinit(testing.allocator);
    var report = try output.run(
        testing.allocator,
        &fixture.store,
        selected.program,
        selected.input_part,
        selected.roots,
        .validate,
        .{ .input_path = "/ws/root.wgsl" },
    );
    defer report.deinit(testing.allocator);

    const item = findCode(&report, "P0002") orelse return error.TestExpectedDiagnostic;
    try expectTextContains(item.message, "unknown import 'nope'");
    try expectTextContains(item.message, "'main'");
    try testing.expectEqual(@as(u8, 1), report.exit_code);

    const text = try report.renderText(testing.allocator);
    defer testing.allocator.free(text);
    try expectTextContains(text, "P0002");
    try expectTextContains(text, "unknown import 'nope'");
}

test "import cycle prints P0002 with the ordered cycle path" {
    var fixture: Fixture = undefined;
    try fixture.init(
        \\(wgsl :name cyc_a :file "cyc_a.wgsl" :imports [cyc_b])
        \\(wgsl :name cyc_b :file "cyc_b.wgsl" :imports [cyc_a])
        \\(shader-module :name main :file "root.wgsl" :imports [cyc_a])
    ,
        &.{
            .{ .path = "/ws/cyc_a.wgsl", .text = "fn a() {}" },
            .{ .path = "/ws/cyc_b.wgsl", .text = "fn b() {}" },
            .{ .path = "/ws/root.wgsl", .text = "// root\n" },
        },
    );
    defer fixture.deinit();

    var selected = try fixture.select("/ws/root.wgsl", null);
    defer selected.deinit(testing.allocator);
    var report = try output.run(
        testing.allocator,
        &fixture.store,
        selected.program,
        selected.input_part,
        selected.roots,
        .validate,
        .{ .input_path = "/ws/root.wgsl" },
    );
    defer report.deinit(testing.allocator);

    const item = findCode(&report, "P0002") orelse return error.TestExpectedDiagnostic;
    try expectTextContains(item.message, "import cycle");
    try expectTextContains(item.message, "cyc_a -> cyc_b -> cyc_a");
    try testing.expectEqual(@as(u8, 1), report.exit_code);

    const text = try report.renderText(testing.allocator);
    defer testing.allocator.free(text);
    try expectTextContains(text, "cyc_a -> cyc_b -> cyc_a");
}

test "missing source prints P0002 naming the part and file" {
    var fixture: Fixture = undefined;
    try fixture.init(
        \\(wgsl :name ghost :file "ghost.wgsl")
        \\(shader-module :name main :file "root.wgsl" :imports [ghost])
    ,
        &.{
            .{ .path = "/ws/root.wgsl", .text = "// root\n" },
        },
    );
    defer fixture.deinit();

    var selected = try fixture.select("/ws/root.wgsl", null);
    defer selected.deinit(testing.allocator);
    var report = try output.run(
        testing.allocator,
        &fixture.store,
        selected.program,
        selected.input_part,
        selected.roots,
        .validate,
        .{ .input_path = "/ws/root.wgsl" },
    );
    defer report.deinit(testing.allocator);

    const item = findCode(&report, "P0002") orelse return error.TestExpectedDiagnostic;
    try expectTextContains(item.message, "missing source");
    try expectTextContains(item.message, "'ghost'");
    try expectTextContains(item.message, "ghost.wgsl");
    try testing.expectEqual(@as(u8, 1), report.exit_code);
}

// =========================================================================
// T4 — strict mode and the clean-project exit.
// =========================================================================

const warning_program =
    \\(shader-module :name main :file "root.wgsl")
;
const warning_root =
    \\fn f() -> i32 {
    \\  return 1;
    \\  let dead = 2;
    \\  return dead;
    \\}
;

test "strict mode escalates warnings; clean projects exit 0" {
    var fixture: Fixture = undefined;
    try fixture.init(warning_program, &.{
        .{ .path = "/ws/root.wgsl", .text = warning_root },
    });
    defer fixture.deinit();

    var selected = try fixture.select("/ws/root.wgsl", null);
    defer selected.deinit(testing.allocator);

    var loose = try output.run(
        testing.allocator,
        &fixture.store,
        selected.program,
        selected.input_part,
        selected.roots,
        .validate,
        .{ .input_path = "/ws/root.wgsl", .strict = false },
    );
    defer loose.deinit(testing.allocator);
    try testing.expect(loose.warning_count > 0);
    try testing.expectEqual(@as(u8, 0), loose.exit_code);

    var strict = try output.run(
        testing.allocator,
        &fixture.store,
        selected.program,
        selected.input_part,
        selected.roots,
        .validate,
        .{ .input_path = "/ws/root.wgsl", .strict = true },
    );
    defer strict.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 1), strict.exit_code);

    var clean_fixture: Fixture = undefined;
    try clean_fixture.init(
        \\(shader-module :name main :file "clean.wgsl")
    ,
        &.{.{ .path = "/ws/clean.wgsl", .text = "fn main() {}" }},
    );
    defer clean_fixture.deinit();
    var clean_selected = try clean_fixture.select("/ws/clean.wgsl", null);
    defer clean_selected.deinit(testing.allocator);
    var clean = try output.run(
        testing.allocator,
        &clean_fixture.store,
        clean_selected.program,
        clean_selected.input_part,
        clean_selected.roots,
        .validate,
        .{ .input_path = "/ws/clean.wgsl", .strict = true },
    );
    defer clean.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), clean.items().len);
    try testing.expectEqual(@as(u8, 0), clean.exit_code);
}

// =========================================================================
// T5 — quiet and max-warnings over the composed set.
// =========================================================================

test "quiet suppresses warnings and max-warnings counts once per composed finding" {
    var fixture: Fixture = undefined;
    try fixture.init(
        \\(wgsl :name shared :file "shared.wgsl")
        \\(shader-module :name r1 :file "r1.wgsl" :imports [shared])
        \\(shader-module :name r2 :file "r2.wgsl" :imports [shared])
        \\(shader-module :name r3 :file "r3.wgsl" :imports [shared])
        \\(shader-module :name r4 :file "r4.wgsl" :imports [shared])
    ,
        &.{
            .{ .path = "/ws/shared.wgsl", .text = "fn never_used() -> f32 { return 1.0; }" },
            .{ .path = "/ws/r1.wgsl", .text = "// r1\n" },
            .{ .path = "/ws/r2.wgsl", .text = "// r2\n" },
            .{ .path = "/ws/r3.wgsl", .text = "// r3\n" },
            .{ .path = "/ws/r4.wgsl", .text = "// r4\n" },
        },
    );
    defer fixture.deinit();

    var selected = try fixture.select("/ws/shared.wgsl", null);
    defer selected.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), selected.roots.len);

    const lint_config = output.Config{
        .input_path = "/ws/shared.wgsl",
        .lint_extends = &.{"@wgslender/recommended"},
    };

    var relaxed = try output.run(
        testing.allocator,
        &fixture.store,
        selected.program,
        selected.input_part,
        selected.roots,
        .lint,
        lint_config,
    );
    defer relaxed.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), relaxed.error_count);
    try testing.expectEqual(@as(u32, 1), relaxed.warning_count);
    try testing.expectEqual(@as(usize, 1), countCode(&relaxed, "W0001"));

    var threshold = try output.run(
        testing.allocator,
        &fixture.store,
        selected.program,
        selected.input_part,
        selected.roots,
        .lint,
        .{ .input_path = "/ws/shared.wgsl", .lint_extends = &.{"@wgslender/recommended"}, .max_warnings = 1 },
    );
    defer threshold.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), threshold.exit_code);

    var over = try output.run(
        testing.allocator,
        &fixture.store,
        selected.program,
        selected.input_part,
        selected.roots,
        .lint,
        .{ .input_path = "/ws/shared.wgsl", .lint_extends = &.{"@wgslender/recommended"}, .max_warnings = 0 },
    );
    defer over.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 1), over.exit_code);

    const loud = try relaxed.renderText(testing.allocator);
    defer testing.allocator.free(loud);
    try expectTextContains(loud, "W0001");

    var quiet = try output.run(
        testing.allocator,
        &fixture.store,
        selected.program,
        selected.input_part,
        selected.roots,
        .lint,
        .{ .input_path = "/ws/shared.wgsl", .lint_extends = &.{"@wgslender/recommended"}, .quiet = true },
    );
    defer quiet.deinit(testing.allocator);
    const quiet_text = try quiet.renderText(testing.allocator);
    defer testing.allocator.free(quiet_text);
    try testing.expect(std.mem.indexOf(u8, quiet_text, "W0001") == null);
}

// =========================================================================
// T6 — fixes touch the input part only, never the assembled module.
// =========================================================================

const fix_shared =
    \\fn fix_target() -> f32 {
    \\  var x = 1.0;
    \\  x = x;
    \\  return x;
    \\}
;

test "fix dry-run fixes the input part and never prints the assembled module" {
    var fixture: Fixture = undefined;
    try fixture.init(
        \\(wgsl :name shared :file "shared.wgsl")
        \\(shader-module :name main :file "root.wgsl" :imports [shared])
    ,
        &.{
            .{ .path = "/ws/shared.wgsl", .text = fix_shared },
            .{ .path = "/ws/root.wgsl", .text = "// ROOT_MARKER\n" },
        },
    );
    defer fixture.deinit();

    var selected = try fixture.select("/ws/shared.wgsl", null);
    defer selected.deinit(testing.allocator);
    var report = try output.run(
        testing.allocator,
        &fixture.store,
        selected.program,
        selected.input_part,
        selected.roots,
        .lint,
        .{ .input_path = "/ws/shared.wgsl", .lint_extends = &.{"@wgslender/recommended"} },
    );
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), report.fixable_count);
    const fixed = (try report.fixedInput(testing.allocator)) orelse return error.TestExpectedInputText;
    defer testing.allocator.free(fixed);
    try testing.expect(std.mem.indexOf(u8, fixed, "x = x;") == null);
    try testing.expect(std.mem.indexOf(u8, fixed, "ROOT_MARKER") == null);
    try expectTextContains(fixed, "fn fix_target()");
}

test "fixedInput never applies a fix that belongs to another part" {
    var fixture: Fixture = undefined;
    try fixture.init(
        \\(wgsl :name shared :file "shared.wgsl")
        \\(shader-module :name main :file "root.wgsl" :imports [shared])
    ,
        &.{
            .{ .path = "/ws/shared.wgsl", .text = fix_shared },
            .{ .path = "/ws/root.wgsl", .text = "// ROOT_MARKER\n" },
        },
    );
    defer fixture.deinit();

    // The fixable lint finding lives in `shared.wgsl`, but the input part is
    // the root; fixing must leave the root bytes untouched.
    var selected = try fixture.select("/ws/root.wgsl", null);
    defer selected.deinit(testing.allocator);
    var report = try output.run(
        testing.allocator,
        &fixture.store,
        selected.program,
        selected.input_part,
        selected.roots,
        .lint,
        .{ .input_path = "/ws/root.wgsl", .lint_extends = &.{"@wgslender/recommended"} },
    );
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), report.fixable_count);
    const fixed = (try report.fixedInput(testing.allocator)) orelse return error.TestExpectedInputText;
    defer testing.allocator.free(fixed);
    try testing.expectEqualStrings("// ROOT_MARKER\n", fixed);
}

// =========================================================================
// T7 — mapped JSON fields and count consistency.
// =========================================================================

test "validate JSON carries file/project/root on mapped entries" {
    var fixture: Fixture = undefined;
    try fixture.init(
        \\(wgsl :name lib :file "lib.wgsl")
        \\(shader-module :name main :file "root.wgsl" :imports [lib])
    ,
        &.{
            .{ .path = "/ws/lib.wgsl", .text = "fn lib_fn() -> f32 { return missing_value; }" },
            .{ .path = "/ws/root.wgsl", .text = "// root\n" },
        },
    );
    defer fixture.deinit();

    var selected = try fixture.select("/ws/root.wgsl", null);
    defer selected.deinit(testing.allocator);
    var report = try output.run(
        testing.allocator,
        &fixture.store,
        selected.program,
        selected.input_part,
        selected.roots,
        .validate,
        .{ .input_path = "/ws/root.wgsl" },
    );
    defer report.deinit(testing.allocator);

    const json = try report.renderValidateJson(testing.allocator);
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqual(false, root.get("valid").?.bool);

    var error_count: u32 = 0;
    var warning_count: u32 = 0;
    for (root.get("diagnostics").?.array.items) |diag_value| {
        const diag = diag_value.object;
        const severity = diag.get("severity").?.string;
        if (std.mem.eql(u8, severity, "error")) error_count += 1;
        if (std.mem.eql(u8, severity, "warning")) warning_count += 1;
        if (std.mem.eql(u8, diag.get("code").?.string, "E0100")) {
            try testing.expectEqualStrings("/ws/lib.wgsl", diag.get("file").?.string);
            try testing.expectEqualStrings("/ws/program.sjon", diag.get("project").?.string);
            try testing.expectEqualStrings("main", diag.get("root").?.string);
        }
    }
    try testing.expectEqual(error_count, @as(u32, @intCast(root.get("errorCount").?.integer)));
    try testing.expectEqual(warning_count, @as(u32, @intCast(root.get("warningCount").?.integer)));
}

test "lint JSON groups by origin and keeps totals equal to emitted entries" {
    var fixture: Fixture = undefined;
    try fixture.init(
        \\(wgsl :name shared :file "shared.wgsl")
        \\(shader-module :name left :file "left.wgsl" :imports [shared])
        \\(shader-module :name right :file "right.wgsl" :imports [shared])
    ,
        &.{
            .{ .path = "/ws/shared.wgsl", .text = "fn never_used() -> f32 { return 1.0; }" },
            .{ .path = "/ws/left.wgsl", .text = "// left\n" },
            .{ .path = "/ws/right.wgsl", .text = "// right\n" },
        },
    );
    defer fixture.deinit();

    var selected = try fixture.select("/ws/shared.wgsl", null);
    defer selected.deinit(testing.allocator);
    var report = try output.run(
        testing.allocator,
        &fixture.store,
        selected.program,
        selected.input_part,
        selected.roots,
        .lint,
        .{ .input_path = "/ws/shared.wgsl", .lint_extends = &.{"@wgslender/recommended"} },
    );
    defer report.deinit(testing.allocator);

    const json = try report.renderLintJson(testing.allocator);
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    var total_errors: u32 = 0;
    var total_warnings: u32 = 0;
    for (root.get("results").?.array.items) |result_value| {
        const result = result_value.object;
        var result_errors: u32 = 0;
        var result_warnings: u32 = 0;
        for (result.get("diagnostics").?.array.items) |diag_value| {
            const diag = diag_value.object;
            const severity = diag.get("severity").?.string;
            if (std.mem.eql(u8, severity, "error")) result_errors += 1;
            if (std.mem.eql(u8, severity, "warning")) result_warnings += 1;
            if (diag.get("file")) |file_value| {
                try testing.expectEqualStrings("/ws/shared.wgsl", file_value.string);
                try testing.expectEqualStrings("/ws/program.sjon", diag.get("project").?.string);
                try testing.expectEqualStrings("left", diag.get("root").?.string);
            }
        }
        try testing.expectEqual(result_errors, @as(u32, @intCast(result.get("errorCount").?.integer)));
        try testing.expectEqual(result_warnings, @as(u32, @intCast(result.get("warningCount").?.integer)));
        total_errors += result_errors;
        total_warnings += result_warnings;
    }
    try testing.expectEqual(total_errors, @as(u32, @intCast(root.get("errorCount").?.integer)));
    try testing.expectEqual(total_warnings, @as(u32, @intCast(root.get("warningCount").?.integer)));
    try testing.expectEqual(@as(u32, 0), total_errors);
    try testing.expectEqual(@as(u32, 1), total_warnings);
}
