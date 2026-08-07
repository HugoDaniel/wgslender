//! Drift gate for the version stamped into every package manifest.
//!
//! One library, four language ecosystems, one version line. `tools/gen_version.zig`
//! writes it; this test proves nobody hand-edited a manifest since. On failure:
//! run `zig build gen-version` and commit the result.
//!
//! Unlike its sibling `tests/npm_generated_test.zig`, this compares *fields*
//! rather than bytes — `package.json` and `Cargo.toml` are hand-maintained
//! everywhere except their one version field, so the generator rewrites that
//! field in place and has no opinion about the rest of the file.
//!
//! The manifests are read at runtime relative to the build cwd (the repo root
//! during `zig build test`, same as the corpus tests) — `@embedFile` can't
//! reach outside the `tests/` package directory.

const std = @import("std");
const gen_version = @import("gen_version");
const wgslender = @import("wgslender");
const testing = std.testing;

const io = std.Options.debug_io;

const stale_hint = "version drift: run `zig build gen-version` and commit the result";

test "every manifest carries the canonical version" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var drifted: usize = 0;
    for (gen_version.sites) |site| {
        const source = try std.Io.Dir.cwd().readFileAlloc(io, site.path, alloc, .unlimited);
        // A locate failure is a real failure, not a skip: it means the
        // manifest's shape moved out from under the stamper, which would
        // otherwise leave `zig build gen-version` reporting success while
        // silently stamping nothing.
        const found = try gen_version.valueIn(source, site);
        if (!std.mem.eql(u8, found, wgslender.version)) {
            drifted += 1;
            std.debug.print("  {s}: {s} (expected {s})\n", .{
                try gen_version.describe(alloc, site),
                found,
                wgslender.version,
            });
        }
    }

    if (drifted != 0) {
        std.debug.print("\n{d} of {d} sites drifted — {s}\n", .{ drifted, gen_version.sites.len, stale_hint });
        return error.VersionDrift;
    }
}

// The specific drift that motivated the stamper. Cargo's three inter-crate
// pins carry their own copy of the version alongside the `path`, and a
// workspace where they disagree with the workspace version builds fine
// locally — the path wins — and fails only at `cargo publish`. Kept as a
// targeted assertion so that failure mode stays self-documenting.
test "Cargo's inter-crate pins match the workspace version" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = try std.Io.Dir.cwd().readFileAlloc(io, "packages/rust/Cargo.toml", alloc, .unlimited);

    var workspace_version: ?[]const u8 = null;
    var pins: usize = 0;
    for (gen_version.sites) |site| {
        if (!std.mem.eql(u8, site.path, "packages/rust/Cargo.toml")) continue;
        const found = try gen_version.valueIn(source, site);
        if (workspace_version) |v| {
            pins += 1;
            testing.expectEqualStrings(v, found) catch |e| {
                std.debug.print("\n{s} disagrees with the workspace version — {s}\n", .{ site.what, stale_hint });
                return e;
            };
        } else {
            workspace_version = found;
        }
    }
    try testing.expectEqual(@as(usize, 3), pins);
}
