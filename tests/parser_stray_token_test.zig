//! Module-scope stray-token recovery.
//!
//! WGSL's module scope admits only directives and global declarations. A token
//! that can start neither is an error — but the parser still has to consume it,
//! because the CST is lossless and every byte of source must land somewhere.
//! Consuming it *silently* is what these tests guard against: before this was
//! pinned, arbitrary non-WGSL (`export default "..."` — the JS wrapper Vite
//! hands a plugin for a `?raw` import, a stray HTML page, plain prose) parsed
//! with zero diagnostics and minified to the empty string, so a build pipeline
//! fed the wrong bytes shipped an empty shader and reported success.

const std = @import("std");
const wgslender = @import("wgslender");
const Cst = wgslender.Cst;
const Incremental = wgslender.Incremental;

/// Minifies `source` and returns the result, asserting nothing about validity.
fn minifyRaw(arena: std.mem.Allocator, source: [:0]const u8) !wgslender.Minifier.Result {
    return wgslender.minifyWithOptions(arena, source, .{});
}

fn hasCode(result: wgslender.Validator.Result, code: []const u8) bool {
    for (result.diagnostics.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, code)) return true;
    }
    return false;
}

// =========================================================================
// Non-WGSL input must not be accepted silently
// =========================================================================

test "stray tokens: non-WGSL input reports an error instead of minifying to nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cases = [_][:0]const u8{
        // The JS wrapper Vite produces for `import x from './s.wgsl?raw'`.
        \\export default "fn f() {}"
        ,
        "this is not wgsl at all",
        "<!doctype html><p>hi</p>",
        "hello",
        "hello;",
    };

    for (cases) |source| {
        const result = try minifyRaw(arena.allocator(), source);
        if (result.errors.len == 0) {
            std.debug.print(
                "accepted non-WGSL silently: {s}\n  -> code: \"{s}\"\n",
                .{ source, result.code },
            );
            return error.NonWgslAcceptedSilently;
        }
    }
}

test "stray tokens: validator rejects non-WGSL with E0001" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try wgslender.validateWithOptions(arena.allocator(),
        \\export default "fn f() {}"
    , .{});
    try std.testing.expect(!result.valid);
    try std.testing.expect(hasCode(result, wgslender.Diagnostic.Code.unexpected_token));
}

// =========================================================================
// One diagnostic per run, not one per token
// =========================================================================

test "stray tokens: a contiguous run collapses to a single diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Eight stray tokens in a row. Reporting each one would bury the real
    // signal under a cascade, which is the reason the recovery path stayed
    // silent in the first place.
    const result = try wgslender.validateWithOptions(arena.allocator(),
        "one two three four five six seven eight", .{});

    var count: usize = 0;
    for (result.diagnostics.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, wgslender.Diagnostic.Code.unexpected_token)) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "stray tokens: separate runs are reported separately" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Two runs, split by a well-formed declaration in between.
    const result = try wgslender.validateWithOptions(arena.allocator(),
        \\garbage here
        \\fn f() -> f32 { return 1.0; }
        \\more garbage
    , .{});

    var count: usize = 0;
    for (result.diagnostics.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, wgslender.Diagnostic.Code.unexpected_token)) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

// =========================================================================
// Valid WGSL stays clean
// =========================================================================

test "stray tokens: well-formed modules gain no diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try wgslender.validateWithOptions(arena.allocator(),
        \\enable f16;
        \\const K: f32 = 2.0;
        \\alias F = f32;
        \\struct S { x: f32 }
        \\@group(0) @binding(0) var<uniform> u: S;
        \\const_assert K > 1.0;
        \\fn helper(v: F) -> f32 { return v * u.x; }
        \\@fragment fn fs() -> @location(0) vec4f {
        \\  return vec4f(helper(K), 0.0, 0.0, 1.0);
        \\}
    , .{});

    for (result.diagnostics.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, wgslender.Diagnostic.Code.unexpected_token)) {
            std.debug.print("valid module gained E0001: {s}\n", .{d.message});
            return error.ValidModuleReported;
        }
    }
}

test "stray tokens: an empty global declaration is legal, not stray" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // WGSL's grammar admits `global_decl: ';'`. A trailing semicolon after a
    // struct or function body is the common way this shows up, and it reaches
    // module scope as a token no declaration parser claimed — so it lands on
    // the same recovery path a genuinely stray token does.
    const result = try wgslender.validateWithOptions(arena.allocator(),
        \\struct S { x: f32 };
        \\fn f() -> f32 { return 1.0; };
        \\;
        \\@fragment fn fs() -> @location(0) vec4f { return vec4f(f()); }
    , .{});

    for (result.diagnostics.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, wgslender.Diagnostic.Code.unexpected_token)) {
            std.debug.print("empty global declaration flagged: {s}\n", .{d.message});
            return error.EmptyDeclFlagged;
        }
    }
}

test "stray tokens: an empty declaration ends a stray run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // `;` is a real declaration, so the runs on either side of it are
    // distinct and each earns its own diagnostic.
    const result = try wgslender.validateWithOptions(arena.allocator(),
        "garbage ; more garbage", .{});

    var count: usize = 0;
    for (result.diagnostics.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, wgslender.Diagnostic.Code.unexpected_token)) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

// =========================================================================
// The lossless-CST invariant the silent skip was protecting
// =========================================================================

fn concatCst(
    gpa: std.mem.Allocator,
    tree: *const Cst.Tree,
    buf: *std.ArrayListUnmanaged(u8),
    node_idx: Cst.NodeIndex,
) !void {
    const n = tree.getNode(node_idx);
    for (tree.children[n.first_child .. n.first_child + n.child_count]) |el| {
        if (el.asToken()) |token| {
            const s = tree.tokens.items(.start)[token];
            const e = tree.tokens.items(.end)[token];
            try buf.appendSlice(gpa, tree.source[s..e]);
        } else if (el.asNode()) |child| {
            try concatCst(gpa, tree, buf, child);
        }
    }
}

test "stray tokens: source still round-trips through the CST" {
    const gpa = std.testing.allocator;
    const source = "garbage here\nfn f() -> f32 { return 1.0; }";

    var result = try Incremental.parseFull(gpa, source);
    defer result.deinit();

    // Diagnosing the stray run must not cost the byte-exact CST round trip —
    // the tokens still have to be consumed into the tree.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try concatCst(gpa, &result.cst, &buf, result.cst.root());
    try std.testing.expectEqualStrings(source, buf.items);
}
