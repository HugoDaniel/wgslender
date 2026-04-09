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

    // Unit tests (src/)
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Snapshot tests (tests/)
    const snapshot_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/snapshot_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wgslender", .module = wgslender_mod },
            },
        }),
    });
    const run_snapshot_tests = b.addRunArtifact(snapshot_tests);

    // Validation test data module
    const validation_data_mod = b.addModule("validation_data", .{
        .root_source_file = b.path("tests/testdata_validation.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Validation tests (tests/)
    const validation_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/validation_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wgslender", .module = wgslender_mod },
                .{ .name = "validation_data", .module = validation_data_mod },
            },
        }),
    });
    const run_validation_tests = b.addRunArtifact(validation_tests);

    // Validation location tests (tests/)
    const validation_location_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/validation_location_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wgslender", .module = wgslender_mod },
            },
        }),
    });
    const run_validation_location_tests = b.addRunArtifact(validation_location_tests);

    // Validation related-info tests (tests/)
    const validation_related_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/validation_related_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wgslender", .module = wgslender_mod },
            },
        }),
    });
    const run_validation_related_tests = b.addRunArtifact(validation_related_tests);

    // Collision tests (tests/)
    const collision_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/collision_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wgslender", .module = wgslender_mod },
            },
        }),
    });
    const run_collision_tests = b.addRunArtifact(collision_tests);

    // Regression tests (tests/)
    const regression_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/regression_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wgslender", .module = wgslender_mod },
            },
        }),
    });
    const run_regression_tests = b.addRunArtifact(regression_tests);

    // Reflect tests (tests/)
    const reflect_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/reflect_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wgslender", .module = wgslender_mod },
            },
        }),
    });
    const run_reflect_tests = b.addRunArtifact(reflect_tests);

    // Semantic test data module
    const semantic_data_mod = b.addModule("semantic_data", .{
        .root_source_file = b.path("tests/testdata_semantic.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Compute.toys tests (tests/)
    const compute_toys_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/compute_toys_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wgslender", .module = wgslender_mod },
                .{ .name = "semantic_data", .module = semantic_data_mod },
            },
        }),
    });
    const run_compute_toys_tests = b.addRunArtifact(compute_toys_tests);

    // Semantic preservation tests (tests/)
    const semantic_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/semantic_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wgslender", .module = wgslender_mod },
                .{ .name = "semantic_data", .module = semantic_data_mod },
            },
        }),
    });
    const run_semantic_tests = b.addRunArtifact(semantic_tests);

    // Source map tests (tests/)
    const sourcemap_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/sourcemap_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wgslender", .module = wgslender_mod },
            },
        }),
    });
    const run_sourcemap_tests = b.addRunArtifact(sourcemap_tests);

    // Tint tests (tests/) — bulk semantic preservation test of ~1,445 real Tint shaders.
    // testdata/tint/ is optional: if absent the test prints a skip message and passes.
    const tint_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tint_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wgslender", .module = wgslender_mod },
            },
        }),
    });
    const run_tint_tests = b.addRunArtifact(tint_tests);

    const tint_step = b.step("tint-test", "Run Tint semantic preservation tests");
    tint_step.dependOn(&run_tint_tests.step);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_snapshot_tests.step);
    test_step.dependOn(&run_validation_tests.step);
    test_step.dependOn(&run_validation_location_tests.step);
    test_step.dependOn(&run_validation_related_tests.step);
    test_step.dependOn(&run_collision_tests.step);
    test_step.dependOn(&run_regression_tests.step);
    test_step.dependOn(&run_compute_toys_tests.step);
    test_step.dependOn(&run_reflect_tests.step);
    test_step.dependOn(&run_semantic_tests.step);
    test_step.dependOn(&run_sourcemap_tests.step);
    test_step.dependOn(&run_tint_tests.step);
}
