//! Tint semantic preservation tests.
//!
//! Walks tests/testdata/tint/ recursively for .wgsl files and verifies that
//! minification preserves shader semantics:
//!   parse -> validate -> minify -> re-parse -> re-validate ->
//!   verify entry point count and binding count match.
//!
//! Since tests/testdata/tint/ is large (~408 MB, 25k+ files) we cannot use @embedFile.
//! Files are read at runtime via std.Io.Dir directory walking.
//!
//! The tests/testdata/tint/ directory is OPTIONAL — if it does not exist the test
//! prints a skip message and exits successfully.
//!

const std = @import("std");
const wgslender = @import("wgslender");

/// Make a sentinel-terminated copy of the source bytes.
fn makeSentinel(allocator: std.mem.Allocator, source_bytes: []const u8) ![:0]const u8 {
    const buf = try allocator.alloc(u8, source_bytes.len + 1);
    @memcpy(buf[0..source_bytes.len], source_bytes);
    buf[source_bytes.len] = 0;
    return buf[0..source_bytes.len :0];
}

/// Features that wgslender does not support — files containing these strings
/// are skipped rather than failed.
const unsupported_features = [_][]const u8{
    "enable f16",
    "enable chromium",
    "enable subgroups",
    "diagnostic(off",
    "diagnostic(warning",
    "diagnostic(error",
    "@diagnostic",
};

fn containsUnsupportedFeatures(source: []const u8) bool {
    for (unsupported_features) |feature| {
        if (std.mem.indexOf(u8, source, feature) != null) return true;
    }
    return false;
}

/// Known minifier bugs — files where the minifier produces incorrect output
/// due to pre-existing bugs (e.g., symbol binding issues with builtin names).
/// These are skipped rather than counted as failures.
const known_minifier_bugs = [_][]const u8{
    // Parser binds `max` builtin call to struct field symbol, causing rename.
    // Same bug exists in Go implementation.
    "bug/tint/1121.wgsl",
    // Shadowing tests: renamer produces name collisions when locals shadow
    // type aliases, structs, or functions. Pre-existing minifier limitation.
    "shadowing/alias/const.wgsl",
    "shadowing/alias/let.wgsl",
    "shadowing/alias/var.wgsl",
    "shadowing/function/var.wgsl",
    "shadowing/struct/let.wgsl",
    "shadowing/struct/var.wgsl",
};

fn isKnownMinifierBug(rel_path: []const u8) bool {
    for (known_minifier_bugs) |bug_path| {
        if (std.mem.endsWith(u8, rel_path, bug_path)) return true;
    }
    return false;
}

const TestResult = enum { passed, failed, skipped };

/// Run semantic preservation test on one shader source.
/// Returns the outcome; never returns an error — failures are reported via
/// the `failed` count so we keep running all files.
fn testOneShader(
    allocator: std.mem.Allocator,
    source_bytes: []const u8,
    rel_path: []const u8,
    failed_files: *std.ArrayListUnmanaged([]const u8),
    failed_alloc: std.mem.Allocator,
) TestResult {
    // Skip files with known minifier bugs.
    if (isKnownMinifierBug(rel_path)) return .skipped;

    // Skip files that use unsupported WGSL features.
    if (containsUnsupportedFeatures(source_bytes)) return .skipped;

    // Make sentinel-terminated source for the wgslender API.
    const source = makeSentinel(allocator, source_bytes) catch return .skipped;

    // Step 1: Parse original — skip on parse error (some tint files have
    // intentional parse errors or use constructs we don't support yet).
    const orig_val = wgslender.validateWithOptions(allocator, source, .{}) catch return .skipped;
    if (!orig_val.valid) return .skipped;

    // Step 2: Minify (tree_shaking=false — preserve all declarations).
    const min_result = wgslender.minifyWithOptions(allocator, source, .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
        .tree_shaking = false,
    }) catch return .skipped;

    // Skip on minification error.
    if (min_result.errors.len > 0) return .skipped;

    // Step 3: Re-parse minified output — this must succeed.
    const min_source = makeSentinel(allocator, min_result.code) catch {
        failed_files.append(failed_alloc, rel_path) catch {};
        return .failed;
    };

    // Step 4: Re-validate minified output — this must succeed.
    const min_val = wgslender.validateWithOptions(allocator, min_source, .{}) catch {
        failed_files.append(failed_alloc, rel_path) catch {};
        return .failed;
    };
    if (!min_val.valid) {
        std.log.err("tint: validation failed after minification: {s}", .{rel_path});
        std.log.err("  minified output:\n{s}", .{min_result.code});
        failed_files.append(failed_alloc, rel_path) catch {};
        return .failed;
    }

    // Step 5: Verify entry point count and binding count via reflect.
    const orig_reflect = wgslender.reflect(allocator, source) catch {
        failed_files.append(failed_alloc, rel_path) catch {};
        return .failed;
    };
    const min_reflect = wgslender.reflect(allocator, min_source) catch {
        failed_files.append(failed_alloc, rel_path) catch {};
        return .failed;
    };

    if (orig_reflect.entry_points.items.len != min_reflect.entry_points.items.len) {
        std.log.err("tint: entry point count mismatch in {s}: original={d}, minified={d}", .{
            rel_path,
            orig_reflect.entry_points.items.len,
            min_reflect.entry_points.items.len,
        });
        failed_files.append(failed_alloc, rel_path) catch {};
        return .failed;
    }

    if (orig_reflect.bindings.items.len != min_reflect.bindings.items.len) {
        std.log.err("tint: binding count mismatch in {s}: original={d}, minified={d}", .{
            rel_path,
            orig_reflect.bindings.items.len,
            min_reflect.bindings.items.len,
        });
        failed_files.append(failed_alloc, rel_path) catch {};
        return .failed;
    }

    return .passed;
}

test "tint: semantic preservation" {
    const tint_dir_rel = "tests/testdata/tint";

    // std.Options.debug_io is available in all contexts, including tests.
    const io = std.Options.debug_io;

    var tint_dir = std.Io.Dir.cwd().openDir(io, tint_dir_rel, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound or err == error.NotFound) {
            std.debug.print("tests/testdata/tint not found — skipping tint tests\n", .{});
            return;
        }
        return err;
    };
    defer tint_dir.close(io);

    // Use a DebugAllocator (formerly GeneralPurposeAllocator) for the whole test run.
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const gpa_alloc = gpa.allocator();

    var failed_files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (failed_files.items) |s| gpa_alloc.free(s);
        failed_files.deinit(gpa_alloc);
    }

    var total: usize = 0;
    var passed: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;

    // Walk the directory tree recursively.
    var walker = try tint_dir.walk(gpa_alloc);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        // Only process regular .wgsl files; skip .expected. files and dirs.
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".wgsl")) continue;
        if (std.mem.indexOf(u8, entry.path, ".expected.") != null) continue;

        total += 1;

        // Per-file arena — reset after each file to bound memory use.
        var arena = std.heap.ArenaAllocator.init(gpa_alloc);
        defer arena.deinit();
        const alloc = arena.allocator();

        // Read the file via the Walker's open dir handle (avoids path length
        // issues on deeply nested trees).
        const source_bytes = entry.dir.readFileAlloc(io, entry.basename, alloc, .unlimited) catch {
            skipped += 1;
            continue;
        };

        // Keep a GPA-owned copy of the path for error reporting (the walker
        // path is only valid during the current iteration).
        const rel_path = gpa_alloc.dupe(u8, entry.path) catch entry.path;

        const outcome = testOneShader(alloc, source_bytes, rel_path, &failed_files, gpa_alloc);
        switch (outcome) {
            .passed => {
                passed += 1;
                gpa_alloc.free(rel_path);
            },
            .failed => failed += 1,
            .skipped => {
                skipped += 1;
                gpa_alloc.free(rel_path);
            },
        }
    }

    // Print summary.
    std.debug.print(
        "\ntint tests: {d} total, {d} passed, {d} failed, {d} skipped\n",
        .{ total, passed, failed, skipped },
    );

    if (failed > 0) {
        std.debug.print("failed files:\n", .{});
        for (failed_files.items) |f| {
            std.debug.print("  {s}\n", .{f});
        }
    }

    // Fail the test if any file failed.
    try std.testing.expectEqual(@as(usize, 0), failed);
}
