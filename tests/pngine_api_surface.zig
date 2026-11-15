//! Shared source-only compile surface for the pngine API build checks
//! (pngine-shaders phase 05, Task 5).
//!
//! Every API check object — the native enabled/disabled check in
//! `tests/pngine_native_api_check.zig` and the project-free graph checks
//! in `tests/pngine_project_free_check.zig` — compiles this file against
//! the exact `wgslender` module instance that graph links. The function
//! below calls every source-only entry point with its existing text-only
//! signature, so a lane fails to compile the moment one of those
//! signatures grows a path, provider, or `std.Io` parameter, on either
//! side of the project boundary.
//!
//! This file is never executed; its body is only semantically analyzed.
//! It is reached by relative import from the check files and must not be
//! registered as a test step.

const std = @import("std");
const wgslender = @import("wgslender");

/// Call the existing source-only API exactly as npm, WASM, C, Go, and
/// Rust consumers do: text in, owned result out. The pngine facade must
/// never change these signatures.
pub fn sourceOnlySurface(gpa: std.mem.Allocator, source: [:0]const u8) !void {
    var validate_result = try wgslender.validate(gpa, source);
    validate_result.deinit();

    var lint_result = try wgslender.lint(gpa, source, .{});
    lint_result.deinit(gpa);

    var reflect_result = try wgslender.reflect(gpa, source);
    reflect_result.deinit(gpa);

    var minify_result = try wgslender.minify(gpa, source);
    minify_result.deinit(gpa);

    var compile_result = try wgslender.compile(gpa, source, .{});
    compile_result.deinit(gpa);
}
