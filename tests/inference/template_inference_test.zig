//! Template inference for vec/mat constructors — WGSL §14.462.
//!
//! Bare `vec2(...)` / `vec3(...)` / `vec4(...)` / `matCxR(...)` infer
//! their element type from the arguments; a suffixed constructor
//! (`vec2f`, `mat3x3f`, etc.) or a templated one (`vec2<i32>(...)`)
//! pins the element explicitly. This file pins both paths plus the
//! cross-product unification cases (abstract → concrete promotion,
//! abstract stays abstract when all args are abstract).

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
        std.debug.print("let '{s}' has no recorded type; diagnostics follow:\n", .{name});
        for (r.diagnostics.items()) |d| {
            std.debug.print("  [{s}] {s}: {s}\n", .{ d.code, d.severity.string(), d.message });
        }
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqualStrings(expected, t.string());
}

// --- Bare vec: element inference ---

test "§14.462: bare vec2(1, 2) infers vec2<i32> at let" {
    var r = try analyze("fn f() { let a = vec2(1, 2); }");
    defer r.deinit();
    try expectLetString(&r, "a", "vec2<i32>");
}

test "§14.462: bare vec3(1.0, 2.0, 3.0) infers vec3<f32> at let" {
    var r = try analyze("fn f() { let a = vec3(1.0, 2.0, 3.0); }");
    defer r.deinit();
    try expectLetString(&r, "a", "vec3<f32>");
}

test "§14.462: bare vec4(1u, 2u, 3u, 4u) infers vec4<u32>" {
    var r = try analyze("fn f() { let a = vec4(1u, 2u, 3u, 4u); }");
    defer r.deinit();
    try expectLetString(&r, "a", "vec4<u32>");
}

test "§14.462: bare vec2(1, 2u) — one u32 forces vec2<u32>" {
    var r = try analyze("fn f() { let a = vec2(1, 2u); }");
    defer r.deinit();
    try expectLetString(&r, "a", "vec2<u32>");
}

test "§14.462: bare vec3(1.0, 2, 3) — one float forces vec3<f32>" {
    var r = try analyze("fn f() { let a = vec3(1.0, 2, 3); }");
    defer r.deinit();
    try expectLetString(&r, "a", "vec3<f32>");
}

test "§14.462: nested vec3(vec2(1.0, 2.0), 3.0) → vec3<f32>" {
    var r = try analyze("fn f() { let a = vec3(vec2(1.0, 2.0), 3.0); }");
    defer r.deinit();
    try expectLetString(&r, "a", "vec3<f32>");
}

test "§14.462: nested vec4(vec3(1, 2, 3), 4) — all-abstract-int" {
    var r = try analyze("fn f() { let a = vec4(vec3(1, 2, 3), 4); }");
    defer r.deinit();
    try expectLetString(&r, "a", "vec4<i32>");
}

// --- Suffixed vec: element pinned explicitly ---

test "§14.462: vec2f(1, 2) → vec2<f32> (args convert abstract→f32)" {
    var r = try analyze("fn f() { let a = vec2f(1, 2); }");
    defer r.deinit();
    try expectLetString(&r, "a", "vec2<f32>");
}

test "§14.462: vec3i(1, 2, 3) → vec3<i32>" {
    var r = try analyze("fn f() { let a = vec3i(1, 2, 3); }");
    defer r.deinit();
    try expectLetString(&r, "a", "vec3<i32>");
}

test "§14.462: vec4u(1, 2, 3, 4) → vec4<u32>" {
    var r = try analyze("fn f() { let a = vec4u(1, 2, 3, 4); }");
    defer r.deinit();
    try expectLetString(&r, "a", "vec4<u32>");
}

// --- Templated vec: element pinned explicitly ---

test "§14.462: vec2<i32>(3, 4) → vec2<i32>" {
    var r = try analyze("fn f() { let a = vec2<i32>(3, 4); }");
    defer r.deinit();
    try expectLetString(&r, "a", "vec2<i32>");
}

test "§14.462: vec3<f32>(1, 2, 3) → vec3<f32>" {
    var r = try analyze("fn f() { let a = vec3<f32>(1, 2, 3); }");
    defer r.deinit();
    try expectLetString(&r, "a", "vec3<f32>");
}

// --- Vec splat ---

test "§14.462: vec3<f32>(1.0f) splat → vec3<f32>" {
    var r = try analyze("fn f() { let a = vec3<f32>(1.0f); }");
    defer r.deinit();
    try expectLetString(&r, "a", "vec3<f32>");
}

// --- Matrix element inference ---

test "§14.462: bare mat2x2(…) all-f32 → mat2x2<f32>" {
    var r = try analyze("fn f() { let a = mat2x2(1.0f, 2.0f, 3.0f, 4.0f); }");
    defer r.deinit();
    try expectLetString(&r, "a", "mat2x2<f32>");
}

test "§14.462: bare mat3x3(…) abstract-float args → mat3x3<f32>" {
    var r = try analyze("fn f() { let a = mat3x3(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0); }");
    defer r.deinit();
    try expectLetString(&r, "a", "mat3x3<f32>");
}

test "§14.462: mat2x3f(…) explicit → mat2x3<f32>" {
    var r = try analyze("fn f() { let a = mat2x3f(1.0, 2.0, 3.0, 4.0, 5.0, 6.0); }");
    defer r.deinit();
    try expectLetString(&r, "a", "mat2x3<f32>");
}

// --- Min/max with inferred vec args: regression pin ---

test "§14.462 regression: min(vec2(1,2), vec2<i32>(3,4)) → vec2<i32>" {
    var r = try analyze("fn f() { let x = min(vec2(1, 2), vec2<i32>(3, 4)); }");
    defer r.deinit();
    try expectLetString(&r, "x", "vec2<i32>");
}

test "§14.462 regression: min(vec3(1.0, 2.0, 3.0), vec3f(4.0, 5.0, 6.0)) → vec3<f32>" {
    var r = try analyze("fn f() { let x = min(vec3(1.0, 2.0, 3.0), vec3f(4.0, 5.0, 6.0)); }");
    defer r.deinit();
    try expectLetString(&r, "x", "vec3<f32>");
}

// --- Constructor identity on vectors ---

test "§14.462: vec2<f32>(vec2f(1.0)) → vec2<f32>" {
    var r = try analyze("fn f() { let a = vec2<f32>(vec2f(1.0)); }");
    defer r.deinit();
    try expectLetString(&r, "a", "vec2<f32>");
}
