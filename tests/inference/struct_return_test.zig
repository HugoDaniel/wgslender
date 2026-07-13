//! Anonymous-struct return types — WGSL §17.5.33 (frexp),
//! §17.5.49 (modf), §17.9.7 (atomicCompareExchangeWeak).
//!
//! Before this pass those three builtins returned `null` from
//! `inferCustomBuiltin`, which broke member access on their result
//! and prevented downstream type inference. Now the validator
//! synthesizes (and caches) the spec-defined struct types so
//! `frexp(x).fract`, `modf(x).whole`, and
//! `atomicCompareExchangeWeak(&p, 0, 1).exchanged` all type-check.

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
        std.debug.print("let '{s}' missing; diagnostics:\n", .{name});
        for (r.diagnostics.items()) |d| std.debug.print("  [{s}] {s}: {s}\n", .{ d.code, d.severity.string(), d.message });
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqualStrings(expected, t.string());
}

// --- frexp (§17.5.33) ---

test "§17.5.33: frexp(f32) returns __frexp_result_f32" {
    var r = try analyze("fn f() { let x = frexp(1.5f); }");
    defer r.deinit();
    try expectLetString(&r, "x", "__frexp_result_f32");
}

test "§17.5.33: frexp(f32).fract → f32" {
    var r = try analyze("fn f() { let r = frexp(1.5f); let m = r.fract; }");
    defer r.deinit();
    try expectLetString(&r, "m", "f32");
}

test "§17.5.33: frexp(f32).exp → i32" {
    var r = try analyze("fn f() { let r = frexp(1.5f); let e = r.exp; }");
    defer r.deinit();
    try expectLetString(&r, "e", "i32");
}

test "§17.5.33: frexp(vec3<f32>).fract → vec3<f32>" {
    var r = try analyze("fn f() { let r = frexp(vec3f(1.0, 2.0, 3.0)); let m = r.fract; }");
    defer r.deinit();
    try expectLetString(&r, "m", "vec3<f32>");
}

test "§17.5.33: frexp(vec3<f32>).exp → vec3<i32>" {
    var r = try analyze("fn f() { let r = frexp(vec3f(1.0, 2.0, 3.0)); let e = r.exp; }");
    defer r.deinit();
    try expectLetString(&r, "e", "vec3<i32>");
}

test "§17.5.33: repeated frexp calls reuse the same cached struct" {
    // The validator caches `__frexp_result_f32` so two call sites share
    // the same struct pointer — we observe this via member access typing.
    var r = try analyze(
        \\fn f() {
        \\  let a = frexp(1.5f);
        \\  let b = frexp(2.5f);
        \\  let ax = a.fract;
        \\  let bx = b.fract;
        \\}
    );
    defer r.deinit();
    try expectLetString(&r, "ax", "f32");
    try expectLetString(&r, "bx", "f32");
}

// --- modf (§17.5.49) ---

test "§17.5.49: modf(f32) returns __modf_result_f32" {
    var r = try analyze("fn f() { let x = modf(1.5f); }");
    defer r.deinit();
    try expectLetString(&r, "x", "__modf_result_f32");
}

test "§17.5.49: modf(f32).fract → f32" {
    var r = try analyze("fn f() { let r = modf(1.5f); let m = r.fract; }");
    defer r.deinit();
    try expectLetString(&r, "m", "f32");
}

test "§17.5.49: modf(f32).whole → f32" {
    var r = try analyze("fn f() { let r = modf(1.5f); let w = r.whole; }");
    defer r.deinit();
    try expectLetString(&r, "w", "f32");
}

test "§17.5.49: modf(vec2<f32>).fract → vec2<f32>" {
    var r = try analyze("fn f() { let r = modf(vec2f(1.5, 2.5)); let m = r.fract; }");
    defer r.deinit();
    try expectLetString(&r, "m", "vec2<f32>");
}

// --- atomicCompareExchangeWeak (§17.9.7) ---

test "§17.9.7: atomicCompareExchangeWeak on atomic<i32>" {
    var r = try analyze(
        \\var<workgroup> w: atomic<i32>;
        \\fn f() { let x = atomicCompareExchangeWeak(&w, 0, 1); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "__atomic_compare_exchange_result_i32");
}

test "§17.9.7: .old_value field → underlying atomic scalar" {
    var r = try analyze(
        \\var<workgroup> w: atomic<i32>;
        \\fn f() {
        \\  let r = atomicCompareExchangeWeak(&w, 0, 1);
        \\  let v = r.old_value;
        \\}
    );
    defer r.deinit();
    try expectLetString(&r, "v", "i32");
}

test "§17.9.7: .exchanged field → bool" {
    var r = try analyze(
        \\var<workgroup> w: atomic<i32>;
        \\fn f() {
        \\  let r = atomicCompareExchangeWeak(&w, 0, 1);
        \\  let e = r.exchanged;
        \\}
    );
    defer r.deinit();
    try expectLetString(&r, "e", "bool");
}

test "§17.9.7: atomic<u32> variant" {
    var r = try analyze(
        \\var<workgroup> w: atomic<u32>;
        \\fn f() {
        \\  let r = atomicCompareExchangeWeak(&w, 0u, 1u);
        \\  let v = r.old_value;
        \\  let e = r.exchanged;
        \\}
    );
    defer r.deinit();
    try expectLetString(&r, "v", "u32");
    try expectLetString(&r, "e", "bool");
}
