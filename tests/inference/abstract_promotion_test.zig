//! Abstract-numeric promotion and demotion — WGSL §8.2 / §15
//! (Value conversion) and decl-site concretization for let/const/var.
//!
//! Pins the tree-shape interactions:
//!   • `let x = 1.0 + 2 + 3` → all abstract-float, demotes to f32
//!     at the let-binding.
//!   • `let x = 1u + (1 + 2)` → u32 (concrete wins over abstract
//!     siblings).
//!   • `var x = 1` → concrete i32 (var always concretizes).
//!   • unary `-` preserves abstractness.
//!   • Mixed-signedness at arithmetic sites stays rejected.

const std = @import("std");
const wgslender = @import("wgslender");

fn analyze(src: [:0]const u8) !wgslender.Validator.AnalysisResult {
    return wgslender.analyzeWithOptions(std.testing.allocator, src, .{});
}

fn validate(src: [:0]const u8) !wgslender.Validator.Result {
    return wgslender.validateWithOptions(std.testing.allocator, src, .{});
}

fn anyError(r: wgslender.Validator.Result) bool {
    for (r.diagnostics.items()) |d| {
        if (d.severity == .@"error") return true;
    }
    return false;
}

fn hasErrorContaining(r: wgslender.Validator.Result, needle: []const u8) bool {
    for (r.diagnostics.items()) |d| {
        if (d.severity != .@"error") continue;
        if (std.mem.indexOf(u8, d.message, needle) != null) return true;
    }
    return false;
}

fn dump(label: []const u8, r: wgslender.Validator.Result) void {
    std.debug.print("\n{s}:\n", .{label});
    for (r.diagnostics.items()) |d| {
        std.debug.print(
            "  [{s}] {s}: {s}\n",
            .{ d.code, d.severity.string(), d.message },
        );
    }
}

fn dumpAnalysis(label: []const u8, r: wgslender.Validator.AnalysisResult) void {
    std.debug.print("\n{s}:\n", .{label});
    for (r.diagnostics.items()) |d| {
        std.debug.print(
            "  [{s}] {s}: {s}\n",
            .{ d.code, d.severity.string(), d.message },
        );
    }
}

fn letType(r: *const wgslender.Validator.AnalysisResult, name: []const u8) ?wgslender.Types.Type {
    const mod = r.module orelse return null;
    for (mod.symbols.items, 0..) |sym, idx| {
        if (sym.kind != .let) continue;
        if (!std.mem.eql(u8, sym.original_name, name)) continue;
        return r.symbol_types.get(@intCast(idx));
    }
    return null;
}

fn varType(r: *const wgslender.Validator.AnalysisResult, name: []const u8) ?wgslender.Types.Type {
    const mod = r.module orelse return null;
    for (mod.symbols.items, 0..) |sym, idx| {
        if (sym.kind != .@"var") continue;
        if (!std.mem.eql(u8, sym.original_name, name)) continue;
        return r.symbol_types.get(@intCast(idx));
    }
    return null;
}

fn constType(r: *const wgslender.Validator.AnalysisResult, name: []const u8) ?wgslender.Types.Type {
    const mod = r.module orelse return null;
    for (mod.symbols.items, 0..) |sym, idx| {
        if (sym.kind != .@"const") continue;
        if (!std.mem.eql(u8, sym.original_name, name)) continue;
        return r.symbol_types.get(@intCast(idx));
    }
    return null;
}

fn expectSymbolType(
    lookup: fn (*const wgslender.Validator.AnalysisResult, []const u8) ?wgslender.Types.Type,
    r: *const wgslender.Validator.AnalysisResult,
    name: []const u8,
    expected: []const u8,
) !void {
    const t = lookup(r, name) orelse {
        std.debug.print("symbol '{s}' missing; diagnostics:\n", .{name});
        for (r.diagnostics.items()) |d| std.debug.print("  [{s}] {s}: {s}\n", .{ d.code, d.severity.string(), d.message });
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqualStrings(expected, t.string());
}

// -------------------------------------------------------------------------
// `let x = ...;` — abstract types concretize only if the expression is
// concrete. `let` can preserve abstractness in principle, but the spec
// demotes at the binding site per §15 — our validator concretizes to
// i32/f32 today. Lock that in.
// -------------------------------------------------------------------------

test "§15: let x = 1; → i32 (demote AbstractInt to default)" {
    var r = try analyze("fn f() { let x = 1; }");
    defer r.deinit(std.testing.allocator);
    try expectSymbolType(letType, &r, "x", "i32");
}

test "§15: let x = 1.0; → f32" {
    var r = try analyze("fn f() { let x = 1.0; }");
    defer r.deinit(std.testing.allocator);
    try expectSymbolType(letType, &r, "x", "f32");
}

test "§15: let x = 1u; → u32" {
    var r = try analyze("fn f() { let x = 1u; }");
    defer r.deinit(std.testing.allocator);
    try expectSymbolType(letType, &r, "x", "u32");
}

test "§15: let x = 1i; → i32" {
    var r = try analyze("fn f() { let x = 1i; }");
    defer r.deinit(std.testing.allocator);
    try expectSymbolType(letType, &r, "x", "i32");
}

// -------------------------------------------------------------------------
// Tree-shape binop cascades — concrete anchors pull abstract siblings.
// -------------------------------------------------------------------------

test "§8.2: let x = 1u + 2; → u32 (abstract RHS concretizes)" {
    var r = try analyze("fn f() { let x = 1u + 2; }");
    defer r.deinit(std.testing.allocator);
    try expectSymbolType(letType, &r, "x", "u32");
}

test "§8.2: let x = 1 + 2u; → u32" {
    var r = try analyze("fn f() { let x = 1 + 2u; }");
    defer r.deinit(std.testing.allocator);
    try expectSymbolType(letType, &r, "x", "u32");
}

test "§8.2: let x = 1.0 + 2; → f32 (abstract-int → abstract-float)" {
    var r = try analyze("fn f() { let x = 1.0 + 2; }");
    defer r.deinit(std.testing.allocator);
    try expectSymbolType(letType, &r, "x", "f32");
}

test "§8.2: let x = 1.0f + 2; → f32" {
    var r = try analyze("fn f() { let x = 1.0f + 2; }");
    defer r.deinit(std.testing.allocator);
    try expectSymbolType(letType, &r, "x", "f32");
}

test "§8.2: let x = 1 + 2 + 3; → i32 (all abstract, demotes to default)" {
    var r = try analyze("fn f() { let x = 1 + 2 + 3; }");
    defer r.deinit(std.testing.allocator);
    try expectSymbolType(letType, &r, "x", "i32");
}

test "§8.2: let x = 1.0 + 2 + 3; → f32 (tree-cascade)" {
    var r = try analyze("fn f() { let x = 1.0 + 2 + 3; }");
    defer r.deinit(std.testing.allocator);
    try expectSymbolType(letType, &r, "x", "f32");
}

test "§8.2: let x = 1u + (1 + 2); → u32 (paren subtree concretizes)" {
    var r = try analyze("fn f() { let x = 1u + (1 + 2); }");
    defer r.deinit(std.testing.allocator);
    try expectSymbolType(letType, &r, "x", "u32");
}

test "§8.2: let x = 1f + ((2 + 3) + 4); → f32" {
    var r = try analyze("fn f() { let x = 1f + ((2 + 3) + 4); }");
    defer r.deinit(std.testing.allocator);
    try expectSymbolType(letType, &r, "x", "f32");
}

// -------------------------------------------------------------------------
// `var` always concretizes (may not carry abstract).
// -------------------------------------------------------------------------

test "§6.8: var x = 1; → i32" {
    var r = try analyze("fn f() { var x = 1; }");
    defer r.deinit(std.testing.allocator);
    try expectSymbolType(varType, &r, "x", "i32");
}

test "§6.8: var x = 1.0; → f32" {
    var r = try analyze("fn f() { var x = 1.0; }");
    defer r.deinit(std.testing.allocator);
    try expectSymbolType(varType, &r, "x", "f32");
}

test "§6.8: var x = 1u + 2; → u32" {
    var r = try analyze("fn f() { var x = 1u + 2; }");
    defer r.deinit(std.testing.allocator);
    try expectSymbolType(varType, &r, "x", "u32");
}

// -------------------------------------------------------------------------
// `const` at module scope — retains abstract typing per §6.6 so downstream
// contexts can pick the best concretization (e.g. the same `const` can feed
// both `f32` and `f16` slots). Function-scope `const` still demotes per §15.
// -------------------------------------------------------------------------

test "§6.6: const MY_VAL = 1; preserves abstract-int" {
    try validMustPass("const MY_VAL = 1; fn f() { let x = MY_VAL; }", "const abstract-int");
    var r = try analyze("const MY_VAL = 1;");
    defer r.deinit(std.testing.allocator);
    try expectSymbolType(constType, &r, "MY_VAL", "abstract-int");
}

test "§6.6: const PI = 3.14; preserves abstract-float" {
    try validMustPass("const PI = 3.14; fn f() { let x = PI; }", "const abstract-float");
    var r = try analyze("const PI = 3.14;");
    defer r.deinit(std.testing.allocator);
    try expectSymbolType(constType, &r, "PI", "abstract-float");
}

test "§15: function-scope const still demotes to concrete" {
    var r = try analyze("fn f() { const MY_VAL = 1; }");
    defer r.deinit(std.testing.allocator);
    try expectSymbolType(constType, &r, "MY_VAL", "i32");
}

// -------------------------------------------------------------------------
// Unary `-` preserves abstractness through the operand.
// -------------------------------------------------------------------------

test "§8.4: let x = -5; → i32 (unary on abstract-int)" {
    var r = try analyze("fn f() { let x = -5; }");
    defer r.deinit(std.testing.allocator);
    try expectSymbolType(letType, &r, "x", "i32");
}

test "§8.4: let x = -5.5; → f32" {
    var r = try analyze("fn f() { let x = -5.5; }");
    defer r.deinit(std.testing.allocator);
    try expectSymbolType(letType, &r, "x", "f32");
}

test "§8.4: let x = -5 + 1u; → u32 (unary result still participates)" {
    var r = try analyze("fn f() { let x = -5 + 1u; }");
    defer r.deinit(std.testing.allocator);
    // The spec requires the concrete u32 to pull the unary-negated
    // abstract int. We produce u32 even though literal -5u is illegal
    // (u32 has no sign); the cast happens at the op, not at the literal.
    try expectSymbolType(letType, &r, "x", "u32");
}

// -------------------------------------------------------------------------
// Vector abstract propagation.
// -------------------------------------------------------------------------

test "§14.5: let v = vec3f(1.0, 2.0, 3.0); → vec3<f32>" {
    var r = try analyze("fn f() { let v = vec3f(1.0, 2.0, 3.0); }");
    defer r.deinit(std.testing.allocator);
    try expectSymbolType(letType, &r, "v", "vec3<f32>");
}

test "§14.5: let v = vec3(1, 2, 3); → vec3<i32>" {
    var r = try analyze("fn f() { let v = vec3(1, 2, 3); }");
    defer r.deinit(std.testing.allocator);
    try expectSymbolType(letType, &r, "v", "vec3<i32>");
}

test "§14.5: let v = vec3(1.0, 2.0, 3.0); → vec3<f32>" {
    var r = try analyze("fn f() { let v = vec3(1.0, 2.0, 3.0); }");
    defer r.deinit(std.testing.allocator);
    try expectSymbolType(letType, &r, "v", "vec3<f32>");
}

test "§14.5: let v = vec2(1u, 2); → vec2<u32>" {
    var r = try analyze("fn f() { let v = vec2(1u, 2); }");
    defer r.deinit(std.testing.allocator);
    try expectSymbolType(letType, &r, "v", "vec2<u32>");
}

// -------------------------------------------------------------------------
// Abstract result is NOT allowed in runtime contexts — e.g. an abstract
// array length would be rejected (array counts must be const/override).
// We test the narrower property: `let v: i32 = 1u + 2;` compiles (because
// the target type drives the context), while `let v: i32 = 1.5;` rejects.
// -------------------------------------------------------------------------

test "§15: let v: i32 = 1u + 2; rejects (u32 not convertible to i32)" {
    var r = try validate("fn f() { let v: i32 = 1u + 2; }");
    defer r.deinit(std.testing.allocator);
    if (!anyError(r)) {
        dump("expected i32-assignment error", r);
        return error.TestUnexpectedResult;
    }
}

test "§15: let v: f32 = 1 + 2; accepts (both abstract → f32)" {
    try validMustPass("fn f() { let v: f32 = 1 + 2; }", "abstract-int → f32");
}

test "§15: let v: i32 = 1.5; rejects (float → int no auto-conversion)" {
    var r = try validate("fn f() { let v: i32 = 1.5; }");
    defer r.deinit(std.testing.allocator);
    if (!anyError(r)) {
        dump("expected i32-from-float error", r);
        return error.TestUnexpectedResult;
    }
}

// -------------------------------------------------------------------------
// Mixed-signedness rejection.
// -------------------------------------------------------------------------

test "§8.2: 1u + 1i rejected (mixed signedness)" {
    var r = try validate("fn f() { let x = 1u + 1i; }");
    defer r.deinit(std.testing.allocator);
    if (!anyError(r)) {
        dump("expected mixed-signedness error", r);
        return error.TestUnexpectedResult;
    }
}

test "§8.2: 1u - 1i rejected" {
    var r = try validate("fn f() { let x = 1u - 1i; }");
    defer r.deinit(std.testing.allocator);
    if (!anyError(r)) {
        dump("expected mixed-signedness error on sub", r);
        return error.TestUnexpectedResult;
    }
}

// helper used above
fn validMustPass(src: [:0]const u8, label: []const u8) !void {
    var r = try validate(src);
    defer r.deinit(std.testing.allocator);
    if (anyError(r)) {
        dump(label, r);
        return error.TestUnexpectedResult;
    }
}
