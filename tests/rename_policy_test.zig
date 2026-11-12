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
const Incremental = wgslender.Incremental;
const RenamePolicy = wgslender.RenamePolicy;
const Renamer = wgslender.Renamer;
const UseCounts = wgslender.UseCounts;
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

// =========================================================================
// Retired tombstones
// =========================================================================

test "retired symbols neither reserve nor receive rename names" {
    const gpa = std.testing.allocator;

    // --- Module-wide Builder scans ignore tombstones ---------------------
    // Real tombstone: a compound splice re-lowers the body, leaving the old
    // `keep` declaration behind with `is_retired = true` and a fresh copy in
    // the active subtree. `keep_names` is a name-based scan, so without the
    // filter it would pin the tombstone too.
    const src: [:0]const u8 = "fn f() -> i32 { let keep: i32 = 1; _ = keep; return 0; }";
    var state = try Incremental.parseFull(gpa, src);
    defer state.deinit();

    const ret_at: u32 = @intCast(std.mem.indexOf(u8, src, "return 0;").?);
    const next = try Incremental.reparse(gpa, &state, .{
        .start = ret_at,
        .end = ret_at,
        .new_text = " ",
    });
    state.deinit();
    state = next;
    try std.testing.expect(state.reused);

    var retired: ?Ast.SymbolIndex = null;
    var fresh: ?Ast.SymbolIndex = null;
    for (state.module.symbols.items, 0..) |sym, i| {
        if (sym.kind != .let or !std.mem.eql(u8, sym.original_name, "keep")) continue;
        const ref: Ast.SymbolIndex = @enumFromInt(@as(u32, @intCast(i)));
        if (sym.flags.is_retired) retired = ref else fresh = ref;
    }
    try std.testing.expect(retired != null);
    try std.testing.expect(fresh != null);

    var policy_arena = std.heap.ArenaAllocator.init(gpa);
    defer policy_arena.deinit();
    var builder = try RenamePolicy.Builder.init(policy_arena.allocator(), state.module.symbols.items.len);
    builder.markKeepNames(state.module, &.{"keep"});
    const policy = builder.build();

    try std.testing.expect(!policy.mustNotRename(retired.?));
    try std.testing.expectEqual(RenamePolicy.Reason.none, policy.reasonFor(retired.?));
    try std.testing.expect(policy.mustNotRename(fresh.?));
    try std.testing.expectEqual(RenamePolicy.Reason.keep_names, policy.reasonFor(fresh.?));

    // --- Renamer slot allocation / reservation --------------------------
    // Pure unit style: `MinifyRenamer` only reads the symbol slice and its
    // side tables, so no scope tree is involved. The retired symbol carries
    // a higher use count than the active one; a tombstone must neither take
    // the shortest slot nor reserve its short name away from the live
    // declaration.
    var symbols = [_]Ast.Symbol{
        .{ .original_name = "a", .kind = .let, .flags = .{ .is_retired = true } },
        .{ .original_name = "z", .kind = .let, .flags = .{} },
    };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var use_counts = try UseCounts.init(arena, symbols.len);
    var none_policy = try RenamePolicy.init(arena, symbols.len);
    const reserved = std.StringHashMapUnmanaged(void){};

    var renamer = Renamer.MinifyRenamer.init(arena, &symbols, reserved);
    renamer.setSideTables(&use_counts, &none_policy);
    renamer.renamer.ptr = @ptrCast(&renamer);
    defer {
        renamer.slots.deinit(arena);
        renamer.top_level_slots.deinit(arena);
        renamer.name_buf.deinit(arena);
        renamer.name_offsets.deinit(arena);
    }

    var uses = std.AutoHashMapUnmanaged(Ast.SymbolIndex, u32){};
    defer uses.deinit(arena);
    try uses.put(arena, @as(Ast.SymbolIndex, @enumFromInt(0)), 5);
    try uses.put(arena, @as(Ast.SymbolIndex, @enumFromInt(1)), 1);

    renamer.accumulateSymbolUseCounts(&uses);
    // The retired count never reaches the canonical side-table.
    try std.testing.expectEqual(@as(u32, 0), use_counts.counts[0]);

    try renamer.allocateSlots();
    try renamer.reserveUnrenamedSymbolNames();
    try renamer.assignNames();

    // Direct lookup on the tombstone is empty, not its original name.
    try std.testing.expectEqualStrings(
        "",
        renamer.renamer.nameForSymbol(@as(Ast.SymbolIndex, @enumFromInt(0))),
    );
    // The active symbol gets the first name; the tombstone's `a` was not
    // reserved because it belongs only to a retired declaration.
    try std.testing.expectEqualStrings(
        "a",
        renamer.renamer.nameForSymbol(@as(Ast.SymbolIndex, @enumFromInt(1))),
    );
}
