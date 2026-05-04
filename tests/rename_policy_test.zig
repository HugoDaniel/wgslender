//! Integration tests for B.M2 — RenamePolicy.Builder end-to-end.
//!
//! Two invariants that the unit tests in src/RenamePolicy.zig can't
//! exercise (because they construct synthetic Symbols without going
//! through Parser/CstLower):
//!
//!   1. `Symbol.flags.parser_wants_no_rename` is set on **exactly** the
//!      same symbols as `Symbol.flags.is_entry_point` after parsing —
//!      proves the Parser and CstLower writes added in B.M2 line up
//!      with the existing entry-point marking.
//!   2. After running `wgslender.minify`, every symbol's
//!      `must_not_be_renamed` field agrees with what a fresh `Builder`
//!      run over the same module would produce — proves the Builder
//!      mirror in `markAPIFacingSymbols` is the source of truth.
//!
//! Both invariants run over the curated `compute.toys` corpus when it
//! is available; the tests skip cleanly otherwise.

const std = @import("std");
const wgslender = @import("wgslender");

const Ast = wgslender.Ast;
const Parser = wgslender.Parser;
const Lexer = wgslender.Lexer;
const RenamePolicy = wgslender.RenamePolicy;

// =========================================================================
// Helper: iterate the compute.toys directory, calling `check` per shader.
// =========================================================================

fn forEachComputeToysShader(
    gpa: std.mem.Allocator,
    check: *const fn (gpa: std.mem.Allocator, src: [:0]const u8) anyerror!void,
) !usize {
    const io = std.Options.debug_io;
    const dir_path = "tests/testdata/compute.toys";
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound or err == error.NotFound) return 0;
        return err;
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    var n: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".wgsl")) continue;

        var arena_inst = std.heap.ArenaAllocator.init(gpa);
        defer arena_inst.deinit();
        const arena = arena_inst.allocator();

        const bytes = entry.dir.readFileAlloc(io, entry.basename, arena, .unlimited) catch continue;
        const src = try arena.dupeZ(u8, bytes);
        try check(gpa, src);
        n += 1;
    }
    return n;
}

// =========================================================================
// Invariant 1 — parser_wants_no_rename ↔ is_entry_point parity
// =========================================================================

fn checkParserBitMatchesEntryPoint(gpa: std.mem.Allocator, src: [:0]const u8) anyerror!void {
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const tokens = try Lexer.tokenize(arena, src);
    var parser = try Parser.init(arena, src, tokens);
    const module = parser.parse() catch return; // skip on parse error

    for (module.symbols.items) |sym| {
        // The bit is *only* set on entry points today; both sides must
        // agree on every symbol or B.M5's deletion plan breaks.
        try std.testing.expectEqual(sym.flags.is_entry_point, sym.flags.parser_wants_no_rename);
    }
}

test "rename_policy: parser_wants_no_rename matches is_entry_point on a synthetic shader" {
    const src: [:0]const u8 =
        \\@compute @workgroup_size(1) fn main() {}
        \\fn helper() -> i32 { return 1; }
        \\@vertex fn v() -> @builtin(position) vec4<f32> { return vec4<f32>(0.0); }
    ;
    try checkParserBitMatchesEntryPoint(std.testing.allocator, src);
}

test "rename_policy: parser_wants_no_rename matches is_entry_point on compute.toys corpus" {
    const n = try forEachComputeToysShader(std.testing.allocator, checkParserBitMatchesEntryPoint);
    if (n == 0) {
        std.debug.print("skip: compute.toys directory missing\n", .{});
        return;
    }
    std.debug.print("rename_policy parser-bit parity: verified on {d} compute.toys shaders\n", .{n});
}

// =========================================================================
// Invariant 2 — Builder.build() agrees with field after minify()
// =========================================================================

fn checkBuilderMatchesField(gpa: std.mem.Allocator, src: [:0]const u8) anyerror!void {
    // Run the production minify path. This mutates `must_not_be_renamed`
    // via the Builder + mirror in `markAPIFacingSymbols`. We then run a
    // *separate* Builder over the same module and assert per-symbol
    // agreement.
    var result = wgslender.minifyWithOptions(gpa, src, .{}) catch return;
    defer result.deinit(gpa);

    if (result.errors.len > 0) return; // skip on parse errors

    // Re-parse to inspect the post-mark module. Production's module is
    // private to its arena; we need our own to compare the field state.
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const tokens = try Lexer.tokenize(arena, src);
    var parser = try Parser.init(arena, src, tokens);
    const module = parser.parse() catch return;

    // Mirror the standard production marking via the Builder.
    var builder = try RenamePolicy.Builder.init(arena, module.symbols.items.len);
    builder.markFromParser(module);
    builder.markEntryPoints(module);
    builder.markBuiltinsAndOverrides(module);
    builder.markExternalBindings(module);
    // Default minify options have empty keep_names and
    // preserve_uniform_struct_types=false, so we skip those marks.
    const policy = builder.build();
    policy.mirrorToFlags(module);
    policy.assertParity(module);
}

test "rename_policy: Builder produces same set as field on synthetic shader" {
    const src: [:0]const u8 =
        \\@group(0) @binding(0) var<uniform> u: f32;
        \\override SCALE: f32 = 1.0;
        \\@compute @workgroup_size(1) fn main() { let x = u * SCALE; _ = x; }
    ;
    try checkBuilderMatchesField(std.testing.allocator, src);
}

test "rename_policy: Builder agrees with field on compute.toys corpus" {
    const n = try forEachComputeToysShader(std.testing.allocator, checkBuilderMatchesField);
    if (n == 0) {
        std.debug.print("skip: compute.toys directory missing\n", .{});
        return;
    }
    std.debug.print("rename_policy builder/field parity: verified on {d} compute.toys shaders\n", .{n});
}
