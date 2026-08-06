//! Integration tests for `RenamePolicy.Builder` end-to-end.
//!
//! After B.M5 deleted `Symbol.flags.must_not_be_renamed` and
//! `Symbol.flags.parser_wants_no_rename`, the original B.M2 parity
//! invariants no longer apply. The remaining smoke tests confirm the
//! Builder produces a non-empty policy on every shader in the corpus
//! and that the policy correctly pins entry points and external
//! bindings — without crashing or out-of-range indices.

const std = @import("std");
const wgslender = @import("wgslender");

const Ast = wgslender.Ast;
const RenamePolicy = wgslender.RenamePolicy;
const parseOk = @import("parse_ok.zig").parseOk;

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
// Builder smoke: every entry point and external binding gets pinned.
// =========================================================================

fn checkBuilderPinsEntryPointsAndBindings(gpa: std.mem.Allocator, src: [:0]const u8) anyerror!void {
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // `parse() catch return` here used to skip a shader silently while
    // `forEachComputeToysShader` still counted it, so the corpus loop could
    // report N shaders checked having checked none of them.
    const module = try parseOk(arena, src);

    var builder = try RenamePolicy.Builder.init(arena, module.symbols.items.len);
    builder.markEntryPoints(module);
    builder.markBuiltinsAndOverrides(module);
    builder.markExternalBindings(module);
    const policy = builder.build();

    for (module.symbols.items, 0..) |sym, i| {
        const ref: Ast.SymbolIndex = @enumFromInt(@as(u32, @intCast(i)));
        if (sym.flags.is_entry_point or sym.flags.is_external_binding or
            sym.kind == .builtin or sym.kind == .override)
        {
            try std.testing.expect(policy.mustNotRename(ref));
        }
    }
}

test "rename_policy: builder pins entry points + bindings on synthetic shader" {
    const src: [:0]const u8 =
        \\@compute @workgroup_size(1) fn main() {}
        \\fn helper() -> i32 { return 1; }
        \\@vertex fn v() -> @builtin(position) vec4<f32> { return vec4<f32>(0.0); }
        \\@group(0) @binding(0) var<uniform> u: f32;
        \\override SCALE: f32 = 1.0;
    ;
    try checkBuilderPinsEntryPointsAndBindings(std.testing.allocator, src);
}

test "rename_policy: builder pins entry points + bindings on compute.toys corpus" {
    const n = try forEachComputeToysShader(std.testing.allocator, checkBuilderPinsEntryPointsAndBindings);
    if (n == 0) {
        std.debug.print("skip: compute.toys directory missing\n", .{});
        return;
    }
    std.debug.print("rename_policy builder pin parity: verified on {d} compute.toys shaders\n", .{n});
}
