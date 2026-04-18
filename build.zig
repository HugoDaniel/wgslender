//! Zig build script for wgslender.
//!
//! Produces native CLI, WASM binary, C static library, and LSP server.
//! Requires Zig 0.16.x or newer.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.zig_version.major != 0 or builtin.zig_version.minor < 16) {
        @compileError("wgslender requires Zig 0.16.x or newer");
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Core library module
    const wgslender_mod = b.addModule("wgslender", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Native CLI
    const exe = b.addExecutable(.{
        .name = "wgslender",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wgslender", .module = wgslender_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the wgslender CLI");
    run_step.dependOn(&run_cmd.step);

    // WASM build
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm = b.addExecutable(.{
        .name = "wgslender",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;

    const install_wasm = b.addInstallArtifact(wasm, .{});
    const wasm_step = b.step("wasm", "Build WASM binary");
    wasm_step.dependOn(&install_wasm.step);

    // C static library
    const lib = b.addLibrary(.{
        .name = "wgslender",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const install_lib = b.addInstallArtifact(lib, .{});
    const install_header = b.addInstallFile(b.path("include/wgslender.h"), "include/wgslender.h");
    const lib_step = b.step("lib", "Build C static library (libwgslender.a)");
    lib_step.dependOn(&install_lib.step);
    lib_step.dependOn(&install_header.step);

    // LSP server (native)
    const lsp_kit_dep = b.dependency("lsp_kit", .{
        .target = target,
        .optimize = optimize,
    });
    const lsp_mod = lsp_kit_dep.module("lsp");

    const lsp_exe = b.addExecutable(.{
        .name = "wgslender-lsp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("lsp/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wgslender", .module = wgslender_mod },
                .{ .name = "lsp", .module = lsp_mod },
            },
        }),
    });

    const install_lsp = b.addInstallArtifact(lsp_exe, .{});
    const lsp_step = b.step("lsp", "Build the WGSL LSP server");
    lsp_step.dependOn(&install_lsp.step);

    // LSP server (WASM)
    const lsp_wasm = b.addExecutable(.{
        .name = "wgslender-lsp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("lsp/wasm.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .imports = &.{
                .{ .name = "wgslender", .module = b.addModule("wgslender-wasm", .{
                    .root_source_file = b.path("src/root.zig"),
                    .target = wasm_target,
                    .optimize = .ReleaseSmall,
                }) },
            },
        }),
    });
    lsp_wasm.entry = .disabled;
    lsp_wasm.rdynamic = true;

    const install_lsp_wasm = b.addInstallArtifact(lsp_wasm, .{});
    const lsp_wasm_step = b.step("lsp-wasm", "Build the WGSL LSP WASM module");
    lsp_wasm_step.dependOn(&install_lsp_wasm.step);

    // Test data modules
    const validation_data_mod = b.addModule("validation_data", .{
        .root_source_file = b.path("tests/testdata_validation.zig"),
        .target = target,
        .optimize = optimize,
    });
    const semantic_data_mod = b.addModule("semantic_data", .{
        .root_source_file = b.path("tests/testdata_semantic.zig"),
        .target = target,
        .optimize = optimize,
    });
    const handler_mod = b.addModule("Handler", .{
        .root_source_file = b.path("lsp/Handler.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "wgslender", .module = wgslender_mod },
        },
    });

    const test_step = b.step("test", "Run all tests");
    const w: std.Build.Module.Import = .{ .name = "wgslender", .module = wgslender_mod };

    // Unit tests (src/)
    _ = addTestStep(b, test_step, "src/root.zig", target, optimize, &.{});
    // Snapshot tests
    _ = addTestStep(b, test_step, "tests/snapshot_test.zig", target, optimize, &.{w});
    // Validation tests
    _ = addTestStep(b, test_step, "tests/validation_test.zig", target, optimize, &.{ w, .{ .name = "validation_data", .module = validation_data_mod } });
    _ = addTestStep(b, test_step, "tests/validation_location_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/validation_related_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/validation_range_test.zig", target, optimize, &.{w});
    // Collision tests
    _ = addTestStep(b, test_step, "tests/collision_test.zig", target, optimize, &.{w});
    // Regression tests
    _ = addTestStep(b, test_step, "tests/regression_test.zig", target, optimize, &.{w});
    // Reflect tests
    _ = addTestStep(b, test_step, "tests/reflect_test.zig", target, optimize, &.{w});
    // Edits tests — library-level rename / text edit primitives
    _ = addTestStep(b, test_step, "tests/edits_test.zig", target, optimize, &.{w});
    // StableId tests — reparse-stable symbol identifiers
    _ = addTestStep(b, test_step, "tests/stable_id_test.zig", target, optimize, &.{w});
    // Semantic tests
    const sd: std.Build.Module.Import = .{ .name = "semantic_data", .module = semantic_data_mod };
    _ = addTestStep(b, test_step, "tests/compute_toys_test.zig", target, optimize, &.{ w, sd });
    _ = addTestStep(b, test_step, "tests/semantic_test.zig", target, optimize, &.{ w, sd });
    // Source map tests
    _ = addTestStep(b, test_step, "tests/sourcemap_test.zig", target, optimize, &.{w});
    // Tint tests — bulk semantic preservation test of ~1,445 real Tint shaders.
    // testdata/tint/ is optional: if absent the test prints a skip message and passes.
    const run_tint_tests = addTestStep(b, test_step, "tests/tint_test.zig", target, optimize, &.{w});
    const tint_step = b.step("tint-test", "Run Tint semantic preservation tests");
    tint_step.dependOn(run_tint_tests);
    // LSP Handler tests
    _ = addTestStep(b, test_step, "lsp/Handler.zig", target, optimize, &.{w});
    // Code action integration tests
    _ = addTestStep(b, test_step, "tests/code_action_test.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    // Node-at-position tests
    _ = addTestStep(b, test_step, "tests/node_at_position_test.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    // LSP feature tests
    _ = addTestStep(b, test_step, "tests/hover_test.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    _ = addTestStep(b, test_step, "tests/definition_test.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    _ = addTestStep(b, test_step, "tests/references_test.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    _ = addTestStep(b, test_step, "tests/document_highlight_test.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    _ = addTestStep(b, test_step, "tests/rename_test.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    _ = addTestStep(b, test_step, "tests/completion_test.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    _ = addTestStep(b, test_step, "tests/signature_help_test.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    _ = addTestStep(b, test_step, "tests/document_symbols_test.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    _ = addTestStep(b, test_step, "tests/folding_test.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    _ = addTestStep(b, test_step, "tests/type_definition_test.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    _ = addTestStep(b, test_step, "tests/inlay_hints_test.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    _ = addTestStep(b, test_step, "tests/unused_warnings_test.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    _ = addTestStep(b, test_step, "tests/code_lens_test.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    _ = addTestStep(b, test_step, "tests/incremental_sync_test.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    _ = addTestStep(b, test_step, "tests/formatting_test.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    _ = addTestStep(b, test_step, "tests/semantic_tokens_test.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    _ = addTestStep(b, test_step, "tests/selection_range_test.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    _ = addTestStep(b, test_step, "tests/call_hierarchy_test.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    // OOM exhaustive tests
    _ = addTestStep(b, test_step, "tests/oom_test.zig", target, optimize, &.{w});
    // Fuzz tests
    _ = addTestStep(b, test_step, "tests/fuzz_test.zig", target, optimize, &.{w});
    // Determinism tests
    _ = addTestStep(b, test_step, "tests/determinism_test.zig", target, optimize, &.{w});
}

fn addTestStep(
    b: *std.Build,
    test_step: *std.Build.Step,
    source: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imports: []const std.Build.Module.Import,
) *std.Build.Step {
    const t = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
    const run = b.addRunArtifact(t);
    test_step.dependOn(&run.step);
    return &run.step;
}
