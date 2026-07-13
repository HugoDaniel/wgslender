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
    defer r.deinit();
    try expectLetString(&r, "x", "__frexp_result_f32");
}

test "frexp(f32).fract → f32" {
    var r = try analyze("fn f() { let r = frexp(2.5f); let m = r.fract; }");
    defer r.deinit();
    try expectLetString(&r, "m", "f32");
}

test "frexp(f32).exp → i32" {
    var r = try analyze("fn f() { let r = frexp(2.5f); let e = r.exp; }");
    defer r.deinit();
    try expectLetString(&r, "e", "i32");
}

test "frexp(vec3<f32>) result.exp is vec3<i32>" {
    var r = try analyze("fn f() { let r = frexp(vec3<f32>(1.0, 2.0, 3.0)); let e = r.exp; }");
    defer r.deinit();
    try expectLetString(&r, "e", "vec3<i32>");
}

test "frexp(vec2<f32>) result.fract is vec2<f32>" {
    var r = try analyze("fn f() { let r = frexp(vec2<f32>(1.0, 2.0)); let m = r.fract; }");
    defer r.deinit();
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
    defer r.deinit();
    try expectLetString(&r, "x", "__frexp_result_abstract-float");
}

test "frexp: reject i32 (no matching overload)" {
    var r = try validate("fn f() { let x = frexp(1i); }");
    defer r.deinit();
    try std.testing.expect(anyError(r));
}

test "frexp: reject bool" {
    var r = try validate("fn f() { let x = frexp(true); }");
    defer r.deinit();
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
    defer r.deinit();
    try expectLetString(&r, "am", "f32");
    try expectLetString(&r, "bm", "f32");
}

// =========================================================================
// 3. modf (§17.5.49)
// =========================================================================

test "modf(f32): return is __modf_result_f32" {
    var r = try analyze("fn f() { let x = modf(1.5f); }");
    defer r.deinit();
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
    defer r.deinit();
    try expectLetString(&r, "a", "f32");
    try expectLetString(&r, "b", "f32");
}

test "modf(vec4<f32>).whole → vec4<f32>" {
    var r = try analyze("fn f() { let r = modf(vec4<f32>(1.0, 2.0, 3.0, 4.0)); let w = r.whole; }");
    defer r.deinit();
    try expectLetString(&r, "w", "vec4<f32>");
}

test "modf: reject integer arg" {
    var r = try validate("fn f() { let x = modf(1i); }");
    defer r.deinit();
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
    defer r.deinit();
    try expectLetString(&r, "x", "u32");
}

test "atomicLoad on atomic<i32> returns i32" {
    var r = try analyze(
        \\@group(0) @binding(0) var<storage, read_write> s: atomic<i32>;
        \\fn f() { let x = atomicLoad(&s); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "i32");
}

test "atomicAdd(ptr<atomic<u32>>, u32) returns u32" {
    var r = try analyze(
        \\@group(0) @binding(0) var<storage, read_write> s: atomic<u32>;
        \\fn f() { let x = atomicAdd(&s, 1u); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "u32");
}

test "atomicAdd accepts abstract-int as value (promotes to u32)" {
    var r = try analyze(
        \\@group(0) @binding(0) var<storage, read_write> s: atomic<u32>;
        \\fn f() { let x = atomicAdd(&s, 1); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "u32");
}

test "atomicAdd(u32 atomic, i32 value) — rejected: mismatched scalars" {
    var r = try validate(
        \\@group(0) @binding(0) var<storage, read_write> s: atomic<u32>;
        \\fn f() { let x = atomicAdd(&s, 1i); }
    );
    defer r.deinit();
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
        defer r.deinit();
        try expectLetString(&r, "x", "i32");
    }
}

test "atomicExchange on atomic<u32> with u32 value" {
    var r = try analyze(
        \\@group(0) @binding(0) var<storage, read_write> s: atomic<u32>;
        \\fn f() { let x = atomicExchange(&s, 2u); }
    );
    defer r.deinit();
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
    defer r.deinit();
    try expectLetString(&r, "x", "__atomic_compare_exchange_result_i32");
}

test "atomicCompareExchangeWeak .old_value → scalar T" {
    var r = try analyze(
        \\@group(0) @binding(0) var<storage, read_write> s: atomic<u32>;
        \\fn f() { let r = atomicCompareExchangeWeak(&s, 0u, 1u); let v = r.old_value; }
    );
    defer r.deinit();
    try expectLetString(&r, "v", "u32");
}

test "atomicCompareExchangeWeak .exchanged → bool" {
    var r = try analyze(
        \\@group(0) @binding(0) var<storage, read_write> s: atomic<u32>;
        \\fn f() { let r = atomicCompareExchangeWeak(&s, 0u, 1u); let e = r.exchanged; }
    );
    defer r.deinit();
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
    defer r.deinit();
    try std.testing.expect(anyError(r));
}

// =========================================================================
// 6. unpack family (§17.10)
// =========================================================================

test "unpack4xI8(u32) → vec4<i32>" {
    var r = try analyze("fn f() { let x = unpack4xI8(0u); }");
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<i32>");
}

test "unpack4xU8(u32) → vec4<u32>" {
    var r = try analyze("fn f() { let x = unpack4xU8(0u); }");
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<u32>");
}

test "unpack4x8snorm(u32) → vec4<f32>" {
    var r = try analyze("fn f() { let x = unpack4x8snorm(0u); }");
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<f32>");
}

test "unpack4x8unorm(u32) → vec4<f32>" {
    var r = try analyze("fn f() { let x = unpack4x8unorm(0u); }");
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<f32>");
}

test "unpack2x16snorm(u32) → vec2<f32>" {
    var r = try analyze("fn f() { let x = unpack2x16snorm(0u); }");
    defer r.deinit();
    try expectLetString(&r, "x", "vec2<f32>");
}

test "unpack2x16unorm(u32) → vec2<f32>" {
    var r = try analyze("fn f() { let x = unpack2x16unorm(0u); }");
    defer r.deinit();
    try expectLetString(&r, "x", "vec2<f32>");
}

test "unpack2x16float(u32) → vec2<f32>" {
    var r = try analyze("fn f() { let x = unpack2x16float(0u); }");
    defer r.deinit();
    try expectLetString(&r, "x", "vec2<f32>");
}

test "unpack4xI8 accepts abstract-int (promotes to u32)" {
    var r = try analyze("fn f() { let x = unpack4xI8(0); }");
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<i32>");
}

test "unpack4xI8 rejects i32 (no matching overload — u32 only)" {
    var r = try validate("fn f() { let x = unpack4xI8(1i); }");
    defer r.deinit();
    try std.testing.expect(anyError(r));
}

// =========================================================================
// 7. subgroupBallot (§17.12)
// =========================================================================

test "subgroupBallot() with no args → vec4<u32>" {
    var r = try analyze(
        \\@compute @workgroup_size(1) fn main() { let x = subgroupBallot(); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<u32>");
}

test "subgroupBallot(bool) → vec4<u32>" {
    var r = try analyze(
        \\@compute @workgroup_size(1) fn main() { let x = subgroupBallot(true); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec4<u32>");
}

test "subgroupBallot(u32) rejected (only bool)" {
    var r = try validate(
        \\@compute @workgroup_size(1) fn main() { let x = subgroupBallot(1u); }
    );
    defer r.deinit();
    try std.testing.expect(anyError(r));
}

test "subgroupBallot too many args rejected" {
    var r = try validate(
        \\@compute @workgroup_size(1) fn main() { let x = subgroupBallot(true, false); }
    );
    defer r.deinit();
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
    defer r.deinit();
    try expectLetString(&r, "x", "i32");
}

test "workgroupUniformLoad on ptr<workgroup, u32> → u32" {
    var r = try analyze(
        \\var<workgroup> w: u32;
        \\@compute @workgroup_size(1) fn main() { let x = workgroupUniformLoad(&w); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "u32");
}

test "workgroupUniformLoad rejected on storage pointer (wrong AS)" {
    var r = try validate(
        \\@group(0) @binding(0) var<storage, read_write> s: i32;
        \\@compute @workgroup_size(1) fn main() { let x = workgroupUniformLoad(&s); }
    );
    defer r.deinit();
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
    defer r.deinit();
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
    defer r.deinit();
    try expectLetString(&r, "t", "mat4x4<f32>");
}

test "transpose(mat3x2<f32>) → mat2x3<f32>" {
    var r = try analyze(
        \\fn f() {
        \\  let m = mat3x2<f32>(vec2<f32>(1.0, 2.0), vec2<f32>(3.0, 4.0), vec2<f32>(5.0, 6.0));
        \\  let t = transpose(m);
        \\}
    );
    defer r.deinit();
    try expectLetString(&r, "t", "mat2x3<f32>");
}

test "transpose rejects scalar argument" {
    var r = try validate("fn f() { let t = transpose(1.0f); }");
    defer r.deinit();
    try std.testing.expect(anyError(r));
}

test "transpose rejects vector argument" {
    var r = try validate("fn f() { let t = transpose(vec3<f32>(1.0, 2.0, 3.0)); }");
    defer r.deinit();
    try std.testing.expect(anyError(r));
}

// =========================================================================
// 10. Diagnostic wording sanity — overload rejections use E0203
// =========================================================================

test "diagnostic: frexp(i32) uses E0203 invalid_arg_type" {
    var r = try validate("fn f() { let x = frexp(1i); }");
    defer r.deinit();
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
    defer r.deinit();
    try std.testing.expect(hasErrorWithCode(r, "E0203"));
}

test "diagnostic: overload rejection mentions the builtin name" {
    var r = try validate(
        \\@group(0) @binding(0) var<storage, read_write> s: atomic<u32>;
        \\fn f() { let x = atomicAdd(&s, 1i); }
    );
    defer r.deinit();
    try std.testing.expect(hasErrorContaining(r, "atomicAdd"));
}

// =========================================================================
// 11. Regression pins — cross-file invariants (copied from existing tests)
// =========================================================================

test "regression: min(5, 0u) → u32 (same_as_arg path, not Phase 1 but shares stage)" {
    var r = try analyze("fn f() { let x = min(5, 0u); }");
    defer r.deinit();
    try expectLetString(&r, "x", "u32");
}

test "regression: sin(1.0f) → f32 (numeric category, not migrated to engine)" {
    var r = try analyze("fn f() { let x = sin(1.0f); }");
    defer r.deinit();
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
    defer r.deinit();
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
    defer r.deinit();
    try expectLetString(&r, "x", "i32");
}

test "dot4U8Packed(u32, u32) → u32" {
    var r = try analyze("fn f() { let x = dot4U8Packed(0u, 0u); }");
    defer r.deinit();
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
    defer r.deinit();
    try expectLetString(&r, "x", "i32");
}

test "dot4I8Packed rejects i32 args (no matching overload)" {
    var r = try validate("fn f() { let x = dot4I8Packed(1i, 2i); }");
    defer r.deinit();
    try std.testing.expect(hasErrorWithCode(r, "E0203"));
    try std.testing.expect(hasErrorContaining(r, "dot4I8Packed"));
}

test "dot4U8Packed rejects mixed u32/i32 on second arg" {
    var r = try validate("fn f() { let x = dot4U8Packed(0u, 1i); }");
    defer r.deinit();
    try std.testing.expect(hasErrorWithCode(r, "E0203"));
    try std.testing.expect(hasErrorContaining(r, "argument 2"));
}

test "dot4I8Packed arity: one arg rejected" {
    var r = try validate("fn f() { let x = dot4I8Packed(0u); }");
    defer r.deinit();
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
    defer r.deinit();
    try expectLetString(&r, "x", "f32");
}

test "bitcast<i32>(1u) → i32 (cross-type scalar)" {
    var r = try analyze("fn f() { let x = bitcast<i32>(1u); }");
    defer r.deinit();
    try expectLetString(&r, "x", "i32");
}

test "bitcast<vec2u>(vec2i(1,2)) → vec2<u32> (vecN_32 sig, N=2 seeded)" {
    var r = try analyze("fn f() { let x = bitcast<vec2u>(vec2i(1, 2)); }");
    defer r.deinit();
    try expectLetString(&r, "x", "vec2<u32>");
}

test "bitcast<vec3f>(vec3i(1,2,3)) → vec3<f32> (vecN_32 sig, N=3 seeded)" {
    var r = try analyze("fn f() { let x = bitcast<vec3f>(vec3i(1, 2, 3)); }");
    defer r.deinit();
    try expectLetString(&r, "x", "vec3<f32>");
}

test "bitcast<vec2h>(1u) → vec2<f16> (vec2_f16 sig, T=f16/N=2 seeded)" {
    var r = try analyze(
        \\enable f16;
        \\fn f() { let x = bitcast<vec2h>(1u); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "vec2<f16>");
}

test "bitcast<u32>(vec2h) → u32 (scalar_32 sig, concrete vec2<f16> param)" {
    var r = try analyze(
        \\enable f16;
        \\fn f() { let y = bitcast<vec2h>(1u); let x = bitcast<u32>(y); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "u32");
}

test "bitcast<vec4h>(vec2u(1u, 2u)) → vec4<f16> (vec4_f16 sig)" {
    var r = try analyze(
        \\enable f16;
        \\fn f() { let x = bitcast<vec4h>(vec2u(1u, 2u)); }
    );
    defer r.deinit();
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
    defer r.deinit();
    try expectLetString(&r, "x", "vec2<f32>");
}

test "bitcast seed preservation: T=f32 returned even when arg is u32" {
    // Confirms the return comes from the seeded slot 0 (= template T),
    // not from the solver-bound slot 2 (= source scalar S).
    var r = try analyze("fn f() { let x = bitcast<f32>(0xFFFFFFFFu); }");
    defer r.deinit();
    try expectLetString(&r, "x", "f32");
}

test "bitcast width seeding rejects wrong-N vector (vec3 template vs vec2 arg)" {
    // Template vec3<u32> seeds N=3; the vecN_32 sig's tparam_vector
    // binds the arg's width against the seed. vec2<i32> binds N=2 ≠ 3,
    // so the solver rejects; size-check runs first (96 vs 64 bits) and
    // emits the bit-width diagnostic. Either rejection path is a fail,
    // so we just assert an error.
    var r = try validate("fn f() { let x = bitcast<vec3u>(vec2i(1, 2)); }");
    defer r.deinit();
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
    defer r.deinit();
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
    defer r.deinit();
    try std.testing.expect(anyError(r));
}

test "bitcast arity: zero args rejected" {
    var r = try validate("fn f() { let x = bitcast<u32>(); }");
    defer r.deinit();
    try std.testing.expect(hasErrorContaining(r, "bitcast"));
}

test "bitcast arity: two args rejected" {
    var r = try validate("fn f() { let x = bitcast<u32>(1u, 2u); }");
    defer r.deinit();
    try std.testing.expect(hasErrorContaining(r, "bitcast"));
}

test "bitcast abstract-int concretizes before seeding" {
    var r = try analyze("fn f() { let x = bitcast<f32>(42); }");
    defer r.deinit();
    try expectLetString(&r, "x", "f32");
}

test "bitcast nested: outer f32 seeded even when inner is vec2<f16>" {
    var r = try analyze(
        \\enable f16;
        \\fn f() { let x = bitcast<f32>(bitcast<vec2h>(1u)); }
    );
    defer r.deinit();
    try expectLetString(&r, "x", "f32");
}

test "bitcast without template argument rejected" {
    // Previously this silently returned no-type (bitcast fell through to
    // inferCustomBuiltin → null). Now the validator emits a dedicated
    // diagnostic so the user knows a template is required.
    var r = try validate("fn f() { let x = bitcast(1u); }");
    defer r.deinit();
    try std.testing.expect(hasErrorContaining(r, "template type argument"));
}

// =========================================================================
// 15. Targeted resolution + cross-arg constructor patterns (Block 4a)
//
// Engine-level coverage of the constructor machinery: `resolveTargeted`
// (result type is the fixed target, not a materialized ResultRule) and the
// two cross-arg reduction patterns — `variadic_components_to_width` (vector
// composition, WGSL §16.1) and `all_scalar_or_all_vector` (matrix ctor
// dichotomy). No validator wiring yet (that is Block 4b); these drive the
// solver directly. Element convertibility is *implicit* conversion
// (`Types.conversionRank`), matching the old `canConvertScalarTo` used by
// the splat/multi-arg constructor paths.
// =========================================================================

// A few short-lived composite types shared by the blocks below.
const v2f = Types.Vector{ .width = 2, .element = Types.scalar_f32_ptr };
const v3f = Types.Vector{ .width = 3, .element = Types.scalar_f32_ptr };
const v4f = Types.Vector{ .width = 4, .element = Types.scalar_f32_ptr };
const v2f_t: Types.Type = .{ .vector = &v2f };
const v3f_t: Types.Type = .{ .vector = &v3f };
const v4f_t: Types.Type = .{ .vector = &v4f };
const m2x2f = Types.Matrix{ .cols = 2, .rows = 2, .element = Types.scalar_f32_ptr };
const m2x3f = Types.Matrix{ .cols = 2, .rows = 3, .element = Types.scalar_f32_ptr };
const m2x2f_t: Types.Type = .{ .matrix = &m2x2f };
const m2x3f_t: Types.Type = .{ .matrix = &m2x3f };

// NOTE: params are `comptime` so the `&.{...}` pattern literal is comptime-known
// and lives in static storage. With runtime params it would point at a stack
// temporary that dies when the helper returns — a use-after-return whose reads
// are non-deterministic garbage. Every caller passes compile-time constants.
fn composeVecSigs(comptime width: u8, comptime elem: Types.Type) [1]Overload.OverloadSig {
    return .{.{
        .tparam_count = 0,
        .params = &.{.{ .variadic_components_to_width = .{ .width = width, .elem = elem } }},
        .result = .{ .fixed = Types.F32 }, // dummy — never materialized (resolveTargeted uses target)
    }};
}

fn matrixDichotomySigs(comptime cols: u8, comptime rows: u8, comptime elem: Types.Type) [1]Overload.OverloadSig {
    return .{.{
        .tparam_count = 0,
        .params = &.{.{ .all_scalar_or_all_vector = .{ .cols = cols, .rows = rows, .elem = elem } }},
        .result = .{ .fixed = Types.F32 }, // dummy
    }};
}

// --- variadic_components_to_width (vector composition) --------------------

test "compose: vec4(scalar, vec2, scalar) sums to width 4" {
    const sigs = composeVecSigs(4, Types.F32);
    const args = [_]?Types.Type{ Types.F32, v2f_t, Types.F32 };
    try std.testing.expect(Overload.resolve(&sigs, &args) == .ok);
}

test "compose: single vec4 argument sums to width 4" {
    const sigs = composeVecSigs(4, Types.F32);
    const args = [_]?Types.Type{v4f_t};
    try std.testing.expect(Overload.resolve(&sigs, &args) == .ok);
}

test "compose: width mismatch (1+2 = 3 != 4) rejected" {
    const sigs = composeVecSigs(4, Types.F32);
    const args = [_]?Types.Type{ Types.F32, v2f_t };
    try std.testing.expect(Overload.resolve(&sigs, &args) == .err);
}

test "compose: i32 components into f32 vector rejected (no implicit i32->f32)" {
    const sigs = composeVecSigs(4, Types.F32);
    const args = [_]?Types.Type{ Types.I32, Types.I32, Types.I32, Types.I32 };
    try std.testing.expect(Overload.resolve(&sigs, &args) == .err);
}

test "compose: abstract-int components convert to f32 with rank 6" {
    const sigs = composeVecSigs(4, Types.F32);
    const args = [_]?Types.Type{ Types.AbstractInt, Types.AbstractInt, Types.AbstractInt, Types.AbstractInt };
    const r = Overload.resolve(&sigs, &args);
    try std.testing.expect(r == .ok);
    try std.testing.expectEqual(@as(u32, 6), r.ok.total_rank);
}

test "compose: bool components into f32 vector rejected" {
    const sigs = composeVecSigs(4, Types.F32);
    const args = [_]?Types.Type{ Types.Bool, Types.Bool, Types.Bool, Types.Bool };
    try std.testing.expect(Overload.resolve(&sigs, &args) == .err);
}

test "compose: vec2<bool> accepts bool components" {
    const sigs = composeVecSigs(2, Types.Bool);
    const args = [_]?Types.Type{ Types.Bool, Types.Bool };
    try std.testing.expect(Overload.resolve(&sigs, &args) == .ok);
}

test "compose: null arg makes the whole call feasible (skip width check)" {
    const sigs = composeVecSigs(4, Types.F32);
    const args = [_]?Types.Type{ Types.F32, null, Types.F32 };
    try std.testing.expect(Overload.resolve(&sigs, &args) == .ok);
}

test "compose: non-scalar/vector arg (matrix) rejected" {
    const sigs = composeVecSigs(4, Types.F32);
    const args = [_]?Types.Type{m2x2f_t};
    try std.testing.expect(Overload.resolve(&sigs, &args) == .err);
}

// --- all_scalar_or_all_vector (matrix dichotomy) -------------------------

test "matrix: 4 scalars build mat2x2 (cols*rows)" {
    const sigs = matrixDichotomySigs(2, 2, Types.F32);
    const args = [_]?Types.Type{ Types.F32, Types.F32, Types.F32, Types.F32 };
    try std.testing.expect(Overload.resolve(&sigs, &args) == .ok);
}

test "matrix: 2 column vectors of width 2 build mat2x2" {
    const sigs = matrixDichotomySigs(2, 2, Types.F32);
    const args = [_]?Types.Type{ v2f_t, v2f_t };
    try std.testing.expect(Overload.resolve(&sigs, &args) == .ok);
}

test "matrix: mat2x3 needs 2 column vectors of width 3" {
    const sigs = matrixDichotomySigs(2, 3, Types.F32);
    const args = [_]?Types.Type{ v3f_t, v3f_t };
    try std.testing.expect(Overload.resolve(&sigs, &args) == .ok);
}

test "matrix: wrong scalar count (3 != 4) rejected" {
    const sigs = matrixDichotomySigs(2, 2, Types.F32);
    const args = [_]?Types.Type{ Types.F32, Types.F32, Types.F32 };
    try std.testing.expect(Overload.resolve(&sigs, &args) == .err);
}

test "matrix: column vectors of wrong width rejected (vec3 into mat2x2)" {
    const sigs = matrixDichotomySigs(2, 2, Types.F32);
    const args = [_]?Types.Type{ v3f_t, v3f_t };
    try std.testing.expect(Overload.resolve(&sigs, &args) == .err);
}

test "matrix: mix of scalar and vector rejected" {
    const sigs = matrixDichotomySigs(2, 2, Types.F32);
    const args = [_]?Types.Type{ Types.F32, v2f_t };
    try std.testing.expect(Overload.resolve(&sigs, &args) == .err);
}

test "matrix: wrong vector count (3 vectors into mat2x2, cols=2) rejected" {
    const sigs = matrixDichotomySigs(2, 2, Types.F32);
    const args = [_]?Types.Type{ v2f_t, v2f_t, v2f_t };
    try std.testing.expect(Overload.resolve(&sigs, &args) == .err);
}

test "matrix: i32 scalars into f32 matrix rejected" {
    const sigs = matrixDichotomySigs(2, 2, Types.F32);
    const args = [_]?Types.Type{ Types.I32, Types.I32, Types.I32, Types.I32 };
    try std.testing.expect(Overload.resolve(&sigs, &args) == .err);
}

test "matrix: abstract-int scalars convert to f32 with rank 6" {
    const sigs = matrixDichotomySigs(2, 2, Types.F32);
    const args = [_]?Types.Type{ Types.AbstractInt, Types.AbstractInt, Types.AbstractInt, Types.AbstractInt };
    const r = Overload.resolve(&sigs, &args);
    try std.testing.expect(r == .ok);
    try std.testing.expectEqual(@as(u32, 6), r.ok.total_rank);
}

// --- resolveTargeted (result is the target type) -------------------------

test "resolveTargeted: vec composition returns the target type" {
    const sigs = composeVecSigs(4, Types.F32);
    const args = [_]?Types.Type{ Types.F32, v2f_t, Types.F32 };
    const r = Overload.resolveTargeted(&sigs, v4f_t, &args);
    try std.testing.expect(r == .ok);
    try std.testing.expectEqualStrings("vec4<f32>", r.ok.string());
}

test "resolveTargeted: matrix composition returns the target type" {
    const sigs = matrixDichotomySigs(2, 2, Types.F32);
    const args = [_]?Types.Type{ v2f_t, v2f_t };
    const r = Overload.resolveTargeted(&sigs, m2x2f_t, &args);
    try std.testing.expect(r == .ok);
    try std.testing.expectEqualStrings("mat2x2<f32>", r.ok.string());
}

test "resolveTargeted: matrix mix fails" {
    const sigs = matrixDichotomySigs(2, 2, Types.F32);
    const args = [_]?Types.Type{ Types.F32, v2f_t };
    const r = Overload.resolveTargeted(&sigs, m2x2f_t, &args);
    try std.testing.expect(r == .err);
}

test "resolveTargeted: reduction sig with zero args is an arity mismatch" {
    // A cross-arg reduction sig requires at least one arg; the zero-value
    // constructor form (`vec4()`) is a separate zero-arg sig (see ctorSigsFor).
    const sigs = composeVecSigs(4, Types.F32);
    const args = [_]?Types.Type{};
    const r = Overload.resolveTargeted(&sigs, v4f_t, &args);
    try std.testing.expect(r == .err);
    try std.testing.expectEqual(Overload.ResolveError.arg_count_mismatch, r.err.kind);
}

// =========================================================================
// 16. ctorSigsFor — per-target constructor signature derivation (Block 4a)
//
// One function emits the whole overload set for a target type; the tests
// drive it through `resolveTargeted`. Still engine-only — no validator
// wiring. The single-composite copy/convert form admits only implicit
// element conversions here; the explicit form (`vec2f(vec2h(..))`, WGSL
// §16.2.2) is completed when the validator is migrated in Block 4b.
// =========================================================================

fn ok(sigs: []const Overload.OverloadSig, target: Types.Type, args: []const ?Types.Type) bool {
    return Overload.resolveTargeted(sigs, target, args) == .ok;
}

test "ctorSigsFor scalar: any scalar converts, non-scalar rejected, arity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sigs = try Overload.ctorSigsFor(arena.allocator(), Types.F32);
    try std.testing.expect(ok(sigs, Types.F32, &.{Types.I32})); // f32(i32): explicit
    try std.testing.expect(ok(sigs, Types.F32, &.{})); // f32(): zero-value
    try std.testing.expect(!ok(sigs, Types.F32, &.{v2f_t})); // f32(vec2): rejected
    try std.testing.expect(!ok(sigs, Types.F32, &.{ Types.F32, Types.F32 })); // arity
}

test "ctorSigsFor vector: splat / compose / copy / zero-arg; width mismatch rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sigs = try Overload.ctorSigsFor(arena.allocator(), v4f_t);
    try std.testing.expect(ok(sigs, v4f_t, &.{Types.F32})); // splat
    try std.testing.expect(ok(sigs, v4f_t, &.{ Types.F32, v2f_t, Types.F32 })); // compose
    try std.testing.expect(ok(sigs, v4f_t, &.{v4f_t})); // copy
    try std.testing.expect(ok(sigs, v4f_t, &.{})); // zero-value
    try std.testing.expect(!ok(sigs, v4f_t, &.{ Types.F32, Types.F32, Types.F32 })); // width 3 != 4
    const r = Overload.resolveTargeted(sigs, v4f_t, &.{Types.F32});
    try std.testing.expectEqualStrings("vec4<f32>", r.ok.string());
}

test "ctorSigsFor vector: abstract-int splat converts to f32 element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sigs = try Overload.ctorSigsFor(arena.allocator(), v4f_t);
    try std.testing.expect(ok(sigs, v4f_t, &.{Types.AbstractInt})); // vec4f(1)
    try std.testing.expect(!ok(sigs, v4f_t, &.{Types.I32})); // vec4f(1i): no implicit i32->f32
}

test "ctorSigsFor matrix: scalars / column vectors / copy / zero-arg; mix rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sigs = try Overload.ctorSigsFor(arena.allocator(), m2x2f_t);
    try std.testing.expect(ok(sigs, m2x2f_t, &.{ Types.F32, Types.F32, Types.F32, Types.F32 }));
    try std.testing.expect(ok(sigs, m2x2f_t, &.{ v2f_t, v2f_t }));
    try std.testing.expect(ok(sigs, m2x2f_t, &.{m2x2f_t})); // copy
    try std.testing.expect(ok(sigs, m2x2f_t, &.{})); // zero-value
    try std.testing.expect(!ok(sigs, m2x2f_t, &.{ Types.F32, v2f_t })); // mix
}

test "ctorSigsFor struct: positional args, arity, field mismatch, field convert, zero-arg" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fields = try arena.allocator().alloc(Types.StructField, 2);
    fields[0] = .{ .name = "a", .typ = Types.I32, .offset = 0 };
    fields[1] = .{ .name = "b", .typ = Types.F32, .offset = 0 };
    const st = try arena.allocator().create(Types.Struct);
    st.* = .{ .name = "S", .fields = fields, .size_bytes = 0, .align_bytes = 0, .has_runtime_array = false };
    const target: Types.Type = .{ .@"struct" = st };
    const sigs = try Overload.ctorSigsFor(arena.allocator(), target);
    try std.testing.expect(ok(sigs, target, &.{ Types.I32, Types.F32 })); // positional
    try std.testing.expect(ok(sigs, target, &.{})); // zero-value
    try std.testing.expect(ok(sigs, target, &.{ Types.AbstractInt, Types.AbstractFloat })); // field convert
    try std.testing.expect(!ok(sigs, target, &.{Types.I32})); // arity
    try std.testing.expect(!ok(sigs, target, &.{ v2f_t, Types.F32 })); // field 'a' type mismatch
}

test "ctorSigsFor array: fixed count positional, arity, element convert, zero-arg" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const arr = Types.Array{ .element = Types.F32, .count = 3 };
    const target: Types.Type = .{ .array = &arr };
    const sigs = try Overload.ctorSigsFor(arena.allocator(), target);
    try std.testing.expect(ok(sigs, target, &.{ Types.F32, Types.F32, Types.F32 }));
    try std.testing.expect(ok(sigs, target, &.{})); // zero-value
    try std.testing.expect(ok(sigs, target, &.{ Types.AbstractInt, Types.AbstractInt, Types.AbstractInt })); // convert
    try std.testing.expect(!ok(sigs, target, &.{ Types.F32, Types.F32 })); // arity
    try std.testing.expect(!ok(sigs, target, &.{ Types.Bool, Types.Bool, Types.Bool })); // bad element
}

test "ctorSigsFor runtime array: only the zero-value form, no positional ctor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const arr = Types.Array{ .element = Types.F32, .count = 0 };
    const target: Types.Type = .{ .array = &arr };
    const sigs = try Overload.ctorSigsFor(arena.allocator(), target);
    try std.testing.expect(ok(sigs, target, &.{})); // runtime-array zero-value
    try std.testing.expect(!ok(sigs, target, &.{Types.F32})); // no element ctor
}

test "ctorSigsFor non-constructible target yields an empty sig set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ptr = Types.Pointer{ .address_space = .function, .element = Types.F32, .access_mode = .read_write };
    const sigs = try Overload.ctorSigsFor(arena.allocator(), .{ .pointer = &ptr });
    try std.testing.expectEqual(@as(usize, 0), sigs.len);
}

// =========================================================================
// 17. Diagnostic refiner hook (Block 4a)
//
// The engine emits one generic no-match diagnostic; constructors want better
// wording ("requires 3 components, got 4", "not a mix", "did you mean
// vec3?"). `resolveTargetedRefined` gives a caller-installed refiner the
// failure path. Still engine-only — the validator does not install a refiner
// until Block 4b, where the swapped-in messages become wire-visible in the
// validate JSON / LSP payloads (called out there). These tests install a
// probe refiner directly to pin the mechanism.
// =========================================================================

const RefinerProbe = struct { calls: u32 = 0 };

fn probeRefine(ctx: *anyopaque, input: Overload.RefineInput) ?Overload.RefinedDiagnostic {
    const p: *RefinerProbe = @ptrCast(@alignCast(ctx));
    p.calls += 1;
    // Thread first_bad_arg into the message to prove it is delivered.
    return .{
        .code = "E0204",
        .message = if (input.first_bad_arg == 1)
            "refined: culprit is argument 1"
        else
            "refined: constructor mismatch",
    };
}

fn nullRefine(ctx: *anyopaque, input: Overload.RefineInput) ?Overload.RefinedDiagnostic {
    _ = ctx;
    _ = input;
    return null;
}

test "refiner: no-match surfaces a refined diagnostic carrying the culprit arg" {
    const sigs = matrixDichotomySigs(2, 2, Types.F32);
    var probe = RefinerProbe{};
    const refiner = Overload.DiagnosticRefiner{ .ctx = &probe, .refine = &probeRefine };
    // Mixed scalar/vector args → fold fails; culprit is the last arg (index 1).
    const args = [_]?Types.Type{ Types.F32, v2f_t };
    const r = Overload.resolveTargetedRefined(&sigs, m2x2f_t, &args, refiner);
    try std.testing.expect(r == .err);
    try std.testing.expect(r.err.refined != null);
    try std.testing.expectEqualStrings("E0204", r.err.refined.?.code);
    try std.testing.expectEqualStrings("refined: culprit is argument 1", r.err.refined.?.message);
    try std.testing.expectEqual(@as(u32, 1), probe.calls);
}

test "refiner: not invoked on a successful resolution" {
    const sigs = matrixDichotomySigs(2, 2, Types.F32);
    var probe = RefinerProbe{};
    const refiner = Overload.DiagnosticRefiner{ .ctx = &probe, .refine = &probeRefine };
    const args = [_]?Types.Type{ v2f_t, v2f_t };
    const r = Overload.resolveTargetedRefined(&sigs, m2x2f_t, &args, refiner);
    try std.testing.expect(r == .ok);
    try std.testing.expectEqual(@as(u32, 0), probe.calls);
}

test "refiner: absent refiner leaves refined null on failure" {
    const sigs = matrixDichotomySigs(2, 2, Types.F32);
    const args = [_]?Types.Type{ Types.F32, v2f_t };
    const r = Overload.resolveTargetedRefined(&sigs, m2x2f_t, &args, null);
    try std.testing.expect(r == .err);
    try std.testing.expect(r.err.refined == null);
}

test "refiner: a refiner returning null leaves refined null" {
    const sigs = matrixDichotomySigs(2, 2, Types.F32);
    var probe = RefinerProbe{};
    const refiner = Overload.DiagnosticRefiner{ .ctx = &probe, .refine = &nullRefine };
    const args = [_]?Types.Type{ Types.F32, v2f_t };
    const r = Overload.resolveTargetedRefined(&sigs, m2x2f_t, &args, refiner);
    try std.testing.expect(r == .err);
    try std.testing.expect(r.err.refined == null);
}

test "refiner: plain resolveTargeted has no refined field set" {
    const sigs = matrixDichotomySigs(2, 2, Types.F32);
    const args = [_]?Types.Type{ Types.F32, v2f_t };
    const r = Overload.resolveTargeted(&sigs, m2x2f_t, &args);
    try std.testing.expect(r == .err);
    try std.testing.expect(r.err.refined == null);
}

// =========================================================================
// 18. Explicit-composite copy/convert (Block 4b)
//
// The single-composite value ctors vecN<T>(vecN<S>) / matCxR<T>(matCxR<S>)
// are *explicit* conversions (WGSL §16.2.2): any concrete S converts
// element-wise to any concrete T (vec2f(vec2u), mat2x2f(mat2x2h)) — looser
// than the implicit `conversionRank` the splat/compose forms use. Block 4a's
// copy sig used `.concrete = target` (implicit only), so these were rejected;
// the `composite_convert` Pattern closes that gap. Width / dimension
// mismatches stay rejected (the call-site refiner explains them in Block 4b).
// =========================================================================

const v2u = Types.Vector{ .width = 2, .element = Types.scalar_u32_ptr };
const v2u_t: Types.Type = .{ .vector = &v2u };
const v4i = Types.Vector{ .width = 4, .element = Types.scalar_i32_ptr };
const v4i_t: Types.Type = .{ .vector = &v4i };
const v4u = Types.Vector{ .width = 4, .element = Types.scalar_u32_ptr };
const v4u_t: Types.Type = .{ .vector = &v4u };
const m2x2h = Types.Matrix{ .cols = 2, .rows = 2, .element = Types.scalar_f16_ptr };
const m2x2h_t: Types.Type = .{ .matrix = &m2x2h };
const m3x3f = Types.Matrix{ .cols = 3, .rows = 3, .element = Types.scalar_f32_ptr };
const m3x3f_t: Types.Type = .{ .matrix = &m3x3f };

test "composite_convert: vec2f(vec2u) explicit element conversion is accepted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sigs = try Overload.ctorSigsFor(arena.allocator(), v2f_t);
    try std.testing.expect(ok(sigs, v2f_t, &.{v2u_t})); // concrete u32 -> concrete f32
}

test "composite_convert: vec4u(vec4i) explicit element conversion is accepted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sigs = try Overload.ctorSigsFor(arena.allocator(), v4u_t);
    try std.testing.expect(ok(sigs, v4u_t, &.{v4i_t}));
}

test "composite_convert: vec2f(vec2f) same-type copy is accepted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sigs = try Overload.ctorSigsFor(arena.allocator(), v2f_t);
    try std.testing.expect(ok(sigs, v2f_t, &.{v2f_t}));
}

test "composite_convert: mat2x2f(mat2x2h) explicit element conversion is accepted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sigs = try Overload.ctorSigsFor(arena.allocator(), m2x2f_t);
    try std.testing.expect(ok(sigs, m2x2f_t, &.{m2x2h_t}));
}

test "composite_convert: width mismatch vec2f(vec3f) stays rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sigs = try Overload.ctorSigsFor(arena.allocator(), v2f_t);
    try std.testing.expect(!ok(sigs, v2f_t, &.{v3f_t}));
}

test "composite_convert: matrix dimension mismatch mat2x2f(mat3x3f) stays rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sigs = try Overload.ctorSigsFor(arena.allocator(), m2x2f_t);
    try std.testing.expect(!ok(sigs, m2x2f_t, &.{m3x3f_t}));
}
