//! Integration tests for the Liveness side-table.
//!
//! After B.M5 deleted `Symbol.flags.is_live`, only one invariant
//! survives at this layer: running `wgslender.minify` on a shader
//! produces output whose live decl set matches a fresh `Dce.mark`
//! over a re-parse of the same shader. Proves that the production
//! minify path threads a `Liveness` through end-to-end and doesn't
//! accidentally drop a write.
//!
//! The invariant runs over the curated `compute.toys` corpus when it
//! is available; the test skips cleanly otherwise.

const std = @import("std");
const wgslender = @import("wgslender");

const Ast = wgslender.Ast;
const Dce = wgslender.Dce;
const Liveness = wgslender.Liveness;
const parseOk = @import("parse_ok.zig").parseOk;

// =========================================================================
// Liveness sanity: no-entry-points fallback marks every symbol live.
// =========================================================================

test "liveness: Dce.mark no-entry-points fallback marks every symbol live" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Library mode: no entry points → DCE keeps everything.
    const src: [:0]const u8 = "fn a() -> i32 { return 1; } fn b() -> i32 { return 2; }";
    const module = try parseOk(arena, src);

    var liveness = try Liveness.init(arena, module.symbols.items.len);
    _ = try Dce.mark(arena, module, &liveness);

    for (module.symbols.items, 0..) |_, i| {
        try std.testing.expect(liveness.isLive(@intCast(i)));
    }
}

// =========================================================================
// Invariant — minify output drops dead decls per a fresh Dce.mark
// (synthetic shader only — the corpus version would need word-boundary
// reasoning to avoid false positives like "float" inside "float32").
// =========================================================================

fn checkMinifyDceDecls(gpa: std.mem.Allocator, src: [:0]const u8) anyerror!void {
    var result = try wgslender.minifyWithOptions(gpa, src, .{});
    defer result.deinit(gpa);

    // The caller's fixture is hand-written and expected to minify cleanly.
    // This used to `return` here, which made the whole check vacuous whenever
    // the fixture failed to parse — and it did: `_ = 1;` was a parse error
    // until phony assignment landed, so this test asserted nothing at all.
    if (result.errors.len > 0) {
        for (result.errors) |e| std.debug.print("minify error at byte {d}: {s}\n", .{ e.pos, e.message });
        return error.FixtureDidNotMinifyCleanly;
    }

    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const module = try parseOk(arena, src);

    var fresh = try Liveness.init(arena, module.symbols.items.len);
    _ = try Dce.mark(arena, module, &fresh);

    var dead_names = std.StringHashMapUnmanaged(void){};
    for (module.declarations.items) |decl| {
        const ref = decl.nameRef();
        if (!ref.isValid()) continue;
        const idx = ref.index();
        if (idx >= module.symbols.items.len) continue;
        if (fresh.isLive(idx)) continue;
        const name = module.symbols.items[idx].original_name;
        if (name.len == 0) continue;
        try dead_names.put(arena, name, {});
    }

    var it = dead_names.keyIterator();
    while (it.next()) |name_ptr| {
        if (std.mem.indexOf(u8, result.code, name_ptr.*)) |_| {
            std.debug.print(
                "minified output retains dead decl name '{s}'\n",
                .{name_ptr.*},
            );
            return error.DeadDeclSurvivedMinify;
        }
    }
}

test "liveness: minify drops dead decls per fresh Dce on synthetic shader" {
    const src: [:0]const u8 =
        \\const dead_const_xyz = 2;
        \\fn dead_helper_xyz() -> i32 { return 1; }
        \\@compute @workgroup_size(1) fn main() { _ = 1; }
    ;
    try checkMinifyDceDecls(std.testing.allocator, src);
}
