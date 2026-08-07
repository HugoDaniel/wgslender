//! Stamps the canonical version into every package manifest.
//!
//! The repo ships one library through four language ecosystems, and each has
//! its own manifest with its own idea of the version. Kept by hand they drift,
//! and they already had: `packages/rust` and `npm/wgslender-vscode` sat at
//! `0.1.0` while everything else read `1.1.0`.
//!
//! Canonical source: `src/root.zig`'s `pub const version`, imported rather than
//! parsed. It is already what `packages/go` pins against and what the C ABI's
//! `wgslender_version_c` returns, so it is the version every consumer can
//! observe at runtime. Importing it also means the build graph rebuilds this
//! tool whenever it changes — a text scrape would have to be kept honest by a
//! second mechanism.
//!
//! Usage — `zig build gen-version`: rewrites every site in place.
//! `tests/version_sync_test.zig` reads the same table back and fails with
//! "run `zig build gen-version`" on drift.
//!
//! ## Why this is a field rewrite, not a whole-file emit
//!
//! Its sibling `tools/gen_npm.zig` owns its output files completely and emits
//! them from scratch. That is not available here: `package.json` and
//! `Cargo.toml` are hand-maintained, and a generator that owned them would have
//! to own every dependency, script, and keyword in them too. So this tool
//! locates one field per site and replaces the quoted value, leaving the file
//! otherwise byte-identical — and the test compares *fields*, not bytes.
//!
//! The cost of that choice is that locating the field can fail. A stamper that
//! silently matches nothing is worse than no stamper at all: it reports
//! success, the drift test then fails, and the two disagree about which one is
//! broken. So every lookup here is a hard error naming the file, and every
//! anchor must match exactly one line.

const std = @import("std");
const wgslender = @import("wgslender");
const File = std.Io.File;
const Allocator = std.mem.Allocator;

/// The one version every manifest is stamped from.
pub const canonical = wgslender.version;

pub const Site = struct {
    path: []const u8,
    /// Prefix of the leading-whitespace-trimmed line carrying the version.
    /// Must match exactly one line in the file — see `locate`.
    anchor: []const u8,
    /// Text on that line immediately preceding the opening quote of the
    /// version. Usually equal to `anchor`; they differ where the version is
    /// not the first quoted value on its line (Cargo's inter-crate pins carry
    /// a `path = "…"` first).
    key: []const u8,
    /// What this site is, for error messages.
    what: []const u8,
};

/// Every version-bearing manifest field in the repo.
///
/// Not listed, deliberately:
///   * `src/root.zig` — the source, stamped by hand. That edit is the one
///     act of the release; everything here follows from it.
///   * `packages/go` — has no version field. It reports whatever the embedded
///     WASM says, which is the right design and needs nothing from a stamper.
///   * the four `packages/rust` member crates — they inherit
///     `version.workspace = true` from the workspace root below.
///   * the LSP `serverInfo` on both transports — those read
///     `wgslender.version` directly, so they cannot drift at all.
pub const sites = [_]Site{
    .{
        .path = "build.zig.zon",
        .anchor = ".version = ",
        .key = ".version = ",
        .what = "Zig package version",
    },
    .{
        .path = "packages/js-npm/package.json",
        .anchor = "\"version\":",
        .key = "\"version\":",
        .what = "npm package version",
    },
    .{
        .path = "npm/wgslender-lsp/package.json",
        .anchor = "\"version\":",
        .key = "\"version\":",
        .what = "npm LSP package version",
    },
    .{
        .path = "npm/wgslender-vscode/package.json",
        .anchor = "\"version\":",
        .key = "\"version\":",
        .what = "VS Code extension version",
    },
    // Cargo's four occurrences are the trap in this table. The workspace
    // version is inherited by all five member crates, but the three
    // inter-crate pins below carry their own copy alongside the `path`.
    // Cargo requires each pin to match the member's real version *at publish
    // time only* — a workspace where they disagree builds fine locally,
    // because the path wins, and fails at `cargo publish`. All four move
    // together or none do.
    .{
        .path = "packages/rust/Cargo.toml",
        .anchor = "version = ",
        .key = "version = ",
        .what = "Rust workspace version",
    },
    .{
        .path = "packages/rust/Cargo.toml",
        .anchor = "wgslender-core = ",
        .key = "version = ",
        .what = "Rust wgslender-core pin",
    },
    .{
        .path = "packages/rust/Cargo.toml",
        .anchor = "wgslender-macros = ",
        .key = "version = ",
        .what = "Rust wgslender-macros pin",
    },
    .{
        .path = "packages/rust/Cargo.toml",
        .anchor = "wgslender-sys = ",
        .key = "version = ",
        .what = "Rust wgslender-sys pin",
    },
};

pub const LocateError = error{
    /// No line's trimmed form starts with the anchor.
    AnchorNotFound,
    /// More than one does — the anchor no longer identifies a unique field,
    /// and guessing which one to stamp is exactly the silent-wrong-answer
    /// this tool must not produce.
    AnchorAmbiguous,
    /// The anchor line exists but carries no `key "…"` after it.
    KeyNotFound,
    /// The opening quote has no closing quote on the same line.
    UnterminatedValue,
};

/// Byte range of the version value *inside* its quotes.
pub const Span = struct { start: usize, end: usize };

/// Find the site's version value in `source`.
pub fn locate(source: []const u8, site: Site) LocateError!Span {
    var found: ?Span = null;

    var offset: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        defer offset += line.len + 1;

        const indent = line.len - std.mem.trimStart(u8, line, " \t").len;
        if (!std.mem.startsWith(u8, line[indent..], site.anchor)) continue;
        if (found != null) return error.AnchorAmbiguous;

        const after_key = (std.mem.indexOf(u8, line[indent..], site.key) orelse
            return error.KeyNotFound) + indent + site.key.len;
        const open = (std.mem.indexOfScalarPos(u8, line, after_key, '"') orelse
            return error.KeyNotFound) + 1;
        const close = std.mem.indexOfScalarPos(u8, line, open, '"') orelse
            return error.UnterminatedValue;

        found = .{ .start = offset + open, .end = offset + close };
    }

    return found orelse error.AnchorNotFound;
}

/// The version currently written at `site`.
pub fn valueIn(source: []const u8, site: Site) LocateError![]const u8 {
    const span = try locate(source, site);
    return source[span.start..span.end];
}

/// `source` with the site's version replaced. Byte-identical elsewhere.
pub fn stamped(alloc: Allocator, source: []const u8, site: Site, version: []const u8) Allocator.Error![]u8 {
    const span = locate(source, site) catch unreachable; // caller located it already
    return std.mem.concat(alloc, u8, &.{ source[0..span.start], version, source[span.end..] });
}

/// Human-readable "which field in which file", for both this tool's errors
/// and the drift test's failure output.
pub fn describe(alloc: Allocator, site: Site) Allocator.Error![]u8 {
    return std.fmt.allocPrint(alloc, "{s} ({s}, line starting `{s}`)", .{ site.path, site.what, site.anchor });
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var stamps: usize = 0;
    // Cargo.toml appears four times; re-reading it each pass keeps every site
    // independent, at the cost of three extra reads of a small file.
    for (sites) |site| {
        const source = try cwd.readFileAlloc(io, site.path, arena, .unlimited);
        const current = valueIn(source, site) catch |e| {
            try File.stderr().writeStreamingAll(io, try std.fmt.allocPrint(
                arena,
                "gen-version: cannot locate the version in {s}: {t}\n" ++
                    "  the manifest's shape changed — fix the anchor in tools/gen_version.zig\n",
                .{ try describe(arena, site), e },
            ));
            return e;
        };
        if (std.mem.eql(u8, current, canonical)) continue;

        try cwd.writeFile(io, .{
            .sub_path = site.path,
            .data = try stamped(arena, source, site, canonical),
        });
        stamps += 1;
        try File.stderr().writeStreamingAll(io, try std.fmt.allocPrint(
            arena,
            "gen-version: {s} {s} -> {s}\n",
            .{ try describe(arena, site), current, canonical },
        ));
    }

    try File.stderr().writeStreamingAll(io, try std.fmt.allocPrint(
        arena,
        "gen-version: {d} of {d} sites stamped to {s}\n",
        .{ stamps, sites.len, canonical },
    ));
}
