//! Native pngine API compile check (pngine-shaders phase 05, Task 5).
//!
//! `build.zig` compiles this file as an object against the *real*
//! `wgslender` module the native CLI links (and, through
//! `lsp_step.dependOn`, the same module instance the native LSP graph
//! compiles) and wires it into the default install step, so both plain
//! `zig build` and `zig build -Dlsp=false` prove their own graph:
//!
//! - `pngine_support == true` (`zig build`, `zig build lsp` after the
//!   lazy SJON dependency resolved): `wgslender.Pngine` must be the
//!   consumer facade with every declaration and signature the phase-05
//!   ruling lists, the removed proof-of-life exports (`enabled`,
//!   `hasFormHead`) and the CLI selection policy must stay off it, and
//!   `Store.init(gpa, provider)` must remain the only construction path.
//! - `pngine_support == false` (`zig build -Dlsp=false`): the same
//!   module must compile `Pngine` out to `void` — every project
//!   declaration, including `Pngine.Store`, is necessarily a compile
//!   error in that graph, which is why the positive assertions below
//!   are the whole proof (an expected-failure consumer probe is not a
//!   substitute; see the ruling's compile-test matrix).
//!
//! In both branches, `tests/pngine_api_surface.zig` proves the existing
//! source-only entry points keep their text-only signatures. The
//! project-free `wasm`, `lib`, and `lsp-wasm` graphs carry their own
//! in-graph check (`tests/pngine_project_free_check.zig`).
//!
//! Never executed: everything below is comptime.

const std = @import("std");
const build_options = @import("build_options");
const wgslender = @import("wgslender");
const surface = @import("pngine_api_surface.zig");

const Pngine = wgslender.Pngine;

comptime {
    // The source-only surface compiles unchanged in every native graph,
    // enabled or not.
    _ = &surface.sourceOnlySurface;

    if (build_options.pngine_support) {
        assertEnabledFacade();
    } else {
        if (Pngine != void) {
            @compileError(
                "native -Dlsp=false graph compiled wgslender.Pngine in: " ++
                    "pngine_support is false here, so src/root.zig must keep " ++
                    "the project namespace behind the flag (a project-free " ++
                    "graph has no project entry point at all)",
            );
        }
    }
    // Keep the module import live under both branches.
    _ = wgslender;
}

/// The enabled-graph assertions, factored out so the lazy branch above
/// stays readable. Compiled only when `pngine_support` is true.
fn assertEnabledFacade() void {
    comptime {
        if (Pngine == void) {
            @compileError(
                "enabled native graph exposes no wgslender.Pngine: " ++
                    "build_options.pngine_support is true, so src/root.zig " ++
                    "must import the pngine facade module",
            );
        }

        // --- Removed exports stay removed ------------------------------
        if (@hasDecl(Pngine, "enabled")) {
            @compileError(
                "Pngine.enabled must stay off the consumer facade: the " ++
                    "presence of the namespace is the answer (phase-05 " ++
                    "Task 5 ruling, Q1)",
            );
        }
        if (@hasDecl(Pngine, "hasFormHead")) {
            @compileError(
                "Pngine.hasFormHead was dependency proof-of-life, not " ++
                    "project functionality; it must stay off the facade " ++
                    "(phase-05 Task 5 ruling, Q1)",
            );
        }
        if (@hasDecl(Pngine, "selectProject") or @hasDecl(Pngine, "ProjectSelection")) {
            @compileError(
                "CLI project-selection policy (selectProject/ProjectSelection) " ++
                    "must stay in cli/PngineSelection.zig, not on Pngine " ++
                    "(phase-05 Task 5 ruling)",
            );
        }

        // --- Every facade declaration exists ---------------------------
        const declarations = [_][]const u8{
            "Types",       "Store",         "Program",       "ProgramId",
            "PartId",      "RootId",        "OriginKey",     "ByteRange",
            "Assembled",   "OriginRange",   "OriginOffset",  "LocatedLine",
            "AssemblyError", "MappedDiagnostics", "SourceMapOptions",
            "SourceMapError", "RemappedSourceMap",
        };
        for (declarations) |name| {
            if (!@hasDecl(Pngine, name)) {
                @compileError("enabled facade declaration missing: Pngine." ++ name);
            }
        }
        const functions = [_][]const u8{ "assembleRoot", "mapDiagnostics", "remapSourceMap" };
        for (functions) |name| {
            if (!@hasDecl(Pngine, name)) {
                @compileError("enabled facade function missing: Pngine." ++ name);
            }
        }

        // --- Exact signatures ------------------------------------------
        if (@TypeOf(Pngine.assembleRoot) !=
            fn (*Pngine.Store, Pngine.RootId) Pngine.AssemblyError!*const Pngine.Assembled)
        {
            @compileError("Pngine.assembleRoot signature drifted from the ruling");
        }
        if (@TypeOf(Pngine.mapDiagnostics) !=
            fn (
                std.mem.Allocator,
                *Pngine.Store,
                *const Pngine.Assembled,
                []const wgslender.Diagnostic.Entry,
            ) std.mem.Allocator.Error!Pngine.MappedDiagnostics)
        {
            @compileError("Pngine.mapDiagnostics signature drifted from the ruling");
        }
        if (@TypeOf(Pngine.remapSourceMap) !=
            fn (
                std.mem.Allocator,
                *Pngine.Store,
                *const Pngine.Assembled,
                *const wgslender.SourceMap.Result,
                Pngine.SourceMapOptions,
            ) Pngine.SourceMapError!Pngine.RemappedSourceMap)
        {
            @compileError("Pngine.remapSourceMap signature drifted from the ruling");
        }

        // --- Store has exactly the provider construction path ----------
        if (@TypeOf(Pngine.Store.init) !=
            fn (std.mem.Allocator, Pngine.Types.SourceProvider) Pngine.Store)
        {
            @compileError(
                "Pngine.Store.init must be the single construction path: " ++
                    "Store.init(gpa, provider); no second convenience constructor",
            );
        }

        // --- Error sets are exactly the ruling's members ---------------
        // The member arrays fail compilation if a required member is
        // missing. The probe functions fail if the facade set has any
        // member outside the ruling's list: their parameter is a runtime
        // value of the facade's set, so the return coercion is a
        // type-level subset check. Together: exact.
        const assembly_set_probe = struct {
            fn rulingOnly(e: Pngine.AssemblyError) error{
                OutOfMemory,   ImportCycle, UnknownFragment,
                TooDeep,       MissingSource,
                UnknownProgram, UnknownPart, NotARoot,
            } {
                return e;
            }
        };
        _ = &assembly_set_probe.rulingOnly;
        const assembly_members = [_]Pngine.AssemblyError{
            error.OutOfMemory,   error.ImportCycle,   error.UnknownFragment,
            error.TooDeep,       error.MissingSource, error.UnknownProgram,
            error.UnknownPart,   error.NotARoot,
        };
        _ = assembly_members;

        const source_map_set_probe = struct {
            fn rulingOnly(e: Pngine.SourceMapError) error{ OutOfMemory, InvalidPartUri } {
                return e;
            }
        };
        _ = &source_map_set_probe.rulingOnly;
        const source_map_members = [_]Pngine.SourceMapError{
            error.OutOfMemory,
            error.InvalidPartUri,
        };
        _ = source_map_members;

        // --- Owning result envelopes -----------------------------------
        if (!@hasField(Pngine.MappedDiagnostics, "items") or
            !@hasField(Pngine.MappedDiagnostics, "_arena"))
        {
            @compileError("Pngine.MappedDiagnostics must own items and its arena");
        }
        if (@TypeOf(Pngine.MappedDiagnostics.deinit) !=
            fn (*Pngine.MappedDiagnostics) void)
        {
            @compileError("Pngine.MappedDiagnostics.deinit must take only *self");
        }
        if (!@hasField(Pngine.RemappedSourceMap, "map") or
            !@hasField(Pngine.RemappedSourceMap, "dropped") or
            !@hasField(Pngine.RemappedSourceMap, "_arena"))
        {
            @compileError("Pngine.RemappedSourceMap must own its map, dropped, and arena");
        }
        if (@TypeOf(Pngine.RemappedSourceMap.deinit) !=
            fn (*Pngine.RemappedSourceMap) void)
        {
            @compileError("Pngine.RemappedSourceMap.deinit must take only *self");
        }

        // --- Value vocabulary -------------------------------------------
        if (Pngine.ProgramId != u32) {
            @compileError("Pngine.ProgramId must stay the u32 program slot");
        }
        if (Pngine.RootId != Pngine.PartId or Pngine.OriginKey != Pngine.PartId) {
            @compileError("Pngine.RootId/OriginKey must stay PartId-shaped values");
        }
    }
}
