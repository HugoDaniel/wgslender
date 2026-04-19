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

test "M5.e: condition references local declared later → AddWalkRaisedErrors fallback" {
    const src: [:0]const u8 =
        "fn f(x: i32) -> i32 { if x > 0 { return 1; } let y = 2; return y; }";
    const new_src: []const u8 =
        "fn f(x: i32) -> i32 { if x > 0 || y < 0 { return 1; } let y = 2; return y; }";
    // Replace the binary subtree `x > 0` with `x > 0 || y < 0`.
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
        false,
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

