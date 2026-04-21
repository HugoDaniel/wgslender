//! Corpus-wide diagnostic-code pin for the tint test set.
//!
//! Walks `tests/testdata/tint/`, runs each shader through the validator
//! with default options, and builds a histogram:
//!   { diagnostic-code → number of distinct shaders that emit it }.
//!
//! The histogram is compared against
//! `tests/inference/corpus_golden.txt`. The test fails on any drift —
//! intended as a regression net for the inference / validator surface.
//!
//! To regenerate the golden file after an intentional change:
//!   rm tests/inference/corpus_golden.txt && zig build test
//!
//! When the golden file is absent, this test writes the current
//! histogram to it and succeeds. The first run after you delete the
//! file acts as the "regenerate" step; the next run (and CI) compares.
//!
//! The corpus directory is optional. When absent the test is a no-op
//! so CI / downstream environments without the Google Dawn dataset
//! still succeed.

const std = @import("std");
const wgslender = @import("wgslender");

fn makeSentinel(allocator: std.mem.Allocator, bytes: []const u8) ![:0]const u8 {
    const buf = try allocator.alloc(u8, bytes.len + 1);
    @memcpy(buf[0..bytes.len], bytes);
    buf[bytes.len] = 0;
    return buf[0..bytes.len :0];
}

/// Files that use features we don't support yet. Skipped so they don't
/// contribute noise to the pin.
const unsupported_features = [_][]const u8{
    "enable f16",
    "enable chromium",
    "enable subgroups",
    "diagnostic(off",
    "diagnostic(warning",
    "diagnostic(error",
    "@diagnostic",
};

fn containsUnsupported(source: []const u8) bool {
    for (unsupported_features) |f| {
        if (std.mem.indexOf(u8, source, f) != null) return true;
    }
    return false;
}

const CodeEntry = struct {
    code: []const u8,
    count: u32,
};

fn lessThanByCode(_: void, a: CodeEntry, b: CodeEntry) bool {
    return std.mem.lessThan(u8, a.code, b.code);
}

test "tint corpus diagnostic-code pin" {
    const tint_dir_rel = "tests/testdata/tint";
    const io = std.Options.debug_io;

    var tint_dir = std.Io.Dir.cwd().openDir(io, tint_dir_rel, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound or err == error.NotFound) {
            std.debug.print("tests/testdata/tint not found — skipping corpus pin\n", .{});
            return;
        }
        return err;
    };
    defer tint_dir.close(io);

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const gpa_alloc = gpa.allocator();

    // Histogram keyed by code string. The arena backs both the map
    // entries' code strings and the per-shader temporary allocations.
    var arena_outer = std.heap.ArenaAllocator.init(gpa_alloc);
    defer arena_outer.deinit();
    const outer_alloc = arena_outer.allocator();

    var histogram: std.StringHashMapUnmanaged(u32) = .{};
    var shaders_processed: usize = 0;

    var walker = try tint_dir.walk(gpa_alloc);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".wgsl")) continue;
        if (std.mem.indexOf(u8, entry.path, ".expected.") != null) continue;

        // Per-shader arena — bounds memory, freed after the shader.
        var arena = std.heap.ArenaAllocator.init(gpa_alloc);
        defer arena.deinit();
        const alloc = arena.allocator();

        const bytes = entry.dir.readFileAlloc(io, entry.basename, alloc, .unlimited) catch continue;
        if (containsUnsupported(bytes)) continue;

        const source = makeSentinel(alloc, bytes) catch continue;
        var result = wgslender.validateWithOptions(alloc, source, .{}) catch continue;
        defer result.deinit(alloc);

        shaders_processed += 1;

        // Collect the distinct set of codes this shader emitted. A code
        // emitted twice in one shader still counts once in the histogram.
        var seen: std.StringHashMapUnmanaged(void) = .{};
        defer seen.deinit(alloc);
        for (result.diagnostics.items()) |d| {
            if (d.code.len == 0) continue;
            const gop = seen.getOrPut(alloc, d.code) catch continue;
            if (gop.found_existing) continue;

            const entry_result = histogram.getOrPut(outer_alloc, d.code) catch continue;
            if (!entry_result.found_existing) {
                // Copy the code string into the outer arena so it outlives
                // the per-shader arena.
                const code_copy = outer_alloc.dupe(u8, d.code) catch continue;
                entry_result.key_ptr.* = code_copy;
                entry_result.value_ptr.* = 0;
            }
            entry_result.value_ptr.* += 1;
        }
    }

    // Materialize a sorted list of (code, count) so the output is
    // deterministic across runs.
    var entries: std.ArrayListUnmanaged(CodeEntry) = .empty;
    defer entries.deinit(gpa_alloc);
    var it = histogram.iterator();
    while (it.next()) |e| {
        try entries.append(gpa_alloc, .{ .code = e.key_ptr.*, .count = e.value_ptr.* });
    }
    std.sort.block(CodeEntry, entries.items, {}, lessThanByCode);

    // Serialize histogram as "CODE COUNT\n" lines with a leading header
    // "# shaders=N\n" so environmental drift (corpus size changing) is
    // also caught.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa_alloc);
    {
        const header = try std.fmt.allocPrint(gpa_alloc, "# shaders={d}\n", .{shaders_processed});
        defer gpa_alloc.free(header);
        try out.appendSlice(gpa_alloc, header);
    }
    for (entries.items) |e| {
        const line = try std.fmt.allocPrint(gpa_alloc, "{s} {d}\n", .{ e.code, e.count });
        defer gpa_alloc.free(line);
        try out.appendSlice(gpa_alloc, line);
    }

    const golden_path = "tests/inference/corpus_golden.txt";

    const golden_bytes_or_err = std.Io.Dir.cwd().readFileAlloc(io, golden_path, gpa_alloc, .unlimited);
    if (golden_bytes_or_err) |golden_bytes| {
        defer gpa_alloc.free(golden_bytes);
        if (!std.mem.eql(u8, std.mem.trimEnd(u8, golden_bytes, "\n"), std.mem.trimEnd(u8, out.items, "\n"))) {
            std.debug.print(
                "\ntint corpus pin drift at {s}. Current histogram:\n{s}\n" ++
                    "If this change is intentional, regenerate by deleting the golden and re-running:\n" ++
                    "  rm {s} && zig build test\n",
                .{ golden_path, out.items, golden_path },
            );
            return error.TestUnexpectedResult;
        }
    } else |err| switch (err) {
        error.FileNotFound => {
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = golden_path, .data = out.items }) catch |werr| {
                std.debug.print("tint corpus pin: failed to write golden: {s}\n", .{@errorName(werr)});
                return werr;
            };
            std.debug.print(
                "tint corpus pin: wrote {d} entries across {d} shaders → {s}\n",
                .{ entries.items.len, shaders_processed, golden_path },
            );
        },
        else => return err,
    }
}
