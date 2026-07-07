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

    // LSP server (native). lsp_kit is marked `.lazy = true`, so it's only
    // fetched when a step that actually needs it is in the build graph
    // (lsp / lsp-wasm / test). If it hasn't been fetched yet, skip the
    // LSP graph — Zig will re-invoke build() after the fetch completes.
    const lsp_kit_dep = b.lazyDependency("lsp_kit", .{
        .target = target,
        .optimize = optimize,
    }) orelse return;
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
    // Per-feature native adapters live under lsp/native/. Each one takes
    // a `*Handler` + per-call arena and converts between `Handler` types
    // and `lsp.types.*`. NativeServer keeps the lifecycle / mutex / timer
    // and delegates the per-method body to these. The `lspkit` module
    // (rooted at lsp/lspkit_root.zig) aggregates the shared codec tree —
    // primitives + per-feature shape conversions — so each adapter
    // imports it once and reaches helpers as `lspkit.primitives.*` etc.
    const lspkit_mod = b.addModule("lspkit", .{
        .root_source_file = b.path("lsp/lspkit_root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lsp", .module = lsp_mod },
            .{ .name = "Handler", .module = handler_mod },
            .{ .name = "wgslender", .module = wgslender_mod },
        },
    });
    // Native-target wire codec tree — manual-JSON encoders shared with the
    // WASM transport. Native side uses these for the diagnostic-corruption
    // regression test and the parity harness.
    const wire_mod = b.addModule("wire", .{
        .root_source_file = b.path("lsp/wire_root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "Handler", .module = handler_mod },
            .{ .name = "wgslender", .module = wgslender_mod },
        },
    });
    // The `bridge` alias keeps existing test imports working; the file it
    // points to is now a thin shim over `lspkit/diagnostics.zig`.
    const bridge_mod = b.addModule("bridge", .{
        .root_source_file = b.path("lsp/native/diagnostics.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lsp", .module = lsp_mod },
            .{ .name = "Handler", .module = handler_mod },
            .{ .name = "lspkit", .module = lspkit_mod },
        },
    });
    const native_code_actions_mod = b.addModule("native_code_actions", .{
        .root_source_file = b.path("lsp/native/code_actions.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lsp", .module = lsp_mod },
            .{ .name = "Handler", .module = handler_mod },
            .{ .name = "lspkit", .module = lspkit_mod },
        },
    });
    const native_document_sync_mod = b.addModule("native_document_sync", .{
        .root_source_file = b.path("lsp/native/document_sync.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lsp", .module = lsp_mod },
            .{ .name = "Handler", .module = handler_mod },
        },
    });
    const native_lifecycle_mod = b.addModule("native_lifecycle", .{
        .root_source_file = b.path("lsp/native/lifecycle.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lsp", .module = lsp_mod },
        },
    });
    const native_navigation_mod = b.addModule("native_navigation", .{
        .root_source_file = b.path("lsp/native/navigation.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lsp", .module = lsp_mod },
            .{ .name = "Handler", .module = handler_mod },
            .{ .name = "lspkit", .module = lspkit_mod },
        },
    });
    const native_symbols_mod = b.addModule("native_symbols", .{
        .root_source_file = b.path("lsp/native/symbols.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lsp", .module = lsp_mod },
            .{ .name = "Handler", .module = handler_mod },
            .{ .name = "lspkit", .module = lspkit_mod },
        },
    });
    const native_editing_mod = b.addModule("native_editing", .{
        .root_source_file = b.path("lsp/native/editing.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lsp", .module = lsp_mod },
            .{ .name = "Handler", .module = handler_mod },
            .{ .name = "lspkit", .module = lspkit_mod },
        },
    });
    const native_call_hierarchy_mod = b.addModule("native_call_hierarchy", .{
        .root_source_file = b.path("lsp/native/call_hierarchy.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lsp", .module = lsp_mod },
            .{ .name = "Handler", .module = handler_mod },
            .{ .name = "lspkit", .module = lspkit_mod },
        },
    });
    const native_workspace_commands_mod = b.addModule("native_workspace_commands", .{
        .root_source_file = b.path("lsp/native/workspace_commands.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lsp", .module = lsp_mod },
            .{ .name = "wgslender", .module = wgslender_mod },
            .{ .name = "Handler", .module = handler_mod },
            .{ .name = "lspkit", .module = lspkit_mod },
        },
    });

    // Native-target build of the WASM workspace handlers, used by the
    // workspace-error parity test to drive `handleExecuteCommand` /
    // `handleReflect` directly. The wasm/*.zig source has no
    // wasm-specific intrinsics, so it compiles cleanly for the native
    // target. Sibling `lifecycle.zig` / `diagnostics.zig` are reached
    // via `@import("foo.zig")` and become sub-graph nodes of this
    // module — the test reflects on the field type to construct a
    // matching lifecycle Ctx.
    const wasm_workspace_commands_mod = b.addModule("wasm_workspace_commands", .{
        .root_source_file = b.path("lsp/wasm/workspace_commands.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "Handler", .module = handler_mod },
            .{ .name = "wgslender", .module = wgslender_mod },
            .{ .name = "wire", .module = wire_mod },
        },
    });

    // NativeServer dispatcher — extracted from main.zig so the Phase 7
    // perf tests can drive the timer-thread + debouncer integration
    // without spawning a real stdio LSP.
    const native_server_mod = b.addModule("NativeServer", .{
        .root_source_file = b.path("lsp/NativeServer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lsp", .module = lsp_mod },
            .{ .name = "wgslender", .module = wgslender_mod },
            .{ .name = "Handler", .module = handler_mod },
            .{ .name = "bridge", .module = bridge_mod },
            .{ .name = "native_code_actions", .module = native_code_actions_mod },
            .{ .name = "native_document_sync", .module = native_document_sync_mod },
            .{ .name = "native_lifecycle", .module = native_lifecycle_mod },
            .{ .name = "native_navigation", .module = native_navigation_mod },
            .{ .name = "native_symbols", .module = native_symbols_mod },
            .{ .name = "native_editing", .module = native_editing_mod },
            .{ .name = "native_call_hierarchy", .module = native_call_hierarchy_mod },
            .{ .name = "native_workspace_commands", .module = native_workspace_commands_mod },
        },
    });

    const lsp_exe = b.addExecutable(.{
        .name = "wgslender-lsp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("lsp/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lsp", .module = lsp_mod },
                .{ .name = "NativeServer", .module = native_server_mod },
            },
        }),
    });

    const install_lsp = b.addInstallArtifact(lsp_exe, .{});
    const lsp_step = b.step("lsp", "Build the WGSL LSP server");
    lsp_step.dependOn(&install_lsp.step);

    // LSP server (WASM)
    const wgslender_wasm_mod = b.addModule("wgslender-wasm", .{
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    // Wasm-target Handler module — referenced by `lsp/wasm/<feature>.zig`
    // adapters via `@import("Handler")` so they don't need cross-directory
    // relative imports (Zig forbids `../` reaches outside a test module's
    // root path).
    const handler_wasm_mod = b.addModule("Handler-wasm", .{
        .root_source_file = b.path("lsp/Handler.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "wgslender", .module = wgslender_wasm_mod },
        },
    });
    // Wire codec tree — manual-JSON helpers shared by every wasm/<feature>.zig
    // adapter. Registered as a build module so `lsp/wasm/<feature>.zig` and
    // its tests can reach `wire/primitives.zig` without a `../`-style
    // relative import (forbidden across module roots).
    const wire_wasm_mod = b.addModule("wire-wasm", .{
        .root_source_file = b.path("lsp/wire_root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "Handler", .module = handler_wasm_mod },
            .{ .name = "wgslender", .module = wgslender_wasm_mod },
        },
    });
    const lsp_wasm = b.addExecutable(.{
        .name = "wgslender-lsp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("lsp/wasm.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .imports = &.{
                .{ .name = "wgslender", .module = wgslender_wasm_mod },
                .{ .name = "Handler", .module = handler_wasm_mod },
                .{ .name = "wire", .module = wire_wasm_mod },
            },
        }),
    });
    lsp_wasm.entry = .disabled;
    lsp_wasm.rdynamic = true;

    const install_lsp_wasm = b.addInstallArtifact(lsp_wasm, .{});
    const lsp_wasm_step = b.step("lsp-wasm", "Build the WGSL LSP WASM module");
    lsp_wasm_step.dependOn(&install_lsp_wasm.step);

    // VS Code extension assets — copy the WASM artefacts into
    // npm/wgslender-vscode/dist/ so esbuild + vsce can pick them up.
    const copy_lsp_wasm_to_vscode = b.addInstallFile(
        lsp_wasm.getEmittedBin(),
        "../npm/wgslender-vscode/dist/wgslender-lsp.wasm",
    );
    const copy_wasm_to_vscode = b.addInstallFile(
        wasm.getEmittedBin(),
        "../npm/wgslender-vscode/dist/wgslender.wasm",
    );
    const vscode_assets_step = b.step("vscode-assets", "Copy WASM artefacts into npm/wgslender-vscode/dist/");
    vscode_assets_step.dependOn(&copy_lsp_wasm_to_vscode.step);
    vscode_assets_step.dependOn(&copy_wasm_to_vscode.step);

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
    // Tint expected-file verdict classifier (Block 1). Registered here as an
    // importable module for its first consumers: the corpus pinning/triage
    // test and the `tint-triage` tool.
    const tint_oracle_mod = b.addModule("tint_oracle", .{
        .root_source_file = b.path("tests/tint_oracle.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tint_oracle_import: std.Build.Module.Import = .{ .name = "tint_oracle", .module = tint_oracle_mod };
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
    _ = addTestStep(b, test_step, "tests/lint_rules_test.zig", target, optimize, &.{w});
    // MultiVisitor — multi-listener AST walker shared by lint rules.
    _ = addTestStep(b, test_step, "tests/multi_visitor_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/multi_visitor_dispatch_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/validation_dedup_test.zig", target, optimize, &.{ w, .{ .name = "validation_data", .module = validation_data_mod } });
    // Collision tests
    _ = addTestStep(b, test_step, "tests/collision_test.zig", target, optimize, &.{w});
    // Regression tests
    _ = addTestStep(b, test_step, "tests/regression_test.zig", target, optimize, &.{w});
    // Parser recursive-descent depth limit regressions
    _ = addTestStep(b, test_step, "tests/depth_limits_test.zig", target, optimize, &.{w});
    // Parser template-arg postfix-suffix tests (member/index/call inside
    // array<T, ...> template args) — guards against the regression where
    // `parseTemplatePrimaryExprInner` silently dropped postfix suffixes.
    _ = addTestStep(b, test_step, "tests/parser_template_postfix_test.zig", target, optimize, &.{w});
    // Numeric-literal text fidelity — AST literal value must equal the lexer's
    // byte-exact `source[token.start..token.end]` (no hand-rolled re-scanner).
    _ = addTestStep(b, test_step, "tests/parser_token_text_test.zig", target, optimize, &.{w});
    // Diagnostic JSON escaping — serialized entries must parse under std.json
    // even when a message carries a control byte (< 0x20).
    _ = addTestStep(b, test_step, "tests/diagnostic_json_test.zig", target, optimize, &.{w});
    // Reflect tests
    _ = addTestStep(b, test_step, "tests/reflect_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/reflect_wgslreflect_test.zig", target, optimize, &.{w});
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
    // RenamePolicy.Builder integration — verifies the parser_wants_no_rename
    // bit and the mirror-to-flags semantics over the compute.toys corpus.
    _ = addTestStep(b, test_step, "tests/rename_policy_test.zig", target, optimize, &.{w});
    // Liveness side-table integration — Dce.mark dual-write parity and
    // minify-path agreement with a fresh DCE on the compute.toys corpus.
    _ = addTestStep(b, test_step, "tests/liveness_test.zig", target, optimize, &.{w});
    // Pipeline `Pass.custom` integration — verifies the public extension
    // point: state observation, mid-pipeline mutation honored downstream,
    // ordering, and the non-strict (skip on missing input) contract.
    _ = addTestStep(b, test_step, "tests/pipeline_custom_pass_test.zig", target, optimize, &.{w});
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
    _ = addTestStep(b, test_step, "tests/predeclared_test.zig", target, optimize, &.{w});
    // Semantic tests
    const sd: std.Build.Module.Import = .{ .name = "semantic_data", .module = semantic_data_mod };
    _ = addTestStep(b, test_step, "tests/compute_toys_test.zig", target, optimize, &.{ w, sd });
    _ = addTestStep(b, test_step, "tests/semantic_test.zig", target, optimize, &.{ w, sd });
    // Source map tests
    _ = addTestStep(b, test_step, "tests/sourcemap_test.zig", target, optimize, &.{w});
    // Tint tests — bulk semantic preservation test of 12,668 real Tint shaders.
    // testdata/tint/ is optional: if absent the test prints a skip message and passes.
    const run_tint_tests = addTestStep(b, test_step, "tests/tint_test.zig", target, optimize, &.{w});
    const tint_step = b.step("tint-test", "Run Tint semantic preservation tests");
    tint_step.dependOn(run_tint_tests);

    // tint-triage: Tint-oracle conformance worklist/report tool (reports only).
    // setCwd(.) so it resolves `tests/testdata/tint` relative to the repo root
    // regardless of the build's cwd; `--` args pass straight through.
    const tint_triage_exe = b.addExecutable(.{
        .name = "tint-triage",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/tint_triage.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ w, tint_oracle_import },
        }),
    });
    const run_tint_triage = b.addRunArtifact(tint_triage_exe);
    run_tint_triage.setCwd(b.path("."));
    if (b.args) |triage_args| run_tint_triage.addArgs(triage_args);
    const tint_triage_step = b.step("tint-triage", "Tint-oracle triage worklist/report tool");
    tint_triage_step.dependOn(&run_tint_triage.step);
    // The tool's pure-fn tests (arg parsing, TSV escaping) run corpus-free in CI.
    _ = addTestStep(b, test_step, "tools/tint_triage.zig", target, optimize, &.{ w, tint_oracle_import });

    // LSP Handler tests
    _ = addTestStep(b, test_step, "lsp/Handler.zig", target, optimize, &.{w});
    // LSP URI helper tests (no imports needed beyond stdlib)
    _ = addTestStep(b, test_step, "lsp/uri.zig", target, optimize, &.{});
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
    // UTF-16 position-encoding regressions: pin that
    // lspPositionToOffset / offsetToLspPosition + the helper-routed
    // diagnostic ranges count UTF-16 code units (matching the
    // `positionEncoding: utf-16` we advertise in initialize).
    _ = addTestStep(b, test_step, "tests/lsp_position_encoding_test.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
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
    // Unit tests for the shared diagnostic-items JSON encoder. Lives in
    // `lsp/wire/` so both transports (and the parity harness) can reach
    // it as a registered module.
    _ = addTestStep(b, test_step, "lsp/wire/primitives.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    _ = addTestStep(b, test_step, "lsp/wire/diagnostics.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    _ = addTestStep(b, test_step, "lsp/wire/navigation.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    _ = addTestStep(b, test_step, "lsp/wire/call_hierarchy.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    _ = addTestStep(b, test_step, "lsp/wire/edits.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    _ = addTestStep(b, test_step, "lsp/wire/symbols.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    _ = addTestStep(b, test_step, "lsp/wire/code_actions.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    _ = addTestStep(b, test_step, "lsp/wire/editing.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    _ = addTestStep(b, test_step, "lsp/wire/workspace_commands.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    // Native parity harness — asserts `lspkit/diagnostics.zig` and
    // `wire/diagnostics.zig` produce byte-equivalent JSON for every
    // `QuickFixHint` variant.
    _ = addTestStep(b, test_step, "lsp/lspkit/diagnostics.zig", target, optimize, &.{
        w,
        .{ .name = "Handler", .module = handler_mod },
        .{ .name = "lsp", .module = lsp_mod },
    });
    _ = addTestStep(b, test_step, "tests/lsp_diagnostic_parity_test.zig", target, optimize, &.{
        w,
        .{ .name = "Handler", .module = handler_mod },
        .{ .name = "lsp", .module = lsp_mod },
        .{ .name = "lspkit", .module = lspkit_mod },
        .{ .name = "wire", .module = wire_mod },
    });
    // Parity harness for navigation + call_hierarchy: same property as
    // diagnostics, but for `lspkit/{navigation,call_hierarchy}.zig` vs
    // `wire/{navigation,call_hierarchy}.zig`.
    _ = addTestStep(b, test_step, "tests/lsp_navigation_parity_test.zig", target, optimize, &.{
        w,
        .{ .name = "Handler", .module = handler_mod },
        .{ .name = "lsp", .module = lsp_mod },
        .{ .name = "lspkit", .module = lspkit_mod },
        .{ .name = "wire", .module = wire_mod },
    });
    // Parity harness for symbols + edits + code_actions: same property
    // as the navigation harness but covers the recursive `DocumentSymbol`,
    // the `WorkspaceEdit.changes` map, and the composed `CodeAction`
    // shape — `lspkit/{edits,symbols,code_actions}.zig` vs
    // `wire/{edits,symbols,code_actions}.zig`.
    _ = addTestStep(b, test_step, "tests/lsp_symbols_parity_test.zig", target, optimize, &.{
        w,
        .{ .name = "Handler", .module = handler_mod },
        .{ .name = "lsp", .module = lsp_mod },
        .{ .name = "lspkit", .module = lspkit_mod },
        .{ .name = "wire", .module = wire_mod },
    });
    // Parity harness for the editing batch + workspace_commands. Asserts
    // `lspkit/{editing,workspace_commands}.zig` and
    // `wire/{editing,workspace_commands}.zig` produce byte-equivalent
    // JSON, including the InlayHint LabelPart `def_range` null-vs-set
    // case the migration plan called out as a known divergence.
    _ = addTestStep(b, test_step, "tests/lsp_editing_parity_test.zig", target, optimize, &.{
        w,
        .{ .name = "Handler", .module = handler_mod },
        .{ .name = "lsp", .module = lsp_mod },
        .{ .name = "lspkit", .module = lspkit_mod },
        .{ .name = "wire", .module = wire_mod },
    });
    // Error-envelope parity for `workspace/executeCommand` — drives both
    // transports' workspace-command error paths and asserts the JSON-RPC
    // `code` matches between native (`@errorName(err)` via lsp-kit) and
    // wasm (hardcoded English via `sendErrorCode`). Each side's message
    // is locked separately so accidental drift fails a test.
    _ = addTestStep(b, test_step, "tests/lsp_workspace_error_parity_test.zig", target, optimize, &.{
        w,
        .{ .name = "Handler", .module = handler_mod },
        .{ .name = "lsp", .module = lsp_mod },
        .{ .name = "wire", .module = wire_mod },
        .{ .name = "native_workspace_commands", .module = native_workspace_commands_mod },
        .{ .name = "wasm_workspace_commands", .module = wasm_workspace_commands_mod },
    });
    // Internal smoke tests for the shared parity helpers module
    // (`jsonEql`, `expectEqualErrorCode` round-trip, escape-aware
    // `buildAndParseWasmErrorEnvelope`). Lives in its own file so the
    // inline tests don't fire inside every parity-test binary that
    // imports `lsp_parity_helpers.zig` as a sibling module.
    _ = addTestStep(b, test_step, "tests/lsp_parity_helpers_test.zig", target, optimize, &.{
        .{ .name = "lsp", .module = lsp_mod },
        .{ .name = "wire", .module = wire_mod },
    });
    // Standalone test for the lspkit edits + symbols + code_actions
    // bridges (assertions on the resulting `lsp.types.*` shape).
    _ = addTestStep(b, test_step, "lsp/lspkit/edits.zig", target, optimize, &.{
        w,
        .{ .name = "Handler", .module = handler_mod },
        .{ .name = "lsp", .module = lsp_mod },
    });
    _ = addTestStep(b, test_step, "lsp/lspkit/symbols.zig", target, optimize, &.{
        w,
        .{ .name = "Handler", .module = handler_mod },
        .{ .name = "lsp", .module = lsp_mod },
    });
    _ = addTestStep(b, test_step, "lsp/lspkit/code_actions.zig", target, optimize, &.{
        w,
        .{ .name = "Handler", .module = handler_mod },
        .{ .name = "lsp", .module = lsp_mod },
    });
    _ = addTestStep(b, test_step, "lsp/lspkit/editing.zig", target, optimize, &.{
        w,
        .{ .name = "Handler", .module = handler_mod },
        .{ .name = "lsp", .module = lsp_mod },
    });
    _ = addTestStep(b, test_step, "lsp/lspkit/workspace_commands.zig", target, optimize, &.{
        w,
        .{ .name = "Handler", .module = handler_mod },
        .{ .name = "lsp", .module = lsp_mod },
    });
    // Regression test for publishDiagnostics message/codeDescription.href
    // corruption after codeLens/documentHighlight + incremental edit.
    // Drives the Handler directly and renders through the same
    // `wire/diagnostics.appendDiagnosticItems` path the WASM transport
    // uses, so byte-level assertions see what an editor sees on the wire.
    _ = addTestStep(b, test_step, "lsp/diagnostic_corruption_test.zig", target, optimize, &.{
        w,
        .{ .name = "Handler", .module = handler_mod },
        .{ .name = "wire", .module = wire_mod },
    });
    // Phase 7 idle-debounce data structure. Pure unit tests against the
    // arm / clear / popDue / nextDeadline contract that the native
    // timer thread will later drive.
    _ = addTestStep(b, test_step, "lsp/Debouncer.zig", target, optimize, &.{});
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
    // Minify-mode settings resolver (precedence merge of magic comment,
    // workspace, and project-config layers).
    _ = addTestStep(b, test_step, "tests/minify_settings_test.zig", target, optimize, &.{w});
    // Per-document magic-comment scanner for `// wgslender-minify-*`
    // directives that override workspace/project mode.
    _ = addTestStep(b, test_step, "tests/magic_comment_test.zig", target, optimize, &.{w});
    // Phase 3 byte-size estimator: dry-run Printer + length-only renamer.
    // Ground-truth parity against wgslender.minifyWithOptions on the
    // compute.toys corpus plus correctness tests on small fixtures.
    _ = addTestStep(b, test_step, "tests/minify_estimator_test.zig", target, optimize, &.{w});
    // LSP-layer plumbing for minifier-mode: Handler settings parse,
    // effectiveMinify accessor, workspace/executeCommand dispatch.
    _ = addTestStep(b, test_step, "tests/lsp_minify_settings_test.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    // Phase 4 byte-size inlay hints emitted by the LSP when minifier-mode
    // is `insights` or `strict`.
    _ = addTestStep(b, test_step, "tests/lsp_minify_inlay_hints_test.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    // Phase 5a — minify lint rules (`minify/unused-const`,
    // `minify/unused-override`, `minify/external-binding-blocks-rename`)
    // and the LSP wiring that surfaces them in `mode=strict`.
    _ = addTestStep(b, test_step, "tests/lint_minify_rules_test.zig", target, optimize, &.{w});
    _ = addTestStep(b, test_step, "tests/lsp_minify_rules_test.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    // Phase 6 — module-level total-size code lens + showMinifiedOutput
    // command. Lives next to the other lsp_minify_* suites.
    _ = addTestStep(b, test_step, "tests/lsp_minify_code_lens_test.zig", target, optimize, &.{ w, .{ .name = "Handler", .module = handler_mod } });
    // Phase 7 — per-document `MinifyEstimator` cache + recompute
    // notification. Drives the Handler through inlay-hint / code-lens /
    // M-rule paths and verifies a single cached estimator run is
    // shared across all of them, plus the invalidation hooks.
    _ = addTestStep(b, test_step, "tests/lsp_minify_perf_test.zig", target, optimize, &.{
        w,
        .{ .name = "Handler", .module = handler_mod },
        .{ .name = "NativeServer", .module = native_server_mod },
        .{ .name = "lsp", .module = lsp_mod },
    });
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
    _ = addTestStep(b, test_step, "tests/inference_corpus_pinning_test.zig", target, optimize, &.{ w, tint_oracle_import });
    // Tint expected-file verdict oracle — pure classifier with corpus-free
    // fixture tests (feeds the Block-2 triage golden; runs in default CI).
    _ = addTestStep(b, test_step, "tests/tint_oracle.zig", target, optimize, &.{});
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
