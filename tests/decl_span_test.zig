//! Tests for declaration and type source spans captured by the parser,
//! plus the edit builders that consume them (`removeDeclarationEdit`,
//! `changeTypeEdit`) and the stable-ID locators
//! (`locateDeclaration`, `locateType`).
//!
//! Every test analyzes a shader, looks up the symbol of interest by
//! name, and asserts against the captured span or the result of applying
//! an edit. Round-trip tests re-analyze the rewritten source to confirm
//! parse validity.

const std = @import("std");
const wgslender = @import("wgslender");
const Ast = wgslender.Ast;

// -------------------------------------------------------------------------
// Helpers
// -------------------------------------------------------------------------

fn analyze(a: std.mem.Allocator, source: [:0]const u8) !wgslender.Validator.AnalysisResult {
    return try wgslender.analyze(a, source);
}

/// Look up a top-level or local symbol by name within `module`. Returns
/// `.none` if not found. When multiple symbols share a name (e.g.,
/// shadowing), `skip` lets you pick the Nth (0-indexed).
fn findSymByName(module: *const Ast.Module, name: []const u8, skip: usize) Ast.SymbolIndex {
    var remaining = skip;
    for (module.symbols.items, 0..) |sym, i| {
        if (std.mem.eql(u8, sym.original_name, name)) {
            if (remaining == 0) return @enumFromInt(@as(u32, @intCast(i)));
            remaining -= 1;
        }
    }
    return .none;
}

fn sliceOfSpan(source: []const u8, span: Ast.Span) []const u8 {
    return source[span.start..span.end];
}

fn expectSpan(source: []const u8, span: Ast.Span, expected: []const u8) !void {
    try std.testing.expectEqualStrings(expected, sliceOfSpan(source, span));
}

// -------------------------------------------------------------------------
// Parser-side span capture
// -------------------------------------------------------------------------

test "decl_span: const with trivial initializer" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "const PI: f32 = 3.14;";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), module.declarations.items.len);
    const d = module.declarations.items[0];
    try expectSpan(source, d.declSpan(), "const PI: f32 = 3.14;");
}

test "decl_span: override with attrs" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "@id(0) override K: f32 = 2.0;";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    try expectSpan(source, module.declarations.items[0].declSpan(), "@id(0) override K: f32 = 2.0;");
}

test "decl_span: var without initializer" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "var<private> counter: atomic<u32>;";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    try expectSpan(source, module.declarations.items[0].declSpan(), "var<private> counter: atomic<u32>;");
}

test "decl_span: var with initializer" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "var<private> counter: u32 = 0u;";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    try expectSpan(source, module.declarations.items[0].declSpan(), "var<private> counter: u32 = 0u;");
}

test "decl_span: alias" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "alias V = vec3<f32>;";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    try expectSpan(source, module.declarations.items[0].declSpan(), "alias V = vec3<f32>;");
}

test "decl_span: struct with trailing comma" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "struct S { x: f32, y: i32, }";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    try expectSpan(source, module.declarations.items[0].declSpan(), "struct S { x: f32, y: i32, }");
}

test "decl_span: struct no trailing comma" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "struct S { x: f32, y: i32 }";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    try expectSpan(source, module.declarations.items[0].declSpan(), "struct S { x: f32, y: i32 }");
}

test "decl_span: empty function" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "fn f() {}";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    try expectSpan(source, module.declarations.items[0].declSpan(), "fn f() {}");
}

test "decl_span: function with body and return type" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "fn f(x: i32) -> f32 { return 0.0; }";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    try expectSpan(source, module.declarations.items[0].declSpan(), "fn f(x: i32) -> f32 { return 0.0; }");
}

test "decl_span: entry point attrs included" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "@compute @workgroup_size(16) fn main() {}";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    try expectSpan(source, module.declarations.items[0].declSpan(), "@compute @workgroup_size(16) fn main() {}");
}

test "decl_span: binding attributes + template args" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "@group(0) @binding(0) var<uniform> u: f32;";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    try expectSpan(source, module.declarations.items[0].declSpan(), "@group(0) @binding(0) var<uniform> u: f32;");
}

test "decl_span: local let inside function body" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "fn f() { let x = 1; }";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    const target = findSymByName(module, "x", 0);
    try std.testing.expect(target.isValid());
    const range = wgslender.StableId.locateDeclaration(module, "v1:fn:f/block#0/let:x").?;
    try std.testing.expectEqualStrings("let x = 1;", source[range.start..range.end]);
}

test "decl_span: local var typed inside function body" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "fn f() { var y: i32 = 0; }";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    const range = wgslender.StableId.locateDeclaration(module, "v1:fn:f/block#0/var:y").?;
    try std.testing.expectEqualStrings("var y: i32 = 0;", source[range.start..range.end]);
}

test "decl_span: siblings in nested blocks" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "fn f() { { let inner = 1; } }";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    const range = wgslender.StableId.locateDeclaration(module, "v1:fn:f/block#0/block#0/let:inner").?;
    try std.testing.expectEqualStrings("let inner = 1;", source[range.start..range.end]);
}

// -------------------------------------------------------------------------
// Type spans
// -------------------------------------------------------------------------

test "type_span: plain ident" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "struct S { x: f32 }";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    const s = module.declarations.items[0].@"struct";
    try expectSpan(source, s.members.items[0].typ.span(), "f32");
}

test "type_span: attribute does not bleed" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "struct S { @align(16) x: f32 }";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    const s = module.declarations.items[0].@"struct";
    try expectSpan(source, s.members.items[0].typ.span(), "f32");
}

test "type_span: vec" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "struct S { x: vec3<f32> }";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    const s = module.declarations.items[0].@"struct";
    try expectSpan(source, s.members.items[0].typ.span(), "vec3<f32>");
}

test "type_span: nested array" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "struct S { x: array<array<vec4<f32>, 4>, 8> }";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    const s = module.declarations.items[0].@"struct";
    try expectSpan(source, s.members.items[0].typ.span(), "array<array<vec4<f32>, 4>, 8>");
}

test "type_span: mat" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "struct S { x: mat4x4<f32> }";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    const s = module.declarations.items[0].@"struct";
    try expectSpan(source, s.members.items[0].typ.span(), "mat4x4<f32>");
}

test "type_span: parameter + return type" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "fn f(x: vec3<f32>, y: f32) -> mat4x4<f32> {}";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    const f = module.declarations.items[0].function;
    try expectSpan(source, f.parameters.items[0].typ.span(), "vec3<f32>");
    try expectSpan(source, f.parameters.items[1].typ.span(), "f32");
    try expectSpan(source, f.return_type.?.span(), "mat4x4<f32>");
}

test "type_span: var + const + local let explicit" {
    const a = std.testing.allocator;
    const source: [:0]const u8 =
        \\var<private> v: atomic<u32>;
        \\const C: f32 = 1.0;
        \\fn f() { let a: array<i32, 4> = array<i32, 4>(0, 0, 0, 0); }
    ;
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    try expectSpan(source, module.declarations.items[0].@"var".typ.?.span(), "atomic<u32>");
    try expectSpan(source, module.declarations.items[1].@"const".typ.?.span(), "f32");
    // Local let — reach via StableId locator
    const lt = wgslender.StableId.locateType(module, "v1:fn:f/block#0/let:a").?;
    try std.testing.expectEqualStrings("array<i32, 4>", source[lt.start..lt.end]);
}

// -------------------------------------------------------------------------
// removeDeclarationEdit
// -------------------------------------------------------------------------

fn reanalyze(a: std.mem.Allocator, source: []const u8) !bool {
    const z = try a.dupeZ(u8, source);
    defer a.free(z);
    var re = try wgslender.analyze(a, z);
    defer re.deinit(a);
    return re.module != null;
}

test "removeDeclarationEdit: unused top-level fn" {
    const a = std.testing.allocator;
    const source: [:0]const u8 =
        \\fn helper() -> f32 { return 1.0; }
        \\@compute @workgroup_size(1) fn main() {}
    ;
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    const helper = findSymByName(module, "helper", 0);
    try std.testing.expect(helper.isValid());

    const edits = (try wgslender.Edits.removeDeclarationEdit(a, module, helper)) orelse
        return error.TestUnexpectedResult;
    defer a.free(edits);

    const rewritten = try wgslender.Edits.applyEdits(a, source, edits);
    defer a.free(rewritten);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "helper") == null);
    try std.testing.expect(try reanalyze(a, rewritten));
}

test "removeDeclarationEdit: binding with attributes" {
    const a = std.testing.allocator;
    const source: [:0]const u8 =
        \\@group(0) @binding(0) var<uniform> u: f32;
        \\@compute @workgroup_size(1) fn main() {}
    ;
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;

    const u = findSymByName(module, "u", 0);
    const edits = (try wgslender.Edits.removeDeclarationEdit(a, module, u)) orelse
        return error.TestUnexpectedResult;
    defer a.free(edits);

    const rewritten = try wgslender.Edits.applyEdits(a, source, edits);
    defer a.free(rewritten);
    // Attribute went with it.
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "@group") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "u: f32") == null);
    try std.testing.expect(try reanalyze(a, rewritten));
}

test "removeDeclarationEdit: local let" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "fn f() { let x = 1; let y = 2; }";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    const x = findSymByName(module, "x", 0);

    const edits = (try wgslender.Edits.removeDeclarationEdit(a, module, x)) orelse
        return error.TestUnexpectedResult;
    defer a.free(edits);
    const rewritten = try wgslender.Edits.applyEdits(a, source, edits);
    defer a.free(rewritten);
    try std.testing.expectEqualStrings("fn f() {  let y = 2; }", rewritten);
    try std.testing.expect(try reanalyze(a, rewritten));
}

test "removeDeclarationEdit: rejects member symbol" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "struct S { x: f32 }";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    const field = findSymByName(module, "x", 0);
    try std.testing.expect(field.isValid());

    const edits = try wgslender.Edits.removeDeclarationEdit(a, module, field);
    try std.testing.expect(edits == null);
}

test "removeDeclarationEdit: rejects parameter symbol" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "fn f(x: f32) {}";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    const param = findSymByName(module, "x", 0);

    const edits = try wgslender.Edits.removeDeclarationEdit(a, module, param);
    try std.testing.expect(edits == null);
}

test "removeDeclarationEdit: rejects .none" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "const X = 1;";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    const edits = try wgslender.Edits.removeDeclarationEdit(a, module, .none);
    try std.testing.expect(edits == null);
}

// -------------------------------------------------------------------------
// changeTypeEdit
// -------------------------------------------------------------------------

test "changeTypeEdit: struct field" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "struct S { x: f32 }";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    const f = findSymByName(module, "x", 0);

    const edits = (try wgslender.Edits.changeTypeEdit(a, module, f, "i32")) orelse
        return error.TestUnexpectedResult;
    defer a.free(edits);
    const rewritten = try wgslender.Edits.applyEdits(a, source, edits);
    defer a.free(rewritten);
    try std.testing.expectEqualStrings("struct S { x: i32 }", rewritten);
    try std.testing.expect(try reanalyze(a, rewritten));
}

test "changeTypeEdit: preserves neighbors in multi-field struct" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "struct S { a: f32, b: f32, c: f32 }";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    const b = findSymByName(module, "b", 0);

    const edits = (try wgslender.Edits.changeTypeEdit(a, module, b, "vec3<f32>")) orelse
        return error.TestUnexpectedResult;
    defer a.free(edits);
    const rewritten = try wgslender.Edits.applyEdits(a, source, edits);
    defer a.free(rewritten);
    try std.testing.expectEqualStrings("struct S { a: f32, b: vec3<f32>, c: f32 }", rewritten);
    try std.testing.expect(try reanalyze(a, rewritten));
}

test "changeTypeEdit: attribute preserved" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "struct S { @align(16) x: f32 }";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    const x = findSymByName(module, "x", 0);
    const edits = (try wgslender.Edits.changeTypeEdit(a, module, x, "vec4<f32>")) orelse
        return error.TestUnexpectedResult;
    defer a.free(edits);
    const rewritten = try wgslender.Edits.applyEdits(a, source, edits);
    defer a.free(rewritten);
    try std.testing.expectEqualStrings("struct S { @align(16) x: vec4<f32> }", rewritten);
}

test "changeTypeEdit: fn parameter" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "fn f(x: f32) -> f32 { return x; }";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    const p = findSymByName(module, "x", 0);

    const edits = (try wgslender.Edits.changeTypeEdit(a, module, p, "f32")) orelse
        return error.TestUnexpectedResult;
    defer a.free(edits);
    const rewritten = try wgslender.Edits.applyEdits(a, source, edits);
    defer a.free(rewritten);
    // No-op replace must be byte-identical.
    try std.testing.expectEqualStrings(source, rewritten);
}

test "changeTypeEdit: fn return type" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "fn f() -> f32 { return 1.0; }";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    const f = findSymByName(module, "f", 0);

    const edits = (try wgslender.Edits.changeTypeEdit(a, module, f, "vec2<f32>")) orelse
        return error.TestUnexpectedResult;
    defer a.free(edits);
    const rewritten = try wgslender.Edits.applyEdits(a, source, edits);
    defer a.free(rewritten);
    try std.testing.expectEqualStrings("fn f() -> vec2<f32> { return 1.0; }", rewritten);
}

test "changeTypeEdit: const with explicit type" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "const PI: f32 = 3.14;";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    const pi = findSymByName(module, "PI", 0);
    const edits = (try wgslender.Edits.changeTypeEdit(a, module, pi, "f16")) orelse
        return error.TestUnexpectedResult;
    defer a.free(edits);
    const rewritten = try wgslender.Edits.applyEdits(a, source, edits);
    defer a.free(rewritten);
    try std.testing.expectEqualStrings("const PI: f16 = 3.14;", rewritten);
}

test "changeTypeEdit: rejects untyped const" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "const PI = 3.14;";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    const pi = findSymByName(module, "PI", 0);
    const edits = try wgslender.Edits.changeTypeEdit(a, module, pi, "f32");
    try std.testing.expect(edits == null);
}

test "changeTypeEdit: rejects void return type" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "fn f() {}";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    const f = findSymByName(module, "f", 0);
    const edits = try wgslender.Edits.changeTypeEdit(a, module, f, "f32");
    try std.testing.expect(edits == null);
}

test "changeTypeEdit: malformed replacement rejected" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "struct S { x: f32 }";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    const x = findSymByName(module, "x", 0);

    try std.testing.expect((try wgslender.Edits.changeTypeEdit(a, module, x, "")) == null);
    try std.testing.expect((try wgslender.Edits.changeTypeEdit(a, module, x, "f32;")) == null);
    try std.testing.expect((try wgslender.Edits.changeTypeEdit(a, module, x, "f32\n")) == null);
    try std.testing.expect((try wgslender.Edits.changeTypeEdit(a, module, x, "f32}")) == null);
}

// -------------------------------------------------------------------------
// Stable ID locators
// -------------------------------------------------------------------------

test "locateDeclaration: via stable ID" {
    const a = std.testing.allocator;
    const source: [:0]const u8 =
        \\fn helper() -> f32 { return 1.0; }
    ;
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    const range = wgslender.StableId.locateDeclaration(module, "v1:fn:helper").?;
    try std.testing.expectEqualStrings("fn helper() -> f32 { return 1.0; }", source[range.start..range.end]);
}

test "locateType: fn return type via stable ID" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "fn f() -> vec3<f32> { return vec3<f32>(0.0); }";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    const range = wgslender.StableId.locateType(module, "v1:fn:f").?;
    try std.testing.expectEqualStrings("vec3<f32>", source[range.start..range.end]);
}

test "locateType: struct member via stable ID" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "struct S { x: vec2<f32> }";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    const range = wgslender.StableId.locateType(module, "v1:struct:S/member:x").?;
    try std.testing.expectEqualStrings("vec2<f32>", source[range.start..range.end]);
}

test "locateType: parameter via stable ID" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "fn f(p: u32) {}";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    const range = wgslender.StableId.locateType(module, "v1:fn:f/param:p").?;
    try std.testing.expectEqualStrings("u32", source[range.start..range.end]);
}

test "locateDeclaration: null for unknown ID" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "const X = 1;";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    try std.testing.expect(wgslender.StableId.locateDeclaration(module, "v1:fn:nope") == null);
    try std.testing.expect(wgslender.StableId.locateType(module, "v1:fn:nope") == null);
}

// -------------------------------------------------------------------------
// Composition and round-trip
// -------------------------------------------------------------------------

// -------------------------------------------------------------------------
// Bulk regression (compute.toys corpus)
// -------------------------------------------------------------------------

fn makeSentinel(a: std.mem.Allocator, bytes: []const u8) ![:0]const u8 {
    const buf = try a.alloc(u8, bytes.len + 1);
    @memcpy(buf[0..bytes.len], bytes);
    buf[bytes.len] = 0;
    return buf[0..bytes.len :0];
}

test "compute.toys: changeTypeEdit no-op is byte-identical" {
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

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    var walker = try dir.walk(a);
    defer walker.deinit();

    var shaders: usize = 0;
    var edits_checked: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".wgsl")) continue;

        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();

        const bytes = entry.dir.readFileAlloc(io, entry.basename, alloc, .unlimited) catch continue;
        const src = try makeSentinel(alloc, bytes);

        var an = try wgslender.analyze(a, src);
        defer an.deinit(a);
        const module = an.module orelse continue;

        // Walk decls, collect every typed site, apply a no-op changeTypeEdit,
        // assert the result is byte-identical.
        for (module.declarations.items) |decl| {
            const sym = decl.nameRef();
            const maybe_typ: ?Ast.Type = switch (decl) {
                .@"const" => |c| c.typ,
                .override => |o| o.typ,
                .@"var" => |v| v.typ,
                .let => |l| l.typ,
                .alias => |al| al.typ,
                .function => |f| f.return_type,
                else => null,
            };
            if (sym.isValid()) if (maybe_typ) |t| {
                const span = t.span();
                const current_text = src[span.start..span.end];
                if (current_text.len == 0) continue;
                // Skip if the literal contains chars our guard rejects (e.g. `{`).
                var has_bad: bool = false;
                for (current_text) |ch| {
                    if (ch == '\n' or ch == '\r' or ch == ';' or ch == '}' or ch == '{') {
                        has_bad = true;
                        break;
                    }
                }
                if (has_bad) continue;

                const edits = (try wgslender.Edits.changeTypeEdit(a, module, sym, current_text)) orelse continue;
                defer a.free(edits);
                const rewritten = try wgslender.Edits.applyEdits(a, src, edits);
                defer a.free(rewritten);
                try std.testing.expectEqualStrings(src, rewritten);
                edits_checked += 1;
            };

            // Struct members.
            if (decl == .@"struct") {
                const st = decl.@"struct";
                for (st.members.items) |m| {
                    const span = m.typ.span();
                    const current = src[span.start..span.end];
                    if (current.len == 0) continue;
                    const edits = (try wgslender.Edits.changeTypeEdit(a, module, m.name, current)) orelse continue;
                    defer a.free(edits);
                    const rewritten = try wgslender.Edits.applyEdits(a, src, edits);
                    defer a.free(rewritten);
                    try std.testing.expectEqualStrings(src, rewritten);
                    edits_checked += 1;
                }
            }

            // Function parameters.
            if (decl == .function) {
                for (decl.function.parameters.items) |p| {
                    const span = p.typ.span();
                    const current = src[span.start..span.end];
                    if (current.len == 0) continue;
                    const edits = (try wgslender.Edits.changeTypeEdit(a, module, p.name, current)) orelse continue;
                    defer a.free(edits);
                    const rewritten = try wgslender.Edits.applyEdits(a, src, edits);
                    defer a.free(rewritten);
                    try std.testing.expectEqualStrings(src, rewritten);
                    edits_checked += 1;
                }
            }
        }
        shaders += 1;
    }
    std.debug.print(
        "compute.toys changeTypeEdit no-op: {d} shaders, {d} edits verified byte-identical\n",
        .{ shaders, edits_checked },
    );
    try std.testing.expect(shaders > 0);
    try std.testing.expect(edits_checked > 0);
}

test "compute.toys: removeDeclarationEdit produces parseable rewrites" {
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

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    var walker = try dir.walk(a);
    defer walker.deinit();

    var shaders: usize = 0;
    var decls_removed: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".wgsl")) continue;

        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();

        const bytes = entry.dir.readFileAlloc(io, entry.basename, alloc, .unlimited) catch continue;
        const src = try makeSentinel(alloc, bytes);

        var an = try wgslender.analyze(a, src);
        defer an.deinit(a);
        const module = an.module orelse continue;

        // Collect top-level decl symbols before any rewrite.
        var syms: std.ArrayListUnmanaged(Ast.SymbolIndex) = .empty;
        defer syms.deinit(alloc);
        for (module.declarations.items) |decl| {
            const s = decl.nameRef();
            if (s.isValid()) try syms.append(alloc, s);
        }

        // For each one, produce a removeDeclarationEdit against the original
        // source and assert the rewritten source re-parses (validation may
        // fail; we only care about parse).
        for (syms.items) |sym| {
            const edits = (try wgslender.Edits.removeDeclarationEdit(a, module, sym)) orelse continue;
            defer a.free(edits);
            const rewritten = try wgslender.Edits.applyEdits(a, src, edits);
            defer a.free(rewritten);

            const rz = try a.dupeZ(u8, rewritten);
            defer a.free(rz);
            var re = try wgslender.analyze(a, rz);
            defer re.deinit(a);
            try std.testing.expect(re.module != null);
            decls_removed += 1;
        }
        shaders += 1;
    }
    std.debug.print(
        "compute.toys removeDeclarationEdit: {d} shaders, {d} decls removed and re-parsed\n",
        .{ shaders, decls_removed },
    );
    try std.testing.expect(shaders > 0);
    try std.testing.expect(decls_removed > 0);
}

test "change + re-stable-id round-trip" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "struct S { x: f32 } fn f() -> f32 { return 0.0; }";
    var r = try analyze(a, source);
    defer r.deinit(a);
    const module = r.module orelse return error.TestUnexpectedResult;
    const x = findSymByName(module, "x", 0);
    const edits = (try wgslender.Edits.changeTypeEdit(a, module, x, "i32")) orelse
        return error.TestUnexpectedResult;
    defer a.free(edits);
    const rewritten = try wgslender.Edits.applyEdits(a, source, edits);
    defer a.free(rewritten);

    const z = try a.dupeZ(u8, rewritten);
    defer a.free(z);
    var r2 = try wgslender.analyze(a, z);
    defer r2.deinit(a);
    const m2 = r2.module orelse return error.TestUnexpectedResult;

    const range2 = wgslender.StableId.locateType(m2, "v1:struct:S/member:x").?;
    try std.testing.expectEqualStrings("i32", rewritten[range2.start..range2.end]);
}
