//! Unit tests for the CLI shell logic relocated into `src/` (Block 3.4):
//! minify-cluster precedence (`OptionsSpec.applyMinifyPrecedence`), the
//! source-map flag fold (`OptionsSpec.applySourceMapFlags`), and the lint
//! config/CLI merge (`Config.mergeLintOptions`). These used to live as
//! private helpers in `cli/main.zig` and were untestable without a full arg
//! parse; housed in `src/` they are exercised directly here.

const std = @import("std");
const wgslender = @import("wgslender");
const OptionsSpec = wgslender.OptionsSpec;
const Config = wgslender.Config;
const Minifier = wgslender.Minifier;
const Linter = wgslender.Linter;
const testing = std.testing;

// --- applyMinifyPrecedence ---------------------------------------------------

const MinifyCase = struct {
    name: []const u8,
    flags: OptionsSpec.MinifyClusterFlags,
    // Starting state (defaults: all passes on, matching Minifier.defaultOptions).
    start: [3]bool = .{ true, true, true },
    // Expected {whitespace, identifiers, syntax}.
    want: [3]bool,
};

const minify_cases = [_]MinifyCase{
    .{
        .name = "no flags leaves the starting state untouched",
        .flags = .{},
        .want = .{ true, true, true },
    },
    .{
        .name = "--minify forces all three on from an off start",
        .flags = .{ .all = true },
        .start = .{ false, false, false },
        .want = .{ true, true, true },
    },
    .{
        .name = "a single granular flag resets the unspecified passes off",
        .flags = .{ .whitespace = true },
        .want = .{ true, false, false },
    },
    .{
        .name = "granular flags set each pass independently",
        .flags = .{ .whitespace = true, .identifiers = false, .syntax = true },
        .want = .{ true, false, true },
    },
    .{
        .name = "--minify overrides granular flags (higher priority)",
        .flags = .{ .whitespace = false, .all = true },
        .want = .{ true, true, true },
    },
    .{
        .name = "--no-mangle turns identifiers off as the final word",
        .flags = .{ .all = true, .no_mangle = true },
        .start = .{ false, false, false },
        .want = .{ true, false, true },
    },
    .{
        .name = "--no-whitespace / --no-syntax win over --minify",
        .flags = .{ .all = true, .no_whitespace = true, .no_syntax = true },
        .want = .{ false, true, false },
    },
    .{
        .name = "--no-* beats a granular enable of the same pass",
        .flags = .{ .whitespace = true, .no_whitespace = true },
        .want = .{ false, false, false },
    },
};

test "applyMinifyPrecedence resolves the cluster with correct precedence" {
    for (minify_cases) |c| {
        var opts = Minifier.defaultOptions();
        opts.minify_whitespace = c.start[0];
        opts.minify_identifiers = c.start[1];
        opts.minify_syntax = c.start[2];
        OptionsSpec.applyMinifyPrecedence(&opts, c.flags);
        testing.expectEqual(c.want[0], opts.minify_whitespace) catch |e| {
            std.debug.print("\ncase '{s}': whitespace mismatch\n", .{c.name});
            return e;
        };
        testing.expectEqual(c.want[1], opts.minify_identifiers) catch |e| {
            std.debug.print("\ncase '{s}': identifiers mismatch\n", .{c.name});
            return e;
        };
        testing.expectEqual(c.want[2], opts.minify_syntax) catch |e| {
            std.debug.print("\ncase '{s}': syntax mismatch\n", .{c.name});
            return e;
        };
    }
}

// --- applySourceMapFlags -----------------------------------------------------

test "applySourceMapFlags: no toggles → no map, options untouched" {
    var opts = Minifier.defaultOptions();
    const generate = OptionsSpec.applySourceMapFlags(&opts, false, false, true);
    try testing.expect(!generate);
    try testing.expect(!opts.generate_source_map);
    try testing.expect(!opts.source_map_options.include_source);
}

test "applySourceMapFlags: --source-map enables generation" {
    var opts = Minifier.defaultOptions();
    const generate = OptionsSpec.applySourceMapFlags(&opts, true, false, false);
    try testing.expect(generate);
    try testing.expect(opts.generate_source_map);
    try testing.expect(!opts.source_map_options.include_source);
}

test "applySourceMapFlags: inline alone still generates; sources sets include_source" {
    var opts = Minifier.defaultOptions();
    const generate = OptionsSpec.applySourceMapFlags(&opts, false, true, true);
    try testing.expect(generate);
    try testing.expect(opts.generate_source_map);
    try testing.expect(opts.source_map_options.include_source);
}

// --- Config.mergeLintOptions -------------------------------------------------

fn ov(id: []const u8, sev: wgslender.Diagnostic.Severity) Linter.Options.RuleOverride {
    return .{ .id = id, .severity = sev };
}

test "mergeLintOptions: no config, no CLI → seeds @wgslender/recommended" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const merged = try Config.mergeLintOptions(arena.allocator(), null, &.{}, &.{}, false, true);
    try testing.expectEqual(@as(usize, 1), merged.extends.len);
    try testing.expectEqualStrings("@wgslender/recommended", merged.extends[0]);
    try testing.expectEqual(@as(usize, 0), merged.rules.len);
    try testing.expect(!merged.report_unused_disable_directives);
}

test "mergeLintOptions: --no-recommended with no extends leaves the list empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const merged = try Config.mergeLintOptions(arena.allocator(), null, &.{}, &.{}, false, false);
    try testing.expectEqual(@as(usize, 0), merged.extends.len);
}

test "mergeLintOptions: config extends come before CLI extends, no recommended seed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg: Config = .{ .lint_extends = &.{"@wgslender/style"} };
    const cli_extends = [_][]const u8{"@wgslender/strict"};
    const merged = try Config.mergeLintOptions(arena.allocator(), cfg, &cli_extends, &.{}, false, true);
    try testing.expectEqual(@as(usize, 2), merged.extends.len);
    try testing.expectEqualStrings("@wgslender/style", merged.extends[0]);
    try testing.expectEqualStrings("@wgslender/strict", merged.extends[1]);
}

test "mergeLintOptions: config rules precede CLI rules so CLI wins on conflict" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg: Config = .{ .lint_rules = &.{ov("no-magic-numbers", .warning)} };
    const cli_rules = [_]Linter.Options.RuleOverride{ov("no-magic-numbers", .@"error")};
    const merged = try Config.mergeLintOptions(arena.allocator(), cfg, &.{}, &cli_rules, false, true);
    try testing.expectEqual(@as(usize, 2), merged.rules.len);
    try testing.expectEqual(wgslender.Diagnostic.Severity.warning, merged.rules[0].severity);
    try testing.expectEqual(wgslender.Diagnostic.Severity.@"error", merged.rules[1].severity);
}

test "mergeLintOptions: report_unused — CLI true wins; else config; else false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // CLI true wins even when config says false.
    const cfg_false: Config = .{ .report_unused_disable_directives = false };
    const a = try Config.mergeLintOptions(alloc, cfg_false, &.{}, &.{}, true, true);
    try testing.expect(a.report_unused_disable_directives);

    // Config true applies when CLI didn't ask.
    const cfg_true: Config = .{ .report_unused_disable_directives = true };
    const b = try Config.mergeLintOptions(alloc, cfg_true, &.{}, &.{}, false, true);
    try testing.expect(b.report_unused_disable_directives);

    // Neither set → false.
    const c = try Config.mergeLintOptions(alloc, null, &.{}, &.{}, false, true);
    try testing.expect(!c.report_unused_disable_directives);
}
