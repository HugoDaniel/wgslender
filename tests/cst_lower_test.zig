//! Equivalence tests for `CstLower.lowerTree`.
//!
//! For every shader fixture we run two front-ends in parallel:
//!   1. `Parser.parse` (reference) — produces `Ast.Module` + CST.
//!   2. `CstLower.lowerTree(cst)` (under test) — produces `Ast.Module` by
//!      walking the same CST green tree.
//!
//! The two modules must be structurally identical, including per-symbol
//! `use_count` parity (which proves Pass 2 ran identically on both).

const std = @import("std");
const wgslender = @import("wgslender");

const Ast = wgslender.Ast;
const Cst = wgslender.Cst;
const CstLower = wgslender.CstLower;
const Lexer = wgslender.Lexer;
const Parser = wgslender.Parser;

const ast_equal = @import("ast_equal.zig");

/// Run both front-ends against the same source and assert equivalence.
fn assertEquivalent(gpa: std.mem.Allocator, source_bytes: []const u8) !void {
    // Reference path — one arena for the whole run.
    var ref_arena = std.heap.ArenaAllocator.init(gpa);
    defer ref_arena.deinit();
    const ra = ref_arena.allocator();

    const source = try ra.allocSentinel(u8, source_bytes.len, 0);
    @memcpy(source, source_bytes);

    var all_tokens = try Lexer.tokenizeAll(ra, source);
    const stream = try Parser.TokenStream.init(ra, &all_tokens);

    var builder = Cst.Builder.init(gpa);
    defer builder.deinit();
    var parser = try Parser.initWithCst(ra, source, stream, &builder);
    const ref_module = try parser.parse();

    var cst_tree = try builder.finish(ra, all_tokens, source);
    // No deinit — tree borrows from the arena.

    // Lowered path — a separate arena so the modules don't share pointers.
    var low_arena = std.heap.ArenaAllocator.init(gpa);
    defer low_arena.deinit();
    const la = low_arena.allocator();

    const lowered = try CstLower.lowerTree(gpa, la, &cst_tree);
    try ast_equal.expectModulesEqual(ref_module, lowered);
}

test "cst_lower: empty module" {
    try assertEquivalent(std.testing.allocator, "");
}

test "cst_lower: enable directive" {
    try assertEquivalent(std.testing.allocator, "enable f16;");
}

test "cst_lower: multi-feature directives" {
    try assertEquivalent(std.testing.allocator,
        \\enable f16, subgroups;
        \\requires dual_source_blending;
        \\diagnostic(error, derivative_uniformity);
        \\
    );
}

test "cst_lower: const_decl literal" {
    try assertEquivalent(std.testing.allocator, "const x = 1;");
}

test "cst_lower: const_decl with type and float" {
    try assertEquivalent(std.testing.allocator, "const pi: f32 = 3.14;");
}

test "cst_lower: numeric literal edge cases (lexer-boundary parity)" {
    // Both front-ends must record the literal's `value` as the lexer's own
    // byte-exact slice. `1.e5` (dot-then-exponent, §6.1.2) and `2.f` (dot then
    // float suffix) are the edge cases where a hand-rolled re-scanner drifted
    // from `Lexer.Token.end`.
    try assertEquivalent(std.testing.allocator, "const a = 1.e5;");
    try assertEquivalent(std.testing.allocator, "const b = 2.f;");
    try assertEquivalent(std.testing.allocator, "const c = 0x1.8p2;");
    try assertEquivalent(std.testing.allocator, "const d = 1e5f;");
}

test "cst_lower: override_decl" {
    try assertEquivalent(std.testing.allocator, "@id(0) override workgroup_x: u32 = 16;");
}

test "cst_lower: var_decl with address space + access" {
    try assertEquivalent(std.testing.allocator,
        \\@group(0) @binding(0) var<uniform> u: f32;
        \\@group(0) @binding(1) var<storage, read_write> s: array<u32, 4>;
        \\
    );
}

test "cst_lower: alias_decl" {
    try assertEquivalent(std.testing.allocator, "alias MyF = f32;");
}

test "cst_lower: const_assert" {
    try assertEquivalent(std.testing.allocator, "const_assert 1 < 2;");
}

test "cst_lower: struct_decl" {
    try assertEquivalent(std.testing.allocator,
        \\struct Vertex {
        \\    @location(0) pos: vec3<f32>,
        \\    @location(1) uv: vec2<f32>,
        \\};
        \\
    );
}

test "cst_lower: function with params and body" {
    try assertEquivalent(std.testing.allocator,
        \\fn add(a: f32, b: f32) -> f32 {
        \\    return a + b;
        \\}
        \\
    );
}

test "cst_lower: nested expressions" {
    try assertEquivalent(std.testing.allocator,
        \\fn f(a: f32, b: f32, c: f32) -> f32 {
        \\    return a + b * c - (a + b) / c;
        \\}
        \\
    );
}

test "cst_lower: control flow — if/else" {
    try assertEquivalent(std.testing.allocator,
        \\fn f(x: i32) -> i32 {
        \\    if (x > 0) {
        \\        return 1;
        \\    } else if (x < 0) {
        \\        return -1;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
        \\
    );
}

test "cst_lower: for and while loops" {
    try assertEquivalent(std.testing.allocator,
        \\fn f() {
        \\    var i: i32 = 0;
        \\    for (var j: i32 = 0; j < 10; j++) {
        \\        i = i + j;
        \\    }
        \\    while (i > 0) {
        \\        i = i - 1;
        \\    }
        \\}
        \\
    );
}

test "cst_lower: loop with continuing block" {
    try assertEquivalent(std.testing.allocator,
        \\fn f() {
        \\    var i: i32 = 0;
        \\    loop {
        \\        if (i >= 10) { break; }
        \\        continuing {
        \\            i = i + 1;
        \\        }
        \\    }
        \\}
        \\
    );
}

test "cst_lower: switch statement" {
    try assertEquivalent(std.testing.allocator,
        \\fn f(x: i32) -> i32 {
        \\    switch x {
        \\        case 0, 1: { return 10; }
        \\        case 2: { return 20; }
        \\        default: { return -1; }
        \\    }
        \\}
        \\
    );
}

test "cst_lower: types — vec, mat, array, ptr, atomic" {
    try assertEquivalent(std.testing.allocator,
        \\struct S {
        \\    v: vec3<f32>,
        \\    m: mat2x3<f32>,
        \\    a: array<u32, 4>,
        \\};
        \\@group(0) @binding(0) var<storage, read_write> counter: atomic<u32>;
        \\fn f(p: ptr<function, f32>) -> f32 { return *p; }
        \\
    );
}

test "cst_lower: textures and samplers" {
    try assertEquivalent(std.testing.allocator,
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var smp: sampler;
        \\@group(0) @binding(2) var depth: texture_depth_2d;
        \\@group(0) @binding(3) var storageTex: texture_storage_2d<rgba8unorm, write>;
        \\
    );
}

test "cst_lower: calls and constructors" {
    try assertEquivalent(std.testing.allocator,
        \\fn f() -> vec3<f32> {
        \\    let v = vec3<f32>(1.0, 2.0, 3.0);
        \\    let u = dot(v, v);
        \\    return v * u;
        \\}
        \\
    );
}

test "cst_lower: index + member + paren expressions" {
    try assertEquivalent(std.testing.allocator,
        \\struct S { x: f32, y: f32 };
        \\fn f(s: S, arr: array<i32, 4>) -> f32 {
        \\    let a = arr[0];
        \\    let b = s.x;
        \\    let c = (s.x + s.y) * 2.0;
        \\    return c;
        \\}
        \\
    );
}

test "cst_lower: full compute.toys corpus" {
    const io = std.Options.debug_io;
    const dir_path = "tests/testdata/compute.toys";

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound or err == error.NotFound) {
            std.debug.print("skip: compute.toys directory missing\n", .{});
            return;
        }
        return err;
    };
    defer dir.close(io);

    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    var n: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".wgsl")) continue;

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const alloc = arena.allocator();

        const source_bytes = entry.dir.readFileAlloc(io, entry.basename, alloc, .unlimited) catch continue;

        assertEquivalent(gpa, source_bytes) catch |err| {
            std.debug.print("CstLower equivalence failure on {s}: {s}\n", .{ entry.path, @errorName(err) });
            return err;
        };
        n += 1;
    }
    std.debug.print("cst_lower: equivalence verified on {d} compute.toys shaders\n", .{n});
}

test "cst_lower: top-level testdata shaders" {
    const io = std.Options.debug_io;

    var dir = std.Io.Dir.cwd().openDir(io, "tests/testdata", .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound or err == error.NotFound) {
            std.debug.print("skip: testdata directory missing\n", .{});
            return;
        }
        return err;
    };
    defer dir.close(io);

    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var iter = dir.iterate();
    var n: usize = 0;
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".wgsl")) continue;

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const alloc = arena.allocator();

        const source_bytes = dir.readFileAlloc(io, entry.name, alloc, .unlimited) catch continue;

        assertEquivalent(gpa, source_bytes) catch |err| {
            std.debug.print("CstLower equivalence failure on {s}: {s}\n", .{ entry.name, @errorName(err) });
            return err;
        };
        n += 1;
    }
    std.debug.print("cst_lower: equivalence verified on {d} top-level testdata shaders\n", .{n});
}
