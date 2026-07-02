//! Corpus-wide diagnostic-code pin for the tint test set.
//!
//! Walks `tests/testdata/tint/` once, runs each shader through the
//! validator with default options, and pins two goldens from that single
//! walk:
//!
//!   * `tests/inference/corpus_golden.txt` — histogram
//!     { diagnostic-code → number of distinct shaders that emit it }.
//!   * `tests/inference/triage_golden.txt` — the same histogram split by
//!     Tint's own verdict (from each shader's sibling `.expected.wgsl`,
//!     classified by `tint_oracle`): fp = code emitted on a shader Tint
//!     *accepts* (a false-positive candidate for E-codes), tp = on a
//!     shader Tint *rejects*, unk = verdict unknown. Plus a per-shader
//!     audit of every Tint-rejected shader and our outcome on it.
//!
//! Both fail on any drift — a regression net for the inference / validator
//! surface, now measured against the Tint oracle.
//!
//! To regenerate after an intentional change (both goldens together):
//!   rm tests/inference/corpus_golden.txt tests/inference/triage_golden.txt && zig build test
//!
//! When a golden is absent, the current value is written to it and the run
//! succeeds — the first run after deletion acts as "regenerate"; the next
//! run (and CI) compares.
//!
//! The corpus directory is optional. When absent the test is a no-op so
//! CI / downstream environments without the Google Dawn dataset still
//! succeed.

const std = @import("std");
const wgslender = @import("wgslender");
const tint_oracle = @import("tint_oracle");
const Verdict = tint_oracle.Verdict;
const testing = std.testing;

fn makeSentinel(allocator: std.mem.Allocator, bytes: []const u8) ![:0]const u8 {
    const buf = try allocator.alloc(u8, bytes.len + 1);
    @memcpy(buf[0..bytes.len], bytes);
    buf[bytes.len] = 0;
    return buf[0..bytes.len :0];
}

const CodeEntry = struct {
    code: []const u8,
    count: u32,
};

fn lessThanByCode(_: void, a: CodeEntry, b: CodeEntry) bool {
    return std.mem.lessThan(u8, a.code, b.code);
}

/// Per-code split of the histogram by the shader's Tint verdict. Keyed by
/// the same code strings as `histogram`, updated in the same loop, so
/// `fp + tp + unk == histogram[code]` holds for every code.
const Bucket3 = struct { fp: u32 = 0, tp: u32 = 0, unk: u32 = 0 };

/// Our outcome on a shader — recorded for the Tint-rejects audit so a
/// disagreement with Tint is visible.
const Outcome = union(enum) {
    /// We validated it clean.
    accept,
    /// We rejected it; carries the first error-severity code (outer arena).
    reject: []const u8,
    /// Excluded via `containsUnsupported` (feature we don't model yet).
    skip,
    /// Hard validate/sentinel failure (`catch`).
    validate_error,
};

const RejectEntry = struct {
    path: []const u8, // outer-arena dupe, '/'-normalized
    outcome: Outcome,
};

fn lessThanByPath(_: void, a: RejectEntry, b: RejectEntry) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

fn outcomeString(alloc: std.mem.Allocator, o: Outcome) ![]u8 {
    return switch (o) {
        .accept => alloc.dupe(u8, "accept"),
        .reject => |code| std.fmt.allocPrint(alloc, "reject:{s}", .{code}),
        .skip => alloc.dupe(u8, "skip"),
        .validate_error => alloc.dupe(u8, "error"),
    };
}

/// Copy `p` with backslashes normalized to `/` so Windows walker output
/// matches the committed goldens.
fn normalizePath(alloc: std.mem.Allocator, p: []const u8) ![]u8 {
    const buf = try alloc.dupe(u8, p);
    for (buf) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return buf;
}

/// Write `out_items` to `golden_path` when it is absent, otherwise compare
/// (trailing newlines ignored) and fail on drift.
fn writeOrCompareGolden(
    io: std.Io,
    gpa_alloc: std.mem.Allocator,
    golden_path: []const u8,
    out_items: []const u8,
) !void {
    const golden_bytes_or_err = std.Io.Dir.cwd().readFileAlloc(io, golden_path, gpa_alloc, .unlimited);
    if (golden_bytes_or_err) |golden_bytes| {
        defer gpa_alloc.free(golden_bytes);
        if (!std.mem.eql(u8, std.mem.trimEnd(u8, golden_bytes, "\n"), std.mem.trimEnd(u8, out_items, "\n"))) {
            std.debug.print(
                "\ncorpus pin drift at {s}. Current:\n{s}\n" ++
                    "If this change is intentional, regenerate by deleting the golden(s) and re-running:\n" ++
                    "  rm {s} && zig build test\n",
                .{ golden_path, out_items, golden_path },
            );
            return error.TestUnexpectedResult;
        }
    } else |err| switch (err) {
        error.FileNotFound => {
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = golden_path, .data = out_items }) catch |werr| {
                std.debug.print("corpus pin: failed to write golden {s}: {s}\n", .{ golden_path, @errorName(werr) });
                return werr;
            };
            std.debug.print("corpus pin: wrote {s}\n", .{golden_path});
        },
        else => return err,
    }
}

test "tint corpus diagnostic-code pin + oracle triage" {
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

    // The outer arena backs the histogram/triage map keys, the reject list,
    // and any per-shader temporary that must outlive its shader arena.
    var arena_outer = std.heap.ArenaAllocator.init(gpa_alloc);
    defer arena_outer.deinit();
    const outer_alloc = arena_outer.allocator();

    var histogram: std.StringHashMapUnmanaged(u32) = .{};
    var triage: std.StringHashMapUnmanaged(Bucket3) = .{};
    var rejects_list: std.ArrayListUnmanaged(RejectEntry) = .empty;

    var shaders_processed: usize = 0;
    var accepts: usize = 0;
    var rejects: usize = 0;
    var unknown: usize = 0;
    var excluded_unsupported: usize = 0;
    var validate_errors: usize = 0;

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

        // Tint's own verdict for this shader (reads the sibling
        // `.expected.wgsl`; absent/other → unknown). Computed for every
        // walked shader so excluded-but-rejected shaders still audit.
        const verdict = tint_oracle.verdictForEntry(io, entry.dir, entry.basename, alloc);

        var outcome: Outcome = .skip;
        process: {
            if (tint_oracle.containsUnsupported(bytes)) {
                excluded_unsupported += 1;
                outcome = .skip;
                break :process;
            }

            const source = makeSentinel(alloc, bytes) catch {
                validate_errors += 1;
                outcome = .validate_error;
                break :process;
            };
            var result = wgslender.validateWithOptions(alloc, source, .{}) catch {
                validate_errors += 1;
                outcome = .validate_error;
                break :process;
            };
            defer result.deinit(alloc);

            shaders_processed += 1;
            switch (verdict) {
                .accepts => accepts += 1,
                .rejects => rejects += 1,
                .unknown => unknown += 1,
            }

            // Our outcome: clean → accept; else the first error-severity code.
            if (result.valid) {
                outcome = .accept;
            } else {
                var first_code: []const u8 = "";
                for (result.diagnostics.items()) |d| {
                    if (d.severity == .@"error" and d.code.len > 0) {
                        first_code = d.code;
                        break;
                    }
                }
                outcome = .{ .reject = outer_alloc.dupe(u8, first_code) catch "" };
            }

            // Histogram + triage over the distinct set of codes this shader
            // emitted (a code emitted twice still counts once).
            var seen: std.StringHashMapUnmanaged(void) = .{};
            defer seen.deinit(alloc);
            for (result.diagnostics.items()) |d| {
                if (d.code.len == 0) continue;
                const gop = seen.getOrPut(alloc, d.code) catch continue;
                if (gop.found_existing) continue;

                const he = histogram.getOrPut(outer_alloc, d.code) catch continue;
                if (!he.found_existing) {
                    // Copy the code into the outer arena so it outlives the
                    // per-shader arena.
                    he.key_ptr.* = outer_alloc.dupe(u8, d.code) catch continue;
                    he.value_ptr.* = 0;
                }
                he.value_ptr.* += 1;

                const te = triage.getOrPut(outer_alloc, d.code) catch continue;
                if (!te.found_existing) {
                    te.key_ptr.* = outer_alloc.dupe(u8, d.code) catch continue;
                    te.value_ptr.* = .{};
                }
                switch (verdict) {
                    .accepts => te.value_ptr.fp += 1,
                    .rejects => te.value_ptr.tp += 1,
                    .unknown => te.value_ptr.unk += 1,
                }
            }
        }

        // Audit every Tint-rejected shader (processed or excluded) with our
        // outcome — a `reject`-bucket `accept` is a false negative.
        if (verdict == .rejects) {
            const path_norm = try normalizePath(outer_alloc, entry.path);
            try rejects_list.append(outer_alloc, .{ .path = path_norm, .outcome = outcome });
        }
    }

    // Materialize a sorted (code, count) list so output is deterministic.
    var entries: std.ArrayListUnmanaged(CodeEntry) = .empty;
    defer entries.deinit(gpa_alloc);
    var it = histogram.iterator();
    while (it.next()) |e| {
        try entries.append(gpa_alloc, .{ .code = e.key_ptr.*, .count = e.value_ptr.* });
    }
    std.sort.block(CodeEntry, entries.items, {}, lessThanByCode);

    std.sort.block(RejectEntry, rejects_list.items, {}, lessThanByPath);

    // --- Invariants (assert before serializing) ------------------------------

    // Every processed shader has exactly one Tint verdict.
    try testing.expectEqual(shaders_processed, accepts + rejects + unknown);

    // Each code's verdict split reconstructs its histogram count.
    for (entries.items) |e| {
        const t = triage.get(e.code) orelse Bucket3{};
        try testing.expectEqual(e.count, t.fp + t.tp + t.unk);
    }

    // Known answer: among WGSL shaders the pinned dawn revision has exactly
    // one Tint-rejected shader — bug/chromium/1395241.wgsl — which we also
    // reject (not a false negative). The corpus holds 25 `SKIP: FAILED`
    // expected files in total, but the other 24 are `.spvasm` SPIR-V-reader
    // tests whose input is not WGSL, so this `.wgsl`-scoped walk never sees
    // them (see the triage golden's tint-rejects note).
    try testing.expectEqual(@as(usize, 1), rejects_list.items.len);
    // No Tint-rejected shader we validate may be accepted (that is a false
    // negative worth surfacing).
    for (rejects_list.items) |r| {
        try testing.expect(std.meta.activeTag(r.outcome) != .accept);
    }
    {
        var found_1395241 = false;
        for (rejects_list.items) |r| {
            if (std.mem.endsWith(u8, r.path, "bug/chromium/1395241.wgsl")) found_1395241 = true;
        }
        try testing.expect(found_1395241);
    }

    // --- Golden 1: histogram (format unchanged) ------------------------------

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
    try writeOrCompareGolden(io, gpa_alloc, "tests/inference/corpus_golden.txt", out.items);

    // --- Golden 2: oracle triage split --------------------------------------

    var tri: std.ArrayListUnmanaged(u8) = .empty;
    defer tri.deinit(gpa_alloc);
    try tri.appendSlice(gpa_alloc, "# tint-oracle triage. accepts = expected file, no SKIP; rejects = \"SKIP: FAILED\"; unknown = absent or other SKIP.\n");
    try tri.appendSlice(gpa_alloc, "# fp/tp/unk = shaders emitting the code whose verdict is accepts/rejects/unknown.\n");
    try tri.appendSlice(gpa_alloc, "# fp is a false-positive *candidate* for E-codes; W/I rows are mechanical.\n");
    {
        const header = try std.fmt.allocPrint(
            gpa_alloc,
            "# shaders={d} accepts={d} rejects={d} unknown={d} excluded={d} validate_errors={d}\n",
            .{ shaders_processed, accepts, rejects, unknown, excluded_unsupported, validate_errors },
        );
        defer gpa_alloc.free(header);
        try tri.appendSlice(gpa_alloc, header);
    }
    for (entries.items) |e| {
        const t = triage.get(e.code) orelse Bucket3{};
        const line = try std.fmt.allocPrint(gpa_alloc, "{s} {d} fp={d} tp={d} unk={d}\n", .{ e.code, e.count, t.fp, t.tp, t.unk });
        defer gpa_alloc.free(line);
        try tri.appendSlice(gpa_alloc, line);
    }
    try tri.appendSlice(gpa_alloc, "# tint-rejects: WGSL shaders Tint rejected (expected file = \"SKIP: FAILED\"), with our outcome.\n");
    try tri.appendSlice(gpa_alloc, "#   A rejects-bucket 'accept' is a false negative. The corpus also has 24 non-WGSL\n");
    try tri.appendSlice(gpa_alloc, "#   SKIP:FAILED cases (.spvasm reader tests) outside this .wgsl walk; not listed.\n");
    try tri.appendSlice(gpa_alloc, "# tint-rejects <path> <our-outcome: accept|reject:<code>|skip|error>\n");
    for (rejects_list.items) |r| {
        const os = try outcomeString(gpa_alloc, r.outcome);
        defer gpa_alloc.free(os);
        const line = try std.fmt.allocPrint(gpa_alloc, "tint-rejects {s} {s}\n", .{ r.path, os });
        defer gpa_alloc.free(line);
        try tri.appendSlice(gpa_alloc, line);
    }
    try writeOrCompareGolden(io, gpa_alloc, "tests/inference/triage_golden.txt", tri.items);
}
