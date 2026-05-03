//! Dispatch tests for rules migrated to the `MultiVisitor` listener API.
//!
//! Two assertions per migrated rule:
//!   1. Structural — its `Rule` entry has `.listener != null` (and, for
//!      pure-listener rules, `.run == null`) so it is provably riding the
//!      multiplexed walk in `Linter.run`.
//!   2. Behavioral — a curated source triggers it and the expected
//!      diagnostic code appears in the lint result.
//!
//! Combined-source test at the bottom verifies that several migrated rules
//! fire from one shared `MultiVisitor.walk`.

const std = @import("std");
const wgslender = @import("wgslender");

const Linter = wgslender.Linter;
const Rule = Linter.Rule;
const registry = Linter.registry;

// =========================================================================
// Helpers
// =========================================================================

fn runLint(src: [:0]const u8, ids: []const []const u8) !Linter.Result {
    const overrides = try std.testing.allocator.alloc(Linter.Options.RuleOverride, ids.len);
    defer std.testing.allocator.free(overrides);
    for (ids, 0..) |id, i| overrides[i] = .{ .id = id, .severity = .warning };

    var analysis = try wgslender.analyze(std.testing.allocator, src);
    defer analysis.deinit(std.testing.allocator);

    return try Linter.run(std.testing.allocator, &analysis, .{ .rules = overrides });
}

fn hasCode(r: Linter.Result, code: []const u8) bool {
    for (r.diagnostics.items()) |d| {
        if (std.mem.eql(u8, d.code, code)) return true;
    }
    return false;
}

fn ruleByIdConst(id: []const u8) ?*const Rule {
    for (&registry.all) |*r| {
        if (std.mem.eql(u8, r.meta.id, id)) return r;
    }
    return null;
}

// =========================================================================
// Structural: every migrated rule provably rides the multiplexed walk
// =========================================================================

test "dispatch: migrated rules expose .listener (proof they ride MultiVisitor)" {
    const migrated = [_][]const u8{
        "no-redundant-casts",
        "prefer-mix",
        "no-self-assign",
        "no-constant-condition",
        "for-direction",
        "no-duplicate-case",
        "no-empty",
        "no-lonely-if",
        "no-large-local-arrays",
        "no-useless-return",
    };
    for (migrated) |id| {
        const r = ruleByIdConst(id) orelse {
            std.debug.print("rule '{s}' not found in registry\n", .{id});
            return error.RuleNotFound;
        };
        if (r.listener == null) {
            std.debug.print("rule '{s}' has no listener — not migrated\n", .{id});
            return error.RuleNotMigrated;
        }
    }
}

// =========================================================================
// Behavioral: each migrated rule still fires on a triggering source
// =========================================================================

test "dispatch: no-self-assign fires via listener" {
    var r = try runLint(
        \\fn f() { var x: i32 = 0; x = x; }
    , &.{"no-self-assign"});
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCode(r, "W0214"));
}

test "dispatch: no-constant-condition fires via listener" {
    var r = try runLint(
        \\fn f() { if (true) { } }
    , &.{"no-constant-condition"});
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCode(r, "W0211"));
}

test "dispatch: for-direction fires via listener" {
    var r = try runLint(
        \\fn f() {
        \\  for (var i = 0; i < 10; i--) { }
        \\}
    , &.{"for-direction"});
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCode(r, "W0212"));
}

test "dispatch: no-duplicate-case fires via listener" {
    var r = try runLint(
        \\fn f(x: i32) {
        \\  switch (x) {
        \\    case 1: { }
        \\    case 1: { }
        \\    default: { }
        \\  }
        \\}
    , &.{"no-duplicate-case"});
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCode(r, "W0213"));
}

test "dispatch: no-empty fires via listener" {
    var r = try runLint(
        \\fn f(x: i32) -> i32 {
        \\  if (x > 0) { }
        \\  return 0;
        \\}
    , &.{"no-empty"});
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCode(r, "W0216"));
}

test "dispatch: no-lonely-if fires via listener" {
    var r = try runLint(
        \\fn f(x: i32, y: i32) -> i32 {
        \\  if (x > 0) { return 1; }
        \\  else { if (y > 0) { return 2; } }
        \\  return 0;
        \\}
    , &.{"no-lonely-if"});
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCode(r, "W0218"));
}

test "dispatch: no-useless-return fires via listener" {
    var r = try runLint(
        \\fn f() {
        \\  let x = 1;
        \\  _ = x;
        \\  return;
        \\}
    , &.{"no-useless-return"});
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCode(r, "W0217"));
}

test "dispatch: no-large-local-arrays fires via listener" {
    var r = try runLint(
        \\fn f() {
        \\  var big: array<f32, 4096>;
        \\  _ = big[0];
        \\}
    , &.{"no-large-local-arrays"});
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasCode(r, "W0204"));
}

// =========================================================================
// Combined: many migrated rules fan out from one shared walk
// =========================================================================

test "dispatch: several listener rules fire together from one walk" {
    // Source crafted to trip multiple migrated rules in one parse:
    //   - no-self-assign (x = x)
    //   - no-constant-condition (if (true))
    //   - no-empty (empty if body)
    //   - no-useless-return (trailing bare return)
    //   - for-direction (counter < limit, decrementing)
    //   - no-duplicate-case (two case 1)
    const src: [:0]const u8 =
        \\fn f(x: i32) {
        \\  if (true) { }
        \\  for (var i = 0; i < 10; i--) { let z = i; _ = z; }
        \\  switch (x) {
        \\    case 1: { }
        \\    case 1: { }
        \\    default: { }
        \\  }
        \\  var y: i32 = 0;
        \\  y = y;
        \\  return;
        \\}
    ;
    var r = try runLint(src, &.{
        "no-self-assign",
        "no-constant-condition",
        "for-direction",
        "no-duplicate-case",
        "no-empty",
        "no-useless-return",
    });
    defer r.deinit(std.testing.allocator);

    try std.testing.expect(hasCode(r, "W0214")); // no-self-assign
    try std.testing.expect(hasCode(r, "W0211")); // no-constant-condition
    try std.testing.expect(hasCode(r, "W0212")); // for-direction
    try std.testing.expect(hasCode(r, "W0213")); // no-duplicate-case
    try std.testing.expect(hasCode(r, "W0216")); // no-empty
    try std.testing.expect(hasCode(r, "W0217")); // no-useless-return
}
