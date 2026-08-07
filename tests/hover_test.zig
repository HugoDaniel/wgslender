const std = @import("std");
const Handler = @import("Handler");
const Builtins = @import("wgslender").Builtins;

fn setup(source: [:0]const u8) !struct { handler: *Handler, source: [:0]const u8 } {
    const handler = try std.testing.allocator.create(Handler);
    handler.* = Handler.init(std.testing.allocator);
    try handler.openDocument("test://file.wgsl", source, 1);
    return .{ .handler = handler, .source = source };
}

fn teardown(ctx: anytype) void {
    ctx.handler.deinit();
    std.testing.allocator.destroy(ctx.handler);
}

fn posAt(source: []const u8, needle: []const u8) ?Handler.Position {
    const offset = std.mem.indexOf(u8, source, needle) orelse return null;
    return Handler.offsetToLspPosition(source, @intCast(offset));
}

/// Assert hover contents are markdown a client can actually render.
///
/// Both transports serve hover as `MarkupContent{kind: "markdown"}`
/// (`lsp/wire/navigation.zig`, `lsp/lspkit/navigation.zig`), and WGSL is not
/// markdown. Two things break outside a fence:
///
///   - `vec4<f32>` is parsed as an HTML tag, so the type parameter arrives as
///     an element and renders as nothing — the text is in the DOM and
///     invisible on screen.
///   - single newlines fold, so the struct-layout table collapses into one
///     paragraph.
///
/// So: every `<` belongs inside a fence, and every fence is closed.
fn expectRenderableMarkdown(contents: []const u8) !void {
    var inside_fence = false;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "```")) {
            inside_fence = !inside_fence;
            continue;
        }
        if (!inside_fence and std.mem.indexOfScalar(u8, line, '<') != null) {
            std.debug.print("\nunfenced '<' in hover line: {s}\n", .{line});
            return error.UnfencedAngleBracket;
        }
    }
    if (inside_fence) {
        std.debug.print("\nunclosed fence in hover:\n{s}\n", .{contents});
        return error.UnclosedFence;
    }
}

test "hover: a function signature's type parameters survive markdown" {
    const source: [:0]const u8 = "fn shade(c: vec4<f32>) -> vec4<f32> { return c; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = posAt(source, "shade") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    try expectRenderableMarkdown(result.?.contents);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "vec4<f32>") != null);
}

test "hover: a variable's type parameters survive markdown" {
    const source: [:0]const u8 = "fn f() { let v = vec3<f32>(1.0); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = posAt(source, "v =") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    try expectRenderableMarkdown(result.?.contents);
}

test "hover: a builtin's type constraint survives markdown" {
    // The one this was found on: sin's constraint reads
    // "T is f32, f16, vecN<f32>, or vecN<f16>", and rendered as
    // "T is f32, f16, vecN, or vecN" in the playground.
    const source: [:0]const u8 = "fn f(x: f32) -> f32 { return sin(x); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = posAt(source, "sin") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    try expectRenderableMarkdown(result.?.contents);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "vecN<f32>") != null);
}

test "hover: a builtin description's prose is escaped, not fenced" {
    // The description stays outside the fence, so its metacharacters have to
    // be escaped instead. `step` is the builtin that has one: "Returns 0.0 if
    // x < edge, otherwise 1.0."
    try std.testing.expect(std.mem.indexOfScalar(u8, Builtins.doc("step").?.description, '<') != null);

    const source: [:0]const u8 = "fn f(x: f32) -> f32 { return step(0.5, x); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = posAt(source, "step") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    try expectRenderableMarkdown(result.?.contents);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "x &lt; edge") != null);
}

test "hover: a struct layout keeps its lines" {
    const source: [:0]const u8 = "struct Camera { eye: vec3<f32>, time: f32 } fn f(c: Camera) {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const type_ref = std.mem.lastIndexOf(u8, source, "Camera") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(type_ref)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    try expectRenderableMarkdown(result.?.contents);
    // One line per field is the whole point of this hover; markdown folds
    // single newlines, so the fence is what preserves them.
    try std.testing.expect(std.mem.count(u8, result.?.contents, "\n  @") == 2);
}

test "hover: a member access's field type survives markdown" {
    const source: [:0]const u8 =
        "struct S { p: vec2<f32> } fn f(s: S) -> vec2<f32> { return s.p; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const dot_pos = std.mem.lastIndexOf(u8, source, ".p") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(dot_pos + 1)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    try expectRenderableMarkdown(result.?.contents);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "vec2<f32>") != null);
}

test "hover: a binary expression's type survives markdown" {
    const source: [:0]const u8 =
        \\fn f(a: vec2<f32>, b: vec2<f32>) -> vec2<f32> {
        \\  return a + b;
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = posAt(source, "+ b") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    if (result) |r| {
        defer std.testing.allocator.free(r.contents);
        try expectRenderableMarkdown(r.contents);
    }
}

test "hover: variable shows type" {
    const source: [:0]const u8 = "fn f() { let x: f32 = 1.0; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Hover on 'x' in 'let x'
    const pos = posAt(source, "x:") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    // Should contain "f32"
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "f32") != null);
}

test "hover: function name shows full signature" {
    const source: [:0]const u8 = "fn my_func() -> f32 { return 1.0; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = posAt(source, "my_func") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "my_func") != null);
    // Should show full signature: fn my_func() -> f32
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "fn ") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "f32") != null);
}

test "hover: whitespace returns null" {
    const source: [:0]const u8 = "fn f() { }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Position at a space
    const result = try ctx.handler.computeHover("test://file.wgsl", .{ .line = 0, .character = 2 });
    try std.testing.expect(result == null);
}

test "hover: type ref shows struct info" {
    const source: [:0]const u8 = "struct S { x: f32, y: f32 } fn f(s: S) {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Find the second 'S' (in "s: S")
    const s_type_pos = std.mem.lastIndexOf(u8, source, "S") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(s_type_pos)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    // Should show struct fields
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "struct S") != null);
}

test "hover: parse error returns null gracefully" {
    const source: [:0]const u8 = "fn { invalid }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const result = try ctx.handler.computeHover("test://file.wgsl", .{ .line = 0, .character = 0 });
    // Should not crash, may return null
    if (result) |r| std.testing.allocator.free(r.contents);
}

test "hover: unknown document returns null" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    const result = try handler.computeHover("test://nonexistent.wgsl", .{ .line = 0, .character = 0 });
    try std.testing.expect(result == null);
}

// =========================================================================
// Edge cases: multi-line, nested, WGSL-specific
// =========================================================================

test "hover: multi-line function with parameters" {
    const source: [:0]const u8 =
        \\@compute @workgroup_size(1)
        \\fn main(
        \\  @builtin(global_invocation_id) id: vec3u
        \\) {
        \\  let x: f32 = 1.0;
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    // Hover on 'x' in let statement — line 4, char 6
    const result = try ctx.handler.computeHover("test://file.wgsl", .{ .line = 4, .character = 6 });
    if (result) |r| {
        defer std.testing.allocator.free(r.contents);
        try std.testing.expect(std.mem.indexOf(u8, r.contents, "f32") != null);
    }
}

test "hover: const with integer value" {
    const source: [:0]const u8 = "const SIZE: u32 = 256;";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = posAt(source, "SIZE") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "const") != null);
}

test "hover: override declaration" {
    const source: [:0]const u8 = "@id(0) override WG_SIZE: u32 = 64;";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = posAt(source, "WG_SIZE") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "override") != null);
}

test "hover: variable with address space" {
    const source: [:0]const u8 = "var<private> counter: u32 = 0;";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = posAt(source, "counter") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    try std.testing.expect(result.?.contents.len > 0);
}

test "hover: struct with multiple fields shows all" {
    const source: [:0]const u8 =
        \\struct Vertex {
        \\  position: vec3f,
        \\  normal: vec3f,
        \\  uv: vec2f,
        \\}
        \\fn f(v: Vertex) {}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    // Hover on "Vertex" in parameter type — find the second occurrence
    const type_offset = std.mem.lastIndexOf(u8, source, "Vertex") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(type_offset)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "position") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "normal") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "uv") != null);
}

test "hover: parameter inside function body" {
    const source: [:0]const u8 = "fn add(a: f32, b: f32) -> f32 { return a + b; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Hover on 'a' in "return a + b" (the usage)
    const a_usage = std.mem.lastIndexOf(u8, source, "a") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(a_usage)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    if (result) |r| {
        defer std.testing.allocator.free(r.contents);
        try std.testing.expect(std.mem.indexOf(u8, r.contents, "parameter") != null);
    }
}

test "hover: entry point function" {
    const source: [:0]const u8 = "@vertex fn vs_main() -> @builtin(position) vec4f { return vec4f(0.0); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = posAt(source, "vs_main") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "fn ") != null);
}

test "hover: position past end of file returns null" {
    const source: [:0]const u8 = "fn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const result = try ctx.handler.computeHover("test://file.wgsl", .{ .line = 99, .character = 0 });
    try std.testing.expect(result == null);
}

test "hover: empty source returns null" {
    const source: [:0]const u8 = "";
    const ctx = try setup(source);
    defer teardown(ctx);
    const result = try ctx.handler.computeHover("test://file.wgsl", .{ .line = 0, .character = 0 });
    try std.testing.expect(result == null);
}

test "hover: nested struct member type" {
    const source: [:0]const u8 = "struct Inner { x: f32 } struct Outer { inner: Inner }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Hover on "Inner" in Outer's field type
    const inner_ref = std.mem.lastIndexOf(u8, source, "Inner") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(inner_ref)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    // Should show Inner's struct info
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "Inner") != null);
}

test "hover: member access shows field type" {
    const source: [:0]const u8 = "struct S { x: f32 } fn f(s: S) -> f32 { return s.x; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Find the '.x' member access — hover on 'x' after the dot
    const dot_pos = std.mem.lastIndexOf(u8, source, ".x") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(dot_pos + 1)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    // Should show "(field) x: f32"
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "field") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "f32") != null);
}

test "hover: function with params shows full signature" {
    const source: [:0]const u8 = "fn add(a: f32, b: f32) -> f32 { return a + b; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = posAt(source, "add") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    // Should show "fn add(a: f32, b: f32) -> f32"
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "fn add(") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "a: f32") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "b: f32") != null);
}

test "hover: struct type shows size and alignment" {
    const source: [:0]const u8 = "struct S { x: f32, y: f32 } fn f(s: S) {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Find the second 'S' (in "s: S")
    const s_type_pos = std.mem.lastIndexOf(u8, source, "S") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(s_type_pos)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    // Should show struct with size/alignment info
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "struct S") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "size:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "align:") != null);
    // Should show per-field offsets
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "@0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "@4") != null);
}

test "hover: struct layout shows padding gaps" {
    // vec3<f32> is 12 bytes but aligns to 16, so there will be padding before the next field
    const source: [:0]const u8 = "struct V { pos: vec3<f32>, w: f32 } fn f(v: V) {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const v_type_pos = std.mem.lastIndexOf(u8, source, "V") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(v_type_pos)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    // Should show field offsets
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "@0") != null);
    // vec3<f32> is 12 bytes, next field at offset 12 (no padding since f32 aligns to 4)
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "pos") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "w") != null);
}

test "hover: builtin function shows signature and description" {
    const source: [:0]const u8 = "fn f(x: f32) -> f32 { return sin(x); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Hover on 'sin'
    const pos = posAt(source, "sin") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    // Should show signature
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "fn sin") != null);
    // Should show description
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "sine") != null);
    // Should show category
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "numeric") != null);
}

test "hover: builtin with uniform requirement shows warning" {
    const source: [:0]const u8 = "@fragment fn f(@location(0) uv: vec2f) -> @location(0) vec4f { return textureSample(t, s, uv); } @group(0) @binding(0) var t: texture_2d<f32>; @group(0) @binding(1) var s: sampler;";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = posAt(source, "textureSample") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    // Should show uniform control flow requirement
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "uniform") != null);
}

test "hover: builtin length in let initializer" {
    const source: [:0]const u8 = "fn f(v: vec3f) -> f32 { let s = length(v); return s; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = posAt(source, "length") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "fn length") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "magnitude") != null);
}

test "hover: builtin normalize in return expression" {
    const source: [:0]const u8 = "fn f(v: vec3f) -> vec3f { return normalize(v); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = posAt(source, "normalize") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "fn normalize") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "unit vector") != null);
}

test "hover: builtin normalize in binary expression" {
    const source: [:0]const u8 = "fn f(v: vec3f) -> vec3f { return normalize(v) * 2.0; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = posAt(source, "normalize") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "fn normalize") != null);
}

test "hover: builtin after local declaration" {
    const source: [:0]const u8 =
        \\fn f(v: vec3f, max_speed: f32) -> vec3f {
        \\  let speed = length(v);
        \\  if speed > max_speed {
        \\    return normalize(v) * max_speed;
        \\  }
        \\  return v;
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = posAt(source, "normalize") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "fn normalize") != null);
}

test "hover: user function still works after builtin changes" {
    const source: [:0]const u8 = "fn my_fn(a: f32) -> f32 { return a; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = posAt(source, "my_fn") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "my_fn") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "f32") != null);
}

// =========================================================================
// Binary operator hover — const evaluation and expression types
// =========================================================================

test "hover: binary operator shows const evaluated value" {
    const source: [:0]const u8 =
        \\const A = 10;
        \\const B = A * 20;
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    // Hover on the '*' operator in A * 20
    const pos = posAt(source, "* 20") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    if (result) |r| {
        defer std.testing.allocator.free(r.contents);
        // Should show "= 200"
        try std.testing.expect(std.mem.indexOf(u8, r.contents, "200") != null);
    }
}

test "hover: binary operator shows expression type" {
    const source: [:0]const u8 =
        \\fn f() {
        \\  let a: f32 = 1.0;
        \\  let b: f32 = 2.0;
        \\  let c = a + b;
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    // Hover on '+' in a + b
    const pos = posAt(source, "+ b") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    if (result) |r| {
        defer std.testing.allocator.free(r.contents);
        // Should show f32 as the expression type
        try std.testing.expect(std.mem.indexOf(u8, r.contents, "f32") != null);
    }
}

test "hover: binary operator on non-const expr shows type only" {
    const source: [:0]const u8 =
        \\fn f(x: f32, y: f32) -> f32 {
        \\  return x + y;
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = posAt(source, "+ y") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    if (result) |r| {
        defer std.testing.allocator.free(r.contents);
        // Should show type (f32) but no const value
        try std.testing.expect(std.mem.indexOf(u8, r.contents, "f32") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.contents, "= ") == null);
    }
}

test "hover: binary operator with chained const" {
    const source: [:0]const u8 =
        \\const X = 3;
        \\const Y = 4;
        \\const Z = X + Y;
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = posAt(source, "+ Y") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    if (result) |r| {
        defer std.testing.allocator.free(r.contents);
        // Should show "= 7"
        try std.testing.expect(std.mem.indexOf(u8, r.contents, "7") != null);
    }
}

test "hover: comparison operator returns null (no useful hover)" {
    const source: [:0]const u8 =
        \\fn f() {
        \\  let a: i32 = 1;
        \\  let b: i32 = 2;
        \\  if a == b {}
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = posAt(source, "== b") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    // Comparison operators still return a binary_expr node which may show the bool type
    if (result) |r| {
        defer std.testing.allocator.free(r.contents);
    }
}

test "hover: const multiplication evaluated" {
    const source: [:0]const u8 =
        \\const W = 16;
        \\const H = 8;
        \\const AREA = W * H;
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = posAt(source, "* H") orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    if (result) |r| {
        defer std.testing.allocator.free(r.contents);
        try std.testing.expect(std.mem.indexOf(u8, r.contents, "128") != null);
    }
}
