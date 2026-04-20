//! Long-tail mutation scenarios for `Incremental.reparse` (M1–M8).
//!
//! Each scenario stresses a different branch in the hot-path slot finder
//! (`findAstSlot` family), the scope map (`scopeAtCstNode`), the span-shift
//! pass (`shiftAstSpans`), or the AstVisit add/sub walks. Per-symbol
//! `use_count` is verified against a `parseFull` oracle so subtractive
//! bugs that aggregate counters miss are caught here.

const std = @import("std");
const wgslender = @import("wgslender");

const Ast = wgslender.Ast;
const Incremental = wgslender.Incremental;

// =========================================================================
// Harness — mirror of `incremental_addsub_test.zig` so callers can swap
// freely between the two files.
// =========================================================================

fn useCountOf(module: *const Ast.Module, name: []const u8) u32 {
    for (module.symbols.items) |s| {
        if (std.mem.eql(u8, s.original_name, name)) return s.use_count;
    }
    return 0;
}

fn expectUseCountsMatch(got: *const Ast.Module, oracle: *const Ast.Module) !void {
    try std.testing.expectEqual(oracle.symbols.items.len, got.symbols.items.len);
    for (got.symbols.items) |g| {
        const o_uc = useCountOf(oracle, g.original_name);
        if (o_uc != g.use_count) {
            std.debug.print(
                "use_count mismatch: '{s}' got={d} oracle={d}\n",
                .{ g.original_name, g.use_count, o_uc },
            );
            return error.UseCountMismatch;
        }
    }
}

fn renderShape(
    gpa: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    m: *const Ast.Module,
) !void {
    try buf.appendSlice(gpa, "(module");
    for (m.declarations.items) |d| {
        try buf.append(gpa, ' ');
        try buf.appendSlice(gpa, @tagName(d));
    }
    try buf.appendSlice(gpa, ")");
}

fn expectShapesMatch(gpa: std.mem.Allocator, a: *const Ast.Module, b: *const Ast.Module) !void {
    var ab: std.ArrayListUnmanaged(u8) = .empty;
    defer ab.deinit(gpa);
    var bb: std.ArrayListUnmanaged(u8) = .empty;
    defer bb.deinit(gpa);
    try renderShape(gpa, &ab, a);
    try renderShape(gpa, &bb, b);
    try std.testing.expectEqualStrings(ab.items, bb.items);
}

fn runEdit(
    gpa: std.mem.Allocator,
    base_src: [:0]const u8,
    edit: Incremental.Edit,
    expected_new_src: []const u8,
    expect_reused: bool,
) !void {
    var base = try Incremental.parseFull(gpa, base_src);
    defer base.deinit();

    var updated = try Incremental.reparse(gpa, &base, edit);
    defer updated.deinit();

    try std.testing.expectEqualStrings(expected_new_src, updated.source);
    try std.testing.expectEqual(expect_reused, updated.reused);

    var oracle = try Incremental.parseFull(gpa, updated.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, updated.module, oracle.module);
    try expectUseCountsMatch(updated.module, oracle.module);
}

/// Locate the byte index of `needle`'s first occurrence in `haystack`, as a
/// `u32` so it can be used directly in `Incremental.Edit`.
fn at(haystack: []const u8, needle: []const u8) u32 {
    return @intCast(std.mem.indexOf(u8, haystack, needle).?);
}

// =========================================================================
// M1 — Attribute-argument expression mutation.
//
// Stresses the only path through which a hot-path anchor can land inside
// an attribute: `findSlotInAttribute` (`src/Incremental.zig:1122`).
// `AstVisit.visitDecl` deliberately does NOT walk `attr.args`, so attribute
// arguments contribute nothing to `use_count` in either the original parse
// or the oracle — making M1's correctness oracle especially sharp:
// per-symbol counts must be unchanged across an attribute-arg edit, no
// matter what idents the edit introduces or removes.
// =========================================================================

test "M1.a: workgroup_size literal flip on fn main" {
    const src: [:0]const u8 = "@compute @workgroup_size(8) fn main() {}";
    const new_src: []const u8 = "@compute @workgroup_size(16) fn main() {}";
    const lit_off = at(src, "8");
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = lit_off, .end = lit_off + 1, .new_text = "16" },
        new_src,
        true,
    );
}

test "M1.b: @group literal flip on a var binding" {
    const src: [:0]const u8 = "@group(0) @binding(0) var<uniform> u: f32;";
    const new_src: []const u8 = "@group(1) @binding(0) var<uniform> u: f32;";
    const lit_off = at(src, "(0)");
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = lit_off + 1, .end = lit_off + 2, .new_text = "1" },
        new_src,
        true,
    );
}

test "M1.c: @binding literal flip on a var binding" {
    const src: [:0]const u8 = "@group(0) @binding(0) var<uniform> u: f32;";
    const new_src: []const u8 = "@group(0) @binding(3) var<uniform> u: f32;";
    // Find the SECOND `(0)` — i.e., binding's argument.
    const first = at(src, "(0)");
    const second = at(src[first + 1 ..], "(0)") + first + 1;
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = second + 1, .end = second + 2, .new_text = "3" },
        new_src,
        true,
    );
}

test "M1.d: @align literal flip on a struct member attribute" {
    const src: [:0]const u8 = "struct S { @align(16) x: f32, y: i32 }";
    const new_src: []const u8 = "struct S { @align(8) x: f32, y: i32 }";
    const lit_off = at(src, "16");
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = lit_off, .end = lit_off + 2, .new_text = "8" },
        new_src,
        true,
    );
}

test "M1.e: workgroup_size second-arg literal flip" {
    const src: [:0]const u8 = "@compute @workgroup_size(8, 8) fn main() {}";
    const new_src: []const u8 = "@compute @workgroup_size(8, 16) fn main() {}";
    // Find the second `8` (after the comma).
    const comma = at(src, ",");
    const second_eight = at(src[comma..], "8") + comma;
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = second_eight, .end = second_eight + 1, .new_text = "16" },
        new_src,
        true,
    );
}

test "M1.f: @location literal flip on an entry-point return attribute" {
    const src: [:0]const u8 = "@vertex fn main() -> @location(0) vec4<f32> { return vec4<f32>(0.0); }";
    const new_src: []const u8 = "@vertex fn main() -> @location(2) vec4<f32> { return vec4<f32>(0.0); }";
    const lit_off: u32 = at(src, "@location(") + @as(u32, @intCast("@location(".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = lit_off, .end = lit_off + 1, .new_text = "2" },
        new_src,
        true,
    );
}

// =========================================================================
// M2 — Type-expression mutation falls back gracefully.
//
// `findSlotInDecl` (`src/Incremental.zig:1088–1119`) intentionally does NOT
// descend into `typ` / `return_type` fields. Any edit whose innermost
// reparse anchor lives inside a type expression must therefore promote up
// the parent chain until it either finds a hot-path anchor (none exists
// at module scope) or hits the root → fallback.
//
// These tests pin that contract: a future "improvement" to the slot
// finder that recurses into types would silently produce wrong AST state
// without an oracle here.
// =========================================================================

test "M2.a: array<f32, N> size-expr ident swap falls back" {
    const src: [:0]const u8 = "const N: u32 = 8; const K: u32 = 16; var<private> u: array<f32, N>;";
    const new_src: []const u8 = "const N: u32 = 8; const K: u32 = 16; var<private> u: array<f32, K>;";
    // The `N` we want lives inside `array<f32, N>` — last `N` in the source.
    const n_off: u32 = @intCast(std.mem.lastIndexOfScalar(u8, src, 'N').?);
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = n_off, .end = n_off + 1, .new_text = "K" },
        new_src,
        false,
    );
}

test "M2.b: struct member vec3 → vec4 falls back" {
    const src: [:0]const u8 = "struct S { x: vec3<f32>, y: i32 }";
    const new_src: []const u8 = "struct S { x: vec4<f32>, y: i32 }";
    const off: u32 = at(src, "vec3") + 3; // index of '3' in 'vec3'
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = off, .end = off + 1, .new_text = "4" },
        new_src,
        false,
    );
}

test "M2.c: ptr<storage, …> → ptr<workgroup, …> on a struct member falls back" {
    // ptrs are uncommon as struct-member types but still parseable and the
    // type-span machinery handles them. The point of this test is that a
    // pure address-space token swap inside a `type_ptr` falls back.
    const src: [:0]const u8 = "struct S { p: ptr<storage, f32, read_write> }";
    const new_src: []const u8 = "struct S { p: ptr<workgroup, f32, read_write> }";
    const off: u32 = at(src, "storage");
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = off, .end = off + @as(u32, @intCast("storage".len)), .new_text = "workgroup" },
        new_src,
        false,
    );
}

test "M2.d: function return type f32 → vec2<f32> falls back" {
    const src: [:0]const u8 = "fn f() -> f32 { return 0.0; }";
    const new_src: []const u8 = "fn f() -> vec2<f32> { return vec2<f32>(0.0); }";
    // Replace " f32 { return 0.0;" → " vec2<f32> { return vec2<f32>(0.0);"
    const ret_arrow: u32 = at(src, "-> f32 {");
    const old_chunk: []const u8 = "-> f32 { return 0.0;";
    const new_chunk: []const u8 = "-> vec2<f32> { return vec2<f32>(0.0);";
    try runEdit(
        std.testing.allocator,
        src,
        .{
            .start = ret_arrow,
            .end = ret_arrow + @as(u32, @intCast(old_chunk.len)),
            .new_text = new_chunk,
        },
        new_src,
        false,
    );
}

test "M2.e: nested array<vec3<f32>, 4> → array<vec4<f32>, 4> falls back" {
    const src: [:0]const u8 = "var<private> u: array<vec3<f32>, 4>;";
    const new_src: []const u8 = "var<private> u: array<vec4<f32>, 4>;";
    const off: u32 = at(src, "vec3") + 3;
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = off, .end = off + 1, .new_text = "4" },
        new_src,
        false,
    );
}

// =========================================================================
// M3 — `for`-loop compartment mutations exercise the for-scope map.
//
// `for_stmt` is a scope opener (`isScopeOpener`,
// `src/Incremental.zig:128`); its CST node maps to an AST scope holding
// the for-init local. A hot-path anchor inside the condition or update
// must therefore resolve via `scopeAtCstNode` → for-scope so the local is
// visible. `findSlotInStmt` for `.@"for"` (`src/Incremental.zig:1179`)
// descends into init/condition/update/body — these tests pin down each
// compartment.
// =========================================================================

test "M3.a: for-condition operator flip (binary_expr anchor)" {
    const src: [:0]const u8 =
        "fn f() { let limit = 5; for (var i = 0; i < limit; i = i + 1) {} }";
    const new_src: []const u8 =
        "fn f() { let limit = 5; for (var i = 0; i <= limit; i = i + 1) {} }";
    // Replace the entire `i < limit` binary expression so the new subtree
    // is also a binary_expr (kind-stable hot path).
    const cond_off: u32 = at(src, "i < limit");
    try runEdit(
        std.testing.allocator,
        src,
        .{
            .start = cond_off,
            .end = cond_off + @as(u32, @intCast("i < limit".len)),
            .new_text = "i <= limit",
        },
        new_src,
        true,
    );
}

test "M3.b: for-condition RHS literal swap (literal_expr anchor)" {
    const src: [:0]const u8 = "fn f() { for (var i = 0; i < 10; i = i + 1) {} }";
    const new_src: []const u8 = "fn f() { for (var i = 0; i < 5; i = i + 1) {} }";
    const lit_off: u32 = at(src, "< 10") + 2;
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = lit_off, .end = lit_off + 2, .new_text = "5" },
        new_src,
        true,
    );
}

test "M3.c: for-condition RHS ident swap to sibling const (ident_expr anchor)" {
    const src: [:0]const u8 =
        "const N: i32 = 8; const K: i32 = 16; fn f() { for (var i = 0; i < N; i = i + 1) {} }";
    const new_src: []const u8 =
        "const N: i32 = 8; const K: i32 = 16; fn f() { for (var i = 0; i < K; i = i + 1) {} }";
    // The `N` we want is the one inside `i < N`.
    const probe_off: u32 = at(src, "< N") + 2;
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = probe_off, .end = probe_off + 1, .new_text = "K" },
        new_src,
        true,
    );
}

test "M3.d: for-update binary RHS swap to sibling local (binary_expr anchor)" {
    // `step` is declared before the `for`, so text-order visibility allows
    // resolving it from inside the for-update's RHS.
    const src: [:0]const u8 =
        "fn f() { let step = 2; for (var i = 0; i < 10; i = i + 1) {} }";
    const new_src: []const u8 =
        "fn f() { let step = 2; for (var i = 0; i < 10; i = i + step) {} }";
    // Replace the binary `i + 1` so the new subtree stays binary_expr.
    const bin_off: u32 = at(src, "i + 1");
    try runEdit(
        std.testing.allocator,
        src,
        .{
            .start = bin_off,
            .end = bin_off + @as(u32, @intCast("i + 1".len)),
            .new_text = "i + step",
        },
        new_src,
        true,
    );
}

test "M3.e: for-init initializer literal swap (literal_expr anchor)" {
    const src: [:0]const u8 = "fn f() { for (var i = 0; i < 10; i = i + 1) {} }";
    const new_src: []const u8 = "fn f() { for (var i = 5; i < 10; i = i + 1) {} }";
    const init_lit: u32 = at(src, "var i = 0") + @as(u32, @intCast("var i = ".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = init_lit, .end = init_lit + 1, .new_text = "5" },
        new_src,
        true,
    );
}

test "M3.f: 10 successive literal flips on for-update keep hot path" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "fn f() { for (var i = 0; i < 10; i = i + 1) {} }";
    var prev = try Incremental.parseFull(gpa, src);
    defer prev.deinit();

    // Position of the trailing `1` in `i + 1` (the for-update RHS literal).
    // Length stays at 1 byte through every cycle so the offset is stable.
    const lit_off: u32 = at(src, "i + 1") + 4;
    var i: u8 = 0;
    while (i < 10) : (i += 1) {
        const ch: u8 = '0' + ((i + 1) % 10);
        const new_text = [_]u8{ch};
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = lit_off,
            .end = lit_off + 1,
            .new_text = &new_text,
        });
        try std.testing.expect(next.reused);
        // Spot-check: declarations + symbol set match the oracle on every step.
        var oracle = try Incremental.parseFull(gpa, next.source);
        defer oracle.deinit();
        try expectShapesMatch(gpa, next.module, oracle.module);
        try expectUseCountsMatch(next.module, oracle.module);

        prev.deinit();
        prev = next;
    }
}

// =========================================================================
// M4 — `switch` / `case` selector & body mutations.
//
// `findSlotInStmt` for `.@"switch"` (`src/Incremental.zig:1169`) walks
// the switch subject expr, then per-case `selectors` and `body`. Selectors
// are visited via `visitExpr` in the *switch's enclosing scope* (not the
// case body's scope) — `AstVisit.processOneStmt` line 170. These tests
// exercise selector literal/ident mutations and case-body return-stmt
// mutations, plus the cross-case fallback.
// =========================================================================

test "M4.a: case literal selector flip (literal_expr anchor)" {
    const src: [:0]const u8 = "fn f(t: i32) { switch t { case 0: {} default: {} } }";
    const new_src: []const u8 = "fn f(t: i32) { switch t { case 1: {} default: {} } }";
    const sel: u32 = at(src, "case 0:") + @as(u32, @intCast("case ".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = sel, .end = sel + 1, .new_text = "1" },
        new_src,
        true,
    );
}

test "M4.b: case multi-selector second-arg literal flip" {
    const src: [:0]const u8 = "fn f(t: i32) { switch t { case 0, 1: {} default: {} } }";
    const new_src: []const u8 = "fn f(t: i32) { switch t { case 0, 2: {} default: {} } }";
    // Second selector literal is the `1` after the comma.
    const comma: u32 = at(src, ",");
    const second_sel: u32 = at(src[comma..], "1") + comma;
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = second_sel, .end = second_sel + 1, .new_text = "2" },
        new_src,
        true,
    );
}

test "M4.c: case selector ident swap to sibling const (ident_expr anchor)" {
    const src: [:0]const u8 =
        "const A: i32 = 1; const B: i32 = 2; fn f(t: i32) { switch t { case A: {} default: {} } }";
    const new_src: []const u8 =
        "const A: i32 = 1; const B: i32 = 2; fn f(t: i32) { switch t { case B: {} default: {} } }";
    const sel: u32 = at(src, "case A:") + @as(u32, @intCast("case ".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = sel, .end = sel + 1, .new_text = "B" },
        new_src,
        true,
    );
}

test "M4.d: case-body return value swap (return_stmt anchor)" {
    const src: [:0]const u8 =
        "fn f(t: i32) -> i32 { switch t { case 0: { return 1; } default: { return 0; } } }";
    const new_src: []const u8 =
        "fn f(t: i32) -> i32 { switch t { case 0: { return 7; } default: { return 0; } } }";
    // Replace the entire `return 1;` so the new subtree is also a
    // return_stmt (kind-stable hot path).
    const ret_off: u32 = at(src, "return 1;");
    try runEdit(
        std.testing.allocator,
        src,
        .{
            .start = ret_off,
            .end = ret_off + @as(u32, @intCast("return 1;".len)),
            .new_text = "return 7;",
        },
        new_src,
        true,
    );
}

test "M4.f: edit spanning two top-level fns falls back" {
    // No common compound_stmt enclosure — `findAnchor` walks up to the
    // module root, which is not a hot-path anchor. Triggers full reparse.
    const src: [:0]const u8 =
        "fn f() { return; } fn g() { return; }";
    const new_src: []const u8 =
        "fn fz() { return; } fn gz() { return; }";
    const start: u32 = at(src, "f() { return; } fn g(");
    const old_chunk: []const u8 = "f() { return; } fn g(";
    try runEdit(
        std.testing.allocator,
        src,
        .{
            .start = start,
            .end = start + @as(u32, @intCast(old_chunk.len)),
            .new_text = "fz() { return; } fn gz(",
        },
        new_src,
        false,
    );
}

test "M4.e: edit spanning two case boundaries collapses cases via compound_stmt re-lower" {
    // `findAnchor` cannot find a single switch-internal anchor for an edit
    // that crosses case boundaries — but it CAN promote to the enclosing
    // function-body `compound_stmt`, which is a hot-path anchor that
    // triggers a whole-module re-lower (reused = true). This test pins
    // that behavior so a future change that demotes compound_stmt off the
    // hot-path allowlist surfaces here.
    const src: [:0]const u8 =
        "fn f(t: i32) { switch t { case 0: { return; } case 1: {} default: {} } }";
    const new_src: []const u8 =
        "fn f(t: i32) { switch t { case 0, 1: {} default: {} } }";
    const start: u32 = at(src, "0: { return; } case 1:");
    const old_chunk: []const u8 = "0: { return; } case 1:";
    try runEdit(
        std.testing.allocator,
        src,
        .{
            .start = start,
            .end = start + @as(u32, @intCast(old_chunk.len)),
            .new_text = "0, 1:",
        },
        new_src,
        true,
    );
}

// =========================================================================
// M5 — `if` / `else if` / `else` condition mutations.
//
// `processOneStmt` for `.@"if"` (`src/AstVisit.zig:154`) visits the
// condition in the enclosing scope and pushes the body / else compounds
// (which open their own scopes). `findSlotInStmt`'s `.@"if"` arm
// recurses through `else_branch` so nested `else if` chains stay
// reachable. M5 covers each shape, plus the use-before-declaration
// fallback path through `error.AddWalkRaisedErrors`
// (`src/Incremental.zig:754`).
// =========================================================================

test "M5.a: if-condition operator flip (binary_expr anchor)" {
    const src: [:0]const u8 = "fn f(x: i32) { if x > 0 { return; } }";
    const new_src: []const u8 = "fn f(x: i32) { if x >= 0 { return; } }";
    const cond_off: u32 = at(src, "x > 0");
    try runEdit(
        std.testing.allocator,
        src,
        .{
            .start = cond_off,
            .end = cond_off + @as(u32, @intCast("x > 0".len)),
            .new_text = "x >= 0",
        },
        new_src,
        true,
    );
}

test "M5.b: else-if chain inner literal flip (literal_expr anchor)" {
    const src: [:0]const u8 =
        "fn f(x: i32) { if x > 0 { return; } else if x == 0 { return; } else { return; } }";
    const new_src: []const u8 =
        "fn f(x: i32) { if x > 0 { return; } else if x == 1 { return; } else { return; } }";
    const inner_lit: u32 = at(src, "x == 0") + 5;
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = inner_lit, .end = inner_lit + 1, .new_text = "1" },
        new_src,
        true,
    );
}

test "M5.c: if-condition operand swap (binary_expr anchor)" {
    const src: [:0]const u8 =
        "fn f(a: i32, b: i32) { if a > b { return; } }";
    const new_src: []const u8 =
        "fn f(a: i32, b: i32) { if b > a { return; } }";
    const cond_off: u32 = at(src, "a > b");
    try runEdit(
        std.testing.allocator,
        src,
        .{
            .start = cond_off,
            .end = cond_off + @as(u32, @intCast("a > b".len)),
            .new_text = "b > a",
        },
        new_src,
        true,
    );
}

test "M5.d: edit return value inside if-body (return_stmt anchor)" {
    const src: [:0]const u8 =
        "fn f(x: i32) -> i32 { if x > 0 { return 1; } return 0; }";
    const new_src: []const u8 =
        "fn f(x: i32) -> i32 { if x > 0 { return 7; } return 0; }";
    const ret_off: u32 = at(src, "return 1;");
    try runEdit(
        std.testing.allocator,
        src,
        .{
            .start = ret_off,
            .end = ret_off + @as(u32, @intCast("return 1;".len)),
            .new_text = "return 7;",
        },
        new_src,
        true,
    );
}

test "M5.e: condition references local declared later → hot path with E0102" {
    // The add-walk encounters `y` referenced before its declaration,
    // emits E0102, and surfaces it on the result. Since the bidirectional
    // error-fixup landing, this is no longer a fallback — the hot path
    // succeeds and `result.errors` matches a fresh full parse.
    const src: [:0]const u8 =
        "fn f(x: i32) -> i32 { if x > 0 { return 1; } let y = 2; return y; }";
    const new_src: []const u8 =
        "fn f(x: i32) -> i32 { if x > 0 || y < 0 { return 1; } let y = 2; return y; }";
    const cond_off: u32 = at(src, "x > 0");
    try runEdit(
        std.testing.allocator,
        src,
        .{
            .start = cond_off,
            .end = cond_off + @as(u32, @intCast("x > 0".len)),
            .new_text = "x > 0 || y < 0",
        },
        new_src,
        true,
    );
}

// =========================================================================
// M6 — `loop` / `while` continuing & condition mutations.
//
// Neither `loop_stmt` nor `while_stmt` opens its own scope — only the
// nested compound bodies do. `findSlotInStmt` for `.loop`
// (`src/Incremental.zig:1208`) walks `body` then `continuing`. M6 covers
// while-condition, loop-continuing assign-RHS, break_if condition, and a
// 5-iteration burst.
// =========================================================================

test "M6.a: while-condition RHS ident swap (binary_expr anchor)" {
    const src: [:0]const u8 =
        "fn f(i: i32) { let limit = 10; while i < 0 { } }";
    const new_src: []const u8 =
        "fn f(i: i32) { let limit = 10; while i < limit { } }";
    const cond_off: u32 = at(src, "i < 0");
    try runEdit(
        std.testing.allocator,
        src,
        .{
            .start = cond_off,
            .end = cond_off + @as(u32, @intCast("i < 0".len)),
            .new_text = "i < limit",
        },
        new_src,
        true,
    );
}

test "M6.b: loop continuing assign-RHS swap (binary_expr anchor)" {
    const src: [:0]const u8 =
        "fn f(i: i32) { var k: i32 = 0; loop { continuing { k = k + 1; break if k > 5; } } }";
    const new_src: []const u8 =
        "fn f(i: i32) { var k: i32 = 0; loop { continuing { k = k + 2; break if k > 5; } } }";
    const bin_off: u32 = at(src, "k = k + 1") + @as(u32, @intCast("k = ".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{
            .start = bin_off,
            .end = bin_off + @as(u32, @intCast("k + 1".len)),
            .new_text = "k + 2",
        },
        new_src,
        true,
    );
}

test "M6.c: break-if condition ident swap (ident_expr anchor)" {
    const src: [:0]const u8 =
        "fn f() { var done: bool = false; var stop: bool = true; loop { continuing { break if done; } } }";
    const new_src: []const u8 =
        "fn f() { var done: bool = false; var stop: bool = true; loop { continuing { break if stop; } } }";
    const id_off: u32 = at(src, "break if done") + @as(u32, @intCast("break if ".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{
            .start = id_off,
            .end = id_off + @as(u32, @intCast("done".len)),
            .new_text = "stop",
        },
        new_src,
        true,
    );
}

// =========================================================================
// M7 — Member-access & call-argument chain mutations.
//
// `findSlotInExprField` (`src/Incremental.zig:1237`) descends through
// `.member`, `.index`, `.call`, `.unary`, and `.paren`. M7 covers a deep
// member chain, an inner index-expression edit, mid-call argument swap,
// nested calls, unary, and nested parentheses — each picking a different
// branch of the expression descent.
// =========================================================================

test "M7.a: chained member-access trailing field rename (member_expr anchor)" {
    // Renaming the trailing field `.c` keeps the outermost member_expr
    // shape; the change lands on the member-name token whose parent
    // anchor is the outermost member_expr.
    const src: [:0]const u8 =
        "struct Inner { x: f32 } struct Mid { c: Inner } struct Outer { b: Mid } fn f(o: Outer) -> f32 { return o.b.c.x; }";
    const new_src: []const u8 =
        "struct Inner { x: f32 } struct Mid { c: Inner } struct Outer { b: Mid } fn f(o: Outer) -> f32 { return o.b.c.xx; }";
    const off: u32 = at(src, "o.b.c.x;") + @as(u32, @intCast("o.b.c.".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = off, .end = off + 1, .new_text = "xx" },
        new_src,
        true,
    );
}

test "M7.b: index-expr inner literal swap (literal_expr anchor)" {
    const src: [:0]const u8 =
        "fn f(arr: array<i32, 4>, i: i32) -> i32 { return arr[i + 1]; }";
    const new_src: []const u8 =
        "fn f(arr: array<i32, 4>, i: i32) -> i32 { return arr[i + 2]; }";
    const lit_off: u32 = at(src, "i + 1") + @as(u32, @intCast("i + ".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = lit_off, .end = lit_off + 1, .new_text = "2" },
        new_src,
        true,
    );
}

test "M7.c: third call-arg ident swap to sibling local (ident_expr anchor)" {
    const src: [:0]const u8 =
        "fn g(a: i32, b: i32, c: i32) -> i32 { return a + b + c; } fn f() -> i32 { let x = 1; let y = 2; let z = 3; let w = 4; return g(x, y, z); }";
    const new_src: []const u8 =
        "fn g(a: i32, b: i32, c: i32) -> i32 { return a + b + c; } fn f() -> i32 { let x = 1; let y = 2; let z = 3; let w = 4; return g(x, y, w); }";
    // The third arg is the trailing `z` before the `)`.
    const arg_off: u32 = at(src, "g(x, y, z)") + @as(u32, @intCast("g(x, y, ".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = arg_off, .end = arg_off + 1, .new_text = "w" },
        new_src,
        true,
    );
}

test "M7.d: ident inside nested call argument (ident_expr anchor)" {
    const src: [:0]const u8 =
        "fn g(a: i32) -> i32 { return a; } fn h(a: i32, b: i32) -> i32 { return a; } fn f() -> i32 { let x = 1; let xx = 2; let y = 3; return h(g(x), y); }";
    const new_src: []const u8 =
        "fn g(a: i32) -> i32 { return a; } fn h(a: i32, b: i32) -> i32 { return a; } fn f() -> i32 { let x = 1; let xx = 2; let y = 3; return h(g(xx), y); }";
    const arg_off: u32 = at(src, "h(g(x), y)") + @as(u32, @intCast("h(g(".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = arg_off, .end = arg_off + 1, .new_text = "xx" },
        new_src,
        true,
    );
}

test "M7.e: unary operand ident swap (ident_expr anchor)" {
    const src: [:0]const u8 =
        "fn f() -> i32 { let a = 1; let aa = 2; return -a; }";
    const new_src: []const u8 =
        "fn f() -> i32 { let a = 1; let aa = 2; return -aa; }";
    const id_off: u32 = at(src, "return -a;") + @as(u32, @intCast("return -".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = id_off, .end = id_off + 1, .new_text = "aa" },
        new_src,
        true,
    );
}

test "M7.f: nested paren innermost ident swap (ident_expr anchor)" {
    const src: [:0]const u8 =
        "fn f() -> i32 { let a = 1; let b = 2; let c = 3; let d = 4; return (a + (b + c)); }";
    const new_src: []const u8 =
        "fn f() -> i32 { let a = 1; let b = 2; let c = 3; let d = 4; return (a + (b + d)); }";
    const id_off: u32 = at(src, "(b + c)") + @as(u32, @intCast("(b + ".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = id_off, .end = id_off + 1, .new_text = "d" },
        new_src,
        true,
    );
}

test "M6.d: 5 successive condition flips on a while keep hot path" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 =
        "fn f(i: i32) { let a = 1; let b = 2; while i < 0 { } }";
    var prev = try Incremental.parseFull(gpa, src);
    defer prev.deinit();

    // Cycle the trailing `0` through `0..4` each iteration; offset is
    // stable because the literal stays one byte wide.
    const lit_off: u32 = at(src, "while i < 0") + @as(u32, @intCast("while i < ".len));
    var i: u8 = 0;
    while (i < 5) : (i += 1) {
        const ch: u8 = '0' + ((i + 1) % 5);
        const new_text = [_]u8{ch};
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = lit_off,
            .end = lit_off + 1,
            .new_text = &new_text,
        });
        try std.testing.expect(next.reused);
        var oracle = try Incremental.parseFull(gpa, next.source);
        defer oracle.deinit();
        try expectShapesMatch(gpa, next.module, oracle.module);
        try expectUseCountsMatch(next.module, oracle.module);
        prev.deinit();
        prev = next;
    }
}

// =========================================================================
// M8 — Mixed-anchor mutation churn + retained_arenas growth.
//
// Each successful symbol-free reparse moves `prev.arena` into
// `result.retained_arenas` (`src/Incremental.zig:774`). M8 stresses the
// retention bookkeeping under (a) cross-anchor-kind edit cycles, (b) long
// hot-path bursts that monotonically grow `retained_arenas`, (c) bursts
// that alternate hot path with fallback (each fallback resets retention
// to zero), and (d) per-symbol use_count round-trips on multi-ident
// expressions.
// =========================================================================

test "M8.a: 4-edit round-trip across literal/binary/return/attribute returns to base" {
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 =
        "@compute @workgroup_size(8) fn f() -> i32 { let a = 1; return a + 2; }";

    var step0 = try Incremental.parseFull(gpa, base_src);
    defer step0.deinit();

    // 1. Flip the return-value literal `2` → `5`. Anchor: literal_expr.
    const lit_off: u32 = at(base_src, "a + 2") + 4;
    var step1 = try Incremental.reparse(gpa, &step0, .{
        .start = lit_off,
        .end = lit_off + 1,
        .new_text = "5",
    });
    defer step1.deinit();
    try std.testing.expect(step1.reused);

    // 2. Inverse: flip back `5` → `2` on the same byte. Anchor: literal_expr.
    var step2 = try Incremental.reparse(gpa, &step1, .{
        .start = lit_off,
        .end = lit_off + 1,
        .new_text = "2",
    });
    defer step2.deinit();
    try std.testing.expect(step2.reused);

    // 3. Flip the workgroup_size literal `8` → `16`. Anchor: literal_expr
    //    inside attribute_args.
    const wg_off: u32 = at(step2.source, "@workgroup_size(") + @as(u32, @intCast("@workgroup_size(".len));
    var step3 = try Incremental.reparse(gpa, &step2, .{
        .start = wg_off,
        .end = wg_off + 1,
        .new_text = "16",
    });
    defer step3.deinit();
    try std.testing.expect(step3.reused);

    // 4. Inverse: flip workgroup_size back to `8`. Source returns to base.
    var step4 = try Incremental.reparse(gpa, &step3, .{
        .start = wg_off,
        .end = wg_off + 2,
        .new_text = "8",
    });
    defer step4.deinit();
    try std.testing.expect(step4.reused);
    try std.testing.expectEqualStrings(base_src, step4.source);

    // Final shape + per-symbol use_counts match a fresh parse of base.
    var oracle = try Incremental.parseFull(gpa, base_src);
    defer oracle.deinit();
    try expectShapesMatch(gpa, step4.module, oracle.module);
    try expectUseCountsMatch(step4.module, oracle.module);
}

// M8.b and M8.c used to assert the per-edit growth of
// `retained_arenas.items.len` under the old fresh-arena hot path:
// one entry appended per successful symbol-free reparse, reset on
// fallback. With the in-place hot path (`in_place_hot_path = true` in
// `src/Incremental.zig`) `retained_arenas` stays at 0 across any
// number of hot-path edits. Coverage of the underlying churn
// correctness is preserved by M8.d's inverse-round-trip assertion and
// the M9 family (see `tests/incremental_mutation_longtail_test.zig`
// after Step 2 of `docs/arena-transfer-zero-alloc-plan.md`).

test "M8.d: edit + inverse on multi-symbol expression preserves use_counts" {
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 =
        "fn f() -> i32 { let a = 1; let b = 2; let c = 3; return a + b * c; }";

    var step0 = try Incremental.parseFull(gpa, base_src);
    defer step0.deinit();

    const a_uc0 = useCountOf(step0.module, "a");
    const b_uc0 = useCountOf(step0.module, "b");
    const c_uc0 = useCountOf(step0.module, "c");

    // Replace the whole return value with a permuted form. Anchor:
    // binary_expr.
    const ret_off: u32 = at(base_src, "a + b * c");
    var step1 = try Incremental.reparse(gpa, &step0, .{
        .start = ret_off,
        .end = ret_off + @as(u32, @intCast("a + b * c".len)),
        .new_text = "c + b * a",
    });
    defer step1.deinit();
    try std.testing.expect(step1.reused);

    const ret_off2: u32 = at(step1.source, "c + b * a");
    var step2 = try Incremental.reparse(gpa, &step1, .{
        .start = ret_off2,
        .end = ret_off2 + @as(u32, @intCast("c + b * a".len)),
        .new_text = "a + b * c",
    });
    defer step2.deinit();
    try std.testing.expect(step2.reused);

    try std.testing.expectEqualStrings(base_src, step2.source);
    // Per-symbol use_counts match the pre-edit state exactly. A sub/add
    // inversion bug that swaps a's count with c's would slip past an
    // aggregate-only check but fail here.
    try std.testing.expectEqual(a_uc0, useCountOf(step2.module, "a"));
    try std.testing.expectEqual(b_uc0, useCountOf(step2.module, "b"));
    try std.testing.expectEqual(c_uc0, useCountOf(step2.module, "c"));
}

// =========================================================================
// M9 — In-place hot-path arena reuse: `retained_arenas` stays at 0
// across any length of symbol-free hot-path churn.
//
// Prior to `in_place_hot_path = true` in `src/Incremental.zig`, each
// successful hot-path reparse appended prev's arena to the new
// result's `retained_arenas`, growing the chain monotonically. The
// in-place path extends prev.arena in place instead, so the chain stays
// empty. M9 covers single-anchor bursts (a/d), anchor-kind alternation
// (b/c), and cross-function interleaving (e), each verified against a
// `parseFull` oracle on the final source.
// =========================================================================

test "M9.a: 30 literal churns keep retained_arenas at 0" {
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "fn f() -> i32 { return 1 + 2; }";

    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();
    try std.testing.expectEqual(@as(usize, 0), prev.retained_arenas.items.len);

    const lit_off: u32 = at(base_src, "1 + 2") + 4;
    var i: u32 = 0;
    while (i < 30) : (i += 1) {
        const ch: u8 = '0' + @as(u8, @intCast((i + 1) % 10));
        const new_text = [_]u8{ch};
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = lit_off,
            .end = lit_off + 1,
            .new_text = &new_text,
        });
        try std.testing.expect(next.reused);
        try std.testing.expectEqual(@as(usize, 0), next.retained_arenas.items.len);

        prev.deinit();
        prev = next;
    }

    var oracle = try Incremental.parseFull(gpa, prev.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, prev.module, oracle.module);
    try expectUseCountsMatch(prev.module, oracle.module);
}

test "M9.b: alternating ident_expr refs across two module-scope consts" {
    // Base module has `a` and `b` at module scope; the return value
    // alternates between `1 + a` and `1 + b`. Each edit's anchor is
    // ident_expr (the swapped operand). In-place path must preserve
    // per-symbol use_count exactly on each iteration.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 =
        "const a: i32 = 1; const b: i32 = 2; fn f() -> i32 { return 1 + a; }";

    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    var cur_name: []const u8 = "a";
    const ident_off_init: u32 = at(base_src, "1 + a") + 4;
    var ident_off = ident_off_init;

    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        const next_name: []const u8 = if (std.mem.eql(u8, cur_name, "a")) "b" else "a";
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = ident_off,
            .end = ident_off + 1,
            .new_text = next_name,
        });
        try std.testing.expect(next.reused);
        try std.testing.expectEqual(@as(usize, 0), next.retained_arenas.items.len);

        var oracle = try Incremental.parseFull(gpa, next.source);
        defer oracle.deinit();
        try expectUseCountsMatch(next.module, oracle.module);

        cur_name = next_name;
        prev.deinit();
        prev = next;
        ident_off = at(prev.source, if (std.mem.eql(u8, cur_name, "a")) "1 + a" else "1 + b") + 4;
    }
}

test "M9.c: 20 binary_expr operator flips keep retained_arenas at 0" {
    // Covers the binary_expr anchor variant of the in-place arena
    // invariant. Every edit stays on the same anchor kind (binary_expr)
    // and re-lowers the whole RHS so the add/sub walk exercises multi-
    // operand symbol resolution. Kind-flip scenarios (ident_expr ↔
    // binary_expr) legitimately fall back — S8 documents why — so they
    // are not part of the in-place-arena contract tested here.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 =
        "fn f() -> i32 { let a = 1; return a + 0; }";

    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    var use_plus: bool = true;
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        // Swap the operator inside `a + 0` ↔ `a - 0`. Anchor: binary_expr.
        const op_needle: []const u8 = if (use_plus) "a + 0" else "a - 0";
        const op_off: u32 = at(prev.source, op_needle) + 2;
        const new_op: []const u8 = if (use_plus) "-" else "+";

        const next = try Incremental.reparse(gpa, &prev, .{
            .start = op_off,
            .end = op_off + 1,
            .new_text = new_op,
        });
        try std.testing.expect(next.reused);
        try std.testing.expectEqual(@as(usize, 0), next.retained_arenas.items.len);

        var oracle = try Incremental.parseFull(gpa, next.source);
        defer oracle.deinit();
        try expectUseCountsMatch(next.module, oracle.module);

        use_plus = !use_plus;
        prev.deinit();
        prev = next;
    }
}

test "M9.d: 20 attribute-arg literal flips keep retained_arenas at 0" {
    // The attribute-arg path (`findSlotInAttribute`) is structurally
    // distinct from statement/expression slot lookup — M1 exercises
    // correctness; M9.d exercises arena bookkeeping on that code path.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 =
        "@compute @workgroup_size(8) fn main() {}";

    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    const lit_off: u32 = at(base_src, "@workgroup_size(") + @as(u32, @intCast("@workgroup_size(".len));
    var prev_len: u32 = 1;
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        // Cycle "8" → "16" → "32" → "64" → "128" → back to "8". Constant
        // length per group keeps lit_off stable; we just track the
        // current digit count.
        const digits: []const u8 = switch (i % 5) {
            0 => "16",
            1 => "32",
            2 => "64",
            3 => "128",
            4 => "8",
            else => unreachable,
        };
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = lit_off,
            .end = lit_off + prev_len,
            .new_text = digits,
        });
        try std.testing.expect(next.reused);
        try std.testing.expectEqual(@as(usize, 0), next.retained_arenas.items.len);
        prev_len = @intCast(digits.len);

        var oracle = try Incremental.parseFull(gpa, next.source);
        defer oracle.deinit();
        try expectUseCountsMatch(next.module, oracle.module);

        prev.deinit();
        prev = next;
    }
}

test "M9.e: interleaved edits across two functions keep the chain flat" {
    // Two fns, each with its own scope. Edits alternate between them
    // so the add-walk repeatedly positions `ctx.scope` at different
    // anchor scopes (via `scopeAtCstNode`). Arena invariant must hold
    // across scope switches.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 =
        "fn fa() -> i32 { return 1; } fn fb() -> i32 { return 2; }";

    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        const target: []const u8 = if (i % 2 == 0) "fn fa" else "fn fb";
        const fn_start: u32 = at(prev.source, target);
        const body_open: u32 = fn_start + @as(u32, @intCast(std.mem.indexOf(u8, prev.source[fn_start..], "return ").?)) + @as(u32, @intCast("return ".len));
        // The literal following `return ` is a single digit — flip it.
        const new_digit: u8 = '0' + @as(u8, @intCast((i + 1) % 10));
        const new_text = [_]u8{new_digit};
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = body_open,
            .end = body_open + 1,
            .new_text = &new_text,
        });
        try std.testing.expect(next.reused);
        try std.testing.expectEqual(@as(usize, 0), next.retained_arenas.items.len);

        prev.deinit();
        prev = next;
    }

    var oracle = try Incremental.parseFull(gpa, prev.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, prev.module, oracle.module);
    try expectUseCountsMatch(prev.module, oracle.module);
}

// =========================================================================
// M10 — Compaction watermark: the in-place hot path grows prev.arena
// forever, so the reparse driver trips a full-parse fallback once live
// arena capacity passes 8× source size (floor 16 KiB). M10 validates
// that (a) sustained churn eventually trips at least once, (b) a large
// insert trips quickly, and (c) the chain resets to a fresh arena on
// the trip.
// =========================================================================

test "M10.a: sustained literal churn trips the watermark at least once" {
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "fn f() -> i32 { return 1 + 2; }";
    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    const lit_off: u32 = at(base_src, "1 + 2") + 4;
    var trip_count: u32 = 0;
    var i: u32 = 0;
    // 500 iterations on a 31-byte base: threshold = max(256 KiB, 31*8)
    // = 256 KiB. Each hot-path edit adds a new source copy, re-lexed
    // token array, CST splice, and lowered AST subtree — enough to
    // trip at least once across 500 edits.
    while (i < 500) : (i += 1) {
        const ch: u8 = '0' + @as(u8, @intCast((i + 1) % 10));
        const new_text = [_]u8{ch};
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = lit_off,
            .end = lit_off + 1,
            .new_text = &new_text,
        });
        if (!next.reused) trip_count += 1;
        prev.deinit();
        prev = next;
    }
    try std.testing.expect(trip_count >= 1);

    var oracle = try Incremental.parseFull(gpa, prev.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, prev.module, oracle.module);
    try expectUseCountsMatch(prev.module, oracle.module);
}

test "M10.b: a large insert makes the next edit trip the watermark" {
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "fn f() -> i32 { return 1 + 2; }";
    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    // Craft a single hot-path edit whose prev-arena cost exceeds the
    // watermark on the *next* iteration. We insert a 200 KiB integer
    // literal so after one edit prev.arena's capacity is already past
    // the 256 KiB floor; the second edit immediately falls back.
    const padding_len: usize = 200 * 1024;
    const big_lit = try gpa.alloc(u8, padding_len);
    defer gpa.free(big_lit);
    @memset(big_lit, '1');

    const lit_off: u32 = at(base_src, "1 + 2") + 4;
    const first = try Incremental.reparse(gpa, &prev, .{
        .start = lit_off,
        .end = lit_off + 1,
        .new_text = big_lit,
    });
    prev.deinit();
    prev = first;
    try std.testing.expect(prev.reused);

    const next = try Incremental.reparse(gpa, &prev, .{
        .start = lit_off,
        .end = lit_off + @as(u32, @intCast(padding_len)),
        .new_text = "7",
    });
    try std.testing.expect(!next.reused);

    var oracle = try Incremental.parseFull(gpa, next.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, next.module, oracle.module);
    try expectUseCountsMatch(next.module, oracle.module);

    prev.deinit();
    prev = next;
}

test "M10.c: a watermark trip resets the arena and re-enables the hot path" {
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "fn f() -> i32 { return 1 + 2; }";
    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    const padding_len: usize = 200 * 1024;
    const big_lit = try gpa.alloc(u8, padding_len);
    defer gpa.free(big_lit);
    @memset(big_lit, '1');

    const lit_off: u32 = at(base_src, "1 + 2") + 4;
    const first = try Incremental.reparse(gpa, &prev, .{
        .start = lit_off,
        .end = lit_off + 1,
        .new_text = big_lit,
    });
    prev.deinit();
    prev = first;

    // Trip the watermark with a shrinking edit.
    const tripped = try Incremental.reparse(gpa, &prev, .{
        .start = lit_off,
        .end = lit_off + @as(u32, @intCast(padding_len)),
        .new_text = "7",
    });
    try std.testing.expect(!tripped.reused);
    // Full-parse fallback allocates a fresh arena and retains none.
    try std.testing.expectEqual(@as(usize, 0), tripped.retained_arenas.items.len);
    prev.deinit();
    prev = tripped;

    // Next hot-path edit should take the in-place path on the fresh
    // arena and keep retained_arenas at 0. Post-trip source is
    // `"fn f() -> i32 { return 1 + 7; }"` — flip the `7` to `9`.
    const post_lit_off: u32 = at(prev.source, "+ 7") + 2;
    const follow = try Incremental.reparse(gpa, &prev, .{
        .start = post_lit_off,
        .end = post_lit_off + 1,
        .new_text = "9",
    });
    try std.testing.expect(follow.reused);
    try std.testing.expectEqual(@as(usize, 0), follow.retained_arenas.items.len);

    prev.deinit();
    prev = follow;
}

// =========================================================================
// M11 — Fallback robustness: each known hot-path failure mode must
// leave the resulting state walkable and must NOT poison the next
// reparse. The in-place hot path may write garbage bytes into
// prev.arena before a late validation gate fails; this family chains a
// failure-triggering edit with a clean hot edit and asserts the clean
// edit still hot-paths and produces an oracle-matching module.
// =========================================================================

test "M11.a: AnchorKindMismatch fallback allows a follow-up hot edit" {
    // Triggering edit: S8-shape `1` → `1 * 3` inside `return 1 + 2;`
    // produces a binary_expr where the anchor was literal_expr. Hot
    // path bails; parseFull returns a clean result.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "fn f() -> i32 { return 1 + 2; }";
    var base = try Incremental.parseFull(gpa, base_src);
    defer base.deinit();

    const lit_off: u32 = at(base_src, "return 1") + @as(u32, @intCast("return ".len));
    var fallback = try Incremental.reparse(gpa, &base, .{
        .start = lit_off,
        .end = lit_off + 1,
        .new_text = "1 * 3",
    });
    defer fallback.deinit();
    try std.testing.expect(!fallback.reused);

    // Post-fallback source: `"fn f() -> i32 { return 1 * 3 + 2; }"`.
    // Flip the trailing `2` via a literal-swap edit — classic
    // symbol-free hot-path shape.
    const tail_lit: u32 = at(fallback.source, "3 + 2") + 4;
    var hot = try Incremental.reparse(gpa, &fallback, .{
        .start = tail_lit,
        .end = tail_lit + 1,
        .new_text = "9",
    });
    defer hot.deinit();
    try std.testing.expect(hot.reused);

    var oracle = try Incremental.parseFull(gpa, hot.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, hot.module, oracle.module);
    try expectUseCountsMatch(hot.module, oracle.module);
}

test "M11.b: AnchorParseError fallback allows a follow-up hot edit" {
    // S16-shape: `return 2;` → `return +;` produces a literal_expr
    // anchor that reparses into an error subtree — sub_parser.errors
    // populated → fallback.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "fn f() -> i32 { return 2; }";
    var base = try Incremental.parseFull(gpa, base_src);
    defer base.deinit();

    const lit_off: u32 = at(base_src, "return ") + @as(u32, @intCast("return ".len));
    var fallback = try Incremental.reparse(gpa, &base, .{
        .start = lit_off,
        .end = lit_off + 1,
        .new_text = "+",
    });
    defer fallback.deinit();
    try std.testing.expect(!fallback.reused);
    // Full-parse fallback gives the error-recovered module; fix the
    // parse error with a second edit and confirm the hot path fires.
    const bad_off: u32 = at(fallback.source, "return +") + @as(u32, @intCast("return ".len));
    var fix = try Incremental.reparse(gpa, &fallback, .{
        .start = bad_off,
        .end = bad_off + 1,
        .new_text = "9",
    });
    defer fix.deinit();
    // Fixing the parse error is also a fallback (prev had errors, so
    // the reparse oracle must run). What we care about is the result
    // is byte-clean and a *subsequent* literal flip takes the hot
    // path.
    const lit2: u32 = at(fix.source, "return 9") + @as(u32, @intCast("return ".len));
    var hot = try Incremental.reparse(gpa, &fix, .{
        .start = lit2,
        .end = lit2 + 1,
        .new_text = "7",
    });
    defer hot.deinit();
    try std.testing.expect(hot.reused);

    var oracle = try Incremental.parseFull(gpa, hot.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, hot.module, oracle.module);
    try expectUseCountsMatch(hot.module, oracle.module);
}

test "M11.c: kind-mismatch fallback allows a follow-up hot edit" {
    // Replacing `false` with `x < 1` flips the anchor kind from
    // literal_expr to binary_expr — a kind mismatch, distinct from any
    // add-walk concern, so the hot path bails to a full re-parse.
    // Verifies that a subsequent clean edit still hot-paths cleanly.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 =
        "fn f() -> i32 { if (false) { return 1; } let x = 7; return x; }";
    var base = try Incremental.parseFull(gpa, base_src);
    defer base.deinit();

    const cond_off: u32 = at(base_src, "(false)") + 1;
    var fallback = try Incremental.reparse(gpa, &base, .{
        .start = cond_off,
        .end = cond_off + @as(u32, @intCast("false".len)),
        .new_text = "x < 1",
    });
    defer fallback.deinit();
    try std.testing.expect(!fallback.reused);

    // Post-fallback source references `x` in the condition. A
    // subsequent literal flip on the `1` inside `(x < 1)` is a
    // clean literal_expr hot edit.
    const tail_lit: u32 = at(fallback.source, "x < 1") + 4;
    var hot = try Incremental.reparse(gpa, &fallback, .{
        .start = tail_lit,
        .end = tail_lit + 1,
        .new_text = "2",
    });
    defer hot.deinit();
    try std.testing.expect(hot.reused);

    var oracle = try Incremental.parseFull(gpa, hot.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, hot.module, oracle.module);
    try expectUseCountsMatch(hot.module, oracle.module);
}

// =========================================================================
// M12 — Trivia-only shortcut: zero-delta edits that leave every
// non-trivia token tag/length/text unchanged must bypass the hot
// path entirely and reuse prev.module + prev.cst byte-for-byte. The
// distinguishing observable is pointer-equality on module and on the
// underlying CST node store. Edits that fail the zero-delta-trivia
// precondition fall through to the regular path without firing.
// =========================================================================

test "M12.a: zero-delta line-comment body swap reuses module + CST" {
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "// abc\nfn f() {}";
    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    const prev_module_ptr = prev.module;
    const prev_cst_nodes_bytes = prev.cst.nodes.bytes;

    // Replace `abc` with `xyz` — same length, inside a line comment.
    const body_off: u32 = at(base_src, "abc");
    var updated = try Incremental.reparse(gpa, &prev, .{
        .start = body_off,
        .end = body_off + 3,
        .new_text = "xyz",
    });
    defer updated.deinit();

    try std.testing.expect(updated.reused);
    try std.testing.expectEqualStrings("// xyz\nfn f() {}", updated.source);

    // Shortcut fingerprint: the Module pointer is byte-identical and
    // the CST's node-store backing pointer is unchanged.
    try std.testing.expectEqual(prev_module_ptr, updated.module);
    try std.testing.expectEqual(prev_cst_nodes_bytes, updated.cst.nodes.bytes);
}

test "M12.b: zero-delta whitespace swap reuses module + CST" {
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "fn f() {   return 0; }";
    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    const prev_module_ptr = prev.module;
    const prev_cst_nodes_bytes = prev.cst.nodes.bytes;

    // Replace three spaces with tab+space+space (same length, all trivia).
    const ws_off: u32 = at(base_src, "{   ") + 1;
    var updated = try Incremental.reparse(gpa, &prev, .{
        .start = ws_off,
        .end = ws_off + 3,
        .new_text = "\t  ",
    });
    defer updated.deinit();

    try std.testing.expect(updated.reused);
    try std.testing.expectEqual(prev_module_ptr, updated.module);
    try std.testing.expectEqual(prev_cst_nodes_bytes, updated.cst.nodes.bytes);
}

test "M12.c: zero-delta block-comment body swap reuses module + CST" {
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "/* old */ fn f() {}";
    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    const prev_module_ptr = prev.module;
    const prev_cst_nodes_bytes = prev.cst.nodes.bytes;

    const body_off: u32 = at(base_src, "old");
    var updated = try Incremental.reparse(gpa, &prev, .{
        .start = body_off,
        .end = body_off + 3,
        .new_text = "new",
    });
    defer updated.deinit();

    try std.testing.expect(updated.reused);
    try std.testing.expectEqual(prev_module_ptr, updated.module);
    try std.testing.expectEqual(prev_cst_nodes_bytes, updated.cst.nodes.bytes);
}

test "M12.d: non-zero-delta trivia insert falls through to regular path" {
    // A comment insertion is trivia-only but has non-zero delta; the
    // shortcut must NOT fire, and the regular reparse must still
    // produce the correctly-spliced source.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "fn f() -> i32 { return 1; }";
    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    // Replace `return` with `return /* x */`. Non-zero-delta trivia
    // insertion — shortcut condition fails on the delta check.
    const ret_off: u32 = at(base_src, "return");
    var updated = try Incremental.reparse(gpa, &prev, .{
        .start = ret_off,
        .end = ret_off + @as(u32, @intCast("return".len)),
        .new_text = "return /* x */",
    });
    defer updated.deinit();

    try std.testing.expectEqualStrings("fn f() -> i32 { return /* x */ 1; }", updated.source);
}

test "M12.e: zero-delta trivia swap across several tokens reuses module" {
    // Replace a span inside a comment that sits between two real
    // decls. Still zero-delta, still trivia-only, still
    // shortcut-eligible.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "const x = 1; // abc def\nconst y = 2;";
    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    const prev_module_ptr = prev.module;
    const prev_cst_nodes_bytes = prev.cst.nodes.bytes;

    const body_off: u32 = at(base_src, "abc");
    var updated = try Incremental.reparse(gpa, &prev, .{
        .start = body_off,
        .end = body_off + 7,
        .new_text = "zzz qqq",
    });
    defer updated.deinit();

    try std.testing.expect(updated.reused);
    try std.testing.expectEqual(prev_module_ptr, updated.module);
    try std.testing.expectEqual(prev_cst_nodes_bytes, updated.cst.nodes.bytes);
}

// =========================================================================
// M13 — Arena envelope smoke test: a 100-edit churn on a real
// compute.toys shader keeps arena capacity bounded by the
// compaction watermark on every iteration.
//
// queryCapacity() sums used + free pages in the ArenaAllocator's
// internal free-list, so this tracks live + cache-retained bytes.
// The assertion uses 16× source size as the envelope — the watermark
// trips at 8× source size (floor 256 KiB); a 16× ceiling leaves
// headroom for the single edit between checks that allocated into
// prev.arena before the next watermark check.
// =========================================================================

test "M13: 100-edit literal churn on circle_sample keeps arena bounded" {
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = @embedFile("testdata/compute.toys/circle_sample.wgsl");

    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    const lit_off: u32 = at(base_src, "let s = 1.0;") + @as(u32, @intCast("let s = ".len));
    const floor: usize = 256 * 1024;
    const envelope: usize = @max(floor, base_src.len) * @as(usize, 16);

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const ch: u8 = '0' + @as(u8, @intCast((i + 1) % 10));
        const new_text = [_]u8{ch};
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = lit_off,
            .end = lit_off + 1,
            .new_text = &new_text,
        });

        const bytes = next.arenaBytes();
        if (bytes >= envelope) {
            std.debug.print("M13: arena capacity {d} exceeded envelope {d} at iter {d}\n", .{ bytes, envelope, i });
            return error.ArenaEnvelopeExceeded;
        }

        prev.deinit();
        prev = next;
    }

    var oracle = try Incremental.parseFull(gpa, prev.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, prev.module, oracle.module);
    try expectUseCountsMatch(prev.module, oracle.module);
}

// =========================================================================
// M14 — Chained-reparse invariants across mutation sections.
//
// The edit-count bound (HOT_EDIT_COALESCE_MAX = 256) is a defense-in-
// depth backstop. The byte-watermark (M10) typically trips first on
// realistic shaders because per-edit arena cost (~KB/edit for tokens +
// CST splice + lowered subtree) reaches the 256 KiB floor well before
// 256 edits. M14 covers one chained test per mutation section (M1, M3,
// M4, M5, M6, M7) exercising two invariants that MUST hold regardless
// of which watermark fires:
//   (a) `retained_arenas.items.len == 0` on every result (commit-3
//       invariant, locks the always-empty guarantee),
//   (b) `hot_edits_since_full <= HOT_EDIT_COALESCE_MAX` when
//       `reused == true`; equals 0 when `reused == false` (coalesce
//       reset).
// Long bursts also assert at least one coalesce fires, which proves
// the reclamation path activates and correctly returns control to
// `parseFull`.
// =========================================================================

const HOT_MAX = Incremental.HOT_EDIT_COALESCE_MAX;

/// Shared per-iteration assertions for every M14 chain.
fn expectChainInvariants(r: *const Incremental.ReparseResult) !void {
    try std.testing.expectEqual(@as(usize, 0), r.retained_arenas.items.len);
    if (r.reused) {
        try std.testing.expect(r.hot_edits_since_full >= 1);
        try std.testing.expect(r.hot_edits_since_full <= HOT_MAX);
    } else {
        try std.testing.expectEqual(@as(u16, 0), r.hot_edits_since_full);
    }
}

test "M14.a: M1 attr-arg 300-edit chain holds invariants and coalesces" {
    // `@binding(0)` literal flips `0`↔`1` 300×. Anchor: literal_expr
    // inside attribute args (M1 path).
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "@group(0) @binding(0) var<uniform> u: f32;";

    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    const first_paren = at(base_src, "(0)");
    const second_paren = at(base_src[first_paren + 1 ..], "(0)") + first_paren + 1;
    const lit_off: u32 = second_paren + 1;

    var coalesce_count: u32 = 0;
    var i: u32 = 0;
    while (i < 300) : (i += 1) {
        const ch: u8 = if (i % 2 == 0) '1' else '0';
        const new_text = [_]u8{ch};
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = lit_off,
            .end = lit_off + 1,
            .new_text = &new_text,
        });
        try expectChainInvariants(&next);
        if (!next.reused) coalesce_count += 1;

        prev.deinit();
        prev = next;
    }
    try std.testing.expect(coalesce_count >= 1);

    var oracle = try Incremental.parseFull(gpa, prev.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, prev.module, oracle.module);
    try expectUseCountsMatch(prev.module, oracle.module);
}

test "M14.b: M3 for-loop cond 300-edit chain holds invariants and coalesces" {
    // For-loop condition RHS `<10`↔`<11`. M3 path.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "fn f() { for (var i=0; i<10; i=i+1) {} }";

    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    var cur_ten: bool = true;
    var coalesce_count: u32 = 0;
    var i: u32 = 0;
    while (i < 300) : (i += 1) {
        const needle: []const u8 = if (cur_ten) "i<10" else "i<11";
        const off: u32 = at(prev.source, needle) + 2;
        const new_text: []const u8 = if (cur_ten) "11" else "10";
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = off,
            .end = off + 2,
            .new_text = new_text,
        });
        try expectChainInvariants(&next);
        if (!next.reused) coalesce_count += 1;

        cur_ten = !cur_ten;
        prev.deinit();
        prev = next;
    }
    try std.testing.expect(coalesce_count >= 1);
}

test "M14.c: M4 switch case-selector 300-edit chain holds invariants" {
    // Case selector `0`↔`2`.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 =
        "fn f(x:i32) { switch(x) { case 0: {} case 1: {} default: {} } }";

    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    var cur_zero: bool = true;
    var coalesce_count: u32 = 0;
    var i: u32 = 0;
    while (i < 300) : (i += 1) {
        const needle: []const u8 = if (cur_zero) "case 0:" else "case 2:";
        const off: u32 = at(prev.source, needle) + 5;
        const new_text: []const u8 = if (cur_zero) "2" else "0";
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = off,
            .end = off + 1,
            .new_text = new_text,
        });
        try expectChainInvariants(&next);
        if (!next.reused) coalesce_count += 1;

        cur_zero = !cur_zero;
        prev.deinit();
        prev = next;
    }
    try std.testing.expect(coalesce_count >= 1);
}

test "M14.d: M5 if/else 600-edit chain holds invariants with multiple coalesces" {
    // return literal `1`↔`3`.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 =
        "fn f(x:i32)->i32 { if (x>0) { return 1; } else { return 2; } }";

    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    var cur_one: bool = true;
    var coalesce_count: u32 = 0;
    var i: u32 = 0;
    while (i < 600) : (i += 1) {
        const needle: []const u8 = if (cur_one) "return 1" else "return 3";
        const off: u32 = at(prev.source, needle) + @as(u32, @intCast("return ".len));
        const new_text: []const u8 = if (cur_one) "3" else "1";
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = off,
            .end = off + 1,
            .new_text = new_text,
        });
        try expectChainInvariants(&next);
        if (!next.reused) coalesce_count += 1;

        cur_one = !cur_one;
        prev.deinit();
        prev = next;
    }
    // Long burst fires at least 2 coalesces (one per arena refill cycle).
    try std.testing.expect(coalesce_count >= 2);
}

test "M14.e: hot_edits_since_full is monotonic within an in-place run" {
    // Directly observe the counter: every successful in-place edit
    // increments it by 1; a coalesce resets it to 0. Sub-HOT_MAX bursts
    // may still coalesce via the byte-watermark; when they do, counter
    // resets and starts climbing again.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "fn f() { var i=0; loop { if (i>5) { break; } i=i+1; } }";

    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();
    try std.testing.expectEqual(@as(u16, 0), prev.hot_edits_since_full);

    var cur_five: bool = true;
    var last_counter: u16 = 0;
    var observed_increment: bool = false;
    var observed_reset: bool = false;
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        const needle: []const u8 = if (cur_five) "i>5" else "i>6";
        const off: u32 = at(prev.source, needle) + 2;
        const new_text: []const u8 = if (cur_five) "6" else "5";
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = off,
            .end = off + 1,
            .new_text = new_text,
        });
        try expectChainInvariants(&next);
        if (next.reused) {
            if (next.hot_edits_since_full == last_counter + 1) observed_increment = true;
            last_counter = next.hot_edits_since_full;
        } else {
            try std.testing.expectEqual(@as(u16, 0), next.hot_edits_since_full);
            observed_reset = true;
            last_counter = 0;
        }
        cur_five = !cur_five;
        prev.deinit();
        prev = next;
    }
    try std.testing.expect(observed_increment);
    // Reset may or may not fire in 200 edits depending on per-edit cost;
    // `observed_reset` is informational, not a gate. The counter-never-
    // exceeding-HOT_MAX invariant is enforced inside `expectChainInvariants`
    // on every iteration above.
    if (observed_reset) {
        try std.testing.expect(prev.hot_edits_since_full < HOT_MAX);
    }
}

test "M14.f: M7 member-access 300-edit chain holds invariants" {
    // Toggle `s.a`↔`s.a*1.0`. Anchor: member_expr.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "struct S { a: f32 } fn f(s: S) -> f32 { return s.a; }";

    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    var plain: bool = true;
    var coalesce_count: u32 = 0;
    var last_was_coalesce: bool = false;
    var post_coalesce_reused: bool = false;
    var i: u32 = 0;
    while (i < 300) : (i += 1) {
        const old_needle: []const u8 = if (plain) "return s.a;" else "return s.a*1.0;";
        const new_text: []const u8 = if (plain) "return s.a*1.0;" else "return s.a;";
        const off: u32 = at(prev.source, old_needle);
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = off,
            .end = off + @as(u32, @intCast(old_needle.len)),
            .new_text = new_text,
        });
        try expectChainInvariants(&next);
        if (!next.reused) {
            coalesce_count += 1;
            last_was_coalesce = true;
        } else if (last_was_coalesce) {
            post_coalesce_reused = true;
            last_was_coalesce = false;
        }
        plain = !plain;
        prev.deinit();
        prev = next;
    }
    try std.testing.expect(coalesce_count >= 1);
    try std.testing.expect(post_coalesce_reused);
}

test "M14.g: M9 extended — 512-edit literal churn holds invariants" {
    // Extends M9.a's 30-edit scope; final oracle match proves chained
    // reparses across multiple coalesce cycles converge on the ground
    // truth a fresh parseFull would produce.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "fn f() -> i32 { return 1 + 2; }";

    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    const lit_off: u32 = at(base_src, "1 + 2") + 4;
    var coalesce_count: u32 = 0;
    var i: u32 = 0;
    while (i < 512) : (i += 1) {
        const ch: u8 = '0' + @as(u8, @intCast((i + 1) % 10));
        const new_text = [_]u8{ch};
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = lit_off,
            .end = lit_off + 1,
            .new_text = &new_text,
        });
        try expectChainInvariants(&next);
        if (!next.reused) coalesce_count += 1;
        prev.deinit();
        prev = next;
    }
    try std.testing.expect(coalesce_count >= 2);

    var oracle = try Incremental.parseFull(gpa, prev.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, prev.module, oracle.module);
    try expectUseCountsMatch(prev.module, oracle.module);
}

// =========================================================================
// M15 — Cross-section retained_arenas sentinel.
//
// Runs every M14 fixture through a short burst (well below HOT_MAX)
// and asserts `retained_arenas.items.len == 0` on every result. Catches
// any future commit that introduces a new growth site on any mutation
// section without going through the edit-count coalesce path.
// =========================================================================

const M15Fixture = struct {
    base_src: [:0]const u8,
    needle: []const u8,
    old_byte: []const u8,
    new_byte: []const u8,
    needle_offset: u32,
};

test "M15: retained_arenas stays empty across every mutation fixture" {
    const gpa = std.testing.allocator;
    const fixtures = [_]M15Fixture{
        // M1 attr arg
        .{
            .base_src = "@group(0) @binding(0) var<uniform> u: f32;",
            .needle = "@binding(",
            .old_byte = "0",
            .new_byte = "1",
            .needle_offset = @intCast("@binding(".len),
        },
        // M3 for-loop cond
        .{
            .base_src = "fn f() { for (var i=0; i<9; i=i+1) {} }",
            .needle = "i<",
            .old_byte = "9",
            .new_byte = "8",
            .needle_offset = @intCast("i<".len),
        },
        // M4 switch case
        .{
            .base_src = "fn f(x:i32) { switch(x) { case 0: {} default: {} } }",
            .needle = "case ",
            .old_byte = "0",
            .new_byte = "1",
            .needle_offset = @intCast("case ".len),
        },
        // M5 if-body return
        .{
            .base_src = "fn f(x:i32)->i32 { if (x>0) { return 1; } else { return 2; } }",
            .needle = "return ",
            .old_byte = "1",
            .new_byte = "3",
            .needle_offset = @intCast("return ".len),
        },
        // M6 loop cond
        .{
            .base_src = "fn f() { var i=0; loop { if (i>5) { break; } i=i+1; } }",
            .needle = "i>",
            .old_byte = "5",
            .new_byte = "6",
            .needle_offset = @intCast("i>".len),
        },
        // M9 literal flip
        .{
            .base_src = "fn f() -> i32 { return 1 + 2; }",
            .needle = "+ ",
            .old_byte = "2",
            .new_byte = "3",
            .needle_offset = @intCast("+ ".len),
        },
    };

    for (fixtures) |fx| {
        var prev = try Incremental.parseFull(gpa, fx.base_src);
        defer prev.deinit();
        try std.testing.expectEqual(@as(usize, 0), prev.retained_arenas.items.len);

        var cur_old: bool = true;
        var i: u32 = 0;
        while (i < 60) : (i += 1) {
            const needle_start: u32 = at(prev.source, fx.needle) + fx.needle_offset;
            const ch_old = if (cur_old) fx.old_byte else fx.new_byte;
            const ch_new = if (cur_old) fx.new_byte else fx.old_byte;
            // Sanity: the byte at needle_start must be ch_old[0] before the edit.
            try std.testing.expectEqual(ch_old[0], prev.source[needle_start]);

            const next = try Incremental.reparse(gpa, &prev, .{
                .start = needle_start,
                .end = needle_start + 1,
                .new_text = ch_new,
            });
            try std.testing.expectEqual(@as(usize, 0), next.retained_arenas.items.len);
            cur_old = !cur_old;
            prev.deinit();
            prev = next;
        }
    }
}

