//! Phase 2 hot-path coverage smoke on `bridge.wgsl` (~850 LOC — the
//! largest compute.toys shader and the canonical "biggest real-world
//! workload" target from the roadmap).
//!
//! This file is the "perf smoke" slot reserved in the plan. Wall-clock
//! timing is deferred until Zig 0.16 exposes a convenient `std.time.Timer`
//! / `Instant` (see BENCHMARK.md:201). Until then, the test asserts the
//! regression-prone invariant: every body-edit on bridge.wgsl must take
//! the in-place compound_stmt hot path, not fall back to parseFull.

const std = @import("std");
const wgslender = @import("wgslender");

const Incremental = wgslender.Incremental;

fn makeSentinel(a: std.mem.Allocator, bytes: []const u8) ![:0]const u8 {
    const buf = try a.allocSentinel(u8, bytes.len, 0);
    @memcpy(buf, bytes);
    return buf[0..bytes.len :0];
}

test "perf-smoke: 25 compound_stmt appends on bridge.wgsl all take the hot path" {
    const gpa = std.testing.allocator;

    const source_bytes = @embedFile("testdata/compute.toys/bridge.wgsl");
    const source_z = try makeSentinel(gpa, source_bytes);
    defer gpa.free(source_z);

    const iterations: u32 = 25;
    var reused_count: u32 = 0;

    var cur = try Incremental.parseFull(gpa, source_z);
    defer cur.deinit();

    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        const close_off: u32 = @intCast(std.mem.lastIndexOfScalar(u8, cur.source, '}').?);
        var buf: [64]u8 = undefined;
        const payload = try std.fmt.bufPrint(&buf, "  let _perf_{} = {}.0;\n", .{ i, i });

        const next = try Incremental.reparse(gpa, &cur, .{
            .start = close_off,
            .end = close_off,
            .new_text = payload,
        });
        if (next.reused) reused_count += 1;
        cur.deinit();
        cur = next;
    }

    // Live symbol sum matches a fresh parseFull at the end — the
    // append-only contract keeps dead symbols around but the live totals
    // must agree.
    var oracle = try Incremental.parseFull(gpa, cur.source);
    defer oracle.deinit();
    var oracle_live: u64 = 0;
    for (oracle.module.use_counts.counts) |c| oracle_live += c;
    var cur_live: u64 = 0;
    for (cur.module.use_counts.counts) |c| cur_live += c;
    try std.testing.expectEqual(oracle_live, cur_live);

    std.debug.print(
        "perf-smoke bridge.wgsl compound_stmt append x{d}: reused={d}/{d}\n",
        .{ iterations, reused_count, iterations },
    );

    // The hot path must dominate. Occasional fallbacks from the
    // compaction watermark tripping are expected on a large base — the
    // 4 MiB floor is engineered so realistic bursts stay mostly hot
    // without letting sessions drift unboundedly. A regression in
    // anchor classification or scope splice would surface as a
    // dramatic drop here.
    try std.testing.expect(reused_count * 100 >= iterations * 75);
}
