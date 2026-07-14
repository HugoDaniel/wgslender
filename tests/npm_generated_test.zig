//! Freshness gate for the generated npm mirrors.
//!
//! `npm/wgslender/configs.{js,d.ts}` are generated from the Zig config pack
//! tables (`src/lint/configs.zig`) and option specs (`src/options.zig`) by
//! `tools/gen_npm.zig`. This test byte-compares the committed files against
//! the generator's in-process output so drift can never ship silently — the
//! no-CI analogue of the corpus goldens. On failure: run `zig build gen-npm`
//! and commit the result.
//!
//! The committed files are read at runtime relative to the build cwd (the repo
//! root during `zig build test`, same as the corpus tests) — `@embedFile`
//! can't reach outside the `tests/` package directory.

const std = @import("std");
const gen_npm = @import("gen_npm");
const testing = std.testing;

const io = std.Options.debug_io;

const stale_hint =
    "npm/wgslender/configs.{js,d.ts} is stale — run `zig build gen-npm` and commit the result";

fn expectMatchesGenerator(
    comptime emit: fn (std.mem.Allocator) std.mem.Allocator.Error![]u8,
    committed_path: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const committed = try std.Io.Dir.cwd().readFileAlloc(io, committed_path, alloc, .unlimited);
    const generated = try emit(alloc);
    testing.expectEqualStrings(generated, committed) catch |e| {
        std.debug.print("\n{s}\n", .{stale_hint});
        return e;
    };
}

test "configs.js matches the generator (run `zig build gen-npm` on failure)" {
    try expectMatchesGenerator(gen_npm.emitConfigsJs, "npm/wgslender/configs.js");
}

test "configs.d.ts matches the generator (run `zig build gen-npm` on failure)" {
    try expectMatchesGenerator(gen_npm.emitConfigsDts, "npm/wgslender/configs.d.ts");
}

// The specific drift that motivated the generator: the advisory
// `@wgslender/minify` pack was missing from the hand-maintained mirror.
// Kept as a targeted assertion so the regression is self-documenting even if
// the byte-compare above is ever relaxed.
test "the committed mirror exports the @wgslender/minify pack" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const js = try std.Io.Dir.cwd().readFileAlloc(io, "npm/wgslender/configs.js", alloc, .unlimited);
    const dts = try std.Io.Dir.cwd().readFileAlloc(io, "npm/wgslender/configs.d.ts", alloc, .unlimited);
    try testing.expect(std.mem.indexOf(u8, js, "'@wgslender/minify'") != null);
    try testing.expect(std.mem.indexOf(u8, dts, "export const minify: SharedConfig;") != null);
}
