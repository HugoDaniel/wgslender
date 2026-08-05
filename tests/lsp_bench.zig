//! Wall-clock benchmark for the LSP request handlers that convert one byte
//! offset per result — the shape that made `Handler.offsetToLspPosition`'s
//! scan-from-byte-0 quadratic before `PositionMapper` landed.
//!
//! Run with `zig build bench-lsp -Doptimize=ReleaseFast`. This is NOT
//! attached to `zig build test`: timings are noisy, the corpus shaders are
//! large, and a wall-clock number is not a pass/fail gate. The correctness
//! gate for the same code is `tests/lsp_position_mapper_test.zig`.
//!
//! `analyzeDocument` is timed alongside each request as the floor: with the
//! analysis cache warm it reports ~0 ms, so every millisecond the other rows
//! show is work the request does *on top of* a cache hit — which is exactly
//! the position-conversion cost this benchmark exists to watch.

const std = @import("std");
const Handler = @import("Handler");

const Case = struct { name: []const u8, source: [:0]const u8 };

const cases = [_]Case{
    .{ .name = "sceneW.wgsl", .source = @embedFile("testdata/sceneW.wgsl") },
    .{ .name = "sceneY.wgsl", .source = @embedFile("testdata/sceneY.wgsl") },
    .{ .name = "starsParticlesModule.wgsl", .source = @embedFile("testdata/starsParticlesModule.wgsl") },
};

const iters = 50;
const uri = "bench://shader.wgsl";

const Timing = struct { ms: f64, count: usize };

/// Milliseconds per call over `iters` runs of `body`.
fn timeIt(handler: *Handler, comptime body: fn (*Handler) anyerror!usize) !Timing {
    const io = std.Options.debug_io;
    var count: usize = 0;
    const t0 = std.Io.Clock.now(.awake, io);
    for (0..iters) |_| count = try body(handler);
    const t1 = std.Io.Clock.now(.awake, io);
    const ns: u64 = @intCast(@divTrunc(t1.nanoseconds - t0.nanoseconds, iters));
    return .{ .ms = @as(f64, @floatFromInt(ns)) / 1_000_000.0, .count = count };
}

fn benchAnalyze(handler: *Handler) !usize {
    const a = try handler.analyzeDocument(uri);
    const module = a.module orelse return 0;
    return module.declarations.items.len;
}

fn benchSemanticTokens(handler: *Handler) !usize {
    const data = try handler.computeSemanticTokens(uri);
    defer std.testing.allocator.free(data);
    return data.len / 5;
}

fn benchDocumentSymbols(handler: *Handler) !usize {
    const symbols = try handler.computeDocumentSymbols(uri);
    defer {
        for (symbols) |s| if (s.children.len > 0) std.testing.allocator.free(s.children);
        std.testing.allocator.free(symbols);
    }
    return symbols.len;
}

fn benchFoldingRanges(handler: *Handler) !usize {
    const ranges = try handler.computeFoldingRanges(uri);
    defer std.testing.allocator.free(ranges);
    return ranges.len;
}

fn benchCodeLens(handler: *Handler) !usize {
    const lenses = try handler.computeCodeLens(uri);
    defer Handler.freeCodeLens(std.testing.allocator, lenses);
    return lenses.len;
}

fn benchDiagnostics(handler: *Handler) !usize {
    const diags = try handler.validateDocumentFull(uri);
    defer Handler.freeDiagnostics(std.testing.allocator, diags);
    return diags.len;
}

test "bench: LSP per-result request handlers" {
    const gpa = std.testing.allocator;

    const requests = .{
        .{ "analyzeDocument (cached)", benchAnalyze },
        .{ "semanticTokens", benchSemanticTokens },
        .{ "documentSymbols", benchDocumentSymbols },
        .{ "foldingRanges", benchFoldingRanges },
        .{ "codeLens", benchCodeLens },
        .{ "diagnostics", benchDiagnostics },
    };

    for (cases) |c| {
        const handler = try gpa.create(Handler);
        defer gpa.destroy(handler);
        handler.* = Handler.init(gpa);
        defer handler.deinit();
        try handler.openDocument(uri, c.source, 1);

        std.debug.print("\n{s} ({d} bytes)\n", .{ c.name, c.source.len });
        inline for (requests) |req| {
            // Warm the analysis cache so the first timed iteration isn't
            // paying for a parse the rest of them skip.
            _ = try req[1](handler);
            const r = try timeIt(handler, req[1]);
            std.debug.print("  {s: <24} {d: >8.2} ms/call  ({d} results)\n", .{ req[0], r.ms, r.count });
        }
    }
}
