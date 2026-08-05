const std = @import("std");
const Handler = @import("Handler");

fn setup(source: [:0]const u8) !struct { handler: *Handler } {
    const handler = try std.testing.allocator.create(Handler);
    handler.* = Handler.init(std.testing.allocator);
    try handler.openDocument("test://file.wgsl", source, 1);
    return .{ .handler = handler };
}

fn teardown(ctx: anytype) void {
    ctx.handler.deinit();
    std.testing.allocator.destroy(ctx.handler);
}

fn hasItem(items: []const Handler.CompletionItem, label: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.label, label)) return true;
    }
    return false;
}

test "completion: general includes keywords" {
    const source: [:0]const u8 = "fn f() { }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Position in empty function body (after space)
    const items = try ctx.handler.computeCompletion("test://file.wgsl", .{ .line = 0, .character = 9 });
    defer std.testing.allocator.free(items);
    try std.testing.expect(hasItem(items, "return"));
    try std.testing.expect(hasItem(items, "let"));
    try std.testing.expect(hasItem(items, "var"));
    try std.testing.expect(hasItem(items, "if"));
}

test "completion: general includes builtins" {
    const source: [:0]const u8 = "fn f() { }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const items = try ctx.handler.computeCompletion("test://file.wgsl", .{ .line = 0, .character = 9 });
    defer std.testing.allocator.free(items);
    try std.testing.expect(hasItem(items, "sin"));
    try std.testing.expect(hasItem(items, "cos"));
    try std.testing.expect(hasItem(items, "dot"));
}

test "completion: general includes type names" {
    const source: [:0]const u8 = "fn f() { }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const items = try ctx.handler.computeCompletion("test://file.wgsl", .{ .line = 0, .character = 9 });
    defer std.testing.allocator.free(items);
    try std.testing.expect(hasItem(items, "f32"));
    try std.testing.expect(hasItem(items, "vec3"));
    try std.testing.expect(hasItem(items, "mat4x4"));
}

test "completion: general includes module symbols" {
    const source: [:0]const u8 = "const MY_CONST: f32 = 1.0; fn f() { }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const items = try ctx.handler.computeCompletion("test://file.wgsl", .{ .line = 0, .character = 36 });
    defer std.testing.allocator.free(items);
    try std.testing.expect(hasItem(items, "MY_CONST"));
}

test "completion: after @ lists attributes" {
    const source: [:0]const u8 = "@";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Position right after '@'
    const items = try ctx.handler.computeCompletion("test://file.wgsl", .{ .line = 0, .character = 1 });
    defer std.testing.allocator.free(items);
    try std.testing.expect(hasItem(items, "vertex"));
    try std.testing.expect(hasItem(items, "fragment"));
    try std.testing.expect(hasItem(items, "compute"));
    try std.testing.expect(hasItem(items, "group"));
    try std.testing.expect(hasItem(items, "binding"));
    try std.testing.expect(hasItem(items, "location"));
    // Should NOT contain keywords
    try std.testing.expect(!hasItem(items, "fn"));
}

test "completion: empty file returns keywords and types" {
    const source: [:0]const u8 = "";
    const ctx = try setup(source);
    defer teardown(ctx);
    const items = try ctx.handler.computeCompletion("test://file.wgsl", .{ .line = 0, .character = 0 });
    defer std.testing.allocator.free(items);
    try std.testing.expect(items.len > 0);
    try std.testing.expect(hasItem(items, "fn"));
    try std.testing.expect(hasItem(items, "struct"));
}

test "completion: unknown document returns empty" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    const items = try handler.computeCompletion("test://nonexistent.wgsl", .{ .line = 0, .character = 0 });
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

// =========================================================================
// Edge cases
// =========================================================================

test "completion: includes user-defined structs" {
    const source: [:0]const u8 = "struct MyData { x: f32 } fn f() { }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const items = try ctx.handler.computeCompletion("test://file.wgsl", .{ .line = 0, .character = 34 });
    defer std.testing.allocator.free(items);
    try std.testing.expect(hasItem(items, "MyData"));
}

test "completion: includes user-defined functions" {
    const source: [:0]const u8 = "fn helper() {} fn main() { }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const items = try ctx.handler.computeCompletion("test://file.wgsl", .{ .line = 0, .character = 27 });
    defer std.testing.allocator.free(items);
    try std.testing.expect(hasItem(items, "helper"));
}

test "completion: after @ includes all standard attributes" {
    const source: [:0]const u8 = "@";
    const ctx = try setup(source);
    defer teardown(ctx);
    const items = try ctx.handler.computeCompletion("test://file.wgsl", .{ .line = 0, .character = 1 });
    defer std.testing.allocator.free(items);
    try std.testing.expect(hasItem(items, "workgroup_size"));
    try std.testing.expect(hasItem(items, "builtin"));
    try std.testing.expect(hasItem(items, "id"));
    try std.testing.expect(hasItem(items, "align"));
    try std.testing.expect(hasItem(items, "size"));
    try std.testing.expect(hasItem(items, "interpolate"));
    try std.testing.expect(hasItem(items, "invariant"));
    try std.testing.expect(hasItem(items, "must_use"));
    try std.testing.expect(hasItem(items, "diagnostic"));
}

test "completion: includes all texture type names" {
    const source: [:0]const u8 = "fn f() { }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const items = try ctx.handler.computeCompletion("test://file.wgsl", .{ .line = 0, .character = 9 });
    defer std.testing.allocator.free(items);
    try std.testing.expect(hasItem(items, "texture_2d"));
    try std.testing.expect(hasItem(items, "texture_3d"));
    try std.testing.expect(hasItem(items, "texture_cube"));
    try std.testing.expect(hasItem(items, "sampler"));
    try std.testing.expect(hasItem(items, "sampler_comparison"));
}

test "completion: includes vector/matrix shorthands" {
    const source: [:0]const u8 = "fn f() { }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const items = try ctx.handler.computeCompletion("test://file.wgsl", .{ .line = 0, .character = 9 });
    defer std.testing.allocator.free(items);
    try std.testing.expect(hasItem(items, "vec2f"));
    try std.testing.expect(hasItem(items, "vec3u"));
    try std.testing.expect(hasItem(items, "vec4i"));
    try std.testing.expect(hasItem(items, "mat4x4f"));
    try std.testing.expect(hasItem(items, "mat2x2h"));
}

test "completion: includes control flow keywords" {
    const source: [:0]const u8 = "fn f() { }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const items = try ctx.handler.computeCompletion("test://file.wgsl", .{ .line = 0, .character = 9 });
    defer std.testing.allocator.free(items);
    try std.testing.expect(hasItem(items, "for"));
    try std.testing.expect(hasItem(items, "while"));
    try std.testing.expect(hasItem(items, "loop"));
    try std.testing.expect(hasItem(items, "switch"));
    try std.testing.expect(hasItem(items, "break"));
    try std.testing.expect(hasItem(items, "continue"));
    try std.testing.expect(hasItem(items, "discard"));
}

test "completion: includes math builtins" {
    const source: [:0]const u8 = "fn f() { }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const items = try ctx.handler.computeCompletion("test://file.wgsl", .{ .line = 0, .character = 9 });
    defer std.testing.allocator.free(items);
    try std.testing.expect(hasItem(items, "abs"));
    try std.testing.expect(hasItem(items, "clamp"));
    try std.testing.expect(hasItem(items, "min"));
    try std.testing.expect(hasItem(items, "max"));
    try std.testing.expect(hasItem(items, "pow"));
    try std.testing.expect(hasItem(items, "sqrt"));
    try std.testing.expect(hasItem(items, "normalize"));
    try std.testing.expect(hasItem(items, "cross"));
    try std.testing.expect(hasItem(items, "length"));
    try std.testing.expect(hasItem(items, "distance"));
}

test "completion: includes atomic builtins" {
    const source: [:0]const u8 = "fn f() { }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const items = try ctx.handler.computeCompletion("test://file.wgsl", .{ .line = 0, .character = 9 });
    defer std.testing.allocator.free(items);
    try std.testing.expect(hasItem(items, "atomicLoad"));
    try std.testing.expect(hasItem(items, "atomicStore"));
    try std.testing.expect(hasItem(items, "atomicAdd"));
}

test "completion: includes texture builtins" {
    const source: [:0]const u8 = "fn f() { }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const items = try ctx.handler.computeCompletion("test://file.wgsl", .{ .line = 0, .character = 9 });
    defer std.testing.allocator.free(items);
    try std.testing.expect(hasItem(items, "textureSample"));
    try std.testing.expect(hasItem(items, "textureLoad"));
    try std.testing.expect(hasItem(items, "textureStore"));
    try std.testing.expect(hasItem(items, "textureDimensions"));
}

// =========================================================================
// Member ("dot") completion (plan 05, Block 4)
// =========================================================================

/// Completion at the byte offset just past `needle`'s last occurrence.
fn completeAfter(handler: *Handler, source: [:0]const u8, needle: []const u8) ![]Handler.CompletionItem {
    const idx = std.mem.lastIndexOf(u8, source, needle) orelse return error.TestUnexpectedResult;
    const off: u32 = @intCast(idx + needle.len);
    const pos = Handler.offsetToLspPosition(source, off) orelse return error.TestUnexpectedResult;
    return handler.computeCompletion("test://file.wgsl", pos);
}

test "completion: dot on an incomplete statement still offers fields" {
    // The real dot-completion state: the editor fires completion the instant
    // `.` is typed, when nothing follows it. Parser error recovery drops that
    // statement, so the base identifier is not in the AST at that offset —
    // resolution has to survive that.
    const source: [:0]const u8 =
        \\struct S { a: f32 }
        \\fn f() {
        \\  var p: S;
        \\  p.
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const items = try completeAfter(ctx.handler, source, "p.");
    defer std.testing.allocator.free(items);
    try std.testing.expect(hasItem(items, "a"));
}

test "completion: dot resolves the base to the enclosing function's local" {
    // `one`'s `p` precedes `two`'s in module.symbols, so a whole-module name
    // scan hands back struct A's fields inside `two`.
    const source: [:0]const u8 =
        \\struct A { fa: f32 }
        \\struct B { fb: f32 }
        \\fn one() { var p: A; let q = p.; }
        \\fn two() { var p: B; let r = p.; }
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const items = try completeAfter(ctx.handler, source, "p.");
    defer std.testing.allocator.free(items);
    try std.testing.expect(hasItem(items, "fb"));
    try std.testing.expect(!hasItem(items, "fa"));
}

// =========================================================================
// Scope-aware general completion (plan 05, Block 5)
// =========================================================================

/// Completion at the byte offset of `needle`'s first occurrence.
fn completeAt(handler: *Handler, source: [:0]const u8, needle: []const u8) ![]Handler.CompletionItem {
    const idx = std.mem.indexOf(u8, source, needle) orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(idx)) orelse return error.TestUnexpectedResult;
    return handler.computeCompletion("test://file.wgsl", pos);
}

test "completion: another function's locals are not offered" {
    const source: [:0]const u8 =
        \\fn a() { let only_in_a = 1.0; }
        \\fn b() {
        \\  /*HERE*/
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const items = try completeAt(ctx.handler, source, "/*HERE*/");
    defer std.testing.allocator.free(items);
    try std.testing.expect(!hasItem(items, "only_in_a"));
    // Module-level names stay visible.
    try std.testing.expect(hasItem(items, "a"));
    try std.testing.expect(hasItem(items, "b"));
}

test "completion: an enclosing block's locals are offered" {
    const source: [:0]const u8 =
        \\fn c() {
        \\  let y = 1.0;
        \\  if (true) {
        \\    /*HERE*/
        \\  }
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const items = try completeAt(ctx.handler, source, "/*HERE*/");
    defer std.testing.allocator.free(items);
    try std.testing.expect(hasItem(items, "y"));
}

test "completion: locals declared after the cursor are not offered" {
    const source: [:0]const u8 =
        \\fn d() {
        \\  let before = 1.0;
        \\  /*HERE*/
        \\  let after = 2.0;
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const items = try completeAt(ctx.handler, source, "/*HERE*/");
    defer std.testing.allocator.free(items);
    try std.testing.expect(hasItem(items, "before"));
    try std.testing.expect(!hasItem(items, "after"));
}

test "completion: the enclosing function's parameters are always offered" {
    const source: [:0]const u8 =
        \\fn e(param_x: f32, param_y: f32) -> f32 {
        \\  /*HERE*/
        \\  return param_x;
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const items = try completeAt(ctx.handler, source, "/*HERE*/");
    defer std.testing.allocator.free(items);
    try std.testing.expect(hasItem(items, "param_x"));
    try std.testing.expect(hasItem(items, "param_y"));
}

test "completion: a for-loop init declaration is offered inside the body" {
    // ForStmt.init_stmt is a bare Stmt, not wrapped in a CompoundStmt, so a
    // nested-compound walk alone would miss it.
    const source: [:0]const u8 =
        \\fn g() {
        \\  for (var i = 0; i < 4; i++) {
        \\    /*HERE*/
        \\  }
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const items = try completeAt(ctx.handler, source, "/*HERE*/");
    defer std.testing.allocator.free(items);
    try std.testing.expect(hasItem(items, "i"));
}

test "completion: a switch case body sees the enclosing function's locals" {
    const source: [:0]const u8 =
        \\fn h(k: i32) {
        \\  let outer = 1.0;
        \\  switch (k) {
        \\    case 0: { let inner = 2.0; /*HERE*/ }
        \\    default: {}
        \\  }
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const items = try completeAt(ctx.handler, source, "/*HERE*/");
    defer std.testing.allocator.free(items);
    try std.testing.expect(hasItem(items, "outer"));
    try std.testing.expect(hasItem(items, "inner"));
    try std.testing.expect(hasItem(items, "k"));
}

test "completion: a loop continuing block sees the loop body's locals" {
    const source: [:0]const u8 =
        \\fn i_fn() {
        \\  loop {
        \\    let body_local = 1.0;
        \\    continuing { /*HERE*/ break if true; }
        \\  }
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const items = try completeAt(ctx.handler, source, "/*HERE*/");
    defer std.testing.allocator.free(items);
    try std.testing.expect(hasItem(items, "body_local"));
}

test "completion: a sibling block's locals are not offered after it closes" {
    const source: [:0]const u8 =
        \\fn f(cond: bool) {
        \\  if (cond) { let block_local = 1.0; }
        \\  /*HERE*/
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const items = try completeAt(ctx.handler, source, "/*HERE*/");
    defer std.testing.allocator.free(items);
    try std.testing.expect(!hasItem(items, "block_local"));
    try std.testing.expect(hasItem(items, "cond"));
}

test "completion: at module level no function locals are offered" {
    const source: [:0]const u8 =
        \\fn a() { let hidden = 1.0; }
        \\/*HERE*/
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const items = try completeAt(ctx.handler, source, "/*HERE*/");
    defer std.testing.allocator.free(items);
    try std.testing.expect(!hasItem(items, "hidden"));
    try std.testing.expect(hasItem(items, "a"));
}

test "completion: dot on a vector base offers swizzle components" {
    const source: [:0]const u8 =
        \\fn f() { var v: vec3f; let s = v.; }
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const items = try completeAfter(ctx.handler, source, "v.");
    defer std.testing.allocator.free(items);
    try std.testing.expect(hasItem(items, "x"));
    try std.testing.expect(hasItem(items, "rgba"[0..1]));
}
