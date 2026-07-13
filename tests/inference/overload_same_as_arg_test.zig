//! Return-type unification for builtins with the `same_as_arg` pattern.
//!
//! Before: `min(5, 0u)` → AbstractInt (demoted to i32 by let-default).
//! After:  `min(5, 0u)` → u32 (second arg forces the concrete promotion).
//!
//! Spec: WGSL §8.7 overload resolution prescribes picking the lowest-rank
//! feasible overload. For min/max/clamp/mix/select/step/smoothstep/fma
//! and the reflect/refract/faceForward family, the return type must be
//! the unified type across the numeric arguments, never blindly the
//! first argument's type.

const std = @import("std");
const wgslender = @import("wgslender");

fn analyze(src: [:0]const u8) !wgslender.Validator.AnalysisResult {
    return wgslender.analyzeWithOptions(std.testing.allocator, src, .{});
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

fn expectLetString(r: *const wgslender.Validator.AnalysisResult, name: []const u8, expected: []const u8) !void {
    const t = letType(r, name) orelse {
        std.debug.print("let '{s}' has no recorded type\n", .{name});
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqualStrings(expected, t.string());
}

// --- min / max ---

test "same_as_arg: min(abs, u32) → u32" {
    var r = try analyze("fn f() { let x = min(5, 0u); }");
    defer r.deinit();
    try expectLetString(&r, "x", "u32");
}

test "same_as_arg: min(u32, abs) → u32" {
    var r = try analyze("fn f() { let x = min(0u, 5); }");
    defer r.deinit();
    try expectLetString(&r, "x", "u32");
}

test "same_as_arg: min(abs, abs-float) → abstract-float → f32 at let" {
    var r = try analyze("fn f() { let x = min(0, 1.0); }");
    defer r.deinit();
    try expectLetString(&r, "x", "f32");
}

test "same_as_arg: max(f32, abs) → f32" {
    var r = try analyze("fn f() { let x = max(1.5f, 0); }");
    defer r.deinit();
    try expectLetString(&r, "x", "f32");
}

test "same_as_arg: min all-abstract stays abstract then demotes to i32 at let" {
    var r = try analyze("fn f() { let x = min(5, 10); }");
    defer r.deinit();
    try expectLetString(&r, "x", "i32");
}

// Per WGSL §6.6 / §6.7, `const x = min(5, 10)` at module scope preserves
// AbstractInt so downstream contexts can pick the best concretization.
// The AbstractHandling split wired this in — function-scope `const`
// still demotes via `Types.concreteType` (§15).
test "same_as_arg: min all-abstract at module-scope const preserves abstract-int" {
    var r = try analyze("const x = min(5, 10);");
    defer r.deinit();
    const mod = r.module orelse return error.TestUnexpectedResult;
    var found = false;
    for (mod.symbols.items, 0..) |sym, idx| {
        if (sym.kind != .@"const") continue;
        if (!std.mem.eql(u8, sym.original_name, "x")) continue;
        const t = r.symbol_types.get(@intCast(idx)) orelse continue;
        try std.testing.expectEqualStrings("abstract-int", t.string());
        found = true;
    }
    try std.testing.expect(found);
}

// --- clamp (3 args) ---

test "same_as_arg: clamp(abs, f32, abs) → f32" {
    var r = try analyze("fn f() { let x = clamp(0, 1f, 1); }");
    defer r.deinit();
    try expectLetString(&r, "x", "f32");
}

test "same_as_arg: clamp(abs, abs, u32) → u32" {
    var r = try analyze("fn f() { let x = clamp(5, 0, 1u); }");
    defer r.deinit();
    try expectLetString(&r, "x", "u32");
}

test "same_as_arg: clamp all-abstract → i32 at let" {
    var r = try analyze("fn f() { let x = clamp(1, 0, 10); }");
    defer r.deinit();
    try expectLetString(&r, "x", "i32");
}

// --- mix (scalar blend is allowed on vector forms, but all-scalar is common) ---

test "same_as_arg: mix(abs-float, f32, abs-float) → f32" {
    var r = try analyze("fn f() { let x = mix(0.0, 1.0f, 0.5); }");
    defer r.deinit();
    try expectLetString(&r, "x", "f32");
}

// --- select: first two args determine result, third is bool ---

test "same_as_arg: select(i32, i32, bool) → i32" {
    var r = try analyze("fn f() { let x = select(1i, 2i, true); }");
    defer r.deinit();
    try expectLetString(&r, "x", "i32");
}

test "same_as_arg: select(abs, abs, bool) → i32 at let" {
    var r = try analyze("fn f() { let x = select(1, 2, true); }");
    defer r.deinit();
    try expectLetString(&r, "x", "i32");
}

test "same_as_arg: select(abs, f32, bool) → f32 — numeric args unified despite bool trailing" {
    var r = try analyze("fn f() { let x = select(0, 1.5f, true); }");
    defer r.deinit();
    try expectLetString(&r, "x", "f32");
}

// --- refract: (vec I, vec N, scalar eta) — scalar trail must not derail unification ---

test "same_as_arg: refract(vec3f, vec3f, f32) → vec3<f32>" {
    var r = try analyze("fn f() { let x = refract(vec3f(1.0), vec3f(0.0, 0.0, 1.0), 1.5f); }");
    defer r.deinit();
    try expectLetString(&r, "x", "vec3<f32>");
}

// --- Vector arg types ---

test "same_as_arg: min(vec<i32>, vec<i32>) → vec<i32>" {
    var r = try analyze("fn f() { let x = min(vec2<i32>(1, 2), vec2<i32>(3, 4)); }");
    defer r.deinit();
    try expectLetString(&r, "x", "vec2<i32>");
}

test "same_as_arg: min(vec<f32>, vec<f32>) → vec<f32>" {
    var r = try analyze("fn f() { let x = min(vec3<f32>(1.0), vec3<f32>(2.0)); }");
    defer r.deinit();
    try expectLetString(&r, "x", "vec3<f32>");
}

// --- Single-arg builtins: unification no-op ---

test "same_as_arg: abs(-5) at module-scope const preserves abstract-int" {
    var r = try analyze("const x = abs(-5);");
    defer r.deinit();
    const mod = r.module orelse return error.TestUnexpectedResult;
    var found = false;
    for (mod.symbols.items, 0..) |sym, idx| {
        if (sym.kind != .@"const") continue;
        if (!std.mem.eql(u8, sym.original_name, "x")) continue;
        const t = r.symbol_types.get(@intCast(idx)) orelse continue;
        try std.testing.expectEqualStrings("abstract-int", t.string());
        found = true;
    }
    try std.testing.expect(found);
}

test "same_as_arg: sin(1.0) at module-scope const preserves abstract-float" {
    var r = try analyze("const x = sin(1.0);");
    defer r.deinit();
    const mod = r.module orelse return error.TestUnexpectedResult;
    var found = false;
    for (mod.symbols.items, 0..) |sym, idx| {
        if (sym.kind != .@"const") continue;
        if (!std.mem.eql(u8, sym.original_name, "x")) continue;
        const t = r.symbol_types.get(@intCast(idx)) orelse continue;
        try std.testing.expectEqualStrings("abstract-float", t.string());
        found = true;
    }
    try std.testing.expect(found);
}

test "same_as_arg: sin(1.0f) at let → f32" {
    var r = try analyze("fn f() { let x = sin(1.0f); }");
    defer r.deinit();
    try expectLetString(&r, "x", "f32");
}

// --- step / smoothstep ---

test "same_as_arg: step(abs, f32) → f32" {
    var r = try analyze("fn f() { let x = step(0.5, 1.0f); }");
    defer r.deinit();
    try expectLetString(&r, "x", "f32");
}

test "same_as_arg: smoothstep(abs, f32, abs) → f32" {
    var r = try analyze("fn f() { let x = smoothstep(0.0, 1.0f, 0.5); }");
    defer r.deinit();
    try expectLetString(&r, "x", "f32");
}

// --- fma ---

test "same_as_arg: fma(abs, abs, f32) → f32" {
    var r = try analyze("fn f() { let x = fma(1.0, 2.0, 3.0f); }");
    defer r.deinit();
    try expectLetString(&r, "x", "f32");
}
