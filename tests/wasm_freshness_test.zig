//! Drift gates for the committed WASM artefacts — and a statement of what
//! they cannot do.
//!
//! ## The limit, first
//!
//! A committed binary cannot be proven fresh by anything committed alongside
//! it. A hash pinned in the same commit is circular: whoever forgot to rebuild
//! the WASM also did not update the hash, so both agree and both are wrong.
//! Only a rebuild proves freshness, and that lives in `scripts/release.sh`,
//! whose `git diff --exit-code` after regenerating everything is the real gate.
//!
//! What is available here are two cheap approximations, both of which catch
//! failures that actually happened:
//!
//!   (a) **copy-equality** — every in-tree copy of a given module is
//!       byte-identical. This is the exact shape of the drift that motivated
//!       `zig build release-assets`: one destination refreshed, another not,
//!       for three months, with no symptom because a stale WASM does not
//!       crash — it answers questions using the old wire format.
//!
//!   (b) **version pin** — the version string baked into the module equals
//!       `wgslender.version`. Catches a WASM left behind *across* a release.
//!       It cannot catch one left behind *within* a version, which is
//!       precisely why (a) and `release.sh` both still exist.
//!
//! Deliberately absent: a hash constant. It would need updating on every WASM
//! rebuild — the manual step this whole effort exists to delete — and a
//! constant that gets updated reflexively has stopped being a gate.
//!
//! The `npm/wgslender-vscode/dist/` copies are gitignored build output rather
//! than committed artefacts, so they are checked when present and skipped when
//! not; `packages/go`'s copy exists because `go:embed` cannot reach outside its
//! module. Files are read at runtime relative to the build cwd (the repo root
//! during `zig build test`) — `@embedFile` can't escape `tests/`.

const std = @import("std");
const wgslender = @import("wgslender");
const testing = std.testing;

const io = std.Options.debug_io;

const refresh_hint = "run `zig build release-assets` and commit the result";

const wgslender_wasm_copies = [_][]const u8{
    "packages/js-npm/wgslender.wasm",
    "packages/go/internal/wasmabi/wgslender.wasm",
    "npm/wgslender-vscode/dist/wgslender.wasm",
};

const lsp_wasm_copies = [_][]const u8{
    "npm/wgslender-lsp/wgslender-lsp.wasm",
    "npm/wgslender-vscode/dist/wgslender-lsp.wasm",
};

fn readIfPresent(alloc: std.mem.Allocator, path: []const u8) !?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch |e| switch (e) {
        error.FileNotFound => null,
        else => e,
    };
}

/// Assert every present copy in `paths` is byte-identical to the first one.
fn expectCopiesIdentical(comptime paths: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var reference: ?[]const u8 = null;
    var reference_path: []const u8 = undefined;
    var compared: usize = 0;

    for (paths) |path| {
        const bytes = (try readIfPresent(alloc, path)) orelse continue;
        const ref = reference orelse {
            reference = bytes;
            reference_path = path;
            continue;
        };
        compared += 1;
        if (!std.mem.eql(u8, ref, bytes)) {
            std.debug.print(
                "\n{s} ({d} bytes) differs from {s} ({d} bytes) — {s}\n",
                .{ path, bytes.len, reference_path, ref.len, refresh_hint },
            );
            return error.WasmCopiesDiffer;
        }
    }

    if (reference == null) return error.SkipZigTest; // extracted from the repo
    // One lone copy is not a failure — packages/go's is the only one that
    // survives extraction — but it does mean this test proved nothing, and
    // silence would read as coverage.
    if (compared == 0) return error.SkipZigTest;
}

/// Assert the module carries `needle`, which embeds `wgslender.version`.
fn expectVersionBakedIn(comptime paths: []const []const u8, needle: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var checked: usize = 0;
    for (paths) |path| {
        const bytes = (try readIfPresent(alloc, path)) orelse continue;
        checked += 1;
        if (std.mem.indexOf(u8, bytes, needle) == null) {
            std.debug.print(
                "\n{s} does not contain \"{s}\" — it was built from a different version. {s}\n",
                .{ path, needle, refresh_hint },
            );
            return error.WasmVersionStale;
        }
    }
    if (checked == 0) return error.SkipZigTest;
}

test "every wgslender.wasm copy is byte-identical" {
    try expectCopiesIdentical(&wgslender_wasm_copies);
}

test "every wgslender-lsp.wasm copy is byte-identical" {
    try expectCopiesIdentical(&lsp_wasm_copies);
}

test "the shipped wgslender.wasm was built at the current version" {
    // `wgslender_version_c` returns this constant, so it lands in the data
    // section verbatim.
    try expectVersionBakedIn(&wgslender_wasm_copies, wgslender.version);
}

test "the shipped wgslender-lsp.wasm was built at the current version" {
    // Tighter than a bare version search: this is the exact fragment of
    // `initialize_result_json`, which exists only because both transports
    // derive serverInfo from `wgslender.version` rather than a literal.
    try expectVersionBakedIn(&lsp_wasm_copies, "\"version\":\"" ++ wgslender.version ++ "\"");
}
