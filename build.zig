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

    // Handler and bridge modules (registered here so both the LSP
    // executable and the test files can depend on them by name). The
    // bridge module translates `Handler.LspDiagnostic` to the lsp-kit
    // JSON-shaped `lsp.types.Diagnostic` used by publishDiagnostics.
    const handler_mod = b.addModule("Handler", .{
        .root_source_file = b.path("lsp/Handler.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "wgslender", .module = wgslender_mod },
        },
    });
    const bridge_mod = b.addModule("bridge", .{
        .root_source_file = b.path("lsp/bridge.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lsp", .module = lsp_mod },
            .{ .name = "Handler", .module = handler_mod },
        },
    });

    const lsp_exe = b.addExecutable(.{
        .name = "wgslender-lsp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("lsp/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wgslender", .module = wgslender_mod },
                .{ .name = "lsp", .module = lsp_mod },
                .{ .name = "Handler", .module = handler_mod },
                .{ .name = "bridge", .module = bridge_mod },
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
    // `handler_mod` and `bridge_mod` are defined above, adjacent to the
    // LSP executable so both binary and tests share the same module graph.

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
    _ = addTestStep(b, test_step, "tests/validation_spec_ref_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/validation_suggestions_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/lint_warnings_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/validation_dedup_test.zig", target, optimize, &.{ w, .{ .name = "validation_data", .module = validation_data_mod } });
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
    // Declaration / type span tests — spans on AST, removeDeclarationEdit,
    // changeTypeEdit, locateDeclaration, locateType.
    _ = addTestStep(b, test_step, "tests/decl_span_test.zig", target, optimize, &.{w});
    // Incremental.reparse — bulk corpus over compute.toys + composition.
    _ = addTestStep(b, test_step, "tests/incremental_corpus_test.zig", target, optimize, &.{w});
    // Incremental.reparse — corpus × mutation-section add/sub coverage
    // with per-symbol use_count oracle (complements the aggregate-sum
    // I-01 in incremental_corpus_test.zig).
    _ = addTestStep(b, test_step, "tests/incremental_corpus_addsub_test.zig", target, optimize, &.{w});
    // Non-gating perf smoke for the Phase 2 compound_stmt hot path. Reports
    // a speedup ratio over parseFull on bridge.wgsl and asserts a loose
    // floor so regressions surface in CI logs.
    _ = addTestStep(b, test_step, "tests/lsp_incremental_compound_perf_test.zig", target, optimize, &.{w});
    // AstVisit `.add` / `.sub` mode unit tests — exercises the subtree
    // entry points in isolation from the Incremental driver.
    _ = addTestStep(b, test_step, "tests/astvisit_mode_test.zig", target, optimize, &.{w});
    // Incremental.reparse — end-to-end add/sub delta scenarios covering
    // per-symbol use_count invariants across a range of symbol-free
    // anchor kinds and round-trip edit sequences.
    _ = addTestStep(b, test_step, "tests/incremental_addsub_test.zig", target, optimize, &.{w});
    // Incremental.reparse — symbol-free hot-path unit tests.
    _ = addTestStep(b, test_step, "tests/incremental_mutation_test.zig", target, optimize, &.{w});
    // Incremental.reparse — shared sentinel stub arena identity /
    // deinit-safety contract across every hot-path return.
    _ = addTestStep(b, test_step, "tests/incremental_stub_sentinel_test.zig", target, optimize, &.{w});
    // Incremental.reparse — moved-from state contract: hot paths flip
    // `prev.moved = true`, fallbacks don't, and a second `reparse` on a
    // moved prev returns `error.PrevAlreadyMoved`.
    _ = addTestStep(b, test_step, "tests/incremental_moved_guard_test.zig", target, optimize, &.{w});
    // Incremental.reparse — hot-path targeted fuzz / property tests.
    _ = addTestStep(b, test_step, "tests/incremental_mutation_fuzz_test.zig", target, optimize, &.{w});
    // Incremental.reparse — long-tail edge cases (unicode, CRLF, token
    // tag flips, comment-break / comment-close, boundary edits, …).
    _ = addTestStep(b, test_step, "tests/incremental_longtail_test.zig", target, optimize, &.{w});
    // Incremental.reparse — long-tail mutation scenarios (M1–M8): attribute
    // args, type-expr fallback, for/switch/if/while compartments, member &
    // call chains, and mixed-anchor churn / retained_arenas growth.
    _ = addTestStep(b, test_step, "tests/incremental_mutation_longtail_test.zig", target, optimize, &.{w});
    // Incremental.reparse — error-list fixup across the splice (drop entries
    // inside the old anchor, shift downstream by delta, append add-walk
    // E0102s) verified against a parseFull oracle on the new source.
    _ = addTestStep(b, test_step, "tests/incremental_error_fixup_test.zig", target, optimize, &.{w});
    // Per-decl `interior_pending` bias mechanism — bias state assertions,
    // burst amortization, and reader absorption contracts.
    _ = addTestStep(b, test_step, "tests/incremental_interior_pending_test.zig", target, optimize, &.{w});
    // CST round-trip — concat of every leaf token equals source, on
    // handcrafted edge cases and the compute.toys corpus.
    _ = addTestStep(b, test_step, "tests/cst_roundtrip_test.zig", target, optimize, &.{w});
    // CST shape snapshots — S-expression assertions on grammar-ambiguity
    // cases (templates vs comparisons, attribute-with-call, parse recovery).
    _ = addTestStep(b, test_step, "tests/cst_shape_test.zig", target, optimize, &.{w});
    // CST subtree splice unit tests — asserts spliceSubtree produces a
    // structurally identical tree to a full parse of the edited source.
    _ = addTestStep(b, test_step, "tests/cst_splice_test.zig", target, optimize, &.{w});
    // Property-based fuzz for Incremental.reparse — random edits must
    // produce the same AST / source as parseFull on the spliced source.
    _ = addTestStep(b, test_step, "tests/incremental_fuzz_test.zig", target, optimize, &.{w});
    // CstLower equivalence — Parser.parse vs CstLower.lowerTree on every
    // test shader. Proves Stage 4's lowering path produces an identical
    // Ast.Module (including use_count parity from shared Pass 2).
    _ = addTestStep(b, test_step, "tests/cst_lower_test.zig", target, optimize, &.{w});
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
    // LSP-driven analysis cache + wiring tests: every scenario drives
    // openDocument → changeDocumentIncremental → analyzeDocument and
    // cross-checks diagnostics against a fresh analyzeWithOptions oracle
    // on the document's current source (the strongest consistency check
    // for the incremental wiring).
    _ = addTestStep(b, test_step, "tests/lsp_analysis_cache_test.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    // End-to-end publishDiagnostics JSON payload tests — drive WGSL
    // sources through validateDocument + bridge + writeNotification and
    // assert the serialized code / codeDescription.href / relatedInformation
    // shape every editor consumes.
    _ = addTestStep(b, test_step, "tests/lsp_publish_diagnostics_test.zig", target, optimize, &.{
        w,
        .{ .name = "Handler", .module = handler_mod },
        .{ .name = "bridge", .module = bridge_mod },
        .{ .name = "lsp", .module = lsp_mod },
    });
    // End-to-end tests for the pull-mode `textDocument/diagnostic`
    // response (LSP 3.17) — drives `bridge.buildPullReport` + `lsp.writeResponse`.
    _ = addTestStep(b, test_step, "tests/lsp_pull_diagnostic_test.zig", target, optimize, &.{
        w,
        .{ .name = "Handler", .module = handler_mod },
        .{ .name = "bridge", .module = bridge_mod },
        .{ .name = "lsp", .module = lsp_mod },
    });
    // Unit tests for the shared WASM diagnostic-items JSON encoder.
    // Tested as its own root module so `@import("Handler.zig")` resolves
    // locally (matches how `lsp/wasm.zig` consumes it at build time).
    _ = addTestStep(b, test_step, "lsp/diagnostic_json.zig", target, optimize, &.{w});
    // LSP analyze perf smoke: records Lexer.tokenize invocations
    // across a 200-keystroke burst against bridge.wgsl. Enforces a
    // generous upper bound so a reintroduced tokenize path in
    // analyzeDocument surfaces before it ships.
    _ = addTestStep(b, test_step, "tests/lsp_analyze_perf_test.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    // `textDocument/didSave` wiring — handler must be source-preserving
    // and cache-preserving.
    _ = addTestStep(b, test_step, "tests/lsp_did_save_test.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    // `workspace/configuration` + `workspace/didChangeConfiguration`
    // settings merge semantics and inlay-hint gating.
    _ = addTestStep(b, test_step, "tests/lsp_configuration_test.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
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
    // Inference tests (spec §8.2 rank table, and future inference surface).
    _ = addTestStep(b, test_step, "tests/inference/conversion_rank_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/inference/const_classification_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/inference/overload_same_as_arg_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/inference/overload_mixed_args_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/inference/template_inference_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/inference/operator_types_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/inference/struct_return_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/inference/swizzle_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/inference/pointer_reference_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/inference/bitcast_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/inference/math_builtins_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/inference/texture_overload_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/inference/abstract_promotion_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/inference/expr_types_coverage_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/inference/expectation_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/inference/literal_range_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/inference/load_rule_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/inference/overload_engine_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/inference/overload_phase2_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/inference/overload_phase3c_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/inference/overload_phase3d_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/inference/sig_shape_invariant_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/inference/builtin_rejection_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/inference/named_edge_cases_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/inference_corpus_pinning_test.zig", target, optimize, &.{w});
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
