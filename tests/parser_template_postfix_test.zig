//! Parser-level coverage for postfix expressions inside `array<T, ...>`
//! template arguments.
//!
//! Until recently the template-arg subparser dropped `.member` / `[idx]`
//! / `(args)` suffixes — `parseTemplatePrimaryExprInner` returned
//! immediately and the unary chain never reached a postfix loop. These
//! tests assert the AST shape produced by `Incremental.parseFull` on
//! representative inputs so the regression cannot recur silently.

const std = @import("std");
const wgslender = @import("wgslender");

const Ast = wgslender.Ast;
const Incremental = wgslender.Incremental;

fn findVarType(module: *const Ast.Module, name: []const u8) ?Ast.Type {
    for (module.declarations.items) |d| {
        if (d != .@"var") continue;
        const sym_idx = d.@"var".name;
        if (sym_idx == .none) continue;
        const sym = module.symbols.items[@intFromEnum(sym_idx)];
        if (!std.mem.eql(u8, sym.original_name, name)) continue;
        return d.@"var".typ;
    }
    return null;
}

fn arraySize(typ: Ast.Type) ?Ast.Expr {
    return switch (typ) {
        .array => |a| a.size,
        else => null,
    };
}

fn arrayElem(typ: Ast.Type) ?Ast.Type {
    return switch (typ) {
        .array => |a| a.elem_type,
        else => null,
    };
}

fn expectIdent(expr: Ast.Expr, name: []const u8) !void {
    try std.testing.expect(expr == .ident);
    try std.testing.expectEqualStrings(name, expr.ident.name);
}

fn expectLiteralInt(expr: Ast.Expr, text: []const u8) !void {
    try std.testing.expect(expr == .literal);
    try std.testing.expectEqualStrings(text, expr.literal.value);
}

test "parser/template-postfix: array<f32, P.x> — member size" {
    const src =
        \\struct Pair { x: u32, y: u32 }
        \\const P = Pair(4u, 0u);
        \\@group(0) @binding(0) var<uniform> u: array<f32, P.x>;
    ;
    var r = try Incremental.parseFull(std.testing.allocator, src);
    defer r.deinit();

    const typ = findVarType(r.module, "u") orelse return error.TestExpectedVar;
    const size = arraySize(typ) orelse return error.TestExpectedSize;
    try std.testing.expect(size == .member);
    try std.testing.expectEqualStrings("x", size.member.member_name);
    try expectIdent(size.member.base, "P");
}

test "parser/template-postfix: array<f32, arr[0]> — index size" {
    const src =
        \\const arr = array<u32, 4>(1u, 2u, 3u, 4u);
        \\@group(0) @binding(0) var<uniform> u: array<f32, arr[0]>;
    ;
    var r = try Incremental.parseFull(std.testing.allocator, src);
    defer r.deinit();

    const typ = findVarType(r.module, "u") orelse return error.TestExpectedVar;
    const size = arraySize(typ) orelse return error.TestExpectedSize;
    try std.testing.expect(size == .index);
    try expectIdent(size.index.base, "arr");
    try expectLiteralInt(size.index.idx, "0");
}

test "parser/template-postfix: array<f32, P.x + 1> — binary around member" {
    const src =
        \\struct Pair { x: u32, y: u32 }
        \\const P = Pair(4u, 0u);
        \\@group(0) @binding(0) var<uniform> u: array<f32, P.x + 1>;
    ;
    var r = try Incremental.parseFull(std.testing.allocator, src);
    defer r.deinit();

    const typ = findVarType(r.module, "u") orelse return error.TestExpectedVar;
    const size = arraySize(typ) orelse return error.TestExpectedSize;
    try std.testing.expect(size == .binary);
    try std.testing.expectEqual(Ast.BinaryOp.add, size.binary.op);
    try std.testing.expect(size.binary.left == .member);
    try std.testing.expectEqualStrings("x", size.binary.left.member.member_name);
    try expectIdent(size.binary.left.member.base, "P");
    try expectLiteralInt(size.binary.right, "1");
}

test "parser/template-postfix: array<vec3<f32>, lim.size> — nested template + member size" {
    const src =
        \\struct Lim { size: u32 }
        \\const lim = Lim(8u);
        \\@group(0) @binding(0) var<uniform> u: array<vec3<f32>, lim.size>;
    ;
    var r = try Incremental.parseFull(std.testing.allocator, src);
    defer r.deinit();

    const typ = findVarType(r.module, "u") orelse return error.TestExpectedVar;
    const elem = arrayElem(typ) orelse return error.TestExpectedElem;
    try std.testing.expect(elem == .vec);
    try std.testing.expectEqual(@as(u8, 3), elem.vec.size);

    const size = arraySize(typ) orelse return error.TestExpectedSize;
    try std.testing.expect(size == .member);
    try std.testing.expectEqualStrings("size", size.member.member_name);
    try expectIdent(size.member.base, "lim");
}

test "parser/template-postfix: array<f32, foo(0)> — call size" {
    const src =
        \\fn foo(n: u32) -> u32 { return n + 1u; }
        \\@group(0) @binding(0) var<uniform> u: array<f32, foo(0)>;
    ;
    var r = try Incremental.parseFull(std.testing.allocator, src);
    defer r.deinit();

    const typ = findVarType(r.module, "u") orelse return error.TestExpectedVar;
    const size = arraySize(typ) orelse return error.TestExpectedSize;
    try std.testing.expect(size == .call);
    const call = size.call;
    try std.testing.expect(call.func != null);
    try expectIdent(call.func.?, "foo");
    try std.testing.expectEqual(@as(usize, 1), call.args.items.len);
    try expectLiteralInt(call.args.items[0], "0");
}

test "parser/template-postfix: array<f32, P.x[0].y> — chained postfix" {
    // Synthetic shape — wgsl semantics aside, the parser must produce
    // member(index(member(P,x), 0), y).
    const src =
        \\struct Inner { y: u32 }
        \\struct Outer { x: array<Inner, 4> }
        \\const P = Outer(array<Inner, 4>(Inner(0u), Inner(0u), Inner(0u), Inner(0u)));
        \\@group(0) @binding(0) var<uniform> u: array<f32, P.x[0].y>;
    ;
    var r = try Incremental.parseFull(std.testing.allocator, src);
    defer r.deinit();

    const typ = findVarType(r.module, "u") orelse return error.TestExpectedVar;
    const size = arraySize(typ) orelse return error.TestExpectedSize;

    // Outermost: .member ".y"
    try std.testing.expect(size == .member);
    try std.testing.expectEqualStrings("y", size.member.member_name);

    // Next: [0]
    const idx_expr = size.member.base;
    try std.testing.expect(idx_expr == .index);
    try expectLiteralInt(idx_expr.index.idx, "0");

    // Innermost: .member ".x" on P
    const inner_member = idx_expr.index.base;
    try std.testing.expect(inner_member == .member);
    try std.testing.expectEqualStrings("x", inner_member.member.member_name);
    try expectIdent(inner_member.member.base, "P");
}

test "parser/template-postfix: vec2<P.x> errors but does not panic" {
    // vec template arg is a *type*, not an expression. Member access here
    // is not legal — the parser should report a diagnostic without
    // crashing, and the change to the template-arg-expression path must
    // not have widened the type-arg path.
    const src =
        \\struct Pair { x: u32, y: u32 }
        \\const P = Pair(4u, 0u);
        \\@group(0) @binding(0) var<uniform> u: vec2<P.x>;
    ;
    var r = try Incremental.parseFull(std.testing.allocator, src);
    defer r.deinit();

    try std.testing.expect(r.errors.len > 0);
}

test "parser/template-postfix: array<f32, P.> reports useful diagnostic" {
    // Trailing dot with no member name — the helper's existing
    // `addError("expected member name")` should fire and parsing should
    // recover without panic.
    const src =
        \\struct Pair { x: u32, y: u32 }
        \\const P = Pair(4u, 0u);
        \\@group(0) @binding(0) var<uniform> u: array<f32, P.>;
    ;
    var r = try Incremental.parseFull(std.testing.allocator, src);
    defer r.deinit();

    try std.testing.expect(r.errors.len > 0);
    var saw_member_msg = false;
    for (r.errors) |e| {
        if (std.mem.indexOf(u8, e.message, "member") != null) {
            saw_member_msg = true;
            break;
        }
    }
    try std.testing.expect(saw_member_msg);
}

test "parser/template-postfix: minify round-trip preserves array<f32, P.x>" {
    const src: [:0]const u8 =
        \\struct Pair { x: u32, y: u32 }
        \\const P = Pair(4u, 0u);
        \\@group(0) @binding(0) var<uniform> u: array<f32, P.x>;
        \\@compute @workgroup_size(1) fn main() { let _t = u[0]; }
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try wgslender.minifyWithOptions(arena.allocator(), src, .{
        .minify_whitespace = true,
        .minify_identifiers = false,
        .tree_shaking = false,
    });
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);

    // Re-parse the minified output and verify the type still has a
    // member-expression as the array size.
    const minified_owned = try arena.allocator().dupeZ(u8, result.code);
    var r = try Incremental.parseFull(std.testing.allocator, minified_owned);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.errors.len);

    const typ = findVarType(r.module, "u") orelse return error.TestExpectedVar;
    const size = arraySize(typ) orelse return error.TestExpectedSize;
    try std.testing.expect(size == .member);
    try std.testing.expectEqualStrings("x", size.member.member_name);
}
