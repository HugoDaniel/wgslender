//! `Compiler.minifiedText` — the exact bytes `compile` embeds.
//!
//! These are the bytes the BPE stage compresses and the generated module's
//! `generate()` decodes back; the npm suite's decoded-text assertion executes
//! that module and validates the decoded bytes, so proving `minifiedText`
//! preserves bindings here pins the in-tree half of the chain without a wasm
//! runtime. This file runs that proof for the report's shader, the
//! pinned-local shape and the counter-named-`a` shape, under
//! `.minify = true` and the compiler's no-op base (`.minify = false`, which
//! still wraps the base renamer scope-local).

const std = @import("std");
const wgslender = @import("wgslender");
const bindings = @import("bindings_preserved.zig");
const parse_ok = @import("parse_ok.zig");

const CompileOptions = wgslender.Compiler.CompileOptions;
const testing = std.testing;

const Fixture = struct {
    name: []const u8,
    source: [:0]const u8,
    keep_names: []const []const u8 = &.{},
};

const fixtures = [_]Fixture{
    .{
        .name = "report-for-counter",
        .source =
        \\fn accumulate(x: i32) -> i32 {
        \\  let base = x * 2;
        \\  var total = 0;
        \\  for (var idx = 0; idx < 4; idx++) {
        \\    total = total + base + idx;
        \\  }
        \\  return total;
        \\}
        ,
    },
    .{
        .name = "keep-names-local",
        .source =
        \\fn f(x: i32) -> i32 {
        \\  let a = 1;
        \\  return x + a;
        \\}
        ,
        .keep_names = &.{"a"},
    },
    .{
        .name = "counter-named-a",
        .source =
        \\fn f(x: i32) -> i32 {
        \\  var b = 0;
        \\  for (var a = 0; a < 4; a++) {
        \\    b = b + a + x;
        \\  }
        \\  return b;
        \\}
        ,
    },
};

/// Parse `source` and run the compiler's print path, returning the text as a
/// sentinel slice `parse_ok` can re-parse.
fn compileText(arena: std.mem.Allocator, source: [:0]const u8, options: CompileOptions) ![:0]const u8 {
    const module = try parse_ok.parseOk(arena, source);
    const text = try wgslender.Compiler.minifiedText(arena, source, module, options);
    return arena.dupeZ(u8, text);
}

fn expectCleanValidate(arena: std.mem.Allocator, text: [:0]const u8) !void {
    const validation = try wgslender.validateWithOptions(arena, text, .{});
    for (validation.diagnostics.diagnostics.items) |d| {
        if (d.severity != .@"error") continue;
        std.debug.print(
            "compiler text failed to validate: {s} [{s}]\ntext:\n{s}\n",
            .{ d.message, d.code, text },
        );
        return error.CompilerTextInvalid;
    }
}

test "compiler text preserves bindings in both naming modes" {
    const gpa = testing.allocator;

    for (fixtures) |fixture| {
        for ([_]bool{ true, false }) |minify| {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const alloc = arena.allocator();

            const options = CompileOptions{
                .minify = minify,
                .minify_options = .{ .keep_names = fixture.keep_names },
            };

            const text = compileText(alloc, fixture.source, options) catch |err| {
                std.debug.print("fixture \"{s}\" minify={} failed to print\n", .{ fixture.name, minify });
                return err;
            };
            bindings.expectBindingsPreservedText(alloc, fixture.source, text, null) catch |err| {
                std.debug.print(
                    "fixture \"{s}\" minify={} did not preserve bindings\ntext:\n{s}\n",
                    .{ fixture.name, minify, text },
                );
                return err;
            };
            expectCleanValidate(alloc, text) catch |err| {
                std.debug.print("fixture \"{s}\" minify={} failed validation\n", .{ fixture.name, minify });
                return err;
            };
        }
    }
}
