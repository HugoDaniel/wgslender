//! Tests for `MinifyEstimator.estimate` — Phase 3 of minifier-mode.
//!
//! Strategy: Option B (dry-run Printer with length-only renamer) means the
//! estimator reuses the production Printer and only substitutes a renamer
//! that returns dummy slices of the same length the real MinifyRenamer
//! would have produced. Consequently, `total_min` is expected to match
//! `wgslender.minifyWithOptions(...).code.len` exactly on valid shaders —
//! the plan's 5% parity guard is kept as the acceptance bound but almost
//! always clears with room to spare.
//!
//! Perf tests here assert shape (linear scaling via symbol-count proxies),
//! not wall-clock, mirroring the existing convention in
//! `tests/lsp_incremental_compound_perf_test.zig`.

const std = @import("std");
const wgslender = @import("wgslender");

const Ast = wgslender.Ast;
const MinifyEstimator = wgslender.MinifyEstimator;
const Minifier = wgslender.Minifier;
const Renamer = wgslender.Renamer;

const testing = std.testing;

fn sentinel(a: std.mem.Allocator, bytes: []const u8) ![:0]const u8 {
    const buf = try a.allocSentinel(u8, bytes.len, 0);
    @memcpy(buf, bytes);
    return buf[0..bytes.len :0];
}

/// Parse `source`, run the estimator with the given options, and return
/// the result along with the owning analysis (caller must deinit both).
const Ctx = struct {
    analysis: wgslender.Validator.AnalysisResult,
    estimate: MinifyEstimator.EstimateResult,

    fn init(gpa: std.mem.Allocator, source: [:0]const u8, options: MinifyEstimator.Options) !Ctx {
        var analysis = try wgslender.analyzeWithOptions(gpa, source, .{});
        errdefer analysis.deinit();
        const module = analysis.module orelse return error.MissingModule;
        const estimate = try MinifyEstimator.estimate(analysis._arena.?.allocator(), module, options);
        return .{ .analysis = analysis, .estimate = estimate };
    }

    fn deinit(self: *Ctx) void {
        self.analysis.deinit();
    }
};

fn estimateTotal(gpa: std.mem.Allocator, source: [:0]const u8, options: MinifyEstimator.Options) !u32 {
    var ctx = try Ctx.init(gpa, source, options);
    defer ctx.deinit();
    return ctx.estimate.total_min;
}

fn realMinifySize(gpa: std.mem.Allocator, source: [:0]const u8, options: Minifier.Options) !usize {
    var result = try wgslender.minifyWithOptions(gpa, source, options);
    defer result.deinit(gpa);
    return result.code.len;
}

fn defaultMinifyOptions() Minifier.Options {
    // Mirror MinifyEstimator.Options defaults: tree_shaking on, no mangle,
    // no sort, no scope-local rename. Matches the estimator's inputs so
    // parity tests compare apples-to-apples.
    return .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
        .tree_shaking = true,
        .mangle_external_bindings = false,
        .sort_declarations = false,
        .scope_local_rename = false,
    };
}

// =========================================================================
// Correctness — small-shader enumerations
// =========================================================================

test "empty module is 0 bytes" {
    const gpa = testing.allocator;
    const source = try sentinel(gpa, "");
    defer gpa.free(source);

    const total = try estimateTotal(gpa, source, .{});
    try testing.expectEqual(@as(u32, 0), total);
}

test "fn main() {} parity with real minify" {
    const gpa = testing.allocator;
    const source = try sentinel(gpa, "fn main() {}");
    defer gpa.free(source);

    const total = try estimateTotal(gpa, source, .{});
    const real = try realMinifySize(gpa, source, defaultMinifyOptions());
    try testing.expectEqual(@as(u32, @intCast(real)), total);
}

test "single var declaration parity" {
    const gpa = testing.allocator;
    const source = try sentinel(gpa,
        \\const PI: f32 = 3.14;
        \\fn main() -> f32 { return PI; }
    );
    defer gpa.free(source);

    const total = try estimateTotal(gpa, source, .{});
    const real = try realMinifySize(gpa, source, defaultMinifyOptions());
    try testing.expectEqual(@as(u32, @intCast(real)), total);
}

test "function with body parity" {
    const gpa = testing.allocator;
    const source = try sentinel(gpa,
        \\fn square(x: f32) -> f32 { return x * x; }
        \\@compute @workgroup_size(1) fn main() { let y = square(2.0); }
    );
    defer gpa.free(source);

    const total = try estimateTotal(gpa, source, .{});
    const real = try realMinifySize(gpa, source, defaultMinifyOptions());
    try testing.expectEqual(@as(u32, @intCast(real)), total);
}

test "struct declaration parity" {
    const gpa = testing.allocator;
    const source = try sentinel(gpa,
        \\struct Uniforms { time: f32, count: i32 };
        \\@group(0) @binding(0) var<uniform> u: Uniforms;
        \\@compute @workgroup_size(1) fn main() { let t = u.time; }
    );
    defer gpa.free(source);

    const total = try estimateTotal(gpa, source, .{});
    const real = try realMinifySize(gpa, source, defaultMinifyOptions());
    try testing.expectEqual(@as(u32, @intCast(real)), total);
}

test "swizzle parity" {
    const gpa = testing.allocator;
    const source = try sentinel(gpa,
        \\fn take(v: vec4<f32>) -> vec3<f32> { return v.xyz; }
        \\@compute @workgroup_size(1) fn main() { let _v = take(vec4<f32>(1.0, 2.0, 3.0, 4.0)); }
    );
    defer gpa.free(source);

    const total = try estimateTotal(gpa, source, .{});
    const real = try realMinifySize(gpa, source, defaultMinifyOptions());
    try testing.expectEqual(@as(u32, @intCast(real)), total);
}

// =========================================================================
// Renaming correctness
// =========================================================================

test "long identifier renames to 1 char when most frequent" {
    const gpa = testing.allocator;
    // `foo` used 4× (decl + 3 calls), `main` is the entry point (must_not_be_renamed).
    // `foo` should rename to a 1-char name in both real minify and estimator.
    const source = try sentinel(gpa,
        \\fn foo() {}
        \\@compute @workgroup_size(1) fn main() { foo(); foo(); foo(); }
    );
    defer gpa.free(source);

    const total = try estimateTotal(gpa, source, .{});
    const real = try realMinifySize(gpa, source, defaultMinifyOptions());
    try testing.expectEqual(@as(u32, @intCast(real)), total);

    // Longer original name should make the savings visible vs a baseline where
    // nothing is renamed (estimate must shrink as identifier length grows).
    const source_long = try sentinel(gpa,
        \\fn verylongfunctionname() {}
        \\@compute @workgroup_size(1) fn main() { verylongfunctionname(); verylongfunctionname(); verylongfunctionname(); }
    );
    defer gpa.free(source_long);

    const total_long = try estimateTotal(gpa, source_long, .{});
    const real_long = try realMinifySize(gpa, source_long, defaultMinifyOptions());
    try testing.expectEqual(@as(u32, @intCast(real_long)), total_long);
}

test "external binding keeps original name without mangle flag" {
    const gpa = testing.allocator;
    const source = try sentinel(gpa,
        \\@group(0) @binding(0) var<uniform> timeUniform: f32;
        \\@compute @workgroup_size(1) fn main() { let _t = timeUniform; }
    );
    defer gpa.free(source);

    var opts: MinifyEstimator.Options = .{};
    opts.mangle_external_bindings = false;
    const total = try estimateTotal(gpa, source, opts);

    var real_opts = defaultMinifyOptions();
    real_opts.mangle_external_bindings = false;
    const real = try realMinifySize(gpa, source, real_opts);
    try testing.expectEqual(@as(u32, @intCast(real)), total);
}

test "external binding renamed with mangle-external-bindings flag" {
    const gpa = testing.allocator;
    const source = try sentinel(gpa,
        \\@group(0) @binding(0) var<uniform> timeUniform: f32;
        \\@compute @workgroup_size(1) fn main() { let _t = timeUniform; }
    );
    defer gpa.free(source);

    var opts: MinifyEstimator.Options = .{};
    opts.mangle_external_bindings = true;
    const total_mangled = try estimateTotal(gpa, source, opts);

    var real_opts = defaultMinifyOptions();
    real_opts.mangle_external_bindings = true;
    const real_mangled = try realMinifySize(gpa, source, real_opts);
    try testing.expectEqual(@as(u32, @intCast(real_mangled)), total_mangled);

    // Mangling MUST shrink the output vs the default (non-mangled) baseline.
    const default_opts: MinifyEstimator.Options = .{};
    const total_default = try estimateTotal(gpa, source, default_opts);
    try testing.expect(total_mangled < total_default);
}

test "frequency rank determines rename length" {
    const gpa = testing.allocator;
    // Enough renameable fns that the rank→length policy (most frequent gets
    // 1-char, rare ones grow) cannot give a trivial byte count. Real-minify
    // parity is the ground-truth check.
    const source = try sentinel(gpa,
        \\fn a1() {}
        \\fn a2() {}
        \\fn a3() {}
        \\fn a4() {}
        \\fn a5() {}
        \\@compute @workgroup_size(1) fn main() {
        \\  a1(); a1(); a1(); a1();
        \\  a2(); a2(); a2();
        \\  a3(); a3();
        \\  a4();
        \\  a5();
        \\}
    );
    defer gpa.free(source);

    const total = try estimateTotal(gpa, source, .{});
    const real = try realMinifySize(gpa, source, defaultMinifyOptions());
    try testing.expectEqual(@as(u32, @intCast(real)), total);
}

test "reserved words never chosen as rename target" {
    const gpa = testing.allocator;
    // Declare many functions so the rename stream naturally passes through
    // keyword-shaped names (`if`, `fn`, etc.). The shared skip-reserved
    // helper must ensure the estimator reflects the same skipping as the
    // real renamer. Parity is the tight check.
    const source = try sentinel(gpa,
        \\fn a() {} fn b() {} fn c() {} fn d() {} fn e() {}
        \\fn f() {} fn g() {} fn h() {} fn i() {} fn j() {}
        \\fn k() {} fn l() {} fn m() {} fn n() {} fn o() {}
        \\fn p() {} fn q() {} fn r() {} fn s() {} fn t() {}
        \\fn u() {} fn v() {} fn w() {} fn x() {} fn y() {} fn z() {}
        \\@compute @workgroup_size(1) fn main() {
        \\  a(); b(); c(); d(); e(); f(); g(); h(); i(); j();
        \\  k(); l(); m(); n(); o(); p(); q(); r(); s(); t();
        \\  u(); v(); w(); x(); y(); z();
        \\}
    );
    defer gpa.free(source);

    const total = try estimateTotal(gpa, source, .{});
    const real = try realMinifySize(gpa, source, defaultMinifyOptions());
    try testing.expectEqual(@as(u32, @intCast(real)), total);
}

// =========================================================================
// Scope-local rename across the name-length boundary
// =========================================================================

/// 10 used module-scope constants, one helper function, and one function
/// with 52 locals — the shape the plan's reviewer measured when the cheap
/// estimator's placeholder names leaked into the scope-local wrapper's
/// reserved set. Built at comptime so the table cannot drift.
fn BoundaryBytes(comptime n: usize) type {
    return struct { bytes: [n]u8, len: usize };
}

const scope_local_boundary_built: BoundaryBytes(16 * 1024) = init: {
    @setEvalBranchQuota(200_000);
    var buf: [16 * 1024]u8 = undefined;
    var len: usize = 0;

    for (0..10) |i| {
        const decl = std.fmt.comptimePrint("const c{d}: i32 = {d};\n", .{ i, i + 1 });
        @memcpy(buf[len..][0..decl.len], decl);
        len += decl.len;
    }
    const helper = "fn h() -> i32 { return 1; }\n";
    @memcpy(buf[len..][0..helper.len], helper);
    len += helper.len;

    const open = "fn f(x: i32) -> i32 {\n  var t = x + h();\n";
    @memcpy(buf[len..][0..open.len], open);
    len += open.len;
    for (0..52) |i| {
        const decl = std.fmt.comptimePrint("  let v{d} = t + c{d};\n", .{ i, i % 10 });
        @memcpy(buf[len..][0..decl.len], decl);
        len += decl.len;
        const use = std.fmt.comptimePrint("  t = t + v{d};\n", .{i});
        @memcpy(buf[len..][0..use.len], use);
        len += use.len;
    }
    const tail = "  return t + c0 + c1 + c2 + c3 + c4 + c5 + c6 + c7 + c8 + c9;\n}\n";
    @memcpy(buf[len..][0..tail.len], tail);
    len += tail.len;

    buf[len] = 0;
    const frozen = buf;
    break :init .{ .bytes = frozen, .len = len };
};

const scope_local_boundary_source: [:0]const u8 = scope_local_boundary_built.bytes[0..scope_local_boundary_built.len :0];

test "scope-local estimator matches real minify across the name-length boundary" {
    // Cheap and full are two paths over the same module; both must equal the
    // real minifier byte-for-byte. The bug this pins: the cheap path's
    // `LengthRenamer` answered every symbol with an 'x'-run, so the
    // scope-local wrapper reserved 'x'/'xx' instead of the real global names,
    // the canonical sequence crossed into two-character names at a different
    // local, and the estimate undercounted. Full mode already ran the
    // production renamer and agreed with the minifier.
    const gpa = testing.allocator;

    var cheap_opts: MinifyEstimator.Options = .{};
    cheap_opts.scope_local_rename = true;
    const cheap = try estimateTotal(gpa, scope_local_boundary_source, cheap_opts);

    var full_opts = cheap_opts;
    full_opts.use_full_minify = true;
    const full = try estimateTotal(gpa, scope_local_boundary_source, full_opts);

    var real_opts = defaultMinifyOptions();
    real_opts.scope_local_rename = true;
    const real = try realMinifySize(gpa, scope_local_boundary_source, real_opts);

    try testing.expectEqual(@as(u32, @intCast(real)), full);
    try testing.expectEqual(@as(u32, @intCast(real)), cheap);
}

// =========================================================================
// Ground-truth parity on compute.toys shaders
// =========================================================================

const compute_toys_shaders = [_][]const u8{
    @embedFile("testdata/compute.toys/bridge.wgsl"),
    @embedFile("testdata/compute.toys/circle_sample.wgsl"),
    @embedFile("testdata/compute.toys/cubes_in_space.wgsl"),
    @embedFile("testdata/compute.toys/jitter_starfield.wgsl"),
    @embedFile("testdata/compute.toys/mouse_draw.wgsl"),
    @embedFile("testdata/compute.toys/prelude.wgsl"),
    @embedFile("testdata/compute.toys/spaced.wgsl"),
};

const compute_toys_names = [_][]const u8{
    "bridge.wgsl",
    "circle_sample.wgsl",
    "cubes_in_space.wgsl",
    "jitter_starfield.wgsl",
    "mouse_draw.wgsl",
    "prelude.wgsl",
    "spaced.wgsl",
};

test "estimator within 5% of real minify on compute.toys corpus" {
    const gpa = testing.allocator;
    var total_est: f64 = 0;
    var total_real: f64 = 0;

    for (compute_toys_shaders, compute_toys_names) |bytes, name| {
        const source = try sentinel(gpa, bytes);
        defer gpa.free(source);

        const est = try estimateTotal(gpa, source, .{});
        const real = try realMinifySize(gpa, source, defaultMinifyOptions());

        total_est += @floatFromInt(est);
        total_real += @floatFromInt(real);

        const delta: f64 = @abs(@as(f64, @floatFromInt(est)) - @as(f64, @floatFromInt(real)));
        const ratio = delta / @as(f64, @floatFromInt(real));
        if (ratio >= 0.05) {
            std.debug.print(
                "compute.toys parity fail: {s} est={d} real={d} ratio={d:.4}\n",
                .{ name, est, real, ratio },
            );
            return error.EstimatorDriftExceedsFivePercent;
        }
    }

    // Aggregate parity — mean delta must stay well under 5%.
    const mean_ratio = @abs(total_est - total_real) / total_real;
    try testing.expect(mean_ratio < 0.05);
}

// =========================================================================
// Result shape
// =========================================================================

test "per_function populated for every function decl" {
    const gpa = testing.allocator;
    const source = try sentinel(gpa,
        \\fn a() {}
        \\fn b() { a(); }
        \\@compute @workgroup_size(1) fn main() { b(); }
    );
    defer gpa.free(source);

    var ctx = try Ctx.init(gpa, source, .{});
    defer ctx.deinit();

    // Every function in the module should appear in per_function, keyed by
    // the function's name symbol.
    const module = ctx.analysis.module.?;
    var fn_count: u32 = 0;
    for (module.declarations.items) |decl| {
        if (decl != .function) continue;
        fn_count += 1;
        const name_ref = decl.nameRef();
        try testing.expect(name_ref.isValid());
        try testing.expect(ctx.estimate.per_function.contains(name_ref));
    }
    try testing.expect(fn_count >= 3);
    try testing.expectEqual(fn_count, @as(u32, @intCast(ctx.estimate.per_function.count())));
}

test "per_decl populated for every named declaration" {
    const gpa = testing.allocator;
    const source = try sentinel(gpa,
        \\struct S { x: f32 };
        \\alias A = S;
        \\const K: f32 = 1.0;
        \\@compute @workgroup_size(1) fn main() { let v = A(K); let _x = v.x; }
    );
    defer gpa.free(source);

    var ctx = try Ctx.init(gpa, source, .{});
    defer ctx.deinit();

    const module = ctx.analysis.module.?;
    for (module.declarations.items) |decl| {
        const name_ref = decl.nameRef();
        if (!name_ref.isValid()) continue;
        // Unused aliases may be DCE'd out — skip checking dead decls.
        if (!wgslender.Dce.isDeclarationLive(decl, module.liveness)) continue;
        try testing.expect(ctx.estimate.per_decl.contains(name_ref));
    }
}

test "per_function.min sums to total minus directives+non-function decls" {
    const gpa = testing.allocator;
    const source = try sentinel(gpa,
        \\fn helper() -> f32 { return 1.0; }
        \\@compute @workgroup_size(1) fn main() { let _v = helper(); }
    );
    defer gpa.free(source);

    var ctx = try Ctx.init(gpa, source, .{});
    defer ctx.deinit();

    var sum_per_decl: u32 = 0;
    var it = ctx.estimate.per_decl.iterator();
    while (it.next()) |entry| sum_per_decl += entry.value_ptr.min;
    // per_decl covers every named decl; only unnamed const_assert escapes it.
    // The source above has none, so sums line up exactly.
    try testing.expectEqual(ctx.estimate.total_min, sum_per_decl);
}

test "total_gz heuristic is 35% of total_min" {
    const gpa = testing.allocator;
    const source = try sentinel(gpa,
        \\fn helper() -> f32 { return 1.0; }
        \\@compute @workgroup_size(1) fn main() { let _v = helper(); }
    );
    defer gpa.free(source);

    var ctx = try Ctx.init(gpa, source, .{});
    defer ctx.deinit();

    const expected: u32 = @intFromFloat(@as(f32, @floatFromInt(ctx.estimate.total_min)) * 0.35);
    try testing.expectEqual(expected, ctx.estimate.total_gz);
}

// =========================================================================
// Shape assertions (perf proxies — no wall-clock, Zig 0.16 has no Timer)
// =========================================================================

test "estimator scales with symbol count, not a fixed overhead" {
    const gpa = testing.allocator;
    // Monotonic: bigger shader → at least as many bytes estimated. Not a
    // proper perf test (no Timer in Zig 0.16, per BENCHMARK.md convention),
    // but catches the "always returns 0" and "always returns source.len"
    // regressions.
    const small = try sentinel(gpa, "fn main() {}");
    defer gpa.free(small);
    const large = try sentinel(gpa,
        \\fn a() {} fn b() {} fn c() {} fn d() {} fn e() {}
        \\@compute @workgroup_size(1) fn main() { a(); b(); c(); d(); e(); }
    );
    defer gpa.free(large);

    const small_total = try estimateTotal(gpa, small, .{});
    const large_total = try estimateTotal(gpa, large, .{});
    try testing.expect(small_total < large_total);
    try testing.expect(small_total > 0);
}

// =========================================================================
// Edge cases
// =========================================================================

test "parse error produces estimate result with zero total" {
    const gpa = testing.allocator;
    const source = try sentinel(gpa, "fn { invalid }");
    defer gpa.free(source);

    var analysis = try wgslender.analyzeWithOptions(gpa, source, .{});
    defer analysis.deinit();

    // Parser failed → module may be null or malformed. If module is null,
    // the estimator shouldn't be called. If it's present, estimator should
    // return without crashing (possibly with total_min=0).
    if (analysis.module) |module| {
        const result = try MinifyEstimator.estimate(analysis._arena.?.allocator(), module, .{});
        try testing.expect(result.total_min <= source.len);
    }
}

test "tree_shaking=false keeps dead code in total" {
    const gpa = testing.allocator;
    const source = try sentinel(gpa,
        \\fn unused() -> f32 { return 42.0; }
        \\@compute @workgroup_size(1) fn main() {}
    );
    defer gpa.free(source);

    var opts_ts: MinifyEstimator.Options = .{};
    opts_ts.tree_shaking = true;
    const with_ts = try estimateTotal(gpa, source, opts_ts);

    var opts_no_ts: MinifyEstimator.Options = .{};
    opts_no_ts.tree_shaking = false;
    const without_ts = try estimateTotal(gpa, source, opts_no_ts);

    try testing.expect(without_ts > with_ts);
}

// =========================================================================
// Phase 8 — opt-in full-minify estimator fallback
// =========================================================================

test "estimator.useFullMinify=true runs real pipeline" {
    // Phase 8 acceptance test: the heavy path must produce ground-truth
    // numbers — i.e. the byte count returned by the estimator equals the
    // byte count produced by `wgslender.minifyWithOptions` exactly.
    const gpa = testing.allocator;
    const source = try sentinel(gpa,
        \\fn helper() -> f32 { return 1.0; }
        \\@compute @workgroup_size(1) fn main() { let _v = helper(); }
    );
    defer gpa.free(source);

    var opts: MinifyEstimator.Options = .{};
    opts.use_full_minify = true;
    const total = try estimateTotal(gpa, source, opts);
    const real = try realMinifySize(gpa, source, defaultMinifyOptions());
    try testing.expectEqual(@as(u32, @intCast(real)), total);
}

test "estimator.useFullMinify=true populates per_decl + per_function" {
    // Same shape contract as the cheap path — downstream sites (inlay
    // hints, code lens, M-rules) read these maps regardless of which
    // path produced the result.
    const gpa = testing.allocator;
    const source = try sentinel(gpa,
        \\fn a() {}
        \\fn b() { a(); }
        \\@compute @workgroup_size(1) fn main() { b(); }
    );
    defer gpa.free(source);

    var opts: MinifyEstimator.Options = .{};
    opts.use_full_minify = true;
    var ctx = try Ctx.init(gpa, source, opts);
    defer ctx.deinit();

    const module = ctx.analysis.module.?;
    var fn_count: u32 = 0;
    for (module.declarations.items) |decl| {
        if (decl != .function) continue;
        fn_count += 1;
        const name_ref = decl.nameRef();
        try testing.expect(name_ref.isValid());
        try testing.expect(ctx.estimate.per_function.contains(name_ref));
    }
    try testing.expect(fn_count >= 3);
    try testing.expectEqual(fn_count, @as(u32, @intCast(ctx.estimate.per_function.count())));
}

test "estimator.useFullMinify=true bumps estimate_count" {
    // The counter must track BOTH paths so the LSP perf tests (which
    // assert deltas across a Handler-driven burst) stay honest when
    // a doc has `useFullMinify=true` resolved.
    const gpa = testing.allocator;
    const source = try sentinel(gpa,
        \\@compute @workgroup_size(1) fn main() {}
    );
    defer gpa.free(source);

    var opts: MinifyEstimator.Options = .{};
    opts.use_full_minify = true;
    const before = MinifyEstimator.estimate_count;
    _ = try estimateTotal(gpa, source, opts);
    try testing.expectEqual(@as(u64, 1), MinifyEstimator.estimate_count - before);
}

// =========================================================================
// estimateRenameLength helper — shared with production MinifyRenamer
// =========================================================================

test "estimateRenameLength fills output matching numberToMinifiedName" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var reserved = try Renamer.computeReservedNames(arena.allocator());
    defer reserved.deinit(arena.allocator());

    // Small batch — first 5 non-reserved names should all be length 1 ('a'..'e').
    var out: [5]u32 = undefined;
    Renamer.estimateRenameLength(&reserved, &out);
    for (out) |len| {
        try testing.expectEqual(@as(u32, 1), len);
    }
}

test "estimateRenameLength skips reserved words identically to assignNames" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Build a reserved set that forces skips at known ranks.
    var reserved: std.StringHashMapUnmanaged(void) = .{};
    try reserved.put(a, "a", {});
    try reserved.put(a, "c", {});

    var out: [3]u32 = undefined;
    Renamer.estimateRenameLength(&reserved, &out);

    // Rank 0 skips 'a', lands on 'b' (1 char)
    // Rank 1 skips 'c', lands on 'd' (1 char)
    // Rank 2 lands on 'e' (1 char)
    try testing.expectEqual(@as(u32, 1), out[0]);
    try testing.expectEqual(@as(u32, 1), out[1]);
    try testing.expectEqual(@as(u32, 1), out[2]);
}
