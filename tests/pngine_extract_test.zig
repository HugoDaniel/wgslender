//! Strict SJON → pngine graph extraction (pngine-shaders phase 01, Task 3).
//!
//! Every fixture here is a recovered-or-clean SJON tree fed to the typed
//! extractor. The suite pins the fail-closed rules:
//!
//!   * no graph from a tree with error-severity parser diagnostics;
//!   * no graph from an `(import …)` document;
//!   * exactly one of `:code`/`:file` for fragments and shader modules;
//!   * a pass owns `:code` and ignores `:file` (a WASM data-file list);
//!   * imports and requires keep their SJON spans;
//!   * duplicate part names fail the program, scoped to one document;
//!   * over-size input is a result, never a `sjon.parse` assert.

const std = @import("std");
const extract = @import("pngine_extract");

const testing = std.testing;
const Types = extract.Types;

const document_path = "/project/program.sjon";

fn spanText(source: []const u8, span: Types.Span) []const u8 {
    return source[span.start..span.end];
}

fn expectDiagnostic(result: *const Types.Result, code: Types.DiagnosticCode) !void {
    for (result.diagnostics) |d| {
        if (d.code == code) return;
    }
    std.debug.print("missing diagnostic {s}; got:", .{@tagName(code)});
    for (result.diagnostics) |d| std.debug.print(" {s}", .{@tagName(d.code)});
    std.debug.print("\n", .{});
    return error.TestExpectedDiagnostic;
}

fn expectProgramDiagnostic(program: *const Types.Program, code: Types.DiagnosticCode) !void {
    for (program.diagnostics) |d| {
        if (d.code == code) return;
    }
    return error.TestExpectedProgramDiagnostic;
}

test "wgsl :file form records name, form, and file spans" {
    const source =
        \\(wgsl :name sceneLib :file "kernels/scene_lib.wgsl")
    ;
    var result = try extract.extract(testing.allocator, document_path, source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(Types.Status.ok, result.status);
    const program = &result.program.?;
    try testing.expectEqualStrings(document_path, program.document_path);
    try testing.expectEqual(@as(usize, 1), program.parts.len);
    try testing.expectEqual(@as(usize, 0), program.roots.len);

    const part = program.parts[0];
    try testing.expectEqual(Types.PartKind.wgsl, part.kind);
    try testing.expectEqualStrings("sceneLib", part.name);
    try testing.expectEqualStrings("sceneLib", spanText(source, part.name_span));
    try testing.expect(part.form_span.end > part.form_span.start);
    switch (part.origin) {
        .file => |file| {
            try testing.expectEqualStrings("kernels/scene_lib.wgsl", file.path);
            try testing.expect(std.mem.indexOf(u8, spanText(source, file.span), "kernels/scene_lib.wgsl") != null);
        },
        else => return error.TestExpectedFileOrigin,
    }
    try testing.expectEqual(@as(usize, 0), part.imports.len);
    try testing.expectEqual(@as(usize, 0), part.requires.len);
}

test "wgsl :code form records an inline origin and permits empty text" {
    const source =
        \\(wgsl :name f :code "fn helper() {}")
        \\(wgsl :name empty :code "")
    ;
    var result = try extract.extract(testing.allocator, document_path, source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(Types.Status.ok, result.status);
    const program = &result.program.?;
    try testing.expectEqual(@as(usize, 2), program.parts.len);

    switch (program.parts[0].origin) {
        .inline_code => |code| {
            try testing.expectEqualStrings("fn helper() {}", code.code);
            try testing.expect(std.mem.indexOf(u8, spanText(source, code.span), "fn helper() {}") != null);
        },
        else => return error.TestExpectedInlineOrigin,
    }
    switch (program.parts[1].origin) {
        .inline_code => |code| try testing.expectEqual(@as(usize, 0), code.code.len),
        else => return error.TestExpectedInlineOrigin,
    }
}

test "shader-module :code root is inline with document, form, and code spans (D17)" {
    const source =
        \\(shader-module :name sceneCode :code "fn vs() {}")
    ;
    var result = try extract.extract(testing.allocator, document_path, source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(Types.Status.ok, result.status);
    const program = &result.program.?;
    try testing.expectEqual(@as(usize, 1), program.parts.len);
    try testing.expectEqual(@as(usize, 1), program.roots.len);
    try testing.expectEqual(@as(u32, 0), program.roots[0]);
    try testing.expectEqual(Types.PartKind.shader_module, program.parts[0].kind);
    try testing.expectEqualStrings(document_path, program.document_path);
    switch (program.parts[0].origin) {
        .inline_code => |code| try testing.expectEqualStrings("fn vs() {}", code.code),
        else => return error.TestExpectedInlineOrigin,
    }
}

test "inline fragment imported by a file root has no file origin (D16)" {
    const source =
        \\(wgsl :name inlineFrag :code "fn helper() {}")
        \\(shader-module :name root :file "root.wgsl" :imports [inlineFrag])
    ;
    var result = try extract.extract(testing.allocator, document_path, source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(Types.Status.ok, result.status);
    const program = &result.program.?;
    try testing.expectEqual(@as(?u32, 0), program.findFragment("inlineFrag"));
    switch (program.parts[0].origin) {
        .inline_code => |code| try testing.expectEqualStrings("fn helper() {}", code.code),
        else => return error.TestExpectedInlineOrigin,
    }
    switch (program.parts[1].origin) {
        .file => |file| try testing.expectEqualStrings("root.wgsl", file.path),
        else => return error.TestExpectedFileOrigin,
    }
    try testing.expectEqual(@as(usize, 1), program.parts[1].imports.len);
    try testing.expectEqualStrings("inlineFrag", program.parts[1].imports[0].name);
}

test "pass :code :imports records the pass root and its import, with no synthetic post root (D18)" {
    const source =
        \\(wgsl :name f :code "fn helper() {}")
        \\(pass :name picture :code "fn fs() {}" :imports [f])
    ;
    var result = try extract.extract(testing.allocator, document_path, source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(Types.Status.ok, result.status);
    const program = &result.program.?;
    try testing.expectEqual(@as(usize, 2), program.parts.len);
    try testing.expectEqual(@as(usize, 1), program.roots.len);
    try testing.expectEqual(@as(u32, 1), program.roots[0]);
    try testing.expectEqual(Types.PartKind.pass, program.parts[1].kind);
    try testing.expectEqual(@as(?u32, 0), program.findFragment("f"));
    try testing.expectEqual(@as(?u32, null), program.findFragment("post"));
    try testing.expectEqual(@as(?u32, null), program.findFragment("main"));

    const imports = program.parts[1].imports;
    try testing.expectEqual(@as(usize, 1), imports.len);
    try testing.expectEqualStrings("f", imports[0].name);
    try testing.expectEqualStrings("f", spanText(source, imports[0].span));
}

test "pass :file is a data-file list and is ignored, even when malformed (D19)" {
    const source =
        \\(pass :name p :code "fn fs() {}" :file ["data.bin"])
        \\(pass :name q :code "fn fs2() {}" :file 42)
    ;
    var result = try extract.extract(testing.allocator, document_path, source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(Types.Status.ok, result.status);
    const program = &result.program.?;
    try testing.expectEqual(@as(usize, 2), program.parts.len);
    for (program.parts) |part| {
        switch (part.origin) {
            .inline_code => {},
            else => return error.TestExpectedInlineOrigin,
        }
    }
}

test "pass without :code is an invalid root graph error (D19)" {
    const source =
        \\(pass :name p :file ["data.bin"])
    ;
    var result = try extract.extract(testing.allocator, document_path, source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(Types.Status.invalid, result.status);
    try testing.expectEqual(@as(?Types.Program, null), result.program);
    try expectDiagnostic(&result, .missing_pass_code);
}

test "exactly one source key: both and neither are invalid (D20, D21)" {
    const cases = [_]struct {
        source: []const u8,
        code: Types.DiagnosticCode,
    }{
        .{ .source = "(wgsl :name f :code \"x\" :file \"a.wgsl\")", .code = .both_code_and_file },
        .{ .source = "(shader-module :name m :code \"x\" :file \"a.wgsl\")", .code = .both_code_and_file },
        .{ .source = "(wgsl :name f)", .code = .missing_source },
        .{ .source = "(shader-module :name m)", .code = .missing_source },
    };
    for (cases) |case| {
        var result = try extract.extract(testing.allocator, document_path, case.source);
        defer result.deinit(testing.allocator);
        try testing.expectEqual(Types.Status.invalid, result.status);
        try testing.expectEqual(@as(?Types.Program, null), result.program);
        try expectDiagnostic(&result, case.code);
    }
}

test ":requires records the WGSL name and its SJON span (D22)" {
    const source =
        \\(wgsl :name fbm :code "fn f() {}" :requires [noise])
    ;
    var result = try extract.extract(testing.allocator, document_path, source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(Types.Status.ok, result.status);
    const program = &result.program.?;
    const requires = program.parts[0].requires;
    try testing.expectEqual(@as(usize, 1), requires.len);
    try testing.expectEqualStrings("noise", requires[0].name);
    try testing.expectEqualStrings("noise", spanText(source, requires[0].span));
    try testing.expect(program.parts[0].requires_span != null);
}

test ":imports preserves written order and element spans" {
    const source =
        \\(wgsl :name a :code "fn a() {}")
        \\(wgsl :name b :code "fn b() {}")
        \\(shader-module :name root :file "root.wgsl" :imports [b a])
    ;
    var result = try extract.extract(testing.allocator, document_path, source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(Types.Status.ok, result.status);
    const imports = result.program.?.parts[2].imports;
    try testing.expectEqual(@as(usize, 2), imports.len);
    try testing.expectEqualStrings("b", imports[0].name);
    try testing.expectEqualStrings("a", imports[1].name);
    try testing.expectEqualStrings("b", spanText(source, imports[0].span));
    try testing.expectEqualStrings("a", spanText(source, imports[1].span));
}

test "unknown :imports name is a root diagnostic; the rest of the program survives (D23)" {
    const source =
        \\(wgsl :name f :code "fn f() {}")
        \\(shader-module :name root :code "fn fs() {}" :imports [f ghost])
    ;
    var result = try extract.extract(testing.allocator, document_path, source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(Types.Status.ok, result.status);
    const program = &result.program.?;
    try testing.expectEqual(@as(usize, 2), program.parts.len);
    try testing.expectEqual(@as(usize, 1), program.diagnostics.len);
    const diag = program.diagnostics[0];
    try testing.expectEqual(Types.DiagnosticCode.unknown_import, diag.code);
    try testing.expectEqual(@as(?u32, 1), diag.part_index);
    try testing.expectEqualStrings("ghost", spanText(source, diag.span));
    try testing.expect(std.mem.indexOf(u8, diag.message, "ghost") != null);
}

test "duplicate part names fail the whole program, never last-wins (D15)" {
    const source =
        \\(wgsl :name dup :code "fn first() {}")
        \\(wgsl :name dup :code "fn second() {}")
    ;
    var result = try extract.extract(testing.allocator, document_path, source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(Types.Status.invalid, result.status);
    try testing.expectEqual(@as(?Types.Program, null), result.program);
    try expectDiagnostic(&result, .duplicate_part_name);
    for (result.diagnostics) |d| {
        if (d.code == .duplicate_part_name) {
            try testing.expectEqual(@as(?u32, 1), d.part_index);
            try testing.expectEqualStrings("dup", spanText(source, d.span));
        }
    }
}

test "part names share one program namespace: a root cannot reuse a fragment name" {
    const source =
        \\(wgsl :name same :code "fn f() {}")
        \\(shader-module :name same :code "fn fs() {}")
    ;
    var result = try extract.extract(testing.allocator, document_path, source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(Types.Status.invalid, result.status);
    try testing.expectEqual(@as(?Types.Program, null), result.program);
    try expectDiagnostic(&result, .duplicate_part_name);
}

test "fragment lookup is scoped to one Program" {
    var a = try extract.extract(testing.allocator, "/project/a.sjon", "(wgsl :name onlyA :code \"fn a() {}\")");
    defer a.deinit(testing.allocator);
    var b = try extract.extract(testing.allocator, "/project/b.sjon", "(wgsl :name onlyB :code \"fn b() {}\")");
    defer b.deinit(testing.allocator);

    try testing.expectEqual(@as(?u32, 0), a.program.?.findFragment("onlyA"));
    try testing.expectEqual(@as(?u32, null), a.program.?.findFragment("onlyB"));
    try testing.expectEqual(@as(?u32, 0), b.program.?.findFragment("onlyB"));
    try testing.expectEqual(@as(?u32, null), b.program.?.findFragment("onlyA"));
}

test "malformed forms produce located graph errors, never guessed fields" {
    const cases = [_]struct {
        source: []const u8,
        code: Types.DiagnosticCode,
    }{
        .{ .source = "(wgsl :code \"x\")", .code = .missing_name },
        .{ .source = "(wgsl :name \"f\" :code \"x\")", .code = .invalid_name },
        .{ .source = "(wgsl :name f :code 42)", .code = .invalid_source },
        .{ .source = "(wgsl :name f :file 42)", .code = .invalid_source },
        .{ .source = "(wgsl :name f :file \"\")", .code = .invalid_source },
        .{ .source = "(wgsl :name f :code \"x\" :imports f)", .code = .invalid_imports },
        .{ .source = "(wgsl :name f :code \"x\" :imports [f 42])", .code = .non_symbol_import },
        .{ .source = "(wgsl :name f :code \"x\" :requires noise)", .code = .invalid_requires },
        .{ .source = "(wgsl :name f :code \"x\" :requires [noise 42])", .code = .non_symbol_requires },
        .{ .source = "(wgsl :name :code \"x\")", .code = .malformed_form },
        .{ .source = "(wgsl :name f :name g :code \"x\")", .code = .duplicate_key },
        .{ .source = "(shader-module :name m :imports [])", .code = .missing_source },
    };
    for (cases) |case| {
        var result = try extract.extract(testing.allocator, document_path, case.source);
        defer result.deinit(testing.allocator);
        try testing.expectEqual(Types.Status.invalid, result.status);
        try testing.expectEqual(@as(?Types.Program, null), result.program);
        try expectDiagnostic(&result, case.code);
        for (result.diagnostics) |d| try testing.expect(d.span.end >= d.span.start);
    }
}

test "an (import …) document is unsupported and builds no partial graph (D36)" {
    const source =
        \\(import :file "base.sjon")
        \\(wgsl :name f :code "fn f() {}")
    ;
    var result = try extract.extract(testing.allocator, document_path, source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(Types.Status.unsupported_document_import, result.status);
    try testing.expectEqual(@as(?Types.Program, null), result.program);
    try expectDiagnostic(&result, .unsupported_document_import);
}

test "SJON parse errors never yield a typed graph (D27)" {
    const source =
        \\(wgsl :name f :code "fn f() {}"
    ;
    var result = try extract.extract(testing.allocator, document_path, source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(Types.Status.invalid, result.status);
    try testing.expectEqual(@as(?Types.Program, null), result.program);
    try expectDiagnostic(&result, .sjon_syntax_error);
    try testing.expect(result.diagnostics.len > 0);
}

test "an over-size document is a result, never a sjon.parse assert" {
    const source =
        \\(wgsl :name f :code "fn f() {}")
    ;
    var result = try extract.extractWithOptions(testing.allocator, document_path, source, .{
        .max_document_bytes = 8,
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqual(Types.Status.invalid, result.status);
    try testing.expectEqual(@as(?Types.Program, null), result.program);
    try expectDiagnostic(&result, .document_too_large);
}

test "the walk is top-level-only and ignores unrelated heads" {
    const source =
        \\(data :name defaults :float32 [1 2])
        \\(wrapper (wgsl :name nested :code "fn n() {}"))
        \\(texture :name t :size 16)
        \\(wgsl :name top :code "fn t() {}")
    ;
    var result = try extract.extract(testing.allocator, document_path, source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(Types.Status.ok, result.status);
    const program = &result.program.?;
    try testing.expectEqual(@as(usize, 1), program.parts.len);
    try testing.expectEqualStrings("top", program.parts[0].name);
}
