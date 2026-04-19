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
