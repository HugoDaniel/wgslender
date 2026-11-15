//! Compile-level proof that the project-free graphs stay project-free
//! (pngine-shaders phase 01, Task 1).
//!
//! `build.zig` compiles this file as an object for each project-free
//! graph — `wasm` and `lsp-wasm` (wasm32-freestanding, through the
//! shared `wgslender-wasm` module) and `lib` (native) — and wires it
//! into those build steps. It is never executed: the assertions are
//! comptime, so a graph that ever resolves `pngine_support=true`, or
//! compiles `wgslender.Pngine` in, fails to build that step.
//!
//! Why compile-time assertions rather than a test: the property is
//! per-compilation. The native test binary always carries SJON
//! (`pngine_support=true`) and cannot see what a different graph
//! compiled; only code compiled inside the project-free compilation
//! itself can prove it. The fetch side of the boundary — that the build
//! runner never resolves the sjon dependency for those graphs — is
//! proven separately with a throwaway `ZIG_GLOBAL_CACHE_DIR` (see the
//! phase-01 plan's gates).
//!
//! `wgslender` here is a module rooted at `src/root.zig` carrying the
//! same `build_options` instance the graph under test compiles with:
//! the real `wgslender-wasm` module for the wasm graphs, and a mirror
//! with the lib graph's target/options for `lib` (whose compilation
//! reaches `src/root.zig` only through `src/lib.zig`'s relative import,
//! leaving no named root module to hook).

const build_options = @import("build_options");
const wgslender = @import("wgslender");
const surface = @import("pngine_api_surface.zig");

comptime {
    if (build_options.pngine_support) {
        @compileError(
            "project-free graph carries pngine_support=true: the wasm, lib, " ++
                "and lsp-wasm graphs must never resolve pngine project support " ++
                "(build.zig, docs/plans/pngine-shaders/README.md \"Packaging\")",
        );
    }
    if (wgslender.Pngine != void) {
        @compileError(
            "project-free graph compiled wgslender.Pngine in: src/root.zig " ++
                "must keep every pngine entry point behind pngine_support, " ++
                "and that flag must be false here",
        );
    }
    // The source-only ABI these graphs export must keep compiling with
    // its existing text-only signatures (phase 05, Task 5: the ruling's
    // compile-test matrix) — no path, provider, or `std.Io` parameter
    // may appear on a single-source entry point.
    _ = &surface.sourceOnlySurface;
    // Reference the namespace so the module import stays live even while
    // both assertions above hold.
    _ = wgslender;
}
