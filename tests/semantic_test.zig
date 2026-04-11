//! Semantic preservation tests.
//!
//! For every WGSL sample file: parse -> validate -> minify -> re-parse -> re-validate
//! -> verify entry point count and binding count are preserved.
//! These tests are REQUIRED to pass (not optional).
//!

const std = @import("std");
const wgslender = @import("wgslender");

// =========================================================================
// Test data — imported from project-root bridge module (testdata_semantic.zig)
// =========================================================================

const td = @import("semantic_data");

// Top-level testdata shaders
const example_wgsl = td.example;
const basic_vert_wgsl = td.basic_vert;
const sceneW_wgsl = td.sceneW;
const sceneE_wgsl = td.sceneE;
const sceneY_wgsl = td.sceneY;
const starsParticlesModule_wgsl = td.starsParticlesModule;
const trailing_comma_wgsl = td.trailing_comma_fn_params;
const blur_wgsl = td.blur;
const cornell_common_wgsl = td.cornell_common;
const fullscreen_quad_wgsl = td.fullscreen_quad;
const shadow_fragment_wgsl = td.shadow_fragment;

// compute.toys shaders
const ct_circle_sample_wgsl = td.ct_circle_sample;
const ct_bridge_wgsl = td.ct_bridge;
const ct_cubes_in_space_wgsl = td.ct_cubes_in_space;
const ct_jitter_starfield_wgsl = td.ct_jitter_starfield;
const ct_mouse_draw_wgsl = td.ct_mouse_draw;
const ct_prelude_wgsl = td.ct_prelude;
const ct_spaced_wgsl = td.ct_spaced;

// =========================================================================
// compute.toys keep_names config (same as compute_toys_test.zig)
// =========================================================================

const compute_toys_keep_names: []const []const u8 = &.{
    "time",                          "mouse",           "custom",    "dispatch",
    "screen",                        "pass_in",         "pass_out",  "channel0",
    "channel1",                      "nearest",         "bilinear",  "trilinear",
    "nearest_repeat",                "bilinear_repeat",  "trilinear_repeat",
    "_keyboard",                     "Time",            "Mouse",     "Custom",
    "DispatchInfo",                  "int",             "uint",      "float",
    "int2",                          "int3",            "int4",      "uint2",
    "uint3",                         "uint4",           "float2",    "float3",
    "float4",                        "bool2",           "bool3",     "bool4",
    "float2x2",                      "float2x3",        "float2x4",
    "float3x2",                      "float3x3",        "float3x4",
    "float4x2",                      "float4x3",        "float4x4",
    "keyDown",                       "assert",          "passStore", "passLoad",
    "passSampleLevelBilinearRepeat", "main_image",
};

// =========================================================================
// Helpers
// =========================================================================

/// Make a sentinel-terminated copy of the source bytes.
fn makeSentinel(allocator: std.mem.Allocator, source_bytes: []const u8) ![:0]const u8 {
    const buf = try allocator.alloc(u8, source_bytes.len + 1);
    @memcpy(buf[0..source_bytes.len], source_bytes);
    buf[source_bytes.len] = 0;
    return buf[0..source_bytes.len :0];
}

/// Full semantic preservation test for a shader that should validate.
/// parse -> validate original -> minify -> re-parse minified -> re-validate -> check properties.
fn testSemanticPreservation(allocator: std.mem.Allocator, source_bytes: []const u8) !void {
    const source = try makeSentinel(allocator, source_bytes);

    // 1. Parse + validate original
    const orig_val = try wgslender.validateWithOptions(allocator, source, .{});
    if (!orig_val.valid) return; // Skip shaders that don't validate

    // 2. Minify (no tree shaking — preserve all declarations)
    const result = try wgslender.minifyWithOptions(allocator, source, .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
        .tree_shaking = false,
    });

    // Check no minification errors
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);

    // 3. Re-parse + re-validate minified
    const min_source = try makeSentinel(allocator, result.code);
    const min_val = try wgslender.validateWithOptions(allocator, min_source, .{});
    if (!min_val.valid) {
        std.debug.print("\n=== Minified code that failed validation ===\n{s}\n===\n", .{result.code});
    }
    try std.testing.expect(min_val.valid);

    // 4. Verify preserved properties via reflect
    const orig_reflect = try wgslender.reflect(allocator, source);
    const min_reflect = try wgslender.reflect(allocator, min_source);

    // Entry point count must match
    try std.testing.expectEqual(orig_reflect.entry_points.items.len, min_reflect.entry_points.items.len);

    // Binding count must match
    try std.testing.expectEqual(orig_reflect.bindings.items.len, min_reflect.bindings.items.len);
}

/// Roundtrip stability test: parse -> print -> re-parse -> re-print; output must be identical.
fn testRoundtripStability(allocator: std.mem.Allocator, source_bytes: []const u8) !void {
    const source = try makeSentinel(allocator, source_bytes);

    // First pass: parse + print (whitespace only, no renaming)
    var tokens1 = try wgslender.Lexer.tokenize(allocator, source);
    _ = &tokens1;
    var parser1 = try wgslender.Parser.init(allocator, source, tokens1);
    const module1 = try parser1.parse();

    const RenamerMod = wgslender.Renamer;
    const noop1 = try allocator.create(RenamerMod.NoOpRenamer);
    noop1.* = RenamerMod.NoOpRenamer.init(module1.symbols.items);
    noop1.renamer.ptr = @ptrCast(noop1);

    var printer1 = wgslender.Printer.init(allocator, .{
        .minify_whitespace = false,
        .minify_identifiers = false,
        .minify_syntax = false,
        .tree_shaking = false,
        .renamer = &noop1.renamer,
    }, module1.symbols.items);
    const output1 = try printer1.print(module1);

    // Second pass: parse output1 + print again
    const output1_z = try makeSentinel(allocator, output1);
    var tokens2 = try wgslender.Lexer.tokenize(allocator, output1_z);
    _ = &tokens2;
    var parser2 = try wgslender.Parser.init(allocator, output1_z, tokens2);
    const module2 = try parser2.parse();

    const noop2 = try allocator.create(RenamerMod.NoOpRenamer);
    noop2.* = RenamerMod.NoOpRenamer.init(module2.symbols.items);
    noop2.renamer.ptr = @ptrCast(noop2);

    var printer2 = wgslender.Printer.init(allocator, .{
        .minify_whitespace = false,
        .minify_identifiers = false,
        .minify_syntax = false,
        .tree_shaking = false,
        .renamer = &noop2.renamer,
    }, module2.symbols.items);
    const output2 = try printer2.print(module2);

    // Outputs must be identical
    try std.testing.expectEqualStrings(output1, output2);
}

/// Size reduction test: verify minified output is smaller than original.
fn testSizeReduction(allocator: std.mem.Allocator, source_bytes: []const u8) !void {
    const source = try makeSentinel(allocator, source_bytes);

    const result = try wgslender.minifyWithOptions(allocator, source, .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
        .tree_shaking = false,
    });

    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
    try std.testing.expect(result.minified_size < result.original_size);
}

/// Test for compute.toys shaders: parse -> minify -> re-parse -> verify size reduction.
/// Does NOT validate since compute.toys shaders reference external prelude symbols.
fn testComputeToysShader(allocator: std.mem.Allocator, source_bytes: []const u8) !void {
    const source = try makeSentinel(allocator, source_bytes);

    const result = try wgslender.minifyWithOptions(allocator, source, .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
        .tree_shaking = true,
        .keep_names = compute_toys_keep_names,
    });

    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
    try std.testing.expect(result.minified_size < result.original_size);

    // Verify re-parse succeeds
    const min_source = try makeSentinel(allocator, result.code);
    var tokens = try wgslender.Lexer.tokenize(allocator, min_source);
    _ = &tokens;
    var parser = try wgslender.Parser.init(allocator, min_source, tokens);
    _ = try parser.parse();

    // Check required names are preserved
    if (std.mem.indexOf(u8, source_bytes, "main_image") != null) {
        try std.testing.expect(std.mem.indexOf(u8, result.code, "main_image") != null);
    }
    if (std.mem.indexOf(u8, source_bytes, "screen") != null) {
        try std.testing.expect(std.mem.indexOf(u8, result.code, "screen") != null);
    }
}

// =========================================================================
// Semantic preservation tests — top-level testdata shaders
// =========================================================================

test "semantic: example.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testSemanticPreservation(arena.allocator(), example_wgsl);
}

test "semantic: basic_vert.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testSemanticPreservation(arena.allocator(), basic_vert_wgsl);
}

test "semantic: sceneW.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testSemanticPreservation(arena.allocator(), sceneW_wgsl);
}

test "semantic: sceneE.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testSemanticPreservation(arena.allocator(), sceneE_wgsl);
}

test "semantic: sceneY.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testSemanticPreservation(arena.allocator(), sceneY_wgsl);
}

test "semantic: starsParticlesModule.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testSemanticPreservation(arena.allocator(), starsParticlesModule_wgsl);
}

test "semantic: trailing_comma_fn_params.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testSemanticPreservation(arena.allocator(), trailing_comma_wgsl);
}

test "semantic: blur.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testSemanticPreservation(arena.allocator(), blur_wgsl);
}

test "semantic: cornell_common.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testSemanticPreservation(arena.allocator(), cornell_common_wgsl);
}

test "semantic: fullscreen_quad.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testSemanticPreservation(arena.allocator(), fullscreen_quad_wgsl);
}

test "semantic: shadow_fragment.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testSemanticPreservation(arena.allocator(), shadow_fragment_wgsl);
}

// =========================================================================
// Roundtrip stability tests — parse -> print -> re-parse -> re-print
// =========================================================================

test "roundtrip: example.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testRoundtripStability(arena.allocator(), example_wgsl);
}

test "roundtrip: basic_vert.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testRoundtripStability(arena.allocator(), basic_vert_wgsl);
}

test "roundtrip: sceneW.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testRoundtripStability(arena.allocator(), sceneW_wgsl);
}

test "roundtrip: sceneE.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testRoundtripStability(arena.allocator(), sceneE_wgsl);
}

test "roundtrip: sceneY.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testRoundtripStability(arena.allocator(), sceneY_wgsl);
}

test "roundtrip: starsParticlesModule.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testRoundtripStability(arena.allocator(), starsParticlesModule_wgsl);
}

test "roundtrip: blur.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testRoundtripStability(arena.allocator(), blur_wgsl);
}

test "roundtrip: cornell_common.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testRoundtripStability(arena.allocator(), cornell_common_wgsl);
}

test "roundtrip: fullscreen_quad.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testRoundtripStability(arena.allocator(), fullscreen_quad_wgsl);
}

test "roundtrip: shadow_fragment.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testRoundtripStability(arena.allocator(), shadow_fragment_wgsl);
}

// =========================================================================
// Size reduction tests — verify minified < original
// =========================================================================

test "size reduction: example.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testSizeReduction(arena.allocator(), example_wgsl);
}

test "size reduction: basic_vert.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testSizeReduction(arena.allocator(), basic_vert_wgsl);
}

test "size reduction: sceneW.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testSizeReduction(arena.allocator(), sceneW_wgsl);
}

test "size reduction: sceneE.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testSizeReduction(arena.allocator(), sceneE_wgsl);
}

test "size reduction: sceneY.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testSizeReduction(arena.allocator(), sceneY_wgsl);
}

test "size reduction: starsParticlesModule.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testSizeReduction(arena.allocator(), starsParticlesModule_wgsl);
}

test "size reduction: blur.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testSizeReduction(arena.allocator(), blur_wgsl);
}

test "size reduction: cornell_common.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testSizeReduction(arena.allocator(), cornell_common_wgsl);
}

test "size reduction: fullscreen_quad.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testSizeReduction(arena.allocator(), fullscreen_quad_wgsl);
}

test "size reduction: shadow_fragment.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testSizeReduction(arena.allocator(), shadow_fragment_wgsl);
}

// =========================================================================
// compute.toys semantic tests — parse -> minify -> re-parse -> size check
// =========================================================================

test "compute.toys semantic: circle_sample.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testComputeToysShader(arena.allocator(), ct_circle_sample_wgsl);
}

test "compute.toys semantic: bridge.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testComputeToysShader(arena.allocator(), ct_bridge_wgsl);
}

test "compute.toys semantic: cubes_in_space.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testComputeToysShader(arena.allocator(), ct_cubes_in_space_wgsl);
}

test "compute.toys semantic: jitter_starfield.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testComputeToysShader(arena.allocator(), ct_jitter_starfield_wgsl);
}

test "compute.toys semantic: mouse_draw.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testComputeToysShader(arena.allocator(), ct_mouse_draw_wgsl);
}

test "compute.toys semantic: prelude.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testComputeToysShader(arena.allocator(), ct_prelude_wgsl);
}

test "compute.toys semantic: spaced.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testComputeToysShader(arena.allocator(), ct_spaced_wgsl);
}

// =========================================================================
// Entry point name preservation tests
// =========================================================================

fn testPreservesEntryPointNames(allocator: std.mem.Allocator, source_bytes: []const u8, entry_points: []const []const u8) !void {
    const source = try makeSentinel(allocator, source_bytes);
    const result = try wgslender.minifyWithOptions(allocator, source, .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
        .tree_shaking = false,
    });
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
    for (entry_points) |ep| {
        // Check for "fn <name>" in minified output
        var found = false;
        var i: usize = 0;
        while (i + 3 + ep.len <= result.code.len) : (i += 1) {
            if (std.mem.startsWith(u8, result.code[i..], "fn ")) {
                if (i + 3 + ep.len <= result.code.len and std.mem.eql(u8, result.code[i + 3 ..][0..ep.len], ep)) {
                    found = true;
                    break;
                }
            }
        }
        if (!found) {
            std.debug.print("entry point '{s}' not found in minified output\n", .{ep});
            return error.TestUnexpectedResult;
        }
    }
}

test "preserves entry points: example.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testPreservesEntryPointNames(arena.allocator(), example_wgsl, &.{ "vertexMain", "fragmentMain", "computeMain" });
}

test "preserves entry points: basic_vert.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testPreservesEntryPointNames(arena.allocator(), basic_vert_wgsl, &.{"main"});
}

test "preserves entry points: fullscreen_quad.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testPreservesEntryPointNames(arena.allocator(), fullscreen_quad_wgsl, &.{ "vert_main", "frag_main" });
}

test "preserves entry points: shadow_fragment.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testPreservesEntryPointNames(arena.allocator(), shadow_fragment_wgsl, &.{"main"});
}

// =========================================================================
// Binding count preservation tests
// =========================================================================

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) {
        if (std.mem.eql(u8, haystack[i..][0..needle.len], needle)) {
            n += 1;
            i += needle.len;
        } else {
            i += 1;
        }
    }
    return n;
}

fn testPreservesBindingCount(allocator: std.mem.Allocator, source_bytes: []const u8) !void {
    const source = try makeSentinel(allocator, source_bytes);
    const result = try wgslender.minifyWithOptions(allocator, source, .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
        .tree_shaking = false,
    });
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
    const source_bindings = countOccurrences(source_bytes, "@binding");
    const minified_bindings = countOccurrences(result.code, "@binding");
    try std.testing.expectEqual(source_bindings, minified_bindings);
    const source_groups = countOccurrences(source_bytes, "@group");
    const minified_groups = countOccurrences(result.code, "@group");
    try std.testing.expectEqual(source_groups, minified_groups);
}

test "preserves bindings: example.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testPreservesBindingCount(arena.allocator(), example_wgsl);
}

test "preserves bindings: basic_vert.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testPreservesBindingCount(arena.allocator(), basic_vert_wgsl);
}

test "preserves bindings: fullscreen_quad.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testPreservesBindingCount(arena.allocator(), fullscreen_quad_wgsl);
}

test "preserves bindings: shadow_fragment.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testPreservesBindingCount(arena.allocator(), shadow_fragment_wgsl);
}

// =========================================================================
// Builtin count preservation tests
// =========================================================================

fn testPreservesBuiltinCount(allocator: std.mem.Allocator, source_bytes: []const u8) !void {
    const source = try makeSentinel(allocator, source_bytes);
    const result = try wgslender.minifyWithOptions(allocator, source, .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
        .tree_shaking = false,
    });
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
    const source_builtins = countOccurrences(source_bytes, "@builtin");
    const minified_builtins = countOccurrences(result.code, "@builtin");
    try std.testing.expectEqual(source_builtins, minified_builtins);
}

test "preserves builtins: basic_vert.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testPreservesBuiltinCount(arena.allocator(), basic_vert_wgsl);
}

test "preserves builtins: fullscreen_quad.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testPreservesBuiltinCount(arena.allocator(), fullscreen_quad_wgsl);
}

test "preserves builtins: blur.wgsl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testPreservesBuiltinCount(arena.allocator(), blur_wgsl);
}
