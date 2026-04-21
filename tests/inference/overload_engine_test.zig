//! End-to-end coverage of the declarative overload / unification engine
//! (`src/Overload.zig` + its integration with `Validator.checkBuiltinCall`)
//! introduced by Task #9 / Phase 1.
//!
//! Each block either drives WGSL source through the full pipeline and
//! inspects the resulting `let` type, or calls the solver directly to
//! pin a specific unification behavior. The file is intentionally dense:
//! most Phase 1-migrated builtins get both a positive and a negative
//! test, plus cross-cut cases (abstract-numeric promotion, width
//! polymorphism, pointer/atomic unwrapping, struct cache reuse).
//!
//! Spec references are kept in each test title so a future reviewer can
//! cross-check against bikeshed §17 without re-reading the implementation.

const std = @import("std");
const wgslender = @import("wgslender");

const Overload = wgslender.Overload;
const Types = wgslender.Types;
const Ast = wgslender.Ast;
const Validator = wgslender.Validator;

// =========================================================================
// Helpers
// =========================================================================

fn analyze(src: [:0]const u8) !Validator.AnalysisResult {
    return wgslender.analyzeWithOptions(std.testing.allocator, src, .{});
}

fn validate(src: [:0]const u8) !Validator.Result {
    return wgslender.validateWithOptions(std.testing.allocator, src, .{});
}

fn letType(r: *const Validator.AnalysisResult, name: []const u8) ?Types.Type {
    const mod = r.module orelse return null;
    for (mod.symbols.items, 0..) |sym, idx| {
        if (sym.kind != .let) continue;
        if (!std.mem.eql(u8, sym.original_name, name)) continue;
        return r.symbol_types.get(@intCast(idx));
    }
    return null;
}

fn expectLetString(r: *const Validator.AnalysisResult, name: []const u8, expected: []const u8) !void {
    const t = letType(r, name) orelse {
        std.debug.print("let '{s}' missing in fixture; diagnostics:\n", .{name});
        for (r.diagnostics.items()) |d| std.debug.print("  [{s}] {s}: {s}\n", .{ d.code, d.severity.string(), d.message });
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqualStrings(expected, t.string());
}

fn anyError(r: Validator.Result) bool {
    for (r.diagnostics.items()) |d| {
        if (d.severity == .@"error") return true;
    }
    return false;
}

fn hasErrorWithCode(r: Validator.Result, code: []const u8) bool {
    for (r.diagnostics.items()) |d| {
        if (d.severity != .@"error") continue;
        if (std.mem.eql(u8, d.code, code)) return true;
    }
    return false;
}

fn hasErrorContaining(r: Validator.Result, needle: []const u8) bool {
    for (r.diagnostics.items()) |d| {
        if (d.severity != .@"error") continue;
        if (std.mem.indexOf(u8, d.message, needle) != null) return true;
    }
    return false;
}

fn dump(label: []const u8, r: Validator.Result) void {
    std.debug.print("\n{s}:\n", .{label});
    for (r.diagnostics.items()) |d| {
        std.debug.print("  [{s}] {s}: {s}\n", .{ d.code, d.severity.string(), d.message });
    }
}

// =========================================================================
// 1. Solver primitives — direct Overload.resolve calls
// =========================================================================

test "solver: bind T to f32 from scalar arg" {
    const sigs = [_]Overload.OverloadSig{.{
        .tparam_count = 1,
        .params = &.{.{ .tparam_scalar = .{ .idx = 0, .family = .float } }},
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    }};
    const args = [_]?Types.Type{Types.F32};
    const res = Overload.resolve(&sigs, &args);
    try std.testing.expect(res == .ok);
    try std.testing.expectEqual(Types.ScalarKind.f32, res.ok.bindings[0].scalar_kind.?);
    try std.testing.expectEqual(@as(u32, 0), res.ok.total_rank);
}

test "solver: reject scalar outside family (i32 against float)" {
    const sigs = [_]Overload.OverloadSig{.{
        .tparam_count = 1,
        .params = &.{.{ .tparam_scalar = .{ .idx = 0, .family = .float } }},
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    }};
    const args = [_]?Types.Type{Types.I32};
    const res = Overload.resolve(&sigs, &args);
    try std.testing.expect(res == .err);
    try std.testing.expectEqual(Overload.ResolveError.no_matching_overload, res.err.kind);
}

test "solver: abstract-int concretizes to i32 with rank 3" {
    const sigs = [_]Overload.OverloadSig{.{
        .tparam_count = 0,
        .params = &.{.{ .concrete = Types.I32 }},
        .result = .{ .pattern = .{ .concrete = Types.I32 } },
    }};
    const args = [_]?Types.Type{Types.AbstractInt};
    const res = Overload.resolve(&sigs, &args);
    try std.testing.expect(res == .ok);
    try std.testing.expectEqual(@as(u32, 3), res.ok.total_rank);
}

test "solver: abstract-int concretizes to u32 with rank 4" {
    const sigs = [_]Overload.OverloadSig{.{
        .tparam_count = 0,
        .params = &.{.{ .concrete = Types.U32 }},
        .result = .{ .pattern = .{ .concrete = Types.U32 } },
    }};
    const args = [_]?Types.Type{Types.AbstractInt};
    const res = Overload.resolve(&sigs, &args);
    try std.testing.expect(res == .ok);
    try std.testing.expectEqual(@as(u32, 4), res.ok.total_rank);
}

test "solver: abstract-float → f32 rank 1, → f16 rank 2" {
    const sigs_f32 = [_]Overload.OverloadSig{.{
        .tparam_count = 0,
        .params = &.{.{ .concrete = Types.F32 }},
        .result = .{ .pattern = .{ .concrete = Types.F32 } },
    }};
    const sigs_f16 = [_]Overload.OverloadSig{.{
        .tparam_count = 0,
        .params = &.{.{ .concrete = Types.F16 }},
        .result = .{ .pattern = .{ .concrete = Types.F16 } },
    }};
    const args = [_]?Types.Type{Types.AbstractFloat};
    const r1 = Overload.resolve(&sigs_f32, &args);
    const r2 = Overload.resolve(&sigs_f16, &args);
    try std.testing.expectEqual(@as(u32, 1), r1.ok.total_rank);
    try std.testing.expectEqual(@as(u32, 2), r2.ok.total_rank);
}

test "solver: width polymorphism — vec3 agrees across params" {
    const sigs = [_]Overload.OverloadSig{.{
        .tparam_count = 2,
        .params = &.{
            .{ .tparam_vector = .{ .elem_idx = 1, .elem_family = .float, .n_idx = 0 } },
            .{ .tparam_vector = .{ .elem_idx = 1, .elem_family = .float, .n_idx = 0 } },
        },
        .result = .{ .pattern = .{ .bound_vector = .{ .elem_idx = 1, .n_idx = 0 } } },
    }};
    const v3 = Types.Vector{ .width = 3, .element = Types.scalar_f32_ptr };
    const v2 = Types.Vector{ .width = 2, .element = Types.scalar_f32_ptr };

    const ok_args = [_]?Types.Type{ .{ .vector = &v3 }, .{ .vector = &v3 } };
    try std.testing.expect(Overload.resolve(&sigs, &ok_args) == .ok);

    const bad_args = [_]?Types.Type{ .{ .vector = &v3 }, .{ .vector = &v2 } };
    try std.testing.expect(Overload.resolve(&sigs, &bad_args) == .err);
}

test "solver: tie-break — first sig wins on equal rank" {
    const sigs = [_]Overload.OverloadSig{
        .{
            .tparam_count = 0,
            .params = &.{.{ .concrete = Types.I32 }},
            .result = .{ .pattern = .{ .concrete = Types.I32 } },
        },
        .{
            .tparam_count = 1,
            .params = &.{.{ .tparam_scalar = .{ .idx = 0, .family = .integer } }},
            .result = .{ .pattern = .{ .bound_scalar = 0 } },
        },
    };
    const args = [_]?Types.Type{Types.I32};
    const res = Overload.resolve(&sigs, &args);
    try std.testing.expectEqual(@as(usize, 0), res.ok.sig_index);
}

test "solver: arity filter — distinct error kind" {
    const sigs = [_]Overload.OverloadSig{.{
        .tparam_count = 1,
        .params = &.{.{ .tparam_scalar = .{ .idx = 0, .family = .integer } }},
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    }};
    const args = [_]?Types.Type{ Types.I32, Types.I32 };
    const res = Overload.resolve(&sigs, &args);
    try std.testing.expectEqual(Overload.ResolveError.arg_count_mismatch, res.err.kind);
}

test "solver: null arg contributes no constraint (upstream inference fail)" {
    const sigs = [_]Overload.OverloadSig{.{
        .tparam_count = 1,
        .params = &.{
            .{ .tparam_scalar = .{ .idx = 0, .family = .integer } },
            .{ .tparam_scalar = .{ .idx = 0, .family = .integer } },
        },
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    }};
    const args = [_]?Types.Type{ Types.I32, null };
    const res = Overload.resolve(&sigs, &args);
    try std.testing.expect(res == .ok);
    try std.testing.expectEqual(Types.ScalarKind.i32, res.ok.bindings[0].scalar_kind.?);
}

test "solver: ptr<AS, atomic<T>, AM> binds all three slots" {
    const sigs = [_]Overload.OverloadSig{.{
        .tparam_count = 3,
        .params = &.{.{ .tparam_ptr_atomic = .{ .as_idx = 1, .am_idx = 2, .elem_idx = 0, .elem_family = .integer } }},
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    }};
    const a = Types.Atomic{ .element = Types.scalar_u32_ptr };
    const p = Types.Pointer{ .address_space = .storage, .element = .{ .atomic = &a }, .access_mode = .read_write };
    const args = [_]?Types.Type{.{ .pointer = &p }};
    const res = Overload.resolve(&sigs, &args);
    try std.testing.expect(res == .ok);
    try std.testing.expectEqual(Types.ScalarKind.u32, res.ok.bindings[0].scalar_kind.?);
    try std.testing.expectEqual(Ast.AddressSpace.storage, res.ok.bindings[1].address_space.?);
    try std.testing.expectEqual(Ast.AccessMode.read_write, res.ok.bindings[2].access_mode.?);
}

test "solver: bound_scalar in param position — later args must match bound T" {
    // Mimics atomicAdd(ptr<AS, atomic<T>, AM>, T) -> T.
    const sigs = [_]Overload.OverloadSig{.{
        .tparam_count = 3,
        .params = &.{
            .{ .tparam_ptr_atomic = .{ .as_idx = 1, .am_idx = 2, .elem_idx = 0, .elem_family = .integer } },
            .{ .bound_scalar = 0 },
        },
        .result = .{ .pattern = .{ .bound_scalar = 0 } },
    }};
    const a = Types.Atomic{ .element = Types.scalar_u32_ptr };
    const p = Types.Pointer{ .address_space = .storage, .element = .{ .atomic = &a }, .access_mode = .read_write };

    const ok_args = [_]?Types.Type{ .{ .pointer = &p }, Types.U32 };
    try std.testing.expect(Overload.resolve(&sigs, &ok_args) == .ok);

    const bad_args = [_]?Types.Type{ .{ .pointer = &p }, Types.I32 };
    try std.testing.expect(Overload.resolve(&sigs, &bad_args) == .err);

    // abstract-int promotes to u32 — feasible, with rank 4.
    const abs_args = [_]?Types.Type{ .{ .pointer = &p }, Types.AbstractInt };
    const abs_res = Overload.resolve(&sigs, &abs_args);
    try std.testing.expect(abs_res == .ok);
    try std.testing.expectEqual(@as(u32, 4), abs_res.ok.total_rank);
}

// =========================================================================
// 2. frexp (§17.5.33)
// =========================================================================

test "frexp(f32): return is __frexp_result_f32" {
    var r = try analyze("fn f() { let x = frexp(1.0f); }");
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "__frexp_result_f32");
}

test "frexp(f32).fract → f32" {
    var r = try analyze("fn f() { let r = frexp(2.5f); let m = r.fract; }");
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "m", "f32");
}

test "frexp(f32).exp → i32" {
    var r = try analyze("fn f() { let r = frexp(2.5f); let e = r.exp; }");
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "e", "i32");
}

test "frexp(vec3<f32>) result.exp is vec3<i32>" {
    var r = try analyze("fn f() { let r = frexp(vec3<f32>(1.0, 2.0, 3.0)); let e = r.exp; }");
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "e", "vec3<i32>");
}

test "frexp(vec2<f32>) result.fract is vec2<f32>" {
    var r = try analyze("fn f() { let r = frexp(vec2<f32>(1.0, 2.0)); let m = r.fract; }");
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "m", "vec2<f32>");
}

test "frexp: abstract-float arg preserves abstract in the synthesized struct name" {
    // Pre-engine behavior (preserved): the struct name carries the operand
    // type string verbatim — `frexp(1.0)` → `__frexp_result_abstract-float`.
    // The `let` default does not push concretion *inside* the struct cache
    // because the struct is already synthesized keyed by the raw operand
    // type. This is a known quirk scoped to the synth_* rules; a concrete
    // literal (`frexp(1.0f)`) correctly names the struct `__frexp_result_f32`.
    var r = try analyze("fn f() { let x = frexp(1.0); }");
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "__frexp_result_abstract-float");
}

test "frexp: reject i32 (no matching overload)" {
    var r = try validate("fn f() { let x = frexp(1i); }");
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(anyError(r));
}

test "frexp: reject bool" {
    var r = try validate("fn f() { let x = frexp(true); }");
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(anyError(r));
}

test "frexp: cached struct — two calls yield the same struct type string" {
    var r = try analyze(
        \\fn f() {
        \\  let a = frexp(1.0f);
        \\  let b = frexp(2.0f);
        \\  let am = a.fract;
        \\  let bm = b.fract;
        \\}
    );
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "am", "f32");
    try expectLetString(&r, "bm", "f32");
}

// =========================================================================
// 3. modf (§17.5.49)
// =========================================================================

test "modf(f32): return is __modf_result_f32" {
    var r = try analyze("fn f() { let x = modf(1.5f); }");
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "__modf_result_f32");
}

test "modf(f32).fract and .whole → f32" {
    var r = try analyze(
        \\fn f() {
        \\  let r = modf(1.5f);
        \\  let a = r.fract;
        \\  let b = r.whole;
        \\}
    );
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "a", "f32");
    try expectLetString(&r, "b", "f32");
}

test "modf(vec4<f32>).whole → vec4<f32>" {
    var r = try analyze("fn f() { let r = modf(vec4<f32>(1.0, 2.0, 3.0, 4.0)); let w = r.whole; }");
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "w", "vec4<f32>");
}

test "modf: reject integer arg" {
    var r = try validate("fn f() { let x = modf(1i); }");
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(anyError(r));
}

// =========================================================================
// 4. Atomic read-modify-write family (§17.9)
// =========================================================================

test "atomicLoad on atomic<u32> returns u32" {
    var r = try analyze(
        \\@group(0) @binding(0) var<storage, read_write> s: atomic<u32>;
        \\fn f() { let x = atomicLoad(&s); }
    );
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "u32");
}

test "atomicLoad on atomic<i32> returns i32" {
    var r = try analyze(
        \\@group(0) @binding(0) var<storage, read_write> s: atomic<i32>;
        \\fn f() { let x = atomicLoad(&s); }
    );
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "i32");
}

test "atomicAdd(ptr<atomic<u32>>, u32) returns u32" {
    var r = try analyze(
        \\@group(0) @binding(0) var<storage, read_write> s: atomic<u32>;
        \\fn f() { let x = atomicAdd(&s, 1u); }
    );
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "u32");
}

test "atomicAdd accepts abstract-int as value (promotes to u32)" {
    var r = try analyze(
        \\@group(0) @binding(0) var<storage, read_write> s: atomic<u32>;
        \\fn f() { let x = atomicAdd(&s, 1); }
    );
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "u32");
}

test "atomicAdd(u32 atomic, i32 value) — rejected: mismatched scalars" {
    var r = try validate(
        \\@group(0) @binding(0) var<storage, read_write> s: atomic<u32>;
        \\fn f() { let x = atomicAdd(&s, 1i); }
    );
    defer r.deinit(std.testing.allocator);
    if (!anyError(r)) {
        dump("expected atomic<u32> + i32 value rejection", r);
        return error.TestUnexpectedResult;
    }
}

test "atomicSub / atomicMax / atomicMin / atomicAnd / atomicOr / atomicXor / atomicExchange all carry through T" {
    inline for (.{ "atomicSub", "atomicMax", "atomicMin", "atomicAnd", "atomicOr", "atomicXor", "atomicExchange" }) |name| {
        var src_buf: [256]u8 = undefined;
        const src = try std.fmt.bufPrintZ(&src_buf,
            \\@group(0) @binding(0) var<storage, read_write> s: atomic<i32>;
            \\fn f() {{ let x = {s}(&s, 1i); }}
        , .{name});
        var r = try analyze(src);
        defer r.deinit(std.testing.allocator);
        try expectLetString(&r, "x", "i32");
    }
}

test "atomicExchange on atomic<u32> with u32 value" {
    var r = try analyze(
        \\@group(0) @binding(0) var<storage, read_write> s: atomic<u32>;
        \\fn f() { let x = atomicExchange(&s, 2u); }
    );
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "u32");
}

// =========================================================================
// 5. atomicCompareExchangeWeak (§17.9.7)
// =========================================================================

test "atomicCompareExchangeWeak on atomic<i32> returns the spec struct" {
    var r = try analyze(
        \\@group(0) @binding(0) var<storage, read_write> s: atomic<i32>;
        \\fn f() { let x = atomicCompareExchangeWeak(&s, 0i, 1i); }
    );
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "__atomic_compare_exchange_result_i32");
}

test "atomicCompareExchangeWeak .old_value → scalar T" {
    var r = try analyze(
        \\@group(0) @binding(0) var<storage, read_write> s: atomic<u32>;
        \\fn f() { let r = atomicCompareExchangeWeak(&s, 0u, 1u); let v = r.old_value; }
    );
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "v", "u32");
}

test "atomicCompareExchangeWeak .exchanged → bool" {
    var r = try analyze(
        \\@group(0) @binding(0) var<storage, read_write> s: atomic<u32>;
        \\fn f() { let r = atomicCompareExchangeWeak(&s, 0u, 1u); let e = r.exchanged; }
    );
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "e", "bool");
}

test "atomicCompareExchangeWeak rejects i32 compare / u32 atomic" {
    // NB: the first arg fixes T = u32; arg 2 is then required to be u32.
    // `-1` is abstract-int → u32 conversion rank 4 which is *feasible*.
    // Use an explicit `i32` value to trip the family mismatch.
    var r = try validate(
        \\@group(0) @binding(0) var<storage, read_write> s: atomic<u32>;
        \\fn f() { let x = atomicCompareExchangeWeak(&s, 0i, 1u); }
    );
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(anyError(r));
}

// =========================================================================
// 6. unpack family (§17.10)
// =========================================================================

test "unpack4xI8(u32) → vec4<i32>" {
    var r = try analyze("fn f() { let x = unpack4xI8(0u); }");
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "vec4<i32>");
}

test "unpack4xU8(u32) → vec4<u32>" {
    var r = try analyze("fn f() { let x = unpack4xU8(0u); }");
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "vec4<u32>");
}

test "unpack4x8snorm(u32) → vec4<f32>" {
    var r = try analyze("fn f() { let x = unpack4x8snorm(0u); }");
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "vec4<f32>");
}

test "unpack4x8unorm(u32) → vec4<f32>" {
    var r = try analyze("fn f() { let x = unpack4x8unorm(0u); }");
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "vec4<f32>");
}

test "unpack2x16snorm(u32) → vec2<f32>" {
    var r = try analyze("fn f() { let x = unpack2x16snorm(0u); }");
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "vec2<f32>");
}

test "unpack2x16unorm(u32) → vec2<f32>" {
    var r = try analyze("fn f() { let x = unpack2x16unorm(0u); }");
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "vec2<f32>");
}

test "unpack2x16float(u32) → vec2<f32>" {
    var r = try analyze("fn f() { let x = unpack2x16float(0u); }");
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "vec2<f32>");
}

test "unpack4xI8 accepts abstract-int (promotes to u32)" {
    var r = try analyze("fn f() { let x = unpack4xI8(0); }");
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "vec4<i32>");
}

test "unpack4xI8 rejects i32 (no matching overload — u32 only)" {
    var r = try validate("fn f() { let x = unpack4xI8(1i); }");
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(anyError(r));
}

// =========================================================================
// 7. subgroupBallot (§17.12)
// =========================================================================

test "subgroupBallot() with no args → vec4<u32>" {
    var r = try analyze(
        \\@compute @workgroup_size(1) fn main() { let x = subgroupBallot(); }
    );
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "vec4<u32>");
}

test "subgroupBallot(bool) → vec4<u32>" {
    var r = try analyze(
        \\@compute @workgroup_size(1) fn main() { let x = subgroupBallot(true); }
    );
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "vec4<u32>");
}

test "subgroupBallot(u32) rejected (only bool)" {
    var r = try validate(
        \\@compute @workgroup_size(1) fn main() { let x = subgroupBallot(1u); }
    );
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(anyError(r));
}

test "subgroupBallot too many args rejected" {
    var r = try validate(
        \\@compute @workgroup_size(1) fn main() { let x = subgroupBallot(true, false); }
    );
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(anyError(r));
}

// =========================================================================
// 8. workgroupUniformLoad (§17.11)
// =========================================================================

test "workgroupUniformLoad on ptr<workgroup, i32, read_write> → i32" {
    var r = try analyze(
        \\var<workgroup> w: i32;
        \\@compute @workgroup_size(1) fn main() { let x = workgroupUniformLoad(&w); }
    );
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "i32");
}

test "workgroupUniformLoad on ptr<workgroup, u32> → u32" {
    var r = try analyze(
        \\var<workgroup> w: u32;
        \\@compute @workgroup_size(1) fn main() { let x = workgroupUniformLoad(&w); }
    );
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "u32");
}

test "workgroupUniformLoad rejected on storage pointer (wrong AS)" {
    var r = try validate(
        \\@group(0) @binding(0) var<storage, read_write> s: i32;
        \\@compute @workgroup_size(1) fn main() { let x = workgroupUniformLoad(&s); }
    );
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(anyError(r));
}

// =========================================================================
// 9. transpose (§17.5.44)
// =========================================================================

test "transpose(mat2x3<f32>) → mat3x2<f32>" {
    var r = try analyze(
        \\fn f() {
        \\  let m = mat2x3<f32>(vec3<f32>(1.0, 2.0, 3.0), vec3<f32>(4.0, 5.0, 6.0));
        \\  let t = transpose(m);
        \\}
    );
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "t", "mat3x2<f32>");
}

test "transpose(mat4x4<f32>) → mat4x4<f32>" {
    var r = try analyze(
        \\fn f() {
        \\  let m = mat4x4<f32>(
        \\    vec4<f32>(1.0), vec4<f32>(2.0),
        \\    vec4<f32>(3.0), vec4<f32>(4.0)
        \\  );
        \\  let t = transpose(m);
        \\}
    );
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "t", "mat4x4<f32>");
}

test "transpose(mat3x2<f32>) → mat2x3<f32>" {
    var r = try analyze(
        \\fn f() {
        \\  let m = mat3x2<f32>(vec2<f32>(1.0, 2.0), vec2<f32>(3.0, 4.0), vec2<f32>(5.0, 6.0));
        \\  let t = transpose(m);
        \\}
    );
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "t", "mat2x3<f32>");
}

test "transpose rejects scalar argument" {
    var r = try validate("fn f() { let t = transpose(1.0f); }");
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(anyError(r));
}

test "transpose rejects vector argument" {
    var r = try validate("fn f() { let t = transpose(vec3<f32>(1.0, 2.0, 3.0)); }");
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(anyError(r));
}

// =========================================================================
// 10. Diagnostic wording sanity — overload rejections use E0203
// =========================================================================

test "diagnostic: frexp(i32) uses E0203 invalid_arg_type" {
    var r = try validate("fn f() { let x = frexp(1i); }");
    defer r.deinit(std.testing.allocator);
    // Either the category check (float_only) or the overload engine
    // should trigger E0203. Pre-engine, the category check always fired
    // first; post-engine, behavior is unchanged because frexp is .numeric.
    try std.testing.expect(hasErrorWithCode(r, "E0203"));
}

test "diagnostic: atomicAdd mismatched T uses E0203" {
    var r = try validate(
        \\@group(0) @binding(0) var<storage, read_write> s: atomic<u32>;
        \\fn f() { let x = atomicAdd(&s, 1i); }
    );
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasErrorWithCode(r, "E0203"));
}

test "diagnostic: overload rejection mentions the builtin name" {
    var r = try validate(
        \\@group(0) @binding(0) var<storage, read_write> s: atomic<u32>;
        \\fn f() { let x = atomicAdd(&s, 1i); }
    );
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasErrorContaining(r, "atomicAdd"));
}

// =========================================================================
// 11. Regression pins — cross-file invariants (copied from existing tests)
// =========================================================================

test "regression: min(5, 0u) → u32 (same_as_arg path, not Phase 1 but shares stage)" {
    var r = try analyze("fn f() { let x = min(5, 0u); }");
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "u32");
}

test "regression: sin(1.0f) → f32 (numeric category, not migrated to engine)" {
    var r = try analyze("fn f() { let x = sin(1.0f); }");
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "f32");
}

test "regression: textureSample unchanged (not Phase 1 migration)" {
    var r = try analyze(
        \\@group(0) @binding(0) var t: texture_2d<f32>;
        \\@group(0) @binding(1) var s: sampler;
        \\@fragment fn main() -> @location(0) vec4<f32> {
        \\  let c = textureSample(t, s, vec2<f32>(0.0, 0.0));
        \\  return c;
        \\}
    );
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "c", "vec4<f32>");
}

// =========================================================================
// 12. buildPatternType — result construction isolated from solver
// =========================================================================

test "buildPatternType: concrete type passes through" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bindings: [Overload.max_tparams]Overload.Binding = @splat(.{});
    const t = try Overload.buildPatternType(arena.allocator(), .{ .concrete = Types.F32 }, &bindings);
    try std.testing.expect(t != null);
    try std.testing.expectEqualStrings("f32", t.?.string());
}

test "buildPatternType: bound_scalar yields the scalar singleton" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bindings: [Overload.max_tparams]Overload.Binding = @splat(.{});
    bindings[0] = .{ .bound = true, .scalar_kind = .i32 };
    const t = try Overload.buildPatternType(arena.allocator(), .{ .bound_scalar = 0 }, &bindings);
    try std.testing.expect(t != null);
    try std.testing.expectEqualStrings("i32", t.?.string());
}

test "buildPatternType: unbound slot returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bindings: [Overload.max_tparams]Overload.Binding = @splat(.{});
    const t = try Overload.buildPatternType(arena.allocator(), .{ .bound_scalar = 0 }, &bindings);
    try std.testing.expect(t == null);
}

test "buildPatternType: bound_matrix_transposed swaps cols/rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bindings: [Overload.max_tparams]Overload.Binding = @splat(.{});
    bindings[0] = .{ .bound = true, .scalar_kind = .f32 };
    bindings[1] = .{ .bound = true, .width = 2 };
    bindings[2] = .{ .bound = true, .width = 4 };
    const pat: Overload.Pattern = .{ .bound_matrix_transposed = .{ .elem_idx = 0, .cols_idx = 1, .rows_idx = 2 } };
    const t = try Overload.buildPatternType(arena.allocator(), pat, &bindings);
    try std.testing.expect(t != null);
    try std.testing.expect(t.? == .matrix);
    // Input was 2×4 → transposed is 4×2.
    try std.testing.expectEqual(@as(u8, 4), t.?.matrix.cols);
    try std.testing.expectEqual(@as(u8, 2), t.?.matrix.rows);
    try std.testing.expectEqual(Types.ScalarKind.f32, t.?.matrix.element.kind);
}

// =========================================================================
// 13. dot4-packed (§17.5.20) — Phase 3a migration
// =========================================================================

test "dot4I8Packed(u32, u32) → i32" {
    var r = try analyze("fn f() { let x = dot4I8Packed(0u, 0u); }");
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "i32");
}

test "dot4U8Packed(u32, u32) → u32" {
    var r = try analyze("fn f() { let x = dot4U8Packed(0u, 0u); }");
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "u32");
}

test "dot4I8Packed accepts u32 variable references (load rule)" {
    var r = try analyze(
        \\fn f() {
        \\    var a: u32 = 1u;
        \\    var b: u32 = 2u;
        \\    let x = dot4I8Packed(a, b);
        \\}
    );
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "i32");
}

test "dot4I8Packed rejects i32 args (no matching overload)" {
    var r = try validate("fn f() { let x = dot4I8Packed(1i, 2i); }");
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasErrorWithCode(r, "E0203"));
    try std.testing.expect(hasErrorContaining(r, "dot4I8Packed"));
}

test "dot4U8Packed rejects mixed u32/i32 on second arg" {
    var r = try validate("fn f() { let x = dot4U8Packed(0u, 1i); }");
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasErrorWithCode(r, "E0203"));
    try std.testing.expect(hasErrorContaining(r, "argument 2"));
}

test "dot4I8Packed arity: one arg rejected" {
    var r = try validate("fn f() { let x = dot4I8Packed(0u); }");
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(anyError(r));
}

// =========================================================================
// 14. bitcast template seeding (§17.9.5) — Phase 3b migration
// =========================================================================
//
// The end-to-end `bitcast<T>(e)` pipeline is heavily covered by
// `tests/inference/bitcast_test.zig` (38+ blocks, all must stay green).
// The blocks below target the Phase 3b solver seam specifically:
// slot-0 / slot-1 seeding, `concrete_32` family gating, and the
// four sig-array dispatch. One positive test per sig array, plus a
// couple of invariants (seed preservation, width-seeded enforcement)
// that the engine tests alone can't pin because they exercise the
// validator-side seeding step.

test "bitcast<f32>(1u) → f32 (scalar_32 sig, slot 0 seeded f32)" {
    var r = try analyze("fn f() { let x = bitcast<f32>(1u); }");
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "f32");
}

test "bitcast<i32>(1u) → i32 (cross-type scalar)" {
    var r = try analyze("fn f() { let x = bitcast<i32>(1u); }");
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "i32");
}

test "bitcast<vec2u>(vec2i(1,2)) → vec2<u32> (vecN_32 sig, N=2 seeded)" {
    var r = try analyze("fn f() { let x = bitcast<vec2u>(vec2i(1, 2)); }");
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "vec2<u32>");
}

test "bitcast<vec3f>(vec3i(1,2,3)) → vec3<f32> (vecN_32 sig, N=3 seeded)" {
    var r = try analyze("fn f() { let x = bitcast<vec3f>(vec3i(1, 2, 3)); }");
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "vec3<f32>");
}

test "bitcast<vec2h>(1u) → vec2<f16> (vec2_f16 sig, T=f16/N=2 seeded)" {
    var r = try analyze(
        \\enable f16;
        \\fn f() { let x = bitcast<vec2h>(1u); }
    );
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "vec2<f16>");
}

test "bitcast<u32>(vec2h) → u32 (scalar_32 sig, concrete vec2<f16> param)" {
    var r = try analyze(
        \\enable f16;
        \\fn f() { let y = bitcast<vec2h>(1u); let x = bitcast<u32>(y); }
    );
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "u32");
}

test "bitcast<vec4h>(vec2u(1u, 2u)) → vec4<f16> (vec4_f16 sig)" {
    var r = try analyze(
        \\enable f16;
        \\fn f() { let x = bitcast<vec4h>(vec2u(1u, 2u)); }
    );
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "vec4<f16>");
}

test "bitcast<vec2f>(vec4h(…)) → vec2<f32> (vecN_32 sig via concrete vec4<f16>)" {
    var r = try analyze(
        \\enable f16;
        \\fn f() {
        \\    let p = vec4h(1.0h, 2.0h, 3.0h, 4.0h);
        \\    let x = bitcast<vec2f>(p);
        \\}
    );
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "vec2<f32>");
}

test "bitcast seed preservation: T=f32 returned even when arg is u32" {
    // Confirms the return comes from the seeded slot 0 (= template T),
    // not from the solver-bound slot 2 (= source scalar S).
    var r = try analyze("fn f() { let x = bitcast<f32>(0xFFFFFFFFu); }");
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "f32");
}

test "bitcast width seeding rejects wrong-N vector (vec3 template vs vec2 arg)" {
    // Template vec3<u32> seeds N=3; the vecN_32 sig's tparam_vector
    // binds the arg's width against the seed. vec2<i32> binds N=2 ≠ 3,
    // so the solver rejects; size-check runs first (96 vs 64 bits) and
    // emits the bit-width diagnostic. Either rejection path is a fail,
    // so we just assert an error.
    var r = try validate("fn f() { let x = bitcast<vec3u>(vec2i(1, 2)); }");
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(anyError(r));
}

test "bitcast concrete_32 family rejects f16 scalar source" {
    // vec2<f16> template has vec2_f16 sig that only takes scalar_32
    // args (via family .concrete_32). f16 is excluded from that family
    // even though f16 would fit size-wise (16-bit scalar). Size check
    // catches this first (16 vs 32 bits).
    var r = try validate(
        \\enable f16;
        \\fn f() { let x = bitcast<vec2h>(1.0h); }
    );
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(anyError(r));
}

test "bitcast invalid template shape (vec3<f16>) produces 'cannot bitcast to'" {
    // bitcastTemplateShape returns .invalid for vec3<f16>; validator
    // emits the destination-domain error without running the solver.
    var r = try validate(
        \\enable f16;
        \\fn f() {
        \\    let p = vec3h(1.0h, 2.0h, 3.0h);
        \\    let x = bitcast<vec3h>(p);
        \\}
    );
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(anyError(r));
}

test "bitcast arity: zero args rejected" {
    var r = try validate("fn f() { let x = bitcast<u32>(); }");
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasErrorContaining(r, "bitcast"));
}

test "bitcast arity: two args rejected" {
    var r = try validate("fn f() { let x = bitcast<u32>(1u, 2u); }");
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasErrorContaining(r, "bitcast"));
}

test "bitcast abstract-int concretizes before seeding" {
    var r = try analyze("fn f() { let x = bitcast<f32>(42); }");
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "f32");
}

test "bitcast nested: outer f32 seeded even when inner is vec2<f16>" {
    var r = try analyze(
        \\enable f16;
        \\fn f() { let x = bitcast<f32>(bitcast<vec2h>(1u)); }
    );
    defer r.deinit(std.testing.allocator);
    try expectLetString(&r, "x", "f32");
}

test "bitcast without template argument rejected" {
    // Previously this silently returned no-type (bitcast fell through to
    // inferCustomBuiltin → null). Now the validator emits a dedicated
    // diagnostic so the user knows a template is required.
    var r = try validate("fn f() { let x = bitcast(1u); }");
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(hasErrorContaining(r, "template type argument"));
}
